#!/usr/bin/env python3
"""Select or create an iPhone destination supported by the active Xcode."""
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]

def destination():
    result = subprocess.run(
        ['xcodebuild', '-project', str(root / 'ios/HardPause.xcodeproj'),
         '-scheme', 'HardPause', '-showdestinations'],
        check=True, capture_output=True, text=True,
    )
    available = result.stdout.split('Ineligible destinations')[0]
    for line in available.splitlines():
        if 'platform:iOS Simulator' in line and 'name:iPhone' in line:
            match = re.search(r'\bid:([0-9a-fA-F-]{36})\b', line)
            if match:
                return match.group(1)
    return None


device_id = destination()
if not device_id:
    runtimes = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', '-j', 'runtimes']))['runtimes']
    types = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', '-j', 'devicetypes']))['devicetypes']
    runtime = next((item for item in runtimes if item['name'].startswith('iOS 26')
                    and item.get('isAvailable')), None)
    device_type = next((item for item in types if item['name'] == 'iPhone 16e'), None)
    if not runtime or not device_type:
        sys.exit('No compatible iPhone simulator runtime or device type is installed.')
    subprocess.run(
        ['xcrun', 'simctl', 'create', 'iPhone Hard Pause CI',
         device_type['identifier'], runtime['identifier']],
        check=True, capture_output=True, text=True,
    )
    device_id = destination()
if not device_id:
    sys.exit('The new iPhone simulator is not an eligible Xcode test destination.')
print(device_id)
