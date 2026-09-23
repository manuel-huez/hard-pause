#!/usr/bin/env python3
"""Write the single latest-version Sparkle feed for a GitHub release."""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "https://github.com/manuel-huez/hard-pause"
ARCHIVE_NAME = "HardPause-macOS.zip"


def plist_value(app: Path, key: str) -> str:
    return subprocess.check_output(
        ["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", str(app / "Contents/Info.plist")],
        text=True,
    ).strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--signature", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
        parser.error("tag must be vMAJOR.MINOR.PATCH")
    version = plist_value(args.app, "CFBundleShortVersionString")
    build = plist_value(args.app, "CFBundleVersion")
    if version != args.tag[1:] or not re.fullmatch(r"[1-9][0-9]*", build):
        parser.error("app version or build number does not match release")
    signature_text = args.signature.read_text().strip()
    match = re.fullmatch(r'sparkle:edSignature="([A-Za-z0-9+/=]+)" length="([0-9]+)"', signature_text)
    if match is None:
        parser.error("unexpected Sparkle signature output")
    signature, signed_length = match.groups()
    if len(base64.b64decode(signature, validate=True)) != 64:
        parser.error("Sparkle signature must decode to 64 bytes")
    if int(signed_length) != args.archive.stat().st_size:
        parser.error("signed length differs from archive size")

    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Hard Pause updates"
    ET.SubElement(channel, "link").text = REPO
    ET.SubElement(channel, "description").text = "Signed macOS releases of Hard Pause"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Hard Pause {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": f"{REPO}/releases/download/{args.tag}/{ARCHIVE_NAME}",
            f"{{{SPARKLE}}}edSignature": signature,
            "length": signed_length,
            "type": "application/zip",
        },
    )
    ET.indent(rss)
    args.output.write_bytes(ET.tostring(rss, encoding="utf-8", xml_declaration=True))


if __name__ == "__main__":
    main()
