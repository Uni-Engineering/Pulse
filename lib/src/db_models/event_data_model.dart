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

import 'package:hive_ce/hive_ce.dart';

import 'data_model.dart';

part 'event_data_model.g.dart';

@HiveType(typeId: 1)
enum EventStatus {
  @HiveField(0, defaultValue: true)
  pending,

  @HiveField(1)
  readyToSync,

  @HiveField(2)
  synced,

  @HiveField(3)
  failed,
}

@HiveType(typeId: 2)
class EventDataModel extends DatabaseModel {
  @HiveField(0)
  final String eventId;

  @HiveField(1)
  final String eventName;

  @HiveField(2)
  final Map<String, dynamic> payload;

  @HiveField(3)
  EventStatus status;

  EventDataModel({
    required this.eventId,
    required this.eventName,
    required this.payload,
    this.status = EventStatus.pending,
  });

  Map<String, dynamic> toJson() {
    return {
      'eventId': eventId,
      'eventName': eventName,
      'payload': payload,
    };
  }
}
