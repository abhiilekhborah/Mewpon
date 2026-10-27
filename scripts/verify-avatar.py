#!/usr/bin/env python3
"""Verify the packaged avatar catalog and every manifest-referenced asset offline."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "Sources/MewponDesktop/Resources/ExistingMewponAvatar"
manifest = json.loads((root / "spritesheets/manifest.json").read_text())
groups = manifest["groups"]
assert set("neutral happy excited thinking confused sad angry sleepy wink laugh surprised embarrassed proud focused".split()) <= set(groups["expressions"])
assert len(groups["actions"]) == 10
assert len(groups["outfits"]) == 10
files = set()
def visit(value):
    if isinstance(value, dict):
        if "file" in value:
            files.add(value["file"])
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)
visit(manifest)
for file in files:
    path = root / "spritesheets" / file
    assert path.is_file(), f"Missing avatar asset: {file}"
for file in ["mewpon.iife.js", "spritesheets/manifest.js", "index.html", "native-bridge.js", "LICENSE"]:
    assert (root / file).is_file(), file
print(f"Avatar verified: {len(files)} assets; 14 expressions, 10 activities, 10 outfits.")
