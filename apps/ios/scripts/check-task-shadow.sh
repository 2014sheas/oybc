#!/usr/bin/env bash
# check-task-shadow.sh — Prevents regressions of the _Concurrency.Task shadow bug.
#
# The OYBC data model defines a `Task` type that shadows Swift Concurrency's
# `Task`. A plain `Task { ... }` launching a trailing closure silently
# resolves to `OYBC.Task.init(from: Decoder)`, producing a baffling
# "trailing closure passed to parameter of type 'any Decoder'" error far
# from the actual bug. Use `_Concurrency.Task { ... }` instead.
#
# This check bit PR #32; keep the guard here so future regressions fail
# fast (in CI and optionally in a pre-commit hook) rather than producing
# cryptic errors deep in a rebuild.
#
# Exit codes: 0 clean, 1 violation(s) found.

set -euo pipefail

cd "$(dirname "$0")/.."  # apps/ios

if hits=$(grep -rEn '^\s*Task\s*\{' OYBC 2>/dev/null); then
  if [ -n "$hits" ]; then
    echo "Found 'Task {' at line start — use '_Concurrency.Task { ... }' to disambiguate from the OYBC Task model:"
    echo "$hits"
    exit 1
  fi
fi

echo "No Task-shadow violations found."
