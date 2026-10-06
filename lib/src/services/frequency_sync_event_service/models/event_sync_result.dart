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

import '../../../db_models/event_data_model.dart';

enum EventSyncState { failed, succeeded, partial, halted }

class EventSyncResult {
  final List<EventDataModel> failed;
  final List<EventDataModel> succeeded;
  final EventSyncState state;

  EventSyncResult({
    this.succeeded = const [],
    this.failed = const [],
    required this.state,
  });

  int get succeededNo => succeeded.length;
  int get failedNo => failed.length;

  bool get hasAtleastOneSucceeded => succeededNo != 0;
  bool get hasAllSucceeded => state == EventSyncState.succeeded && failedNo == 0;

  bool get isSuccess => state == EventSyncState.succeeded && failed.isEmpty;
  bool get isHalted => state == EventSyncState.halted;

  factory EventSyncResult.success(List<EventDataModel> succeeded) {
    return EventSyncResult(succeeded: succeeded, state: EventSyncState.succeeded);
  }

  factory EventSyncResult.failed(List<EventDataModel> failed) {
    return EventSyncResult(failed: failed, state: EventSyncState.failed);
  }

  factory EventSyncResult.halted([List<EventDataModel> failed = const []]) {
    return EventSyncResult(failed: failed, state: EventSyncState.halted);
  }

  static EventSyncResult merge(List<EventSyncResult> results) {
    final succeeded = <EventDataModel>[];
    final failed = <EventDataModel>[];
    var hasHalted = false;

    for (final result in results) {
      succeeded.addAll(result.succeeded);
      failed.addAll(result.failed);
      hasHalted = hasHalted || result.isHalted;
    }

    return EventSyncResult(
      succeeded: succeeded,
      failed: failed,
      state: hasHalted
          ? EventSyncState.halted
          : failed.isEmpty
              ? EventSyncState.succeeded
              : succeeded.isEmpty
                  ? EventSyncState.failed
                  : EventSyncState.partial,
    );
  }

  @override
  String toString() {
    return 'EventSyncResult(succeeded: $succeededNo, failed: $failedNo)';
  }
}

class SingularEventSyncResult {
  final int priority;
  final bool isSyncSuccessful;

  SingularEventSyncResult({
    required this.priority,
    required this.isSyncSuccessful,
  });

  @override
  String toString() {
    return 'SingularEventSyncStatus(priority: $priority, isSyncSuccessful: $isSyncSuccessful)';
  }
}
