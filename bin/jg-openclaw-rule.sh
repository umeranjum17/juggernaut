#!/usr/bin/env bash
# jg-openclaw-rule.sh - refuse NEW OpenClaw work (owner rule owner-rule-286ed286).
#
# Usage: jg-openclaw-rule.sh check <title> [<body>]
#
# The owner decided that no product is going to use OpenClaw, so a new task
# item or a pull request that adds OpenClaw work is refused. Two paths call
# this one check: `add` in bin/jg-tasks-axi.sh (the item's title and body) and
# the GitHub merge in bin/jg-pr-merge.sh (the pull request's title and body).
#
# How the check tells new work from removal. The rule is simple and reads the
# TITLE only:
#   - OpenClaw work is any title or body that names OpenClaw (case-blind;
#     "open-claw" and "open claw" count).
#   - It still passes when the TITLE says the work takes OpenClaw out or moves
#     the product to Pi: remove, drop, delete, retire, decommission, sunset,
#     uninstall, rip out, "migrate/move/switch/port ... to Pi", or
#     "replace ... with Pi"; refuse and forbid pass too, so the change that
#     enforces this rule is not refused by itself. The body never grants the pass, so a body that
#     says "instead of removing it" cannot turn new OpenClaw work into removal.
# Everything else that names OpenClaw is refused with one line on stderr and
# exit 1. Text that never names OpenClaw exits 0.
#
# Test: tests/openclaw-refuse.test.sh.
set -u

RULE='owner-rule-286ed286'

# True when the text names OpenClaw.
names_openclaw() {
  printf '%s' "$1" | grep -Eiq 'open[-_ ]?claw'
}

# True when the title says the work removes OpenClaw or moves the product to Pi.
title_removes_openclaw() {
  printf '%s' "$1" | grep -Eiq \
    '(^|[^[:alnum:]])(remov(e|es|ing|al)|drop(s|ping)?|delet(e|es|ing)|retir(e|es|ing)|decommission(s|ing)?|sunset(s|ting)?|uninstall(s|ing)?|rip(ping)? out|refus(e|es|ing)|forbid(s|ding)?)([^[:alnum:]]|$)|(migrat|mov|switch|port|replac)[a-z]*[^.]*([^[:alnum:]]|^)(to|onto|with|for) pi([^[:alnum:]]|$)'
}

case "${1-}" in
  check)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "usage: jg-openclaw-rule.sh check <title> [<body>]" >&2; exit 2; }
    title=$2 body=${3-}
    names_openclaw "$title"$'\n'"$body" || exit 0
    ! title_removes_openclaw "$title" || exit 0
    echo "refused by owner rule $RULE: no new OpenClaw work. No product will use OpenClaw. Work that removes OpenClaw or moves a product to Pi is allowed: say so in the title." >&2
    exit 1
    ;;
  *)
    echo "usage: jg-openclaw-rule.sh check <title> [<body>]" >&2
    exit 2
    ;;
esac
