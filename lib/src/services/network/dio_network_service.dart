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

import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:pulse_plus_events_sdk/pulse_plus_events_sdk.dart';
import 'package:pulse_plus_events_sdk/src/constants/constants.dart';

import '../interfaces/network_service.dart';
import '../log/log.dart';

typedef DioNetworkServiceType = INetworkService<dio.Response?>;

class DioNetworkService implements DioNetworkServiceType {
  static const tag = 'DioNetworkService';

  final String appType;
  final String baseUrl;
  final EventContext eventContext;
  final dio.Dio _dio;

  DioNetworkService({
    required this.appType,
    required this.baseUrl,
    required this.eventContext,
  }) : _dio = dio.Dio()
          ..options = dio.BaseOptions(
            validateStatus: (statusCode) {
              if (statusCode == null) return false;
              return (200 <= statusCode && statusCode < 300) || statusCode == HttpStatus.unauthorized;
            },
          )
          ..interceptors.add(
            _Interceptor(
              eventContext: eventContext,
              appType: appType,
            ),
          );

  @override
  bool get hasAuthToken => eventContext.appAuthToken != null;

  @override
  Future<dio.Response?> get(String endpoint) async {
    Log.i('$tag: get(...) request with endpoint: $endpoint');

    try {
      if (endpoint.isEmpty) {
        throw NetworkException('Endpoint cannot be empty');
      }

      final response = await _dio.get('$baseUrl$endpoint');

      Log.i('$tag: get(...) at endpoint: $endpoint returned response: $response');

      return response;
    } on dio.DioException catch (error) {
      return _handleDioException('GET', endpoint, error);
    } catch (e) {
      Log.e('$tag: Unexpected error during GET $endpoint: $e');
      throw NetworkException('Network error', originalError: e);
    }
  }

  @override
  Future<dio.Response?> post(
    String endpoint,
    Map<String, dynamic> body, {
    dio.CancelToken? cancelToken,
  }) async {
    Log.i('$tag: POST request to endpoint: $endpoint');

    try {
      // Validate authentication
      if (eventContext.appAuthToken == null) {
        return null;
      }

      if (endpoint.isEmpty) {
        throw NetworkException('Endpoint cannot be empty');
      }

      if (body.isEmpty) {
        throw NetworkException('Request body cannot be empty');
      }

      final response = await _dio.post(
        '$baseUrl$endpoint',
        data: body,
        cancelToken: cancelToken,
      );

      Log.i('$tag: POST $endpoint completed - Status: ${response.statusCode}');
      return response;
    } on dio.DioException catch (error) {
      return _handleDioException('POST', endpoint, error);
    } catch (e) {
      Log.e('$tag: Unexpected error during POST $endpoint: $e');
      throw NetworkException('Network error', originalError: e);
    }
  }

  /// Handles Dio exceptions with basic error mapping
  dio.Response? _handleDioException(String method, String endpoint, dio.DioException error) {
    Log.e('$tag: $method $endpoint failed: ${error.message}');

    // Return the response for further processing if available
    if (error.response != null) {
      return error.response;
    }

    // For connection issues, throw network exception
    switch (error.type) {
      case dio.DioExceptionType.connectionTimeout:
      case dio.DioExceptionType.sendTimeout:
      case dio.DioExceptionType.receiveTimeout:
        throw NetworkException('Request timeout', originalError: error);

      case dio.DioExceptionType.connectionError:
        throw NetworkException('Connection error', originalError: error);

      default:
        throw NetworkException('Network error: ${error.message}', originalError: error);
    }
  }

  /// Disposes resources
  void dispose() {
    try {
      _dio.close();
      Log.i('$tag: Network service disposed');
    } catch (e) {
      Log.e('$tag: Error disposing network service: $e');
    }
  }
}

class _Interceptor extends dio.Interceptor {
  final EventContext eventContext;
  final String appType;

  _Interceptor({
    required this.eventContext,
    required this.appType,
  });

  @override
  void onRequest(dio.RequestOptions options, dio.RequestInterceptorHandler handler) {
    final userAgent = '$appType PulseEventsSdk/${Constants.sdkVersion}($_osType; deviceId=${eventContext.deviceId})';
    final sdkConfig = getIt<PulseEventsSdkConfig>();

    options.headers.addAll({
      'Content-Type': 'application/json',
      'os-type': _osType,
      'appType': appType,
      'User-Agent': userAgent,
      'device-id': eventContext.deviceId,
      'session-id': eventContext.sessionId,
      'Authorization': eventContext.appAuthToken,
    });

    if (eventContext.networkHeaders != null) {
      options.headers.addAll(eventContext.networkHeaders!);
    }
    sdkConfig.onNetworkIntercept?.call(options, handler);

    super.onRequest(options, handler);
  }

  String get _osType => (Platform.isIOS ? 'iOS' : 'Android').toUpperCase();
}
