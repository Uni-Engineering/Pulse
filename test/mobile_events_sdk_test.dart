import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_events_sdk/pulse_events_sdk.dart';
import 'package:pulse_events_sdk/src/db_models/data_model.dart';
import 'package:pulse_events_sdk/src/db_models/event_data_model.dart';
import 'package:pulse_events_sdk/src/services/frequency_sync_event_service/models/event_sync_result.dart';
import 'package:pulse_events_sdk/src/services/frequency_sync_event_service/models/events_priority_config.dart';
import 'package:pulse_events_sdk/src/services/frequency_sync_event_service/workers/single_task_worker.dart';
import 'package:pulse_events_sdk/src/services/frequency_sync_event_service/workers/worker.dart';
import 'package:pulse_events_sdk/src/services/interfaces/database_service.dart';
import 'package:pulse_events_sdk/src/services/interfaces/network_service.dart';
import 'package:pulse_events_sdk/src/services/network/dio_network_service.dart';
import 'package:pulse_events_sdk/src/services/utils/utils.dart';

void main() {
  tearDown(() async {
    await getIt.reset();
  });

  test('halted sync result is not treated as success', () {
    final result = EventSyncResult.halted();

    expect(result.isHalted, isTrue);
    expect(result.hasAllSucceeded, isFalse);
    expect(result.isSuccess, isFalse);
  });

  test('DLQWorker removes events after a fully successful sync', () async {
    final databaseService = _FakeDatabaseService();
    final networkService = _FakeNetworkService();

    getIt.registerSingleton<PulseEventsSdkConfig>(
      PulseEventsSdkConfig(largestBatchSize: 50),
    );
    getIt.registerSingleton<DioNetworkServiceType>(networkService);

    final entityId = Utils.getEntityIdFor(priority: -1);
    final event = EventDataModel(
      eventId: 'event-1',
      eventName: 'ScreenLoaded',
      payload: {},
      status: EventStatus.readyToSync,
    );

    await databaseService.initEntity<EventDataModel>(entityId: entityId);
    await databaseService.put<EventDataModel>(
      entityId: entityId,
      key: event.eventId,
      data: event,
    );

    final dlqWorker = DLQWorker(
      databaseService: databaseService,
      networkService: networkService,
    );

    final result = await dlqWorker.processEventsFor(
      eventPublishEndpoint: '/v2/events',
      eventPriorities: {-1},
    );

    expect(result, isTrue);
    expect(networkService.postedEventIds, [
      ['event-1'],
    ]);
    expect(
      databaseService.getAll<EventDataModel>(entityId: entityId),
      isEmpty,
    );
  });

  test('DLQWorker removes legacy synced events without posting them', () async {
    final databaseService = _FakeDatabaseService();
    final networkService = _FakeNetworkService();

    getIt.registerSingleton<PulseEventsSdkConfig>(
      PulseEventsSdkConfig(largestBatchSize: 50),
    );
    getIt.registerSingleton<DioNetworkServiceType>(networkService);

    final entityId = Utils.getEntityIdFor(priority: -1);
    final syncedEvent = EventDataModel(
      eventId: 'event-synced',
      eventName: 'LegacySyncedEvent',
      payload: {},
      status: EventStatus.synced,
    );

    await databaseService.initEntity<EventDataModel>(entityId: entityId);
    await databaseService.put<EventDataModel>(
      entityId: entityId,
      key: syncedEvent.eventId,
      data: syncedEvent,
    );

    final dlqWorker = DLQWorker(
      databaseService: databaseService,
      networkService: networkService,
    );

    final result = await dlqWorker.processEventsFor(
      eventPublishEndpoint: '/v2/events',
      eventPriorities: {-1},
    );

    expect(result, isTrue);
    expect(networkService.postedEventIds, isEmpty);
    expect(
      databaseService.getAll<EventDataModel>(entityId: entityId),
      isEmpty,
    );
  });

  test('Worker removes legacy synced events during initialization', () async {
    final databaseService = _FakeDatabaseService();
    final networkService = _FakeNetworkService();

    getIt.registerSingleton<PulseEventsSdkConfig>(
      PulseEventsSdkConfig(largestBatchSize: 50),
    );
    getIt.registerSingleton<IDatabaseService>(databaseService);
    getIt.registerSingleton<DioNetworkServiceType>(networkService);

    const processingPolicy = EventProcessingPolicy(
      priority: -1,
      configuration: BatchProcessingConfig(
        batchSize: 50,
        frequencyInSec: 100,
      ),
    );
    final entityId = Utils.getEntityIdFor(priority: processingPolicy.priority);
    final syncedEvent = EventDataModel(
      eventId: 'event-synced',
      eventName: 'LegacySyncedEvent',
      payload: {},
      status: EventStatus.synced,
    );

    await databaseService.initEntity<EventDataModel>(entityId: entityId);
    await databaseService.put<EventDataModel>(
      entityId: entityId,
      key: syncedEvent.eventId,
      data: syncedEvent,
    );

    final worker = Worker(
      processingPolicy: processingPolicy,
      eventPublishEndpoint: '/v2/events',
    );

    await worker.initialize();
    await Future<void>.delayed(Duration.zero);
    await worker.pauseSync();

    expect(networkService.postedEventIds, isEmpty);
    expect(
      databaseService.getAll<EventDataModel>(entityId: entityId),
      isEmpty,
    );
  });
}

class _FakeDatabaseService implements IDatabaseService {
  final Map<String, Map<String, DatabaseModel>> _boxes = {};

  @override
  Future<void> init() async {}

  @override
  Future<void> initEntity<T extends DatabaseModel>({
    required String entityId,
  }) async {
    _boxes.putIfAbsent(entityId, () => {});
  }

  @override
  Future<void> put<T extends DatabaseModel>({
    required String entityId,
    required String key,
    required T data,
  }) async {
    _boxes.putIfAbsent(entityId, () => {})[key] = data;
  }

  @override
  Future<void> putAll<T extends DatabaseModel>({
    required String entityId,
    required Map<String, T> entries,
  }) async {
    _boxes.putIfAbsent(entityId, () => {}).addAll(entries);
  }

  @override
  T? get<T extends DatabaseModel>({
    required String entityId,
    required String key,
  }) {
    return _boxes[entityId]?[key] as T?;
  }

  @override
  Iterable<T> getAll<T extends DatabaseModel>({required String entityId}) {
    return (_boxes[entityId]?.values ?? const <DatabaseModel>[]).cast<T>();
  }

  @override
  Future<void> deleteAll<T extends DatabaseModel>({
    required String entityId,
    required Iterable<String> keys,
  }) async {
    final box = _boxes[entityId];
    if (box == null) return;
    for (final key in keys.toList()) {
      box.remove(key);
    }
  }

  @override
  Future<void> flush<T extends DatabaseModel>(
      {required String entityId}) async {}

  @override
  Future<void> deleteEntity({required String entityId}) async {
    _boxes.remove(entityId);
  }
}

class _FakeNetworkService implements INetworkService<Response?> {
  final List<List<String>> postedEventIds = [];

  @override
  bool get hasAuthToken => true;

  @override
  Future<Response?> get(String endpoint) async {
    throw UnimplementedError();
  }

  @override
  Future<Response?> post(
    String endpoint,
    Map<String, dynamic> body, {
    CancelToken? cancelToken,
  }) async {
    final events = body['events'] as List<dynamic>;
    postedEventIds.add(
      events
          .cast<Map<String, dynamic>>()
          .map((event) => event['eventId'] as String)
          .toList(),
    );
    return Response(
      requestOptions: RequestOptions(path: endpoint),
      statusCode: 200,
    );
  }
}
