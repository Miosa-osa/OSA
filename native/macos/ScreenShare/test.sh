#!/bin/sh
set -eu
cd "$(dirname "$0")"
MODE="${OSA_CAPTURE_TEST_BUILD_MODE:-release}"
./build.sh "$MODE"
python3 tests/lifecycle.py ".build/$MODE/ScreenShare"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" \
    -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework Network \
    Sources/ScreenShare/Lifetime.swift Sources/ScreenShare/FrameEncoder.swift \
    Sources/ScreenShare/VncServer.swift Sources/ScreenShare/Capture.swift \
    Sources/ScreenShare/DesktopInput.swift Sources/ScreenShare/KeyMapping.swift \
    tests/FrameProducer.swift -o ".build/$MODE/FrameProducer"
python3 tests/stream.py ".build/$MODE/FrameProducer"
swiftc Sources/ScreenShare/DesktopInput.swift Sources/ScreenShare/KeyMapping.swift \
    tests/InputTests.swift -o ".build/$MODE/InputTests"
".build/$MODE/InputTests"
swiftc Sources/ScreenShare/DesktopPermissions.swift Sources/ScreenShare/CaptureSession.swift \
    Sources/ScreenShare/Capture.swift Sources/ScreenShare/VncServer.swift \
    Sources/ScreenShare/FrameEncoder.swift Sources/ScreenShare/DesktopInput.swift \
    Sources/ScreenShare/KeyMapping.swift tests/PermissionTests.swift -o ".build/$MODE/PermissionTests"
".build/$MODE/PermissionTests"
swiftc Sources/ScreenShare/Lifetime.swift Sources/ScreenShare/FrameEncoder.swift \
    Sources/ScreenShare/VncServer.swift Sources/ScreenShare/DesktopInput.swift \
    Sources/ScreenShare/KeyMapping.swift tests/InputProtocol.swift -o ".build/$MODE/InputProtocol"
python3 tests/input_protocol.py ".build/$MODE/InputProtocol"
swiftc Sources/ScreenShare/Config.swift tests/ConfigTests.swift -o ".build/$MODE/ConfigTests"
".build/$MODE/ConfigTests"
mkdir -p .build/watchdog-fixture
swiftc tests/LegacyHelper.swift -o .build/watchdog-fixture/osa-screen-capture-darwin
python3 tests/watchdog.py .build/watchdog-fixture/osa-screen-capture-darwin ../../../scripts/capture_watchdog.py
