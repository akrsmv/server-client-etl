'use strict';

// Central runtime configuration: every knob is an environment variable with a
// demo default. Copy .env.example to .env to override locally (loaded through
// Node's native process.loadEnvFile — Node >= 20.12, no dependency).
try {
  process.loadEnvFile('.env');
} catch {
  // .env is optional; the defaults below keep the demo self-contained.
}

module.exports = {
  // HTTP edge
  port: Number(process.env.PORT || 8000),
  apiToken: process.env.API_TOKEN || 'secret', // demo default — change for anything real
  // where partition logs and the dead-letter file live
  logDir: process.env.ETL_LOG_DIR || '.',
  deadLetterFile: process.env.DEAD_LETTER_FILE || 'dead_letter.jsonl',
  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS || 5000),
  // client
  serverUrl: process.env.SERVER_URL || 'http://localhost:8000',
  eventsFile: process.env.EVENTS_FILE || 'events.jsonl',
  // Postgres (psql-compatible names)
  pg: {
    user: process.env.PGUSER || 'postgres',
    host: process.env.PGHOST || 'localhost',
    database: process.env.PGDATABASE || 'postgres',
    password: process.env.PGPASSWORD || 'postgres',
    port: Number(process.env.PGPORT || 5432),
  },
};
