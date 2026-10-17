import hashlib
from pathlib import Path
import struct
import subprocess
import sys

from fontTools.ttLib import TTCollection, TTFont, TTLibError


FONT_EXTENSIONS = {".ttf", ".otf", ".ttc", ".otc"}


def host_font_directories():
    return [Path.home() / "Library/Fonts", Path("/Library/Fonts")]


def font_metadata(path):
    fields = {1: "families", 16: "families", 8: "manufacturers", 13: "licenseDescriptions", 14: "licenseUrls"}
    values = {key: set() for key in fields.values()}
    if path.suffix.lower() in {".ttc", ".otc"}:
        container = TTCollection(path, lazy=True)
    else:
        container = TTFont(path, lazy=True)
    with container:
        faces = container.fonts if isinstance(container, TTCollection) else [container]
        for face in faces:
            if "name" not in face:
                continue
            for record in face["name"].names:
                key = fields.get(record.nameID)
                if key is not None:
                    value = record.toUnicode(errors="replace").strip()
                    if value:
                        values[key].add(value)
    return {key: sorted(items) for key, items in values.items()}


def discover_fonts(directories):
    fonts = []
    seen = set()
    for directory in directories:
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*")):
            if path.name.startswith("._") or path.suffix.lower() not in FONT_EXTENSIONS or not path.is_file():
                continue
            if path.resolve() in seen:
                continue
            seen.add(path.resolve())
            try:
                metadata = font_metadata(path)
            except (OSError, TTLibError, UnicodeError, ValueError, KeyError, struct.error) as error:
                print(f"Skipping unreadable host font {path}: {error}", file=sys.stderr)
                continue
            if metadata["families"]:
                fonts.append({"path": str(path), **metadata})
    return fonts


def stage_fonts(directories, families, staging):
    if not families:
        print("Host font copying is disabled", flush=True)
        return []
    requested = {family.strip().casefold() for family in families}
    found = set()
    hashes = set()
    files = []
    for font in discover_fonts(directories):
        matched = requested.intersection(family.casefold() for family in font["families"])
        if not matched:
            continue
        source = Path(font["path"])
        data = source.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest in hashes:
            continue
        filename = f"voom-{digest}{source.suffix.lower()}"
        staging.mkdir(parents=True, exist_ok=True)
        staged = staging / filename
        staged.write_bytes(data)
        metadata = font_metadata(staged)
        matched = requested.intersection(family.casefold() for family in metadata["families"])
        if not matched:
            raise ValueError(f"Host font changed while preparing it: {source}")
        found.update(matched)
        hashes.add(digest)
        files.append({"file": filename, "sourceFile": source.name, "sha256": digest, **metadata})
        print(f"Selected host font: {source.name} ({', '.join(metadata['families'])})", flush=True)
    for family in families:
        if family.strip().casefold() not in found:
            print(f"Optional host font family not found: {family}", flush=True)
    return files


def install_fonts(guest, files, staging):
    if not files:
        return
    guest.ssh('mkdir -p "$HOME/Library/Fonts"', timeout=60)
    for font in files:
        destination = f"Library/Fonts/{font['file']}"
        guest.copy(staging / font["file"], destination)
        result = guest.ssh(
            f'/run/current-system/sw/bin/sha256sum "$HOME/{destination}"',
            stdout=subprocess.PIPE,
            timeout=60,
        )
        fields = result.stdout.split()
        if not fields or fields[0] != font["sha256"]:
            raise ValueError(f"Guest font checksum mismatch: {font['sourceFile']}")
    print(f"Copied and verified {len(files)} host font files in the guest", flush=True)
