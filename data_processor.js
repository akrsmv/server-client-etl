'use strict';

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const readline = require('readline');
const { Pool } = require('pg');
const config = require('./config');
const { validateEvent } = require('./lib/validate');

const PID = process.pid;
const PARTITION_FILE = /^server_events_.*\.jsonl$/;
// Single-processor fence: only one consumer may run (see README limitations).
const ADVISORY_LOCK_KEY = 727420;

const pool = new Pool(config.pg);

// An error on an idle pooled connection (e.g. Postgres restarted) is logged,
// never fatal: active queries fail on their own and the next poll retries.
pool.on('error', (err) => {
  console.error(`[data_processor][${PID}] idle database connection error (continuing):`, err.message);
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Held for the process lifetime on a dedicated connection. A second processor
// exits loudly instead of double-consuming.
const acquireProcessorLock = async () => {
  const client = await pool.connect();
  const { rows } = await client.query('SELECT pg_try_advisory_lock($1) AS acquired', [ADVISORY_LOCK_KEY]);
  if (!rows[0].acquired) {
    client.release();
    console.error(`[data_processor][${PID}] another processor holds the advisory lock; only one may run. Exiting.`);
    process.exit(1);
  }
  return client;
};

// Poison lines never block their partition: they are isolated here with
// partition, byte offset and reason, and processing continues past them.
const deadLetter = async (partition, byteOffset, line, reason) => {
  const entry = JSON.stringify({ ts: new Date().toISOString(), partition, byteOffset, reason, line });
  try {
    await fsp.appendFile(path.join(config.logDir, config.deadLetterFile), entry + '\n');
    console.log(`[data_processor][${PID}] dead-lettered ${partition}@${byteOffset}: ${reason}`);
  } catch (err) {
    console.error(`[data_processor][${PID}] could not write dead-letter entry:`, err.message);
  }
};

// Reads one partition from its committed byte offset, then — in ONE
// transaction — dedups by event id, applies the revenue deltas, records the
// applied ids and advances the offset. Crash anywhere in that unit and the
// whole unit replays cleanly; commit and the unit is exactly-once.
const processPartition = async (partition) => {
  const filePath = path.join(config.logDir, partition);
  let size;
  try {
    size = (await fsp.stat(filePath)).size;
  } catch (err) {
    if (err.code === 'ENOENT') return; // vanished between listing and stat
    throw err;
  }

  const { rows } = await pool.query('SELECT byte_offset FROM processor_offsets WHERE partition = $1', [partition]);
  const committedOffset = rows.length ? Number(rows[0].byte_offset) : 0;
  if (size <= committedOffset) return;

  const events = [];
  let byteOffset = committedOffset;
  // Read only up to the stat-time snapshot: anything appended during our read
  // belongs to the next cycle, and a half-written tail line is never parsed.
  const stream = fs.createReadStream(filePath, { start: committedOffset, end: size - 1, encoding: 'utf8' });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  for await (const line of rl) {
    const lineStart = byteOffset;
    byteOffset += Buffer.byteLength(line, 'utf8') + 1; // + the '\n'
    if (byteOffset > size) {
      // Partial tail (a writer crashed mid-line): stop before it; it is
      // re-read once the line completes.
      byteOffset = lineStart;
      break;
    }
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      await deadLetter(partition, lineStart, line, 'invalid JSON');
      continue;
    }
    const invalidReason = validateEvent(event);
    if (invalidReason) {
      await deadLetter(partition, lineStart, line, invalidReason);
      continue;
    }
    events.push(event);
  }

  if (byteOffset === committedOffset) return; // nothing new (or only a partial tail)

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Within-batch dedup: the same id twice in the unread tail applies once.
    const batchSeen = new Set();
    const fresh = [];
    for (const event of events) {
      if (!batchSeen.has(event.id)) {
        batchSeen.add(event.id);
        fresh.push(event);
      }
    }

    // Cross-run dedup: ids already applied (earlier batch, earlier
    // incarnation, a client retry that actually landed) never apply twice.
    let toApply = fresh;
    if (fresh.length) {
      const applied = await client.query(
        'SELECT event_id FROM applied_events WHERE event_id = ANY($1)',
        [fresh.map((e) => e.id)],
      );
      const appliedIds = new Set(applied.rows.map((r) => r.event_id));
      toApply = fresh.filter((e) => !appliedIds.has(e.id));
    }

    const deltas = new Map();
    for (const event of toApply) {
      const sign = event.name === 'add_revenue' ? 1 : -1;
      deltas.set(event.userId, (deltas.get(event.userId) || 0) + sign * event.value);
    }
    for (const [userId, delta] of deltas) {
      // Atomic upsert — the 2024 UPDATE-then-INSERT function raced itself.
      await client.query(
        `INSERT INTO users_revenue (user_id, revenue) VALUES ($1, $2)
         ON CONFLICT (user_id) DO UPDATE SET revenue = users_revenue.revenue + EXCLUDED.revenue`,
        [userId, Math.round(delta * 10000) / 10000],
      );
    }

    if (toApply.length) {
      await client.query(
        `INSERT INTO applied_events (event_id, partition)
         SELECT unnest($1::text[]), $2 ON CONFLICT (event_id) DO NOTHING`,
        [toApply.map((e) => e.id), partition],
      );
    }

    await client.query(
      `INSERT INTO processor_offsets (partition, byte_offset) VALUES ($1, $2)
       ON CONFLICT (partition) DO UPDATE SET byte_offset = EXCLUDED.byte_offset, updated_at = now()`,
      [partition, byteOffset],
    );

    await client.query('COMMIT');
    console.log(
      `[data_processor][${PID}] ${partition}: applied ${toApply.length} event(s)` +
      ` (${fresh.length - toApply.length} duplicate(s)), offset ${committedOffset} -> ${byteOffset}`,
    );
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
};

const cycle = async () => {
  const entries = await fsp.readdir(config.logDir);
  for (const name of entries.filter((n) => PARTITION_FILE.test(n)).sort()) {
    await processPartition(name);
  }
};

let stopping = false;
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    stopping = true;
  });
}

const main = async () => {
  const lockClient = await acquireProcessorLock();
  console.log(`[data_processor][${PID}] started; polling ${config.logDir} every ${config.pollIntervalMs}ms`);
  while (!stopping) {
    try {
      await cycle();
    } catch (err) {
      console.error(`[data_processor][${PID}] cycle failed (will retry next poll):`, err.message);
    }
    if (!stopping) await sleep(config.pollIntervalMs);
  }
  lockClient.release(true);
  await pool.end();
  process.exit(0);
};

main().catch((err) => {
  console.error(`[data_processor][${PID}] fatal:`, err);
  process.exit(1);
});
