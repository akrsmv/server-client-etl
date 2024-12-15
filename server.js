const express = require('express');
const fs = require('fs/promises'); // Use fs/promises for async/await
const { Pool } = require('pg');

const app = express();
const port = 8000;
const PID = process.pid;

const pool = new Pool({
  user: 'postgres',
  host: 'localhost',
  database: 'postgres',
  password: 'postgres',
  port: 5432
});

const authenticate = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (authHeader !== 'secret') {
    return res.status(401).send('Unauthorized');
  }
  next();
};

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
}

app.use(express.json());

app.post('/liveEvent', authenticate, async (req, res) => {  // Make the handler async
  const event = req.body;
  try {
    await fs.appendFile(`server_events_${getPartition()}.jsonl`, JSON.stringify(event) + '\n'); // Use await
    console.log(`[server][${PID}] Event received and saved`, event);
    res.status(201).send({ message: 'Event received' });
  } catch (error) {
    console.error(`[server][${PID}] Error writing to file:`, error.message);
    res.status(500).send({ error });
  }
});

app.get('/userEvents/:userId', async (req, res) => {
  const userId = req.params.userId;
  try {
    const result = await pool.query('SELECT * FROM users_revenue WHERE user_id = $1', [userId]);
    res.json(result.rows);
  } catch (error) {
    console.error(`[server][${PID}] Error fetching user events:`, error.message);
    res.status(500).send({error});
  }
});

app.listen(port, () => {
  console.log(`[server][${PID}] Server listening on port ${port}`);
});