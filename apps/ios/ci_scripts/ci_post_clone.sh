#!/bin/sh
# Xcode Cloud post-clone hook (runs on Apple's CI before xcodebuild).
# Two jobs:
#
# 1. Materialize the gitignored GoogleService-Info.plist from the
#    GOOGLE_SERVICE_INFO_PLIST_B64 environment variable (set once in the
#    Xcode Cloud workflow's Environment settings as a SECRET:
#      base64 -i apps/ios/OYBC/GoogleService-Info.plist | pbcopy
#    locally, then paste). The pbxproj REQUIRES this file as a bundle
#    resource (deliberately non-optional — see
#    reference_xcodegen_optional_resource_trap), so a missing var must
#    fail loudly here rather than cryptically in the build.
#
# 2. Stamp the build number: every TestFlight upload needs a unique
#    CURRENT_PROJECT_VERSION, and Xcode Cloud provides a monotonically
#    increasing CI_BUILD_NUMBER — so releases never need a manual bump
#    committed to the repo. (MARKETING_VERSION stays repo-managed in
#    project.yml; bump that deliberately per release.)
set -eu

REPO="${CI_PRIMARY_REPOSITORY_PATH:?not running under Xcode Cloud}"
PLIST="$REPO/apps/ios/OYBC/GoogleService-Info.plist"
PBXPROJ="$REPO/apps/ios/OYBC.xcodeproj/project.pbxproj"

if [ -z "${GOOGLE_SERVICE_INFO_PLIST_B64:-}" ]; then
  echo "error: GOOGLE_SERVICE_INFO_PLIST_B64 is not set in the Xcode Cloud workflow environment." >&2
  exit 1
fi
printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_B64" | base64 --decode > "$PLIST"
plutil -lint "$PLIST"
echo "GoogleService-Info.plist materialized."

sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*;/CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};/g" "$PBXPROJ"
echo "CURRENT_PROJECT_VERSION stamped to ${CI_BUILD_NUMBER}."

# Optional: explicit team for signing when cloud signing needs a nudge.
if [ -n "${DEVELOPMENT_TEAM_ID:-}" ]; then
  printf 'DEVELOPMENT_TEAM = %s\n' "$DEVELOPMENT_TEAM_ID" > "$REPO/apps/ios/Signing.local.xcconfig"
  echo "Signing.local.xcconfig written."
fi
