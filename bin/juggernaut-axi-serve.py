#!/usr/bin/env python3
"""juggernaut-axi serve: opt-in, loopback-only HTTP API.

GET uses config/juggernaut-axi-token. POST to a changing contract path also requires the owner
to create config/juggernaut-axi-write-token before startup. Both files hold distinct random
tokens of at least 32 characters with mode 0600. Send the token for the method in Authorization.
POST accepts an application/json object of named arguments or an array of CLI argument words,
up to 64 KiB. An Idempotency-Key on a command with --key is passed to the dispatcher's repeat
guard. GET has no body. Both methods refuse an Origin header or a non-loopback Host, rate limit
each scope separately, and share a smaller bucket for failed authentication.
"""
import argparse, glob, hmac, json, os, re, stat, subprocess, sys, time
from collections import deque
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "juggernaut-axi")
MAX_BODY_BYTES = 64 * 1024
POST_STATUS = {0: 200, 1: 403, 2: 400, 3: 409, 4: 404, 5: 503}
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


def contract_args(entry, query):
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
    positions = [name.removesuffix("...") for name in re.findall(r"<([^>]+)>", positional_form)]
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
        elif name == "key" and name not in positions:
            argv.extend(["--key", value])
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
    return argv


def json_object(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate JSON argument")
    return result


def post_args(entry, raw, key):
    body = json.loads(raw.decode("utf-8"), object_pairs_hook=json_object) if raw else {}
    if isinstance(body, dict):
        if key is not None and ("key" in body or body.get("again") in (True, "true")):
            raise ValueError("Idempotency-Key conflicts with key or again")
        if any(type(value) not in (str, bool, int) for value in body.values()):
            raise ValueError("named arguments must be strings, booleans or integers")
        args = contract_args(entry, {
            name: [json.dumps(value) if type(value) is bool else str(value)]
            for name, value in body.items()
        })
    elif isinstance(body, list) and all(isinstance(word, str) for word in body):
        args = body
        if key is not None and ("--key" in args or "--again" in args):
            raise ValueError("Idempotency-Key conflicts with --key or --again")
    else:
        raise ValueError("expected a JSON object of named arguments or an array of CLI words")
    if any(re.search(r"[\x00\ud800-\udfff]", word) for word in args):
        raise ValueError("arguments must be valid UTF-8 without NUL")
    if key is None:
        return args
    if not key or not key.isascii() or not key.isprintable():
        raise ValueError("invalid Idempotency-Key")
    if not any(arg["name"] == "key" for arg in entry["args"]):
        raise ValueError("this command does not accept Idempotency-Key")
    return ["--key", key] + args


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


def load_write_token(config_dir, read_token):
    path = os.path.join(config_dir, "juggernaut-axi-write-token")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as exc:
        sys.exit(f"juggernaut-axi serve: cannot open write token file: {exc.strerror}")
    try:
        with os.fdopen(fd, encoding="utf-8") as file:
            st = os.fstat(file.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o600:
                sys.exit(f"juggernaut-axi serve: write token must be an owner-owned regular file with mode 0600: {path}")
            token = file.read().strip()
    except (OSError, UnicodeError):
        sys.exit("juggernaut-axi serve: could not read the write token file")
    if len(token) < 32 or not token.isascii() or not token.isprintable():
        sys.exit("juggernaut-axi serve: write token must be at least 32 printable ASCII characters")
    if hmac.compare_digest(token.encode(), read_token.encode()):
        sys.exit("juggernaut-axi serve: read and write tokens must be different")
    return token


class Handler(BaseHTTPRequestHandler):
    server_version = "juggernaut-axi"
    sys_version = ""
    timeout = 10

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

    def local_request(self):
        port = self.server.server_port
        if self.headers.get_all("Host") not in ([f"127.0.0.1:{port}"], [f"localhost:{port}"]):
            self.fail(403, "host not allowed")
            return False
        if self.headers.get("Origin") is not None:
            self.fail(403, "cross-origin requests are not allowed")
            return False
        return True

    def authenticate(self, scope, token):
        headers = self.headers.get_all("Authorization", [])
        auth = headers[0] if len(headers) == 1 else ""
        presented = auth[7:] if auth.startswith("Bearer ") else ""
        if not hmac.compare_digest(presented.encode(), token.encode()):
            if not self.allowed("auth-failures", 20):
                self.fail(429, "too many failed attempts", [("Retry-After", "60")])
            elif scope == "writes" and hmac.compare_digest(presented.encode(), self.server.token.encode()):
                self.fail(403, "write bearer token required")
            else:
                self.fail(401, "bearer token required", [("WWW-Authenticate", "Bearer")])
            return False
        if not self.allowed(scope, self.server.reads_per_minute):
            self.fail(429, "rate limit exceeded", [("Retry-After", "60")])
            return False
        return True

    def do_GET(self):
        if not self.local_request():
            return
        if self.headers.get("Content-Length", "0") != "0" or self.headers.get("Transfer-Encoding"):
            return self.fail(413, "request bodies are not accepted")
        if not self.authenticate("reads", self.server.token):
            return
        url = urlsplit(self.path)
        route = ROUTES.get(url.path)
        if route is None:
            entry = self.server.contract.get(url.path)
            if entry is None:
                return self.fail(404, "unknown route")
            if entry["method"] != "GET":
                return self.fail(405, "read scope only: GET", [("Allow", "GET")])
            try:
                argv = [CLI] + entry["path"] + contract_args(entry, parse_qs(url.query, keep_blank_values=True))
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

    def do_POST(self):
        if not self.local_request():
            return
        try:
            url = urlsplit(self.path)
        except ValueError:
            return self.fail(400, "invalid request path")
        entry = self.server.contract.get(url.path)
        if url.path in ROUTES or (entry is not None and entry["method"] == "GET"):
            return self.fail(405, "route accepts GET only", [("Allow", "GET")])
        if entry is None:
            return self.fail(404, "unknown route")
        if self.server.write_token is None:
            return self.fail(403, "changes are off on this installation")
        if not self.authenticate("writes", self.server.write_token):
            return
        if url.query:
            return self.fail(400, "send POST arguments in the JSON body")
        lengths = self.headers.get_all("Content-Length", ["0"])
        if self.headers.get("Transfer-Encoding") is not None:
            return self.fail(400, "transfer encoding is not accepted")
        if len(lengths) != 1 or not re.fullmatch(r"[0-9]+", lengths[0]):
            return self.fail(400, "invalid Content-Length")
        size = lengths[0].lstrip("0") or "0"
        if len(size) > len(str(MAX_BODY_BYTES)) or int(size) > MAX_BODY_BYTES:
            return self.fail(413, "request body is over 64 KiB")
        if int(size) and self.headers.get_content_type() != "application/json":
            return self.fail(415, "POST body must be application/json")
        keys = self.headers.get_all("Idempotency-Key", [])
        if len(keys) > 1:
            return self.fail(400, "send at most one Idempotency-Key")
        try:
            body = self.rfile.read(int(size))
            if len(body) != int(size):
                return self.fail(400, "incomplete request body")
            args = post_args(entry, body, keys[0] if keys else None)
        except TimeoutError:
            return self.fail(408, "request body timed out")
        except (json.JSONDecodeError, UnicodeError, RecursionError):
            return self.fail(400, "invalid JSON body")
        except ValueError as exc:
            return self.fail(400, str(exc))

        words = entry["path"] + args
        # The dispatcher matches the longest prefix. Argument words cannot select a different route.
        depth = min(len(words), self.server.command_depth)
        if any(tuple(words[:i]) in self.server.command_paths for i in range(len(entry["path"]) + 1, depth + 1)):
            return self.fail(400, "arguments must not select another route")
        try:
            run = subprocess.run(["bash", DISPATCH, "--as", "jg", "run"] + words,
                                 capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return self.fail(504, "fleet change timed out")
        if run.stdout:
            return self.reply(POST_STATUS.get(run.returncode, 500), run.stdout)
        if run.returncode == 2:
            return self.fail(400, run.stderr.strip())
        return self.fail(500, "fleet change failed")

    def _refuse(self):
        self.fail(405, "method not allowed")

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _refuse


def main():
    ap = argparse.ArgumentParser(
        prog="juggernaut-axi serve",
        description="Loopback API. Create config/juggernaut-axi-write-token (0600) to enable POST.",
        epilog="POST a JSON object of named arguments or an array of CLI argument words (up to 64 KiB).",
    )
    ap.add_argument("--port", type=int, default=0, help="port on 127.0.0.1 (default: OS-assigned)")
    ap.add_argument("--reads-per-minute", type=int, default=60)
    args = ap.parse_args()
    if args.reads_per_minute < 1:
        sys.exit("juggernaut-axi serve: --reads-per-minute must be positive")
    config = os.environ.get("JG_CONFIG_OVERRIDE") or os.path.join(os.environ["JUGGERNAUT_AXI_HOME"], "config")
    token = load_token(config)
    write_token = load_write_token(config, token)
    contract = load_contract()
    srv = HTTPServer(("127.0.0.1", args.port), Handler)
    srv.contract = contract
    srv.command_paths = {tuple(e["path"]) for e in contract.values()} | {
        tuple(alias.split(" ")) for e in contract.values() for alias in e["aliases"]
    }
    srv.command_depth = max(map(len, srv.command_paths), default=0)
    srv.write_token = write_token
    srv.token, srv.reads_per_minute, srv.hits = token, args.reads_per_minute, {}
    print("listening http://127.0.0.1:%d" % srv.server_port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
