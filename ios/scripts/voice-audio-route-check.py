#!/usr/bin/env python3
"""Run the shipped VoiceAudio routing code against deterministic audio doubles."""
import os
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
out = root / '.build/checks/voice-audio-route'
out.mkdir(parents=True, exist_ok=True)
for name in ['VoiceAudio.swift', 'PCMFrames.swift', 'PCMInputConverter.swift']:
    source = (root / 'Suixinghao' / name).read_text()
    (out / name).write_text(source.replace('import AVFoundation\n', ''))
env = os.environ.copy()
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-parse-as-library', '-module-cache-path', str(out / 'module-cache'),
                str(out / 'VoiceAudio.swift'), str(out / 'PCMFrames.swift'), str(out / 'PCMInputConverter.swift'),
                str(root / 'Suixinghao/VoiceSendLoop.swift'), str(root / 'scripts/fixtures/voice-audio-route.swift'),
                '-o', str(out / 'check')], env=env, check=True)
subprocess.run([str(out / 'check')], check=True, timeout=90)
