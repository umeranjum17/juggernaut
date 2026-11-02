package main

import (
	"bytes"
	"strings"
)

// A reader takes one JSON document from a herdr answer and emits the lines jq printed for it.
type reader func(doc raw, emit func(string)) error

func dotted(path string) []string {
	return strings.Split(strings.Trim(path, "."), ".")
}

// fieldReader is `jq -r '.a.b.c // empty'` and, with a default, `jq -r '.a.b.c // <default>'`.
func fieldReader(path []string, def *string) reader {
	return func(doc raw, emit func(string)) error {
		v, err := walk(doc, path)
		if err != nil {
			return err
		}
		switch {
		case truthy(v):
			emit(text(v))
		case def != nil:
			emit(*def)
		}
		return nil
	}
}

// selectReader is `.<array>[]? | select(.<key> == <want>) | .<out>`, where want is a string,
// or the boolean true; with orEmpty the output is `.<out> // empty`.
func selectReader(array []string, key string, want *string, out string, orEmpty bool) reader {
	return func(doc raw, emit func(string)) error {
		els, err := elements(doc, array)
		if err != nil {
			return err
		}
		for _, el := range els {
			got, err := index(el, key)
			if err != nil {
				return err
			}
			if want == nil && kind(got) != 't' || want != nil && !isString(got, *want) {
				continue
			}
			v, err := index(el, out)
			if err != nil {
				return err
			}
			if orEmpty && !truthy(v) {
				continue
			}
			emit(text(v))
		}
		return nil
	}
}

// workspaceIDs is the workspace find: `.result.workspaces[]? | select(.label == $want or
// ($old | length > 0 and .label == $old)) | .workspace_id`.
func workspaceIDs(label, legacy string) reader {
	return func(doc raw, emit func(string)) error {
		els, err := elements(doc, []string{"result", "workspaces"})
		if err != nil {
			return err
		}
		for _, el := range els {
			got, err := index(el, "label")
			if err != nil {
				return err
			}
			if !isString(got, label) && !(legacy != "" && isString(got, legacy)) {
				continue
			}
			id, err := index(el, "workspace_id")
			if err != nil {
				return err
			}
			emit(text(id))
		}
		return nil
	}
}

// liveTabs lists "<tab_id>\t<label>" for every tab whose label starts with jg-; a label that
// is not a string is an error, as jq's startswith makes it.
func liveTabs(doc raw, emit func(string)) error {
	els, err := elements(doc, []string{"result", "tabs"})
	if err != nil {
		return err
	}
	for _, el := range els {
		label, err := index(el, "label")
		if err != nil {
			return err
		}
		if kind(label) != '"' {
			return errf("startswith() requires string inputs")
		}
		if !strings.HasPrefix(text(label), "jg-") {
			continue
		}
		id, err := index(el, "tab_id")
		if err != nil {
			return err
		}
		emit(tostring(id) + "\t" + text(label))
	}
	return nil
}

// agentIdentity is `[.result.agent.agent // "", .result.agent.agent_status // ""] | @tsv`.
func agentIdentity(doc raw, emit func(string)) error {
	cells := make([]string, 2)
	for i, key := range []string{"agent", "agent_status"} {
		v, err := walk(doc, []string{"result", "agent", key})
		if err != nil {
			return err
		}
		if !truthy(v) {
			continue
		}
		switch kind(v) {
		case '{', '[':
			return errf("%s cannot be tsv-formatted, only an array can be", kindName(v))
		case '"':
			cells[i] = tsvEscape(text(v))
		default:
			cells[i] = text(v)
		}
	}
	emit(cells[0] + "\t" + cells[1])
	return nil
}

func tsvEscape(s string) string {
	return strings.NewReplacer("\\", "\\\\", "\t", "\\t", "\n", "\\n", "\r", "\\r").Replace(s)
}

// clientStatus is "<running>|<compatible>" from `status --json`, each empty when the client
// did not report it: running is .server.running, compatible is .server.compatible or, when
// the client does not emit it, whether the client and server protocols are equal.
func clientStatus(doc raw, emit func(string)) error {
	server, err := index(doc, "server")
	if err != nil {
		return err
	}
	client, err := index(doc, "client")
	if err != nil {
		return err
	}
	var running, compatible string
	isObj := kind(server) == '{'
	if isObj {
		r, err := index(server, "running")
		if err != nil {
			return err
		}
		if !isNull(r) {
			running = tostring(r)
		}
		ms, err := members(server)
		if err != nil {
			return err
		}
		for _, m := range ms {
			if m.key == "compatible" {
				compatible = tostring(m.val)
				emit(running + "|" + compatible)
				return nil
			}
		}
	}
	cp, err := index(client, "protocol")
	if err != nil {
		return err
	}
	if !isNull(cp) {
		sp, err := index(server, "protocol")
		if err != nil {
			return err
		}
		if !isNull(sp) {
			compatible = "false"
			if equal(cp, sp) {
				compatible = "true"
			}
		}
	}
	emit(running + "|" + compatible)
	return nil
}

// serverRunning is the tri-state `.server.running`: running, stopped or unknown.
func serverRunning(doc raw, emit func(string)) error {
	v, err := walk(doc, []string{"server", "running"})
	if err != nil {
		return err
	}
	switch {
	case kind(v) == 't':
		emit("running")
	case kind(v) == 'f':
		emit("stopped")
	default:
		emit("unknown")
	}
	return nil
}

// workspacePresence is the count of workspaces named <id> in `workspace list`, as
// dead (none), present (one) or unknown (a malformed list or several).
func workspacePresence(id string) reader {
	return func(doc raw, emit func(string)) error {
		ws, err := walk(doc, []string{"result", "workspaces"})
		if err != nil {
			return err
		}
		if kind(ws) != '[' {
			return nil
		}
		els, err := iterate(ws)
		if err != nil {
			return err
		}
		n := 0
		for _, el := range els {
			got, err := index(el, "workspace_id")
			if err != nil {
				return err
			}
			if isString(got, id) {
				n++
			}
		}
		switch n {
		case 0:
			emit("dead")
		case 1:
			emit("present")
		default:
			emit("unknown")
		}
		return nil
	}
}

// run feeds every document of data to r and returns the lines it printed; the error is what
// jq would have exited 5 on, after the lines printed before it.
func run(data []byte, r reader) ([]string, error) {
	var out []string
	err := documents(bytes.NewReader(data), func(doc raw) error {
		return r(doc, func(s string) { out = append(out, s) })
	})
	return out, err
}

// fieldText is `$(... | jq -r '.a.b // empty' 2>/dev/null)`: what the substitution holds, with
// any error ignored.
func fieldText(data []byte, path ...string) string {
	out, _ := run(data, fieldReader(path, nil))
	return substitution(out)
}

// panePresence reads a `pane get` answer (its stderr merged in, so it may not be JSON): an
// error code names the pane dead (pane_not_found) or unknown, and a pane reads present only
// when it names itself.
func panePresence(data []byte, pane string) string {
	if code := fieldText(data, "error", "code"); code != "" {
		if code == "pane_not_found" {
			return "dead"
		}
		return "unknown"
	}
	if fieldText(data, "result", "pane", "pane_id") == pane {
		return "present"
	}
	return "unknown"
}
