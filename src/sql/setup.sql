-- Message-Server DB Schema
CREATE TABLE IF NOT EXISTS User
(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    handle TEXT UNIQUE,
    pwd_hash BLOB
);

CREATE TABLE IF NOT EXISTS Message (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_id INTEGER REFERENCES User(id) ON DELETE CASCADE,
    to_id INTEGER REFERENCES User(id) ON DELETE CASCADE,
    body TEXT,
    timestamp INTEGER, -- Unix Epoch Time
    CONSTRAINT self_send CHECK (from_id <> to_id)
);

CREATE INDEX IF NOT EXISTS handle_index on User (handle);
