#!/bin/sh
# Xcode Cloud post-xcodebuild hook (runs on Apple's CI after every xcodebuild
# action of the workflow: build, test, archive).
# One job: upload the archive's dSYMs to Firebase Crashlytics. Without them
# every crash stack is unsymbolicated hex and the report is useless.
#
# - Archive actions only. Xcode Cloud sets CI_ARCHIVE_PATH just for those; any
#   other action exits immediately.
# - Uses the `upload-symbols` binary that ships inside the firebase-ios-sdk
#   Swift package (Xcode Cloud resolves it into
#   $CI_DERIVED_DATA_PATH/SourcePackages/checkouts), so it is always the
#   version matching the pinned SDK. The Firebase project comes from the
#   GoogleService-Info.plist that ci_post_clone.sh materialised.
# - A dSYM problem must NEVER block a TestFlight upload: this script has no
#   `set -e`, every failure (missing file, upload error, hang) only prints a
#   warning, and the exit status is always 0. If a build's stacks show up
#   unsymbolicated, re-upload that archive's dSYMs by hand (Xcode > Organizer >
#   the archive > Download Debug Symbols, then `upload-symbols`).
# - Release must keep DEBUG_INFORMATION_FORMAT = dwarf-with-dsym (the Xcode
#   default) or the archive has no dSYMs to upload.
#
# Env overrides (testing only): UPLOAD_SYMBOLS_TIMEOUT_SECONDS (default 300).
set -u

TIMEOUT="${UPLOAD_SYMBOLS_TIMEOUT_SECONDS:-300}"

# Prints a non-fatal diagnostic; the build carries on.
warn() {
  echo "warning: ci_post_xcodebuild: $*" >&2
}

if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
  echo "ci_post_xcodebuild: not an archive action (CI_XCODEBUILD_ACTION=${CI_XCODEBUILD_ACTION:-unset}); no dSYMs to upload."
  exit 0
fi

DSYMS="$CI_ARCHIVE_PATH/dSYMs"
PLIST="${CI_PRIMARY_REPOSITORY_PATH:-}/apps/ios/OYBC/GoogleService-Info.plist"
UPLOADER="${CI_DERIVED_DATA_PATH:-}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols"

if [ ! -d "$DSYMS" ]; then
  warn "no dSYMs directory at $DSYMS; skipping Crashlytics upload."
  exit 0
fi
if [ ! -f "$PLIST" ]; then
  warn "no GoogleService-Info.plist at $PLIST; skipping Crashlytics upload."
  exit 0
fi

# Fall back to a bounded search if the package checkout is not where Xcode
# usually puts it.
if [ ! -x "$UPLOADER" ] && [ -n "${CI_DERIVED_DATA_PATH:-}" ]; then
  UPLOADER="$(find "$CI_DERIVED_DATA_PATH" -maxdepth 6 -type f -path '*/firebase-ios-sdk/Crashlytics/upload-symbols' -print -quit 2>/dev/null)"
fi
if [ -z "$UPLOADER" ] || [ ! -x "$UPLOADER" ]; then
  warn "Crashlytics upload-symbols not found under CI_DERIVED_DATA_PATH; skipping dSYM upload."
  exit 0
fi

echo "ci_post_xcodebuild: uploading dSYMs from $DSYMS to Crashlytics."
"$UPLOADER" -gsp "$PLIST" -p ios "$DSYMS" &
UPLOAD_PID=$!

# Watchdog without a background sleeper (an orphaned sleep would hold the
# step's output pipe open): poll once a second, kill the upload on timeout.
ELAPSED=0
while kill -0 "$UPLOAD_PID" 2>/dev/null; do
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    warn "dSYM upload still running after ${TIMEOUT}s; giving up."
    kill "$UPLOAD_PID" 2>/dev/null
    sleep 2
    kill -9 "$UPLOAD_PID" 2>/dev/null
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if wait "$UPLOAD_PID" 2>/dev/null; then
  echo "ci_post_xcodebuild: dSYM upload finished."
else
  warn "dSYM upload did not complete cleanly; the build continues."
fi
exit 0
