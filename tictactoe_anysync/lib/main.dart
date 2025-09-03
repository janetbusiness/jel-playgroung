import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'anysync_client.dart';

void main() => runApp(const TicTacToeApp());

class TicTacToeApp extends StatelessWidget {
  const TicTacToeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TicTacToe + any-sync',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const GameScreen(),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final AnySyncClient _client = AnySyncClient.instance;
  final SimpleTicTacToeCRDT _game = SimpleTicTacToeCRDT();

  bool _connected = false;
  String? _spaceId;
  String? _error;
  String _host = '127.0.0.1';
  int _port = 8080;
  String _networkId = 'tictactoe-network';
  bool _iAmCreator = false;
  final _joinNotified = <String>{};
  AnySyncStatus _status = AnySyncStatus.empty();
  Timer? _statusTimer;
  bool _showDebug = true;
  bool _verboseLog = false;

  @override
  void initState() {
    super.initState();
    _initializeGame();
  }

  Future<void> _initializeGame() async {
    try {
      final success = await _client.initialize(
        nodeHost: _host,
        nodePort: _port,
        networkId: _networkId,
      );
      if (!success) {
        setState(() => _error = 'Failed to connect to any-sync network');
        return;
      }
      final spaceId = await _client.createTicTacToeSpace();
      if (spaceId == null) {
        setState(() => _error = 'Failed to create game space');
        return;
      }
      setState(() {
        _connected = true;
        _spaceId = spaceId;
        _iAmCreator = true;
      });
      await _announcePresenceAndMaybeRequestSnapshot();
      _startStatusPolling();
      _client.startListening((event) {
        if (event.type == 'tictactoe_reset') {
          _game.reset();
        } else if (event.type == 'tictactoe_move' && event.move != null) {
          _game.handleRemoteMove(event.move!);
        } else if (event.type == 'player_register' && event.playerId != null) {
          _game.registerPlayer(event.playerId!, name: event.name, emoji: event.emoji);
          _maybeNotifyJoin(event.playerId!);
        } else if (event.type == 'snapshot_request' && event.requesterId != null) {
          if (_iAmCreator) {
            _client.sendSnapshotState(
              players: _game.playersOrdered,
              board: _game.board,
              to: event.requesterId!,
              meta: _game.playersMeta,
            );
          }
        } else if (event.type == 'snapshot_state' && event.to == _game.localPlayerId) {
          if (event.players != null && event.board != null && event.board!.length == 9) {
            _game.applySnapshot(players: event.players!, board: event.board!, meta: event.meta ?? {});
          }
        }
        setState(() {});
      });
    } catch (e) {
      setState(() => _error = 'Error: $e');
    }
  }

  void _makeMove(int position) {
    if (_game.canPlayPosition(position)) {
      final move = _game.createLocalMove(position);
      _game.applyMove(move);
      _client.sendMove(move);
      setState(() {});
    }
  }

  void _restartGame() {
    _game.reset();
    // Broadcast reset so peers clear their boards
    _client.sendReset(by: _game.localPlayerId);
    setState(() {});
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final s = await _client.getStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
      });
      if (_verboseLog) {
        // ignore: avoid_print
        print('Status: peers=${s.peerCount}, lastSyncMs=${s.lastSyncMs}, node=${s.nodeHost}:${s.nodePort}, space=${s.spaceId}');
      }
    });
  }

  String _fmtLastSync(int ms) {
    if (ms <= 0) return '–';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 1) return 'now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TicTacToe + any-sync'),
        backgroundColor: _connected ? Colors.green : Colors.red,
        actions: [
          IconButton(
            tooltip: 'Connection Settings',
            icon: const Icon(Icons.settings),
            onPressed: _showConnectionSettings,
          )
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _connected
          ? FloatingActionButton.extended(
              onPressed: _showJoinDialog,
              icon: const Icon(Icons.link),
              label: const Text('Join Space'),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
          child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    if (!_connected) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        if (_connected && _showDebug)
          Container(
            width: double.infinity,
            color: Colors.black12,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Node: ${_status.nodeHost ?? _host}:${_status.nodePort ?? _port}  •  Peers: ${_status.peerCount}  •  Last sync: ${_fmtLastSync(_status.lastSyncMs)}',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_spaceId != null)
                  Text('Space: ${_spaceId!}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_spaceId != null && _spaceId!.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: Theme.of(context).textTheme.bodyMedium,
                          children: [
                            const TextSpan(text: 'Space ID: '),
                            TextSpan(
                              text: _spaceId!,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy Space ID',
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _spaceId!));
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Space ID copied')),
                        );
                      },
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              if (_game.playersOrdered.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: _game.playersOrdered
                      .map((pid) => Chip(
                            label: Text('${_game.playerEmoji(pid)} ${_game.playerName(pid)}'),
                          ))
                      .toList(),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text(_game.getStatusText())),
                  if (_game.isOver)
                    ElevatedButton.icon(
                      onPressed: _restartGame,
                      icon: const Icon(Icons.replay),
                      label: const Text('New Game'),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(20),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 1,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: 9,
            itemBuilder: (context, index) {
              return GestureDetector(
                onTap: () => _makeMove(index),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(width: 2),
                    color: _game.canPlayPosition(index)
                        ? Colors.blue[50]
                        : Colors.grey[200],
                  ),
                  child: Center(
                    child: Text(
                      _game.board[index],
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: _game.board[index] == 'X'
                            ? Colors.blue
                            : Colors.red,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showJoinDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join Space'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter space ID'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final id = controller.text.trim();
              if (id.isNotEmpty) {
                final ok = await _client.joinTicTacToeSpace(id);
                if (ok) {
                  setState(() => _spaceId = id);
                  _iAmCreator = false;
                  _client.startListening((event) {
                    if (event.type == 'tictactoe_reset') {
                      _game.reset();
                    } else if (event.type == 'tictactoe_move' && event.move != null) {
                      _game.handleRemoteMove(event.move!);
                    } else if (event.type == 'player_register' && event.playerId != null) {
                      _game.registerPlayer(event.playerId!, name: event.name, emoji: event.emoji);
                      _maybeNotifyJoin(event.playerId!);
                    } else if (event.type == 'snapshot_request' && event.requesterId != null) {
                      if (_iAmCreator) {
                        _client.sendSnapshotState(
                          players: _game.playersOrdered,
                          board: _game.board,
                          to: event.requesterId!,
                          meta: _game.playersMeta,
                        );
                      }
                    } else if (event.type == 'snapshot_state' && event.to == _game.localPlayerId) {
                      if (event.players != null && event.board != null && event.board!.length == 9) {
                        _game.applySnapshot(players: event.players!, board: event.board!, meta: event.meta ?? {});
                      }
                    }
                    setState(() {});
                  });
                  // Announce presence and request snapshot from creator/peers
                  await _announcePresenceAndMaybeRequestSnapshot();
                  _startStatusPolling();
                } else {
                  setState(() => _error = 'Failed to join space');
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

  void _showConnectionSettings() {
    final hostController = TextEditingController(text: _host);
    final portController = TextEditingController(text: _port.toString());
    final networkController = TextEditingController(text: _networkId);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connection Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostController,
              decoration: const InputDecoration(labelText: 'Node Host'),
            ),
            TextField(
              controller: portController,
              decoration: const InputDecoration(labelText: 'Node Port'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: networkController,
              decoration: const InputDecoration(labelText: 'Network ID'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show Debug Banner'),
              value: _showDebug,
              onChanged: (v) => setState(() => _showDebug = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Verbose Status Logs'),
              value: _verboseLog,
              onChanged: (v) => setState(() => _verboseLog = v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final host = hostController.text.trim();
              final port = int.tryParse(portController.text.trim()) ?? _port;
              final netId = networkController.text.trim();

              setState(() {
                _host = host.isEmpty ? _host : host;
                _port = port;
                _networkId = netId.isEmpty ? _networkId : netId;
                _connected = false;
                _spaceId = null;
                _error = null;
              });

              // Re-initialize and create a fresh space
              await _initializeGame();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Reconnect'),
          )
        ],
      ),
    );
  }
}

extension on _GameScreenState {
  Future<void> _announcePresenceAndMaybeRequestSnapshot() async {
    // Announce this player
    await _client.sendPlayerRegister(
      playerId: _game.localPlayerId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      name: _game.localName,
      emoji: _game.localEmoji,
    );
    // If we joined an existing space (not creator), request snapshot
    if (!_iAmCreator) {
      await _client.sendSnapshotRequest(requesterId: _game.localPlayerId);
    }
  }

  void _maybeNotifyJoin(String playerId) {
    if (playerId == _game.localPlayerId) return;
    if (!mounted) return;
    final msg = '${_game.playerEmoji(playerId)} ${_game.playerName(playerId)} joined';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }
}

const _firstNames = [
  'Alex', 'Sam', 'Taylor', 'Jordan', 'Casey', 'Riley', 'Avery', 'Jamie', 'Morgan', 'Quinn', 'Harper', 'Skyler',
  'Drew', 'Cameron', 'Rowan', 'Parker', 'Reese', 'Charlie', 'Elliot', 'Logan',
];

const _emojis = [
  '😀','😄','😁','😎','🤩','😊','😉','🥳','🤠','🧠','🦊','🐱','🐶','🐼','🐯','🐵','🐸','🐤','🦄','🐙','🐳','🐝','🌈','⭐️','⚡️','🔥','🍀','🍉','🍕','🍩'
];

class SimpleTicTacToeCRDT {
  List<String> board = List.filled(9, '');
  final Map<String, TicTacToeMove> allMoves = {};
  final List<String> playersOrdered = [];
  final Map<String, String> _playerNames = {};
  final Map<String, String> _playerEmojis = {};
  late String localPlayerId;
  late String localName;
  late String localEmoji;

  SimpleTicTacToeCRDT() {
    localPlayerId = 'player_${Random().nextInt(1000)}';
    final names = _firstNames;
    final emojis = _emojis;
    localName = names[Random().nextInt(names.length)];
    localEmoji = emojis[Random().nextInt(emojis.length)];
    registerPlayer(localPlayerId, name: localName, emoji: localEmoji);
  }

  void reset() {
    board = List.filled(9, '');
    allMoves.clear();
  }

  void registerPlayer(String playerId, {String? name, String? emoji}) {
    if (!playersOrdered.contains(playerId)) {
      playersOrdered.add(playerId);
    }
    if (name != null && name.isNotEmpty) _playerNames[playerId] = name;
    if (emoji != null && emoji.isNotEmpty) _playerEmojis[playerId] = emoji;
  }

  void applySnapshot({required List<String> players, required List<String> board, Map<String, Map<String, String>> meta = const {}}) {
    playersOrdered
      ..clear()
      ..addAll(players);
    this.board = List<String>.from(board);
    for (final e in meta.entries) {
      final pid = e.key;
      final m = e.value;
      registerPlayer(pid, name: m['name'], emoji: m['emoji']);
    }
  }

  bool canPlayPosition(int position) {
    return position >= 0 && position < 9 && board[position].isEmpty;
  }

  TicTacToeMove createLocalMove(int position) {
    return TicTacToeMove(
      id: '${localPlayerId}_${DateTime.now().millisecondsSinceEpoch}',
      position: position,
      playerId: localPlayerId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void applyMove(TicTacToeMove move) {
    registerPlayer(move.playerId);
    final existingMove = _findMoveAtPosition(move.position);
    if (existingMove == null) {
      allMoves[move.id] = move;
      board[move.position] = _getPlayerSymbol(move.playerId);
    } else {
      // Conflict resolution: timestamp wins
      if (move.timestamp > existingMove.timestamp) {
        allMoves.remove(existingMove.id);
        allMoves[move.id] = move;
        board[move.position] = _getPlayerSymbol(move.playerId);
      }
    }
  }

  void handleRemoteMove(TicTacToeMove move) {
    applyMove(move);
  }

  TicTacToeMove? _findMoveAtPosition(int position) {
    for (final m in allMoves.values) {
      if (m.position == position) return m;
    }
    return null;
  }

  String _getPlayerSymbol(String playerId) {
    registerPlayer(playerId);
    final idx = playersOrdered.indexOf(playerId);
    const symbols = ['X', 'O', '△', '□', '◇'];
    return symbols[idx.clamp(0, symbols.length - 1)];
  }

  String playerName(String playerId) => _playerNames[playerId] ?? 'Player';
  String playerEmoji(String playerId) => _playerEmojis[playerId] ?? '🙂';
  Map<String, Map<String, String>> get playersMeta => {
        for (final pid in playersOrdered)
          pid: {'name': playerName(pid), 'emoji': playerEmoji(pid)}
      };

  String getStatusText() {
    final winner = _checkWinner();
    if (winner != null) {
      return winner == localPlayerId ? 'You win!' : 'You lose!';
    }
    if (board.every((c) => c.isNotEmpty)) {
      return "It's a draw!";
    }
    return 'Game in progress';
  }

  bool get isOver {
    if (_checkWinner() != null) return true;
    return board.every((c) => c.isNotEmpty);
  }

  String? _checkWinner() {
    const patterns = [
      [0, 1, 2],
      [3, 4, 5],
      [6, 7, 8],
      [0, 3, 6],
      [1, 4, 7],
      [2, 5, 8],
      [0, 4, 8],
      [2, 4, 6]
    ];
    for (final pattern in patterns) {
      final a = board[pattern[0]];
      final b = board[pattern[1]];
      final c = board[pattern[2]];
      if (a.isNotEmpty && a == b && b == c) {
        for (final move in allMoves.values) {
          if (_getPlayerSymbol(move.playerId) == a) {
            return move.playerId;
          }
        }
      }
    }
    return null;
  }
}

// (old duplicate extension removed)
