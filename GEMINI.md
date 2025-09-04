# Gemini Project Context: P2P Playground (TicTacToe with any-sync)

This document provides context for the Gemini AI assistant to understand and effectively assist with this project.

## Project Overview

This repository is a playground for evaluating peer-to-peer (P2P) technologies. The primary project is a real-time, P2P Tic-Tac-Toe application named `tictactoe_anysync`. It's built with Flutter and uses a Go FFI (Foreign Function Interface) bridge to communicate with the `any-sync` protocol. The goal is to enable two Flutter instances to play Tic-Tac-Toe with local-first moves, real-time synchronization, and deterministic conflict resolution, all without a central server.

The repository also contains a legacy project, `tictactoe_gun`, which was a similar experiment using the GUN P2P library. An `index.html` file at the root is also a legacy artifact and is not part of the current P2P application.

## Building and Running

### Prerequisites

*   Go 1.23+
*   Docker Desktop
*   Flutter (recent stable version)

You can verify your environment by running:
```bash
bash tictactoe_anysync/scripts/check_env.sh
```

### Local Runbook

1.  **Start the any-sync network:**
    ```bash
    bash tictactoe_anysync/scripts/setup_anysync_network.sh
    ```
    This command clones and starts the `any-sync-dockercompose` project.

2.  **Build the Go shared library:**
    ```bash
    cd tictactoe_anysync/go && ./build.sh
    ```
    This produces a shared library file in `tictactoe_anysync/lib/native/`.

3.  **Run the Flutter app:**
    ```bash
    cd tictactoe_anysync && flutter pub get && flutter run
    ```
    You can also use the provided script to run the desktop app:
    ```bash
    bash tictactoe_anysync/scripts/run_flutter_desktop.sh
    ```

### Testing P2P

1.  Launch a second instance of the app: `flutter run -d <device-id>`
2.  In the second instance, use the "Join Space" feature and enter the Space ID from the first instance.
3.  Moves made on one device should sync to the other within a second.

## Development Conventions

The development workflow typically involves editing the Go bridge and the Flutter application separately.

*   **Go Bridge:** The main file for the Go FFI bridge is `tictactoe_anysync/go/anysync_bridge.go`. After making changes to this file, you must rebuild the shared library by running `./build.sh` in the `tictactoe_anysync/go` directory.
*   **Flutter App:** The main Flutter application code is in `tictactoe_anysync/lib/main.dart`. The Dart FFI bindings are in `tictactoe_anysync/lib/ffi/anysync_bindings.dart`, and the Dart wrapper for the `any-sync` client is in `tictactoe_anysync/lib/anysync_client.dart`.
*   **Hot-Reload:** Flutter's hot-reload can be used for most UI and Dart-level logic changes. A full restart is required when the Go bridge has been updated.

## Key Files

*   `tictactoe_anysync/README.md`: Detailed documentation for the `tictactoe_anysync` project.
*   `tictactoe_anysync/go/anysync_bridge.go`: The Go FFI bridge that connects to the `any-sync` network.
*   `tictactoe_anysync/lib/main.dart`: The main Flutter application file, containing the UI and game logic.
*   `tictactoe_anysync/lib/anysync_client.dart`: The Dart wrapper for the `any-sync` client, which interacts with the Go bridge.
*   `tictactoe_anysync/scripts/setup_anysync_network.sh`: Script to set up the local `any-sync` network using Docker.
*   `tictactoe_anysync/go/build.sh`: Script to build the Go shared library.

## Architecture

The application follows a three-tiered architecture:

1.  **Flutter UI:** The user interface is built with Flutter. It handles user input and displays the game state. It uses a simple CRDT (Conflict-free Replicated Data Type) for local-first moves with timestamp-based conflict resolution.
2.  **Dart FFI:** A Dart FFI layer loads the Go shared library and binds the C-exported functions, allowing the Flutter app to call the Go functions.
3.  **Go FFI Bridge:** The Go bridge composes an `any-sync` client and exposes functions for creating and joining spaces, sending operations, and listening for updates. It uses the `KeyValue` service in `any-sync` to store and retrieve game moves.

## Legacy Content

*   `tictactoe_gun/`: This directory contains a previous P2P experiment using the GUN library. It is not actively developed but is kept for reference.
*   `index.html`: This is a legacy file and is not related to the `tictactoe_anysync` application.
