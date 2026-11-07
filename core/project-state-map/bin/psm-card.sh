#!/usr/bin/env bash
# Project state map, step 4 (draw): turn a proved map into a sign-off report card, with no model call.
# Usage: psm-card.sh <proved.json> --out-dir <dir> [--filed <iso time>] [--post <board.json> [--replaces <key>]]
# Reads a psm.proved.v1 document (psm-prove.sh). Writes <dir>/report.json (report schema 5, group "State map",
# key state-map-<project>-<tree>) and the pictures it points at: <dir>/state-map/<key>/{explicit,hidden,machinery}.html,
# each phone first and light or dark, drawn only for the parts the map has. Same map and same --filed, same bytes.
# --post publishes the card with sign-off-axi (or JG_REPORT_POST) and then dismisses --replaces, the card it
# replaces, the way fleet-report keeps one live card.
set -euo pipefail

proved='' dir='' filed='' board='' replaces=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) dir=${2:?}; shift 2 ;;
    --filed) filed=${2:?}; shift 2 ;;
    --post) board=${2:?}; shift 2 ;;
    --replaces) replaces=${2:?}; shift 2 ;;
    -h|--help) sed -n 2,9p "$0" | cut -c3-; exit 0 ;;
    -*) echo "psm-card: unknown argument $1" >&2; exit 2 ;;
    *) [ -z "$proved" ] || { echo 'psm-card: one map only' >&2; exit 2; }; proved=$1; shift ;;
  esac
done
[ -n "$proved" ] && [ -n "$dir" ] || { sed -n 2,3p "$0" | cut -c3- >&2; exit 2; }
[ -f "$proved" ] || { echo "psm-card: not a file: $proved" >&2; exit 2; }
command -v jq >/dev/null || { echo 'psm-card: needs jq' >&2; exit 2; }
jq -e '.schema == "psm.proved.v1" and (.machines | type) == "array" and (.machinery | type) == "array" and (.proof | type) == "object"' "$proved" >/dev/null 2>&1 ||
  { echo "psm-card: not a psm.proved.v1 map: $proved" >&2; exit 2; }
[ -z "$replaces" ] || [ -n "$board" ] || { echo 'psm-card: --replaces needs --post' >&2; exit 2; }
[ -n "$filed" ] || filed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
key=$(jq -r '((.project | split("/") | last) // "project" | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-|-$"; "")) as $n | "state-map-\($n)-\((.tree // "x") | .[:8])"' "$proved")
pics=state-map/$key # the card's pictures, as paths from the folder the report sits in
mkdir -p "$dir/$pics"

# One picture per kind of part. The page is drawn by jq from the proved map; the css follows the sign-off sample cards.
# $which: explicit | hidden | machinery.
picture() { # picture <which> <title>
  jq -r --arg which "$1" --arg title "$2" '
    def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;");
    def w($s): (($s | length) * 7.4 + 20) | ceil;
    def pills($m): # one row-wrapped strip of state pills; an arrow joins two neighbours when a move says so
      reduce range(0; $m.states | length) as $i ({x: 8, y: 0, out: ""};
        ($m.states[$i]) as $s
        | (if $i == 0 then 0 elif any(($m.moves // [])[]; .from == $m.states[$i - 1] and .to == $s) then 22 else 8 end) as $gap
        | (if $i > 0 and (.x + $gap + w($s)) > 332 then {x: 8, y: (.y + 38), g: 0, arrow: false, out: .out}
           else {x: .x, y: .y, g: $gap, arrow: ($i > 0 and $gap == 22), out: .out} end) as $p
        | ($p.x + $p.g) as $x
        | {x: ($x + w($s)), y: $p.y,
           out: (.out
             + (if $p.arrow then "<path class=\"a\" d=\"M\($x - 20) \($p.y + 20)L\($x - 2) \($p.y + 20)\" marker-end=\"url(#ar)\"/>" else "" end)
             + "<rect class=\"b\" x=\"\($x)\" y=\"\($p.y + 4)\" width=\"\(w($s))\" height=\"32\" rx=\"7\"/><text class=\"t\" x=\"\($x + w($s) / 2)\" y=\"\($p.y + 24)\" text-anchor=\"middle\">\($s | esc)</text>")});
    def rows($m): (pills($m).y / 38 | floor) + 1;
    (if $which == "machinery" then .machinery else [.machines[] | select(.kind == $which)] end) as $items
    | (reduce $items[] as $it ({y: 8, out: ""};
        if $which == "machinery" then
          {y: (.y + 46), out: (.out + "<rect class=\"\(if $it.kind == "timer" then "x" else "b" end)\" x=\"8\" y=\"\(.y)\" width=\"324\" height=\"38\" rx=\"7\"/><text class=\"t\" x=\"20\" y=\"\(.y + 24)\">\($it.name | esc)</text><text class=\"m\" x=\"324\" y=\"\(.y + 24)\" text-anchor=\"end\">\($it.kind | esc)</text>")}
        else
          (pills($it)) as $p
          | {y: (.y + 26 + rows($it) * 38 + 12),
             out: (.out + "<text class=\"h\" x=\"8\" y=\"\(.y + 14)\">\($it.name | esc)</text><g transform=\"translate(0 \(.y + 18))\">\($p.out)</g>")}
        end)) as $r
    | "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n<title>\($title | esc)</title>\n<style>\n:root{--ink:#1c2430;--mut:#5a6577;--bg:#ffffff;--box:#eef2f7;--line:#7d8aa0}\n@media (prefers-color-scheme: dark){:root:not([data-theme=\"light\"]){--ink:#e6ebf2;--mut:#a9b3c3;--bg:#12161c;--box:#1e2631;--line:#7a889e}}\n:root[data-theme=\"dark\"]{--ink:#e6ebf2;--mut:#a9b3c3;--bg:#12161c;--box:#1e2631;--line:#7a889e}\nhtml,body{margin:0;background:var(--bg)}\nsvg{display:block;width:100%;height:auto;max-width:420px;margin:0 auto;font:13px system-ui,-apple-system,\"Segoe UI\",sans-serif;color:var(--ink)}\n.t{fill:var(--ink)} .m{fill:var(--mut)} .h{fill:var(--ink);font-weight:700}\n.b{fill:var(--box);stroke:var(--line);stroke-width:1.2}\n.x{fill:var(--box);stroke:var(--line);stroke-width:1.2;stroke-dasharray:5 4}\n.a{stroke:var(--line);stroke-width:1.5;fill:none}\n.ah{fill:var(--line)}\n</style></head><body>\n<svg viewBox=\"0 0 340 \($r.y + 8)\" role=\"img\" aria-label=\"\($title | esc)\">\n<defs><marker id=\"ar\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10z\" class=\"ah\"/></marker></defs>\n\($r.out)</svg>\n</body></html>"' "$proved" > "$dir/$pics/$1.html"
}

report_cards() { jq --arg filed "$filed" --arg key "$key" --arg pics "$pics" '
    def trunc($n): if length > $n then .[:$n] else . end;
  def ev_text: [.evidence[] | "\(.file):\(.line)"] | join(", ");
  ((.project | split("/") | last) // "project") as $name
  | ([.machines[] | select(.kind == "explicit")]) as $ex | ([.machines[] | select(.kind == "hidden")]) as $hi
  | (.machines | length) as $mn | (.machinery | length) as $pn | .proof as $pf
  | ([ (if ($ex | length) > 0 then {label: "Explicit sets", src: "\($pics)/explicit.html"} else empty end),
       (if ($hi | length) > 0 then {label: "Hidden states", src: "\($pics)/hidden.html"} else empty end),
       (if $pn > 0 then {label: "Machinery", src: "\($pics)/machinery.html"} else empty end) ]) as $pics
  | {contract: 1, kind: "report", schema: 5, filer: "project-state-map", key: $key,
     title: "\($name) has \($mn) state machines and \($pn) moving parts",
     purpose: "other", filed: $filed, actions: {role: "Project state map", recommended: "approve"}, project: $name, group: "State map",
     about: "This is the state map of \($name). It lists each state set, hidden flag and moving part the code shows, and every line points at real code. \($pf.dropped_count) claimed lines did not hold and were dropped.",
     understood: [{label: "You asked", text: "Show every state and moving part of a project on one page, so a person who does not code can see how it works."},
                  {label: "Done when", text: "Each state set, hidden flag and moving part is listed here, and each one points at a line that was checked."}],
     visual: {type: "bars", heading: "\($name) has \($ex | length) declared sets and \($hi | length) hidden states",
              text: "Counts come from the checked map. Each bar is one kind of state or moving part.", unit: "items",
              diagram: $pics,
              rows: [{label: "Explicit sets", value: ($ex | length), note: "declared", tone: "ok"},
                     {label: "Hidden states", value: ($hi | length), note: "derived", tone: "ok"},
                     {label: "Moving parts", value: $pn, note: "machinery", tone: "ok"},
                     {label: "Lines dropped", value: $pf.dropped_count, note: "not shown by the code", tone: (if $pf.dropped_count > 0 then "warn" else "ok" end)}],
              details: [{label: "Lines checked", value: ($pf.checked | tostring)}, {label: "Lines kept", value: ($pf.kept | tostring)},
                        {label: "Code tree", value: ((.tree // "unknown") | trunc(12))}]},
     sections: [
       {id: "found", stage: "found", heading: "\($name) has \($mn) state machines and \($pn) moving parts",
        body: "Each item below was checked against the code. Open an item to see where.",
        items: ([.machines[] | {title: "\(.name) has \(.states | length) states", text: (.states | join(", ")),
                                more: "\(.kind | if . == "hidden" then "A hidden state, not a declared set." else "A declared set." end) Found at \(ev_text).", tone: "ok"}][:12]
                + [.machinery[] | {title: "\(.name) (\(.kind))", text: "A moving part of the project.", more: "Found at \(ev_text).", tone: "ok"}][:12])},
       {id: "not-read", stage: "recommend", heading: "What the map did not cover",
        body: (if (.not_read | length) == 0 then "Nothing was named as unread." else "The reader named these areas as not read." end),
        items: ([.not_read[] | {title: ., text: "Not read for this map."}][:8]
                + (if $pf.dropped_count > 0 then [{title: "\($pf.dropped_count) claimed lines were dropped", text: "The code did not show them.", tone: "warn",
                     more: ([$pf.dropped[:6][] | "\(.where) \(.reason)"] | join("; "))}] else [] end))}],
     next: {heading: "The map refreshes when the code changes", lines: ["Same code, same card.", "Lines dropped: \($pf.dropped_count)."]}}' "$proved"; }

for pair in 'explicit:[.machines[] | select(.kind == "explicit")]:Explicit state sets' 'hidden:[.machines[] | select(.kind == "hidden")]:Hidden states' 'machinery:.machinery:Moving parts'; do
  w=${pair%%:*} rest=${pair#*:}; sel=${rest%:*} ttl=${rest##*:}
  if jq -e "($sel | length) > 0" "$proved" >/dev/null; then picture "$w" "$ttl"; else rm -f "$dir/$pics/$w.html"; fi
done
report_cards > "$dir/report.json"

if [ -n "$board" ]; then
  # The board reads pictures as paths from its own folder, so they go beside it.
  mkdir -p "$(dirname -- "$board")/$pics" && cp -R "$dir/$pics/." "$(dirname -- "$board")/$pics/"
  ${JG_REPORT_POST:-sign-off-axi} post "$board" --kind report --from "$dir/report.json" --filer project-state-map
  [ -z "$replaces" ] || [ "$replaces" = "$key" ] || ${JG_REPORT_POST:-sign-off-axi} dismiss "$board" "$replaces" >/dev/null 2>&1 || true
fi
