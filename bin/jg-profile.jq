# jg-profile.jq - the ONE definition of a dispatch profile and its validation:
# which harness is verified, which effort a harness and model accept, and what a
# well-formed profile, floor, and provider look like. Included by
# bin/jg-dispatch-resolve.sh (config/crew-dispatch.json) and bin/jg-tool-models.sh
# (config/tool-models.json), so the two files can never disagree on a profile.
# The including call passes --argjson verified_harnesses (the jg_control_harnesses
# list) and --arg provider_re ($JG_QUOTA_PROVIDER_ID_RE).
def verified($h): $verified_harnesses | index($h);
def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
def effort_ok($h; $m; $e):
  if $e == null then true
  elif ($e | type) != "string" then false
  elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
  elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
  elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
  elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
  elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
  elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
  elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
  else true end;
def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
def floor_bad($f; $need_provider):
  ($f | type) != "object"
  or (($f.scope | type) != "string") or (($f.scope | length) == 0)
  or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
  or (if $need_provider
      then (provider_id($f.provider) | not)
      else ($f | has("provider"))
      end);
def profile_bad($p):
  ($p | type) != "object"
  or (($p.harness | type) != "string") or (($p.harness | length) == 0)
  or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
  or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
  or ($p | has("provider") and (provider_id(.provider) | not))
  or ($p | has("floor") and floor_bad(.floor; false));
def duplicate_profiles($items):
  ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
  | ($keys | length) != ($keys | unique | length);
