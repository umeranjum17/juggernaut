#!/usr/bin/env bash
# Fixture spending journey: it calls no tool and only writes the marker the journey looks for.
echo spent > "${TOOL_KIT_SPEND_MARKER:?marker file}"
