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

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class PulseEventsSdkConfig {
  final String? fallbackEventPublishEndpoint;

  final int defaultEventPriority;
  final String logSourceName;
  final Duration eventSyncNetworkTimeout;
  final int largestBatchSize;
  final Duration workerRetryPeriod;

  final Duration syncRetryDelayDuration;
  final int syncMaxRetry = 5;
  final int configFetchMaxRetries;
  final Duration configFetchRetryDelay;
  final int maxDbSizeInMb;
  final bool shouldUseLocalConfigAsFallback;
  final void Function(RequestOptions options, RequestInterceptorHandler handler)? onNetworkIntercept;

  PulseEventsSdkConfig({
    this.fallbackEventPublishEndpoint,
    this.defaultEventPriority = 1,
    this.logSourceName = "PulseSDK",
    this.eventSyncNetworkTimeout = const Duration(seconds: 10),
    this.largestBatchSize = 100,
    this.workerRetryPeriod = const Duration(seconds: 10),
    this.syncRetryDelayDuration = !kReleaseMode
        ? const Duration(seconds: 5)
        : const Duration(seconds: 10),
    this.configFetchMaxRetries = 3,
    this.configFetchRetryDelay = const Duration(seconds: 2),
    this.maxDbSizeInMb = 10,
    this.shouldUseLocalConfigAsFallback = true,
    this.onNetworkIntercept,
  });
}
