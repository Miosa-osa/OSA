#!/bin/sh
set -eu
cd "$(dirname "$0")"
./build.sh
python3 tests/lifecycle.py .build/release/ScreenShare
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" \
    -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework Network \
    Sources/ScreenShare/Lifetime.swift Sources/ScreenShare/FrameEncoder.swift \
    Sources/ScreenShare/VncServer.swift Sources/ScreenShare/Capture.swift \
    tests/FrameProducer.swift -o .build/release/FrameProducer
python3 tests/stream.py .build/release/FrameProducer
mkdir -p .build/watchdog-fixture
swiftc tests/LegacyHelper.swift -o .build/watchdog-fixture/osa-screen-capture-darwin
python3 tests/watchdog.py .build/watchdog-fixture/osa-screen-capture-darwin ../../../scripts/capture_watchdog.py
