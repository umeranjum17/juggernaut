-- The ticket tables of the one item store (docs/item-store.md): every field the fleet keeps in Beads, beside the items.
-- Loaded into the same fleet.db after schema.sql (core/item-store/adapters/tickets.py), and never changes it. The store's
-- audit and `jg-item check` hash this file's objects against tickets.sha256 and everything else against schema.sha256.
-- Three tables: ticket and link are the fold of ticket_change, the append-only log; a writer only INSERTs INTO ticket_change.
-- The ticket's id is unique across every home of the host (all homes share the jg- prefix), so v_ticket, the store's views
-- and the open-question rule can read a ticket by its id alone. A change that names an id another home holds is refused.

CREATE TABLE ticket (
  id           TEXT NOT NULL,
  home         TEXT NOT NULL CHECK (length(home) > 0),   -- main, or the Squad Lead home's id: whose store held it
  title        TEXT,
  description  TEXT,                                     -- the body
  priority     INTEGER,
  issue_type   TEXT,                                     -- task, epic, gate, ...
  assignee     TEXT,
  created_at   TEXT,
  closed_at    TEXT,
  close_reason TEXT,
  status       TEXT,                                     -- Beads' own word (open, in_progress, blocked, on_hold, deferred, closed) while Beads is the record
  defer_until  TEXT,                                     -- the dated hold: with status deferred
  external_ref TEXT,                                     -- the pull request pointer
  labels       TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(labels)),     -- JSON list
  metadata     TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)),   -- JSON object, every key kept
  ephemeral    INTEGER NOT NULL DEFAULT 0 CHECK (ephemeral IN (0, 1)),
  UNIQUE (id)
);
CREATE INDEX ticket_status ON ticket(status, priority);

CREATE TABLE link (
  from_id TEXT NOT NULL,                                 -- the dependent ticket
  to_id   TEXT NOT NULL,                                 -- what it depends on or relates to
  type    TEXT NOT NULL CHECK (type IN ('parent-child', 'blocks', 'related')),
  PRIMARY KEY (from_id, to_id, type)
);
CREATE INDEX link_to ON link(to_id, type);

-- The log. row is the ticket as one JSON object (NULL: the ticket was dropped from this store); links is the JSON list of
-- {"to":..., "type":...} the ticket has after the change. source is the outside record: one call writes each ticket once.
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
CREATE UNIQUE INDEX ticket_change_once ON ticket_change(source, id);
CREATE INDEX ticket_change_id ON ticket_change(id, seq);

CREATE TRIGGER ticket_change_home BEFORE INSERT ON ticket_change
BEGIN
  SELECT RAISE(ABORT, 'ticket: that id is held by another home')
    WHERE EXISTS (SELECT 1 FROM ticket WHERE id = NEW.id AND home <> NEW.home);
END;
CREATE TRIGGER ticket_change_final BEFORE UPDATE ON ticket_change BEGIN SELECT RAISE(ABORT, 'ticket_change: a change never changes'); END;
CREATE TRIGGER ticket_change_kept BEFORE DELETE ON ticket_change BEGIN SELECT RAISE(ABORT, 'ticket_change: a change is never erased'); END;

CREATE TRIGGER ticket_apply AFTER INSERT ON ticket_change WHEN NEW.row IS NOT NULL
BEGIN
  INSERT INTO ticket (id, home, title, description, priority, issue_type, assignee, created_at, closed_at, close_reason,
                      status, defer_until, external_ref, labels, metadata, ephemeral)
  VALUES (NEW.id, NEW.home, json_extract(NEW.row, '$.title'), json_extract(NEW.row, '$.description'),
          json_extract(NEW.row, '$.priority'), json_extract(NEW.row, '$.issue_type'), json_extract(NEW.row, '$.assignee'),
          json_extract(NEW.row, '$.created_at'), json_extract(NEW.row, '$.closed_at'), json_extract(NEW.row, '$.close_reason'),
          json_extract(NEW.row, '$.status'), json_extract(NEW.row, '$.defer_until'), json_extract(NEW.row, '$.external_ref'),
          coalesce(json_extract(NEW.row, '$.labels'), '[]'), coalesce(json_extract(NEW.row, '$.metadata'), '{}'),
          coalesce(json_extract(NEW.row, '$.ephemeral'), 0))
  ON CONFLICT (id) DO UPDATE SET
    title = excluded.title, description = excluded.description, priority = excluded.priority, issue_type = excluded.issue_type,
    assignee = excluded.assignee, created_at = excluded.created_at, closed_at = excluded.closed_at,
    close_reason = excluded.close_reason, status = excluded.status, defer_until = excluded.defer_until,
    external_ref = excluded.external_ref, labels = excluded.labels, metadata = excluded.metadata, ephemeral = excluded.ephemeral;
  DELETE FROM link WHERE from_id = NEW.id;
  INSERT OR IGNORE INTO link (from_id, to_id, type)
    SELECT NEW.id, json_extract(value, '$.to'), json_extract(value, '$.type') FROM json_each(NEW.links);
END;
CREATE TRIGGER ticket_drop AFTER INSERT ON ticket_change WHEN NEW.row IS NULL
BEGIN
  DELETE FROM link WHERE from_id = NEW.id;
  DELETE FROM ticket WHERE id = NEW.id;
END;

-- Beads' status words, read from the items once 10b1 makes ticket.status the backlog lifecycle alone (open, deferred, closed):
-- on hold = an open owner question on the ticket; blocked = an open blocker on it, or an open dispatch it waits for;
-- in progress = an open work, land, merge or release item on it.
CREATE VIEW v_ticket_status AS
  SELECT t.id,
    CASE
      WHEN t.status = 'closed' THEN 'closed'
      WHEN EXISTS (SELECT 1 FROM item i WHERE i.subject = t.id AND i.state = 'open' AND i.kind = 'question') THEN 'on_hold'
      WHEN EXISTS (SELECT 1 FROM item i WHERE i.subject = t.id AND i.state = 'open' AND i.kind IN ('blocker', 'dispatch')) THEN 'blocked'
      WHEN EXISTS (SELECT 1 FROM item i WHERE i.subject = t.id AND i.state = 'open' AND i.kind IN ('work', 'land', 'merge', 'release')) THEN 'in_progress'
      WHEN t.status = 'deferred' THEN 'deferred'
      ELSE 'open'
    END AS status
  FROM ticket t;
