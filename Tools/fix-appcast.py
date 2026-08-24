#!/usr/bin/env python3
"""Point each appcast entry at its own GitHub release asset.

`generate_appcast` takes a single `--download-url-prefix` for the whole
feed, but GitHub puts the tag in the asset path — so v0.1.2 and v0.1.3
live under different prefixes and one value cannot serve both.

Rewriting afterwards keeps the disk images out of the repository. The
alternative, hosting them on Pages so the prefix is constant, grows the
git history by an image per release for ever and can never be undone.

The version comes from each item's own `sparkle:shortVersionString`, so
the URL cannot disagree with the release it describes.
"""
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

source, destination, base = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/")

tree = ET.parse(source)
rewritten = 0
for item in tree.getroot().iter("item"):
    version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
    enclosure = item.find("enclosure")
    if version is None or enclosure is None:
        continue
    filename = enclosure.get("url", "").rsplit("/", 1)[-1]
    if not filename:
        continue
    enclosure.set("url", f"{base}/v{version}/{filename}")
    rewritten += 1

tree.write(destination, encoding="utf-8", xml_declaration=True)
print(f"appcast: {rewritten} release(s), pointed at {base}/v<version>/")
