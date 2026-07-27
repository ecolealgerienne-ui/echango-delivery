import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import '../config/app_config.dart';
import '../models/order.dart';

class BFFClient {
  late final Dio _dio;
  final Logger _logger = Logger();
  String? _accessToken;

  BFFClient() {
    _dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.bffBaseUrl,
        connectTimeout: Duration(seconds: AppConfig.apiTimeout),
        receiveTimeout: Duration(seconds: AppConfig.apiTimeout),
        sendTimeout: Duration(seconds: AppConfig.apiTimeout),
      ),
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (_accessToken != null) {
            options.headers['Authorization'] = 'Bearer $_accessToken';
          }
          return handler.next(options);
        },
        onError: (error, handler) {
          _logger.e('API Error: $error');
          return handler.next(error);
        },
      ),
    );
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _dio.post(
        '/auth/login',
        data: {
          'email': email,
          'password': password,
        },
      );
      _accessToken = response.data['data']['access_token'];
      return response.data;
    } catch (e) {
      _logger.e('Login failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> loginWithPhone({
    required String phone,
  }) async {
    try {
      final response = await _dio.post(
        '/auth/login-phone',
        data: {
          'phone': phone,
        },
      );
      return response.data;
    } catch (e) {
      _logger.e('Phone login failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    try {
      final response = await _dio.post(
        '/auth/verify-otp',
        data: {
          'phone': phone,
          'otp': otp,
        },
      );
      _accessToken = response.data['data']['access_token'];
      return response.data;
    } catch (e) {
      _logger.e('OTP verification failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> refreshToken() async {
    try {
      final response = await _dio.post('/auth/refresh');
      _accessToken = response.data['data']['access_token'];
      return response.data;
    } catch (e) {
      _logger.e('Token refresh failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> logout() async {
    try {
      final response = await _dio.post('/auth/logout');
      _accessToken = null;
      return response.data;
    } catch (e) {
      _logger.e('Logout failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getDriver() async {
    try {
      final response = await _dio.get('/driver/profile');
      return response.data;
    } catch (e) {
      _logger.e('Get driver failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> updateDriverLocation({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final response = await _dio.put(
        '/driver/location',
        data: {
          'latitude': latitude,
          'longitude': longitude,
        },
      );
      return response.data;
    } catch (e) {
      _logger.e('Update location failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> updateDriverStatus(String status) async {
    try {
      final response = await _dio.put(
        '/driver/status',
        data: {
          'status': status, // online, offline, on_break
        },
      );
      return response.data;
    } catch (e) {
      _logger.e('Update status failed: $e');
      rethrow;
    }
  }

  Future<List<Order>> getOrders({
    String status = 'assigned',
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _dio.get(
        '/orders',
        queryParameters: {
          'status': status,
          'page': page,
          'limit': limit,
        },
      );
      final orders = (response.data['data'] as List)
          .map((order) => Order.fromJson(order as Map<String, dynamic>))
          .toList();
      return orders;
    } catch (e) {
      _logger.e('Get orders failed: $e');
      rethrow;
    }
  }

  Future<Order> getOrder(String orderId) async {
    try {
      final response = await _dio.get('/orders/$orderId');
      return Order.fromJson(response.data['data'] as Map<String, dynamic>);
    } catch (e) {
      _logger.e('Get order failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> acceptOrder(String orderId) async {
    try {
      final response = await _dio.put(
        '/orders/$orderId/accept',
      );
      return response.data;
    } catch (e) {
      _logger.e('Accept order failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> startOrder(String orderId) async {
    try {
      final response = await _dio.put(
        '/orders/$orderId/start',
      );
      return response.data;
    } catch (e) {
      _logger.e('Start order failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> completeOrder({
    required String orderId,
    required String proofUrl,
  }) async {
    try {
      final response = await _dio.put(
        '/orders/$orderId/complete',
        data: {
          'proof_url': proofUrl,
        },
      );
      return response.data;
    } catch (e) {
      _logger.e('Complete order failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> reportDeliveryFailure({
    required String orderId,
    required String reason,
    String? photoUrl,
    String? notes,
  }) async {
    try {
      final response = await _dio.put(
        '/orders/$orderId/failure',
        data: {
          'reason': reason,
          'photo_url': photoUrl,
          'notes': notes,
        },
      );
      return response.data;
    } catch (e) {
      _logger.e('Report delivery failure failed: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> uploadProof({
    required String orderId,
    required String filePath,
  }) async {
    try {
      final formData = FormData.fromMap({
        'proof': await MultipartFile.fromFile(filePath),
      });
      final response = await _dio.post(
        '/orders/$orderId/proof',
        data: formData,
      );
      return response.data;
    } catch (e) {
      _logger.e('Upload proof failed: $e');
      rethrow;
    }
  }

  void setAccessToken(String token) {
    _accessToken = token;
  }

  String? getAccessToken() => _accessToken;

  bool isAuthenticated() => _accessToken != null;
}
