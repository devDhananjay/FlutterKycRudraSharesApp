import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:meon_kyc/config/env_config.dart';

/// Global internet monitor — used by [AppConnectivityGate] across the app.
class ConnectivityController extends ChangeNotifier {
  ConnectivityController() {
    _connection = InternetConnection.createInstance(
      checkInterval: const Duration(seconds: 4),
      customCheckOptions: [
        InternetCheckOption(uri: Uri.parse(EnvConfig.baseUrl)),
        InternetCheckOption(uri: Uri.parse('https://www.google.com/generate_204')),
      ],
    );
  }

  late final InternetConnection _connection;
  StreamSubscription<InternetStatus>? _subscription;
  AppLifecycleListener? _lifecycleListener;

  bool _isConnected = true;
  bool _isChecking = true;
  bool _wasDisconnected = false;
  int _reconnectToken = 0;

  bool get isConnected => _isConnected;
  bool get isChecking => _isChecking;
  bool get showNoInternet => !_isChecking && !_isConnected;
  int get reconnectToken => _reconnectToken;

  Future<void> init() async {
    _isConnected = await _connection.hasInternetAccess;
    _isChecking = false;
    if (!_isConnected) _wasDisconnected = true;
    notifyListeners();
    _startListening();
    _lifecycleListener = AppLifecycleListener(
      onResume: _startListening,
      onPause: _stopListening,
    );
  }

  void _startListening() {
    _subscription?.cancel();
    _subscription = _connection.onStatusChange.listen(_onStatus);
  }

  void _stopListening() {
    _subscription?.cancel();
    _subscription = null;
  }

  void _onStatus(InternetStatus status) {
    final connected = status == InternetStatus.connected;
    if (_isConnected == connected) return;

    final wasOff = !_isConnected;
    _isConnected = connected;
    _isChecking = false;

    if (!connected) {
      _wasDisconnected = true;
    } else if (wasOff && connected) {
      _reconnectToken++;
      _wasDisconnected = false;
    }

    notifyListeners();
  }

  /// Manual retry from the no-internet screen.
  Future<void> recheck() async {
    _isChecking = true;
    notifyListeners();

    final connected = await _connection.hasInternetAccess;
    final wasOff = !_isConnected;
    _isConnected = connected;
    _isChecking = false;

    if (!connected) {
      _wasDisconnected = true;
    } else {
      if (wasOff || _wasDisconnected) {
        _reconnectToken++;
      }
      _wasDisconnected = false;
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _stopListening();
    _lifecycleListener?.dispose();
    super.dispose();
  }
}
