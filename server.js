'use strict';

const express = require('express');
const fs = require('fs/promises');
const path = require('path');
const { Pool } = require('pg');
const config = require('./config');
const { validateEvent } = require('./lib/validate');

const app = express();
const PID = process.pid;

const pool = new Pool(config.pg);

// An error on an idle pooled connection (e.g. Postgres restarted) is logged,
// never fatal.
pool.on('error', (err) => {
  console.error(`[server][${PID}] idle database connection error (continuing):`, err.message);
});

app.use(express.json({ limit: '64kb' }));

// Both endpoints sit behind the token. The 2024 code left
// GET /userEvents/:userId open (defect D5).
const authenticate = (req, res, next) => {
  if (req.headers.authorization !== config.apiToken) {
    return res.status(401).send('Unauthorized');
  }
  next();
};

// Time-windowed partition name: the append-only log shards the way a Kafka
// topic partitions, which keeps single files small enough to scan.
const getPartition = () => {
  const timestamp = new Date();
  const year = timestamp.getFullYear().toString().slice(-2);
  const month = (timestamp.getMonth() + 1).toString().padStart(2, '0');
  const day = timestamp.getDate().toString().padStart(2, '0');
  const hours = timestamp.getHours().toString().padStart(2, '0');
  const minutes = timestamp.getMinutes().toString().padStart(2, '0');
  const seconds = timestamp.getSeconds();
  const fiveSecondWindow = Math.floor(seconds / 5).toString().padStart(2, '0');

  return `${year}${month}${day}${hours}${minutes}${fiveSecondWindow}`;
};

app.post('/liveEvent', authenticate, async (req, res) => {
  const invalidReason = validateEvent(req.body);
  if (invalidReason) {
    return res.status(400).json({ error: `invalid event: ${invalidReason}` });
  }
  try {
    await fs.appendFile(
      path.join(config.logDir, `server_events_${getPartition()}.jsonl`),
      JSON.stringify(req.body) + '\n',
    );
    console.log(`[server][${PID}] Event received and saved`, req.body);
    res.status(201).send({ message: 'Event received' });
  } catch (error) {
    console.error(`[server][${PID}] Error writing to file:`, error.message);
    res.status(500).send({ error: 'failed to persist event' });
  }
});

app.get('/userEvents/:userId', authenticate, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT user_id, revenue FROM users_revenue WHERE user_id = $1',
      [req.params.userId],
    );
    res.json(result.rows);
  } catch (error) {
    console.error(`[server][${PID}] Error fetching user events:`, error.message);
    res.status(500).send({ error: 'failed to fetch user revenue' });
  }
});

const server = app.listen(config.port, () => {
  console.log(`[server][${PID}] Server listening on port ${config.port}`);
});

const shutdown = async () => {
  console.log(`[server][${PID}] Shutting down`);
  server.close();
  await pool.end().catch(() => {});
  process.exit(0);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
