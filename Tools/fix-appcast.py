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

PLACEHOLDER = "PLACEHOLDER"

tree = ET.parse(source)
rewritten = 0
for item in tree.getroot().iter("item"):
    version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
    if version is None:
        continue
    # Every enclosure under this item, not just the direct child. A
    # delta lives inside <sparkle:deltas>, and the first version of this
    # script rewrote only the top-level one — leaving "PLACEHOLDER" in
    # the delta's URL. Sparkle would have tried it, failed, and fallen
    # back to the full download, so the feed would have looked fine.
    for enclosure in item.iter("enclosure"):
        filename = enclosure.get("url", "").rsplit("/", 1)[-1]
        if not filename:
            continue
        enclosure.set("url", f"{base}/v{version}/{filename}")
        rewritten += 1

tree.write(destination, encoding="utf-8", xml_declaration=True)

# Refuse to publish a feed with an unrewritten URL in it. A broken
# enclosure degrades quietly rather than failing, which is the kind of
# thing that ships.
published = open(destination, encoding="utf-8").read()
if PLACEHOLDER in published:
    sys.exit(
        f"appcast: {PLACEHOLDER} survived the rewrite — refusing to publish "
        f"a feed with a URL that cannot resolve"
    )

print(f"appcast: {rewritten} enclosure(s), pointed at {base}/v<version>/")
