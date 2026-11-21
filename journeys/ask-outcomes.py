#!/usr/bin/env python3
"""Drive actual ask intake, acceptance and gateway commands against a loopback lab chat."""
import email
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = Path(os.environ["DONE_DONE_EVIDENCE_ROOT"])
EVIDENCE.mkdir(parents=True, exist_ok=True)
LOG = EVIDENCE / "ask-outcomes.log"
steps = []
requests = []
modes = {}
barrier = threading.Event()
entered = threading.Event()


class Bot(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true,"result":[]}')

    def do_POST(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            blocks = []
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if not size:
                    self.rfile.readline()
                    break
                blocks.append(self.rfile.read(size))
                self.rfile.read(2)
            raw = b"".join(blocks)
        else:
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if "multipart" in self.headers.get("Content-Type", ""):
            message = email.message_from_bytes(
                ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + raw)
            fields = {}
            for part in message.walk():
                name = part.get_param("name", header="content-disposition")
                if name:
                    fields[name] = part.get_payload(decode=True)
            reply = json.loads(fields.get("reply_parameters", b'{}'))
            request = {"method": self.path.rsplit("/", 1)[-1],
                       "reply": reply.get("message_id"), "file": fields.get("document"),
                       "chat": int(fields["chat_id"])}
        else:
            fields = json.loads(raw)
            request = {"method": self.path.rsplit("/", 1)[-1],
                       "reply": fields.get("reply_parameters", {}).get("message_id"),
                       "text": fields.get("text", ""), "chat": fields.get("chat_id")}
        requests.append(request)
        mode = modes.get(str(request["reply"]), 200)
        if mode == "block":
            entered.set()
            barrier.wait(20)
        if mode == "disconnect":
            self.close_connection = True
            return
        self.send_response(mode if isinstance(mode, int) else 200)
        self.end_headers()
        result = {} if mode == "missing" else {"message_id": 500 + len(requests)}
        response = {"ok": True, "result": result} if not isinstance(mode, int) or mode == 200 else {
            "ok": False, "error_code": mode, "description": "lab refusal"}
        try:
            self.wfile.write(json.dumps(response).encode())
        except BrokenPipeError:
            pass  # the interrupted-send case kills only its own gateway process


def main(lab):
    home = lab / "home"
    for name in ("config", "data", "state", "user", "cache", "tmp"):
        (home / name).mkdir(parents=True)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("JG_", "BEADS_", "GIT_", "CLAUDE_", "CODEX_"))}
    env.update(HOME=str(home / "user"), XDG_CONFIG_HOME=str(home / "user/config"),
               XDG_DATA_HOME=str(home / "user/data"), XDG_CACHE_HOME=str(home / "cache"),
               TMPDIR=str(home / "tmp"), GOCACHE=str(home / "cache/go"),
               JG_HOME=str(home), JG_STATE_OVERRIDE=str(home / "state"),
               JG_DATA_OVERRIDE=str(home / "data"), JG_CONFIG_OVERRIDE=str(home / "config"),
               JG_VOICE_REWRITE_CMD="/bin/false",
               JG_BUS_HOMES=str(home / "no-machine-members"))

    def run(script, *args, stdin=None, in_env=None):
        cmd = ["bash", str(ROOT / "bin" / script), *args]
        result = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                                cwd=ROOT, env=in_env or env, timeout=90)
        with LOG.open("a") as log:
            log.write(f"$ {script} {' '.join(args)}\n{result.stdout}{result.stderr}exit={result.returncode}\n")
        assert result.returncode == 0, f"{script} {args}: {result.stderr}\n{result.stdout}"
        return result.stdout

    def check(label, condition):
        assert condition, label
        steps.append(label)
        print("PASS:", label, flush=True)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Bot)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        token = home / "lab.token"
        token.write_text("000000:synthetic-only\n")
        token.chmod(0o600)
        (home / "config/captain-channel").write_text(
            f"set mode direct\nset gateway-adapters telegram\nset telegram-token-file {token}\n"
            f"set telegram-allow-user 42\nset telegram-api-url http://127.0.0.1:{server.server_port}\n")
        (home / "config/backlog-intake-loose").touch()

        def ask(ticket, message, origin="telegram", result="failed: Umer could not finish the work."):
            note = json.loads(run("jg-inbox.sh", "note", "--json",
                                  f"[chat {origin} 42:{message}]\nUmer asks for a report."))["id"]
            run("jg-backlog.sh", "add", ticket, "Deliver the requested report", "-l", "captain-ask",
                "--priority", "0", "--kind", "scout", "--body", "Captain: Umer asks for a report.")
            run("jg-inbox.sh", "approve", note, ticket)
            (home / f"state/{ticket}.meta").write_text(f"ticket={ticket}\nkind=scout\n")
            (home / f"state/{ticket}.status").write_text(result + "\n")
            (home / f"data/{ticket}").mkdir()
            return note

        def rows():
            return {r["Ticket"]: r for r in json.loads(run("jg-inbox.sh", "outcomes")) or [] if not r.get("Home")}

        def tick():
            run("jg-bus.sh", "gateway", "--once")

        note = ask("jg-report", 7, result="done: report ready")
        report = home / "data/jg-report/report.md"
        original = b"# Report\n\nUmer can read the full report.\n"
        report.write_bytes(original)
        run("jg-recon-handoff.sh", "draft", "jg-report")
        run("jg-recon-handoff.sh", "verdict", "jg-report", "--critic", "jg-critic",
            "--hash", hashlib.sha256(original).hexdigest(), "--gaps", "0")
        run("jg-backlog.sh", "update", "jg-report", "--report", "data/jg-report/report.md")
        run("jg-backlog.sh", "done", "jg-report")
        run("jg-inbox.sh", "drain", "--ack", note)
        check("read acknowledgment is not a delivery receipt", rows()["jg-report"]["Delivery"] == "pending")
        tick()
        row = rows()["jg-report"]
        check("accepted report reaches its exact origin without Main",
              row["Delivery"] == "sent" and requests[-1]["reply"] == 7 and
              requests[-1]["chat"] == 42 and requests[-1]["file"] == original and bool(row["Parts"]))
        count = len(requests)
        tick()
        check("a restarted gateway does not resend saved parts", len(requests) == count)
        report.write_text("# Revised report\nUmer changed the draft.\n")
        tick()
        check("old acceptance cannot seal changed report bytes",
              rows()["jg-report"]["Delivery"] == "failed" and len(requests) == count)

        ask("jg-failed", 8)
        tick()
        check("failure is delivered without inventing success",
              rows()["jg-failed"]["Delivery"] == "sent" and "could not finish" in requests[-1]["text"])
        ask("jg-primary", 9, origin="primary")
        tick()
        check("primary origin has an explicit adapter failure", "no outbound adapter" in rows()["jg-primary"]["Problem"])
        ask("jg-refused", 10)
        modes["10"] = 400
        tick()
        check("API refusal remains a durable failure", rows()["jg-refused"]["Delivery"] == "failed")
        modes["10"] = 200
        tick()
        check("a refused send recovers on the next gateway pass", rows()["jg-refused"]["Delivery"] == "sent")
        ask("jg-outage", 11)
        modes["11"] = 502
        tick()
        check("API outage is not a receipt", rows()["jg-outage"]["Delivery"] == "failed")
        modes["11"] = 200
        tick()
        check("API outage recovers", rows()["jg-outage"]["Delivery"] == "sent")
        ask("jg-noid", 12)
        modes["12"] = "missing"
        tick()
        check("HTTP success without a platform ID stays ambiguous", rows()["jg-noid"]["Delivery"] == "ambiguous")
        count = len(requests)
        tick()
        check("ambiguous send is never blindly retried", len(requests) == count)
        ask("jg-unknown", 13, origin="unknown")
        tick()
        check("unknown adapter cannot fall back to another chat", rows()["jg-unknown"]["Delivery"] == "failed")
        ask("jg-lost", 14)
        modes["14"] = "disconnect"
        tick()
        check("lost network response stays explicitly ambiguous", rows()["jg-lost"]["Delivery"] == "ambiguous")
        ask("jg-revoked", 15)
        config = home / "config/captain-channel"
        config.write_text(config.read_text().replace("telegram-allow-user 42", "telegram-allow-user 43"))
        tick()
        check("revoked owner origin cannot receive a send", "no longer" in rows()["jg-revoked"]["Problem"])
        config.write_text(config.read_text().replace("telegram-allow-user 43", "telegram-allow-user 42"))
        tick()
        check("restored origin recovers without rebinding", rows()["jg-revoked"]["Delivery"] == "sent")

        ask("jg-cancelled", 16, result="")
        run("jg-backlog.sh", "done", "jg-cancelled", "--captain-quote", "Cancel the report, Umer no longer needs it.")
        tick()
        check("cancellation retains the recorded owner words",
              rows()["jg-cancelled"]["Delivery"] == "sent" and "Umer no longer needs it" in requests[-1]["text"])

        ask("jg-secret", 17, result="done: report ready")
        private = home / "config/private.md"
        private.write_text("# Umer lab private file\n")
        secret = home / "data/jg-secret/report.md"
        secret.symlink_to(private)
        run("jg-recon-handoff.sh", "draft", "jg-secret")
        run("jg-recon-handoff.sh", "verdict", "jg-secret", "--critic", "jg-critic", "--hash",
            hashlib.sha256(private.read_bytes()).hexdigest(), "--gaps", "0")
        count = len(requests)
        tick()
        check("file security refusal never becomes delivery",
              rows()["jg-secret"]["Delivery"] == "failed" and "secret" in rows()["jg-secret"]["Problem"] and len(requests) == count)

        missing = ask("jg-noorigin", 18)
        (home / f"state/inbox/{missing}.note").unlink()
        tick()
        check("missing origin cannot fall back to another chat", rows()["jg-noorigin"]["Delivery"] == "failed")

        ask("jg-interrupt", 19)
        modes["19"] = "block"
        child = subprocess.Popen(["bash", str(ROOT / "bin/jg-bus.sh"), "gateway", "--once"],
                                 env=env, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            check("gateway saves sending state before the API response", entered.wait(45) and rows()["jg-interrupt"]["Delivery"] == "sending")
            count = len(requests)
            tick()
            check("a concurrent gateway cannot send the same outcome", len(requests) == count)
            child.kill()
            child.communicate(timeout=10)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=10)
            barrier.set()
        modes["19"] = 200
        tick()
        check("restart after an interrupted send preserves ambiguity without duplicate",
              rows()["jg-interrupt"]["Delivery"] == "ambiguous" and len(requests) == count)
        squad(lab, home, env, run, check, rows, tick)
        (EVIDENCE / "steps.json").write_text(json.dumps({
            "target": {"version": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()},
            "start": "isolated home on its own tickets tables, no Main, loopback Bot API",
            "steps": steps, "result": "all recorded assertions passed; no live chat used"}, indent=2))
    finally:
        barrier.set()
        server.shutdown()
        server.server_close()
        thread.join()


def squad(lab, home, env, run, check, rows, tick):
    """A captain ask routed to a Squad Lead home answers its origin chat from Main's gateway."""
    def seed(name, parent):
        child = lab / name
        for part in ("config", "data", "state"):
            (child / part).mkdir(parents=True)
        (child / ".jg-squad-lead-parent").write_text(
            f"schema=jg-squad-lead-parent.v1\nroute=local\nparent_home={parent}\n")
        (child / ".jg-squad-lead-home").write_text(name + "\n")
        (child / "AGENTS.md").write_text("# Lab Squad Lead home\n")
        (child / "bin").mkdir()
        child_env = {k: v for k, v in env.items() if not k.startswith(("JG_", "BEADS_"))}
        child_env.update(JG_HOME=str(child))
        (child / "config/backlog-intake-loose").touch()
        with (home / "data/squad_leads.md").open("a") as registry:
            registry.write(f"- {name} - lab lead (home: {child}; scope: lab; projects: lab; added 2026-11-17)\n")
        return child, child_env

    def routed(child, child_env, ticket, message, body):
        note = json.loads(run("jg-inbox.sh", "note", "--json",
                              f"[chat telegram 42:{message}]\nUmer asks for a routed report."))["id"]
        run("jg-backlog.sh", "add", ticket, "Deliver the routed report", "-l", "captain-ask", "--priority", "0",
            "--kind", "scout", "--body", f'owner-words: note:{note} "Umer asks for a routed report."',
            in_env=child_env)
        (child / f"state/{ticket}.meta").write_text(f"ticket={ticket}\nkind=scout\n")
        (child / f"state/{ticket}.status").write_text("done: report ready\n")
        (child / f"data/{ticket}").mkdir()
        report = child / f"data/{ticket}/report.md"
        if isinstance(body, Path):
            report.symlink_to(body)
        else:
            report.write_bytes(body)
        run("jg-recon-handoff.sh", "draft", ticket, in_env=child_env)
        run("jg-recon-handoff.sh", "verdict", ticket, "--critic", "jg-critic", "--hash",
            hashlib.sha256(report.read_bytes()).hexdigest(), "--gaps", "0", in_env=child_env)
        run("jg-backlog.sh", "update", ticket, "--report", f"data/{ticket}/report.md", in_env=child_env)
        run("jg-backlog.sh", "done", ticket, in_env=child_env)

    def home_rows(lead):
        return [r for r in json.loads(run("jg-inbox.sh", "outcomes")) or [] if r.get("Home") == lead]

    child, child_env = seed("sl-lab", home)
    routed_bytes = b"# Routed report\n\nUmer reads the Squad Lead result.\n"
    routed(child, child_env, "jg-report", 21, routed_bytes)
    count = len(requests)
    tick()
    row = home_rows("sl-lab")[0]
    check("a Squad Lead result reaches its origin chat from Main's gateway",
          row["Delivery"] == "sent" and row["Ticket"] == "jg-report" and requests[-1]["reply"] == 21 and
          requests[-1]["chat"] == 42 and requests[-1]["file"] == routed_bytes and len(requests) == count + 1)
    check("the same ticket id in two homes stays two separate outcomes",
          rows()["jg-report"]["Delivery"] in ("sent", "failed") and row["Key"] != rows()["jg-report"]["Key"])
    check("the Squad Lead home gets no channel receipt of its own",
          not (child / "state/captain-chat").exists() and (home / f"state/captain-chat/ask-outcomes/{row['Key']}.json").exists())
    tick()
    check("a restarted gateway does not resend a routed result", len(requests) == count + 1)

    private = child / "config/private.md"
    private.write_text("Umer lab child secret\n")
    routed(child, child_env, "sl-secret", 22, private)
    tick()
    secret = [r for r in home_rows("sl-lab") if r["Ticket"] == "sl-secret"][0]
    check("a child home's secret file is never sent",
          secret["Delivery"] == "failed" and "secret" in secret["Problem"] and len(requests) == count + 1)

    note = json.loads(run("jg-inbox.sh", "note", "--json",
                          "[chat telegram 42:25]\nUmer asks Main to route this report."))["id"]
    run("jg-backlog.sh", "add", "jg-moved", "Deliver the handed-off report", "-l", "captain-ask", "--priority", "0",
        "--kind", "scout", "--body", f'owner-words: note:{note} "Umer asks Main to route this report."')
    moved = subprocess.run(["bash", str(ROOT / "bin/jg-backlog-handoff.sh"), "sl-lab", "jg-moved"], env=env,
                           cwd=ROOT, capture_output=True, text=True, timeout=90)
    with LOG.open("a") as log:
        log.write(f"$ jg-backlog-handoff.sh sl-lab jg-moved\n{moved.stdout}{moved.stderr}exit={moved.returncode}\n")
    check("Main's real handoff moves the ask; the lab has no live lead to wake",
          "destination backlog is durable" in moved.stderr and
          "jg-moved" in run("jg-backlog.sh", "show", "jg-moved", in_env=child_env))
    (child / "state/jg-moved.meta").write_text("ticket=jg-moved\nkind=scout\n")
    (child / "state/jg-moved.status").write_text("failed: Umer's routed work stopped in the Squad Lead home.\n")
    tick()
    handed = [r for r in home_rows("sl-lab") if r["Ticket"] == "jg-moved"][0]
    check("a handed-off ask's failure returns to its origin chat",
          handed["Delivery"] == "sent" and requests[-1]["reply"] == 25 and "stopped in the Squad Lead" in requests[-1]["text"])
    count = len(requests)

    (lab / "another-main").mkdir()   # a real main home that is not this one: the stranger's tickets live in its tables
    stranger, stranger_env = seed("sl-stranger", lab / "another-main")
    routed(stranger, stranger_env, "sl-elsewhere", 23, b"# Not for this chat\n")
    with (home / "data/squad_leads.md").open("a") as registry:
        registry.write(f"- sl-remote - remote lead (host: lab-host; root: /srv/jg; home: {lab}/remote; "
                       "scope: lab; projects: lab; added 2026-11-17)\n")
    tick()
    check("a home that does not name Main as parent is listed unreadable and sends nothing",
          [r["Delivery"] for r in home_rows("sl-stranger")] == ["unreadable"] and
          "parent record" in home_rows("sl-stranger")[0]["Problem"] and len(requests) == count)
    check("a remote Squad Lead stays visible as not delivered from this host",
          "another host" in home_rows("sl-remote")[0]["Problem"])


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="jg-ask-outcomes-") as scratch:
        main(Path(scratch))
