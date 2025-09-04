import 'dart:async';
import 'dart:convert';
import 'package:eventsource/eventsource.dart' show Event, EventSource;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
// Use stub by default; on web replace with real interop.
import 'web_gun_client_stub.dart' if (dart.library.html) 'web_gun_client.dart';

class GunRelayClient {
  String host;
  int port;
  String get base => 'http://$host:$port';
  GunRelayClient({this.host = '127.0.0.1', this.port = 8765});
  WebGunClient? _web; // for web interop

  Future<String?> createSpace() async {
    if (kIsWeb) {
      try {
        _web ??= WebGunClient(host: host, port: port);
        return await _web!.createSpace();
      } catch (e) {
        // ignore: avoid_print
        print('[GunRelayClient] web createSpace error: $e');
        return null;
      }
    }
    try {
      final r = await http.post(Uri.parse('$base/spaces')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        return j['id'] as String?;
      }
      // ignore: avoid_print
      print('[GunRelayClient] createSpace failed: ${r.statusCode} ${r.body}');
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('[GunRelayClient] createSpace error: $e');
      return null;
    }
  }

  Future<bool> joinSpace(String spaceId) async {
    if (kIsWeb) {
      try {
        _web ??= WebGunClient(host: host, port: port);
        return await _web!.joinSpace(spaceId);
      } catch (e) {
        // ignore: avoid_print
        print('[GunRelayClient] web joinSpace error: $e');
        return false;
      }
    }
    try {
      final r = await http.post(Uri.parse('$base/spaces/$spaceId/join')).timeout(const Duration(seconds: 5));
      final ok = r.statusCode == 200;
      if (!ok) {
        // ignore: avoid_print
        print('[GunRelayClient] joinSpace failed: ${r.statusCode} ${r.body}');
      }
      return ok;
    } catch (e) {
      // ignore: avoid_print
      print('[GunRelayClient] joinSpace error: $e');
      return false;
    }
  }

  Future<bool> postEvent(String spaceId, Map<String, dynamic> ev) async {
    if (kIsWeb) {
      try {
        _web ??= WebGunClient(host: host, port: port);
        return await _web!.postEvent(spaceId, ev);
      } catch (e) {
        // ignore: avoid_print
        print('[GunRelayClient] web postEvent error: $e');
        return false;
      }
    }
    try {
      final r = await http
          .post(Uri.parse('$base/spaces/$spaceId/event'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(ev))
          .timeout(const Duration(seconds: 5));
      final ok = r.statusCode == 200;
      if (!ok) {
        // ignore: avoid_print
        print('[GunRelayClient] postEvent failed: ${r.statusCode} ${r.body}');
      }
      return ok;
    } catch (e) {
      // ignore: avoid_print
      print('[GunRelayClient] postEvent error: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> snapshot(String spaceId) async {
    if (kIsWeb) {
      try {
        _web ??= WebGunClient(host: host, port: port);
        return await _web!.snapshot(spaceId);
      } catch (e) {
        // ignore: avoid_print
        print('[GunRelayClient] web snapshot error: $e');
        return [];
      }
    }
    try {
      final r = await http.get(Uri.parse('$base/spaces/$spaceId/snapshot')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final moves = (j['moves'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        return moves;
      }
      // ignore: avoid_print
      print('[GunRelayClient] snapshot failed: ${r.statusCode} ${r.body}');
      return [];
    } catch (e) {
      // ignore: avoid_print
      print('[GunRelayClient] snapshot error: $e');
      return [];
    }
  }

  Future<Stream<Event>> stream(String spaceId) async {
    if (kIsWeb) {
      try {
        _web ??= WebGunClient(host: host, port: port);
        return await _web!.stream(spaceId);
      } catch (e) {
        // ignore: avoid_print
        print('[GunRelayClient] web stream error: $e');
        // Return a closed stream with an error
        final c = StreamController<Event>();
        c.addError(e);
        await c.close();
        return c.stream;
      }
    }
    // EventSource itself is a Stream<Event>, so return it directly.
    return await EventSource.connect('$base/spaces/$spaceId/stream');
  }

  Future<List<Map<String, dynamic>>> listSpaces() async {
    if (kIsWeb) {
      try {
        _web ??= WebGunClient(host: host, port: port);
        return await _web!.listSpaces();
      } catch (e) {
        // ignore: avoid_print
        print('[GunRelayClient] web listSpaces error: $e');
        return [];
      }
    }
    try {
      final r = await http.get(Uri.parse('$base/spaces')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final arr = (j['spaces'] as List<dynamic>? ?? [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        return arr;
      }
      // ignore: avoid_print
      print('[GunRelayClient] listSpaces failed: ${r.statusCode} ${r.body}');
      return [];
    } catch (e) {
      // ignore: avoid_print
      print('[GunRelayClient] listSpaces error: $e');
      return [];
    }
  }
}
