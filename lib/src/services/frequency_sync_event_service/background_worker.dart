// Copyright 2025 Pulse Events SDK Contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:uni_pulse_events_sdk/uni_pulse_events_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:uni_pulse_events_sdk/src/services/db/hive_database_service.dart';
import 'package:workmanager/workmanager.dart';

import '../../constants/constants.dart';
import '../../db_models/event_data_model.dart';
import '../../db_models/sdk_config_data_model.dart';
import '../log/log.dart';
import '../network/dio_network_service.dart';
import '../utils/utils.dart';
import 'workers/single_task_worker.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  const tag = 'Background callback dispatcher';

  Workmanager().executeTask(
    (taskName, inputData) async {
      Log.i('$tag: $taskName is invoked with $inputData');
      if (inputData == null) throw BackgroundTaskInvokedWithEmptyInputData();

      // read from inputData
      final databaseId = inputData[BackgroundTaskConstants.databaseIdKey] as String;
      final baseUrl = inputData[BackgroundTaskConstants.baseUrlKey] as String;
      final eventPublishEndpoint = inputData[BackgroundTaskConstants.eventPublishEndpointKey] as String;
      final appAuthToken = inputData[BackgroundTaskConstants.appAuthTokenKey] as String;
      final deviceId = inputData[BackgroundTaskConstants.deviceIdKey] as String;
      final sessionId = inputData[BackgroundTaskConstants.sessionIdKey] as String;
      final debugMode = inputData[BackgroundTaskConstants.debugMode] as bool;
      final appType = inputData[BackgroundTaskConstants.appType] as String;

      // ensure background isolate has required singletons in GetIt
      // 1) SDK config (reconstruct from inputData if supplied)
      if (!getIt.isRegistered<PulseEventsSdkConfig>()) {
        final largestBatchSize = inputData[BackgroundTaskConstants.cfgLargestBatchSize] as int?;
        final eventSyncTimeoutMs = inputData[BackgroundTaskConstants.cfgEventSyncNetworkTimeoutMs] as int?;
        final retryDelayMs = inputData[BackgroundTaskConstants.cfgSyncRetryDelayDurationMs] as int?;
        final workerRetryMs = inputData[BackgroundTaskConstants.cfgWorkerRetryPeriodMs] as int?;

        final cfg = PulseEventsSdkConfig(
          largestBatchSize: largestBatchSize ?? 100,
          eventSyncNetworkTimeout: Duration(
            milliseconds: eventSyncTimeoutMs ?? const Duration(seconds: 10).inMilliseconds,
          ),
          syncRetryDelayDuration: Duration(
            milliseconds: retryDelayMs ?? (!kReleaseMode ? 5000 : 10000),
          ),
          workerRetryPeriod: Duration(
            milliseconds: workerRetryMs ?? const Duration(seconds: 10).inMilliseconds,
          ),
        );

        getIt.registerSingleton<PulseEventsSdkConfig>(cfg);
      }

      // 2) Network service with the provided event context
      final bgEventContext = EventContext(
        appAuthToken: appAuthToken,
        deviceId: deviceId,
        sessionId: sessionId,
      );

      final dioService = DioNetworkService(
        appType: appType,
        baseUrl: baseUrl,
        eventContext: bgEventContext,
      );

      // Re-register each run to keep headers fresh
      if (getIt.isRegistered<DioNetworkServiceType>()) {
        getIt.unregister<DioNetworkServiceType>();
      }
      getIt.registerSingleton<DioNetworkServiceType>(dioService);

      // prepare database service
      final databaseService = HiveDatabaseService(
        databaseId: databaseId,
      );

      await databaseService.init();

      // initialize dlq worker
      final dlqWorker = DLQWorker(
        databaseService: databaseService,
        networkService: dioService,
      );

      // init core db entity & read the sdk config data model
      await databaseService.initEntity<SdkConfigDataModel>(entityId: Constants.coreDbEntityId);
      final sdkConfigDataModel = dlqWorker.databaseService.get<SdkConfigDataModel>(
        entityId: Constants.coreDbEntityId,
        key: Constants.coreDbEntitySdkConfigKey,
      );

      // process events from single task worker
      final prioritiesSet = (sdkConfigDataModel?.priorities ?? const <int>[]).toSet();

      // add miscellaneous event's priority
      final miscellaneousEventPriority = Utils.defaultEventPublishPolicy.priority;
      prioritiesSet.add(miscellaneousEventPriority);

      // in case of debugMode, add an event for invocation of background task
      // this event is to test out background tasks
      if (debugMode) {
        // prepare event logging

        final entityId = Utils.getEntityIdFor(priority: miscellaneousEventPriority);
        final backgroundTaskTriggeredEvent = Utils.generateBgTaskTriggeredEventWithPriority(
          miscellaneousEventPriority,
        );

        await databaseService.initEntity<EventDataModel>(entityId: entityId);

        // put the event in miscellaneous category
        await databaseService.put<EventDataModel>(
          entityId: entityId,
          key: backgroundTaskTriggeredEvent.eventId,
          data: backgroundTaskTriggeredEvent,
        );
      }

      Log.i('$tag: Invoking event processing for priorities: $prioritiesSet');

      return dlqWorker.processEventsFor(
        eventPriorities: prioritiesSet,
        eventPublishEndpoint: eventPublishEndpoint,
      );
    },
  );
}

class BackgroundWorker {
  static const tag = 'BackgroundWorker';

  final bool debugMode;
  final String baseUrl;
  final String appId;
  final String eventPublishEndpoint;
  final void Function(int? statusCode)? onIrreversibleError;

  BackgroundWorker({
    required this.debugMode,
    required this.baseUrl,
    required this.appId,
    required this.eventPublishEndpoint,
    this.onIrreversibleError,
  }) {
    _spawnWorker();
  }

  /// initializes a worker
  Future<void> _spawnWorker() {
    // register dispatcher
    return Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: debugMode,
    );
  }

  /// Registers a background worker,
  /// This method can be called multiple times, existing registered tasks would be replaced if called again
  ///
  /// [appAuthToken] can be null, in case the user is not logged in
  Future<void> registerTask({
    required EventContext eventContext,
  }) async {
    // if we don't have an active auth token, there is no point registering a background worker
    if (eventContext.appAuthToken == null) return;

    final config = getIt<PulseEventsSdkConfig>();

    final inputData = <String, dynamic>{
      BackgroundTaskConstants.baseUrlKey: baseUrl,
      BackgroundTaskConstants.databaseIdKey: appId,
      BackgroundTaskConstants.eventPublishEndpointKey: eventPublishEndpoint,
      BackgroundTaskConstants.appAuthTokenKey: eventContext.appAuthToken,
      BackgroundTaskConstants.deviceIdKey: eventContext.deviceId,
      BackgroundTaskConstants.sessionIdKey: eventContext.sessionId,
      BackgroundTaskConstants.debugMode: debugMode,
      BackgroundTaskConstants.appType: appId,
      // pass runtime SDK config for background isolate reconstruction
      BackgroundTaskConstants.cfgLargestBatchSize: config.largestBatchSize,
      BackgroundTaskConstants.cfgEventSyncNetworkTimeoutMs: config.eventSyncNetworkTimeout.inMilliseconds,
      BackgroundTaskConstants.cfgSyncRetryDelayDurationMs: config.syncRetryDelayDuration.inMilliseconds,
      BackgroundTaskConstants.cfgWorkerRetryPeriodMs: config.workerRetryPeriod.inMilliseconds,
    };

    try {
      // register one off task with following policies
      return Workmanager().registerOneOffTask(
        BackgroundTaskConstants.taskIdentifier,
        BackgroundTaskConstants.taskName,
        tag: BackgroundTaskConstants.taskTag,
        initialDelay: BackgroundTaskConstants.initialDelay,
        backoffPolicyDelay: BackgroundTaskConstants.backOffPolicyDelay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        backoffPolicy: BackoffPolicy.linear,
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        inputData: inputData,
      );
    } catch (e) {
      Log.e('$tag: ${BackgroundTaskConstants.taskIdentifier} failed to register one off task with error: $e');
    }
  }
}
