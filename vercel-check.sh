#!/usr/bin/env bash
set -euo pipefail

# Vercel checks run in separate checkouts before the archive is extracted by build.
# Dart's analyzer checks both types and the project's configured lint rules.
SAKAN_CHECK_ROOT="$(cd "$(dirname "$0")" && pwd)"
SAKAN_CHECK_TMP="$(mktemp -d)"
trap 'rm -rf "$SAKAN_CHECK_TMP"' EXIT
tar -xzf "$SAKAN_CHECK_ROOT/sakan-source.tar.gz" -C "$SAKAN_CHECK_TMP"
if [ -n "${FLUTTER_BIN:-}" ]; then
  SAKAN_CHECK_FLUTTER="$FLUTTER_BIN"
else
  git clone --depth 1 --branch 3.47.4 https://github.com/flutter/flutter.git "$SAKAN_CHECK_TMP/flutter-sdk"
  SAKAN_CHECK_FLUTTER="$SAKAN_CHECK_TMP/flutter-sdk/bin/flutter"
fi
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export XDG_CONFIG_HOME="$SAKAN_CHECK_TMP/config"
cd "$SAKAN_CHECK_TMP/app"
if [ "${SAKAN_CHECK_OFFLINE:-0}" = 1 ]; then
  "$SAKAN_CHECK_FLUTTER" --suppress-analytics pub get --offline
else
  "$SAKAN_CHECK_FLUTTER" --suppress-analytics pub get
fi
"$SAKAN_CHECK_FLUTTER" --suppress-analytics analyze --no-pub --fatal-infos --fatal-warnings
