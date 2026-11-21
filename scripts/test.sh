#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
xcrun swiftc Sources/MetricsModels.swift Sources/ProcessInspector.swift Tests/main.swift -o build/tests/MetricsTests
./build/tests/MetricsTests
test_app="${MENUBARSTATS_TEST_APP:-./MenuBarStats.app}"
"$test_app/Contents/MacOS/MenuBarStats" --self-test
codesign --verify --deep --strict "$test_app"
