#!/usr/bin/env bash
# The chat gateway's text ingress (core/bus/cmd/jg-bus/gateway.go), proved by its Go test.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v go >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { printf 'skip: needs go and python3\n'; exit 0; }
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-bus-gateway.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
cd "$ROOT/core/bus" && GOCACHE=${GOCACHE:-$lab/gocache} TMPDIR=$lab go test ./cmd/jg-bus/ -run TestGatewayIngress -count=1
