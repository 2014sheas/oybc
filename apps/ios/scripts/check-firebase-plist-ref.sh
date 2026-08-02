#!/usr/bin/env bash
# check-firebase-plist-ref.sh — Prevents the recurring launch crash caused by a
# committed project.pbxproj that has lost its GoogleService-Info.plist reference.
#
# The trap (verified empirically): `xcodegen generate` does NOT fail when the
# gitignored GoogleService-Info.plist is missing, despite project.yml's
# resources entry being non-optional — it exits 0 and SILENTLY drops the
# reference from project.pbxproj. So anyone who runs `xcodegen generate`
# without the plist present (a fresh agent worktree that never fetched the
# gitignored file, a dev who moved it, CI) produces a 0-ref pbxproj. If that
# pbxproj is then committed, every subsequent `pull + build` compiles fine but
# CRASHES at launch:
#   "[FirebaseCore] Could not locate configuration file: 'GoogleService-Info.plist'"
#   *** Terminating app due to uncaught exception 'com.firebase.core'
#
# This guard inspects the on-disk (as-committed) pbxproj, so in CI it MUST run
# BEFORE the `xcodegen generate` step (which regenerates a 0-ref pbxproj on the
# runner, where no plist exists). Run it locally before committing a pbxproj
# change: `bash scripts/check-firebase-plist-ref.sh` from apps/ios.
#
# Exit codes: 0 clean, 1 the pbxproj is missing the plist reference.

set -euo pipefail

cd "$(dirname "$0")/.."  # apps/ios

PBXPROJ="OYBC.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
  echo "::error::$PBXPROJ not found — run this from apps/ios (or run 'xcodegen generate' first)."
  exit 1
fi

count=$(grep -c "GoogleService-Info.plist" "$PBXPROJ" || true)

if [ "$count" -eq 0 ]; then
  echo "::error::project.pbxproj has no GoogleService-Info.plist reference."
  cat >&2 <<'EOF'
This almost always means `xcodegen generate` ran without the (gitignored)
GoogleService-Info.plist present, which silently drops the reference. The app
would build but crash at launch.

Fix: put GoogleService-Info.plist at apps/ios/OYBC/GoogleService-Info.plist
(download from Firebase Console → Project Settings → iOS app, or copy from
another OYBC checkout), re-run `xcodegen generate`, and commit the pbxproj.
EOF
  exit 1
fi

echo "pbxproj references GoogleService-Info.plist ($count refs) — ok."
