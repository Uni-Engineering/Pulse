part of 'frequency_sync_event_service.dart';

class EventManager with WidgetsBindingObserver {
  static const tag = '_EventManager';
  EventContext eventContext;

  final String appId, baseUrl;
  final bool debugMode;

  EventManager({
    required this.baseUrl,
    required this.appId,
    required this.eventContext,
    required this.debugMode,
  }) {
    if (getIt.isRegistered<DioNetworkServiceType>()) {
      getIt.unregister<DioNetworkServiceType>();
    }
    getIt.registerSingleton<DioNetworkServiceType>(
      DioNetworkService(
        appType: appId,
        baseUrl: baseUrl,
        eventContext: eventContext,
      ),
    );
    if (!getIt.isRegistered<IDatabaseService>()) {
      getIt.registerSingleton<IDatabaseService>(HiveDatabaseService(databaseId: appId));
    }
  }

  bool isEnabled = true;
  BackgroundWorker? backgroundWorker;
  String? _userId, _eventPublishEndpoint;

  final _activeBackgroundSyncLock = Lock(debugLabel: 'active background sync');

  final Map<int, Worker> _workers = {};

  late final _dlqWorker = DLQWorker(
    databaseService: getIt<IDatabaseService>(),
    networkService: getIt<DioNetworkServiceType>(),
    onIrreversibleError: (statusCode) async {
      isEnabled = false;
      await _pauseAllWorkers();
    },
  );

  Future<void> init({
    required String configUrl,
  }) async {
    WidgetsBinding.instance.addObserver(this);

    final sdkConfig = getIt<PulseEventsSdkConfig>();

    // initialize database
    await getIt<IDatabaseService>().init();

    // init core db entity
    await getIt<IDatabaseService>().initEntity<SdkConfigDataModel>(entityId: Constants.coreDbEntityId);

    final eventsProcessingPolicy = await _fetchEventsProcessingPolicy(configUrl);
    final localEventsProcessingPolicy = sdkConfig.shouldUseLocalConfigAsFallback
        ? getIt<IDatabaseService>().get<SdkConfigDataModel>(
            entityId: Constants.coreDbEntityId,
            key: Constants.coreDbEntitySdkConfigKey,
          )
        : null;

    var usingFallbackConfig = false;

    // if the config fetch was successful add the needed worker threads as per the config
    if (eventsProcessingPolicy != null) {
      for (final priorityConfig in eventsProcessingPolicy.priorities) {
        final worker = Worker(
          processingPolicy: priorityConfig,
          eventPublishEndpoint: eventsProcessingPolicy.eventPublishEndpoint,
          onIrreversibleError: (statusCode) async {
            await _pauseAllWorkers();
          },
        );

        _workers[priorityConfig.priority] = worker;
      }

      // save config
      final configPriorities = eventsProcessingPolicy.priorities.map((p) => p.priority).toList();
      final localPriorities = localEventsProcessingPolicy?.priorities ?? <int>[];

      // save the config + local priorities
      await getIt<IDatabaseService>().put<SdkConfigDataModel>(
        entityId: Constants.coreDbEntityId,
        key: Constants.coreDbEntitySdkConfigKey,
        data: SdkConfigDataModel(
          eventPublishEndpoint: eventsProcessingPolicy.eventPublishEndpoint,
          priorities: Set<int>.from(configPriorities + localPriorities).toList(),
          isEnabled: eventsProcessingPolicy.isEnabled,
        ),
      );

      await getIt<IDatabaseService>().flush<SdkConfigDataModel>(entityId: Constants.coreDbEntityId);
    } else {
      if (localEventsProcessingPolicy == null && sdkConfig.fallbackEventPublishEndpoint != null) {
        usingFallbackConfig = true;
        PulseEventsSdk.reportWarning(
          'pulse_using_fallback_config',
          '$tag: using fallback event publish endpoint because remote and local config are unavailable',
          {
            'fallbackEventPublishEndpoint': sdkConfig.fallbackEventPublishEndpoint,
          },
        );
        await getIt<IDatabaseService>().put<SdkConfigDataModel>(
          entityId: Constants.coreDbEntityId,
          key: Constants.coreDbEntitySdkConfigKey,
          data: SdkConfigDataModel(
            eventPublishEndpoint: sdkConfig.fallbackEventPublishEndpoint!,
            priorities: [Utils.defaultEventPublishPolicy.priority],
            isEnabled: true,
          ),
        );
        await getIt<IDatabaseService>().flush<SdkConfigDataModel>(entityId: Constants.coreDbEntityId);
      } else if (localEventsProcessingPolicy == null) {
        Log.i(
          '$tag: init() config fetch failed & no local config found, no fallback event publish endpoint configured',
        );
      }
    }

    // if sdk is not enabled for this user, do not initialize any services
    // sdk is always enabled if run in debugMode
    isEnabled = eventsProcessingPolicy?.isEnabled ?? localEventsProcessingPolicy?.isEnabled ?? usingFallbackConfig;

    if (!debugMode && !isEnabled) {
      if (eventsProcessingPolicy == null &&
          localEventsProcessingPolicy == null &&
          sdkConfig.fallbackEventPublishEndpoint == null) {
        PulseEventsSdk.reportWarning(
          'pulse_no_publish_endpoint',
          '$tag: SDK disabled because no remote, local, or fallback event config is available',
          {
            'hasRemoteConfig': false,
            'hasLocalConfig': false,
          },
        );
      }
      Log.i('Sdk is disabled - debugMode: $debugMode, isEnabled: $isEnabled');
      return;
    }

    // we have the event publish endpoint now, either from config, local db, or hardcoded constant
    // this is done to avoid failing to initialize the sdk
    _eventPublishEndpoint = eventsProcessingPolicy?.eventPublishEndpoint ??
        localEventsProcessingPolicy?.eventPublishEndpoint ??
        sdkConfig.fallbackEventPublishEndpoint;

    if (_eventPublishEndpoint == null) {
      PulseEventsSdk.reportWarning(
        'pulse_no_publish_endpoint',
        '$tag: SDK initialized without an event publish endpoint',
        {
          'hasRemoteConfig': eventsProcessingPolicy != null,
          'hasLocalConfig': localEventsProcessingPolicy != null,
          'isEnabled': isEnabled,
        },
      );
      return;
    }

    // init background worker
    backgroundWorker = BackgroundWorker(
      debugMode: debugMode,
      baseUrl: baseUrl,
      appId: appId,
      eventPublishEndpoint: _eventPublishEndpoint!,
    );

    // find lost priorities - which remains in the local storage but are no more included in the config
    final lostPriorities = Set<int>.from(localEventsProcessingPolicy?.priorities ?? const <int>[]);
    final configPriorities = Set<int>.from(eventsProcessingPolicy?.priorities.map((p) => p.priority) ?? const <int>[]);

    lostPriorities.removeAll(configPriorities);

    // -1 priority events are not considered as lostPriorities as it will always have an active worker
    // handle local events which remains the db but has been forgotten and are not received in the config call
    unawaited(
      () async {
        if (_eventPublishEndpoint == null) return;

        final status = await _dlqWorker.processEventsFor(
          eventPublishEndpoint: _eventPublishEndpoint!,
          eventPriorities: lostPriorities,
        );

        Log.i('$tag: lost events sync complete status: $status');
      }(),
    );

    // Add default worker: with -1 priority
    final defaultWorker = Worker(
      processingPolicy: Utils.defaultEventPublishPolicy,
      eventPublishEndpoint: _eventPublishEndpoint!,
      onIrreversibleError: (statusCode) async {
        await _pauseAllWorkers();
      },
    );

    _workers[Utils.defaultEventPublishPolicy.priority] = defaultWorker;

    final futures = <Future<void>>[];

    // initialize all workers
    for (final worker in _workers.values) {
      futures.add(worker.initialize());
    }

    futures.add(
      backgroundWorker!.registerTask(eventContext: eventContext),
    );

    // wait until all workers are initialized & background task is registered
    await Future.wait(futures);
  }

  void trackEvent({
    required String eventName,
    required Map<String, dynamic> payload,
    required int priority,
  }) {
    if (!isEnabled) return;

    /// check if current priority exists in [_workers] list
    final key = _workers.containsKey(priority) ? priority : Utils.defaultEventPublishPolicy.priority;
    final worker = _workers[key];
    if (worker == null) {
      PulseEventsSdk.reportWarning(
        'pulse_missing_worker',
        '$tag: no worker found for event priority',
        {
          'eventName': eventName,
          'requestedPriority': priority,
          'selectedPriority': key,
          'availablePriorities': _workers.keys.toList(),
        },
      );
      return;
    }

    unawaited(worker.trackEvent(eventName: eventName, payload: payload, userId: _userId));
  }

  set userId(String userId) {
    if (!isEnabled) return;

    _userId = userId;

    Log.i('$tag: set userId to $userId');

    // re register worker, as the userId has changed
    backgroundWorker?.registerTask(eventContext: eventContext);
  }

  set setEventContext(EventContext newEventContext) {
    eventContext = newEventContext;
    isEnabled = true;

    if (getIt.isRegistered<DioNetworkServiceType>()) {
      getIt.unregister<DioNetworkServiceType>();
    }

    getIt.registerSingleton<DioNetworkServiceType>(
      DioNetworkService(
        appType: appId,
        baseUrl: baseUrl,
        eventContext: eventContext,
      ),
    );

    _workers.forEach((priority, worker) {
      worker.workerService.restart();
    });

    // an auth token just became available (eg. user logged in) - flush the
    // backlog accumulated while sync was not possible
    if (newEventContext.appAuthToken != null) {
      for (final worker in _workers.values) {
        unawaited(worker.flushNow());
      }
    }

    backgroundWorker?.registerTask(eventContext: eventContext);
  }

  /// fetch events sdk config
  Future<EventsSdkProcessingPolicy?> _fetchEventsProcessingPolicy(String configUrl) async {
    final sdkConfig = getIt<PulseEventsSdkConfig>();
    final maxAttempts = sdkConfig.configFetchMaxRetries < 1 ? 1 : sdkConfig.configFetchMaxRetries;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await getIt<DioNetworkServiceType>().get(configUrl);
        if (response?.statusCode == HttpStatus.ok) return EventsSdkProcessingPolicy.fromJson(response.dataMap);
        lastError = 'statusCode=${response?.statusCode}';
      } catch (e) {
        lastError = e;
        Log.e('$tag: error fetching config: $e');
      }

      if (attempt < maxAttempts) {
        await Future.delayed(sdkConfig.configFetchRetryDelay);
      }
    }

    PulseEventsSdk.reportWarning(
      'pulse_config_fetch_failed',
      '$tag: failed to fetch events SDK config after retries',
      {
        'configUrl': configUrl,
        'attempts': maxAttempts,
        'lastError': lastError?.toString(),
      },
    );

    return null;
  }

  Future<void> _pauseAllWorkers() async {
    await Future.wait(_workers.values.map((worker) => worker.pauseSync()));
  }

  Future<void> _pauseWorkerAndInvokeSyncAll(Worker worker) async {
    // wait until the worker is paused
    await worker.pauseSync();

    // invoke sync all
    return worker.syncAllEvents();
  }

  void logout() {
    if (!isEnabled) return;

    // remove the user Id
    _userId = null;

    // re register worker, as the userId has changed
    backgroundWorker?.registerTask(eventContext: eventContext);
  }

  /// App Lifecycle Methods [didChangeAppLifecycleState], [_onPause], [_onResume]
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    Log.i('$tag: didChangeAppLifecycleState updated to $state');

    switch (state) {
      case AppLifecycleState.paused:
        return _onPause();

      case AppLifecycleState.resumed:
        return _onResume();

      default:
        return;
    }
  }

  /// When app is put to background, all workers are suspended
  /// And an event sync attempt is initiated
  ///
  /// NOTE: Before initiating the single task worker event sync,
  /// we make sure all currently active workers become dormant first
  void _onPause() async {
    await _activeBackgroundSyncLock.acquire();

    try {
      final futures = <Future<void>>[];

      // collect all futures for pause and syncall invocation futures
      for (final worker in _workers.values) {
        futures.add(_pauseWorkerAndInvokeSyncAll(worker));
      }

      Log.i('$tag: pausing sync for ${_workers.length} workers & invoking syncAll for them');

      // wait for all the workers to become dormant
      // each workers internally maintains 3 locks, so it may take a while
      await Future.wait(futures);

      Log.i('$tag: all workers finished working, all of them are dormant now');
    } catch (e) {
      Log.e('$tag: collective sync threw error: $e');
    }

    // finally release the lock
    _activeBackgroundSyncLock.release();
  }

  /// If app gets back to foreground, previously suspended workers are restarted
  ///
  /// NOTE: The workers are resumed only after [_activeBackgroundSyncLock] is freed
  /// This ensures, no race around occurs for syncing events of a particular type
  void _onResume() async {
    // wait if an active sync is occuring
    await _activeBackgroundSyncLock.locked;

    Log.i('$tag: no active background sync is going on, restarting all workers');
    for (final worker in _workers.values) {
      worker.resumeSync();
    }

    Log.i('$tag: restarted ${_workers.length} workers');
  }
}
