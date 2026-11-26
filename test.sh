#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/tests
xcrun swiftc -swift-version 5 -parse-as-library Native/Core.swift Native/OriginalRelink.swift Tests/CoreTests.swift -o build/tests/core-tests
build/tests/core-tests "$PWD/build/tests"
xcrun swiftc -swift-version 5 -parse-as-library Native/Core.swift Native/OriginalRelink.swift Tests/WebTests.swift -framework Cocoa -framework WebKit -o build/tests/web-tests
task_fixture="$(cat build/tests/latest-fixture.txt)"
build/tests/web-tests "$PWD/Resources/index.html" "$task_fixture"

xcrun swiftc -swift-version 5 -D FLOW_TESTS -parse-as-library Native/Core.swift Native/OriginalRelink.swift Native/App.swift Tests/FlowTests.swift -framework Cocoa -framework WebKit -o build/tests/flow-tests
build/tests/flow-tests "$PWD/build/tests"

xcrun swiftc -swift-version 5 -parse-as-library Native/Core.swift Native/OriginalRelink.swift Tests/OriginalRelinkTests.swift -o build/tests/original-relink-tests
build/tests/original-relink-tests /private/tmp
