-- One row per submitted example. The package itself is in R2 at packages/<id>.manimble.
CREATE TABLE examples (
  id          TEXT PRIMARY KEY,
  status      TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
  title       TEXT NOT NULL,
  authors     TEXT NOT NULL,
  institution TEXT NOT NULL DEFAULT '',
  date        TEXT NOT NULL DEFAULT '',
  keywords    TEXT NOT NULL DEFAULT '[]',   -- JSON array of strings
  description TEXT NOT NULL DEFAULT '',
  size        INTEGER NOT NULL,
  ip_hash     TEXT NOT NULL,
  issue_url   TEXT NOT NULL DEFAULT '',
  created     INTEGER NOT NULL,             -- unix seconds
  reviewed    INTEGER
);
CREATE INDEX examples_status ON examples (status, reviewed);
CREATE INDEX examples_ip ON examples (ip_hash, created);
