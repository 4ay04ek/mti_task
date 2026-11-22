import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'session.dart';

class Api {
  Api(this.session);
  final Session session;

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.parse('$apiUrl$path')
        .replace(queryParameters: query?.isEmpty == true ? null : query);
    final request = http.Request(method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer ${await session.accessToken()}',
        'Content-Type': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(seconds: 45)),
    );
    if (response.statusCode >= 400) {
      var message = 'Ошибка запроса (${response.statusCode})';
      try {
        final detail =
            (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['detail'];
        if (detail is String) message = detail;
      } catch (_) {}
      throw Exception(message);
    }
    return response;
  }

  Future<dynamic> get(String path, [Map<String, String>? query]) async =>
      jsonDecode(
        utf8.decode((await _request('GET', path, query: query)).bodyBytes),
      );
  Future<dynamic> post(String path, Object body) async => jsonDecode(
    utf8.decode((await _request('POST', path, body: body)).bodyBytes),
  );
  Future<dynamic> patch(String path, Object body) async => jsonDecode(
    utf8.decode((await _request('PATCH', path, body: body)).bodyBytes),
  );
  Future<Uint8List> csv(Map<String, String> query) async =>
      (await _request('GET', '/api/tickets/export', query: query)).bodyBytes;
}
