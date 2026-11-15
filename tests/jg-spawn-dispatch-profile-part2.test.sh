#!/usr/bin/env bash
# Part 2 of the spawn dispatch-profile cases; tests/jg-spawn-dispatch-profile.test.sh owns the list and the split.
JG_DISPATCH_PROFILE_PART=2 exec bash "$(dirname "${BASH_SOURCE[0]}")/jg-spawn-dispatch-profile.test.sh"
