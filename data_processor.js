const fs = require('fs');
const fsPromises = require('fs/promises');
const jsonlines = require('jsonlines');
const { Pool } = require('pg');

const pool = new Pool({
  user: 'postgres',
  host: 'localhost',
  database: 'postgres',
  password: 'postgres',
  port: 5432
});

const offsetFile = 'processor_offset.json';
const EVENT_ADD_REVENUE = 'add_revenue';
const EVENT_SUBTRACT_REVENUE = 'subtract_revenue';
const PID = process.pid;

/**
 * - Checks for files matching the pattern `server_events_*.jsonl`
 * - Keeps offsets per file in `processor_offset.json`
 * - Processes only newly appended events to each file
 */
const start = async () => {
  while (true) {
    console.log(`[data_processor][${PID}] Checking for new events`);
    await checkForChanges();
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
};

const checkForChanges = async () => {
  try {
    const files = await fsPromises.readdir('./');
    const eventsFiles = files.filter(file => file.startsWith('server_events_') && file.endsWith('.jsonl'));

    for (const eventsFile of eventsFiles) {
      await processEvents(eventsFile);
    }

  } catch (err) {
    console.error(`[data_processor][${PID}] Error checking for changes:`, err.message);
  }
};

const processEvents = async (eventsFile) => {
  try {
    const offset = getOffset(eventsFile);
    let currentLine = 0;
    const revenueUpdates = {};
    // TODO make offset a number of bytes, and use it for opening the read stram, as a start offset
    const readStream = fs.createReadStream(eventsFile, { encoding: 'utf8' });
    const jsonStream = jsonlines.parse();

    jsonStream.on('data', (event) => {
      currentLine++;
      if (currentLine <= offset) {
        return; // Already processed, skip it. (See todo above)
      }

      const { userId, name: eventType, value: deltaRevenew } = event;

      if (!revenueUpdates[userId]) {
        revenueUpdates[userId] = { add: 0, subtract: 0 };
      }

      if (eventType === EVENT_ADD_REVENUE) {
        revenueUpdates[userId].add += deltaRevenew;
      } else if (eventType === EVENT_SUBTRACT_REVENUE) {
        revenueUpdates[userId].subtract += deltaRevenew;
      }
    });

    jsonStream.on('end', async () => {
      await updateUsersRevenue(revenueUpdates);
      saveOffset(eventsFile, currentLine);
    });

    jsonStream.on('error', (err) => {
      console.error(`[data_processor][${PID}] Error parsing JSON:`, err.message);
    });

    readStream.on('error', (err) => {
      console.error(`[data_processor][${PID}] Error reading file:`, err.message);
      if (err.code === 'ENOENT') {
        console.log(`[data_processor][${PID}] File ${eventsFile} not found. Waiting for file creation...`);
        saveOffset(eventsFile, 0);
      }
    });

    readStream.pipe(jsonStream);

  } catch (err) {
    console.error(`[data_processor][${PID}] Error in processEvents:`, err);
  }
};

const countLines = async (filePath) => {
  let count = 0;
  const stream = fs.createReadStream(filePath, { encoding: 'utf8' });

  return new Promise((resolve, reject) => {
    stream.on('data', (chunk) => {
      count += chunk.split('\n').length - 1;
    });

    stream.on('end', () => {
      resolve(count);
    });

    stream.on('error', reject);
  });
};

/**
 * Executes DB transaction for updating user revenue.
 * Retries with exponential backoff.
 *
 * @param {Function} operation - The asynchronous operation to retry.
 * @param {number} [maxRetries=10] - The maximum number of retry attempts.
 * @param {number} [baseRetryDelay=500] - The base delay in milliseconds for retries.
 * @returns {Promise<any>} - The result of the operation.
 */
const updateUser = async (userId, revenueDelta, maxRetries = 10, baseRetryDelay = 500) => {
  const executeWithRetry = async (attempt = 0) => {
    if (attempt > maxRetries) {
      throw new Error(`Operation failed after maximum retries`);
    }

    const retryDelay = baseRetryDelay * Math.pow(2, attempt);

    if (attempt > 0) {
      console.log(`[data_processor][${PID}] Retrying operation after ${retryDelay}ms (attempt ${attempt + 1})`);
      await new Promise(resolve => setTimeout(resolve, retryDelay));
    }
    const connection = await pool.connect();
    try {
      await connection.query('BEGIN');
      await connection.query(
          'SELECT upsert_user_revenue($1, $2)',
          [userId, revenueDelta]
      );
      return await connection.query('COMMIT');
    } catch (error) {
      await connection.query('ROLLBACK');
      console.error(`[data_processor][${PID}] Error in operation (attempt ${attempt + 1}):`, error);
      return executeWithRetry(attempt + 1);
    } finally {
      connection.release();
    }
  };

  return executeWithRetry();
};

/**
 * Updates the revenue of users in the database based on the provided revenue updates.
 *
 * @param {Object} revenueUpdates - An object mapping user IDs to revenue changes.
 */
const updateUsersRevenue = async (revenueUpdates) => {
  try {
    for (const userId in revenueUpdates) {
      const { add, subtract } = revenueUpdates[userId];
      const revenueDelta = add - subtract;

      updateUser(userId, revenueDelta);

      console.log(`[data_processor][${PID}] Updated ${userId}.`);
    }

    if (Object.keys(revenueUpdates).length > 0) {
      console.log(`[data_processor][${PID}] Database updated successfully`);
    }

  } catch (error) {
    console.error(`[data_processor][${PID}] Error updating database:`, error.message);
    throw error;
  }
};


const getOffset = (eventsFile) => {
  try {
    const offsetData = JSON.parse(fs.readFileSync(offsetFile, 'utf8'));
    return offsetData[eventsFile] || 0;
  } catch (err) {
    return 0;
  }
};

const saveOffset = (eventsFile, offset) => {
  try {
    const offsetData = JSON.parse(fs.readFileSync(offsetFile, 'utf8'));
    offsetData[eventsFile] = offset;
    fs.writeFileSync(offsetFile, JSON.stringify(offsetData));
  } catch (err) {
    const offsetData = {};
    offsetData[eventsFile] = offset;
    fs.writeFileSync(offsetFile, JSON.stringify(offsetData));
  }
};

start();