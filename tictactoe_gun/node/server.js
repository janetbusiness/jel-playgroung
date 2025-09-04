import express from 'express';
import Gun from 'gun';
import cors from 'cors';
import { nanoid } from 'nanoid';

const app = express();
app.use(cors());
app.use(express.json());

// In-memory index of known spaces (best-effort)
const spacesIndex = new Set();

const server = app.listen(process.env.PORT || 8765, () => {
  console.log('Relay listening on', server.address().port);
});

const gun = Gun({ web: server, file: 'data' });

app.post('/spaces', (req, res) => {
  const id = `space_${nanoid(10)}`;
  gun.get('spaces').get(id).get('meta').put({ createdAt: Date.now() });
  spacesIndex.add(id);
  res.json({ id });
});

// List known spaces (IDs). Best-effort based on server lifetime.
app.get('/spaces', (req, res) => {
  const out = [];
  for (const id of spacesIndex) out.push({ id });
  res.json({ spaces: out });
});

app.post('/spaces/:id/join', (req, res) => {
  res.json({ ok: true });
});

app.post('/spaces/:id/event', (req, res) => {
  const { id } = req.params;
  const ev = req.body || {};
  ev._ts = Date.now();
  ev._id = ev._id || nanoid(12);
  gun.get('spaces').get(id).get('moves').set(ev);
  res.json({ ok: true });
});

app.get('/spaces/:id/snapshot', (req, res) => {
  const { id } = req.params;
  const moves = [];
  gun.get('spaces').get(id).get('moves').map().once((data) => {
    if (data) moves.push(data);
  });
  setTimeout(() => res.json({ moves }), 200);
});

app.get('/spaces/:id/stream', (req, res) => {
  const { id } = req.params;
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  // Disable proxy buffering for NGINX and friends
  res.setHeader('X-Accel-Buffering', 'no');
  // Hint TCP keep-alive
  try { req.socket.setKeepAlive(true, 15000); } catch (_) {}
  try { req.socket.setNoDelay(true); } catch (_) {}
  res.flushHeaders();
  // Advise client reconnection delay and send periodic heartbeats to prevent idle timeouts
  try { res.write('retry: 5000\n\n'); } catch (_) {}
  const keepAlive = setInterval(() => {
    try {
      // SSE comment line (ignored by clients) keeps the connection warm
      res.write(`: keep-alive ${Date.now()}\n\n`);
      // Also emit a lightweight heartbeat event clients can observe
      res.write(`data: ${JSON.stringify({ type: 'heartbeat', now: Date.now(), spaceId: id })}\n\n`);
    } catch (_) {
      // ignore write errors; connection cleanup happens on 'close'
    }
  }, 15000);
  const write = (obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);
  write({ type: 'hello', spaceId: id, now: Date.now() });
  const space = gun.get('spaces').get(id).get('moves');
  const seen = new Set();
  const handler = space.map().on((data) => {
    if (!data || !data._id) return;
    const k = data._id + ':' + (data._ts || 0);
    if (seen.has(k)) return;
    seen.add(k);
    write({ type: 'event', event: data });
  });
  req.on('close', () => {
    clearInterval(keepAlive);
    try { space.off(); } catch(_){}
    try { gun.off(); } catch(_){}
  });
});
