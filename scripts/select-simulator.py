#!/usr/bin/env python3
"""Select an iPhone destination supported by the active Xcode and project."""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
result = subprocess.run(
    ['xcodebuild', '-project', str(root / 'ios/HardPause.xcodeproj'),
     '-scheme', 'HardPause', '-showdestinations'],
    check=True, capture_output=True, text=True,
)
available = result.stdout.split('Ineligible destinations')[0]
for line in available.splitlines():
    if 'platform:iOS Simulator' not in line or 'name:iPhone' not in line:
        continue
    match = re.search(r'\bid:([0-9a-fA-F-]{36})\b', line)
    if match:
        print(match.group(1))
        sys.exit(0)
sys.exit('No compatible iPhone simulator. Install an iOS runtime in Xcode Settings > Components.')
