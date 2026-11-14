#!/usr/bin/env node
// The conformance script for the ticket adapter interface (docs/ticket-adapter.md). It runs any adapter, one executable called as `adapter <operation>`, against the
// worked examples and checks the contract on every answer: each response against its JSON Schema, then the rules a schema cannot hold (a stale rev is a conflict, an
// unknown extra key survives an update, a failed read is an error and never an empty list, a list that is not whole is refused as incomplete).
//
//   node test/ticket-adapter-conformance.mjs <adapter> --throwaway [--faults <executable>]
//
// It creates and edits tickets and the interface has no delete, so it runs only against a backend that can be thrown away, and only when told so with --throwaway.
// --faults names the backend's own driver, called as `faults <none|unreadable|partial>`: unreadable makes every read fail, partial makes a list readable only in part.
// Without it the two failure checks cannot run and the script says so and exits 3. Exit 0: every check passed. 1: a check failed. 2: bad usage. 3: all that ran passed.
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { loadSchemas, validate } from './support/json-schema.mjs';

const root = fileURLToPath(new URL('../docs/ticket-adapter/', import.meta.url));
export const schemas = loadSchemas(`${root}schemas`);
export const examples = Object.fromEntries(readdirSync(`${root}examples`).filter((f) => f.endsWith('.json')).map((f) => [f.slice(0, -5), JSON.parse(readFileSync(`${root}examples/${f}`, 'utf8'))]));

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const expect = (ok, why) => { if (!ok) throw new Error(why); };

/** Runs every check against `adapter`; returns [{ name, ok, why, notRun }]. `faults` is the optional faults driver, `env` what both run with. */
export function conform({ adapter, faults, env = process.env }) {
  const spawn = (cmd, args, input) => {
    const r = spawnSync(cmd, args, { input, env, encoding: 'utf8', timeout: 30_000 });
    if (r.error) throw new Error(`cannot run ${cmd} ${args.join(' ')}: ${r.error.message}`);
    let json; try { json = JSON.parse(r.stdout); } catch { /* not JSON: the checks say so */ }
    return { status: r.status, json, stdout: r.stdout, stderr: r.stderr };
  };
  const say = (r) => `exit ${r.status}, stdout ${JSON.stringify(r.stdout.slice(0, 200))}${r.stderr ? `, stderr ${JSON.stringify(r.stderr.slice(0, 120))}` : ''}`;
  const call = (op, body = {}, raw) => spawn(adapter, [op], raw ?? JSON.stringify({ interface: 1, ...body }));
  /** A success: exit 0 and a response the operation's schema accepts. */
  const good = (op, body) => {
    const r = call(op, body);
    expect(r.status === 0, `${op} should succeed, got ${say(r)}`);
    const problems = validate(schemas, `${op}.response.json`, r.json);
    expect(!problems.length, `${op} response breaks its schema: ${problems.slice(0, 3).join('; ')}`);
    return r.json;
  };
  /** A refusal: a non-zero exit and an error the error schema accepts, with `code` when one is named. `raw` is the stdin to send instead of a request, `why` what the refusal is for. */
  const refused = (op, body, code, { raw, why = '' } = {}) => {
    const r = call(op, body, raw);
    expect(r.status !== 0, `${op} should be refused with ${code ?? 'an error'}, but it succeeded: ${say(r)}${why && `. ${why}`}`);
    const problems = validate(schemas, 'error.json', r.json);
    expect(!problems.length, `${op} error breaks the error schema: ${problems.slice(0, 3).join('; ')} (${say(r)})`);
    expect(!code || r.json.error.code === code, `${op} should be refused with ${code}, got ${r.json.error.code}: ${r.json.error.message}`);
    return r.json.error;
  };
  /** Every ticket, read the way a client reads: pages to the end, each one claiming complete. A list that is not whole is refused as incomplete. */
  const readAll = (limit) => {
    const all = []; let cursor;
    for (let page = 0; page < 1000; page++) {
      const r = good('list', { ...(limit && { limit }), ...(cursor && { cursor }) });
      expect(r.complete === true, `list answered complete=${r.complete}: a list that is not whole is refused as incomplete (the adapter answers the error incomplete instead)`);
      expect(!limit || r.tickets.length <= limit, `list answered ${r.tickets.length} tickets for limit ${limit}`);
      all.push(...r.tickets); cursor = r.next_cursor;
      if (!cursor) return all;
    }
    throw new Error('list never reached the end of its next_cursor');
  };
  const setFault = (mode) => { const r = spawn(faults, [mode]); expect(r.status === 0, `faults ${mode} failed: ${say(r)}`); };

  const stamp = randomBytes(4).toString('hex'), opId = (n) => `conformance-${stamp}-${n}`, ctx = { caps: [], enums: {} };
  const named = examples.create.request.ticket, patch = examples.update.request.set, unset = examples['update-unset'].request.unset, text = examples.comment.request.text;
  const checks = [];
  const check = (name, fn, needsFaults = false) => checks.push({ name, fn, needsFaults });

  check('describe: names interface 1, its capabilities and its fields', () => {
    const d = good('describe');
    expect(d.interface === 1, `describe says interface ${d.interface}`);
    expect(d.fields.some((f) => f.name === 'title'), 'describe lists no title field');
    ctx.caps = d.capabilities; ctx.enums = Object.fromEntries(d.fields.filter((f) => f.type === 'enum' && f.values?.length).map((f) => [f.name, f.values.map((v) => v.value)]));
  });
  check('create: returns the ticket read back with its id and rev, and keeps an extra key the client does not know', () => {
    const seed = { title: `${named.title} ${stamp}`, body: named.body, labels: named.labels, extra: named.extra, ...Object.fromEntries(['kind', 'status'].filter((k) => ctx.enums[k]).map((k) => [k, ctx.enums[k][0]])) };
    const { ticket } = good('create', { ticket: seed, op_id: opId('create') });
    ctx.seed = seed; ctx.t = ticket;
    for (const k of Object.keys(seed)) expect(same(ticket[k], seed[k]), `create answered ${k} ${JSON.stringify(ticket[k])}, not ${JSON.stringify(seed[k])}`);
  });
  check('create: the same op_id twice is one ticket; the same op_id for another request is invalid', () => {
    const { ticket } = good('create', { ticket: ctx.seed, op_id: opId('create') });
    expect(same(ticket, ctx.t), `a repeated create answered ${JSON.stringify(ticket)}, not the first ticket`);
    expect(readAll().filter((t) => t.title === ctx.seed.title).length === 1, 'a repeated create made a second ticket');
    refused('create', { ticket: { ...ctx.seed, title: `${ctx.seed.title} again` }, op_id: opId('create') }, 'invalid');
  });
  check('create: a ticket with no title is invalid and names the title', () => {
    const e = refused('create', { ticket: { body: 'No title.' }, op_id: opId('untitled') }, 'invalid');
    expect(e.detail.fields.some((f) => f.field === 'title'), `invalid names ${JSON.stringify(e.detail.fields)}, not title`);
  });
  check('get: answers the ticket create answered', () => {
    expect(same(good('get', { id: ctx.t.id }).ticket, ctx.t), 'get answered another record than create did');
  });
  check('list: whole, every ticket once, and pages that join up', () => {
    const all = readAll(), paged = readAll(1);
    expect(all.filter((t) => t.id === ctx.t.id).length === 1, 'list does not hold the created ticket exactly once');
    expect(new Set(all.map((t) => t.id)).size === all.length, 'list repeats a ticket');
    expect(same(paged.map((t) => t.id), all.map((t) => t.id)), 'pages of one ticket do not join up to the whole list, in its order');
  });
  check('update: a patch changes only what it names; the rev moves; the answer is the ticket as read back', () => {
    const set = { title: patch.title, extra: patch.extra, ...(ctx.enums.status && { status: ctx.enums.status.find((s) => s !== ctx.t.status) }) };
    const request = { id: ctx.t.id, rev: ctx.t.rev, op_id: opId('update'), set };
    const { ticket } = good('update', request);
    ctx.request = request; ctx.first = ticket; ctx.before = ctx.t; ctx.t = ticket;
    expect(ticket.rev !== ctx.before.rev, 'the rev did not change on a write');
    expect(ticket.title === set.title, `update answered title ${JSON.stringify(ticket.title)}`);
    for (const k of ['body', 'kind', 'assignee', 'labels', 'parent', 'links', 'created_at', 'id', ...(set.status ? [] : ['status'])]) expect(same(ticket[k], ctx.before[k]), `update changed ${k}, which the patch did not name`);
    expect(same(ticket.extra, { ...ctx.before.extra, ...set.extra }), `update answered extra ${JSON.stringify(ticket.extra)}`);
    expect(same(good('get', { id: ticket.id }).ticket, ticket), 'get does not answer the ticket update answered');
  });
  check('update: an unknown field survives an update of another field, byte for byte', () => {
    const before = ctx.t, { ticket } = good('update', { id: before.id, rev: before.rev, op_id: opId('title'), set: { title: `${before.title} !` } });
    ctx.t = ticket;
    expect(same(ticket.extra, before.extra), `update of the title turned extra ${JSON.stringify(before.extra)} into ${JSON.stringify(ticket.extra)}`);
    expect(ticket.extra['legacy-ref'] === named.extra['legacy-ref'], 'the extra key the client never named is gone');
  });
  check('update: unset removes only the extra key it names', () => {
    const before = ctx.t, { ticket } = good('update', { id: before.id, rev: before.rev, op_id: opId('unset'), unset });
    ctx.t = ticket;
    expect(same(ticket.extra, Object.fromEntries(Object.entries(before.extra).filter(([k]) => !unset.includes(k)))), `unset ${unset} turned extra ${JSON.stringify(before.extra)} into ${JSON.stringify(ticket.extra)}`);
  });
  check('update: a stale rev gives conflict with the current ticket, and writes nothing', () => {
    const e = refused('update', { id: ctx.t.id, rev: ctx.before.rev, op_id: opId('stale'), set: { title: 'Lost' } }, 'conflict');
    expect(same(e.detail.current, ctx.t), 'conflict carries a ticket that is not the current one');
    expect(same(good('get', { id: ctx.t.id }).ticket, ctx.t), 'a refused update changed the ticket');
  });
  check('update: repeating an op_id answers the first result, not a conflict; reusing it for another edit is invalid', () => {
    expect(same(good('update', ctx.request).ticket, ctx.first), 'a repeated update did not answer its first result');
    refused('update', { ...ctx.request, set: { title: 'Another edit' } }, 'invalid');
  });
  check('update: an empty patch, a field a client may not set and a field nobody has are invalid and name the field', () => {
    const at = { id: ctx.t.id, rev: ctx.t.rev };
    refused('update', { ...at, op_id: opId('empty') }, 'invalid');
    refused('update', { ...at, op_id: opId('empty-set'), set: {} }, 'invalid');
    for (const field of ['id', 'rev', 'nonesuch']) {
      const e = refused('update', { ...at, op_id: opId(`bad-${field}`), set: { [field]: 'x' } }, 'invalid');
      expect(e.detail.fields.some((f) => f.field === field), `invalid names ${JSON.stringify(e.detail.fields)}, not ${field}`);
    }
  });
  check('not_found: an id no ticket has', () => {
    refused('get', { id: 'no-such-ticket' }, 'not_found');
    refused('update', { id: 'no-such-ticket', rev: 'x', op_id: opId('missing'), set: { title: 'x' } }, 'not_found');
  });
  check('requests: an unknown key, another interface number, an unknown operation and a body that is not JSON are refused', () => {
    refused('get', { id: ctx.t.id, verbose: true }, 'unsupported');
    refused('get', {}, 'unsupported', { raw: JSON.stringify({ interface: 2, id: ctx.t.id }) });
    refused('frobnicate', {}, 'unsupported');
    refused('get', {}, 'invalid', { raw: 'not json' });
  });
  check('history: every event of the ticket in order, or unsupported when the backend keeps none', () => {
    if (!ctx.caps.includes('history')) return void refused('history', { id: ctx.t.id }, 'unsupported');
    const events = []; let cursor;
    do { const r = good('history', { id: ctx.t.id, ...(cursor && { cursor }) }); events.push(...r.events); cursor = r.next_cursor; } while (cursor);
    expect(events.length >= 3, `history holds ${events.length} events after three edits`);
    expect(new Set(events.map((e) => e.id)).size === events.length, 'history repeats an event id');
    expect(events.every((e, i) => !i || Date.parse(e.at) >= Date.parse(events[i - 1].at)), 'history is not in order, oldest first');
    ctx.events = events;
  });
  check('comment: adds an event with the text, or unsupported when the backend has no comments', () => {
    if (!ctx.caps.includes('comment')) return void refused('comment', { id: ctx.t.id, text, op_id: opId('comment') }, 'unsupported');
    const { event } = good('comment', { id: ctx.t.id, text, op_id: opId('comment') });
    expect(event.text === text, `comment answered the text ${JSON.stringify(event.text)}`);
    expect(same(good('comment', { id: ctx.t.id, text, op_id: opId('comment') }).event, event), 'a repeated comment answered another event');
    if (ctx.caps.includes('history')) expect(good('history', { id: ctx.t.id }).events.some((e) => e.id === event.id), 'history does not hold the comment');
  });
  check('failed read: list and get are errors, never an empty list', () => {
    setFault('unreadable');
    try {
      for (const [op, body] of [['list', {}], ['get', { id: ctx.t.id }]]) refused(op, body, undefined, { why: 'The backend could not be read, so any answer is an empty or old result in place of an error' });
    } finally { setFault('none'); }
    expect(readAll().length > 0, 'list does not work again once the backend can be read');
  }, true);
  check('incomplete: a list that cannot be whole is the error incomplete, never a short list or complete=false', () => {
    setFault('partial');
    try {
      const r = call('list', {});
      expect(!(r.status === 0 && r.json?.complete === false), 'list answered complete=false, which is refused as incomplete: an adapter that cannot return every ticket answers the error incomplete');
      refused('list', {}, 'incomplete', { why: 'The backend could be read only in part, so a list of any length is wrong; the answer is the error incomplete' });
    } finally { setFault('none'); }
  }, true);

  const results = [];
  for (const { name, fn, needsFaults } of checks) {
    if (needsFaults && !faults) { results.push({ name, ok: false, notRun: true, why: 'no --faults driver' }); continue; }
    try { fn(); results.push({ name, ok: true }); } catch (e) { results.push({ name, ok: false, why: e.message }); }
  }
  if (faults) { try { setFault('none'); } catch { /* the check that needed it has already failed */ } }
  return results;
}

/** The command line. Returns the exit code. */
export function main(argv) {
  const faultsAt = argv.indexOf('--faults'), faults = faultsAt >= 0 ? argv[faultsAt + 1] : undefined;
  const adapter = argv.find((a, i) => !a.startsWith('--') && (faultsAt < 0 || i !== faultsAt + 1));
  if (!adapter || !argv.includes('--throwaway') || (faultsAt >= 0 && !faults)) {
    console.error('usage: node test/ticket-adapter-conformance.mjs <adapter> --throwaway [--faults <executable>]\n--throwaway: the adapter points at a backend you can throw away; this script creates and edits tickets and the interface cannot delete them.');
    return 2;
  }
  const results = conform({ adapter, faults });
  results.forEach((r, i) => console.log(`${r.ok ? 'ok' : r.notRun ? 'not run' : 'not ok'} ${i + 1} - ${r.name}${r.why ? `\n    ${r.why}` : ''}`));
  const failed = results.filter((r) => !r.ok && !r.notRun), skipped = results.filter((r) => r.notRun);
  console.log(`# ${results.length - failed.length - skipped.length} passed, ${failed.length} failed, ${skipped.length} not run`);
  if (failed.length) return 1;
  if (skipped.length) { console.log('# not conformant until the failure checks run: give --faults a driver for this backend'); return 3; }
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2));
