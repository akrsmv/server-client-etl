'use strict';

const fs = require('fs');
const fsp = require('fs/promises');
const readline = require('readline');
const crypto = require('crypto');
const axios = require('axios');
const config = require('./config');

const PID = process.pid;
const MAX_RETRY_ATTEMPTS = 10;
const BASE_RETRY_DELAY_MS = 500;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Event identity = (input file inode, 1-based line number, raw line). Retries
// and watch-triggered re-reads of the same file carry the same id and are
// deduped downstream; regenerating the file (new inode) starts a fresh
// identity space so a new experiment is never mistaken for a replay.
const eventId = (ino, lineNumber, line) =>
  crypto.createHash('sha256').update(`${ino}:${lineNumber}:${line}`).digest('hex').slice(0, 32);

const sendEvent = async (event, retryAttempt = 0) => {
  if (retryAttempt > MAX_RETRY_ATTEMPTS) {
    throw new Error(`[client][${PID}] Failed to send event after ${MAX_RETRY_ATTEMPTS} retries`);
  }
  if (retryAttempt > 0) {
    const retryDelay = BASE_RETRY_DELAY_MS * Math.pow(2, retryAttempt);
    console.log(`[client][${PID}] Retrying event ${event.id} after ${retryDelay}ms (attempt ${retryAttempt + 1})`);
    await sleep(retryDelay);
  }
  try {
    await axios.post(`${config.serverUrl}/liveEvent`, event, {
      headers: { Authorization: config.apiToken },
    });
  } catch (error) {
    console.error(`[client][${PID}] Error sending event ${event.id} (attempt ${retryAttempt + 1}): ${error.message}`);
    await sendEvent(event, retryAttempt + 1);
  }
};

const processEventsLineByLine = async () => {
  const stat = await fsp.stat(config.eventsFile).catch(() => null);
  if (!stat) {
    console.log(`[client][${PID}] File ${config.eventsFile} not found.`);
    return;
  }
  const stream = fs.createReadStream(config.eventsFile);
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  let lineNumber = 0;
  for await (const line of rl) {
    lineNumber += 1;
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      console.error(`[client][${PID}] Skipping unparsable line ${lineNumber}`);
      continue;
    }
    event.id = eventId(stat.ino, lineNumber, line);
    try {
      await sendEvent(event); // sequential: preserves file order, which is the demo's point
    } catch (error) {
      console.error(`[client][${PID}] Giving up on line ${lineNumber}: ${error.message}`);
    }
  }
  console.log(`[client][${PID}] Sent ${lineNumber} line(s) from ${config.eventsFile}`);
};

// Watch-and-resend: on `change` the whole file is re-read and re-sent. With
// server-side identity this is now harmless (duplicates dedupe) and stays
// useful for experimenting.
const watchFile = () => {
  let debounce = null;
  try {
    fs.watch(config.eventsFile, (eventType, filename) => {
      if (!filename) return;
      if (eventType === 'rename') {
        // rename also fires on delete: re-arm the whole loop
        console.log(`[client][${PID}] ${config.eventsFile} renamed or deleted; re-arming`);
        setTimeout(start, 1000);
        return;
      }
      if (debounce) return;
      debounce = setTimeout(() => {
        debounce = null;
      }, 500);
      console.log(`[client][${PID}] ${config.eventsFile} changed; re-sending (dedup makes this free)`);
      processEventsLineByLine();
    });
  } catch (error) {
    console.error(`[client][${PID}] Error watching file:`, error.message);
    setTimeout(start, 1000);
  }
};

const start = () => {
  fs.access(config.eventsFile, fs.constants.F_OK, (err) => {
    if (!err) {
      console.log(`[client][${PID}] File found. Processing and watching...`);
      processEventsLineByLine();
      watchFile();
    } else {
      console.log(`[client][${PID}] File ${config.eventsFile} not found. Checking again in 1 second...`);
      setTimeout(start, 1000);
    }
  });
};

start();
