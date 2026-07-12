# Design Plan

## Part 1 - MVC Chat Server

### Description

1. A server handles requests from a small range of connections (2 - 1000)
2. Clients login and can view incoming messages and send messages to other users
3. No authentication
4. Messages can be any length
5. Maybe provide user search functionality
6. Maybe make script or program to test client load

### Plan

    Server starts, spawns threads for thread pool. Accept connections then hand
    off to workers.

### Things to Consider

* Each connection needs state
* Read calls might return more or less than a single message, so you buffer
* Stateful Message Aware Reader
* Having Client and Server structs
* thread pool
* timeouts
* decoupling Disk I/O

### Protocl

    Will use binary encoding with a fixed header prefix that will include the
    length of the message and maybe user info. Push update pattern.

    Fixed Header Format (bytes) - Max 16Mb
    +--------------+-----------+----------+---------------+
    |Magic Byte (2)|Version (1)|Opcode (1)|Payload Len (3)|
    +--------------+-----------+----------+---------------+

    Payload Format (TLV) - Max 65K
    +-------+----------+-------------+
    |Tag (1)|Length (2)|Data (Length)|
    +-------+----------+-------------+

### Things to Research

* Async stuff in Zig

### Implementation Plan

#### Phase 1: Networking & Event Loop Foundation

* Initialize the Server: Create and bind the primary network socket so your
    server can listen for incoming connections.  
* Set up the Event Loop: Create your event monitoring system and configure it
    to watch your listening socket for new users.
* Implement Client Connections: When a new user connects, accept the
    connection, set their socket to non-blocking mode, and register them with
    your event loop.  

#### Phase 2: Thread Pool & Concurrency

* Build the Worker Pool: Initialize a set of background worker threads and a
    thread-safe task queue to handle all disk operations.
* Configure Inter-thread Signaling: Register synthetic, user-triggered events
    in your event loop. This gives your background threads a way to notify the
    main network loop when they finish a blocking task.

#### Phase 3: Custom Protocol & Parsing

* Define the Header Parser: Write logic to read the fixed-size packet header,
    validate it to ensure the client is speaking your protocol, and extract the
    size of the incoming data.
* Implement the Payload Decoder: Write the logic to read the rest of the message
    and parse the specific fields, ensuring you enforce a consistent byte order
    across different devices.  

#### Phase 4: Low-Level Storage Engine

* Initialize the Storage Medium: Set up the physical files or memory mappings
    that will hold your chat data.
* Build the In-Memory Index: Create the data structure that maps message IDs to
    their physical disk coordinates. Write a startup routine that loads existing
    data into this index.
* Write the I/O Handlers: Create the specific read and write functions that your
    background thread pool will execute when saving or retrieving messages.

#### Phase 5: Connecting the Chat Logic

* Implement the Send Flow: Update the main loop so that incoming messages are
    packaged into tasks and handed off to the thread pool, freeing the main loop
    to handle other users.
* Implement the Broadcast Flow: When the thread pool signals that a message is
    safely stored, update your index and queue the message to be sent out to the
    intended recipients' sockets.
* Add Connection Management: Implement a heartbeat system. Create a background
    routine that periodically checks for inactive sockets and aggressively
    disconnects users who have silently dropped offline.

#### Phase 6: Advanced Features

* Implement History Fetching: Add logic to process scroll-back requests by
    querying your index, dispatching a read task to the thread pool, and
    streaming the retrieved data back to the client.
* Integrate File Transfers: Set up a secondary mechanism for out-of-band media
    uploads, and use zero-copy kernel transfers to efficiently serve those files
    to users without bogging down your application memory.
