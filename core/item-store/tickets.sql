-- The ticket tables of the one item store (docs/item-store.md): every field the fleet keeps in Beads, beside the items.
-- Loaded into the same fleet.db after schema.sql (core/item-store/adapters/tickets.py), and never changes it. The store's
-- audit and `jg-item check` hash this file's objects against tickets.sha256 and everything else against schema.sha256.
-- Six tables: ticket, link, comment and ticket_event are the fold of ticket_change, the append-only log; a writer only INSERTs INTO ticket_change.
-- A ticket is keyed on (home, id): ids are NOT unique across homes (every home mints jg- ids from its own counter), so the
-- same id may be a different ticket in two homes, and one id twice in one home is one row. Every read names its home.

CREATE TABLE ticket (
  id           TEXT NOT NULL,
  home         TEXT NOT NULL CHECK (length(home) > 0),   -- main, or the Squad Lead home's id: whose store held it
  title        TEXT,
  description  TEXT,                                     -- the body
  priority     INTEGER,
  issue_type   TEXT,                                     -- task, epic, gate, ...
  assignee     TEXT,
  created_at   TEXT,
  created_by   TEXT,
  updated_at   TEXT,
  started_at   TEXT,                                     -- when the ticket first went in progress
  closed_at    TEXT,
  close_reason TEXT,
  status       TEXT,                                     -- Beads' own word (open, in_progress, blocked, on_hold, deferred, closed) while Beads is the record
  defer_until  TEXT,                                     -- the dated hold: with status deferred
  external_ref TEXT,                                     -- the pull request pointer
  await_type   TEXT,                                     -- a gate's wait (human, ...)
  labels       TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(labels)),     -- JSON list
  metadata     TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)),   -- JSON object, every key kept
  ephemeral    INTEGER NOT NULL DEFAULT 0 CHECK (ephemeral IN (0, 1)),
  UNIQUE (home, id)
);
CREATE INDEX ticket_status ON ticket(status, priority);

CREATE TABLE link (
  home    TEXT NOT NULL,                                 -- the home of both ends: a link never crosses homes
  from_id TEXT NOT NULL,                                 -- the dependent ticket
  to_id   TEXT NOT NULL,                                 -- what it depends on or relates to
  type    TEXT NOT NULL CHECK (type IN ('parent-child', 'blocks', 'related', 'tracks', 'conditional-blocks', 'waits-for', 'discovered-from', 'replies-to', 'relates-to',
                                  'duplicates', 'supersedes', 'authored-by', 'assigned-to', 'approved-by', 'attests', 'caused-by', 'delegated-from', 'until', 'validates')),
  n          INTEGER NOT NULL DEFAULT 0,                 -- the edge's place in its ticket's dependency list, as the export gave it
  created_at TEXT,                                       -- the edge's own stamp, author and metadata text (Beads keeps '{}'), as the export gave them
  created_by TEXT,
  metadata   TEXT,
  PRIMARY KEY (home, from_id, to_id, type)
);
CREATE INDEX link_to ON link(home, to_id, type);

CREATE TABLE comment (
  home       TEXT NOT NULL,
  ticket_id  TEXT NOT NULL,
  id         TEXT NOT NULL,                              -- Beads' own comment id
  author     TEXT,
  text       TEXT,
  created_at TEXT,
  PRIMARY KEY (home, ticket_id, id)
);
-- A ticket's comment count is never stored: it is the rows of comment.
CREATE VIEW v_ticket_comment_count AS
  SELECT t.home, t.id, (SELECT count(*) FROM comment c WHERE c.home = t.home AND c.ticket_id = t.id) AS comment_count FROM ticket t;

-- A home's memories (bd remember, bd memories): key to text. Not a fold of the log; bd_forms/create.py writes it directly.
CREATE TABLE memory (
  home  TEXT NOT NULL,
  key   TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (home, key)
);

-- The events journal and the provenance log of a ticket, one row per entry. source says which stream (event or provenance), n is the
-- entry's place in that stream, data the whole entry as Beads gave it. A change whose row has no events (or no provenance) key leaves
-- that stream as it was: Beads' export carries neither, so a plain re-export never erases them.
CREATE TABLE ticket_event (
  home      TEXT NOT NULL,
  ticket_id TEXT NOT NULL,
  source    TEXT NOT NULL CHECK (source IN ('event', 'provenance')),
  n         INTEGER NOT NULL,
  kind      TEXT,
  actor     TEXT,
  ref_kind  TEXT,                                        -- provenance: what the ref is (a git sha, a pull request, ...)
  ref       TEXT,
  at        TEXT,
  data      TEXT NOT NULL CHECK (json_valid(data)),
  PRIMARY KEY (home, ticket_id, source, n)
);

-- The log. row is the ticket as one JSON object (NULL: the ticket was dropped from this store); links is the JSON list of
-- {"to":..., "type":..., "created_at":..., "created_by":..., "metadata":...} (the last three when the export gave them) the ticket has after the change, in the export's order. source is the outside record: one call writes each ticket once.
CREATE TABLE ticket_change (
  seq    INTEGER PRIMARY KEY,
  at     INTEGER NOT NULL,
  home   TEXT NOT NULL CHECK (length(home) > 0),
  id     TEXT NOT NULL,
  verb   TEXT NOT NULL CHECK (length(verb) > 0),
  source TEXT NOT NULL CHECK (length(source) > 0),
  row    TEXT CHECK (row IS NULL OR json_valid(row)),
  links  TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(links))
);
CREATE UNIQUE INDEX ticket_change_once ON ticket_change(source, home, id);
CREATE INDEX ticket_change_id ON ticket_change(home, id, seq);

CREATE TRIGGER ticket_change_final BEFORE UPDATE ON ticket_change BEGIN SELECT RAISE(ABORT, 'ticket_change: a change never changes'); END;
CREATE TRIGGER ticket_change_kept BEFORE DELETE ON ticket_change BEGIN SELECT RAISE(ABORT, 'ticket_change: a change is never erased'); END;

CREATE TRIGGER ticket_apply AFTER INSERT ON ticket_change WHEN NEW.row IS NOT NULL
BEGIN
  INSERT INTO ticket (id, home, title, description, priority, issue_type, assignee, created_at, created_by, updated_at,
                      started_at, closed_at, close_reason, status, defer_until, external_ref, await_type, labels, metadata, ephemeral)
  VALUES (NEW.id, NEW.home, json_extract(NEW.row, '$.title'), json_extract(NEW.row, '$.description'),
          json_extract(NEW.row, '$.priority'), json_extract(NEW.row, '$.issue_type'), json_extract(NEW.row, '$.assignee'),
          json_extract(NEW.row, '$.created_at'), json_extract(NEW.row, '$.created_by'),
          json_extract(NEW.row, '$.updated_at'), json_extract(NEW.row, '$.started_at'), json_extract(NEW.row, '$.closed_at'), json_extract(NEW.row, '$.close_reason'),
          json_extract(NEW.row, '$.status'), json_extract(NEW.row, '$.defer_until'), json_extract(NEW.row, '$.external_ref'),
          json_extract(NEW.row, '$.await_type'), coalesce(json_extract(NEW.row, '$.labels'), '[]'), coalesce(json_extract(NEW.row, '$.metadata'), '{}'),
          coalesce(json_extract(NEW.row, '$.ephemeral'), 0))
  ON CONFLICT (home, id) DO UPDATE SET
    title = excluded.title, description = excluded.description, priority = excluded.priority, issue_type = excluded.issue_type,
    assignee = excluded.assignee, created_at = excluded.created_at, created_by = excluded.created_by,
    updated_at = excluded.updated_at, started_at = excluded.started_at, closed_at = excluded.closed_at,
    close_reason = excluded.close_reason, status = excluded.status, defer_until = excluded.defer_until,
    external_ref = excluded.external_ref, await_type = excluded.await_type, labels = excluded.labels, metadata = excluded.metadata, ephemeral = excluded.ephemeral;
  DELETE FROM link WHERE home = NEW.home AND from_id = NEW.id;
  INSERT OR IGNORE INTO link (home, from_id, to_id, type, n, created_at, created_by, metadata)
    SELECT NEW.home, NEW.id, json_extract(value, '$.to'), json_extract(value, '$.type'), key, json_extract(value, '$.created_at'),
           json_extract(value, '$.created_by'), json_extract(value, '$.metadata') FROM json_each(NEW.links);
  DELETE FROM comment WHERE home = NEW.home AND ticket_id = NEW.id;
  INSERT OR IGNORE INTO comment (home, ticket_id, id, author, text, created_at)
    SELECT NEW.home, NEW.id, json_extract(value, '$.id'), json_extract(value, '$.author'), json_extract(value, '$.text'),
           json_extract(value, '$.created_at') FROM json_each(NEW.row, '$.comments');
  DELETE FROM ticket_event WHERE home = NEW.home AND ticket_id = NEW.id AND source = 'event' AND json_type(NEW.row, '$.events') = 'array';
  INSERT INTO ticket_event (home, ticket_id, source, n, kind, actor, ref_kind, ref, at, data)
    SELECT NEW.home, NEW.id, 'event', key, coalesce(json_extract(value, '$.kind'), json_extract(value, '$.type')), json_extract(value, '$.actor'),
           NULL, NULL, coalesce(json_extract(value, '$.created_at'), json_extract(value, '$.at')), value FROM json_each(NEW.row, '$.events');
  DELETE FROM ticket_event WHERE home = NEW.home AND ticket_id = NEW.id AND source = 'provenance' AND json_type(NEW.row, '$.provenance') = 'array';
  INSERT INTO ticket_event (home, ticket_id, source, n, kind, actor, ref_kind, ref, at, data)
    SELECT NEW.home, NEW.id, 'provenance', key, json_extract(value, '$.kind'), json_extract(value, '$.actor'), json_extract(value, '$.ref_kind'),
           json_extract(value, '$.ref'), json_extract(value, '$.created_at'), value FROM json_each(NEW.row, '$.provenance');
END;
CREATE TRIGGER ticket_drop AFTER INSERT ON ticket_change WHEN NEW.row IS NULL
BEGIN
  DELETE FROM link WHERE home = NEW.home AND from_id = NEW.id;
  DELETE FROM comment WHERE home = NEW.home AND ticket_id = NEW.id;
  DELETE FROM ticket_event WHERE home = NEW.home AND ticket_id = NEW.id;
  DELETE FROM ticket WHERE home = NEW.home AND id = NEW.id;
END;

-- Beads' status words, read from the items once 10b1 makes ticket.status the backlog lifecycle alone (open, deferred, closed):
-- on hold = an open owner question on the ticket; blocked = an open blocker on it, or an open dispatch it waits for;
-- in progress = an open work, land, merge or release item on it.
CREATE VIEW v_ticket_status AS
  SELECT t.home, t.id,
    CASE
      WHEN t.status = 'closed' THEN 'closed'
      WHEN EXISTS (SELECT 1 FROM item i WHERE i.subject = t.id AND i.home = t.home AND i.state = 'open' AND i.kind = 'question') THEN 'on_hold'
      WHEN EXISTS (SELECT 1 FROM item i WHERE i.subject = t.id AND i.home = t.home AND i.state = 'open' AND i.kind IN ('blocker', 'dispatch')) THEN 'blocked'
      WHEN EXISTS (SELECT 1 FROM item i WHERE i.subject = t.id AND i.home = t.home AND i.state = 'open' AND i.kind IN ('work', 'land', 'merge', 'release')) THEN 'in_progress'
      WHEN t.status = 'deferred' THEN 'deferred'
      ELSE 'open'
    END AS status
  FROM ticket t;
