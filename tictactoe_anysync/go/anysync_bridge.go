package main

// #include <stdlib.h>
// typedef void (*callback_t)(char*);
// static inline void callCallback(callback_t cb, char* s) { if (cb) cb(s); }
import "C"
import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "log"
    "net"
    "os"
    "path/filepath"
    "strconv"
    "sync"
    "sync/atomic"
    "time"
    "unsafe"

    anyapp "github.com/anyproto/any-sync/app"
    "github.com/anyproto/any-sync/app/logger"
    "github.com/anyproto/any-sync/commonspace"
    spaceconfig "github.com/anyproto/any-sync/commonspace/config"
    "github.com/anyproto/any-sync/commonspace/credentialprovider"
    "github.com/anyproto/any-sync/commonspace/deletionmanager"
    "github.com/anyproto/any-sync/commonspace/object/treemanager"
    "github.com/anyproto/any-sync/commonspace/object/tree/objecttree"
    "github.com/anyproto/any-sync/commonspace/object/tree/treestorage"
    "github.com/anyproto/any-sync/commonspace/objecttreebuilder"
    "github.com/anyproto/any-sync/commonspace/headsync"
    "github.com/anyproto/any-sync/commonspace/spacestate"
    "github.com/anyproto/any-sync/commonspace/peermanager"
    "github.com/anyproto/any-sync/commonspace/spacestorage"
    "github.com/anyproto/any-sync/commonspace/object/accountdata"
    "github.com/anyproto/any-sync/commonspace/object/keyvalue/keyvaluestorage"
    "github.com/anyproto/any-sync/commonspace/object/keyvalue/keyvaluestorage/innerstorage"
    kvinterfaces "github.com/anyproto/any-sync/commonspace/object/keyvalue/kvinterfaces"
    kvservice "github.com/anyproto/any-sync/commonspace/object/keyvalue"
    "github.com/anyproto/any-sync/commonspace/syncstatus"
    "github.com/anyproto/any-sync/commonspace/settings"
    "github.com/anyproto/any-sync/commonspace/objectmanager"
    syncsvc "github.com/anyproto/any-sync/commonspace/sync"
    "github.com/anyproto/any-sync/commonspace/deletionstate"
    "github.com/anyproto/any-sync/commonspace/object/treesyncer"
    "github.com/anyproto/any-sync/commonspace/object/acl/syncacl"
    "github.com/anyproto/any-sync/commonspace/object/acl/recordverifier"
    "github.com/anyproto/any-sync/commonspace/acl/aclclient"
    "github.com/anyproto/any-sync/net/peer"
    "github.com/anyproto/any-sync/net/peerservice"
    "github.com/anyproto/any-sync/net/pool"
    rpccfg "github.com/anyproto/any-sync/net/rpc"
    rpcserver "github.com/anyproto/any-sync/net/rpc/server"
    "github.com/anyproto/any-sync/net/streampool"
    "github.com/anyproto/any-sync/net/streampool/streamhandler"
    "storj.io/drpc"
    objectsync "github.com/anyproto/any-sync/commonspace/sync/objectsync"
    "github.com/anyproto/any-sync/commonspace/spacesyncproto"
    "github.com/anyproto/any-sync/commonspace/sync/objectsync/objectmessages"
    "github.com/anyproto/any-sync/net/transport/quic"
    "github.com/anyproto/any-sync/net/transport/yamux"
    "github.com/anyproto/any-sync/net/secureservice"
    "github.com/anyproto/any-sync/node/nodeclient"
    "github.com/anyproto/any-sync/nodeconf"
    // Use local stubs for node configuration source/store
    "github.com/anyproto/any-sync/testutil/accounttest"
    nspeermgr "github.com/anyproto/any-sync-node/nodespace/peermanager"
    "github.com/anyproto/any-sync/util/crypto"
    "github.com/anyproto/any-sync/commonspace/spacepayloads"
    acctsvc "github.com/anyproto/any-sync/accountservice"
    anystore "github.com/anyproto/any-store"
    syncqueues "github.com/anyproto/any-sync/util/syncqueues"
)

// treesyncer stub to satisfy space deps
type noOpTreeSyncer struct{}
func (n *noOpTreeSyncer) Init(a *anyapp.App) error { return nil }
func (n *noOpTreeSyncer) Name() string { return "common.object.treesyncer" }
func (n *noOpTreeSyncer) Run(ctx context.Context) error { return nil }
func (n *noOpTreeSyncer) Close(ctx context.Context) error { return nil }
func (n *noOpTreeSyncer) StartSync() {}
func (n *noOpTreeSyncer) StopSync() {}
func (n *noOpTreeSyncer) ShouldSync(peerId string) bool { return true }
func (n *noOpTreeSyncer) SyncAll(ctx context.Context, p peer.Peer, existing, missing []string) error { return nil }

// noOpStreamHandler satisfies streampool StreamHandler; we rely on direct nodeclient sync instead of stream push
type noOpStreamHandler struct{}
func (n *noOpStreamHandler) Init(a *anyapp.App) error { return nil }
func (n *noOpStreamHandler) Name() string { return streamhandler.CName }
func (n *noOpStreamHandler) OpenStream(ctx context.Context, p peer.Peer) (stream drpc.Stream, tags []string, queueSize int, err error) { return nil, nil, 0, nil }
func (n *noOpStreamHandler) HandleMessage(ctx context.Context, peerId string, msg drpc.Message) error { return nil }
func (n *noOpStreamHandler) NewReadMessage() drpc.Message { return &objectmessages.HeadUpdate{} }

// no-op TreeManager to satisfy commonspace deps
type noOpTreeManager struct{}
func (n *noOpTreeManager) Init(a *anyapp.App) error { return nil }
func (n *noOpTreeManager) Name() string { return treemanager.CName }
func (n *noOpTreeManager) Run(ctx context.Context) error { return nil }
func (n *noOpTreeManager) Close(ctx context.Context) error { return nil }
func (n *noOpTreeManager) GetTree(ctx context.Context, spaceId, treeId string) (objecttree.ObjectTree, error) {
    return nil, fmt.Errorf("not implemented")
}
func (n *noOpTreeManager) ValidateAndPutTree(ctx context.Context, spaceId string, payload treestorage.TreeStorageCreatePayload) error {
    return nil
}
func (n *noOpTreeManager) MarkTreeDeleted(ctx context.Context, spaceId, treeId string) error { return nil }
func (n *noOpTreeManager) DeleteTree(ctx context.Context, spaceId, treeId string) error { return nil }

// no-op PeerManager provider and peer manager
type noOpPeerManagerProvider struct{}
func (n *noOpPeerManagerProvider) Init(a *anyapp.App) error { return nil }
func (n *noOpPeerManagerProvider) Name() string { return peermanager.CName }
func (n *noOpPeerManagerProvider) NewPeerManager(ctx context.Context, spaceId string) (peermanager.PeerManager, error) {
    return &noOpPeerManager{}, nil
}
type noOpPeerManager struct{}
func (n *noOpPeerManager) Init(a *anyapp.App) error { return nil }
func (n *noOpPeerManager) Name() string { return peermanager.CName }
func (n *noOpPeerManager) GetResponsiblePeers(ctx context.Context) ([]peer.Peer, error) { return nil, nil }
func (n *noOpPeerManager) GetNodePeers(ctx context.Context) ([]peer.Peer, error) { return nil, nil }
func (n *noOpPeerManager) BroadcastMessage(ctx context.Context, msg drpc.Message) error { return nil }
func (n *noOpPeerManager) SendMessage(ctx context.Context, peerId string, msg drpc.Message) error { return nil }
func (n *noOpPeerManager) KeepAlive(ctx context.Context) {}

// config component aggregating required getters
type bridgeConfig struct{
    networkId string
    nodeHost string
    nodePort int
}

func (c *bridgeConfig) Init(a *anyapp.App) error { return nil }
func (c *bridgeConfig) Name() string { return "config" }

func (c *bridgeConfig) GetNodeConf() nodeconf.Configuration {
    base := net.JoinHostPort(c.nodeHost, fmt.Sprintf("%d", c.nodePort))
    // Provide both QUIC and YAMUX schemes; peerservice can choose
    addrs := []string{
        "quic://" + base,
        "yamux://" + base,
    }
    return nodeconf.Configuration{
        Id:        c.networkId,
        NetworkId: c.networkId,
        Nodes: []nodeconf.Node{
            { PeerId: "node-1", Addresses: addrs, Types: []nodeconf.NodeType{nodeconf.NodeTypeTree} },
        },
    }
}

func (c *bridgeConfig) GetDrpc() rpccfg.Config { return rpccfg.Config{} }
func (c *bridgeConfig) GetYamux() yamux.Config { return yamux.Config{} }
func (c *bridgeConfig) GetQuic() quic.Config   { return quic.Config{} }
func (c *bridgeConfig) GetSpace() spaceconfig.Config {
    // Reduce background sync activity for demo stability
    return spaceconfig.Config{ GCTTL: 60, SyncPeriod: 0, KeepTreeDataInMemory: true }
}
func (c *bridgeConfig) GetStreamConfig() streampool.StreamConfig {
    return streampool.StreamConfig{
        SendQueueSize:   256,
        DialQueueWorkers: 4,
        DialQueueSize:   64,
    }
}

// nodeConf source/store stubs
type stubNodeConfSource struct{}
func (s *stubNodeConfSource) Init(a *anyapp.App) error { return nil }
func (s *stubNodeConfSource) Name() string { return nodeconf.CNameSource }
func (s *stubNodeConfSource) GetLast(ctx context.Context, currentId string) (nodeconf.Configuration, error) {
    return nodeconf.Configuration{}, nodeconf.ErrConfigurationNotFound
}
func (s *stubNodeConfSource) IsNetworkNeedsUpdate(ctx context.Context) (bool, error) { return false, nil }

type stubNodeConfStore struct{}
func (s *stubNodeConfStore) Init(a *anyapp.App) error { return nil }
func (s *stubNodeConfStore) Name() string { return nodeconf.CNameStore }
func (s *stubNodeConfStore) GetLast(ctx context.Context, netId string) (nodeconf.Configuration, error) {
    return nodeconf.Configuration{}, nodeconf.ErrConfigurationNotFound
}
func (s *stubNodeConfStore) SaveLast(ctx context.Context, c nodeconf.Configuration) error { return nil }

type bridgeClient struct{
    app *anyapp.App
    spaceSvc commonspace.SpaceService
    space commonspace.Space
    store keyvaluestorage.Storage
    kvSync any
    cancel context.CancelFunc
    seenMu sync.Mutex
    seen map[string]struct{}
    demoMode bool
    // status
    statusMu sync.Mutex
    lastSync time.Time
    peerCount int
    nodeHost string
    nodePort int
    networkId string
}

var (
    gClient *bridgeClient
    callbacks = make(map[string]C.callback_t)
    callbackMu sync.RWMutex
    eventQueues = make(map[string][]string)
    eqMu sync.Mutex
)

func initLogger() {
    logger.Config{Production: false, DefaultLevel: "info"}.ApplyGlobal()
}

func defaultSpaceRoot() string {
    // Use a guaranteed user-writable dot folder to avoid sandbox redirects
    if home, err := os.UserHomeDir(); err == nil && home != "" {
        return filepath.Join(home, ".tictactoe_anysync", "spaces")
    }
    if dir, err := os.UserCacheDir(); err == nil && dir != "" {
        return filepath.Join(dir, "tictactoe_anysync", "spaces")
    }
    return filepath.Join(".", "anysync_spaces")
}

// Minimal filesystem-backed SpaceStorageProvider
type fsSpaceStorageProvider struct{
    root string
    stores map[string]anystore.DB
}
func (p *fsSpaceStorageProvider) Init(a *anyapp.App) error { return nil }
func (p *fsSpaceStorageProvider) Name() string { return spacestorage.CName }
func (p *fsSpaceStorageProvider) SpaceExists(id string) bool {
    if id == "" { return false }
    _, err := os.Stat(filepath.Join(p.root, id, "store.db"))
    return err == nil
}
func (p *fsSpaceStorageProvider) WaitSpaceStorage(ctx context.Context, id string) (spacestorage.SpaceStorage, error) {
    if p.stores == nil { p.stores = make(map[string]anystore.DB) }
    if db, ok := p.stores[id]; ok {
        return spacestorage.New(ctx, id, db)
    }
    if !p.SpaceExists(id) { return nil, spacestorage.ErrSpaceStorageMissing }
    dbPath := filepath.Join(p.root, id, "store.db")
    db, err := anystore.Open(ctx, dbPath, nil)
    if err != nil { return nil, err }
    p.stores[id] = db
    return spacestorage.New(ctx, id, db)
}
func (p *fsSpaceStorageProvider) CreateSpaceStorage(ctx context.Context, payload spacestorage.SpaceStorageCreatePayload) (spacestorage.SpaceStorage, error) {
    if p.stores == nil { p.stores = make(map[string]anystore.DB) }
    id := payload.SpaceHeaderWithId.Id
    dir := filepath.Join(p.root, id)
    if err := os.MkdirAll(dir, 0o755); err != nil { return nil, err }
    dbPath := filepath.Join(dir, "store.db")
    db, err := anystore.Open(ctx, dbPath, nil)
    if err != nil { return nil, err }
    p.stores[id] = db
    return spacestorage.Create(ctx, db, payload)
}

//export BridgeInitializeClient
func BridgeInitializeClient(nodeHost *C.char, nodePort C.int, networkId *C.char) C.int {
    host := C.GoString(nodeHost)
    port := int(nodePort)
    network := C.GoString(networkId)
    initLogger()
    log.Printf("Initializing any-sync client: %s:%d, network: %s", host, port, network)

    // Demo mode: bypass any-sync and use in-process echo to avoid crashes while debugging
    if os.Getenv("ANYSYNC_DEMO_MODE") == "1" {
        gClient = &bridgeClient{demoMode: true, seen: make(map[string]struct{})}
        log.Printf("Running in ANYSYNC_DEMO_MODE (no network, in-process echo)")
        return 1
    }

    cfg := &bridgeConfig{networkId: network, nodeHost: host, nodePort: port}
    a := new(anyapp.App)
    // Account: persistent if ANYSYNC_MNEMONIC is provided; otherwise fallback to ephemeral
    var acct *accounttest.AccountTestService
    if mnem := os.Getenv("ANYSYNC_MNEMONIC"); mnem != "" {
        mk := crypto.Mnemonic(mnem)
        base, err := mk.DeriveKeys(0)
        if err != nil {
            log.Printf("mnemonic derive error: %v (falling back to ephemeral account)", err)
            acct = &accounttest.AccountTestService{}
        } else {
            idx := 0
            if s := os.Getenv("ANYSYNC_PEER_INDEX"); s != "" {
                if v, e := strconv.Atoi(s); e == nil { idx = v }
            }
            peerDeriv := base
            if idx != 0 {
                if d, e := mk.DeriveKeys(uint32(idx)); e == nil { peerDeriv = d }
            }
            peerId, _ := crypto.IdFromSigningPubKey(peerDeriv.MasterKey.GetPublic())
            acc := &accountdata.AccountKeys{
                PeerKey: peerDeriv.MasterKey,
                // Share the same signing identity for ACL permissions
                SignKey: base.Identity,
                PeerId:  peerId.String(),
            }
            acct = accounttest.NewWithAcc(acc)
            log.Printf("Using deterministic account (peerId=%s, peerIndex=%d)", acc.PeerId, idx)
        }
    } else {
        acct = &accounttest.AccountTestService{}
    }

    // Ensure storage root exists
    root := defaultSpaceRoot()
    if err := os.MkdirAll(root, 0o755); err != nil {
        log.Printf("Failed to ensure storage root %s: %v", root, err)
    }

    a.Register(cfg).
        Register(acct).
        // Node configuration must be fully available before components that depend on it
        Register(&stubNodeConfSource{}).
        Register(&stubNodeConfStore{}).
        Register(nodeconf.New()).
        // Core networking
        Register(pool.New()).
        Register(&noOpStreamHandler{}).
        Register(peerservice.New()).
        Register(rpcserver.New()).
        Register(secureservice.New()).
        Register(streampool.New()).
        Register(quic.New()).
        Register(yamux.New()).
        Register(nodeclient.New()).
        // Utilities and commonspace deps
        Register(syncqueues.New()).
        Register(credentialprovider.NewNoOp()).
        Register(&noOpTreeManager{}).
        Register(nspeermgr.New()).
        Register(&fsSpaceStorageProvider{root: root}).
        // Full space service (enables fetching remote storage and peering)
        Register(commonspace.New())

    if err := a.Start(context.Background()); err != nil {
        log.Printf("Failed to start any-sync app: %v", err)
        return 0
    }

    gClient = &bridgeClient{app: a, spaceSvc: anyapp.MustComponent[commonspace.SpaceService](a), seen: make(map[string]struct{}), nodeHost: host, nodePort: port, networkId: network}
    log.Printf("Client initialized")
    return 1
}

//export BridgeCreateSpace
func BridgeCreateSpace() *C.char {
    if gClient == nil { return C.CString("") }
    if gClient.demoMode {
        id := fmt.Sprintf("demo-%d", time.Now().UnixNano())
        return C.CString(id)
    }
    ctx := context.Background()
    keys := anyapp.MustComponent[acctsvc.Service](gClient.app).Account()

    masterKey, _, err := crypto.GenerateRandomEd25519KeyPair()
    if err != nil { log.Printf("masterKey err: %v", err); return C.CString("") }
    metaKey, _, err := crypto.GenerateRandomEd25519KeyPair()
    if err != nil { log.Printf("metaKey err: %v", err); return C.CString("") }
    readKey := crypto.NewAES()

    payload := spacepayloads.SpaceCreatePayload{
        SigningKey:     keys.SignKey,
        SpaceType:      "tictactoe",
        ReplicationKey: 1,
        SpacePayload:   nil,
        MasterKey:      masterKey,
        ReadKey:        readKey,
        MetadataKey:    metaKey,
        Metadata:       []byte("tictactoe_meta"),
    }

    // convert to storage payload and create
    id, err := gClient.spaceSvc.CreateSpace(ctx, payload)
    if err != nil { log.Printf("CreateSpace err: %v", err); return C.CString("") }

    // open space
    sp, err := gClient.spaceSvc.NewSpace(ctx, id, commonspace.Deps{
        SyncStatus:     syncstatus.NewNoOpSyncStatus(),
        TreeSyncer:     &noOpTreeSyncer{},
        AccountService: anyapp.MustComponent[acctsvc.Service](gClient.app),
    })
    if err != nil { log.Printf("NewSpace err: %v", err); return C.CString("") }
    if err := sp.Init(ctx); err != nil { log.Printf("Space.Init err: %v", err); return C.CString("") }
    gClient.space = sp
    kv := sp.KeyValue()
    if kv == nil { log.Printf("KeyValue service missing"); return C.CString("") }
    gClient.store = kv.DefaultStore()
    gClient.kvSync = kv
    if err := pushSpaceToNode(ctx, sp); err != nil {
        log.Printf("Space push warning: %v", err)
    }
    return C.CString(id)
}

//export BridgeJoinSpace
func BridgeJoinSpace(spaceId *C.char) C.int {
    if gClient == nil { return 0 }
    if gClient.demoMode {
        return 1
    }
    id := C.GoString(spaceId)
    ctx := context.Background()
    sp, err := gClient.spaceSvc.NewSpace(ctx, id, commonspace.Deps{
        SyncStatus:     syncstatus.NewNoOpSyncStatus(),
        TreeSyncer:     &noOpTreeSyncer{},
        AccountService: anyapp.MustComponent[acctsvc.Service](gClient.app),
    })
    if err != nil { log.Printf("NewSpace err: %v", err); return 0 }
    if err := sp.Init(ctx); err != nil { log.Printf("Space.Init err: %v", err); return 0 }
    gClient.space = sp
    kv := sp.KeyValue()
    gClient.store = kv.DefaultStore()
    gClient.kvSync = kv
    return 1
}

//export BridgeSendOperation
func BridgeSendOperation(spaceId *C.char, operationJson *C.char) C.int {
    if gClient == nil { return 0 }
    if gClient.demoMode {
        id := C.GoString(spaceId)
        msg := C.GoString(operationJson)
        eqMu.Lock()
        eventQueues[id] = append(eventQueues[id], msg)
        eqMu.Unlock()
        return 1
    }
    if gClient.store == nil { return 0 }
    id := C.GoString(spaceId)
    _ = id // space id currently single space in client
    jsonData := C.GoString(operationJson)
    // validate json
    var tmp map[string]any
    if err := json.Unmarshal([]byte(jsonData), &tmp); err != nil { log.Printf("json parse: %v", err); return 0 }
    // key can be a unique id inside JSON to avoid overwrite by same peer; use move id
    key := fmt.Sprintf("moves")
    if err := gClient.store.Set(context.Background(), key, []byte(jsonData)); err != nil {
        log.Printf("kv.Set error: %v", err)
        return 0
    }
    return 1
}

//export BridgeSetOperationCallback
func BridgeSetOperationCallback(spaceId *C.char, callback C.callback_t) {
    id := C.GoString(spaceId)
    callbackMu.Lock()
    callbacks[id] = callback
    callbackMu.Unlock()
    log.Printf("Set callback for space: %s", id)
}

//export BridgeStartListening
func BridgeStartListening(spaceId *C.char) C.int {
    if gClient == nil { return 0 }
    if gClient.demoMode {
        return 1
    }
    if gClient.store == nil { return 0 }
    id := C.GoString(spaceId)
    // polling loop to detect new key-value entries
    _, cancel := context.WithCancel(context.Background())
    gClient.cancel = cancel
    go func(space string){
        for {
            time.Sleep(300 * time.Millisecond)
            _ = gClient.store.Iterate(context.Background(), func(dec keyvaluestorage.Decryptor, key string, values []innerstorage.KeyValue) (bool, error) {
                if key != "moves" { return true, nil }
                for _, v := range values {
                    kp := fmt.Sprintf("%s:%d", v.KeyPeerId, v.TimestampMilli)
                    gClient.seenMu.Lock()
                    if _, ok := gClient.seen[kp]; ok {
                        gClient.seenMu.Unlock()
                        continue
                    }
                    gClient.seen[kp] = struct{}{}
                    // basic cap to prevent unbounded growth
                    if len(gClient.seen) > 10000 {
                        gClient.seen = make(map[string]struct{}, 1024)
                    }
                    gClient.seenMu.Unlock()
                    // decrypt
                    data, err := dec(v)
                    if err != nil { continue }
                    eqMu.Lock()
                    eventQueues[space] = append(eventQueues[space], string(data))
                    eqMu.Unlock()
                }
                return true, nil
            })
            // Opportunistic sync with node peers to pull remote updates if any
            if gClient.space != nil && gClient.kvSync != nil {
                if peers, err := gClient.space.GetNodePeers(context.Background()); err == nil {
                    gClient.statusMu.Lock()
                    gClient.peerCount = len(peers)
                    gClient.statusMu.Unlock()
                    for _, p := range peers {
                        // Call SyncWithPeer if available on the service
                        type syncer interface{ SyncWithPeer(peer.Peer) error }
                        if s, ok := gClient.kvSync.(syncer); ok {
                            _ = s.SyncWithPeer(p)
                            gClient.statusMu.Lock()
                            gClient.lastSync = time.Now()
                            gClient.statusMu.Unlock()
                        }
                    }
                }
            }
        }
    }(id)
    log.Printf("Listening for operations in space: %s", id)
    return 1
}

//export BridgePollOperation
func BridgePollOperation(spaceId *C.char) *C.char {
    id := C.GoString(spaceId)
    eqMu.Lock()
    defer eqMu.Unlock()
    q := eventQueues[id]
    if len(q) == 0 {
        return nil
    }
    msg := q[0]
    if len(q) == 1 {
        delete(eventQueues, id)
    } else {
        eventQueues[id] = q[1:]
    }
    return C.CString(msg)
}

//export BridgeGetStatus
func BridgeGetStatus() *C.char {
    type status struct{
        SpaceId string `json:"spaceId"`
        PeerCount int `json:"peerCount"`
        LastSyncMs int64 `json:"lastSyncMs"`
        NodeHost string `json:"nodeHost"`
        NodePort int `json:"nodePort"`
        NetworkId string `json:"networkId"`
        Connected bool `json:"connected"`
    }
    st := status{}
    if gClient != nil {
        if gClient.space != nil { st.SpaceId = gClient.space.Id() }
        gClient.statusMu.Lock()
        st.PeerCount = gClient.peerCount
        if !gClient.lastSync.IsZero() {
            st.LastSyncMs = gClient.lastSync.UnixMilli()
        }
        gClient.statusMu.Unlock()
        st.NodeHost = gClient.nodeHost
        st.NodePort = gClient.nodePort
        st.NetworkId = gClient.networkId
        st.Connected = true
    }
    b, _ := json.Marshal(st)
    return C.CString(string(b))
}

func pushSpaceToNode(ctx context.Context, sp commonspace.Space) error {
    peers, err := sp.GetNodePeers(ctx)
    if err != nil || len(peers) == 0 { return err }
    desc, err := sp.Description(ctx)
    if err != nil { return err }
    payload := &spacesyncproto.SpacePayload{
        SpaceHeader:            desc.SpaceHeader,
        AclPayload:             desc.AclPayload,
        AclPayloadId:           desc.AclId,
        SpaceSettingsPayload:   desc.SpaceSettingsPayload,
        SpaceSettingsPayloadId: desc.SpaceSettingsId,
    }
    for _, p := range peers {
        conn, e := p.AcquireDrpcConn(ctx)
        if e != nil { continue }
        cl := spacesyncproto.NewDRPCSpaceSyncClient(conn)
        _, e = cl.SpacePush(ctx, &spacesyncproto.SpacePushRequest{Payload: payload})
        p.ReleaseDrpcConn(ctx, conn)
        if e == nil { return nil }
    }
    return fmt.Errorf("space push failed: no peer accepted")
}

//export BridgeFreeString
func BridgeFreeString(str *C.char) {
    C.free(unsafe.Pointer(str))
}

func main() {}

// ---------------- Minimal SpaceService without HeadSync -----------------

type minimalSpaceService struct{
    config spaceconfig.Config
    account acctsvc.Service
    configurationService nodeconf.Service
    storageProvider spacestorage.SpaceStorageProvider
    peerManagerProvider peermanager.PeerManagerProvider
    treeManager treemanager.TreeManager
    app *anyapp.App
}

func newMinimalSpaceService() *minimalSpaceService { return &minimalSpaceService{} }

func (s *minimalSpaceService) Init(a *anyapp.App) error {
    s.config = a.MustComponent("config").(spaceconfig.ConfigGetter).GetSpace()
    s.account = a.MustComponent(acctsvc.CName).(acctsvc.Service)
    s.storageProvider = a.MustComponent(spacestorage.CName).(spacestorage.SpaceStorageProvider)
    s.configurationService = a.MustComponent(nodeconf.CName).(nodeconf.Service)
    s.treeManager = a.MustComponent(treemanager.CName).(treemanager.TreeManager)
    s.peerManagerProvider = a.MustComponent(peermanager.CName).(peermanager.PeerManagerProvider)
    s.app = a
    return nil
}

func (s *minimalSpaceService) Name() string { return "common.commonspace" }

func (s *minimalSpaceService) CreateSpace(ctx context.Context, payload spacepayloads.SpaceCreatePayload) (string, error) {
    storageCreate, err := spacepayloads.StoragePayloadForSpaceCreate(payload)
    if err != nil { return "", err }
    store, err := s.createSpaceStorage(ctx, storageCreate)
    if err != nil {
        if errors.Is(err, spacestorage.ErrSpaceStorageExists) {
            return storageCreate.SpaceHeaderWithId.Id, nil
        }
        return "", err
    }
    id := store.Id()
    _ = store.Close(ctx)
    return id, nil
}

func (s *minimalSpaceService) DeriveSpace(ctx context.Context, payload spacepayloads.SpaceDerivePayload) (string, error) {
    storageCreate, err := spacepayloads.StoragePayloadForSpaceDerive(payload)
    if err != nil { return "", err }
    store, err := s.createSpaceStorage(ctx, storageCreate)
    if err != nil { return "", err }
    id := store.Id()
    _ = store.Close(ctx)
    return id, nil
}

func (s *minimalSpaceService) DeriveId(ctx context.Context, payload spacepayloads.SpaceDerivePayload) (string, error) {
    storageCreate, err := spacepayloads.StoragePayloadForSpaceDerive(payload)
    if err != nil { return "", err }
    return storageCreate.SpaceHeaderWithId.Id, nil
}

func (s *minimalSpaceService) NewSpace(ctx context.Context, id string, deps commonspace.Deps) (commonspace.Space, error) {
    st, err := s.storageProvider.WaitSpaceStorage(ctx, id)
    if err != nil {
        if !errors.Is(err, spacestorage.ErrSpaceStorageMissing) { return nil, err }
        return nil, spacestorage.ErrSpaceStorageMissing
    }

    spaceIsClosed := &atomic.Bool{}
    state := &spacestate.SpaceState{ SpaceId: st.Id(), SpaceIsClosed: spaceIsClosed, TreesUsed: &atomic.Int32{} }
    if s.config.KeepTreeDataInMemory {
        state.TreeBuilderFunc = objecttree.BuildObjectTree
    } else {
        state.TreeBuilderFunc = objecttree.BuildEmptyDataObjectTree
    }

    pm, err := s.peerManagerProvider.NewPeerManager(ctx, id)
    if err != nil { return nil, err }

    app := s.app.ChildApp()
    if deps.AccountService != nil { app.Register(deps.AccountService) }
    var indexer keyvaluestorage.Indexer = keyvaluestorage.NoOpIndexer{}
    if deps.Indexer != nil { indexer = deps.Indexer }
    rv := recordverifier.New()

    app.Register(state).
        Register(deps.SyncStatus).
        Register(rv).
        Register(pm).
        Register(st).
        Register(indexer).
        Register(objectsync.New()).
        Register(syncsvc.NewSyncService()).
        Register(syncacl.New()).
        Register(kvservice.New()).
        Register(deletionstate.New()).
        Register(deletionmanager.New()).
        Register(settings.New()).
        Register(objectmanager.New(s.treeManager)).
        Register(deps.TreeSyncer).
        Register(objecttreebuilder.New()).
        Register(aclclient.NewAclSpaceClient())

    return &minimalSpace{app: app, state: state, storage: st}, nil
}

func (s *minimalSpaceService) createSpaceStorage(ctx context.Context, payload spacestorage.SpaceStorageCreatePayload) (spacestorage.SpaceStorage, error) {
    return s.storageProvider.CreateSpaceStorage(ctx, payload)
}

// minimalSpace implements commonspace.Space but omits HeadSync/sync networking
type minimalSpace struct{
    app *anyapp.App
    state *spacestate.SpaceState
    storage spacestorage.SpaceStorage
}

func (s *minimalSpace) Id() string { return s.state.SpaceId }
func (s *minimalSpace) Init(ctx context.Context) error { return s.app.Start(ctx) }
func (s *minimalSpace) Close() error { return s.app.Close(context.Background()) }
func (s *minimalSpace) TryClose(objectTTL time.Duration) (bool, error) { return true, s.Close() }

// Unused features in this demo; return zero values
func (s *minimalSpace) Acl() syncacl.SyncAcl { return s.app.MustComponent(syncacl.CName).(syncacl.SyncAcl) }
func (s *minimalSpace) StoredIds() []string { return nil }
func (s *minimalSpace) DebugAllHeads() []headsync.TreeHeads { return nil }
func (s *minimalSpace) Description(ctx context.Context) (commonspace.SpaceDescription, error) { return commonspace.SpaceDescription{}, nil }
func (s *minimalSpace) TreeBuilder() objecttreebuilder.TreeBuilder { return s.app.MustComponent(objecttreebuilder.CName).(objecttreebuilder.TreeBuilderComponent) }
func (s *minimalSpace) TreeSyncer() treesyncer.TreeSyncer { return s.app.MustComponent(treesyncer.CName).(treesyncer.TreeSyncer) }
func (s *minimalSpace) AclClient() aclclient.AclSpaceClient { return s.app.MustComponent(aclclient.CName).(aclclient.AclSpaceClient) }
func (s *minimalSpace) SyncStatus() syncstatus.StatusUpdater { return s.app.MustComponent(syncstatus.CName).(syncstatus.StatusUpdater) }
func (s *minimalSpace) Storage() spacestorage.SpaceStorage { return s.storage }
func (s *minimalSpace) KeyValue() kvinterfaces.KeyValueService { return s.app.MustComponent(kvinterfaces.CName).(kvinterfaces.KeyValueService) }
func (s *minimalSpace) DeleteTree(ctx context.Context, id string) error { return s.app.MustComponent(settings.CName).(settings.Settings).DeleteTree(ctx, id) }
func (s *minimalSpace) GetNodePeers(ctx context.Context) ([]peer.Peer, error) { return s.app.MustComponent(peermanager.CName).(peermanager.PeerManager).GetNodePeers(ctx) }
func (s *minimalSpace) HandleStreamSyncRequest(ctx context.Context, req *spacesyncproto.ObjectSyncMessage, stream drpc.Stream) error { return nil }
func (s *minimalSpace) HandleRangeRequest(ctx context.Context, req *spacesyncproto.HeadSyncRequest) (*spacesyncproto.HeadSyncResponse, error) { return nil, nil }
func (s *minimalSpace) HandleMessage(ctx context.Context, msg *objectmessages.HeadUpdate) error { return nil }
