import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math';
import 'dart:math' as math;
import 'package:eventsource/eventsource.dart';
import 'package:flutter/material.dart';
import 'gun_client.dart';
import 'package:flame/particles.dart';
import 'package:flame/widgets.dart';
import 'package:flame_audio/flame_audio.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2;
import 'package:flame/particles.dart';
import 'package:flame/widgets.dart';

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
  StreamSubscription<Event>? _sub;
  bool _closing = false;
  int _retryMs = 500;
  DateTime _lastEventAt = DateTime.now();
  Timer? _watchdog;
  Timer? _clockTicker;
  final List<_Burst> _bursts = [];
  // Replaced by _bursts list

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String();
    // Use both dev.log and print to ensure visibility across platforms
    dev.log('[TicTacToeGun][$ts] $msg');
    // ignore: avoid_print
    print('[TicTacToeGun][$ts] $msg');
  }

  @override
  void initState() {
    super.initState();
    _initialize();
    _clockTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_connected) setState(() {}); // tick UI clocks
    });
  }

  @override
  void dispose() {
    _closing = true;
    _sub?.cancel();
    _watchdog?.cancel();
    _clockTicker?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    _client.host = _host;
    _client.port = _port;
    _log('Initializing client against $_host:$_port');
    final id = await _client.createSpace();
    if (id == null) {
      _log('Failed to create space (null id).');
      return;
    }
    _spaceId = id;
    _log('Created space: $_spaceId');
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
    _log('Fetching snapshot for space: $_spaceId');
    final snaps = await _client.snapshot(_spaceId!);
    _log('Snapshot returned ${snaps.length} events');
    // Rebuild board from snapshot deterministically
    for (final e in snaps) {
      _handleEvent(e);
    }
  }

  Future<void> _startStream() async {
    _sub?.cancel();
    _watchdog?.cancel();
    try {
      _log('Connecting SSE stream for space: $_spaceId');
      final es = await _client.stream(_spaceId!);
      _retryMs = 500; // reset backoff
      _sub = es.listen(
        (msg) {
          final data = msg.data;
          if (data == null || data.isEmpty) return;
          try {
            final map = jsonDecode(data) as Map<String, dynamic>;
            if (map['type'] == 'event') {
              final ev = (map['event'] as Map).cast<String, dynamic>();
              _handleEvent(ev);
              setState(() {});
            } else if (map['type'] == 'hello') {
              _log('SSE hello received: $map');
            } else if (map['type'] == 'heartbeat') {
              _log('SSE heartbeat');
            } else {
              _log('SSE unknown payload: $map');
            }
            _lastEventAt = DateTime.now();
          } catch (e, st) {
            _log('Error decoding SSE data: $e\n$st\nRaw: $data');
          }
        },
        onError: (e, st) {
          _log('SSE stream error: $e');
          _scheduleReconnect();
        },
        onDone: () {
          _log('SSE stream closed by server');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      _log('SSE stream connected');
      _lastEventAt = DateTime.now();
      _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        final silentFor = DateTime.now().difference(_lastEventAt);
        if (silentFor > const Duration(seconds: 35)) {
          _log('No SSE activity for ${silentFor.inSeconds}s, reconnecting');
          _sub?.cancel();
          _scheduleReconnect();
        }
      });
    } catch (e, st) {
      _log('Failed to start SSE stream: $e\n$st');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_closing) return;
    _log('Scheduling reconnect in ${_retryMs}ms');
    Future.delayed(Duration(milliseconds: _retryMs), () async {
      if (_closing) return;
       _log('Reconnecting now...');
      await _connectStream();
    });
    _retryMs = (_retryMs * 2).clamp(500, 8000);
    _log('Backoff updated to ${_retryMs}ms');
  }

  void _handleEvent(Map<String, dynamic> ev) {
    _log('Handling event type=${ev['type']}');
    switch (ev['type']) {
      case 'snapshot_request':
        final requester = ev['requesterId'] as String?;
        if (requester != null && requester != _game.localPlayerId) {
          // Respond with current state
          final payload = {
            'type': 'snapshot_state',
            'players': List<String>.from(_game.playersOrdered),
            'board': List<String>.from(_game.board),
            'meta': _game.playersMeta,
            'symbols': _game.playerSymbols,
            'time': {
              'remaining': { for (final e in _game.remainingMs.entries) e.key: e.value },
              'turnStartTs': _game.turnStartTs ?? DateTime.now().millisecondsSinceEpoch,
              'incrementMs': _game.incrementMs,
            },
            'sessionId': _game.sessionId,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          };
          _client.postEvent(_spaceId!, payload);
        }
        break;
      case 'tictactoe_move':
        final move = TicTacToeMove.fromJson(ev);
        _game.handleRemoteMove(move);
        _playSfx('move.wav');
        _triggerBurstAt(_alignmentForIndex(move.position));
        if (_game.isOver) { _triggerBurstAt(Alignment.center, scale: 2.0, duration: const Duration(milliseconds: 1100)); _playSfx('win.wav'); }
        if (mounted) setState(() {});
        break;
      case 'tictactoe_reset':
        final sid = (ev['sessionId'] as num?)?.toInt() ?? (_game.sessionId + 1);
        _game.sessionId = sid;
        _game.reset();
        break;
      case 'player_register':
        _game.registerPlayer(ev['playerId'] as String? ?? '', name: ev['name'] as String?, emoji: ev['emoji'] as String?);
        // Coordinator assigns symbols deterministically
        if (_game.isCoordinator) {
          final pid = (ev['playerId'] as String? ?? '').trim();
          if (pid.isNotEmpty && _game.playerSymbol(pid) == null) {
            final symbol = _game.nextAvailableSymbol();
            _game.setSymbol(pid, symbol);
            if (_spaceId != null) {
              _client.postEvent(_spaceId!, {'type': 'symbol_assign', 'playerId': pid, 'symbol': symbol});
            }
          }
        }
        if (mounted) setState(() {});
        break;
      case 'symbol_assign':
        final pid = (ev['playerId'] ?? '').toString();
        final sym = (ev['symbol'] ?? '').toString();
        if (pid.isNotEmpty && sym.isNotEmpty) {
          _game.setSymbol(pid, sym);
          if (mounted) setState(() {});
        }
        break;
      case 'snapshot_state':
        final players = _asStringList(ev['players']);
        final board = _asStringList(ev['board']);
        final meta = (ev['meta'] as Map?)?.cast<String, dynamic>() ?? {};
        final mapped = <String, Map<String, String>>{};
        for (final e in meta.entries) {
          mapped[e.key] = {
            'name': (e.value as Map)['name']?.toString() ?? '',
            'emoji': (e.value as Map)['emoji']?.toString() ?? '',
          };
        }
        _game.applySnapshot(players: players, board: board, meta: mapped);
        final symbols = (ev['symbols'] as Map?)?.cast<String, dynamic>();
        if (symbols != null) { symbols.forEach((k, v) { if (v != null) _game.setSymbol(k, v.toString()); }); }
        final time = (ev['time'] as Map?)?.cast<String, dynamic>();
        if (time != null) {
          final remainingRaw = (time['remaining'] as Map?)?.cast<String, dynamic>() ?? {};
          final rem = <String, int>{};
          for (final e in remainingRaw.entries) {
            final v = e.value;
            rem[e.key] = v is num ? v.toInt() : int.tryParse(v.toString()) ?? _game.initialTimeMs;
          }
          final ts = (time['turnStartTs'] is num) ? (time['turnStartTs'] as num).toInt() : int.tryParse('${time['turnStartTs'] ?? ''}');
          final inc = (time['incrementMs'] is num) ? (time['incrementMs'] as num).toInt() : int.tryParse('${time['incrementMs'] ?? ''}');
          _game.applyTimeUpdate(remaining: rem, turnStartTs: ts, incrementMs: inc);
        }
        final sid = (ev['sessionId'] as num?)?.toInt();
        if (sid != null) _game.sessionId = sid;
        if (mounted) setState(() {});
        break;
      case 'time_update':
        final remainingRaw = (ev['remaining'] as Map?)?.cast<String, dynamic>() ?? {};
        final rem = <String, int>{};
        for (final e in remainingRaw.entries) {
          final v = e.value;
          rem[e.key] = v is num ? v.toInt() : int.tryParse(v.toString()) ?? _game.initialTimeMs;
        }
        final ts = (ev['turnStartTs'] is num) ? (ev['turnStartTs'] as num).toInt() : int.tryParse('${ev['turnStartTs'] ?? ''}');
        final inc = (ev['incrementMs'] is num) ? (ev['incrementMs'] as num).toInt() : int.tryParse('${ev['incrementMs'] ?? ''}');
        _game.applyTimeUpdate(remaining: rem, turnStartTs: ts, incrementMs: inc);
        if (mounted) setState(() {});
        break;
      case 'time_flag':
        final winner = (ev['winnerId'] ?? '').toString();
        final loser = (ev['loserId'] ?? '').toString();
        _game.applyFlag(winnerId: winner, loserId: loser);
        _triggerBurstAt(Alignment.center, scale: 2.2, duration: const Duration(milliseconds: 1200));
        _playSfx('win.wav');
        if (mounted) setState(() {});
        break;
    }
  }

  // Accept either a List<String> or a Map<String, dynamic> (index-keyed) and return a List<String> in order.
  List<String> _asStringList(dynamic v) {
    if (v is List) {
      return v.map((e) => e?.toString() ?? '').toList();
    } else if (v is Map) {
      final m = v.cast<String, dynamic>();
      final keys = m.keys.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a) ?? 0;
          final bi = int.tryParse(b) ?? 0;
          return ai.compareTo(bi);
        });
      return keys.map((k) => m[k]?.toString() ?? '').toList();
    }
    return const [];
  }

  Future<void> _announcePresenceAndRequestSnapshot() async {
    _log('Announce presence: ${_game.localPlayerId}');
    final ok1 = await _client.postEvent(_spaceId!, {
      'type': 'player_register',
      'playerId': _game.localPlayerId,
      'name': _game.localName,
      'emoji': _game.localEmoji,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    _log('Register posted: $ok1, requesting snapshot');
    final ok2 = await _client.postEvent(_spaceId!, {
      'type': 'snapshot_request',
      'requesterId': _game.localPlayerId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    _log('Snapshot request posted: $ok2');
  }

  void _makeMove(int position) async {
    if (!_game.isMyTurn()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wait your turn — ${_game.playerEmoji(_game.currentTurnPlayerId ?? '')} ${_game.playerName(_game.currentTurnPlayerId ?? '')} is playing')),
      );
      return;
    }
    if (_game.canPlayPosition(position)) {
      if (_game.currentTurnRemainingMs(DateTime.now().millisecondsSinceEpoch) <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Out of time!')),
        );
        return;
      }
      _game.consumeTimeBeforeMove(DateTime.now().millisecondsSinceEpoch);
      final move = _game.createLocalMove(position);
      _game.applyMove(move);
      final ok = await _client.postEvent(_spaceId!, move.toJson());
      _log('Posted move position=$position ok=$ok');
      // Advance turn timing and broadcast time update
      final timeUpdate = _game.advanceTurnAndGetTimeUpdate(DateTime.now().millisecondsSinceEpoch);
      await _client.postEvent(_spaceId!, {
        'type': 'time_update',
        ...timeUpdate,
      });
      _playSfx('move.wav');
      _triggerBurstAt(_alignmentForIndex(position));
      if (_game.isOver) { _triggerBurstAt(Alignment.center, scale: 2.0, duration: const Duration(milliseconds: 1100)); _playSfx('win.wav'); }
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
      body: Stack(children: [
        _buildBody(),
        if (_bursts.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(child: _buildBurstOverlay()),
          ),
      ]),
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
          Wrap(spacing: 8, runSpacing: 8, children: [
            Text('You are: ${_game.localEmoji} ${_game.localName}', style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 8),
          // Clocks for all players
          Wrap(spacing: 12, runSpacing: 6, children: _game.playersOrdered.map((pid) {
            final rem = _game.timeDisplayFor(pid, DateTime.now().millisecondsSinceEpoch);
            final isTurn = _game.currentTurnPlayerId == pid && !_game.isOver;
            final me = pid == _game.localPlayerId;
            return Chip(
              avatar: Text(_game.playerEmoji(pid)),
              label: Text('${_game.playerName(pid)} • ${_fmtMs(rem)}'),
              backgroundColor: _game.flagged && _game.flagLoser == pid
                  ? Colors.red[200]
                  : isTurn ? Colors.green[100] : (me ? Colors.blue[50] : Colors.grey[200]),
            );
          }).toList()),
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

  Widget _buildBurstOverlay() {
    return Stack(children: _bursts.map((b) {
      final rnd = Random(b.seed);
      final particle = Particle.generate(
        count: (80 * b.scale).round(),
        lifespan: 0.8 + 0.4 * b.scale,
        generator: (i) {
          final angle = rnd.nextDouble() * math.pi * 2;
          final speed = (80 + rnd.nextDouble() * 240) * b.scale;
          final vx = speed * math.cos(angle);
          final vy = speed * math.sin(angle);
          return AcceleratedParticle(
            acceleration: Vector2(0, 200 * b.scale),
            speed: Vector2(vx, vy),
            position: Vector2.zero(),
            child: CircleParticle(
              radius: 2 + rnd.nextDouble() * 5 * b.scale,
              paint: Paint()
                ..color = Colors.primaries[rnd.nextInt(Colors.primaries.length)]
                    .withOpacity(0.9),
            ),
          );
        },
      );
      return Align(
        alignment: b.alignment,
        child: SizedBox.expand(child: _ParticleWidgetLite(particle: particle)),
      );
    }).toList());
  }

  void _triggerBurstAt(Alignment alignment, {double scale = 1.0, Duration duration = const Duration(milliseconds: 900)}) {
    final b = _Burst(seed: DateTime.now().microsecondsSinceEpoch, alignment: alignment, scale: scale, endAt: DateTime.now().add(duration));
    setState(() => _bursts.add(b));
    Future.delayed(duration, () { if (!mounted) return; setState(() => _bursts.remove(b)); });
  }

  Alignment _alignmentForIndex(int index) {
    final row = (index ~/ 3).clamp(0, 2);
    final col = (index % 3).clamp(0, 2);
    const positions = [-0.8, 0.0, 0.8];
    return Alignment(positions[col], positions[row]);
  }

  void _playSfx(String name) { try { FlameAudio.play(name, volume: 0.8); } catch (_) {} }

  String _fmtMs(int ms) {
    final s = (ms / 1000).floor();
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final r = (s % 60).toString().padLeft(2, '0');
    return '$m:$r';
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
              _log('Applied settings host=$_host port=$_port');
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
    final manualController = TextEditingController();
    List<Map<String, dynamic>> spaces = [];
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Join Space'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh list'),
                  onPressed: () async {
                    final list = await _client.listSpaces();
                    setLocal(() => spaces = list);
                  },
                ),
              ),
              SizedBox(
                height: 220,
                child: spaces.isEmpty
                    ? const Center(child: Text('No spaces found yet. Click Refresh or use manual join.'))
                    : ListView.builder(
                        itemCount: spaces.length,
                        itemBuilder: (context, i) {
                          final id = spaces[i]['id']?.toString() ?? '';
                          return ListTile(
                            title: Text(id),
                            trailing: const Icon(Icons.login),
                            onTap: () async {
                              _log('Joining space: $id');
                              final ok = await _client.joinSpace(id);
                              if (ok) {
                                setState(() => _spaceId = id);
                                await _connectStream();
                                await _announcePresenceAndRequestSnapshot();
                                if (mounted) Navigator.pop(context);
                              } else {
                                _log('Join space failed');
                              }
                            },
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              const Align(alignment: Alignment.centerLeft, child: Text('Join manually:')),
              TextField(controller: manualController, decoration: const InputDecoration(hintText: 'Enter space ID')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            ElevatedButton(
              onPressed: () async {
                final id = manualController.text.trim();
                if (id.isNotEmpty) {
                  _log('Joining space: $id');
                  final ok = await _client.joinSpace(id);
                  if (ok) {
                    setState(() => _spaceId = id);
                    await _connectStream();
                    await _announcePresenceAndRequestSnapshot();
                    if (mounted) Navigator.pop(context);
                  } else {
                    _log('Join space failed');
                  }
                }
              },
              child: const Text('Join'),
            )
          ],
        ),
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
  final Map<String, String> _playerSymbols = {}; // explicit symbol assignment
  late String localPlayerId;
  late String localName;
  late String localEmoji;
  int sessionId = 1;
  // Timebank settings/state
  int initialTimeMs = 60000; // 60s default per side
  int incrementMs = 2000; // per-move increment
  final Map<String, int> remainingMs = {}; // per player remaining
  int? turnStartTs; // epoch ms when current turn started
  bool flagged = false;
  String? flagWinner;
  String? flagLoser;
  SimpleTicTacToeCRDT() {
    localPlayerId = 'player_${Random().nextInt(1000)}';
    final names = _firstNames;
    final emojis = _emojis;
    localName = names[Random().nextInt(names.length)];
    localEmoji = emojis[Random().nextInt(emojis.length)];
    registerPlayer(localPlayerId, name: localName, emoji: localEmoji);
    _ensureTime(localPlayerId);
  }
  void reset() { board = List.filled(9, ''); allMoves.clear(); }
  int newSession() { sessionId += 1; reset(); return sessionId; }
  void registerPlayer(String playerId, {String? name, String? emoji}) {
    if (!playersOrdered.contains(playerId)) playersOrdered.add(playerId);
    if (name != null && name.isNotEmpty) _playerNames[playerId] = name;
    if (emoji != null && emoji.isNotEmpty) _playerEmojis[playerId] = emoji;
    _ensureTime(playerId);
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
  bool get isCoordinator => playersOrdered.isNotEmpty && playersOrdered.first == localPlayerId;
  String? playerSymbol(String playerId) => _playerSymbols[playerId];
  void setSymbol(String playerId, String symbol) { _playerSymbols[playerId] = symbol; }
  Map<String, String> get playerSymbols => { for (final e in _playerSymbols.entries) e.key: e.value };
  String nextAvailableSymbol() {
    const symbols = ['X','O','△','□','◇'];
    for (final s in symbols) { if (!_playerSymbols.values.contains(s)) return s; }
    return symbols[(playersOrdered.indexOf(localPlayerId)).clamp(0, symbols.length - 1)];
  }
  String symbolFor(String playerId) {
    registerPlayer(playerId);
    return _playerSymbols[playerId] ?? (() {
      const symbols = ['X','O','△','□','◇'];
      final idx = playersOrdered.indexOf(playerId);
      return symbols[idx.clamp(0, symbols.length - 1)];
    })();
  }
  String playerName(String playerId) => _playerNames[playerId] ?? 'Player';
  String playerEmoji(String playerId) => _playerEmojis[playerId] ?? '🙂';
  Map<String, Map<String, String>> get playersMeta => { for (final pid in playersOrdered) pid: {'name': playerName(pid), 'emoji': playerEmoji(pid)} };
  String? get currentTurnPlayerId { final count = board.where((c) => c.isNotEmpty).length; if (playersOrdered.isEmpty) return null; final idx = count % playersOrdered.length; return playersOrdered[idx]; }
  bool isMyTurn() => currentTurnPlayerId == localPlayerId;
  bool get isOver => flagged || _checkWinner() != null || board.every((c) => c.isNotEmpty);
  String getStatusText() {
    if (flagged && flagWinner != null) {
      return flagWinner == localPlayerId ? 'Opponent flagged (timeout)!' : '${playerEmoji(flagWinner!)} ${playerName(flagWinner!)} wins on time!';
    }
    final winner = _checkWinner();
    if (winner != null) return winner == localPlayerId ? 'You win!' : '${playerEmoji(winner)} ${playerName(winner)} wins!';
    if (board.every((c) => c.isNotEmpty)) return "It's a draw!";
    return 'Game in progress';
  }
  String? _checkWinner() { const p = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]; for (final w in p){ final a=board[w[0]], b=board[w[1]], c=board[w[2]]; if(a.isNotEmpty && a==b && b==c){ for(final m in allMoves.values){ if(symbolFor(m.playerId)==a) return m.playerId; } } } return null; }

  // Time helpers
  void _ensureTime(String pid) { remainingMs.putIfAbsent(pid, () => initialTimeMs); }
  int currentTurnRemainingMs(int nowMs) {
    final pid = currentTurnPlayerId; if (pid == null) return initialTimeMs;
    final base = remainingMs[pid] ?? initialTimeMs;
    final start = turnStartTs;
    if (start == null) return base;
    final elapsed = nowMs - start; return (base - elapsed).clamp(0, 1<<31);
  }
  int timeDisplayFor(String pid, int nowMs) {
    if (pid != currentTurnPlayerId) return (remainingMs[pid] ?? initialTimeMs).clamp(0, 1<<31);
    return currentTurnRemainingMs(nowMs);
  }
  void consumeTimeBeforeMove(int nowMs) {
    final pid = currentTurnPlayerId; if (pid == null) return;
    final start = turnStartTs ?? nowMs;
    final elapsed = (nowMs - start).clamp(0, 1<<31);
    remainingMs[pid] = ((remainingMs[pid] ?? initialTimeMs) - elapsed).clamp(0, 1<<31);
  }
  Map<String, dynamic> advanceTurnAndGetTimeUpdate(int nowMs) {
    // Add increment to the next player's clock and start their turn now
    final next = _nextTurnPlayerId();
    if (next != null) {
      _ensureTime(next);
      remainingMs[next] = ((remainingMs[next] ?? initialTimeMs) + incrementMs).clamp(0, 1<<31);
    }
    turnStartTs = nowMs;
    return {
      'remaining': { for (final e in remainingMs.entries) e.key: e.value },
      'turnStartTs': turnStartTs,
      'incrementMs': incrementMs,
    };
  }
  void applyTimeUpdate({required Map<String,int> remaining, int? turnStartTs, int? incrementMs}) {
    remainingMs
      ..clear()
      ..addAll(remaining);
    if (turnStartTs != null) this.turnStartTs = turnStartTs;
    if (incrementMs != null) this.incrementMs = incrementMs;
  }
  String? _nextTurnPlayerId() {
    final n = board.where((c) => c.isNotEmpty).length + 1;
    if (playersOrdered.isEmpty) return null; final idx = n % playersOrdered.length; return playersOrdered[idx];
  }
  Map<String, dynamic>? checkAndMaybeFlagTimeout(int nowMs) {
    if (flagged || isOver) return null;
    final cur = currentTurnPlayerId; if (cur == null) return null;
    if (currentTurnRemainingMs(nowMs) <= 0) {
      final others = playersOrdered.where((p) => p != cur).toList();
      final winner = others.isNotEmpty ? others.first : null;
      if (winner != null) {
        flagged = true; flagLoser = cur; flagWinner = winner;
        return {
          'type': 'time_flag',
          'winnerId': winner,
          'loserId': cur,
          'timestamp': nowMs,
        };
      }
    }
    return null;
  }
  void applyFlag({required String winnerId, required String loserId}) {
    flagged = true; flagWinner = winnerId; flagLoser = loserId;
  }
}

class _Burst {
  final int seed;
  final Alignment alignment;
  final double scale;
  final DateTime endAt;
  _Burst({required this.seed, required this.alignment, this.scale = 1.0, required this.endAt});
}

class _ParticleWidgetLite extends StatefulWidget {
  final Particle particle;
  const _ParticleWidgetLite({super.key, required this.particle});
  @override
  State<_ParticleWidgetLite> createState() => _ParticleWidgetLiteState();
}

class _ParticleWidgetLiteState extends State<_ParticleWidgetLite>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final dt = ((elapsed - _last).inMicroseconds) / 1e6;
      if (dt > 0) {
        widget.particle.update(dt);
        setState(() {});
      }
      _last = elapsed;
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ParticlePainterLite(widget.particle));
  }
}

class _ParticlePainterLite extends CustomPainter {
  final Particle particle;
  _ParticlePainterLite(this.particle);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    particle.render(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ParticlePainterLite oldDelegate) => true;
}

const _firstNames = ['Alex','Sam','Taylor','Jordan','Casey','Riley','Avery','Jamie','Morgan','Quinn','Harper','Skyler','Drew','Cameron','Rowan','Parker','Reese','Charlie','Elliot','Logan'];
const _emojis = ['😀','😄','😁','😎','🤩','😊','😉','🥳','🤠','🧠','🦊','🐱','🐶','🐼','🐯','🐵','🐸','🐤','🦄','🐙','🐳','🐝','🌈','⭐️','⚡️','🔥','🍀','🍉','🍕','🍩'];
