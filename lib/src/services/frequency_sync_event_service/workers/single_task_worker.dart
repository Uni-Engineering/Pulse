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

import 'dart:async';

import '../../../constants/constants.dart';
import '../../../db_models/event_data_model.dart';
import '../../../db_models/sdk_config_data_model.dart';
import '../../interfaces/database_service.dart';
import '../../interfaces/network_service.dart';
import '../../log/log.dart';
import '../../utils/utils.dart';
import '../models/event_sync_result.dart';
import 'worker_service.dart';

class DLQWorker {
  static const tag = 'DLQWorker';

  final IDatabaseService databaseService;
  final INetworkService networkService;
  final void Function(int?)? onIrreversibleError;

  /// This worker acts on lost, forgotton or remaining events
  /// which has been lying in the user's local storage - ready to be synced
  /// This worker is invoked once when the event service initializes,
  /// Or, from the background worker manager
  DLQWorker({
    required this.databaseService,
    required this.networkService,
    this.onIrreversibleError,
  });

  /// Make sure the event priorities included in the [eventPriorities] list DO NOT have an active worker
  /// otherwise it may cause conflict & multiple unncessary calls could happen to the server
  /// In case invoked from background worker, the above warning do not apply
  ///
  /// Returns the sync status, if sync succeeds this method returns true, otherwise false
  Future<bool> processEventsFor({
    required String eventPublishEndpoint,
    required Set<int> eventPriorities,
  }) async {
    Log.i('$tag: processEventsFor(...) invoked with eventPriorities: $eventPriorities');

    final futures = <Future<SingularEventSyncResult>>[];

    for (final priority in eventPriorities) {
      futures.add(
        _syncEventsForPriority(
          priority: priority,
          eventPublishEndpoint: eventPublishEndpoint,
        ),
      );
    }

    final syncStatuses = await Future.wait(futures);

    // clean up entities for successfully synced events
    await _cleanupEntitiesFor(
      priorities: Set<int>.from(syncStatuses.where((s) => s.isSyncSuccessful).map((s) => s.priority)),
    );

    // if even a single batch was unnsuccessful, return status as false
    for (final syncStatus in syncStatuses) {
      if (syncStatus.isSyncSuccessful == false) return false;
    }

    return true;
  }

  /// Retrieve local events for [priority] and try syncing them
  /// returns the sync status for the single priority type
  Future<SingularEventSyncResult> _syncEventsForPriority({
    required int priority,
    required String eventPublishEndpoint,
  }) async {
    Log.i('$tag: invoked _syncEventsForPriority(...) for priorty: $priority');

    final entityId = Utils.getEntityIdFor(priority: priority);

    // init entity
    await databaseService.initEntity<EventDataModel>(entityId: entityId);

    await _deleteAlreadySyncedEvents(entityId: entityId);

    // pick all events that are not sycned yet
    final notSycnedEvents =
        databaseService.getAll<EventDataModel>(entityId: entityId).where((e) => e.status != EventStatus.synced);

    if (notSycnedEvents.isEmpty) {
      Log.i('$tag: All events in $entityId for priority: $priority are already synced');
      return SingularEventSyncResult(
        priority: priority,
        isSyncSuccessful: true,
      );
    }

    Log.i('$tag: Found ${notSycnedEvents.length} notSynced events for priority $priority');

    // try syncing events
    final syncResult = await WorkerService(
      tag,
      onIrreversibleError: onIrreversibleError,
    ).syncToServer(
      eventPublishEndpoint: eventPublishEndpoint,
      eventsToSync: notSycnedEvents,
      retry: true, // allow retry
    );

    Log.i('$tag: _syncEventsForPriority(priority: $priority), syncStatus: $syncResult');

    // remove the successfully synced events, and keep the failed ones - to be retried at a later point
    if (syncResult.hasAtleastOneSucceeded) {
      await databaseService.deleteAll<EventDataModel>(
        entityId: entityId,
        keys: syncResult.succeeded.map<String>((e) => e.eventId),
      );

      await databaseService.flush<EventDataModel>(entityId: entityId);
    }

    // if all events are synced successfully
    if (syncResult.hasAllSucceeded) {
      Log.i('$tag: Events in $entityId are successfully synced');
      return SingularEventSyncResult(
        priority: priority,
        isSyncSuccessful: true,
      );
    }

    return SingularEventSyncResult(
      priority: priority,
      isSyncSuccessful: false,
    );
  }

  Future<void> _deleteAlreadySyncedEvents({required String entityId}) async {
    final syncedEventIds = databaseService
        .getAll<EventDataModel>(entityId: entityId)
        .where((event) => event.status == EventStatus.synced)
        .map((event) => event.eventId);

    await databaseService.deleteAll<EventDataModel>(
      entityId: entityId,
      keys: syncedEventIds,
    );
    await databaseService.flush<EventDataModel>(entityId: entityId);
  }

  /// Updates the core db entity [Constants.coreDbEntityId] to reflect the synced changes,
  /// and also removes stale entities from disk
  Future<void> _cleanupEntitiesFor({required Set<int> priorities}) async {
    if (priorities.isEmpty) return;

    await databaseService.initEntity<SdkConfigDataModel>(entityId: Constants.coreDbEntityId);
    final localConfig = databaseService.get<SdkConfigDataModel>(
      entityId: Constants.coreDbEntityId,
      key: Constants.coreDbEntitySdkConfigKey,
    );

    if (localConfig != null) {
      // remove the priority for whom the entity is deleted
      final localPriorities = Set<int>.from(localConfig.priorities);
      localPriorities.removeAll(priorities);

      // write back new priorities to db
      await databaseService.put<SdkConfigDataModel>(
        entityId: Constants.coreDbEntityId,
        key: Constants.coreDbEntitySdkConfigKey,
        data: SdkConfigDataModel(
          eventPublishEndpoint: localConfig.eventPublishEndpoint,
          priorities: localPriorities.toList(),
          isEnabled: localConfig.isEnabled,
        ),
      );

      await databaseService.flush<SdkConfigDataModel>(entityId: Constants.coreDbEntityId);
    }

    return;
  }
}
