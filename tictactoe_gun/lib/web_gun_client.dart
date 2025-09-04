// Web-only: GUN.js interop and EventSource-like stream shim
// Usage: called from gun_client.dart when kIsWeb is true.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html; // only on web
import 'dart:js_util' as jsu;
import 'package:eventsource/eventsource.dart' show Event; // reuse Event type for compatibility

class _WebGun {
  dynamic gun; // JS Gun instance
  final List<String> peers;
  _WebGun(this.peers) {
    final gunCtor = jsu.getProperty(html.window, 'Gun');
    if (gunCtor != null) {
      gun = jsu.callConstructor(gunCtor, [jsu.jsify({'peers': peers})]);
    } else {
      gun = null;
    }
  }

  dynamic _spaces() => jsu.callMethod(gun, 'get', ['spaces']);

  Future<String> createSpace() async {
    if (gun == null) throw StateError('Gun not available on web');
    final id = 'space_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final spaceMeta = jsu.callMethod(jsu.callMethod(_spaces(), 'get', [id]), 'get', ['meta']);
    jsu.callMethod(spaceMeta, 'put', [jsu.jsify({'createdAt': DateTime.now().millisecondsSinceEpoch})]);
    return id;
  }

  Future<bool> joinSpace(String id) async {
    if (gun == null) throw StateError('Gun not available on web');
    // Nothing to do for join in pure GUN; presence is optional.
    return true;
  }

  Future<bool> postEvent(String spaceId, Map<String, dynamic> ev) async {
    if (gun == null) throw StateError('Gun not available on web');
    final spaceMoves = jsu.callMethod(jsu.callMethod(_spaces(), 'get', [spaceId]), 'get', ['moves']);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = ev['_id']?.toString() ?? 'e_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final envelope = {
      '_id': id,
      '_ts': now,
      'payload': jsonEncode(ev),
    };
    jsu.callMethod(spaceMoves, 'set', [jsu.jsify(envelope)]);
    return true;
  }

  Future<List<Map<String, dynamic>>> snapshot(String spaceId) async {
    if (gun == null) throw StateError('Gun not available on web');
    final completer = Completer<List<Map<String, dynamic>>>();
    final result = <Map<String, dynamic>>[];
    final spaceMoves = jsu.callMethod(jsu.callMethod(_spaces(), 'get', [spaceId]), 'get', ['moves']);
    // Once will call each existing node exactly once.
    jsu.callMethod(jsu.callMethod(spaceMoves, 'map', []), 'once', [jsu.allowInterop((dynamic data, [dynamic key]) {
      if (data != null) {
        try {
          result.add(Map<String, dynamic>.from(jsu.dartify(data) as Map));
        } catch (_) {}
      }
    })]);
    // Complete after a short delay to collect entries.
    Future.delayed(const Duration(milliseconds: 250), () => completer.complete(result));
    return completer.future;
  }

  // Produces a Stream<Event> similar to package:eventsource; data contains JSON string
  Future<Stream<Event>> stream(String spaceId) async {
    if (gun == null) throw StateError('Gun not available on web');
    final controller = StreamController<Event>.broadcast();
    // Send a hello event
    controller.add(Event.message(data: jsonEncode({'type': 'hello', 'spaceId': spaceId, 'now': DateTime.now().millisecondsSinceEpoch})));

    final spaceMoves = jsu.callMethod(jsu.callMethod(_spaces(), 'get', [spaceId]), 'get', ['moves']);
    final seen = <String>{};
    final onRef = jsu.callMethod(
      jsu.callMethod(spaceMoves, 'map', []),
      'on',
      [
        jsu.allowInterop((dynamic data, dynamic key, dynamic at, dynamic ev) {
          if (data == null) return;
          try {
            final raw = Map<String, dynamic>.from(jsu.dartify(data) as Map);
            final k = '${raw['_id']}:${raw['_ts']}';
            if (raw['_id'] != null && !seen.contains(k)) {
              seen.add(k);
              Map<String, dynamic> evMap;
              final p = raw['payload'];
              if (p is String) {
                evMap = Map<String, dynamic>.from(jsonDecode(p) as Map);
              } else {
                // fallback: try to pass-through existing shape
                evMap = raw;
              }
              controller.add(Event.message(data: jsonEncode({'type': 'event', 'event': evMap})));
            }
          } catch (_) {}
        })
      ],
    );

    // Local heartbeat to keep client watchdog happy
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      controller.add(Event.message(data: jsonEncode({'type': 'heartbeat', 'now': DateTime.now().millisecondsSinceEpoch})));
    });

    controller.onCancel = () {
      heartbeat.cancel();
      try { jsu.callMethod(spaceMoves, 'off', []); } catch (_) {}
      try { jsu.callMethod(onRef, 'off', []); } catch (_) {}
    };
    return controller.stream;
  }
}

// Note: by storing JSON in 'payload', we avoid GUN graphizing nested objects/arrays.

class WebGunClient {
  final String host;
  final int port;
  late final _WebGun _gun;
  WebGunClient({this.host = '127.0.0.1', this.port = 8765}) {
    final peers = ['http://$host:$port/gun'];
    _gun = _WebGun(peers);
  }
  Future<String> createSpace() => _gun.createSpace();
  Future<bool> joinSpace(String id) => _gun.joinSpace(id);
  Future<bool> postEvent(String id, Map<String, dynamic> ev) => _gun.postEvent(id, ev);
  Future<List<Map<String, dynamic>>> snapshot(String id) => _gun.snapshot(id);
  Future<Stream<Event>> stream(String id) => _gun.stream(id);
  Future<List<Map<String, dynamic>>> listSpaces() async {
    if (_gun.gun == null) throw StateError('Gun not available on web');
    final completer = Completer<List<Map<String, dynamic>>>();
    final out = <Map<String, dynamic>>[];
    final spaces = jsu.callMethod(_gun.gun, 'get', ['spaces']);
    jsu.callMethod(jsu.callMethod(spaces, 'map', []), 'once', [jsu.allowInterop((dynamic data, dynamic key) {
      if (key is String && key.startsWith('space_')) {
        out.add({'id': key});
      }
    })]);
    Future.delayed(const Duration(milliseconds: 250), () => completer.complete(out));
    return completer.future;
  }
}
