import 'dart:convert';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'config.dart';

class Session {
  final _auth = const FlutterAppAuth();
  final _storage = const FlutterSecureStorage();
  String? _access, _refresh, _id;
  DateTime _expires = DateTime(1970);
  Future<String>? _refreshing;

  Future<bool> restore() async {
    final saved = await _storage.read(key: 'session');
    if (saved == null) return false;
    final data = jsonDecode(saved) as Map<String, dynamic>;
    _refresh = data['refresh'];
    _id = data['id'];
    await accessToken();
    return true;
  }

  Future<void> login() async {
    final result = await _auth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        mobileClientId,
        redirectUrl,
        issuer: issuer,
        scopes: ['openid', 'profile'],
        allowInsecureConnections: issuer.startsWith('http:'),
      ),
    );
    await _save(
      result.accessToken,
      result.refreshToken,
      result.idToken,
      result.accessTokenExpirationDateTime,
    );
  }

  Future<void> _save(
    String? access,
    String? refresh,
    String? id,
    DateTime? expires,
  ) async {
    if (access == null) throw Exception('Не удалось получить токен');
    _access = access;
    _refresh = refresh ?? _refresh;
    _id = id ?? _id;
    _expires = expires ?? DateTime.now().add(const Duration(seconds: 60));
    await _storage.write(
      key: 'session',
      value: jsonEncode({'refresh': _refresh, 'id': _id}),
    );
  }

  Future<String> accessToken() async {
    if (_access != null &&
        _expires.isAfter(DateTime.now().add(const Duration(seconds: 30))))
      return _access!;
    if (_refresh == null) throw Exception('Войдите в систему');
    if (_refreshing != null) return _refreshing!;
    _refreshing = _renew();
    try {
      return await _refreshing!;
    } finally {
      _refreshing = null;
    }
  }

  Future<String> _renew() async {
    final result = await _auth.token(
      TokenRequest(
        mobileClientId,
        redirectUrl,
        issuer: issuer,
        refreshToken: _refresh,
        allowInsecureConnections: issuer.startsWith('http:'),
        scopes: ['openid', 'profile'],
      ),
    );
    await _save(
      result.accessToken,
      result.refreshToken,
      result.idToken,
      result.accessTokenExpirationDateTime,
    );
    return _access!;
  }

  Future<void> logout() async {
    final id = _id;
    _access = _refresh = _id = null;
    await _storage.delete(key: 'session');
    if (id != null) {
      await _auth.endSession(
        EndSessionRequest(
          issuer: issuer,
          idTokenHint: id,
          postLogoutRedirectUrl: redirectUrl,
          allowInsecureConnections: issuer.startsWith('http:'),
        ),
      );
    }
  }
}
