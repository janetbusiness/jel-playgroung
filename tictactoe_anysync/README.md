TicTacToe + any-sync (Flutter + Go FFI)

Overview
- Goal: Real-time, P2P TicTacToe using the any-sync protocol, with a local-first UI and conflict‑free sync.
- Stack: Flutter UI → Dart FFI → Go shared library → any-sync network (composed via app.App and components).

Architecture
- Flutter App
  - TicTacToe UI and minimal CRDT behavior (local-first moves, timestamp conflict resolution).
  - Connection settings dialog to change node `host`, `port`, and `networkId` at runtime.
- Dart FFI
  - Loads platform-specific shared library and binds C-exported functions:
    - InitializeClient, CreateSpace, JoinSpace, SendOperation, SetOperationCallback, StartListening, FreeString.
- Go FFI Bridge
  - Composes an any-sync client using app.App and registers: pool, peerservice, nodeconf (+ source/store), secureservice, streampool, quic, yamux, and commonspace.
  - Creates/opens spaces via commonspace.SpaceService and publishes/reads moves using the KeyValue service.
  - Emits move JSON back to Dart via a polling listener over KeyValue storage.
- any-sync Network
  - Provided by any-sync-dockercompose (Docker). Point the app to a reachable node address/port.

What's New (Sync + Identity)
- Space push on create: the Go bridge now pushes new spaces to the node so other peers can fetch/join immediately.
- Pull reconciliation: periodic KeyValue sync with node peers (no fragile native→Dart callbacks).
- Snapshot on join: a joiner requests snapshot and the creator replies with the current board and player registry.
- Player identity: each client announces a random emoji + first name on join; peers see a “joined” toast and chips with identity.

Repository Layout
- go/anysync_bridge.go: Go bridge and any-sync composition. Exports FFI functions.
- go/go.mod: Requires github.com/anyproto/any-sync v0.9.5.
- go/build.sh: Builds the shared library (lib/native/anysync_bridge_<platform>.so).
- lib/ffi/anysync_bindings.dart: Dart FFI bindings.
- lib/anysync_client.dart: Dart wrapper (initialize, create/join, send, listen).
- lib/main.dart: Flutter UI: board, join flow, connection settings.
- scripts/setup_anysync_network.sh: Clones and starts any-sync-dockercompose.
- scripts/check_env.sh: Prints Go, Docker, Flutter availability.
- RESEARCH.md: Notes on any-sync API and client composition.

Current State (What’s Done)
- Go bridge composes a minimal any-sync client and exposes an FFI API used by Flutter.
- Space lifecycle: create (keys generated), open/join, KeyValue storage initialized.
- Ops: TicTacToe moves are JSON payloads stored under KeyValue key `moves`.
- Receiving: polling loop iterates KeyValue entries and enqueues messages; Dart polls and applies updates.
- UI: Create space on startup, display space ID, join another space by ID, settings for host/port/network.
- Identity: registers player name/emoji; chips display players; snapshot on join aligns boards.

Assumptions & Defaults
- Account keys: uses accounttest.AccountTestService (ephemeral). Replace with persistent keys via accountservice.ConfigGetter for production.
- Node config: minimal config derived from provided host/port; no discovery via coordinator.
- Listener: polling-based for simplicity; periodic pull reconciliation keeps peers in sync.
- Defaults: host=localhost, port=8080, networkId=tictactoe-network (change in-app via settings).

Local Runbook (Step-by-Step)
1) Install prerequisites
   - Go: 1.23+ (any-sync uses a 1.24 toolchain).
   - Docker Desktop: for any-sync-dockercompose.
   - Flutter: recent stable.
   - Validate: `bash scripts/check_env.sh`.

2) Start any-sync network via Docker
   - `bash scripts/setup_anysync_network.sh`
   - Clones any-sync-dockercompose and brings it up with docker compose.
   - Find exposed node ports in compose output (commonly `${ANY_SYNC_NODE_1_PORT}` for TCP/yamux, `${ANY_SYNC_NODE_1_QUIC_PORT}` for QUIC/UDP).

3) Build the Go shared library
   - `cd go && ./build.sh`
   - Output: lib/native/anysync_bridge_macos.so (macOS) or anysync_bridge_linux.so (Linux).

4) Run the Flutter app
   - `cd ..`
   - Optional (shared account across peers):
     - `export ANYSYNC_MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"`
     - Instance A: `ANYSYNC_PEER_INDEX=0 flutter run -d macos`
     - Instance B: `ANYSYNC_PEER_INDEX=1 flutter run -d macos`
   - Or use the desktop runner (sets ANYSYNC_LIB_PATH automatically):
     - `bash scripts/run_flutter_desktop.sh`
   - In-app Settings:
     - Host: `127.0.0.1`
     - Port: the node’s exposed port (try TCP/yamux first)
     - Network ID: match compose’s network ID (or leave default initially)
   - The app creates a new space and shows its ID.

5) Test P2P sync
   - Launch a second instance: `flutter run -d <device-id>`
   - Tap “Join Space” and enter the first instance’s space ID.
   - Tap cells on both devices; moves sync within ~1s.

Troubleshooting
- Go build fails: install Go 1.23+ and re-run build.sh
- Network issues: ensure compose is running; verify ports; try TCP/yamux port first; check firewall.
- No moves received: confirm "Peers" > 0 in the Debug banner; make a move to trigger Sync; ensure SendOperation returns 1.
- Mnemonic errors: use a valid BIP‑39 phrase (12/15/18/21/24 words). The example above is valid for demos.

Debugging & Status
- Toggle “Show Debug Banner” and “Verbose Status Logs” in Settings (gear icon).
- Banner shows: Node host:port, Peers count, Last sync time, Space ID.
- Console logs (when enabled) print status every second.

Development Playbook (New Session)
- Quick checks: `bash scripts/check_env.sh`; `docker ps` for network; confirm `lib/native/anysync_bridge_*` exists.
- Change code:
  - Go bridge: go/anysync_bridge.go (composition, space ops, listener)
  - FFI/Dart client: lib/ffi/anysync_bindings.dart, lib/anysync_client.dart
  - UI/CRDT: lib/main.dart
- Rebuild/run:
  - If Go changed: `cd go && ./build.sh`
  - Flutter: `flutter run` or hot-reload

Next Steps (Roadmap)
- Keys: replace test account with persistent keys via accountservice.ConfigGetter.
- Discovery: use coordinator for node discovery; handle multiple nodes and failover.
- Eventing: move from polling to push callbacks where possible.
- CRDT: strengthen conflict resolution (or map to any-sync object trees).
- UX: initial screen (Create vs Join), better error surfaces and health indicators.
- CI/Tests: add build checks for Go/Flutter and unit tests for core logic.

Design Notes
- Simplicity first: polling KeyValue for demo reliability; explicit host/port settings.
- Clear separation: Flutter remains protocol-agnostic; Go encapsulates any-sync.
- JSON payloads: easy to debug and evolve; can switch to compact schema later.

Versioning
- any-sync: github.com/anyproto/any-sync v0.9.5
- Go: >= 1.23 (upstream uses toolchain 1.24)
