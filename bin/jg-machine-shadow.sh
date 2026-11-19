#!/usr/bin/env bash
# STUB (slice 8b1): no guard; it exits 0 for every call, never refuses and never records.
# jg-machine-shadow.sh - a writer's report of the move it is about to make to the machine table.
#
# Usage: jg-machine-shadow.sh [--refuse] <machine> <id> <to>
#
# The store's triggers are the one guard now, so this command answers at once with exit 0 and writes nothing,
# even with --refuse. Callers keep working until their scope order removes the call.
exit 0
