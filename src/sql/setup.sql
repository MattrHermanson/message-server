-- Message-Server DB Schema
CREATE TABLE IF NOT EXISTS User
(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    handle TEXT UNIQUE,
    pwd_hash BLOB
);

CREATE INDEX IF NOT EXISTS handle_index on User (handle);
