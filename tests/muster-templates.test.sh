#!/usr/bin/env bash
# muster-templates.test.sh - the muster skill ships its frozen formats, one
# template per output and one runnable example project before and after a
# feature, byte for byte, with its upstream notices.
#
# Checks, on the tracked skill folder only (no live home is read):
#   1. formats.md, every template and every example file equals the frozen
#      copy it was taken from (pinned by sha256 in the PINS table below), and
#      no extra file sits in templates/ or examples/.
#   2. Each template holds placeholders only: it has a <placeholder> and none
#      of the example project's own words.
#   3. The domain-model template names Lifecycle, `proved by` and the start
#      edge; both decision templates have status, context, two or more
#      considered options, decision, consequences and a Confirmation, and the
#      skill marks the Confirmation as a Juggernaut choice.
#   4. `node journeys/run.ts <id>` passes every journey of examples/helpdesk and
#      examples/rated (node 23.6 or later; exit 77 when node is missing or too
#      old, a setup error).
#   5. UPSTREAM names both pinned sources and UPSTREAM-LICENSE holds both notices.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/muster"
[ -d "$SKILL" ] || fail "the muster skill folder is missing: $SKILL"
for f in SKILL.md questions.md formats.md UPSTREAM UPSTREAM-LICENSE; do
  [ -f "$SKILL/$f" ] || fail "the muster skill has no $f"
done

# PINS: the frozen copies, as `sha256  path` relative to the example pack.
# formats.md and templates/ live in the skill at the same path; helpdesk/,
# skeleton/ and rated/ live under examples/.
pins() {
  cat <<'PINS'
f4d3f71b7cddb3b9838308324b66cfea6bcef786d303efc48b65fd118c73a03a  formats.md
8ae7954f2af2b378f82852a9ef2523d9b5d7042f27acb47952c8129d0cdcde2a  helpdesk/.done-done.yaml
2d78a4233a3f5093978cc830cb6740fcbb398ee4513e5767394210cf9bf30123  helpdesk/CHANGELOG.md
af1698338b5b995f9299552737b9ce8b7c117d89289488ee973f22153f2024e0  helpdesk/GLOSSARY.md
816cd0aafc8ba4f295f2288714cab7ccf752a963288b1625faf94d0c295f29ab  helpdesk/docs/adr/0001-use-typescript-on-node.md
ebfcf547d7857097424d206bffdedfe84d9b24e7a83ff32586dca3c37e919a1b  helpdesk/docs/adr/0002-keep-conversations-in-one-store-file.md
c101cd86bafeea6e848f2dfb873be12b888d814bb1514cb17a89f96287f45626  helpdesk/docs/adr/0003-host-on-one-small-server.md
4e487d69d8ab1ff9b4046f3d9f87e9493215b0992f4fadcf22c9ed4e500c15e5  helpdesk/docs/adr/README.md
34588e3adb5ee883a39259d9fda202e049cb82dbb6cf63d1d1cf5ab68420ec82  helpdesk/docs/charter.md
ad8bb979a6becdee329623cd6575deb612894263bbc605ed871d084e59c4f6f6  helpdesk/docs/architecture/helpdesk.md
fbbaf3fb5d5d2c6e2700223d378c9e3c96c91ed6905176ad7292870dd0b8eb48  helpdesk/docs/design/visual-direction.md
78d78475bce0ac561e146b098f26a677f62e0ca4128490e0908583c6cda6064f  helpdesk/docs/domain/model.md
6596cdbca2dd4f7e25d90639eed51b75c700c3d0d0e6786384c109890fdd5913  helpdesk/docs/specs/helpdesk.md
1814c0bbbe2e5c7e5dba9c8154004e34cd54657660f010ed05466eed4581d755  helpdesk/docs/use-cases.md
cb95e504885cfd49c7efa1667845c31cb0c2a04b3a1ba727d9a03e992307c31b  helpdesk/docs/vision.md
1b526e2c034ada86626a8b92ca82fe38e141b99ccdd568fce1199d44ca79583c  helpdesk/docs/ways-of-working.md
3699063bf991bdc11b96533737ac97051d0ac1176ae619cd990fb803bbe235cb  helpdesk/journeys/run.ts
f4ee5e57f8c4776bcf81db1317c877b03d358c7b92ba60072948ca41eafd0bb3  helpdesk/package.json
fd2044be9d054e2ab1b673572e511d22c494b5f8dd701e97e765bfa4b6f8a483  helpdesk/src/cli.ts
015f7835350c1fdb201ae24a7425db385f539d54d15bf8130f731a88594f21e5  helpdesk/src/domain/conversation.ts
6f58cdf66b52a740a8f2bd5c8a9c76e269a2b1c3b19c921bd65da7836581e842  helpdesk/src/domain/errors.ts
be28fab8642cabc94dc63fdce3f8867a8825d9422d2d5d0493a9225aaf31f2e0  helpdesk/src/domain/handoff.ts
022b430288a60bd90d1496f286ee796579c1dab940a51027b3140753d4e33722  rated/.done-done.yaml
28fe25ec7f7a5cbc89e165ae98e428f255261974898ca9942b0f7eb25f283605  rated/CHANGELOG.md
665ef9e5f3953de47058976e27824ad34a7aa953ac281e5987ea6fc4f81c03cd  rated/GLOSSARY.md
816cd0aafc8ba4f295f2288714cab7ccf752a963288b1625faf94d0c295f29ab  rated/docs/adr/0001-use-typescript-on-node.md
ebfcf547d7857097424d206bffdedfe84d9b24e7a83ff32586dca3c37e919a1b  rated/docs/adr/0002-keep-conversations-in-one-store-file.md
c101cd86bafeea6e848f2dfb873be12b888d814bb1514cb17a89f96287f45626  rated/docs/adr/0003-host-on-one-small-server.md
2bca329a16baed613ef84bec0776a97a19d4849a7d5cc3295c672af1e13b9321  rated/docs/adr/0004-store-the-rating-on-the-conversation.md
f86ffd373b4de09df193a15ee89afc1b4a3b6f74e29134a0a3d7fddb354e15ff  rated/docs/adr/README.md
997b4708676740d4418d46a4f0c23fbb71d26dfd7d3d7249431ef95581aa878d  rated/docs/changes/rate-a-conversation.md
34588e3adb5ee883a39259d9fda202e049cb82dbb6cf63d1d1cf5ab68420ec82  rated/docs/charter.md
ad8bb979a6becdee329623cd6575deb612894263bbc605ed871d084e59c4f6f6  rated/docs/architecture/helpdesk.md
9109ef2574bee5d64f852ecefc3a5a23429edd38f44c8cd6fb549f4f8bbafee8  rated/docs/architecture/rate-a-conversation.md
fbbaf3fb5d5d2c6e2700223d378c9e3c96c91ed6905176ad7292870dd0b8eb48  rated/docs/design/visual-direction.md
5cbc6bba3d96820ed77ec0e1b3043dbbc6d11551b67e16bd96a9731a03c3ebae  rated/docs/domain/model.md
6596cdbca2dd4f7e25d90639eed51b75c700c3d0d0e6786384c109890fdd5913  rated/docs/specs/helpdesk.md
dad7cd07a5fb787ac3b138e7fe60ee81da54abd87339bd85b10750a98654298f  rated/docs/specs/rate-a-conversation.md
fd1f5ff13ee32567c0ceb09f51cd24ba3a098340d9238cdc760b928ccc26ce9c  rated/docs/use-cases.md
cb646965c0c532fe7b88272d2f1d68bdcc0c8253192a3bb39f773dd1c1dc5289  rated/docs/vision.md
1b526e2c034ada86626a8b92ca82fe38e141b99ccdd568fce1199d44ca79583c  rated/docs/ways-of-working.md
9e47750459d64a68bdf3fb027c751af3fe183a2e238b6338c538f14317821ba5  rated/journeys/run.ts
f4ee5e57f8c4776bcf81db1317c877b03d358c7b92ba60072948ca41eafd0bb3  rated/package.json
0e3b34b33a339d356ca1f973be958fbbbcafdec84da9c698910ee317eba0c6b5  rated/src/cli.ts
2002ed2a5bb8cba06a5a02036c7cd506d2ef0adf31591570eab49815960f4ad7  rated/src/domain/conversation.ts
6f58cdf66b52a740a8f2bd5c8a9c76e269a2b1c3b19c921bd65da7836581e842  rated/src/domain/errors.ts
be28fab8642cabc94dc63fdce3f8867a8825d9422d2d5d0493a9225aaf31f2e0  rated/src/domain/handoff.ts
f4ee5e57f8c4776bcf81db1317c877b03d358c7b92ba60072948ca41eafd0bb3  skeleton/package.json
bf7928a0d822c27c803112d77c8f3ea1d76df1e3f9fe71dd262e29f733eb85bd  skeleton/src/cli.ts
8527ae338269cd1f428dc9fe1bc147a6375b9e90c9085741a2cf86e99986f2d7  templates/CHANGELOG.md
f40963d339612e5a89ecddc0a39616266c7fa5807418fa2361ffb88369358685  templates/GLOSSARY.md
bd81f47bf040ce041e54bac4a09e6cf4b67e9fc1c91709cc4b8cec82c1ad6443  templates/adr-README.md
5a9e1dbdfb7bbad4fc87a6a92f8217a00cf85d96ac4afe2e448c444b93391582  templates/adr-short.md
e306917b331c8c8fa5342ae670d8176dda156d36342f5fe8a0757dd5fcd85792  templates/adr.md
a5d2fd3072d867dd065a6bffa13c8cba7943b1f0bdfb113cc4f257c21311e0d8  templates/change.md
901f390e624740b9bb9b682e9c6b3260dbd75665177fad37b678ab512eb64bb3  templates/charter.md
6b8df187fc401db22e697708bb476df37f8b7c6a17860aebc3cdb3941e7d2bdc  templates/technical-design.md
d656e2eec6bc0f966588a883aead8a558bc48c758c6668a1d3f146297aa78631  templates/domain-model.md
d647441d67160358760a22ab26d144d39fa2c49fb70df1c80cd84c15910edafc  templates/done-done.yaml
68f9292ccbb65fc015d76f395f77df7151a3c24e419176651d20ca4ba41fa6e7  templates/spec.md
f457721ca028419b60f758837dfa704006b292d2a5501ad30d84c641bc9cce20  templates/use-cases.md
8f7bb6b9a00e9fada578ef838de70d3cf3c81b723540c781414d4493a16acb70  templates/vision.md
d49832aaf71087ec07f6316dc2a5e43740157e4509e26d3c0b5cd9fcffd0e94c  templates/visual-direction.md
779bfe60ea9f960d33ae894c934f0551571645e48bd1fbb6919ea6f2975132cc  templates/ways-of-working.md
PINS
}

skill_path() {  # <pack path> -> the path inside the skill
  case $1 in
    formats.md | templates/*) printf '%s/%s\n' "$SKILL" "$1" ;;
    *) printf '%s/examples/%s\n' "$SKILL" "$1" ;;
  esac
}

pinned=0
while read -r sum path; do
  file=$(skill_path "$path")
  [ -f "$file" ] || fail "missing: $path (expected at ${file#"$ROOT"/})"
  got=$(sha256sum "$file" | cut -d' ' -f1)
  [ "$got" = "$sum" ] || fail "$path differs from its frozen copy (sha256 ${got:0:12}, want ${sum:0:12})"
  pinned=$((pinned + 1))
done < <(pins)
pass "formats.md, the templates and the three example trees equal their frozen copies ($pinned files)"

# No file may sit beside the pinned ones: an extra file is drift.
extra=$(
  cd "$SKILL" || exit 1
  { find formats.md templates examples -type f | LC_ALL=C sort; } | while read -r f; do
    p=${f#examples/}
    pins | awk -v p="$p" '$2 == p { found = 1 } END { exit !found }' || echo "$f"
  done
)
[ -z "$extra" ] || fail "files not in the frozen pack: $extra"
pass "templates/ and examples/ hold no file beyond the frozen pack"

# 2. Templates: placeholders only.
for t in "$SKILL"/templates/*; do
  name=${t#"$SKILL"/}
  grep -q '<[^>]*>' "$t" || fail "$name has no <placeholder>"
  if hit=$(grep -n -i -E 'help ?desk|handoff|conversation|umer' "$t"); then
    fail "$name holds the example project's words, not placeholders only: $hit"
  fi
  pass "$name: placeholders only"
done

# 3. The domain-model template and the decision templates.
dm="$SKILL/templates/domain-model.md"
grep -q 'Lifecycle' "$dm" || fail "the domain-model template does not name Lifecycle"
grep -q 'proved by' "$dm" || fail "the domain-model template does not name 'proved by'"
grep -q -F '[*] --> ' "$dm" || fail "the domain-model template does not name the start edge"
pass "domain-model template names Lifecycle, 'proved by' and the start edge"

for t in adr adr-short; do
  f="$SKILL/templates/$t.md"
  grep -q '^status:' "$f" || fail "$t.md has no status"
  for h in 'Context and problem' 'Considered options' 'Decision' 'Consequences' 'Confirmation'; do
    grep -q "^## $h" "$f" || fail "$t.md has no '$h' section"
  done
  opts=$(awk '/^## Considered options/{ on = 1; next } /^## /{ on = 0 } on && /^- /{ n++ } END { print n + 0 }' "$f")
  [ "$opts" -ge 2 ] || fail "$t.md lists $opts considered options, need two or more"
  pass "$t.md: status, context, $opts considered options, decision, consequences, Confirmation"
done
grep -q 'required Confirmation (a Juggernaut choice)' "$SKILL/templates/adr-README.md" \
  || fail "templates/adr-README.md does not mark the Confirmation as a Juggernaut choice"
grep -q 'Juggernaut choice' "$SKILL/UPSTREAM" || fail "UPSTREAM does not mark the Confirmation as a Juggernaut choice"
pass "the Confirmation is required and marked as a Juggernaut choice"

# 5. Upstream sources and notices.
grep -q 'mattpocock/skills/tree/abeeaf95660ba9e8b7c753eb38f441ca707a8823' "$SKILL/UPSTREAM" || fail "UPSTREAM does not name the pinned Pocock source"
grep -q 'adr/madr/tree/ba75bb1b20d42af5746b246ad348c202419ae681' "$SKILL/UPSTREAM" || fail "UPSTREAM does not name the pinned MADR source"
pass "UPSTREAM names both pinned sources"
grep -q 'Copyright (c) 2026 Matt Pocock' "$SKILL/UPSTREAM-LICENSE" || fail "UPSTREAM-LICENSE has no Pocock notice"
grep -q 'Copyright (c) 2017-2022 Oliver Kopp, Olaf Zimmermann' "$SKILL/UPSTREAM-LICENSE" || fail "UPSTREAM-LICENSE has no MADR notice"
pass "UPSTREAM-LICENSE holds the Pocock and MADR notices"

# 4. The example journeys, run for real. Exit 77 is a setup error, never a pass.
if ! command -v node > /dev/null 2>&1; then
  echo "setup error: node is missing; the example journeys need node 23.6 or later" >&2
  exit 77
fi
if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 23 || (a === 23 && b >= 6) ? 0 : 1)'; then
  echo "setup error: node $(node --version) is too old; the example journeys need node 23.6 or later" >&2
  exit 77
fi
tmp=$(jg_test_tmproot muster-templates)
for example in helpdesk rated; do
  dir="$SKILL/examples/$example"
  ids=$(sed -n 's/^  \([a-z0-9-]*\): {tier: local, command: node journeys\/run.ts .*/\1/p' "$dir/.done-done.yaml")
  [ -n "$ids" ] || fail "$example/.done-done.yaml names no journey"
  for id in $ids; do
    if out=$(cd "$dir" && TMPDIR="$tmp" node journeys/run.ts "$id" 2>&1); then
      pass "$example journey $id: $out"
    else
      rc=$?
      [ "$rc" -eq 77 ] && { echo "setup error in $example journey $id: $out" >&2; exit 77; }
      fail "$example journey $id exited $rc: $out"
    fi
  done
done
