any-sync Research Notes

Summary
- any-sync does not expose a single `NewClient` entrypoint. Instead, applications are composed by creating an `app.App` and registering components (account service, transport, pool, peerservice, consensus/coordinator clients, and `commonspace` services).
- Spaces are created via `commonspace.SpaceService` (`CreateSpace`, `NewSpace`) which is a component within the app.

Key Import Paths
- App container: `github.com/anyproto/any-sync/app`
- Spaces: `github.com/anyproto/any-sync/commonspace`
- Node configuration model: `github.com/anyproto/any-sync/nodeconf`
- Account: `github.com/anyproto/any-sync/accountservice`
- Networking (examples):
  - `github.com/anyproto/any-sync/net/transport/quic`
  - `github.com/anyproto/any-sync/net/transport/yamux`
  - `github.com/anyproto/any-sync/net/pool`
  - `github.com/anyproto/any-sync/net/secureservice`
  - `github.com/anyproto/any-sync/net/peerservice`
- Space synchronization: `github.com/anyproto/any-sync/commonspace/sync`, `github.com/anyproto/any-sync/commonspace/sync/objectsync`, `github.com/anyproto/any-sync/commonspace/headsync`

Space Service
- Interface (excerpt):
  - `CreateSpace(ctx, payload spacepayloads.SpaceCreatePayload) (string, error)`
  - `NewSpace(ctx, id string, deps Deps) (Space, error)`
- Implementation: `commonspace/spaceservice.go`
- Creating/joining a space relies on a running app with registered services and proper config.

Client Construction Pattern (inferred)
1) Create `a := new(app.App)`.
2) Register config component(s) that implement the required `ConfigGetter` interfaces (e.g., account, nodeconf, rpc/transport configs).
3) Register components similar to node bootstrap but for client usage:
   - `accountservice.New()`, network transports (`quic`, `yamux`), `secureservice`, `peerservice`, `pool`, coordinator/consensus clients, and `commonspace.New()`.
4) `a.Start(ctx)` to bring up services.
5) Obtain `SpaceService` via `app.MustComponent[commonspace.SpaceService](a)` and call `CreateSpace` / `NewSpace`.

Operations API (to verify)
- Likely through object trees within `Space` via `TreeBuilder`/`ObjectManager`. Candidates:
  - `Space.TreeBuilder()` / `objecttreebuilder` to create changes
  - `Space.TreeSyncer()` to sync with peers
  - `commonspace/object/keyvalue` for simple key-value ops
- TODO: Identify a minimal API for app-level “publish/subscribe” style operations suitable for TicTacToe moves.

Next Research Actions
- Find a minimal client example (tests or example apps) that registers only the necessary components and performs `CreateSpace` + simple object updates.
- Trace how `keyvalue` objects are created/updated and how they propagate via sync.

