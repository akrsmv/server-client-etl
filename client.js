const fs = require('fs');
const readline = require('readline');
const axios = require('axios');

/**
 * The input file to read events from
 */
const eventsFile = 'events.jsonl';
const PID = process.pid;

const sendEvent = async (event, retryAttempt = 0) => {
  const MAX_RETRY_ATTEMPTS = 10;
  const BASE_RETRY_DELAY = 500;

  if (retryAttempt > MAX_RETRY_ATTEMPTS) {
    throw new Error(`[client][${PID}] Failed to send event after maximum retries`);
  }

  const retryDelay = BASE_RETRY_DELAY * Math.pow(2, retryAttempt);

  if (retryAttempt > 0) {
    console.log(`[client][${PID}] Retrying event after ${retryDelay}ms (attempt ${retryAttempt + 1})`);
    await new Promise(resolve => setTimeout(resolve, retryDelay));
  }

  try {
    await axios.post('http://localhost:8000/liveEvent', event, {
      headers: {
        Authorization: 'secret',
      },
    });
    console.log(`[client][${PID}] Event sent.`);
  } catch (error) {
    console.error(`[client][${PID}] Error sending event (attempt ${retryAttempt + 1})`);
    await sendEvent(event, retryAttempt + 1); // Recursive retry
  }
};

const processEventsLineByLine = async () => {
  try {
    // Check if the file exists before attempting to read it
    if (!fs.existsSync(eventsFile)) {
      console.log(`[client][${PID}] File ${eventsFile} not found.`);
      return;
    }

    const fileStream = fs.createReadStream(eventsFile);
    const rl = readline.createInterface({
      input: fileStream,
      crlfDelay: Infinity
    });

    for await (const line of rl) {
      try {
        const event = JSON.parse(line);
        await sendEvent(event);
      } catch (error) {
        console.error(`[client][${PID}] Error processing event:`, error.message);
      }
    }
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.log(`[client][${PID}] File ${eventsFile} not found.`);
    } else {
      console.error(`[client][${PID}] Error processing events:`, error.message);
    }
  }
};

const start = () => {
  const checkFileAndStartWatching = () => {
    fs.access(eventsFile, fs.constants.F_OK, (err) => {
      if (!err) {
        console.log(`[client][${PID}] File found. Starting processing and watching...`);
        processEventsLineByLine(); // Process events line by line
        watchFile();
      } else {
        console.log(`[client][${PID}] File ${eventsFile} not found. Checking again in 1 second...`);
        setTimeout(checkFileAndStartWatching, 1000);
      }
    });
  };

  checkFileAndStartWatching();
};

const watchFile = () => {
  let watcher;
  if (watcher) {
    watcher.close();
  }

  let changeEventReceivedInLast500ms = false;
  try {
    watcher = fs.watch(eventsFile, (eventType, filename) => {
      if (filename) {
        console.log(`[client][${PID}] File ${filename} event type: ${eventType}`);
        if (eventType === 'rename') { // 'rename' event also occurs on delete
          console.log(`[client][${PID}] ${eventsFile} was renamed (or deleted). Restarting watch process...`);

          // Start watching again, after a delay, to avoid rapid loops
          setTimeout(start, 1000);

        } else if (!changeEventReceivedInLast500ms && eventType === 'change') {
          changeEventReceivedInLast500ms = true;
          console.log(`[client][${PID}] ${eventsFile} changed. Reprocessing events...`);
          processEventsLineByLine(); // Reprocess events line by line
          setTimeout(() => changeEventReceivedInLast500ms = false, 500);
        }
      } else {
        // Filename is null, which can also indicate file deletion on some systems
        console.log(`[client][${PID}] ${eventsFile} was possibly deleted. Restarting watch process...`);

        // Start watching again, after a delay, to avoid rapid loops
        setTimeout(start, 1000);
      }
    });
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.log(`[client][${PID}] File ${eventsFile} not found. Restarting watch process...`);
      setTimeout(start, 1000);
    } else {
      console.error(`[client][${PID}] Error watching file:`, error);
    }
  }
};

start();