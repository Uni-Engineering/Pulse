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

import 'package:uni_pulse_events_sdk/src/config/pulse_events_sdk_config.dart';

import '../interfaces/events_service.dart';
import '../interfaces/event_context.dart';
import '../interfaces/warning_callback.dart';
import '../exceptions/pulse_events_exceptions.dart';
import '../services/frequency_sync_event_service/frequency_sync_event_service.dart';
import '../services/utils/event_validator.dart';
import '../services/log/log.dart';
import 'package:get_it/get_it.dart';

final getIt = GetIt.I;

class PulseEventsSdk {
  static const String tag = 'PulseEventsSdk';

  /// Callback for reporting critical errors to external monitoring systems (e.g., Sentry)
  static Function(String message, dynamic error, StackTrace? stackTrace)? onCriticalError;

  /// Callback for non-fatal SDK reliability warnings.
  static PulseEventsWarningCallback? get onWarning => Log.onWarning;
  static set onWarning(PulseEventsWarningCallback? callback) => Log.onWarning = callback;

  /// Reports critical errors to both internal logging and external monitoring
  static void reportCriticalError(String message, dynamic error, [StackTrace? stackTrace]) {
    Log.e(message, error, stackTrace);
    onCriticalError?.call(message, error, stackTrace ?? StackTrace.current);
  }

  /// Reports non-fatal SDK reliability warnings.
  static void reportWarning(
    String code,
    String message, [
    Map<String, dynamic>? details,
  ]) {
    Log.warning(code, message, details);
  }

  final EventContext _eventContext;
  final String _appId;
  final IEventsService _eventService;

  bool _isInitialized = false;
  bool _isDisposed = false;

  PulseEventsSdk({
    required String appId,
    required EventContext eventContext,
  })  : _appId = appId,
        _eventContext = eventContext,
        _eventService = FrequencySyncEventService() {
    _validateConstructorParameters();
  }

  /// Gets the current event context
  EventContext get eventContext => _eventContext;

  /// Gets the app ID
  String get appId => _appId;

  /// Checks if the SDK is initialized
  bool get isInitialized => _isInitialized;

  /// Checks if the SDK is disposed
  bool get isDisposed => _isDisposed;

  Future<bool> init({
    required String baseUrl,
    required String configUrlEndpoint,
    required PulseEventsSdkConfig config,
    bool debugMode = false,
  }) async {
    if (_isDisposed) {
      throw InvalidConfiguration('Cannot initialize disposed SDK instance');
    }

    if (_isInitialized) {
      Log.i('$tag: SDK already initialized, skipping initialization');
      return true;
    }

    try {
      Log.i('$tag: Initializing Pulse Events SDK...');

      // Validate initialization parameters
      _validateInitParameters(baseUrl, configUrlEndpoint, config);

      // Prepare logging
      Log.debugMode = debugMode;

      // Register latest configuration.
      if (getIt.isRegistered<PulseEventsSdkConfig>()) {
        await getIt.unregister<PulseEventsSdkConfig>();
      }
      getIt.registerSingleton<PulseEventsSdkConfig>(config);

      // Initialize event service
      final success = await _eventService.init(
        eventContext: _eventContext,
        appId: _appId,
        baseUrl: baseUrl,
        configUrl: configUrlEndpoint,
        debugMode: debugMode,
      );

      if (success) {
        _isInitialized = true;
        Log.i('$tag: SDK initialized successfully');
      } else {
        reportWarning(
          'pulse_no_publish_endpoint',
          '$tag: SDK initialization returned false',
          {
            'baseUrl': baseUrl,
            'configUrlEndpoint': configUrlEndpoint,
          },
        );
      }

      return success;
    } catch (e) {
      Log.e('$tag: SDK initialization failed with error: $e');
      throw InvalidConfiguration('Failed to initialize SDK: $e');
    }
  }

  void setUserId(String userId) {
    _ensureInitialized();
    _validateUserId(userId);

    try {
      _eventService.setUserId(userId: userId);
      Log.i('$tag: User ID set successfully');
    } catch (e) {
      Log.e('$tag: Failed to set user ID: $e');
      throw InvalidConfiguration('Failed to set user ID: $e');
    }
  }

  void refreshEventContext(EventContext eventContext) {
    _ensureInitialized();

    try {
      // The EventContext constructor will validate the new context
      _eventService.refreshEventContext(eventContext);
      Log.i('$tag: Event context refreshed successfully');
    } catch (e) {
      Log.e('$tag: Failed to refresh event context: $e');
      rethrow;
    }
  }

  void trackEvent({
    required String eventName,
    required Map<String, dynamic> payload,
    int priority = 1,
  }) {
    _ensureInitialized();

    try {
      // Validate event parameters
      EventValidator.validateEventName(eventName);
      EventValidator.validatePayload(payload);

      // Track the event
      _eventService.trackEvent(
        eventName: eventName,
        payload: payload,
        priority: priority,
      );

      Log.i('$tag: Event "$eventName" tracked successfully with priority $priority');
    } catch (e) {
      Log.e('$tag: Failed to track event "$eventName": $e');

      // For validation errors, rethrow to inform the caller
      if (e is InvalidEventPayload || e is ValidationException) {
        rethrow;
      }

      // For other errors, wrap in a more generic exception
      throw InvalidEventPayload('Failed to track event: $e');
    }
  }

  /// Tracks an event with automatic payload sanitization
  void trackEventSafe({
    required String eventName,
    required Map<String, dynamic> payload,
    int priority = 1,
  }) {
    _ensureInitialized();

    try {
      // Validate and sanitize event parameters
      EventValidator.validateEventName(eventName);

      if (payload.isEmpty) {
        Log.i('$tag: Event "$eventName" payload was empty after sanitization, skipping');
        return;
      }

      // Track the event with sanitized payload
      _eventService.trackEvent(
        eventName: eventName,
        payload: payload,
        priority: priority,
      );

      Log.i('$tag: Event "$eventName" tracked safely with priority $priority');
    } catch (e) {
      Log.e('$tag: Failed to track event safely "$eventName": $e');

      // For validation errors on event name or priority, still rethrow
      if (e is InvalidEventPayload && (e.message.contains('Event name') || e.message.contains('priority'))) {
        rethrow;
      }

      // For payload issues, log but don't throw (safe mode)
      Log.i('$tag: Event "$eventName" was not tracked due to payload issues');
    }
  }

  void logout() {
    _ensureInitialized();

    try {
      _eventService.logout();
      Log.i('$tag: User logged out successfully');
    } catch (e) {
      Log.e('$tag: Failed to logout: $e');
      // Don't throw on logout errors, just log them
    }
  }

  /// Gets SDK statistics and health information
  Map<String, dynamic> getStats() {
    return {
      'appId': _appId,
      'isInitialized': _isInitialized,
      'isDisposed': _isDisposed,
      'eventContextValid': _eventContext.toString(),
    };
  }

  /// Disposes the SDK and cleans up resources
  Future<void> dispose() async {
    if (_isDisposed) {
      Log.i('$tag: SDK already disposed');
      return;
    }

    Log.i('$tag: Disposing SDK...');

    try {
      // Clean up GetIt registrations if we're the last instance
      if (getIt.isRegistered<PulseEventsSdkConfig>()) {
        try {
          getIt.unregister<PulseEventsSdkConfig>();
        } catch (e) {
          Log.e('$tag: Failed to unregister config: $e');
        }
      }

      _isDisposed = true;
      _isInitialized = false;

      Log.i('$tag: SDK disposed successfully');
    } catch (e) {
      Log.e('$tag: Error during SDK disposal: $e');
      throw ResourceException('Failed to dispose SDK properly', originalError: e);
    }
  }

  /// Validates constructor parameters - only check null/empty
  void _validateConstructorParameters() {
    if (_appId.isEmpty) {
      throw InvalidConfiguration('App ID cannot be empty');
    }
  }

  /// Validates initialization parameters - only check null/empty
  void _validateInitParameters(String baseUrl, String configUrlEndpoint, PulseEventsSdkConfig config) {
    if (baseUrl.isEmpty) {
      throw InvalidConfiguration('Base URL cannot be empty');
    }

    if (configUrlEndpoint.isEmpty) {
      throw InvalidConfiguration('Config URL endpoint cannot be empty');
    }
  }

  /// Validates user ID - only check null/empty
  void _validateUserId(String userId) {
    if (userId.isEmpty) {
      throw ValidationException('User ID cannot be empty', 'userId', userId);
    }
  }

  /// Ensures the SDK is initialized before operations
  void _ensureInitialized() {
    if (_isDisposed) {
      throw NotReady('SDK has been disposed');
    }

    if (!_isInitialized) {
      throw NotReady('SDK is not initialized. Call init() first.');
    }
  }
}
