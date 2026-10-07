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
import 'package:uni_pulse_events_sdk/uni_pulse_events_sdk.dart';
import 'package:uni_pulse_events_sdk/src/constants/constants.dart';
import 'package:uni_pulse_events_sdk/src/services/interfaces/database_service.dart';
import 'package:uni_pulse_events_sdk/src/services/network/dio_network_service.dart';

import '../../../db_models/event_data_model.dart';
import '../../log/log.dart';
import '../../synchronization/lock.dart';
import '../../utils/utils.dart';
import '../models/events_priority_config.dart';
import 'worker_service.dart';

class Worker {
  final String tag;
  final EventProcessingPolicy processingPolicy;
  final String eventPublishEndpoint;

  late final _prepareSyncLock = Lock(debugLabel: '$tag prepare sync lock');
  late final _syncToServerLock = <EventStatus, Lock>{
    EventStatus.readyToSync: Lock(debugLabel: '$tag ready to sync lock'),
    EventStatus.failed: Lock(debugLabel: '$tag failed lock'),
  };
  late final WorkerService workerService = WorkerService(
    tag,
    onIrreversibleError: (statusCode) async {
      await pauseSync();
    },
  );

  final Duration _syncDuration;
  final String _workerEntityId;
  final void Function(int? statusCode)? onIrreversibleError;

  // Readiness gate to ensure DB entity is initialized before access
  final Completer<void> _ready = Completer<void>();
  Future<void> _awaitReady() async {
    if (!_ready.isCompleted) {
      await _ready.future;
    }
  }

  Worker({
    required this.processingPolicy,
    this.onIrreversibleError,
    required this.eventPublishEndpoint,
  })  : tag = 'worker(${processingPolicy.priority})',
        _syncDuration = Duration(seconds: processingPolicy.configuration.frequencyInSec),
        _workerEntityId = Utils.getEntityIdFor(priority: processingPolicy.priority);

  Timer? _flushDebounceTimer;
  Timer? _syncTimer;
  Timer? _workerRetryTimer;
  bool _isWorkerPaused = false;

  final databaseService = getIt<IDatabaseService>();
  final networkService = getIt<DioNetworkServiceType>();

  /// Initializes the worker by creating a unique database entity for it's events
  /// and sets up timers for batch processing
  Future<void> initialize() async {
    await databaseService.initEntity<EventDataModel>(entityId: _workerEntityId);
    await _deleteAlreadySyncedEvents();

    if (!_ready.isCompleted) {
      _ready.complete();
    }

    Log.i('$tag: entity id: $_workerEntityId is successfully initialized');

    Log.i('$tag: attempting startup sync for readyToSync and failed events');
    unawaited(_syncToServer(whichEvents: EventStatus.readyToSync));
    unawaited(_syncToServer(whichEvents: EventStatus.failed));
    _registerWorkerRetryTimer();
    unawaited(_onNewEventAdd());
  }

  /// This method tries to sync the events to server
  /// Two types of events can be syned to server:
  /// which are fresh, marked as [EventStatus.readyToSync], and
  /// which were tried earlier and has failed, marked as [EventStatus.failed]
  /// If sync succeeds, events are marked as [EventStatus.synced] or else marked as [EventStatus.failed]
  Future<void> _syncToServer({required EventStatus whichEvents}) async {
    if (_isWorkerPaused) return;

    // without an auth token the publish call can never succeed - leave the
    // events untouched so they are retried once the user logs in
    if (!getIt.isRegistered<DioNetworkServiceType>() || !getIt<DioNetworkServiceType>().hasAuthToken) {
      Log.i('$tag: skipping sync for $whichEvents - no auth token available');
      return;
    }

    // only [readyToSync] or [failed] events can be synced to server
    assert(whichEvents == EventStatus.readyToSync || whichEvents == EventStatus.failed);

    // lock the appropriate batch
    await _syncToServerLock[whichEvents]!.acquire();

    try {
      Log.i('$tag: _syncToServer(for: $whichEvents) invoked - attempting to sync events');

      // Ensure readiness before attempting to read/write from DB
      await _awaitReady();

      final eventsToSync = queryEventsFromDB(_workerEntityId, filter: (o) => o.status == whichEvents);

      if (eventsToSync.isEmpty) {
        Log.i('$tag: no events to sync for event status: $whichEvents');
        return;
      }

      Log.i(
        '$tag: _syncToServer() total ${eventsToSync.length} events found which needs to be synced from $whichEvents state',
      );

      final syncResult = await workerService.syncToServer(
        eventPublishEndpoint: eventPublishEndpoint,
        eventsToSync: eventsToSync,
      );

      Log.i('$tag: _syncToServer() events from $whichEvents state, sync status: $syncResult');

      // update synchronization status in the db

      // remove successfully synced events
      await databaseService.deleteAll<EventDataModel>(
        entityId: _workerEntityId,
        keys: syncResult.succeeded.map((e) => e.eventId),
      );

      final eventsToUpdate = <String, EventDataModel>{};

      // mark failed events as failed
      for (final event in syncResult.failed) {
        // if event status did not change, do not add event to change batch
        // this can happen if a failed batch was retried and has failed again - sad but true :)
        if (event.status == EventStatus.failed) continue;
        event.status = EventStatus.failed;
        eventsToUpdate[event.eventId] = event;
      }

      // write to db
      await databaseService.putAll<EventDataModel>(entityId: _workerEntityId, entries: eventsToUpdate);
      return databaseService.flush<EventDataModel>(entityId: _workerEntityId);
    } on NothingToSync catch (e) {
      Log.i('$tag: no events to sync for event status: ${e.eventStatus}');
    } catch (e) {
      Log.e('$tag: syncing to server caused unknown error: $e');
    } finally {
      // always release the lock
      _syncToServerLock[whichEvents]!.release();
    }
  }

  void _registerWorkerRetryTimer() {
    _workerRetryTimer?.cancel();
    final retryPeriod = getIt<PulseEventsSdkConfig>().workerRetryPeriod;
    _workerRetryTimer = Timer.periodic(retryPeriod, (_) {
      unawaited(_syncToServer(whichEvents: EventStatus.readyToSync));
      unawaited(_syncToServer(whichEvents: EventStatus.failed));
    });
  }

  /// Immediately attempts to sync every non-synced event.
  /// Unlike [syncAllEvents] this is safe to call on an active worker.
  Future<void> flushNow() async {
    if (_isWorkerPaused) return;

    Log.i('$tag: flushNow() invoked');

    await _prepareAndTrySync();
    await _syncToServer(whichEvents: EventStatus.failed);
  }

  /// Immediately saves the event in the local db, a batch try would happen later to sync the events
  Future<void> trackEvent({
    required String eventName,
    required Map<String, dynamic> payload,
    String? userId,
  }) async {
    try {
      // Wait until entity is initialized before writing
      await _awaitReady();
      final eventId = Utils.generateEventId();

      Log.i('$tag: trackEvent(eventName: $eventName) invoked, recording event with eventId: $eventId');

      // store the event to db first
      await databaseService.put<EventDataModel>(
        entityId: _workerEntityId,
        key: eventId,
        data: EventDataModel(
          eventId: eventId,
          eventName: eventName,
          payload: Utils.prepareEventPayloadFrom(
            payload: payload,
            eventPriority: processingPolicy.priority,
          ),
        ),
      );

      _flushChanges();

      // notify an event addition
      unawaited(_onNewEventAdd());
    } catch (e, stackTrace) {
      Log.e('$tag: failed to record event "$eventName": $e');
      PulseEventsSdk.reportWarning(
        'pulse_db_write_failed',
        '$tag: failed to persist event locally',
        {
          'eventName': eventName,
          'priority': processingPolicy.priority,
          'error': e.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  Future<void> _onNewEventAdd() async {
    // if worker is paused, no further handling of onEventAdd is executed
    if (_isWorkerPaused) return;

    // wait if lock is acquired - meaning we are preparing events for sycning
    await _prepareSyncLock.locked;

    // Ensure readiness before attempting to read from DB
    await _awaitReady();

    final hasMetBatchSize = databaseService
            .getAll<EventDataModel>(entityId: _workerEntityId)
            .where((e) => e.status == EventStatus.pending)
            .length >=
        processingPolicy.configuration.batchSize;

    // check if we have met batch-size
    if (hasMetBatchSize) {
      Log.i('$tag: sync batch size met');

      // cancel any on-going timer
      _syncTimer?.cancel();

      // invoke a sync command
      return _prepareAndTrySync();
    }

    // start a timer, if not already active - as a fallback to sync events
    if (_syncTimer == null || _syncTimer!.isActive == false) {
      Log.i('$tag: starting a timer for event sync as a backup');
      _syncTimer = Timer(
        _syncDuration,
        _prepareAndTrySync, // time has run up, invoke sync command
      );
    }
  }

  /// This method attempts to sync all non-synced (except [EventStatus.synced]) events
  /// The worker must be paused before invoking this method,
  /// otherwise an [AllSyncInvokedOnActiveWorker] would be thrown
  Future<void> syncAllEvents() async {
    if (!_isWorkerPaused) {
      throw AllSyncInvokedOnActiveWorker();
    }

    Log.i('$tag: syncAllEvents() invoked');

    await _deleteAlreadySyncedEvents();

    // pick all events for syncing
    final eventsToSync = queryEventsFromDB(_workerEntityId, filter: (e) => e.status != EventStatus.synced);

    if (eventsToSync.isEmpty) {
      return Log.i('$tag: syncAllEvents() found no events to sync');
    }

    Log.i('$tag: syncAllEvents() found ${eventsToSync.length} events to sync');

    // start syncing with retry
    final syncStatus = await workerService.syncToServer(
      eventPublishEndpoint: eventPublishEndpoint,
      eventsToSync: eventsToSync,
      retry: true,
    );

    Log.i('$tag: syncAllEvents() finished with sync status: $syncStatus');

    // remove successfully synced events
    await databaseService.deleteAll<EventDataModel>(
      entityId: _workerEntityId,
      keys: syncStatus.succeeded.map((e) => e.eventId),
    );

    if (syncStatus.failed.isNotEmpty) {
      final failedEvents = <String, EventDataModel>{};
      for (final event in syncStatus.failed) {
        event.status = EventStatus.failed;
        failedEvents[event.eventId] = event;
      }
      await databaseService.putAll<EventDataModel>(entityId: _workerEntityId, entries: failedEvents);
    }

    return databaseService.flush<EventDataModel>(entityId: _workerEntityId);
  }

  Future<void> _prepareAndTrySync() async {
    await _prepareSyncLock.acquire();

    try {
      Log.i('$tag: _prepareAndTrySync() invoked - preparing events to sync');

      // Ensure readiness before attempting to read/write from DB
      await _awaitReady();

      final pendingSyncEvents = queryEventsFromDB(_workerEntityId, filter: (e) => e.status == EventStatus.pending);

      if (pendingSyncEvents.isEmpty) {
        Log.i('$tag: _prepareAndTrySync() found no events for preparation from event status: ${EventStatus.pending}');
      }

      Log.i('$tag: _prepareAndTrySync() total ${pendingSyncEvents.length} found which will be marked as readyToSync');

      final eventsToUpdate = <String, EventDataModel>{};

      // update all pending event's statuses to readyToSync
      for (final event in pendingSyncEvents) {
        event.status = EventStatus.readyToSync;
        eventsToUpdate[event.eventId] = event;
      }

      await databaseService.putAll<EventDataModel>(entityId: _workerEntityId, entries: eventsToUpdate);
    } catch (e) {
      Log.e('$tag: _prepareAndTrySync() failed with error: $e');
    } finally {
      // always release the lock
      _prepareSyncLock.release();
    }

    return _syncToServer(whichEvents: EventStatus.readyToSync);
  }

  /// Pauses sync for a worker - any running timer will be cancelled, such that no further sync occurs
  /// Existing sync operation would continue until they either fail or succeed
  ///
  /// This method returns a future - if existing operation is going on,
  /// the method completes, once that operation is finished
  Future<void> pauseSync() async {
    Log.i('$tag: worker is paused');

    // cancel existing syncTimer
    _syncTimer?.cancel();

    // cancels retry timer
    _workerRetryTimer?.cancel();

    // wait if _prepareSyncLock is currently active
    await _prepareSyncLock.locked;

    // wait if any _syncToServerLock is currently active
    for (final lock in _syncToServerLock.values) {
      await lock.locked;
    }

    // mark the worker as paused
    _isWorkerPaused = true;
  }

  /// Resumes sync operations for a worker
  void resumeSync() {
    Log.i('$tag: worker is resumed');

    // mark the worker as resumed before invoking any sync triggers
    _isWorkerPaused = false;

    // resumes retry timer
    _registerWorkerRetryTimer();

    unawaited(_syncToServer(whichEvents: EventStatus.readyToSync));
    unawaited(_syncToServer(whichEvents: EventStatus.failed));

    // simulate an event add - to get the ball rolling
    unawaited(_onNewEventAdd());
  }

  Future<void> _deleteAlreadySyncedEvents() async {
    final syncedEventIds = queryEventsFromDB(
      _workerEntityId,
      filter: (event) => event.status == EventStatus.synced,
    ).map((event) => event.eventId);

    await databaseService.deleteAll<EventDataModel>(
      entityId: _workerEntityId,
      keys: syncedEventIds,
    );
    await databaseService.flush<EventDataModel>(entityId: _workerEntityId);
  }

  Iterable<EventDataModel> queryEventsFromDB(String entityId, {bool Function(EventDataModel)? filter}) {
    return databaseService.getAll<EventDataModel>(entityId: entityId).where(filter ?? (_) => true);
  }

  /// changes are flushed to local storage with a debounced duration of [flushDuration]
  void _flushChanges() {
    _flushDebounceTimer?.cancel();

    _flushDebounceTimer = Timer(
      Constants.dbFlushDuration,
      () {
        Log.i('$tag: db flush() invoked');
        unawaited(() async {
          try {
            await databaseService.flush<EventDataModel>(entityId: _workerEntityId);
          } catch (e, stackTrace) {
            PulseEventsSdk.reportWarning(
              'pulse_db_write_failed',
              '$tag: failed to flush event DB changes',
              {
                'priority': processingPolicy.priority,
                'error': e.toString(),
                'stackTrace': stackTrace.toString(),
              },
            );
          }
        }());
      },
    );
  }
}
