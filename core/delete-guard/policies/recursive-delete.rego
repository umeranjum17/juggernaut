# Shadow policy for the delete guard's clearest rule: a recursive delete aimed at the home folder, a folder
# directly in it, `/`, `/home`, or a bare `.` `..` `*` `$VAR` target is refused. Nothing is enforced from this
# file: guard.mjs stays the decider, and opa-shadow.mjs asks this policy the same question per recorded
# decision. Not ported, so the replay measures the gap: a `sh -c` body is not re-entered (Rego forbids
# recursion), and "the last assignment" means the last in the command, not the last one before it.
package juggernaut.guards.delete

import rego.v1

default decision := "allow"

decision := "block" if {
	some cmd in simple_commands
	some operand in operands(cmd)
	dangerous(operand)
}

# A token is a quoted span, a word, or a separator run. Quoting is kept so `rm -rf "$HOME"` still yields one
# operand, and only a separator outside quotes splits the command into simple commands.
tokens := regex.find_n(`"[^"]*"|'[^']*'|[^\s;&|"']+|[;&|\n]+`, input.command, -1)

bounds := array.concat([-1], array.concat([i | some i, t in tokens; regex.match(`^[;&|\n]+$`, t)], [count(tokens)]))

simple_commands contains words if {
	some i in numbers.range(1, count(bounds) - 1)
	words := array.slice(tokens, bounds[i - 1] + 1, bounds[i])
	count(words) > 0
}

unquote(word) := substring(word, 1, count(word) - 2) if regex.match(`^(".*"|'.*')$`, word)

unquote(word) := word if not regex.match(`^(".*"|'.*')$`, word)

flag(t) if regex.match(`^[-(!]`, t)

# rm is recursive with any -r flag, rimraf always, and find only with -delete, whose start paths end at the first
# flag. The operand list is everything a recursive delete could act on, exactly as the guard reads it.
operands(words) := [unquote(t) | some t in array.slice(words, i + 1, count(words)); not flag(unquote(t))] if {
	i := min({j | some j, t in words; regex.match(`(^|/|\\)(rm|rimraf)$`, unquote(t))})
	rm_recursive(words, i)
} else := array.slice(args, 0, min({k | some k, t in args; flag(t)})) if {
	some t in words
	unquote(t) == "find"
	some u in words
	unquote(u) == "-delete"
	i := min({j | some j, t in words; unquote(t) == "find"})
	args := [unquote(w) | some w in array.slice(words, i + 1, count(words))]
} else := []

rm_recursive(words, i) if regex.match(`(^|/)rimraf$`, unquote(words[i]))

rm_recursive(words, i) if {
	some t in array.slice(words, i + 1, count(words))
	regex.match(`(--recursive|-[a-zA-Z]*[rR])`, unquote(t))
}

# A whole operand that is one variable, optionally with a trailing /, /*, /. or /..
var_name(operand) := trim(m[0][1], "{}") if {
	regex.match(`^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(/*|/\.?\*|/\.\.|/\.)?$`, operand)
	m := regex.find_all_string_submatch_n(`\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)`, operand, 1)
}

# A shell or runtime variable is never exempt: the guard blocks it even when the command sets it.
shell_var(name) if regex.match(`^(HOME|PWD|OLDPWD|TMPDIR|TMP|TEMP|USER|LOGNAME|SHELL|PATH|IFS|[A-Z]*(XDG|FM|JG|CLAUDE|CODEX|HERDR|PI|OPENCODE|NO_MISTAKES)_[A-Z_]*)$`, name)

# The last value the command assigns to the variable. The guard judges that value, so a value it cannot read
# - a command substitution, a nested variable, a glob - stays unknown, and an unknown target is refused.
assignment(name) := unquote(v) if {
	re := sprintf(`(?:^|[;\n])\s*(?:export |local |readonly |typeset |declare(?: -[rxg]+)* )?%s\+?=("[^"]*"|'[^']*'|\$\([^()]*\)|[^\s;&|)]*)`, [name])
	m := regex.find_all_string_submatch_n(re, input.command, -1)
	some i, a in m
	i == count(m) - 1
	v := a[1]
}

# d=$(mktemp ...) is the one value the guard proves is a fresh temporary folder.
fresh(value) if regex.match(`^\$\(\s*mktemp\b[^$&|;()\x60]*\)$`, value)

literal(value) if {
	regex.match(`^[~/\w.@%+=:,-]+$`, value)
	not regex.match(`(^|/)\.\.(/|$)`, value)
}

dangerous(operand) if {
	name := var_name(operand)
	shell_var(name)
}

# An unassigned or unreadable value is refused rather than guessed, exactly as the guard refuses it.
dangerous(operand) if {
	name := var_name(operand)
	not shell_var(name)
	not assignment(name)
}

dangerous(operand) if {
	name := var_name(operand)
	not shell_var(name)
	value := assignment(name)
	not fresh(value)
	not literal(value)
}

dangerous(operand) if {
	name := var_name(operand)
	not shell_var(name)
	value := assignment(name)
	literal(value)
	literal_dangerous(value)
}

dangerous(operand) if {
	not var_name(operand)
	literal_dangerous(operand)
}

literal_dangerous(operand) if operand in {".", "..", "*", ".*", "./*", "/", "/home"}

literal_dangerous(operand) if regex.match(`^(\.\.?/)*\.\.$`, operand)

literal_dangerous(operand) if regex.match(`^/home/[^/]+$`, operand)

literal_dangerous(operand) if {
	some home in data.homes
	path := expand(operand, home)
	path == home
}

literal_dangerous(operand) if {
	some home in data.homes
	path := expand(operand, home)
	startswith(path, sprintf("%s/", [home]))
	not contains(substring(path, count(home) + 1, count(path)), "/")
}

# ~, $HOME and ${HOME} name the home folder; a trailing /*, /.* or / is dropped before judging.
expand(operand, home) := regex.replace(p, `/\.?\*$|/$`, "") if {
	p := regex.replace(operand, `^(~|\$HOME|\$\{HOME\})(/|$)`, sprintf("%s$2", [home]))
}
