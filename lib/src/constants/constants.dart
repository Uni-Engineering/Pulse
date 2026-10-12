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

import 'package:flutter/foundation.dart';

class Constants {
  Constants._();
  static const sdkVersion = '1.2.0';
  static const coreDbEntityId = "core-db";
  static const coreDbEntitySdkConfigKey = "sdkConfig";
  static const dbFlushDuration = Duration(seconds: 2);
}

class EventKeyConstants {
  EventKeyConstants._();

  static const eventTime = 'eventTime';
  static const eventPriority = 'eventPriority';
  static const eventSdkVersion = 'eventSdkVersion';
}

class BackgroundTaskConstants {
  BackgroundTaskConstants._();

  static const taskIdentifier = 'pulse-events-sdk-bg-task';
  static const taskName = 'Events Sync Task';
  static const taskTag = 'Events Sync Task';

  static const initialDelay = !kReleaseMode ? Duration(minutes: 10) : Duration(minutes: 30);
  static const backOffPolicyDelay = !kReleaseMode ? Duration(minutes: 1) : Duration(minutes: 10);

  static const databaseIdKey = 'databaseId';
  static const baseUrlKey = 'baseUrl';
  static const eventPublishEndpointKey = 'eventPublishEndpoint';
  static const appAuthTokenKey = 'appAuthToken';
  static const deviceIdKey = 'deviceId';
  static const sessionIdKey = 'sessionId';
  static const debugMode = 'debugMode';
  static const appType = 'appType';

  // Config keys - used to pass runtime SDK config to background isolate
  static const cfgLargestBatchSize = 'cfgLargestBatchSize';
  static const cfgEventSyncNetworkTimeoutMs = 'cfgEventSyncNetworkTimeoutMs';
  static const cfgSyncRetryDelayDurationMs = 'cfgSyncRetryDelayDurationMs';
  static const cfgWorkerRetryPeriodMs = 'cfgWorkerRetryPeriodMs';

  static const debugBackgroundTaskEventName = 'BackgroundTaskTriggered';

  static const eventPayloadOS = 'platform.operatingSystem';
  static const eventPayloadOSVersion = 'platform.operatingSystemVersion';
}
