// Stub for non-web platforms so imports resolve.
// This should never be constructed when kIsWeb == false.

import 'package:eventsource/eventsource.dart' show Event;

class WebGunClient {
  WebGunClient({String host = '127.0.0.1', int port = 8765});
  Future<String> createSpace() async => throw UnsupportedError('WebGunClient is only available on web');
  Future<bool> joinSpace(String id) async => throw UnsupportedError('WebGunClient is only available on web');
  Future<bool> postEvent(String id, Map<String, dynamic> ev) async => throw UnsupportedError('WebGunClient is only available on web');
  Future<List<Map<String, dynamic>>> snapshot(String id) async => throw UnsupportedError('WebGunClient is only available on web');
  Future<Stream<Event>> stream(String id) async => throw UnsupportedError('WebGunClient is only available on web');
}

