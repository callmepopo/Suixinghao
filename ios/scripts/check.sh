#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build/checks
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/VoiceSendLoop.swift Suixinghao/PCMFrames.swift scripts/check.swift -o .build/checks/contracts
.build/checks/contracts
xcrun swiftc -D DEBUG -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/VoiceSendLoop.swift Suixinghao/VoiceTransport.swift Suixinghao/PCMFrames.swift scripts/audio-check.swift -o .build/checks/audio-check
.build/checks/audio-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/SharedOperation.swift scripts/recovery-check.swift -o .build/checks/recovery-check
.build/checks/recovery-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/CallSession.swift scripts/calling-check.swift -o .build/checks/calling-check
.build/checks/calling-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/ConnectionRecovery.swift Suixinghao/AppSource.swift scripts/reliability-check.swift -o .build/checks/reliability-check
.build/checks/reliability-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/ConnectionHistory.swift scripts/history-check.swift -o .build/checks/history-check
.build/checks/history-check
python3 scripts/version.py
