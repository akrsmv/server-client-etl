# Data ETL Project (Client-Server)

   Upon initial startup, the 3 processes (client/server/data processor) will only listen and not do anything. Once you follow instructions from __[Testing](#testing)__, the process flow described in the __[Sequence diagram](#sequence-diagram)__ will begin.
   

**How to run**

   ```bash
   npm install

   # Install Postgresql or use a dockerized one. 
   
   # Ensure you have psql also installed and postgres:postgres@localhost:5432/postgres is a valid connection url
   npm run init-db 
   
   npm start
   ```

**Project Summary**

This project implements a basic data ETL process _highlighting the challenges of building a reliable data pipeline without specialized tools like Kafka or AWS SNS/SQS etc_. It consists of three main components:

* **Client (`client.js`):** _(Simulates a Kafka producer)_ 

    * Extracts user revenue update events from a file (`events.jsonl`) and sends them to the server's `/liveEvent` endpoint.

    * Watches for changes on `events.jsonl` file. Refer to [Testing the Project](#testing) for details on generating events and trigger the ETL

* **Server (`server.js`):** _(Simulates a Kafka broker)_

    * Exposes `/liveEvent`. It uses authentication middleware. Every event that `client.js` sends, the `server.js` will append to `server_events.jsonl` file _(Simulates a Kafka topic)_. 
    
    * Exposes `userEvents/:userId` endpoint that returns recor for particular user from db's `users_revenue` table 

* **Data Processor (`data_processor.js`):** _(Simulates Kafka consumer)_ 

    * Every 5 seconds it reads the `server_events.jsonl` file _(poorly simulating Kafka consumer fetching from the Broker)_ and
        * _(Taken approach a.)_ aggregates all revenue updates deltas per user
        * updates database in transaction, per user


**Limitations**

* There are retry mechanisms in place for sending the event to server, and also for updating the database, _however_, if maximum attempts are reached an event will just be left unprocessed

## Sequence diagram
```mermaid
sequenceDiagram
    participant Client
    participant Server
    participant Data Processor
    participant PostgreSQL Database

    Note over Client,Server: generateEvents(N) test script

    Client->>Server: Makes a request
    activate Server
    Server-->>Server: Appends event to server_events.jsonl
    Note right of Server: Event persisted to file

    loop Every 5 Seconds
        Data Processor->>Data Processor: Checks server_events.jsonl for new events
        alt New Events Found
            activate Data Processor
            Data Processor->>Data Processor: Reads new events from file
            alt Multiple Events Received
                loop For each event
                    Data Processor->>Data Processor: updateUsersRevenue(revenueUpdates)
                end
            end

            loop For each userId in revenueUpdates
                Data Processor->>PostgreSQL Database: BEGIN TRANSACTION
                activate PostgreSQL Database

                Data Processor->>PostgreSQL Database: SELECT upsert_user_revenue(userId, updateValue)
                alt Row Lock Available
                    PostgreSQL Database-->>Data Processor: OK
                else Row Lock Blocked
                    PostgreSQL Database-->>Data Processor: Waits for Lock
                    Note right of PostgreSQL Database: Lock wait timeout possible
                end

                alt Transaction Successful
                    Data Processor->>PostgreSQL Database: COMMIT TRANSACTION
                    PostgreSQL Database-->>Data Processor: OK
                else Transaction Fails (e.g., Serialization Error, Lock Timeout)
                    Data Processor->>PostgreSQL Database: ROLLBACK TRANSACTION
                    PostgreSQL Database-->>Data Processor: OK
                    Note right of Data Processor: Transaction for userId is retried
                end
                deactivate PostgreSQL Database

                Note right of Data Processor: Updated ${userId}.
            end
            deactivate Data Processor
        else No New Events
            Note right of Data Processor: No new events to process
        end
    end

    Server-->>Client: Response
    deactivate Server

    Note right of Data Processor: Stores last processed line in processor_offset.txt
```

## Testing

Open a `node` console at the root of the project and paste the below js code.

Then, by invoking `generateEvents(N)` you will generating `events.jsonl` file repeating the example 5 jsonlines `N` times

If you have your project running, upon executing below function: 
    - the `client.js` process will detect changes and will start sending events to `server.js`
    - the `server.js` will __append__ each received event to `server_events.jsonl` file
    - the `data_processor.js` will detect changes and will process __only the newly appended events__ (as it keeps its offset in a separate file `processor_offset.txt`), updating users_revenue table in postgres

Example usage: `generateEvents(200000)` Will produce `events.jsonl` with aprr

```js
function generateEvents(numTimes = 1) {
  const events = [
    { "userId": "user1", "name": "add_revenue", "value": 98 },
    { "userId": "user1", "name": "subtract_revenue", "value": 72 },
    { "userId": "user2", "name": "add_revenue", "value": 70 },
    { "userId": "user1", "name": "add_revenue", "value": 1 },
    { "userId": "user2", "name": "subtract_revenue", "value": 12 },
  ];

  let output = "";
  for (let i = 0; i < numTimes; i++) {
    output += events.map(event => JSON.stringify(event)).join('\n');
    if (i < numTimes - 1) {
      output += '\n';
    }
  }

  fs.writeFileSync('events.jsonl', output);
  console.log(`Generated events.jsonl with ${events.length * numTimes} events.`);
  return numTimes
}
```
