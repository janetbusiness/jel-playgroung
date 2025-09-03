import express from 'express';
import Gun from 'gun';
import cors from 'cors';
import { nanoid } from 'nanoid';

const app = express();
app.use(cors());
app.use(express.json());

const server = app.listen(process.env.PORT || 8765, () => {
  console.log('Relay listening on', server.address().port);
});

const gun = Gun({ web: server, file: 'data' });

app.post('/spaces', (req, res) => {
  const id = `space_${nanoid(10)}`;
  gun.get('spaces').get(id).get('meta').put({ createdAt: Date.now() });
  res.json({ id });
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
  res.flushHeaders();
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
  req.on('close', () => { try { space.off(); } catch(_){} try{ gun.off(); }catch(_){} });
});

