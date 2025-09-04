# P2P Playground (Flutter + Go FFI, any-sync)

This repository is a playground for us to test and evaluate P2P technologies and app architectures. The current primary experiment is a real-time, peer‑to‑peer TicTacToe application built with Flutter, using a Go FFI bridge to the any-sync protocol. It also contains a legacy `index.html` at the root that is unrelated to the current project (kept for reference).

Goal: Two Flutter instances play TicTacToe over the any-sync network with local‑first moves, real-time sync, and deterministic conflict resolution — no central server.

Key Stack
- Flutter UI → Dart FFI → Go shared library → any-sync network (composed via app.App and components)

Repository Structure
- `tictactoe_anysync/` — main project (any-sync experiment)
  - `go/` — Go FFI bridge and build scripts
  - `lib/` — Flutter app, FFI bindings, and UI
  - `scripts/` — helper scripts for environment checks and docker setup
  - `RESEARCH.md` — notes on any-sync APIs and composition
  - `README.md` — detailed component-level guide
- `tictactoe_gun/` — prior/alternative P2P experiment (GUN-based; optional; see its own README)
- `index.html` — legacy artifact (unrelated to the new P2P app)

Notes on cleanup
- The former `tictactoagun/` folder was removed as part of housekeeping. Any remaining references have been cleared.

Architecture
- Flutter App
  - UI and simple CRDT (local-first; timestamp conflict resolution)
  - Connection settings dialog to edit `host`, `port`, and `networkId`
- Dart FFI
  - Binds Go exports: InitializeClient, CreateSpace, JoinSpace, SendOperation, SetOperationCallback, StartListening, FreeString
- Go FFI Bridge
  - Composes an any-sync client using `app.App` and registers: pool, peerservice, nodeconf (+ source/store), secureservice, streampool, quic, yamux, commonspace
  - Creates/opens spaces via `commonspace.SpaceService`
  - Publishes/receives moves through the KeyValue service (polling-based listener)
- any-sync Network
  - Launched locally via `any-sync-dockercompose` (Docker). App connects to a reachable node address/port

What’s Done
- Go bridge with working composition and FFI API
- Space lifecycle: create, open/join, initialize KeyValue
- Operations: move JSON stored under KeyValue key `moves`
- Receiving: polling loop reads new entries and forwards to Dart callback
- UI: creates a space at startup (shows space ID), supports “Join Space” by ID, connection settings dialog

Assumptions
- Ephemeral account keys via test account service (suitable for demos)
- Minimal node configuration from provided host/port (no discovery)
- Polling listener for simplicity and reliability in a demo context

Local Runbook
1) Prerequisites
   - Go 1.23+ (upstream any-sync uses a 1.24 toolchain)
   - Docker Desktop (for any-sync-dockercompose)
   - Flutter (recent stable)
   - Verify tools: `bash tictactoe_anysync/scripts/check_env.sh`

2) Start any-sync network
   - `bash tictactoe_anysync/scripts/setup_anysync_network.sh`
   - This clones and brings up `any-sync-dockercompose`
   - Note the exposed node ports (TCP/yamux, and QUIC/UDP)

3) Build Go shared library
   - `cd tictactoe_anysync/go && ./build.sh`
   - Produces `../lib/native/anysync_bridge_<platform>.so`

4) Run Flutter app
   - `cd .. && flutter pub get && flutter run`
   - In-app Settings:
     - Host: `127.0.0.1`
     - Port: the node’s exposed TCP (yamux) port (try this first)
     - Network ID: match compose’s network ID (or use the default for initial tests)
   - A new space is created and the space ID is shown

5) Test P2P
   - Launch a second instance/device: `flutter run -d <device-id>`
   - Use “Join Space” with the first instance’s space ID
   - Moves should sync within ~1 second

Troubleshooting
- Go not found: install Go 1.23+ and re-run `./build.sh`
- Docker not running: start Docker Desktop; re-run setup script
- No sync: ensure you used the TCP/yamux port; verify firewall; confirm containers are running
- No incoming moves: ensure StartListening runs (the UI calls this after create/join)

Development Playbook (New Session)
- Quick checks: `bash tictactoe_anysync/scripts/check_env.sh` and `docker ps`
- Ensure Go `.so` exists: `ls tictactoe_anysync/lib/native/anysync_bridge_*`
- Editing:
  - Go composition/FFI: `tictactoe_anysync/go/anysync_bridge.go`
  - Dart FFI + wrapper: `tictactoe_anysync/lib/ffi/anysync_bindings.dart`, `lib/anysync_client.dart`
  - UI/CRDT: `tictactoe_anysync/lib/main.dart`
- Rebuild if Go changed: `cd tictactoe_anysync/go && ./build.sh`
- Run Flutter: `flutter run`

Next Steps / Roadmap
- Persistent keys via `accountservice.ConfigGetter`
- Node discovery via coordinator and better failure handling
- Eventing: push-based callbacks instead of polling
- Stronger CRDT semantics or any-sync trees for deterministic merges
- UX: initial screen (Create vs Join), connection health, richer error reporting

Notes
- The legacy `index.html` is not part of the P2P app; it remains for historical context only

License
- MIT (see LICENSE if present)
