package main

import (
	"encoding/json"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// The checks are the herdr adapter's `jq -e` programs: a predicate over one answer, or a value
// that must exist. Each is one named function that keeps its jq program's evaluation order, so
// `and` stops at the first false operand and an index of the wrong type is an error only where
// jq reached it. A program emits the values jq printed; evalE gives jq -e's exit status.

// program is one jq -e program applied to one JSON document.
type program func(doc raw, emit func(raw)) error

// Exit statuses of jq -e, kept so a caller can tell a false verdict from a failed read:
// 0 the last output was truthy, 1 it was false or null, 4 there was no output, 5 an error.
const (
	exitTrue   = 0
	exitFalse  = 1
	exitNoOut  = 4
	exitFailed = 5
)

// evalE runs p over every document in r and prints what jq -r printed. The status is the one
// jq -e ends with: a parse error or an error in the last document is 5, otherwise the last
// output decides (0 truthy, 1 false or null), and no output at all is 4. An error in an
// earlier document is forgotten, as jq forgets it.
func evalE(r io.Reader, p program, print func(string)) int {
	var last raw
	var lastErr, seen bool
	err := documents(r, func(doc raw) error {
		lastErr = false
		var outs []raw
		if e := p(doc, func(v raw) { outs = append(outs, v) }); e != nil {
			lastErr = true
		}
		for _, v := range outs {
			print(text(v))
			last, seen = v, true
		}
		return nil
	})
	switch {
	case err != nil, lastErr:
		return exitFailed
	case !seen:
		return exitNoOut
	case truthy(last):
		return exitTrue
	}
	return exitFalse
}

func jbool(b bool) raw {
	if b {
		return raw("true")
	}
	return raw("false")
}

// all is jq's `A and B and ...`: operands run in order and the first false one ends it.
func all(ops ...func() (bool, error)) (bool, error) {
	for _, op := range ops {
		if ok, err := op(); err != nil || !ok {
			return false, err
		}
	}
	return true, nil
}

// is reports `walk(path) == <string>`.
func is(doc raw, want string, path ...string) func() (bool, error) {
	return func() (bool, error) {
		v, err := walk(doc, path)
		return err == nil && isString(v, want), err
	}
}

// key reports `.key == <string>` on one element.
func key(el raw, k, want string) func() (bool, error) {
	return func() (bool, error) {
		v, err := index(el, k)
		return err == nil && isString(v, want), err
	}
}

// at is `.[i]`: null indexes to null, an array to its element or null, anything else errors.
func at(v raw, i int) (raw, error) {
	switch kind(v) {
	case 'n':
		return raw("null"), nil
	case '[':
		els, err := iterate(v)
		if err != nil {
			return nil, err
		}
		if i < 0 {
			i += len(els)
		}
		if i < 0 || i >= len(els) {
			return raw("null"), nil
		}
		return els[i], nil
	}
	return nil, errf("Cannot index %s with number", kindName(v))
}

// firstOf is `.a.b[0]`.
func firstOf(doc raw, path ...string) (raw, error) {
	v, err := walk(doc, path)
	if err != nil {
		return nil, err
	}
	return at(v, 0)
}

// array reads `(.a.b | type) == "array"` and, when it holds, the elements.
func array(doc raw, path ...string) ([]raw, bool, error) {
	v, err := walk(doc, path)
	if err != nil || kind(v) != '[' {
		return nil, false, err
	}
	els, err := iterate(v)
	return els, err == nil, err
}

// altNull is `(.a.b // null)`: a false value reads null. An error in the path stays an error,
// which is how the jq the adapter ran treats it.
func altNull(doc raw, path ...string) (raw, error) {
	v, err := walk(doc, path)
	if err != nil {
		return nil, err
	}
	if !truthy(v) {
		return raw("null"), nil
	}
	return v, nil
}

// codepoints is jq's `length` of a string.
func codepoints(s string) int { return len([]rune(s)) }

func isArrayAt(path []string) program {
	return func(doc raw, emit func(raw)) error {
		_, ok, err := array(doc, path...)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// sole is `(.result.<array> | type) == "array" and (.result.<array> | length) == 1 and
// .result.<array>[0].<k> == <v> ...`: the one element of a list read with its identity.
func sole(list string, checks ...[2]string) program {
	return func(doc raw, emit func(raw)) error {
		ok, err := all(
			func() (bool, error) { _, ok, err := array(doc, "result", list); return ok, err },
			func() (bool, error) {
				els, _, err := array(doc, "result", list)
				return len(els) == 1, err
			},
			func() (bool, error) {
				first, err := firstOf(doc, "result", list)
				if err != nil {
					return false, err
				}
				for _, c := range checks {
					if good, err := key(first, c[0], c[1])(); err != nil || !good {
						return false, err
					}
				}
				return true, nil
			},
		)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// tabBinds is `.result.tab.tab_id == $tab and .result.tab.workspace_id == $workspace`.
func tabBinds(tab, workspace string) program {
	return func(doc raw, emit func(raw)) error {
		ok, err := all(is(doc, tab, "result", "tab", "tab_id"), is(doc, workspace, "result", "tab", "workspace_id"))
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// paneBinds is the pane get answer naming its own tab and workspace.
func paneBinds(pane, tab, workspace string) program {
	return func(doc raw, emit func(raw)) error {
		ok, err := all(
			is(doc, pane, "result", "pane", "pane_id"),
			is(doc, tab, "result", "pane", "tab_id"),
			is(doc, workspace, "result", "pane", "workspace_id"),
		)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// infoMatches is a `pane get` or `agent get` answer that is the named pane, in the named
// workspace and tab and directory, with no agent registered (status "unknown").
func infoMatches(typ, obj, pane, workspace, tab, cwd string) program {
	return func(doc raw, emit func(raw)) error {
		ok, err := all(
			is(doc, typ, "result", "type"),
			is(doc, pane, "result", obj, "pane_id"),
			is(doc, workspace, "result", obj, "workspace_id"),
			is(doc, tab, "result", obj, "tab_id"),
			is(doc, cwd, "result", obj, "foreground_cwd"),
			is(doc, "unknown", "result", obj, "agent_status"),
		)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// processInfoPane is a `pane process-info` answer that is for the named pane.
func processInfoPane(pane string) program {
	return func(doc raw, emit func(raw)) error {
		ok, err := all(is(doc, "pane_process_info", "result", "type"), is(doc, pane, "result", "process_info", "pane_id"))
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// workspaceUnique is the workspace list holding the named workspace exactly once.
func workspaceUnique(workspace string) program {
	return func(doc raw, emit func(raw)) error {
		ok, err := all(
			func() (bool, error) { _, ok, err := array(doc, "result", "workspaces"); return ok, err },
			func() (bool, error) {
				els, _, err := array(doc, "result", "workspaces")
				n := 0
				for _, el := range els {
					good, e := key(el, "workspace_id", workspace)()
					if e != nil {
						return false, e
					}
					if good {
						n++
					}
				}
				return n == 1, err
			},
		)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// focusTabIs is the tab list with exactly one focused tab, and it is the named one.
func focusTabIs(tab string) program {
	return func(doc raw, emit func(raw)) error {
		els, isArr, err := array(doc, "result", "tabs")
		if err != nil {
			return err
		}
		if !isArr {
			emit(raw("false"))
			return nil
		}
		focused, err := focusedOf(els)
		if err != nil {
			return err
		}
		if len(focused) != 1 {
			emit(raw("false"))
			return nil
		}
		ok, err := key(focused[0], "tab_id", tab)()
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// focusedOf is `[.[] | select(.focused == true)]`.
func focusedOf(els []raw) ([]raw, error) {
	var out []raw
	for _, el := range els {
		f, err := index(el, "focused")
		if err != nil {
			return nil, err
		}
		if kind(f) == 't' {
			out = append(out, el)
		}
	}
	return out, nil
}

// shapeTabs is the tab list whose first tab is the task's and which holds none of the seeded one.
func shapeTabs(task, seeded string) program {
	return func(doc raw, emit func(raw)) error {
		first, err := firstOf(doc, "result", "tabs")
		if err != nil {
			return err
		}
		ok, err := key(first, "tab_id", task)()
		if err == nil && ok {
			var n int
			n, err = countWhere(doc, []string{"result", "tabs"}, func(el raw) (bool, error) { return key(el, "tab_id", seeded)() })
			ok = n == 0
		}
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// shapePanes is the pane list whose first pane is the task's pane, in the task's tab.
func shapePanes(pane, tab string) program {
	return func(doc raw, emit func(raw)) error {
		first, err := firstOf(doc, "result", "panes")
		if err != nil {
			return err
		}
		ok, err := all(key(first, "pane_id", pane), key(first, "tab_id", tab))
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// countWhere is `[<path>[] | select(f)] | length`.
func countWhere(doc raw, path []string, f func(el raw) (bool, error)) (int, error) {
	v, err := walk(doc, path)
	if err != nil {
		return 0, err
	}
	els, err := iterate(v)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, el := range els {
		ok, err := f(el)
		if err != nil {
			return 0, err
		}
		if ok {
			n++
		}
	}
	return n, nil
}

// sessionSocket is the socket path of the one running session of that name.
func sessionSocket(want string) program {
	return func(doc raw, emit func(raw)) error {
		els, err := elements(doc, []string{"sessions"})
		if err != nil {
			return err
		}
		var found []raw
		for _, el := range els {
			named, err := key(el, "name", want)()
			if err != nil || !named {
				if err != nil {
					return err
				}
				continue
			}
			running, err := index(el, "running")
			if err != nil {
				return err
			}
			sock, err := index(el, "socket_path")
			if err != nil {
				return err
			}
			if kind(running) == 't' && kind(sock) == '"' && text(sock) != "" {
				found = append(found, sock)
			}
		}
		if len(found) == 1 {
			emit(found[0])
		}
		return nil
	}
}

// parentWorkspaceExact is the workspace id of the one workspace labelled <label> (or its legacy
// label), when that id is a non-empty string.
func parentWorkspaceExact(label, legacy string) program {
	return func(doc raw, emit func(raw)) error {
		spaces, err := altNull(doc, "result", "workspaces")
		if err != nil || kind(spaces) != '[' {
			return err
		}
		els, _ := iterate(spaces)
		var hit []raw
		for _, el := range els {
			ok, err := labelIs(el, label, legacy)
			if err != nil {
				return err
			}
			if ok {
				hit = append(hit, el)
			}
		}
		if len(hit) != 1 {
			return nil
		}
		id, err := index(hit[0], "workspace_id")
		if err != nil {
			return err
		}
		if kind(id) == '"' && text(id) != "" {
			emit(id)
		}
		return nil
	}
}

// labelIs is `.label == $a or (($b | length) > 0 and .label == $b)`.
func labelIs(el raw, a, b string) (bool, error) {
	if ok, err := key(el, "label", a)(); err != nil || ok {
		return ok, err
	}
	if b == "" {
		return false, nil
	}
	return key(el, "label", b)()
}

var (
	newChild    = regexp.MustCompile(`^└ .+ · p:[A-Za-z0-9_-]{22}\n?\z`)
	legacyChild = regexp.MustCompile(`^(juggernaut|(lead|2ndmate)-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}\n?\z`)
)

// stringLabel reads an element's `.label` when it is a string.
func stringLabel(el raw) (string, bool, error) {
	l, err := index(el, "label")
	if err != nil || kind(l) != '"' {
		return "", false, err
	}
	return text(l), true, nil
}

// liveBinding is the workspace list proving one projected workspace: it is listed once, with
// its label, it is the only workspace carrying the token, its parent is listed once with the
// parent's label, and every workspace between the two is a child of that parent.
func liveBinding(token, workspace, parentWS, parentLabel, parentOld, workspaceLabel string) program {
	suffix := " · p:" + token
	return func(doc raw, emit func(raw)) error {
		spaces, err := altNull(doc, "result", "workspaces")
		if err != nil || kind(spaces) != '[' {
			return err
		}
		els, _ := iterate(spaces)
		once := func(f func(el raw) (bool, error)) (bool, error) {
			n := 0
			for _, el := range els {
				ok, err := f(el)
				if err != nil {
					return false, err
				}
				if ok {
					n++
				}
			}
			return n == 1, nil
		}
		hasToken := func(el raw) (bool, error) {
			l, isStr, err := stringLabel(el)
			return isStr && strings.HasSuffix(l, suffix), err
		}
		for _, f := range []func(el raw) (bool, error){
			wsIs(workspace),
			func(el raw) (bool, error) {
				return all(key(el, "workspace_id", workspace), key(el, "label", workspaceLabel))
			},
			hasToken,
			func(el raw) (bool, error) {
				return all(func() (bool, error) { return hasToken(el) }, key(el, "workspace_id", workspace))
			},
			func(el raw) (bool, error) {
				return all(key(el, "workspace_id", parentWS), func() (bool, error) { return labelIs(el, parentLabel, parentOld) })
			},
		} {
			if ok, err := once(f); err != nil {
				return err
			} else if !ok {
				return nil
			}
		}
		parents, err := indicesOf(els, parentWS)
		if err != nil {
			return err
		}
		children, err := indicesOf(els, workspace)
		if err != nil {
			return err
		}
		if len(parents) != 1 || len(children) != 1 || children[0] <= parents[0] {
			return nil
		}
		for i := parents[0] + 1; i < children[0]; i++ {
			ok, err := childOf(els[i], parentLabel, parentOld)
			if err != nil {
				return err
			}
			if !ok {
				return nil
			}
		}
		emit(raw("true"))
		return nil
	}
}

func wsIs(workspace string) func(el raw) (bool, error) {
	return func(el raw) (bool, error) { return key(el, "workspace_id", workspace)() }
}

func indicesOf(els []raw, workspace string) ([]int, error) {
	var out []int
	for i, el := range els {
		ok, err := key(el, "workspace_id", workspace)()
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, i)
		}
	}
	return out, nil
}

// childOf is is_new_child, or is_legacy_child_for the parent label or its legacy label.
func childOf(el raw, parentLabel, parentOld string) (bool, error) {
	l, isStr, err := stringLabel(el)
	if err != nil || !isStr {
		return false, err
	}
	if newChild.MatchString(l) {
		return true, nil
	}
	legacy := func(owner string) bool { return legacyChild.MatchString(l) && strings.HasPrefix(l, owner+"/") }
	return legacy(parentLabel) || parentOld != "" && legacy(parentOld), nil
}

// listIDs is `[.result.workspaces[].workspace_id]`.
func listIDs(doc raw) ([]raw, error) {
	v, err := walk(doc, []string{"result", "workspaces"})
	if err != nil {
		return nil, err
	}
	els, err := iterate(v)
	if err != nil {
		return nil, err
	}
	out := make([]raw, len(els))
	for i, el := range els {
		if out[i], err = index(el, "workspace_id"); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// listIs is the move answer: a workspace_list whose ids are the expected value, in order, with
// the named workspace the only focused one.
func listIs(doc, expected raw, focused string) (bool, error) {
	return all(
		is(doc, "workspace_list", "result", "type"),
		func() (bool, error) {
			ids, err := listIDs(doc)
			return err == nil && equal(joinList(ids), expected), err
		},
		func() (bool, error) {
			v, err := walk(doc, []string{"result", "workspaces"})
			if err != nil {
				return false, err
			}
			els, err := iterate(v)
			if err != nil {
				return false, err
			}
			fs, err := focusedOf(els)
			if err != nil {
				return false, err
			}
			ids := make([]raw, len(fs))
			for i, f := range fs {
				if ids[i], err = index(f, "workspace_id"); err != nil {
					return false, err
				}
			}
			return equal(joinList(ids), joinList([]raw{quote(focused)})), nil
		},
	)
}

func joinList(els []raw) raw {
	parts := make([]string, len(els))
	for i, e := range els {
		parts[i] = string(e)
	}
	return raw("[" + strings.Join(parts, ",") + "]")
}

func quote(s string) raw {
	b, _ := json.Marshal(s)
	return b
}

// argJSON is jq's --argjson: one valid JSON value.
func argJSON(s string) (raw, error) {
	if !json.Valid([]byte(s)) {
		return nil, errf("invalid JSON text passed to --argjson")
	}
	return raw(s), nil
}

// moveVerify is the move answer for moving <ws> to the end: the order before, without ws and
// with it last, and the focused workspace unchanged.
func moveVerify(ws, focused, beforeJSON string) program {
	return func(doc raw, emit func(raw)) error {
		before, err := argJSON(beforeJSON)
		if err != nil {
			return err
		}
		els, err := iterate(before)
		if err != nil {
			return err
		}
		var expected []raw
		for _, el := range els {
			if !isString(el, ws) {
				expected = append(expected, el)
			}
		}
		expected = append(expected, quote(ws))
		ok, err := listIs(doc, joinList(expected), focused)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// restoreVerify is the move answer for a rollback: the recorded order, the focus unchanged.
func restoreVerify(expectedJSON, focused string) program {
	return func(doc raw, emit func(raw)) error {
		expected, err := argJSON(expectedJSON)
		if err != nil {
			return err
		}
		ok, err := listIs(doc, expected, focused)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// orderVerify is the move answer for placing <created> at index <desired>, below the one
// parent workspace that stays before it.
func orderVerify(created, parent, parentWS, desiredJSON string) program {
	return func(doc raw, emit func(raw)) error {
		desired, err := argJSON(desiredJSON)
		if err != nil {
			return err
		}
		isParent := func(el raw) (bool, error) {
			if codepoints(parentWS) > 0 {
				return key(el, "workspace_id", parentWS)()
			}
			l, isStr, err := stringLabel(el)
			return isStr && l == parent, err
		}
		var parentAt int
		ok, err := all(
			is(doc, "workspace_list", "result", "type"),
			func() (bool, error) { _, ok, err := array(doc, "result", "workspaces"); return ok, err },
			func() (bool, error) {
				els, _, _ := array(doc, "result", "workspaces")
				if kind(desired) != '0' {
					return false, errf("Cannot index array with %s", kindName(desired))
				}
				f, _ := number(desired)
				if math.Abs(f) > 1e9 {
					return false, nil
				}
				i := int(f)
				if i < 0 {
					i += len(els)
				}
				if i < 0 || i >= len(els) {
					return false, nil
				}
				return key(els[i], "workspace_id", created)()
			},
			func() (bool, error) {
				els, _, _ := array(doc, "result", "workspaces")
				n := 0
				for _, el := range els {
					p, err := isParent(el)
					if err != nil {
						return false, err
					}
					if p {
						n++
					}
				}
				return n == 1, nil
			},
			func() (bool, error) {
				els, _, _ := array(doc, "result", "workspaces")
				for i, el := range els {
					p, err := isParent(el)
					if err != nil {
						return false, err
					}
					if p {
						parentAt = i
						break
					}
				}
				f, _ := number(desired)
				return float64(parentAt) < f, nil
			},
		)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// moveSchema is the api schema offering workspace.move with the parameters the mover sends.
func moveSchema() program {
	return func(doc raw, emit func(raw)) error {
		ok, err := all(
			func() (bool, error) {
				els, err := elements(doc, []string{"schemas", "request", "oneOf"})
				if err != nil {
					return false, err
				}
				for _, el := range els {
					if good, err := is(el, "workspace.move", "properties", "method", "const")(); err != nil || good {
						return good, err
					}
				}
				return false, nil
			},
			func() (bool, error) {
				v, err := walk(doc, []string{"schemas", "request", "$defs", "WorkspaceMoveParams", "required"})
				return err == nil && equal(v, raw(`["workspace_id","insert_index"]`)), err
			},
			is(doc, "integer", "schemas", "request", "$defs", "WorkspaceMoveParams", "properties", "insert_index", "type"),
		)
		if err != nil {
			return err
		}
		emit(jbool(ok))
		return nil
	}
}

// number reads a JSON number; one that overflows reads as the largest double, as jq's does.
func number(v raw) (float64, bool) {
	f, err := strconv.ParseFloat(strings.TrimSpace(string(v)), 64)
	if err != nil && !math.IsInf(f, 0) {
		return 0, false
	}
	return math.Max(-math.MaxFloat64, math.Min(math.MaxFloat64, f)), true
}

// jqNumber prints a double the way jq does: the shortest digits, in plain notation unless the
// exponent is large against the digit count.
func jqNumber(f float64) string {
	if f == 0 {
		return "0"
	}
	e := strconv.FormatFloat(math.Abs(f), 'e', -1, 64)
	mant, expo, _ := strings.Cut(e, "e")
	digits := strings.Replace(mant, ".", "", 1)
	exp, _ := strconv.Atoi(expo)
	decpt := exp + 1
	sign := ""
	if f < 0 {
		sign = "-"
	}
	switch {
	case decpt <= -4 || decpt > len(digits)+15:
		out := digits[:1]
		if len(digits) > 1 {
			out += "." + digits[1:]
		}
		s := "+"
		if exp < 0 {
			s = "-"
		}
		return sign + out + "e" + s + strconv.Itoa(int(math.Abs(float64(exp))))
	case decpt <= 0:
		return sign + "0." + strings.Repeat("0", -decpt) + digits
	case decpt >= len(digits):
		return sign + digits + strings.Repeat("0", decpt-len(digits))
	}
	return sign + digits[:decpt] + "." + digits[decpt:]
}

// wholeNumber is `select(type == "number" and . > <min>) | floor`.
func wholeNumber(v raw, min float64) (raw, bool) {
	if kind(v) != '0' {
		return nil, false
	}
	f, ok := number(v)
	if !ok || !(f > min) {
		return nil, false
	}
	return raw(jqNumber(math.Floor(f))), true
}

// processField reads one field of a `pane process-info` answer, empty when it is not what the
// proof needs: shell-pid and foreground-pgid are whole numbers above 1, count is the number of
// foreground processes, and first-pid, first-name and first-argv0 describe the first of them.
func processField(field string) program {
	info := []string{"result", "process_info"}
	return func(doc raw, emit func(raw)) error {
		switch field {
		case "shell-pid", "foreground-pgid":
			name := map[string]string{"shell-pid": "shell_pid", "foreground-pgid": "foreground_process_group_id"}[field]
			v, err := walk(doc, append(info, name))
			if err != nil {
				return err
			}
			if n, ok := wholeNumber(v, 1); ok {
				emit(n)
			}
		case "count":
			v, err := walk(doc, append(info, "foreground_processes"))
			if err != nil {
				return err
			}
			if kind(v) == '[' {
				els, _ := iterate(v)
				emit(raw(strconv.Itoa(len(els))))
			}
		default:
			first, err := firstOf(doc, "result", "process_info", "foreground_processes")
			if err != nil {
				return err
			}
			switch field {
			case "first-pid":
				v, err := index(first, "pid")
				if err != nil {
					return err
				}
				if n, ok := wholeNumber(v, math.Inf(-1)); ok {
					emit(n)
				}
			case "first-name":
				v, err := index(first, "name")
				if err != nil {
					return err
				}
				if kind(v) == '"' && text(v) != "" {
					emit(v)
				}
			case "first-argv0":
				v, err := firstArgv0(first)
				if err != nil {
					return err
				}
				if kind(v) == '"' && text(v) != "" {
					emit(v)
				}
			}
		}
		return nil
	}
}

// firstArgv0 is `($p.argv0 // $p.argv[0])`.
func firstArgv0(p raw) (raw, error) {
	v, err := index(p, "argv0")
	if err != nil {
		return nil, err
	}
	if truthy(v) {
		return v, nil
	}
	argv, err := index(p, "argv")
	if err != nil {
		return nil, err
	}
	return at(argv, 0)
}

// checks maps a program name to its constructor; the argument count is checked before it runs.
var checks = map[string]struct {
	args int
	make func(a []string) program
	// jsonArgs are the positions of arguments that must be JSON values: jq refuses the whole
	// program when one is not, whether or not it is given an answer to read.
	jsonArgs []int
}{
	"is-array":           {1, func(a []string) program { return isArrayAt(dotted(a[0])) }, nil},
	"session-socket":     {1, func(a []string) program { return sessionSocket(a[0]) }, nil},
	"focus-tab-is":       {1, func(a []string) program { return focusTabIs(a[0]) }, nil},
	"tab-binds":          {2, func(a []string) program { return tabBinds(a[0], a[1]) }, nil},
	"pane-binds":         {3, func(a []string) program { return paneBinds(a[0], a[1], a[2]) }, nil},
	"workspace-unique":   {1, func(a []string) program { return workspaceUnique(a[0]) }, nil},
	"move-schema":        {0, func([]string) program { return moveSchema() }, nil},
	"sole-tab":           {1, func(a []string) program { return sole("tabs", [2]string{"tab_id", a[0]}) }, nil},
	"sole-tab-labelled":  {2, func(a []string) program { return sole("tabs", [2]string{"tab_id", a[0]}, [2]string{"label", a[1]}) }, nil},
	"sole-pane":          {1, func(a []string) program { return sole("panes", [2]string{"pane_id", a[0]}) }, nil},
	"sole-pane-in-tab":   {2, func(a []string) program { return sole("panes", [2]string{"pane_id", a[0]}, [2]string{"tab_id", a[1]}) }, nil},
	"shape-tabs":         {2, func(a []string) program { return shapeTabs(a[0], a[1]) }, nil},
	"shape-panes":        {2, func(a []string) program { return shapePanes(a[0], a[1]) }, nil},
	"move-verify":        {3, func(a []string) program { return moveVerify(a[0], a[1], a[2]) }, []int{2}},
	"restore-verify":     {2, func(a []string) program { return restoreVerify(a[0], a[1]) }, []int{0}},
	"order-verify":       {4, func(a []string) program { return orderVerify(a[0], a[1], a[2], a[3]) }, []int{3}},
	"process-info-pane":  {1, func(a []string) program { return processInfoPane(a[0]) }, nil},
	"process-field":      {1, func(a []string) program { return processField(a[0]) }, nil},
	"parent-workspace":   {2, func(a []string) program { return parentWorkspaceExact(a[0], a[1]) }, nil},
	"live-binding":       {6, func(a []string) program { return liveBinding(a[0], a[1], a[2], a[3], a[4], a[5]) }, nil},
	"pane-info-matches":  {4, func(a []string) program { return infoMatches("pane_info", "pane", a[0], a[1], a[2], a[3]) }, nil},
	"agent-info-matches": {4, func(a []string) program { return infoMatches("agent_info", "agent", a[0], a[1], a[2], a[3]) }, nil},
}
