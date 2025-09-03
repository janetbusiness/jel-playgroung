TicTacToe + GUN.js (Flutter + Node)

Overview
- Goal: Real-time, P2P-like TicTacToe using GUN (graph database) as the sync fabric.
- Stack: Flutter UI (desktop/mobile/web) → HTTP + SSE → Node.js relay peer → GUN.js graph.

Architecture
- Node relay (tictactoagun/node):
  - Express + GUN.js.
  - Endpoints: create/join space, post moves/resets.
  - Server-Sent Events (SSE) stream per space to push updates to Flutter clients.
  - GUN handles fanout/merging across relay peers if you connect to more GUN peers.
- Flutter app (tictactoagun):
  - Same gameplay and UI patterns as the any-sync variant: spaces, identity (emoji+name), snapshot-on-join, turn-based enforcement, session-aligned reset.
  - HTTP + SSE client for publish/subscribe.

Runbook
1) Start the Node relay
   - cd tictactoagun/node
   - npm install
   - npm run start
   - Default: http://127.0.0.1:8765 (GUN relay served at /gun)

2) Run Flutter app
   - cd tictactoagun
   - flutter pub get
   - flutter run -d macos  # or -d linux / -d chrome / -d android / -d ios

Config
- In-app Settings, set Relay Host/Port (default 127.0.0.1:8765).

Notes
- To connect to multiple GUN peers, edit node/server.js and add more peers in gun options.
- SSE keeps clients in near-realtime sync; moves/resets are broadcast to all subscribers of a space.

