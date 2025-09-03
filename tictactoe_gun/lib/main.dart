import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:eventsource/eventsource.dart';
import 'package:flutter/material.dart';
import 'gun_client.dart';

void main() => runApp(const TicTacToeGunApp());

class TicTacToeGunApp extends StatelessWidget {
  const TicTacToeGunApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'TicTacToe + GUN', theme: ThemeData(primarySwatch: Colors.blue), home: const GameScreen());
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final GunRelayClient _client = GunRelayClient();
  final SimpleTicTacToeCRDT _game = SimpleTicTacToeCRDT();
  bool _connected = false;
  String? _spaceId;
  String _host = '127.0.0.1';
  int _port = 8765;
  EventSource? _es;
  StreamSubscription<Message>? _sub;
  bool _closing = false;
  int _retryMs = 500;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _closing = true;
    _sub?.cancel();
    _es?.close();
    super.dispose();
  }

  Future<void> _initialize() async {
    _client.host = _host;
    _client.port = _port;
    final id = await _client.createSpace();
    if (id == null) return;
    _spaceId = id;
    await _connectStream();
    setState(() => _connected = true);
    await _announcePresenceAndRequestSnapshot();
  }

  Future<void> _connectStream() async {
    if (_spaceId == null) return;
    await _snapshotAndApply();
    await _startStream();
  }

  Future<void> _snapshotAndApply() async {
    final snaps = await _client.snapshot(_spaceId!);
    // Rebuild board from snapshot deterministically
    for (final e in snaps) {
      _handleEvent(e);
    }
  }

  Future<void> _startStream() async {
    _es?.close();
    _sub?.cancel();
    try {
      final es = await _client.stream(_spaceId!);
      _es = es;
      _retryMs = 500; // reset backoff
      _sub = es.listen((msg) {
        final data = msg.data;
        if (data == null) return;
        try {
          final map = jsonDecode(data) as Map<String, dynamic>;
          if (map['type'] == 'event') {
            final ev = (map['event'] as Map).cast<String, dynamic>();
            _handleEvent(ev);
            setState(() {});
          }
        } catch (_) {}
      }, onError: (_) => _scheduleReconnect(), onDone: _scheduleReconnect);
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_closing) return;
    Future.delayed(Duration(milliseconds: _retryMs), () async {
      if (_closing) return;
      await _connectStream();
    });
    _retryMs = (_retryMs * 2).clamp(500, 8000);
  }

  void _handleEvent(Map<String, dynamic> ev) {
    switch (ev['type']) {
      case 'tictactoe_move':
        final move = TicTacToeMove.fromJson(ev);
        _game.handleRemoteMove(move);
        break;
      case 'tictactoe_reset':
        final sid = (ev['sessionId'] as num?)?.toInt() ?? (_game.sessionId + 1);
        _game.sessionId = sid;
        _game.reset();
        break;
      case 'player_register':
        _game.registerPlayer(ev['playerId'] as String? ?? '', name: ev['name'] as String?, emoji: ev['emoji'] as String?);
        break;
      case 'snapshot_state':
        final players = (ev['players'] as List<dynamic>? ?? []).cast<String>();
        final board = (ev['board'] as List<dynamic>? ?? []).cast<String>();
        final meta = (ev['meta'] as Map?)?.cast<String, dynamic>() ?? {};
        final mapped = <String, Map<String, String>>{};
        for (final e in meta.entries) {
          mapped[e.key] = {
            'name': (e.value as Map)['name']?.toString() ?? '',
            'emoji': (e.value as Map)['emoji']?.toString() ?? '',
          };
        }
        _game.applySnapshot(players: players, board: board, meta: mapped);
        final sid = (ev['sessionId'] as num?)?.toInt();
        if (sid != null) _game.sessionId = sid;
        break;
    }
  }

  Future<void> _announcePresenceAndRequestSnapshot() async {
    await _client.postEvent(_spaceId!, {
      'type': 'player_register',
      'playerId': _game.localPlayerId,
      'name': _game.localName,
      'emoji': _game.localEmoji,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    await _client.postEvent(_spaceId!, {
      'type': 'snapshot_request',
      'requesterId': _game.localPlayerId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _makeMove(int position) async {
    if (!_game.isMyTurn()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wait your turn — ${_game.playerEmoji(_game.currentTurnPlayerId ?? '')} ${_game.playerName(_game.currentTurnPlayerId ?? '')} is playing')),
      );
      return;
    }
    if (_game.canPlayPosition(position)) {
      final move = _game.createLocalMove(position);
      _game.applyMove(move);
      await _client.postEvent(_spaceId!, move.toJson());
      setState(() {});
    }
  }

  void _restartGame() async {
    final newId = _game.newSession();
    await _client.postEvent(_spaceId!, {
      'type': 'tictactoe_reset',
      'by': _game.localPlayerId,
      'sessionId': newId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TicTacToe + GUN'),
        backgroundColor: _connected ? Colors.green : Colors.red,
        actions: [IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings), onPressed: _showConnectionSettings)],
      ),
      body: _buildBody(),
      floatingActionButton: _connected
          ? FloatingActionButton.extended(onPressed: _showJoinDialog, icon: const Icon(Icons.link), label: const Text('Join Space'))
          : null,
    );
  }

  Widget _buildBody() {
    if (!_connected) return const Center(child: CircularProgressIndicator());
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_spaceId != null)
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Text('Space: ${_spaceId!}'))]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!_game.isOver)
                  Text(
                    _game.isMyTurn()
                        ? 'Your turn (${_game.symbolFor(_game.localPlayerId)})'
                        : 'Waiting: ${_game.playerEmoji(_game.currentTurnPlayerId ?? '')} ${_game.playerName(_game.currentTurnPlayerId ?? '')}',
                    style: TextStyle(fontWeight: FontWeight.bold, color: _game.isMyTurn() ? Colors.green : Colors.orange),
                  ),
                Text(_game.getStatusText()),
              ]),
            ),
            if (_game.isOver) ElevatedButton.icon(onPressed: _restartGame, icon: const Icon(Icons.replay), label: const Text('New Game')),
          ]),
        ]),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(20),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 1, crossAxisSpacing: 8, mainAxisSpacing: 8),
          itemCount: 9,
          itemBuilder: (context, index) {
            final disabled = !_game.isMyTurn() || !_game.canPlayPosition(index);
            return GestureDetector(
              onTap: () => _makeMove(index),
              child: Opacity(
                opacity: disabled ? 0.6 : 1,
                child: Container(
                  decoration: BoxDecoration(border: Border.all(width: 2), color: _game.canPlayPosition(index) ? Colors.blue[50] : Colors.grey[200]),
                  child: Center(
                    child: Text(
                      _game.board[index],
                      style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: _game.board[index] == 'X' ? Colors.blue : Colors.red),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }

  void _showConnectionSettings() {
    final hostController = TextEditingController(text: _host);
    final portController = TextEditingController(text: _port.toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Relay Settings'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: hostController, decoration: const InputDecoration(labelText: 'Relay Host')),
          TextField(controller: portController, decoration: const InputDecoration(labelText: 'Relay Port'), keyboardType: TextInputType.number),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              setState(() {
                _host = hostController.text.trim().isEmpty ? _host : hostController.text.trim();
                _port = int.tryParse(portController.text.trim()) ?? _port;
                _connected = _spaceId != null;
              });
              _client.host = _host;
              _client.port = _port;
              if (_spaceId != null) await _connectStream();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Apply'),
          )
        ],
      ),
    );
  }

  void _showJoinDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join Space'),
        content: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Enter space ID')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final id = controller.text.trim();
              if (id.isNotEmpty) {
                final ok = await _client.joinSpace(id);
                if (ok) {
                  setState(() => _spaceId = id);
                  await _connectStream();
                  await _announcePresenceAndRequestSnapshot();
                }
              }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Join'),
          )
        ],
      ),
    );
  }
}

class TicTacToeMove {
  final String id;
  final int position;
  final String playerId;
  final int timestamp;
  final int sessionId;
  TicTacToeMove({required this.id, required this.position, required this.playerId, required this.timestamp, required this.sessionId});
  Map<String, dynamic> toJson() => {'type': 'tictactoe_move', 'id': id, 'position': position, 'playerId': playerId, 'timestamp': timestamp, 'sessionId': sessionId};
  static TicTacToeMove fromJson(Map<String, dynamic> j) => TicTacToeMove(
        id: j['id'] as String,
        position: (j['position'] as num).toInt(),
        playerId: j['playerId'] as String,
        timestamp: (j['timestamp'] as num).toInt(),
        sessionId: (j['sessionId'] as num?)?.toInt() ?? 1,
      );
}

class SimpleTicTacToeCRDT {
  List<String> board = List.filled(9, '');
  final Map<String, TicTacToeMove> allMoves = {};
  final List<String> playersOrdered = [];
  final Map<String, String> _playerNames = {};
  final Map<String, String> _playerEmojis = {};
  late String localPlayerId;
  late String localName;
  late String localEmoji;
  int sessionId = 1;
  SimpleTicTacToeCRDT() {
    localPlayerId = 'player_${Random().nextInt(1000)}';
    final names = _firstNames;
    final emojis = _emojis;
    localName = names[Random().nextInt(names.length)];
    localEmoji = emojis[Random().nextInt(emojis.length)];
    registerPlayer(localPlayerId, name: localName, emoji: localEmoji);
  }
  void reset() { board = List.filled(9, ''); allMoves.clear(); }
  int newSession() { sessionId += 1; reset(); return sessionId; }
  void registerPlayer(String playerId, {String? name, String? emoji}) {
    if (!playersOrdered.contains(playerId)) playersOrdered.add(playerId);
    if (name != null && name.isNotEmpty) _playerNames[playerId] = name;
    if (emoji != null && emoji.isNotEmpty) _playerEmojis[playerId] = emoji;
  }
  void applySnapshot({required List<String> players, required List<String> board, Map<String, Map<String, String>> meta = const {}}) {
    playersOrdered..clear()..addAll(players);
    this.board = List<String>.from(board);
    for (final e in meta.entries) { registerPlayer(e.key, name: e.value['name'], emoji: e.value['emoji']); }
  }
  bool canPlayPosition(int position) => position >= 0 && position < 9 && board[position].isEmpty;
  TicTacToeMove createLocalMove(int position) => TicTacToeMove(id: '${localPlayerId}_${DateTime.now().millisecondsSinceEpoch}', position: position, playerId: localPlayerId, timestamp: DateTime.now().millisecondsSinceEpoch, sessionId: sessionId);
  void applyMove(TicTacToeMove move) {
    if (move.sessionId != sessionId) return;
    registerPlayer(move.playerId);
    final existingMove = _findMoveAtPosition(move.position);
    if (existingMove == null) {
      allMoves[move.id] = move;
      board[move.position] = symbolFor(move.playerId);
    } else {
      if (move.timestamp > existingMove.timestamp) {
        allMoves.remove(existingMove.id);
        allMoves[move.id] = move;
        board[move.position] = symbolFor(move.playerId);
      }
    }
  }
  void handleRemoteMove(TicTacToeMove move) => applyMove(move);
  TicTacToeMove? _findMoveAtPosition(int position) { for (final m in allMoves.values) { if (m.position == position) return m; } return null; }
  String symbolFor(String playerId) { registerPlayer(playerId); final idx = playersOrdered.indexOf(playerId); const symbols = ['X','O','△','□','◇']; return symbols[idx.clamp(0, symbols.length - 1)]; }
  String playerName(String playerId) => _playerNames[playerId] ?? 'Player';
  String playerEmoji(String playerId) => _playerEmojis[playerId] ?? '🙂';
  Map<String, Map<String, String>> get playersMeta => { for (final pid in playersOrdered) pid: {'name': playerName(pid), 'emoji': playerEmoji(pid)} };
  String? get currentTurnPlayerId { final count = board.where((c) => c.isNotEmpty).length; if (playersOrdered.isEmpty) return null; final idx = count % playersOrdered.length; return playersOrdered[idx]; }
  bool isMyTurn() => currentTurnPlayerId == localPlayerId;
  String getStatusText() { final winner = _checkWinner(); if (winner != null) return winner == localPlayerId ? 'You win!' : '${playerEmoji(winner)} ${playerName(winner)} wins!'; if (board.every((c) => c.isNotEmpty)) return "It's a draw!"; return 'Game in progress'; }
  bool get isOver => _checkWinner() != null || board.every((c) => c.isNotEmpty);
  String? _checkWinner() { const p = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]; for (final w in p){ final a=board[w[0]], b=board[w[1]], c=board[w[2]]; if(a.isNotEmpty && a==b && b==c){ for(final m in allMoves.values){ if(symbolFor(m.playerId)==a) return m.playerId; } } } return null; }
}

const _firstNames = ['Alex','Sam','Taylor','Jordan','Casey','Riley','Avery','Jamie','Morgan','Quinn','Harper','Skyler','Drew','Cameron','Rowan','Parker','Reese','Charlie','Elliot','Logan'];
const _emojis = ['😀','😄','😁','😎','🤩','😊','😉','🥳','🤠','🧠','🦊','🐱','🐶','🐼','🐯','🐵','🐸','🐤','🦄','🐙','🐳','🐝','🌈','⭐️','⚡️','🔥','🍀','🍉','🍕','🍩'];

