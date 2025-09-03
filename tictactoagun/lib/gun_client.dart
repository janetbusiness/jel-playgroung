import 'dart:async';
import 'dart:convert';
import 'package:eventsource/eventsource.dart';
import 'package:http/http.dart' as http;

class GunRelayClient {
  String host;
  int port;
  String base;
  GunRelayClient({this.host = '127.0.0.1', this.port = 8765}) : base = 'http://$host:$port';

  Future<String?> createSpace() async {
    final r = await http.post(Uri.parse('$base/spaces'));
    if (r.statusCode == 200) {
      final j = jsonDecode(r.body);
      return j['id'] as String?;
    }
    return null;
  }

  Future<bool> joinSpace(String spaceId) async {
    final r = await http.post(Uri.parse('$base/spaces/$spaceId/join'));
    return r.statusCode == 200;
  }

  Future<bool> postEvent(String spaceId, Map<String, dynamic> ev) async {
    final r = await http.post(
      Uri.parse('$base/spaces/$spaceId/event'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(ev),
    );
    return r.statusCode == 200;
  }

  Future<List<Map<String, dynamic>>> snapshot(String spaceId) async {
    final r = await http.get(Uri.parse('$base/spaces/$spaceId/snapshot'));
    if (r.statusCode == 200) {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final moves = (j['moves'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      return moves;
    }
    return [];
  }

  Future<EventSource> stream(String spaceId) async {
    return await EventSource.connect('$base/spaces/$spaceId/stream');
  }
}

