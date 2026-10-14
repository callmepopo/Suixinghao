#!/usr/bin/env python3
"""Run shipped routing/recovery code against deterministic audio doubles."""
import os
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
out = root / '.build/checks/route-runtime'
out.mkdir(parents=True, exist_ok=True)
for name in ['VoiceAudio.swift', 'PCMFrames.swift']:
    source = (root / 'Suixinghao' / name).read_text()
    (out / name).write_text(source.replace('import AVFoundation\n', ''))
env = os.environ.copy()
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-module-cache-path', str(out / 'module-cache'),
                str(out / 'VoiceAudio.swift'), str(out / 'PCMFrames.swift'),
                str(root / 'Suixinghao/AudioRoutePolicy.swift'), str(root / 'Suixinghao/VoiceSendLoop.swift'),
                str(root / 'scripts/fixtures/audio-route-runtime.swift'), '-o', str(out / 'check')], env=env, check=True)
subprocess.run([str(out / 'check')], check=True, timeout=60)
