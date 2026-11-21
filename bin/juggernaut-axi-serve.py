#!/usr/bin/env python3
"""juggernaut-axi serve: opt-in, loopback-only, read-scope HTTP API (juggernaut-axi.v1).

Each route runs the matching `juggernaut-axi <command> --json` and returns its output, so the CLI stays
the single owner of the model. Opt-in: refuses to start without an owner-only token file
(config/juggernaut-axi-token, at least 32 characters, mode 0600). Every request needs
`Authorization: Bearer <token>`; requests with an Origin header, a Host other than loopback, any
method but GET, or a body are refused. The token is never logged or returned. Reads are rate limited
per token (a sliding minute); failed auth attempts share one smaller bucket. This is defense in depth,
not protection from another process running as the same OS user.
"""
import argparse, glob, hmac, json, os, re, stat, subprocess, sys, time
from collections import deque
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "juggernaut-axi")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
NUM = re.compile(r"^[0-9]{1,3}$")
# route -> allowed query parameters and their validators
ROUTES = {
    "/v1/status": ("status", {}),
    "/v1/tickets": ("tickets", {"state": NAME, "repo": NAME, "limit": NUM}),
    "/v1/decisions": ("decisions", {}),
    "/v1/messages": ("messages", {"task": NAME, "limit": NUM}),
}


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISPATCH = os.path.join(ROOT, "core", "agent-cli", "dispatch.sh")


def load_contract():
    subprocess.run(["bash", DISPATCH, "check"], check=True)
    routes = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "core", "agent-cli", "contract", "*.json"))):
        with open(path) as f:
            for entry in json.load(f)["entries"]:
                routes["/v1/" + "/".join(entry["path"])] = entry
    return routes


def contract_argv(entry, query):
    args = {arg["name"]: arg for arg in entry["args"]}
    for key, values in query.items():
        if key not in args or len(values) != 1 or not values[0] or "\x00" in values[0]:
            raise ValueError("invalid query parameter: " + key)
    for arg in entry["args"]:
        if arg.get("required") and arg["name"] not in query:
            raise ValueError(arg["name"] + " is required")
    form = entry["form"]
    options = dict((name, flag) for flag, name in re.findall(r"(--[a-z0-9-]+)\s+<([^>]+)>", form))
    positional_form = re.sub(r"--[a-z0-9-]+\s+<[^>]+>", "", form)
    positions = re.findall(r"<([^>]+)>", positional_form)
    argv, positional = [], []
    for name, arg in args.items():
        if name not in query:
            continue
        value = query[name][0]
        if arg["type"] == "flag":
            if value not in ("true", "false"):
                raise ValueError("invalid query parameter: " + name)
            if value == "true":
                argv.append(arg.get("flag", "--" + name))
        elif name in options:
            argv.extend([options[name], value])
        elif name not in positions:
            raise ValueError("unsupported query parameter: " + name)
    missing = False
    for name in positions:
        if name not in query:
            missing = True
        elif missing:
            raise ValueError("missing preceding positional argument")
        else:
            positional.append(query[name][0])
    if positional:
        argv.extend(["--"] + positional)
    return [CLI] + entry["path"] + argv


def load_token(config_dir):
    path = os.path.join(config_dir, "juggernaut-axi-token")
    try:
        st = os.stat(path)
        with open(path) as f:
            token = f.read().strip()
    except OSError:
        sys.exit("juggernaut-axi serve: API is opt-in; create a random token (32+ characters, mode 0600) at " + path)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.exit("juggernaut-axi serve: token file must be owner-only (chmod 600 " + path + ")")
    if len(token) < 32:
        sys.exit("juggernaut-axi serve: token must be at least 32 characters")
    return token


class Handler(BaseHTTPRequestHandler):
    server_version = "juggernaut-axi"
    sys_version = ""

    def log_message(self, *args):  # no request logging: nothing here may carry the token
        pass

    def reply(self, code, body, ctype="application/json", extra=()):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def fail(self, code, msg, extra=()):
        self.reply(code, json.dumps({"schema": "juggernaut-axi.v1", "error": msg}), extra=extra)

    def allowed(self, bucket, limit):
        now = time.monotonic()
        q = self.server.hits.setdefault(bucket, deque())
        while q and now - q[0] > 60:
            q.popleft()
        if len(q) >= limit:
            return False
        q.append(now)
        return True

    def do_GET(self):
        host = self.headers.get("Host", "")
        if host not in ("127.0.0.1:%d" % self.server.server_port, "localhost:%d" % self.server.server_port):
            return self.fail(403, "host not allowed")
        if self.headers.get("Origin") is not None:
            return self.fail(403, "cross-origin requests are not allowed")
        if self.headers.get("Content-Length", "0") != "0" or self.headers.get("Transfer-Encoding"):
            return self.fail(413, "request bodies are not accepted")
        auth = self.headers.get("Authorization", "")
        presented = auth[7:] if auth.startswith("Bearer ") else ""
        if not hmac.compare_digest(presented.encode(), self.server.token.encode()):
            if not self.allowed("auth-failures", 20):
                return self.fail(429, "too many failed attempts", [("Retry-After", "60")])
            return self.fail(401, "bearer token required", [("WWW-Authenticate", "Bearer")])
        if not self.allowed("reads", self.server.reads_per_minute):
            return self.fail(429, "rate limit exceeded", [("Retry-After", "60")])
        url = urlsplit(self.path)
        route = ROUTES.get(url.path)
        if route is None:
            entry = self.server.contract.get(url.path)
            if entry is None:
                return self.fail(404, "unknown route")
            if entry["method"] != "GET":
                return self.fail(405, "read scope only: GET", [("Allow", "GET")])
            try:
                argv = contract_argv(entry, parse_qs(url.query, keep_blank_values=True))
            except ValueError as exc:
                return self.fail(400, str(exc))
            try:
                run = subprocess.run(argv, capture_output=True, text=True, timeout=60)
            except subprocess.TimeoutExpired:
                return self.fail(504, "fleet read timed out")
            if run.returncode == 0:
                return self.reply(200, run.stdout)
            if run.returncode == 2:
                return self.fail(400, run.stderr.strip())
            return self.fail(500, "fleet read failed")
        command, params = route
        argv = [CLI, command]
        query = parse_qs(url.query, keep_blank_values=True)
        for key, values in query.items():
            if key not in params or len(values) != 1 or not params[key].match(values[0]):
                return self.fail(400, "invalid query parameter: " + key)
        if command == "messages":
            if "task" not in query:
                return self.fail(400, "task is required")
            argv.append(query.pop("task")[0])
        for key, values in query.items():
            argv += ["--" + key, values[0]]
        toon = "application/toon" in self.headers.get("Accept", "")
        if not toon:
            argv.append("--json")
        try:
            run = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return self.fail(504, "fleet read timed out")
        if run.returncode == 0:
            return self.reply(200, run.stdout, "application/toon" if toon else "application/json")
        # exit 2 is the CLI refusing the request (unknown task, bad argument); the rest is not for clients
        if run.returncode == 2:
            return self.fail(400, run.stderr.strip().removeprefix("juggernaut-axi: "))
        self.fail(500, "fleet read failed")

    def _refuse(self):
        self.fail(405, "read scope only: GET", [("Allow", "GET")])

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _refuse


def main():
    ap = argparse.ArgumentParser(prog="juggernaut-axi serve")
    ap.add_argument("--port", type=int, default=0, help="port on 127.0.0.1 (default: OS-assigned)")
    ap.add_argument("--reads-per-minute", type=int, default=60)
    args = ap.parse_args()
    if args.reads_per_minute < 1:
        sys.exit("juggernaut-axi serve: --reads-per-minute must be positive")
    config = os.environ.get("JG_CONFIG_OVERRIDE") or os.path.join(os.environ["JUGGERNAUT_AXI_HOME"], "config")
    token = load_token(config)
    contract = load_contract()
    srv = HTTPServer(("127.0.0.1", args.port), Handler)
    srv.contract = contract
    srv.token, srv.reads_per_minute, srv.hits = token, args.reads_per_minute, {}
    print("listening http://127.0.0.1:%d" % srv.server_port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
