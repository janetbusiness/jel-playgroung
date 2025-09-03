# Repository Guidelines

## Project Structure & Module Organization
- Root: `index.html` (legacy; not used by the P2P app).
- `tictactoe_anysync/`
  - `lib/` Flutter UI, FFI bindings, client wrapper.
  - `go/` FFI bridge; `build.sh` outputs `lib/native/anysync_bridge_<platform>.so`.
  - `scripts/` env checks and any-sync Docker bootstrap.
  - `research/` any-sync experiments and docker-compose assets.
- Tests: Dart in `tictactoe_anysync/test/`; Go tests live under `research` modules where applicable.

## Architecture Overview
- Go FFI bridge: `tictactoe_anysync/go/anysync_bridge.go` composes any-sync (pool, transports, space service) and exports C APIs.
- Dart FFI: `tictactoe_anysync/lib/ffi/anysync_bindings.dart` loads the shared library and wires native exports.
- Client wrapper: `tictactoe_anysync/lib/anysync_client.dart` provides initialize/create/join/send/listen APIs and JSON move handling.
- UI entry: `tictactoe_anysync/lib/main.dart` drives the board, join flow, and settings.

## Build, Test, and Development Commands
- Env check: `bash tictactoe_anysync/scripts/check_env.sh` (tooling + Docker readiness).
- Start any-sync (Docker): `bash tictactoe_anysync/scripts/setup_anysync_network.sh`.
- Build native lib: `cd tictactoe_anysync/go && ./build.sh` (outputs to `lib/native/`).
- Run app: `cd tictactoe_anysync && flutter pub get && flutter run` (re-run build if Go changes).
- Dart tests: `cd tictactoe_anysync && flutter test`.
- Go tests (research): `go test ./...` from the module root.

## Coding Style & Naming Conventions
- Dart: 2-space indent; `UpperCamelCase` types, `lowerCamelCase` members; files use `snake_case.dart` (e.g., `anysync_client.dart`).
- Go: `gofmt` + `go vet`; exported FFI use PascalCase (e.g., `InitializeClient`). Keep the bridge minimal.
- Paths: FFI in `lib/ffi/`; native outputs in `lib/native/`. Do not commit generated `.so` files.

## Testing Guidelines
- Dart: tests in `tictactoe_anysync/test/` named `*_test.dart`; run with `flutter test`.
- Go (research): use `go test ./...`. Prioritize unit tests for board logic and FFI wrappers.

## Commit & Pull Request Guidelines
- Commits: imperative, scoped (e.g., "UI: add move toast"); reference issues `#<id>`.
- PRs: purpose, concise changes, test notes; link issues; screenshots for UI; call out config/script changes.

## Security & Configuration Tips
- No secrets in repo; local any-sync uses test configs.
- Configure host/port/networkId in-app; avoid hardcoding.
- Clean `tictactoe_anysync/lib/native/` before packaging.

## Common Edits
- Transports/peers: adjust registrations in `go/anysync_bridge.go` (pool, peerservice, streampool, quic, yamux); rebuild with `./build.sh`.
- New FFI export: add `//export <Name>` in Go; add typedef/lookup in `lib/ffi/anysync_bindings.dart`; wrap in `lib/anysync_client.dart`.
- Move schema: update `TicTacToeMove` and `toJson()/fromJson()`; keep Go JSON-agnostic unless adding validation.
- Defaults: change `initialize()` host/port/networkId in `lib/anysync_client.dart`.

