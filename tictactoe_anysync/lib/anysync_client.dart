import 'dart:convert';
import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'ffi/anysync_bindings.dart';

class AnySyncClient {
  static AnySyncClient? _instance;
  static void Function(TicTacToeEvent)? _eventHandler;

  bool _initialized = false;
  String? _currentSpaceId;
  Timer? _pollTimer;

  static AnySyncClient get instance {
    _instance ??= AnySyncClient._();
    return _instance!;
  }

  AnySyncClient._();

  Future<bool> initialize({
    String nodeHost = 'localhost',
    int nodePort = 8080,
    String networkId = 'tictactoe-network',
  }) async {
    final hostPtr = nodeHost.toNativeUtf8();
    final networkIdPtr = networkId.toNativeUtf8();
    try {
      final result = initializeClientNative(hostPtr, nodePort, networkIdPtr);
      _initialized = result == 1;
      return _initialized;
    } finally {
      malloc.free(hostPtr);
      malloc.free(networkIdPtr);
    }
  }

  Future<String?> createTicTacToeSpace() async {
    if (!_initialized) return null;
    final resultPtr = createSpaceNative();
    if (resultPtr == nullptr) return null;
    final spaceId = resultPtr.toDartString();
    freeStringNative(resultPtr);
    if (spaceId.trim().isEmpty) {
      return null;
    }
    _currentSpaceId = spaceId;
    return spaceId;
  }

  Future<bool> joinTicTacToeSpace(String spaceId) async {
    if (!_initialized) return false;
    final spaceIdPtr = spaceId.toNativeUtf8();
    try {
      final result = joinSpaceNative(spaceIdPtr);
      if (result == 1) {
        _currentSpaceId = spaceId;
        return true;
      }
      return false;
    } finally {
      malloc.free(spaceIdPtr);
    }
  }

  Future<bool> sendMove(TicTacToeMove move) async {
    if (!_initialized || _currentSpaceId == null) return false;
    final operationJson = jsonEncode(move.toJson());
    final spaceIdPtr = _currentSpaceId!.toNativeUtf8();
    final operationPtr = operationJson.toNativeUtf8();
    try {
      final result = sendOperationNative(spaceIdPtr, operationPtr);
      return result == 1;
    } finally {
      malloc.free(spaceIdPtr);
      malloc.free(operationPtr);
    }
  }

  Future<bool> sendReset({required String by, required int sessionId}) async {
    if (!_initialized || _currentSpaceId == null) return false;
    final payload = jsonEncode({
      'type': 'tictactoe_reset',
      'by': by,
      'sessionId': sessionId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    final spaceIdPtr = _currentSpaceId!.toNativeUtf8();
    final operationPtr = payload.toNativeUtf8();
    try {
      final result = sendOperationNative(spaceIdPtr, operationPtr);
      return result == 1;
    } finally {
      malloc.free(spaceIdPtr);
      malloc.free(operationPtr);
    }
  }

  Future<bool> sendPlayerRegister({
    required String playerId,
    required int timestamp,
    required String name,
    required String emoji,
  }) async {
    return _sendJson({
      'type': 'player_register',
      'playerId': playerId,
      'timestamp': timestamp,
      'name': name,
      'emoji': emoji,
    });
  }

  Future<bool> sendSnapshotRequest({required String requesterId}) async {
    return _sendJson({
      'type': 'snapshot_request',
      'requesterId': requesterId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<bool> sendSnapshotState({
    required List<String> players,
    required List<String> board,
    required String to,
    required Map<String, Map<String, String>> meta,
  }) async {
    return _sendJson({
      'type': 'snapshot_state',
      'players': players,
      'board': board,
      'to': to,
      'meta': meta,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<bool> _sendJson(Map<String, dynamic> payload) async {
    if (!_initialized || _currentSpaceId == null) return false;
    final spaceIdPtr = _currentSpaceId!.toNativeUtf8();
    final operationPtr = jsonEncode(payload).toNativeUtf8();
    try {
      final result = sendOperationNative(spaceIdPtr, operationPtr);
      return result == 1;
    } finally {
      malloc.free(spaceIdPtr);
      malloc.free(operationPtr);
    }
  }

  void startListening(void Function(TicTacToeEvent) onEvent) {
    if (!_initialized || _currentSpaceId == null) return;
    _eventHandler = onEvent;
    _pollTimer?.cancel();
    final spaceId = _currentSpaceId!;
    final spaceIdPtr = spaceId.toNativeUtf8();
    startListeningNative(spaceIdPtr);
    malloc.free(spaceIdPtr);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final sidPtr = spaceId.toNativeUtf8();
      final msgPtr = pollOperationNative(sidPtr);
      malloc.free(sidPtr);
      if (msgPtr == nullptr) return;
      try {
        final jsonString = msgPtr.toDartString();
        _handleOperationJson(jsonString);
      } finally {
        freeStringNative(msgPtr);
      }
    });
  }

  Future<AnySyncStatus> getStatus() async {
    final ptr = getStatusNative();
    if (ptr == nullptr) return AnySyncStatus.empty();
    try {
      final jsonStr = ptr.toDartString();
      final map = json.decode(jsonStr) as Map<String, dynamic>;
      return AnySyncStatus.fromJson(map);
    } catch (_) {
      return AnySyncStatus.empty();
    } finally {
      freeStringNative(ptr);
    }
  }

  static void _handleOperationJson(String jsonString) {
    try {
      final operationData = jsonDecode(jsonString) as Map<String, dynamic>;
      final type = operationData['type'] as String?;
      TicTacToeEvent? event;
      if (type == 'tictactoe_move') {
        event = TicTacToeEvent.move(TicTacToeMove.fromJson(operationData));
      } else if (type == 'tictactoe_reset') {
        event = TicTacToeEvent.reset(
          by: operationData['by'] as String?,
          sessionId: (operationData['sessionId'] as num?)?.toInt(),
        );
      } else if (type == 'player_register') {
        event = TicTacToeEvent.playerRegister(
          operationData['playerId'] as String?,
          name: operationData['name'] as String?,
          emoji: operationData['emoji'] as String?,
        );
      } else if (type == 'snapshot_request') {
        event = TicTacToeEvent.snapshotRequest(operationData['requesterId'] as String?);
      } else if (type == 'snapshot_state') {
        final players = (operationData['players'] as List<dynamic>?)?.cast<String>() ?? const [];
        final board = (operationData['board'] as List<dynamic>?)?.cast<String>() ?? const [];
        final to = operationData['to'] as String?;
        final metaRaw = (operationData['meta'] as Map?)?.cast<String, dynamic>();
        final Map<String, Map<String, String>> meta = {};
        if (metaRaw != null) {
          for (final entry in metaRaw.entries) {
            final v = (entry.value as Map).cast<String, dynamic>();
            meta[entry.key] = {
              'name': (v['name'] ?? '').toString(),
              'emoji': (v['emoji'] ?? '').toString(),
            };
          }
        }
        final sessionId = (operationData['sessionId'] as num?)?.toInt();
        event = TicTacToeEvent.snapshotState(players: players, board: board, to: to, meta: meta, sessionId: sessionId);
      }
      final handler = _eventHandler;
      if (handler != null && event != null) {
        handler(event);
      }
    } catch (e) {
      // For debugging only; avoid spamming logs in production
      // ignore: avoid_print
      print('Error in operation callback: $e');
    }
  }
}

class AnySyncStatus {
  final String? spaceId;
  final int peerCount;
  final int lastSyncMs;
  final String? nodeHost;
  final int? nodePort;
  final String? networkId;
  final bool connected;

  AnySyncStatus({
    this.spaceId,
    required this.peerCount,
    required this.lastSyncMs,
    this.nodeHost,
    this.nodePort,
    this.networkId,
    required this.connected,
  });

  factory AnySyncStatus.empty() => AnySyncStatus(
        spaceId: null,
        peerCount: 0,
        lastSyncMs: 0,
        nodeHost: null,
        nodePort: null,
        networkId: null,
        connected: false,
      );

  factory AnySyncStatus.fromJson(Map<String, dynamic> j) => AnySyncStatus(
        spaceId: j['spaceId'] as String?,
        peerCount: (j['peerCount'] as num?)?.toInt() ?? 0,
        lastSyncMs: (j['lastSyncMs'] as num?)?.toInt() ?? 0,
        nodeHost: j['nodeHost'] as String?,
        nodePort: (j['nodePort'] as num?)?.toInt(),
        networkId: j['networkId'] as String?,
        connected: j['connected'] == true,
      );
}

class TicTacToeMove {
  final String id;
  final int position;
  final String playerId;
  final int timestamp;
  final int sessionId;

  TicTacToeMove({
    required this.id,
    required this.position,
    required this.playerId,
    required this.timestamp,
    required this.sessionId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'position': position,
        'playerId': playerId,
        'timestamp': timestamp,
        'sessionId': sessionId,
        'type': 'tictactoe_move',
      };

  static TicTacToeMove fromJson(Map<String, dynamic> json) {
    return TicTacToeMove(
      id: json['id'] as String,
      position: json['position'] as int,
      playerId: json['playerId'] as String,
      timestamp: json['timestamp'] as int,
      sessionId: (json['sessionId'] as num?)?.toInt() ?? 1,
    );
  }
}

class TicTacToeEvent {
  final String type; // 'tictactoe_move' or 'tictactoe_reset'
  final TicTacToeMove? move;
  final String? by;
  final String? playerId;
  final String? requesterId;
  final List<String>? players;
  final List<String>? board;
  final String? to;
  final String? name;
  final String? emoji;
  final Map<String, Map<String, String>>? meta;
  final int? sessionId;

  TicTacToeEvent._(this.type, {this.move, this.by, this.playerId, this.requesterId, this.players, this.board, this.to, this.name, this.emoji, this.meta, this.sessionId});

  factory TicTacToeEvent.move(TicTacToeMove m) =>
      TicTacToeEvent._('tictactoe_move', move: m);
  factory TicTacToeEvent.reset({String? by, int? sessionId}) =>
      TicTacToeEvent._('tictactoe_reset', by: by, sessionId: sessionId);
  factory TicTacToeEvent.playerRegister(String? playerId, {String? name, String? emoji}) =>
      TicTacToeEvent._('player_register', playerId: playerId, name: name, emoji: emoji);
  factory TicTacToeEvent.snapshotRequest(String? requesterId) =>
      TicTacToeEvent._('snapshot_request', requesterId: requesterId);
  factory TicTacToeEvent.snapshotState({List<String>? players, List<String>? board, String? to, Map<String, Map<String, String>>? meta, int? sessionId}) =>
      TicTacToeEvent._('snapshot_state', players: players, board: board, to: to, meta: meta, sessionId: sessionId);
}
