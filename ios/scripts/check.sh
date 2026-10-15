#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build/checks
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/VoiceSendLoop.swift Suixinghao/DownlinkJitter.swift Suixinghao/PCMFrames.swift Suixinghao/PCMInputConverter.swift scripts/check.swift -o .build/checks/contracts
.build/checks/contracts
xcrun swiftc -D DEBUG -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/VoiceSendLoop.swift Suixinghao/DownlinkJitter.swift Suixinghao/VoiceTransport.swift Suixinghao/PCMFrames.swift scripts/audio-check.swift -o .build/checks/audio-check
.build/checks/audio-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/DownlinkJitter.swift Suixinghao/VoiceSendLoop.swift Suixinghao/PCMFrames.swift scripts/downlink-check.swift -o .build/checks/downlink-check
.build/checks/downlink-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/SharedOperation.swift scripts/recovery-check.swift -o .build/checks/recovery-check
.build/checks/recovery-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/CallSession.swift scripts/calling-check.swift -o .build/checks/calling-check
.build/checks/calling-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/ConnectionRecovery.swift Suixinghao/AppSource.swift scripts/reliability-check.swift -o .build/checks/reliability-check
.build/checks/reliability-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/ConnectionHistory.swift scripts/history-check.swift -o .build/checks/history-check
.build/checks/history-check
xcrun swiftc -D DEBUG -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/ConnectionStore.swift scripts/sms-settings-check.swift -o .build/checks/sms-settings-check
.build/checks/sms-settings-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/DialerInput.swift scripts/dialer-input-check.swift -o .build/checks/dialer-input-check
.build/checks/dialer-input-check
xcrun swiftc -module-cache-path .build/checks/module-cache Suixinghao/IncomingReminderState.swift scripts/reminder-check.swift -o .build/checks/reminder-check
.build/checks/reminder-check
xcrun swiftc -parse-as-library -module-cache-path .build/checks/module-cache Suixinghao/IncomingReminderState.swift Suixinghao/IncomingCallReminder.swift scripts/reminder-race-check.swift -o .build/checks/reminder-race-check
.build/checks/reminder-race-check
xcrun swiftc -parse-as-library -D DEBUG -module-cache-path .build/checks/module-cache Suixinghao/API.swift Suixinghao/ConnectionHistory.swift Suixinghao/VoiceSendLoop.swift Suixinghao/DownlinkJitter.swift Suixinghao/VoiceTransport.swift Suixinghao/PCMFrames.swift scripts/pong-check.swift -o .build/checks/pong-check
.build/checks/pong-check scripts/push-first-server.py --local-voice-check
python3 scripts/version.py
python3 scripts/speaker-switch-check.py
python3 scripts/voice-audio-route-check.py
python3 scripts/media-reconnect-check.py
