-- The item store: one SQLite file per host for everything the fleet owes (docs/item-store.md).
-- One file per host. Four tables (item, move, cursor, policy). The rules are read-only views (kind and rung, and the alert ladder's views):
-- a view cannot be written, so a rule changes only by a reviewed edit of this file (a migration).
-- One noun: an ITEM is one thing someone owes, by when. Every item has the same three states
-- (open, done, dropped) and the same five moves (open, note, hand, climb, close).
-- Writers only INSERT INTO move. Triggers check the move, then apply it to item in the same
-- transaction, so the move log is the one input and item is its fold (rebuilt and compared by the tick).
-- Fleet words only: work item, ticket, lane, worker, lead, Main, owner.
--
-- Every writer is `jg-item`. On each connection it registers host_now() (the host clock, epoch seconds) and sets
-- PRAGMA recursive_triggers = ON; it stamps every move's `at` from the host clock, its `frame` from the same reading (the
-- boot id and the host clock minus the boot clock), and its `by` from where it runs
-- (the home, and the lane from JG_TASK_ID); it never takes `by` as an argument. That stops mistakes, not a deliberate
-- writer: JG_HOME and JG_TASK_ID can be set by anyone on the host. So the tick's stamp check compares every owner and
-- adapter stamp, as the pair (message id, item key), with that channel's own log, and every tick drop with the state
-- of its subject, and opens a security item on any mismatch. Only the chat bridge, the board adapter and the policy
-- import (version 1 only, in the one cut-over run) stamp `owner:<channel>`. A land, merge, release, main-down or reply
-- closes done only by its own adapter, whose own record the stamp check reads. A connection without host_now()
-- cannot write a move or a policy version.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------- the fixed ladder (read-only)
-- holder: who holds an item now. next: where it climbs when its time runs out. rank: the order.
-- deadline_s: the time limit after an item lands on this rung (and the cap for a named first holder).
CREATE VIEW rung(holder, next, rank, deadline_s, means) AS VALUES
  ('worker',  'lead',  0,   3600, 'the lane''s own worker'),
  ('outside', 'lead',  0, 604800, 'nobody in the fleet: CI, a quota, a date; rechecked at its due time'),
  ('tick',    'main',  0,    600, 'the machine: it acts by itself (yolo merges, landings, releases)'),
  ('lead',    'main',  1,   7200, 'the home''s lead (Main itself in Main''s own home)'),
  ('main',    'owner', 2,   3600, 'Main'),
  ('owner',   NULL,    3,  86400, 'the owner, the final authority');

-- ---------------------------------------------------------------- the kinds (read-only)
-- first: the first holder (named = the opener names it, capped by the rung's limit).
-- deadline_s: the first time limit (cap). ceiling: the highest rung it may climb to.
-- proof: the prefixes a done close must start with ('|' separates). closer: who may close it done:
--   owner   = only a move stamped by an owner channel (by LIKE 'owner:%')
--   adapter:<name> = only that adapter, from its own record (the stamp check reads that record)
--   ladder  = its holder, its raiser, the lane's own worker, anyone ranked above its holder, or an adapter
--   The tick closes done only an alert it opened itself (clock, schema, fold); it drops on a true reason.
CREATE VIEW kind(kind, first, deadline_s, ceiling, proof, closer, means) AS VALUES
  ('tell',      'main',     1800, 'main',    'sent:',              'adapter:chat',        'Main owes the owner a reply (closed done only by the chat adapter''s sent record)'),
  ('question',  'owner',   86400, 'owner',   'owner:',             'owner',   'a call only the owner can make'),
  ('dispatch',  'lead',    86400, 'main',    'lane:',              'ladder',  'a ticket approved to start, or one a live lane waits for'),
  ('work',      'worker', 604800, 'main',    'receipt:|report:',   'ladder',  'a lane doing a ticket (silence is the stuck-worker alert''s job; a week is the review)'),
  ('wait',      'named',  604800, 'main',    'answer:',            'ladder',  'a lane waits on its lead, Main or outside'),
  ('steer',     'named',    1800, 'main',    'handled:',           'ladder',  'a message a worker or lead must act on'),
  ('report',    'main',     3600, 'main',    'acted:',             'ladder',  'a finished Recon Main must act on'),
  ('alert',     'named',    3600, 'main',    'gone:',              'ladder',  'a fault whose own check must show it gone'),
  ('security',  'main',      900, 'owner',   'contained:',         'ladder',  'a credential or security finding'),
  ('main-down', 'main',      900, 'owner',   'back:',              'adapter:supervision', 'Main''s supervision is not running'),
  ('land',      'tick',     1800, 'main',    'trunk:',             'adapter:trunk',       'a proved commit to put on the local trunk; key land:<home>/<ticket>@<head>'),
  ('merge',     'tick',     3600, 'main',    'merged:',            'adapter:merge',       'a green pull request to merge; key merge:<home>/<ticket>@<pull request>'),
  ('release',   'tick',     3600, 'main',    'released:',          'adapter:trunk',       'a release pull request to put In use and Released; key release:<project>@<release pull request>'),
  ('update',    'lead',     7200, 'main',    'home-at:',           'ladder',  'one home to run a released tip'),
  ('cleanup',   'lead',     3600, 'main',    'cleaned:',           'ladder',  'a finished lane''s copy to return'),
  ('rule',      'outside',2592000,'outside', 'owner:',             'owner',   'an owner standing rule or bypass, in force until its end date'),
  ('intake',    'main',     3600, 'main',    'filed:',             'ladder',  'an arrival no adapter could sort'),
  ('blocker',   'named',    7200, 'main',    'gone:',              'ladder',  'a red check or other fault that holds a step back; it names that step (parent) and closes done in the same write as the step''s done close');

-- ---------------------------------------------------------------- the alert ladder (read-only)
-- What bin/jg-alert.sh reads: the alert ladder, as rules of the store (it replaced the alert table).
-- alert_kind: each alert's precedence (P0 first) and its first rung (0 tick, 1 worker, 2 lead, 3 Main, 4 owner; 'wait' = the one the wait
--   names). fires_at is seconds, 'beats:N' or 'limit' (the limit of its kind, see alert_limit).
-- alert_ladder: per precedence, the seconds to the next rung (step_s), the seconds between repeats (repeat_s), the top rung ('start+2' =
--   two rungs above the first, at most 3), the candidate lift fact (never authority; '-' = none) and the repeats at the top rung
--   before one derived recovery (repeats_at_top).
-- alert_limit: the slow-delivery limit in seconds for a kind of work (0 = none): stranded, stranded-release, every ship-* and recon-* kind.
CREATE VIEW alert_kind(alert, precedence, first_rung, fires_at) AS VALUES
  ('security',          'P0', '4',    '0'),
  ('line-red',          'P1', '2',    '0'),
  ('supervision-down',  'P1', '1',    'beats:2'),
  ('stuck-wait',        'P2', 'wait', '0'),
  ('lost-worker',       'P2', '0',    '900'),
  ('capacity',          'P2', '1',    '0'),
  ('undelivered',       'P2', '2',    '300'),
  ('drift',             'P2', '2',    '600'),
  ('slow-delivery',     'P3', '1',    'limit'),
  ('ready-idle',        'P3', '2',    '600'),
  ('stranded',          'P3', '2',    'limit'),
  ('parked-lane',       'P3', '2',    '0'),
  ('host',              'P3', '3',    '0'),
  ('wrong-repo',        'P2', '2',    '0'),
  ('lock-held',         'P1', '0',    '300'),
  ('orphan-process',    'P3', '0',    '0'),
  ('escalation-stuck',  'P1', '3',    '0'),
  ('fleet-blocked',     'P1', '0',    '0'),
  ('quota-unused',      'P2', '0',    '1800'),
  ('quota-blind',       'P2', '0',    '1800'),
  ('worker-stopped',    'P1', '3',    '0'),
  ('judge-split',       'P1', '2',    '0');

CREATE VIEW alert_ladder(precedence, step_s, repeat_s, top, lift, repeats_at_top) AS VALUES
  ('P0',   0,  600, '4',       '-',            3),
  ('P1', 300,  600, '4',       '-',            3),
  ('P2', 300,  600, 'start+2', 'owner-answer', 3),
  ('P3',   0, 3600, '3',       '-',            3);

CREATE VIEW alert_limit(kind, limit_s) AS VALUES
  ('stranded',          172800),
  ('stranded-release',   14400),
  ('ship-delivering',      300),
  ('ship-proving',         900),
  ('ship-reviewing',       900),
  ('recon-standard',       600),
  ('recon-deep',             0);

-- What the alert table also held, as the same kind of rule: the text of each alert (fires on; quiet when, facts joined by +), the rules
-- that keep one cause from raising many (I1 to I6; I6 holds rung 4 while presence is away), the recipient ceiling of each authority class,
-- and the typed producers allowed to raise a security alert. bin/jg-alert.sh and the table engine read them through core/item-store/alertrules.py.
CREATE VIEW alert_text(alert, fires_on, quiet_when) AS VALUES
  ('security', 'a secret in the open, a refused delete, an owner detail found, an unregistered check', 'never'),
  ('line-red', 'health red on the trunk tip, a release or main; or the tip is above the green pin and no verify has started (900 s)', 'verify-running'),
  ('supervision-down', 'a supervisor session not watching or handling while work is under way', 'never'),
  ('stuck-wait', 'wait is worker, lead or main', 'wait=owner+wait=outside,reason=ci|date|approval|review|quota+reason=parked'),
  ('lost-worker', 'health lost, or stage building or proving with no sign of life', 'wait=worker|lead|main|owner|outside|tick'),
  ('capacity', 'wait reason quota: a quota, an account, a model, no machine slot', 'never'),
  ('undelivered', 'a message stored or rung and not read', 'home-parked'),
  ('drift', 'the observer finds that the stage and the records disagree', 'never'),
  ('slow-delivery', 'stage proving, or delivering in queued, rebased or gated, past the limit for its kind', 'wait=owner+wait=outside,reason=ci|approval|date|review+queued-behind-running-landing'),
  ('ready-idle', 'a ticket in ready and a free lane', 'home-paused+capacity-held+owner-card-open'),
  ('stranded', 'stage delivering in batched, live or joining; or a pull request style in queued with no check started', 'never'),
  ('parked-lane', 'a parked lane whose work is not on the trunk and whose next step its lead has not taken', 'never'),
  ('host', 'memory, disk or temp space over its limit', 'never'),
  ('wrong-repo', 'a spawn refused because the ticket''s files are not in this repository', 'never'),
  ('lock-held', 'a trunk or landing lock held with no beat of its holder', 'holder-beating'),
  ('orphan-process', 'a process past its limit whose owner record is gone', 'never'),
  ('escalation-stuck', 'an alert at its top rung past its repeats; a wake not acknowledged for 20 min at a supervisor; or 10 decision records older than 30 min at Main', 'never'),
  ('fleet-blocked', 'the last-rung conditions B1 to B7 of the self-healing plan (nothing lands, idle with ready work, no account, a supervisor down, the host, paid limits unused)', 'never'),
  ('quota-unused', 'the share of an account''s window that is left is over the share of its time by 20 points, and a ticket can start', 'host-at-stop+account-on-hold'),
  ('quota-blind', 'the newest quota reading of an account that lanes use is old', 'account-no-lane'),
  ('worker-stopped', 'an agent that someone waits for was ended or lost: an unread steer in its inbox, a steer newer than its last status line, an open Recon critic round, or a relaunch after its done line', 'never'),
  ('judge-split', 'two judges (the tip run, the verify, the nightly run) gave one commit tree two different verdicts', 'never');

CREATE VIEW alert_rule(id, covers, scope, quieted, why) AS VALUES
  ('I1', 'supervision-down', 'home', 'stuck-wait,lost-worker,undelivered,ready-idle,slow-delivery', 'nobody is watching, so every wait would fire'),
  ('I2', 'line-red', 'project', 'slow-delivery,stranded', 'they wait for the line, not for themselves'),
  ('I3', 'capacity', 'route', 'lost-worker,stuck-wait', 'the lanes are stopped by the same cause'),
  ('I4', 'host', 'machine', 'slow-delivery', 'a loaded machine is slow'),
  ('I5', '*', 'ticket', '*', 'one page for one ticket'),
  ('I6', 'presence=away', 'home', 'rung-4:P1,P2,P3,!escalation-stuck', 'the return brief lists them; P0 still reaches the owner');

CREATE VIEW alert_authority(class, ceiling) AS VALUES
  ('team-action', '3'),
  ('owner-call', '4'),
  ('security-awareness', '4');

CREATE VIEW alert_security_source(source) AS VALUES
  ('key-in-env'),
  ('delete-guard'),
  ('owner-details-scan'),
  ('unauthenticated-state-checks');

-- ---------------------------------------------------------------- the move log (append-only; the one write path)
CREATE TABLE move (
  seq        INTEGER PRIMARY KEY,
  at         INTEGER NOT NULL,                       -- epoch seconds, from the host clock (jg item stamps it; never an argument)
  verb       TEXT NOT NULL CHECK (verb IN ('open','note','hand','climb','close')),
  key        TEXT NOT NULL,                          -- the cause: the same cause gives the same key
  kind       TEXT,                                   -- open only
  home       TEXT,                                   -- open only: whose ladder it climbs
  subject    TEXT,                                   -- open only: the ticket, lane, project or note it is about
  project    TEXT,                                   -- open only: whose policy row applies (work, land, merge, release: no row refuses work and keeps a step with him)
  parent     TEXT,                                   -- open only: the key of the item that led to it
  by         TEXT NOT NULL CHECK (length(by) > 0),   -- role:id from where the writer runs: worker:muxr/jg-abc, lead:muxr, main, owner:telegram, tick, adapter:alerts
  source     TEXT,                                   -- the outside record this move came from: the idempotency key
  holder     TEXT,                                   -- open, hand, climb: the holder after the move
  holder_id  TEXT,                                   -- which worker, lead, Main or owner
  due_at     INTEGER,                                -- open, hand, climb: the deadline after the move
  ends       TEXT CHECK (ends IS NULL OR ends IN ('done','dropped')),   -- close only
  why        TEXT,                                   -- open: what is owed; hand: the reason; close: the proof or the reason; note: the text
  options    TEXT,                                   -- open of a question only: the picks he is offered, 'a|b|c'; his close names one (pick=<x>)
  page       TEXT,                                   -- whom this move wakes (a holder id), or NULL
  frame      TEXT,                                   -- the writer's clock frame, read with `at`: <boot id>:<host clock minus the boot clock, s>.
                                                     -- A clock leap moves an open deadline by the change since its own last deadline move
  CHECK ((verb = 'close') = (ends IS NOT NULL)),      -- only a close carries an end
  CHECK (verb <> 'close' OR coalesce(length(why), 0) > 0)   -- and a close always carries its proof or reason
);
CREATE UNIQUE INDEX move_source_once ON move(source, key) WHERE source IS NOT NULL;   -- one outside record writes each item at most once
CREATE INDEX move_key ON move(key, seq);
CREATE INDEX move_page ON move(page, seq) WHERE page IS NOT NULL;

-- ---------------------------------------------------------------- the items (the fold of the move log)
CREATE TABLE item (
  id         INTEGER PRIMARY KEY,
  key        TEXT NOT NULL,
  gen        INTEGER NOT NULL,                       -- 1, then 2 when the same cause comes back after a close
  kind       TEXT NOT NULL,
  home       TEXT NOT NULL,
  subject    TEXT NOT NULL,
  project    TEXT,
  parent     TEXT,
  state      TEXT NOT NULL CHECK (state IN ('open','done','dropped')),
  holder     TEXT NOT NULL,
  holder_id  TEXT NOT NULL CHECK (length(holder_id) > 0),
  owes       TEXT NOT NULL CHECK (length(owes) > 0),
  due_at     INTEGER NOT NULL,
  late_at    INTEGER,                                -- set when it is past due at its ceiling: listed in the digest
  opened_at  INTEGER NOT NULL,
  opened_by  TEXT NOT NULL,
  closed_at  INTEGER,
  closed_by  TEXT,
  outcome    TEXT,                                   -- done: the proof; dropped: the reason
  UNIQUE (key, gen),
  CHECK ((state = 'open') = (closed_at IS NULL)),
  CHECK (state = 'open' OR length(outcome) > 0)
);
CREATE UNIQUE INDEX item_one_open ON item(key) WHERE state = 'open';   -- one open item per cause: a repeat is a note
CREATE INDEX item_due ON item(due_at) WHERE state = 'open';
CREATE INDEX item_subject ON item(subject, kind) WHERE state = 'open';
CREATE INDEX item_parent ON item(parent) WHERE state = 'open';          -- a step's blockers, a Recon's critic lane

-- ---------------------------------------------------------------- readers' positions in the move log
CREATE TABLE cursor (
  reader TEXT PRIMARY KEY,                           -- main, lead:<home>, owner-digest, chat-bridge
  seq    INTEGER NOT NULL DEFAULT 0
);
CREATE TRIGGER cursor_forward BEFORE UPDATE OF seq ON cursor WHEN NEW.seq < OLD.seq
BEGIN SELECT RAISE(ABORT, 'a reader''s cursor only moves forward'); END;

-- ---------------------------------------------------------------- the project policy (the one place a project's settings live)
-- One row per version; the newest version is in force (v_policy). Only the owner's own message writes a version
-- (the registry import counts as his, once, at the cut-over).
-- level is the one-word leash (tight, standard, loose); the decision columns are what the level set, or his override.
-- Every column is enforced: merge, land and release by move_open_check, lanes by the lane limit, mode and trunk by
-- the review base (jg item base), the rung columns by the climb check. Use past the plan's quota is never here: the owner decides it at
-- every level (AGENTS.md section 9). Decisions not listed here never change by project (discard: never alone).
CREATE TABLE policy (
  project  TEXT NOT NULL,
  version  INTEGER NOT NULL,
  level    TEXT NOT NULL CHECK (level IN ('tight','standard','loose')),
  mode     TEXT NOT NULL CHECK (mode IN ('no-mistakes','direct-PR','local','local-only','local-trunk','no-mistakes-prod-only')),
  merge    TEXT NOT NULL CHECK (merge   IN ('owner','machine')),        -- owner: his word on the ticket; machine: the tick, an adapter or Main
  land     TEXT NOT NULL CHECK (land    IN ('owner','machine')),        -- the same, for a proved commit onto the local trunk
  release  TEXT NOT NULL CHECK (release IN ('owner','machine')),        -- machine on loose: yolo is the release word; on tight his landing word carries it
  lanes    INTEGER NOT NULL CHECK (lanes BETWEEN 0 AND 16),            -- how many lanes may work at once
  trunk    TEXT NOT NULL CHECK (length(trunk) > 0),                    -- the trunk branch: a review's base is read from mode + trunk, never a default
  worker_s INTEGER CHECK (worker_s BETWEEN 60 AND 3600),               -- a rung's time limit for this project (shorter only)
  lead_s   INTEGER CHECK (lead_s   BETWEEN 60 AND 7200),
  main_s   INTEGER CHECK (main_s   BETWEEN 60 AND 3600),
  owner_s  INTEGER CHECK (owner_s  BETWEEN 3600 AND 86400),
  set_at   INTEGER NOT NULL,
  set_by   TEXT NOT NULL,
  source   TEXT NOT NULL UNIQUE,                                       -- his message: the idempotency key
  PRIMARY KEY (project, version)
);
CREATE TRIGGER policy_check BEFORE INSERT ON policy
BEGIN
  SELECT RAISE(ABORT, 'policy: a version is stamped by the host clock (more than 300 s from it)')
    WHERE abs(NEW.set_at - host_now()) > 300;
  SELECT RAISE(ABORT, 'policy: only the owner''s own message sets a project''s policy')
    WHERE NEW.set_by NOT LIKE 'owner:%' OR length(NEW.source) = 0;
  -- The cut-over run writes every registry row at one stamp. After it, a new project has no row (its lanes go to an
  -- intake item) until his answer to a policy question writes version 1.
  SELECT RAISE(ABORT, 'policy: the registry import writes version 1 only, in the one cut-over run; later, his answer to a policy question writes it')
    WHERE NEW.set_by = 'owner:registry'
      AND (NEW.version <> 1 OR EXISTS (SELECT 1 FROM policy WHERE set_by = 'owner:registry' AND set_at <> NEW.set_at));
  SELECT RAISE(ABORT, 'policy: the next version is one above the last')
    WHERE NEW.version <> coalesce((SELECT max(version) FROM policy WHERE project = NEW.project), 0) + 1;
END;
CREATE TRIGGER policy_final BEFORE UPDATE ON policy BEGIN SELECT RAISE(ABORT, 'policy: a version never changes; write the next one'); END;
CREATE TRIGGER policy_kept BEFORE DELETE ON policy BEGIN SELECT RAISE(ABORT, 'policy: a version is never erased'); END;
CREATE VIEW v_policy AS
  SELECT p.* FROM policy p WHERE p.version = (SELECT max(version) FROM policy q WHERE q.project = p.project);

-- ---------------------------------------------------------------- move checks (one per verb)
-- The clock: `jg-item` stamps `at` and registers host_now() from the same host clock, so through `jg-item` this clause
-- never fires. It refuses a connection that registers no host_now() (the plain sqlite3 shell: no such function) and a
-- writer whose stamp differs from its own registered clock by more than 300 s. It does not guard against a wrong host
-- clock: the tick moves every open deadline whose last deadline move's frame is more than 300 s off its own.
CREATE TRIGGER move_clock_check BEFORE INSERT ON move
  WHEN abs(NEW.at - host_now()) > 300
BEGIN SELECT RAISE(ABORT, 'a move is stamped by the host clock: this stamp is more than 300 s from it'); END;

CREATE TRIGGER move_open_check BEFORE INSERT ON move WHEN NEW.verb = 'open'
BEGIN
  SELECT RAISE(ABORT, 'open: unknown kind') WHERE NOT EXISTS (SELECT 1 FROM kind WHERE kind = NEW.kind);
  SELECT RAISE(ABORT, 'open: home, subject and what is owed are required')
    WHERE coalesce(length(NEW.home),0) = 0 OR coalesce(length(NEW.subject),0) = 0 OR coalesce(length(NEW.why),0) = 0;
  -- An alert is keyed <cause>:<home>/<subject>, so one subject holds one open alert per cause (with item_one_open);
  -- a repeat of the same cause is a note on it, never a second alert (one per steer is impossible by key).
  SELECT RAISE(ABORT, 'open: an alert''s key is <cause>:<home>/<subject>, so a subject holds one alert per cause')
    WHERE NEW.kind = 'alert' AND (instr(NEW.key, ':') < 2 OR instr(substr(NEW.key, 1, instr(NEW.key, ':') - 1), '/') > 0
       OR substr(NEW.key, instr(NEW.key, ':') + 1) <> NEW.home || '/' || NEW.subject);
  SELECT RAISE(ABORT, 'open: the first holder is not the one the kind names')
    FROM kind k WHERE k.kind = NEW.kind
     AND NOT ((k.first = 'named' AND NEW.holder IN ('worker','lead','main','outside'))
              OR NEW.holder = k.first
              OR (k.first IN ('worker','lead') AND NEW.home = 'main' AND NEW.holder = 'main'));
  SELECT RAISE(ABORT, 'open: every item needs a holder id and a deadline within its limit')
    FROM kind k, rung r WHERE k.kind = NEW.kind AND r.holder = NEW.holder
     AND (coalesce(length(NEW.holder_id),0) = 0 OR NEW.due_at IS NULL OR NEW.due_at <= NEW.at
          OR NEW.due_at > NEW.at + CASE WHEN k.first = 'named' THEN min(k.deadline_s, r.deadline_s) ELSE k.deadline_s END);
  SELECT RAISE(ABORT, 'open: a lead or a worker writes only in its own home')
    WHERE (NEW.by LIKE 'lead:%' AND NEW.by <> 'lead:' || NEW.home)
       OR (NEW.by LIKE 'worker:%' AND NEW.by NOT LIKE 'worker:' || NEW.home || '/%' AND NEW.by NOT LIKE 'worker:' || NEW.home || ':%');
  SELECT RAISE(ABORT, 'open: land, merge and release are opened by the tick, an adapter, Main or the owner')
    WHERE NEW.kind IN ('land','merge','release') AND NOT (NEW.by IN ('tick','main') OR NEW.by LIKE 'adapter:%' OR NEW.by LIKE 'owner:%');
  SELECT RAISE(ABORT, 'open: an owner question offers at least two picks')
    WHERE NEW.kind = 'question' AND instr(coalesce(NEW.options, ''), '|') < 2;
  -- A step names the one thing it lets through, so his yes covers that thing only: land:<home>/<ticket>@<head>,
  -- merge:<home>/<ticket>@<pull request>, release:<project>@<release pull request>. Its question is keyed
  -- question:<the step's key>, and the key starts with its kind, so the step-question clause below finds it.
  SELECT RAISE(ABORT, 'open: a land, merge or release key is <kind>:...@<the commit or pull request it lets through>')
    WHERE NEW.kind IN ('land','merge','release') AND (NEW.key NOT LIKE NEW.kind || ':%' OR instr(NEW.key, '@') = 0
                                                    OR length(substr(NEW.key, instr(NEW.key, '@') + 1)) = 0);
  -- A step question is opened by Main or the tick, and its text names that commit or pull request.
  SELECT RAISE(ABORT, 'open: a step question is opened by Main or the tick, and its text names the commit or pull request')
    WHERE NEW.kind = 'question' AND (NEW.key LIKE 'question:land:%' OR NEW.key LIKE 'question:merge:%' OR NEW.key LIKE 'question:release:%')
      AND (NEW.by NOT IN ('main','tick') OR instr(NEW.key, '@') = 0 OR instr(NEW.why, substr(NEW.key, instr(NEW.key, '@') + 1)) = 0);
  -- A blocker names the open step it holds back, so the step's done close can close it (Y10). A step already done
  -- holds nothing back: the store's open says 'clear' and writes nothing.
  SELECT RAISE(ABORT, 'open: a blocker names the open step it holds back (parent)')
    WHERE NEW.kind = 'blocker' AND NOT EXISTS (SELECT 1 FROM item WHERE key = NEW.parent AND state = 'open');
  SELECT RAISE(ABORT, 'open: an open owner question on this ticket stops it')
    WHERE NEW.kind IN ('work','land','merge','release')
      AND EXISTS (SELECT 1 FROM item WHERE kind = 'question' AND state = 'open' AND subject = NEW.subject);
  -- The leash. No writer is exempt, an owner channel included: his adapter writes his close first in the same write,
  -- so his yes is there when the step opens. No project, or no row: the call stays with him.
  SELECT RAISE(ABORT, 'open: the project''s leash keeps this call with the owner and his yes on this exact step is missing')
    WHERE NEW.kind IN ('land','merge','release')
      AND coalesce((SELECT CASE NEW.kind WHEN 'land' THEN land WHEN 'merge' THEN merge ELSE release END
                      FROM v_policy WHERE project = NEW.project), 'owner') = 'owner'
      AND NOT EXISTS (SELECT 1 FROM item WHERE key = 'question:' || NEW.key
                      AND kind = 'question' AND state = 'done' AND closed_by LIKE 'owner:%' AND outcome LIKE '% pick=yes');
  SELECT RAISE(ABORT, 'open: work needs its project''s policy row (no row: the lane goes to an intake item)')
    WHERE NEW.kind = 'work' AND NOT EXISTS (SELECT 1 FROM v_policy WHERE project = NEW.project);
  -- the lane limit stops a lane opened after its policy version took effect; the cut-over writes the registry's rows and
  -- imports the lanes already running (a fact) at that same stamp, so no running lane is refused
  SELECT RAISE(ABORT, 'open: the project''s lane limit is reached')
    WHERE NEW.kind = 'work' AND NEW.at > (SELECT set_at FROM v_policy WHERE project = NEW.project)
      AND (SELECT lanes FROM v_policy WHERE project = NEW.project) <= (SELECT count(*) FROM item WHERE kind = 'work' AND state = 'open' AND project = NEW.project);
  SELECT RAISE(ABORT, 'open: a standing rule needs the owner''s own message')
    WHERE NEW.kind = 'rule' AND (NEW.by NOT LIKE 'owner:%' OR coalesce(length(NEW.source),0) = 0);
END;

CREATE TRIGGER move_note_check BEFORE INSERT ON move WHEN NEW.verb = 'note'
BEGIN
  SELECT RAISE(ABORT, 'note: no open item has this key') WHERE NOT EXISTS (SELECT 1 FROM item WHERE key = NEW.key AND state = 'open');
  SELECT RAISE(ABORT, 'note: a note changes no holder or deadline')
    WHERE NEW.holder IS NOT NULL OR NEW.due_at IS NOT NULL;
END;

CREATE TRIGGER move_hand_check BEFORE INSERT ON move WHEN NEW.verb = 'hand'
BEGIN
  SELECT RAISE(ABORT, 'hand: no open item has this key') WHERE NOT EXISTS (SELECT 1 FROM item WHERE key = NEW.key AND state = 'open');
  SELECT RAISE(ABORT, 'hand: a hand needs a reason, a holder id and a new deadline in the next 14 days')
    WHERE coalesce(length(NEW.why),0) = 0 OR coalesce(length(NEW.holder_id),0) = 0
       OR NEW.due_at IS NULL OR NEW.due_at <= NEW.at OR NEW.due_at > NEW.at + 1209600;
  SELECT RAISE(ABORT, 'hand: not above the kind''s ceiling, and never to the machine or the owner by hand')
    FROM item i JOIN kind k ON k.kind = i.kind JOIN rung c ON c.holder = k.ceiling JOIN rung t ON t.holder = NEW.holder
    WHERE i.key = NEW.key AND i.state = 'open'
      AND (t.rank > c.rank OR (NEW.holder = 'tick' AND NEW.by <> 'tick') OR (NEW.holder = 'owner' AND i.kind NOT IN ('question','security','main-down')));
  SELECT RAISE(ABORT, 'hand: only its holder, its raiser, its lane''s worker or someone ranked above its holder may hand it')
    FROM item i JOIN rung h ON h.holder = i.holder
    WHERE i.key = NEW.key AND i.state = 'open'
      AND NEW.by <> i.holder_id AND NEW.by <> i.opened_by AND NEW.by <> 'tick' AND NEW.by <> 'worker:' || i.subject
      AND (CASE WHEN NEW.by = 'main' THEN 2 WHEN NEW.by LIKE 'owner:%' THEN 3 WHEN NEW.by = 'lead:' || i.home THEN 1 ELSE -1 END) <= h.rank;
END;

CREATE TRIGGER move_climb_check BEFORE INSERT ON move WHEN NEW.verb = 'climb'
BEGIN
  SELECT RAISE(ABORT, 'climb: only the tick climbs') WHERE NEW.by <> 'tick';
  SELECT RAISE(ABORT, 'climb: no open item has this key') WHERE NOT EXISTS (SELECT 1 FROM item WHERE key = NEW.key AND state = 'open');
  SELECT RAISE(ABORT, 'climb: not before its deadline') FROM item i WHERE i.key = NEW.key AND i.state = 'open' AND NEW.at < i.due_at;
  SELECT RAISE(ABORT, 'climb: one rung up the fixed ladder, or stay at the ceiling')
    FROM item i JOIN kind k ON k.kind = i.kind JOIN rung h ON h.holder = i.holder JOIN rung c ON c.holder = k.ceiling
    WHERE i.key = NEW.key AND i.state = 'open'
      AND NOT ((h.rank < c.rank AND (NEW.holder = h.next OR (i.home = 'main' AND h.next = 'lead' AND NEW.holder = 'main')))
               OR (h.rank >= c.rank AND NEW.holder = i.holder AND NEW.holder_id = i.holder_id));
  SELECT RAISE(ABORT, 'climb: the new deadline is the rung''s time limit (the project''s shorter one when its policy sets it)')
    FROM rung r JOIN item i ON i.key = NEW.key AND i.state = 'open' LEFT JOIN v_policy p ON p.project = i.project
    WHERE r.holder = NEW.holder
      AND (NEW.due_at IS NULL OR coalesce(length(NEW.holder_id),0) = 0
           OR NEW.due_at <> NEW.at + coalesce(CASE NEW.holder WHEN 'worker' THEN p.worker_s WHEN 'lead' THEN p.lead_s
                                                             WHEN 'main' THEN p.main_s WHEN 'owner' THEN p.owner_s END, r.deadline_s));
END;

CREATE TRIGGER move_close_check BEFORE INSERT ON move WHEN NEW.verb = 'close'
BEGIN
  SELECT RAISE(ABORT, 'close: no open item has this key') WHERE NOT EXISTS (SELECT 1 FROM item WHERE key = NEW.key AND state = 'open');
  SELECT RAISE(ABORT, 'close: done needs the proof the kind names')
    FROM item i JOIN kind k ON k.kind = i.kind
    WHERE i.key = NEW.key AND i.state = 'open' AND NEW.ends = 'done'
      AND (instr(NEW.why, ':') < 2 OR length(trim(substr(NEW.why, instr(NEW.why, ':') + 1))) = 0
           OR instr('|' || k.proof, '|' || substr(NEW.why, 1, instr(NEW.why, ':'))) = 0);   -- the proof names its thing: trunk:<the landed commit>
  SELECT RAISE(ABORT, 'close: this kind closes done only on the owner''s own message')
    FROM item i JOIN kind k ON k.kind = i.kind
    WHERE i.key = NEW.key AND i.state = 'open' AND NEW.ends = 'done' AND k.closer = 'owner' AND NEW.by NOT LIKE 'owner:%';
  SELECT RAISE(ABORT, 'close: his answer names one of the picks he was offered (pick=<x>)')
    FROM item i WHERE i.key = NEW.key AND i.state = 'open' AND NEW.ends = 'done' AND i.kind = 'question'
      AND (instr(NEW.why, ' pick=') = 0
           OR instr('|' || (SELECT o.options FROM move o WHERE o.key = NEW.key AND o.verb = 'open' ORDER BY o.seq DESC LIMIT 1) || '|',
                    '|' || substr(NEW.why, instr(NEW.why, ' pick=') + 6) || '|') = 0);
  SELECT RAISE(ABORT, 'close: this kind closes done only by its own adapter')
    FROM item i JOIN kind k ON k.kind = i.kind
    WHERE i.key = NEW.key AND i.state = 'open' AND NEW.ends = 'done' AND k.closer LIKE 'adapter:%' AND NEW.by <> k.closer;
  SELECT RAISE(ABORT, 'close: the tick closes done only an alert it opened itself')
    FROM item i WHERE i.key = NEW.key AND i.state = 'open' AND NEW.ends = 'done' AND NEW.by = 'tick'
      AND NOT (i.kind = 'alert' AND i.opened_by = 'tick');
  SELECT RAISE(ABORT, 'close: only its holder, its raiser or someone ranked above its holder may close it done')
    FROM item i JOIN kind k ON k.kind = i.kind JOIN rung h ON h.holder = i.holder
    WHERE i.key = NEW.key AND i.state = 'open' AND NEW.ends = 'done' AND k.closer = 'ladder'
      AND NEW.by <> i.holder_id AND NEW.by <> i.opened_by AND NEW.by <> 'tick' AND NEW.by NOT LIKE 'adapter:%' AND NEW.by <> 'worker:' || i.subject
      AND (CASE WHEN NEW.by = 'main' THEN 2 WHEN NEW.by LIKE 'owner:%' THEN 3 WHEN NEW.by = 'lead:' || i.home THEN 1 ELSE -1 END) < h.rank
      AND NOT (i.kind = 'blocker' AND NEW.why LIKE 'gone: its step % closed done%'
               AND EXISTS (SELECT 1 FROM item p WHERE p.key = i.parent AND p.state = 'done'));   -- the cascade below, by the step's closer
  -- Who may drop. An owner question: the owner, or its raiser (never the tick, never Main unless Main raised it); a
  -- raiser's withdrawal after the question paged him is listed in his next digest with its reason (v_withdrawn).
  -- Anything else: its raiser, Main, the owner, or the tick when its subject is gone or its time ended. An alert or
  -- steer on a lane: also anyone, with 'subject gone: its lane closed', once that lane's work is closed (the cascade).
  SELECT RAISE(ABORT, 'close: only its raiser or the owner drops an owner question; anything else: its raiser, Main, the owner, or the tick when its subject is gone')
    FROM item i
    WHERE i.key = NEW.key AND i.state = 'open' AND NEW.ends = 'dropped'
      AND NOT (NEW.by LIKE 'owner:%'
               OR (NEW.by = i.opened_by AND NOT (i.kind = 'question' AND NEW.by = 'tick'))
               OR (i.kind <> 'question' AND NEW.by = 'main')
               OR (i.kind <> 'question' AND NEW.by = 'tick' AND (NEW.why LIKE 'subject gone:%' OR NEW.why LIKE 'ended:%'))
               OR (i.kind IN ('alert','steer') AND NEW.why LIKE 'subject gone: its lane closed%'
                   AND EXISTS (SELECT 1 FROM item w WHERE w.kind = 'work' AND w.subject = i.subject AND w.home = i.home)
                   AND NOT EXISTS (SELECT 1 FROM item w WHERE w.kind = 'work' AND w.state = 'open' AND w.subject = i.subject AND w.home = i.home)));
END;

-- ---------------------------------------------------------------- apply (same transaction as the move)
CREATE TRIGGER move_apply_open AFTER INSERT ON move WHEN NEW.verb = 'open'
BEGIN
  INSERT INTO item(key, gen, kind, home, subject, project, parent, state, holder, holder_id, owes, due_at, opened_at, opened_by)
  VALUES (NEW.key, coalesce((SELECT max(gen) FROM item WHERE key = NEW.key), 0) + 1, NEW.kind, NEW.home, NEW.subject, NEW.project, NEW.parent,
          'open', NEW.holder, NEW.holder_id, NEW.why, NEW.due_at, NEW.at, NEW.by);
END;

CREATE TRIGGER move_apply_hand AFTER INSERT ON move WHEN NEW.verb IN ('hand','climb')
BEGIN
  UPDATE item SET late_at = CASE WHEN NEW.verb = 'climb' AND NEW.holder = holder THEN coalesce(late_at, NEW.at)
                                 WHEN NEW.verb = 'climb' THEN late_at ELSE NULL END,
                  holder = NEW.holder, holder_id = NEW.holder_id, due_at = NEW.due_at
   WHERE key = NEW.key AND state = 'open';
END;

CREATE TRIGGER move_apply_close AFTER INSERT ON move WHEN NEW.verb = 'close'
BEGIN
  UPDATE item SET state = NEW.ends, closed_at = NEW.at, closed_by = NEW.by, outcome = NEW.why WHERE key = NEW.key AND state = 'open';
  -- A lane's final move closes every alert and steer on that lane in the same write (each its own move, so the fold
  -- sees it): a done lane holds no live alert. Its waits and questions stay, because someone else still owes them.
  INSERT INTO move(at, verb, key, by, ends, why)
    SELECT NEW.at, 'close', o.key, NEW.by, 'dropped', 'subject gone: its lane closed ' || NEW.ends
      FROM item w JOIN item o ON o.subject = w.subject AND o.home = w.home AND o.state = 'open' AND o.kind IN ('alert','steer')
     WHERE w.key = NEW.key AND w.kind = 'work' AND w.gen = (SELECT max(gen) FROM item WHERE key = NEW.key)
     ORDER BY o.id;
  -- A step's done close closes every blocker that names it, done, in the same write (Y10): the proof that the source is
  -- clear is the step's own proof. A dropped step leaves its blockers with their holders.
  INSERT INTO move(at, verb, key, by, ends, why)
    SELECT NEW.at, 'close', b.key, NEW.by, 'done', 'gone: its step ' || NEW.key || ' closed done: ' || NEW.why
      FROM item b WHERE b.parent = NEW.key AND b.kind = 'blocker' AND b.state = 'open' AND NEW.ends = 'done'
     ORDER BY b.id;
END;

-- ---------------------------------------------------------------- nothing is erased; item changes only through a move
CREATE TRIGGER move_kept BEFORE DELETE ON move BEGIN SELECT RAISE(ABORT, 'the move log is never erased'); END;
CREATE TRIGGER move_final BEFORE UPDATE ON move BEGIN SELECT RAISE(ABORT, 'a move is never changed; write a new one'); END;
CREATE TRIGGER item_kept BEFORE DELETE ON item BEGIN SELECT RAISE(ABORT, 'an item is never erased; close it with a reason'); END;
CREATE TRIGGER item_insert_via_move BEFORE INSERT ON item
  WHEN NOT EXISTS (SELECT 1 FROM move WHERE seq = (SELECT max(seq) FROM move) AND verb = 'open' AND key = NEW.key)
BEGIN SELECT RAISE(ABORT, 'an item is opened only by an open move'); END;
CREATE TRIGGER item_update_via_move BEFORE UPDATE ON item
  WHEN OLD.state <> 'open'
    OR NOT EXISTS (SELECT 1 FROM move WHERE seq = (SELECT max(seq) FROM move) AND verb IN ('hand','climb','close') AND key = OLD.key)
BEGIN SELECT RAISE(ABORT, 'an item changes only by a move, and a closed item never changes'); END;

-- ---------------------------------------------------------------- views for people and the tick
-- The board: every open item, who holds it, by when, and whether it is late.
CREATE VIEW v_board AS
  SELECT i.holder, i.holder_id, i.kind, i.key, i.subject, i.owes, i.due_at, i.late_at, i.opened_at,
         (SELECT max(at) FROM move m WHERE m.key = i.key) AS last_move_at
    FROM item i WHERE i.state = 'open';

-- The digest: late items at their ceiling, grouped per holder (one page per holder per interval, not one per item).
CREATE VIEW v_digest AS
  SELECT holder_id, kind, count(*) AS late, min(late_at) AS oldest FROM item
   WHERE state = 'open' AND late_at IS NOT NULL GROUP BY holder_id, kind;

-- Withdrawn owner questions: dropped by someone other than him after they paged him. His next digest lists each one
-- with its reason; the digest reader's cursor (reader 'owner-digest') marks what he has seen.
CREATE VIEW v_withdrawn AS
  SELECT m.seq, m.at, m.key, m.by, m.why FROM move m
   WHERE m.verb = 'close' AND m.ends = 'dropped' AND m.by NOT LIKE 'owner:%'
     AND EXISTS (SELECT 1 FROM move o WHERE o.key = m.key AND o.verb = 'open' AND o.kind = 'question')
     AND EXISTS (SELECT 1 FROM move p WHERE p.key = m.key AND p.page = 'owner' AND p.seq < m.seq)
     AND m.seq > coalesce((SELECT seq FROM cursor WHERE reader = 'owner-digest'), 0);

-- A board view (not a check: it can differ from the item table only when a trigger is bypassed, which the fold check
-- finds): per kind, how many came in and where they are now.
CREATE VIEW v_count AS
  SELECT kind,
         (SELECT count(*) FROM move m WHERE m.verb = 'open' AND m.kind = i.kind) AS came_in,
         sum(state = 'open') AS open, sum(state = 'done') AS done, sum(state = 'dropped') AS dropped,
         sum(state = 'open' AND holder IN ('worker','tick')) AS in_flight,
         sum(state = 'open' AND holder IN ('lead','main','owner')) AS waiting_on_ladder,
         sum(state = 'open' AND holder = 'outside') AS waiting_outside,
         sum(state <> 'open' AND coalesce(length(outcome),0) = 0) AS closed_without_reason
    FROM item i GROUP BY kind;

-- A ticket's stage, read from its chain of items (the open one, else the last closed one).
CREATE VIEW v_ticket AS
  SELECT subject AS ticket,
         coalesce(max(CASE WHEN state = 'open' THEN kind END), (SELECT i2.kind FROM item i2 WHERE i2.subject = i.subject ORDER BY i2.id DESC LIMIT 1)) AS stage,
         max(CASE WHEN kind = 'land' AND state = 'done' THEN 1 ELSE 0 END) AS landed,
         max(CASE WHEN kind = 'release' AND state = 'done' THEN 1 ELSE 0 END) AS released
    FROM item i WHERE kind IN ('dispatch','work','land','merge','release','cleanup') GROUP BY subject;
