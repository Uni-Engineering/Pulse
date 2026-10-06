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

// ignore: implementation_imports
import 'package:hive_ce/src/hive_impl.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'dart:io';

import '../../db_models/data_model.dart';
import '../../db_models/event_data_model.dart';
import '../../db_models/sdk_config_data_model.dart';
import '../../exceptions/pulse_events_exceptions.dart';
import '../../services/log/log.dart';
import '../interfaces/database_service.dart';

class HiveDatabaseService implements IDatabaseService {
  static const tag = 'HiveDatabaseService';

  static const baseDirectory = 'events-sdk';

  final HiveImpl hive;
  final String databaseId;

  HiveDatabaseService({
    required this.databaseId,
  }) : hive = HiveImpl();

  @override
  Future<void> init() async {
    try {
      if (!hive.isAdapterRegistered(1)) {
        hive.registerAdapter<EventStatus>(EventStatusAdapter());
      }
      if (!hive.isAdapterRegistered(2)) {
        hive.registerAdapter<EventDataModel>(EventDataModelAdapter());
      }
      if (!hive.isAdapterRegistered(3)) {
        hive.registerAdapter<SdkConfigDataModel>(SdkConfigDataModelAdapter());
      }
      // register data model adapters

      final applicationSupportDirectory = await path_provider.getApplicationSupportDirectory();
      final dbPath = path.join(applicationSupportDirectory.path, baseDirectory);

      // Check if directory exists and is writable
      final dbDir = Directory(dbPath);
      if (!await dbDir.exists()) {
        await dbDir.create(recursive: true);
      }

      // Verify write permissions
      final testFile = File(path.join(dbPath, '.write_test'));
      try {
        await testFile.writeAsString('test');
        await testFile.delete();
      } catch (e) {
        throw DatabaseException('Database directory is not writable: $dbPath', originalError: e);
      }

      hive.init(dbPath);
      Log.i('$tag: Database initialized successfully at $dbPath');
    } on DatabaseException {
      rethrow;
    } catch (e) {
      Log.e('$tag: Failed to initialize database: $e');
      throw DatabaseException('Failed to initialize database', originalError: e);
    }
  }

  @override
  Future<void> initEntity<T extends DatabaseModel>({required String entityId}) async {
    try {
      if (hive.isBoxOpen(entityId)) {
        Log.i('$tag: Hive box $entityId is already open, ignoring the initEntity(...) call');
        return;
      }

      await hive.openBox<T>(entityId);
      Log.i('$tag: Successfully opened box for entity: $entityId');
    } catch (e) {
      Log.e('$tag: Failed to initialize entity $entityId: $e');
      Log.warning(
        'pulse_db_write_failed',
        '$tag: failed to open Hive entity',
        {
          'entityId': entityId,
          'error': e.toString(),
        },
      );
      throw DatabaseException('Failed to initialize entity: $entityId', originalError: e);
    }
  }

  @override
  Future<void> deleteEntity({required String entityId}) async {
    try {
      /// Avoid deleting an entity, as read and write (if needed later) would fail
      /// entities doesn't take much space in disk.
      ///
      /// If it's not in use, this entity won't be holding any data - space isn't an issue.

      // Validate entity exists before attempting deletion
      if (!hive.isBoxOpen(entityId)) {
        Log.i('$tag: Attempted to delete non-existent entity: $entityId');
        return;
      }

      // For now, we don't actually delete entities as per the original design
      // return hive.deleteBoxFromDisk(entityId);
      Log.i('$tag: Entity deletion skipped for: $entityId (by design)');
    } catch (e) {
      Log.e('$tag: Error during entity deletion for $entityId: $e');
      throw DatabaseException('Failed to delete entity: $entityId', originalError: e);
    }
  }

  @override
  Future<void> flush<T extends DatabaseModel>({required String entityId}) async {
    try {
      _validateEntityExists<T>(entityId);
      await hive.box<T>(entityId).flush();
      Log.i('$tag: Successfully flushed entity: $entityId');
    } catch (e) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!hive.isBoxOpen(entityId)) await hive.openBox<T>(entityId);
        await hive.box<T>(entityId).flush();
      } catch (retryError) {
        Log.e('$tag: Failed to flush entity $entityId: $retryError');
        Log.warning(
          'pulse_db_write_failed',
          '$tag: failed to flush Hive entity',
          {
            'entityId': entityId,
            'error': retryError.toString(),
            'firstError': e.toString(),
          },
        );
        throw DatabaseException('Failed to flush entity: $entityId', originalError: retryError);
      }
    }
  }

  @override
  T? get<T extends DatabaseModel>({required String entityId, required String key}) {
    try {
      _validateEntityExists<T>(entityId);
      if (key.isEmpty) {
        throw DatabaseException('Key cannot be empty');
      }

      return hive.box<T>(entityId).get(key);
    } catch (e) {
      Log.e('$tag: Failed to get data for key $key in entity $entityId: $e');
      throw DatabaseException('Failed to get data for key: $key', originalError: e);
    }
  }

  @override
  Iterable<T> getAll<T extends DatabaseModel>({required String entityId}) {
    try {
      _validateEntityExists<T>(entityId);
      return hive.box<T>(entityId).values;
    } catch (e) {
      Log.e('$tag: Failed to get all data from entity $entityId: $e');
      throw DatabaseException('Failed to get all data from entity: $entityId', originalError: e);
    }
  }

  @override
  Future<void> put<T extends DatabaseModel>({required String entityId, required String key, required T data}) async {
    if (key.isEmpty) {
      throw DatabaseException('Key cannot be empty');
    }

    try {
      _validateEntityExists<T>(entityId);

      await hive.box<T>(entityId).put(key, data);
    } catch (e) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!hive.isBoxOpen(entityId)) await hive.openBox<T>(entityId);
        await hive.box<T>(entityId).put(key, data);
      } catch (retryError) {
        Log.e('$tag: Failed to put data for key $key in entity $entityId: $retryError');
        Log.warning(
          'pulse_db_write_failed',
          '$tag: failed to store data in Hive entity',
          {
            'entityId': entityId,
            'key': key,
            'error': retryError.toString(),
            'firstError': e.toString(),
          },
        );
        throw DatabaseException('Failed to store data for key: $key', originalError: retryError);
      }
    }
  }

  @override
  Future<void> putAll<T extends DatabaseModel>({required String entityId, required Map<String, T> entries}) async {
    try {
      _validateEntityExists<T>(entityId);

      if (entries.isEmpty) {
        return;
      }

      await hive.box<T>(entityId).putAll(entries);
    } catch (e) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!hive.isBoxOpen(entityId)) await hive.openBox<T>(entityId);
        await hive.box<T>(entityId).putAll(entries);
      } catch (retryError) {
        Log.e('$tag: Failed to put all data in entity $entityId: $retryError');
        Log.warning(
          'pulse_db_write_failed',
          '$tag: failed to store batch data in Hive entity',
          {
            'entityId': entityId,
            'entryCount': entries.length,
            'error': retryError.toString(),
            'firstError': e.toString(),
          },
        );
        throw DatabaseException('Failed to store batch data in entity: $entityId', originalError: retryError);
      }
    }
  }

  @override
  Future<void> deleteAll<T extends DatabaseModel>({required String entityId, required Iterable<String> keys}) async {
    try {
      _validateEntityExists<T>(entityId);

      final keysList = keys.toList();
      if (keysList.isEmpty) {
        return;
      }

      await hive.box<T>(entityId).deleteAll(keysList);
    } catch (e) {
      Log.e('$tag: Failed to delete items from entity $entityId: $e');
      throw DatabaseException('Failed to delete items from entity: $entityId', originalError: e);
    }
  }

  // Private validation methods
  void _validateEntityExists<T extends DatabaseModel>(String entityId) {
    if (!hive.isBoxOpen(entityId)) {
      throw DatabaseException('Entity not initialized: $entityId');
    }
  }
}
