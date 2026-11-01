#!/usr/bin/env bash
# Deliberate proof artifact for the done-requires-green-checks task: this file
# exists only to make one pull-request check report red so the done gate can be
# seen refusing it, and the task branch removes it again before it lands.
set -u
target=$1
cd $target
printf '%s\n' "$PWD"
