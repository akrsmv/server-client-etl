const express = require('express');
const fs = require('fs/promises'); // Use fs/promises for async/await
const { Pool } = require('pg');

const app = express();
const port = 8000;

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

app.use(express.json());

app.post('/liveEvent', authenticate, async (req, res) => {  // Make the handler async
  const event = req.body;
  try {
    await fs.appendFile('server_events.jsonl', JSON.stringify(event) + '\n'); // Use await
    console.log('[server] Event received and saved', event);
    res.status(201).send({ message: 'Event received' });
  } catch (error) {
    console.error('[server] Error writing to file:', error);
    res.status(500).send({ error });
  }
});

app.get('/userEvents/:userId', async (req, res) => {
  const userId = req.params.userId;
  try {
    const result = await pool.query('SELECT * FROM users_revenue WHERE user_id = $1', [userId]);
    res.json(result.rows);
  } catch (error) {
    console.error('[server] Error fetching user events:', error);
    res.status(500).send({error});
  }
});

app.listen(port, () => {
  console.log(`[server] Server listening on port ${port}`);
});