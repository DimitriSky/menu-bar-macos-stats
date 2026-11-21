#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate

typeset -a signing_args
signing_args=()
if [[ -n "${MENUBARSTATS_SIGN_IDENTITY:-}" ]]; then
  signing_args+=("CODE_SIGN_IDENTITY=${MENUBARSTATS_SIGN_IDENTITY}")
fi
if [[ -n "${MENUBARSTATS_DEVELOPMENT_TEAM:-}" ]]; then
  signing_args+=("DEVELOPMENT_TEAM=${MENUBARSTATS_DEVELOPMENT_TEAM}")
fi

xcodebuild -project MenuBarStats.xcodeproj -scheme MenuBarStats -configuration Release \
  -derivedDataPath build "${signing_args[@]}" build
rm -rf MenuBarStats.app
/usr/bin/ditto build/Build/Products/Release/MenuBarStats.app MenuBarStats.app
