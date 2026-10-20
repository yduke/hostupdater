#!/usr/bin/env python3
"""Convert a Gettext .po file to LuCI's binary .lmo format.

This is a dependency-free reimplementation of LuCI's po2lmo (lmo.c/po2lmo.c)
for environments without the native tool (e.g. Windows). It supports singular
messages and the Plural-Forms header; plural msgstr[n] forms are rejected
instead of being silently mis-encoded.

Layout:
  [UTF-8 values, each padded to 4 bytes]
  [index entries: key_id, val_id, offset, length (big endian uint32), sorted]
  [index offset (big endian uint32)]
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PO = ROOT / "po/zh-cn/hostupdater.po"
DEFAULT_LMO = ROOT / "files/usr/lib/lua/luci/i18n/hostupdater.zh-cn.lmo"


def sfh_get16(data, offset):
    return data[offset] | (data[offset + 1] << 8)


def sfh_hash(data, init=None):
    """Paul Hsieh's SuperFastHash as used by LuCI, including signed chars."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    length = len(data)
    if length <= 0:
        return 0
    if init is None:
        init = length
    value = init & 0xFFFFFFFF
    remainder = length & 3
    offset = 0
    for _ in range(length >> 2):
        value = (value + sfh_get16(data, offset)) & 0xFFFFFFFF
        tmp = ((sfh_get16(data, offset + 2) << 11) ^ value) & 0xFFFFFFFF
        value = ((value << 16) ^ tmp) & 0xFFFFFFFF
        offset += 4
        value = (value + (value >> 11)) & 0xFFFFFFFF
    if remainder == 3:
        value = (value + sfh_get16(data, offset)) & 0xFFFFFFFF
        value ^= (value << 16) & 0xFFFFFFFF
        byte = data[offset + 2]
        if byte >= 128:
            byte -= 256
        value ^= (byte << 18) & 0xFFFFFFFF
        value = (value + (value >> 11)) & 0xFFFFFFFF
    elif remainder == 2:
        value = (value + sfh_get16(data, offset)) & 0xFFFFFFFF
        value ^= (value << 11) & 0xFFFFFFFF
        value = (value + (value >> 17)) & 0xFFFFFFFF
    elif remainder == 1:
        byte = data[offset]
        if byte >= 128:
            byte -= 256
        value = (value + byte) & 0xFFFFFFFF
        value ^= (value << 10) & 0xFFFFFFFF
        value = (value + (value >> 1)) & 0xFFFFFFFF
    value ^= (value << 3) & 0xFFFFFFFF
    value = (value + (value >> 5)) & 0xFFFFFFFF
    value ^= (value << 4) & 0xFFFFFFFF
    value = (value + (value >> 17)) & 0xFFFFFFFF
    value ^= (value << 25) & 0xFFFFFFFF
    value = (value + (value >> 6)) & 0xFFFFFFFF
    return value


def canon(text):
    """Whitespace normalisation performed by lmo_canon_hash()."""
    out = []
    previous_space = True
    for char in text:
        if char.isspace():
            if not previous_space:
                out.append(" ")
            previous_space = True
        else:
            out.append(char)
            previous_space = False
    while out and out[-1] == " ":
        out.pop()
    return "".join(out)


def unquote(value):
    return (
        value.replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace("\\r", "\r")
        .replace('\\"', '"')
        .replace("\\\\", "\\")
    )


def parse_po(path):
    text = path.read_text(encoding="utf-8")
    entries = []
    current = {}
    field = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            if not line and current:
                entries.append(current)
                current = {}
                field = None
            continue
        match = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+"(.*)"$', line)
        if match:
            field = match.group(1)
            value = unquote(match.group(2))
            if field.startswith("msgstr["):
                raise SystemExit("plural msgstr is not supported: %s" % field)
            current[field] = current.get(field, "") + value
        elif line.startswith('"') and field:
            current[field] = current.get(field, "") + unquote(line[1:-1])
        else:
            raise SystemExit("unsupported po line: %r" % raw)
    if current:
        entries.append(current)
    return entries


def plural_header(entries):
    for entry in entries:
        if entry.get("msgid", None) == "":
            header = entry.get("msgstr", "")
            match = re.search(r"^Plural-Forms:\s*(.+)$", header, re.M)
            if match:
                return match.group(1).strip()
    return None


def build(entries, output):
    values = bytearray()
    index = []

    header = plural_header(entries)
    if header:
        data = header.encode("utf-8")
        index.append((0, 0, len(values), len(data)))
        values += data + b"\0" * ((4 - len(data) % 4) % 4)

    for entry in entries:
        msgid = entry.get("msgid", "")
        if not msgid:
            continue
        if "msgid_plural" in entry:
            raise SystemExit("plural entries are not supported: %r" % msgid)
        if "msgctxt" in entry:
            raise SystemExit("context entries are not supported: %r" % msgid)
        msgstr = entry.get("msgstr", "")
        if not msgstr or msgstr == msgid:
            continue
        key = canon(msgid).encode("utf-8")
        key_id = sfh_hash(key)
        value = msgstr.encode("utf-8")
        if key_id == sfh_hash(value):
            continue
        index.append((key_id, 1, len(values), len(value)))
        values += value + b"\0" * ((4 - len(value) % 4) % 4)

    index.sort(key=lambda item: item[0])
    index_offset = len(values)
    for key_id, val_id, offset, length in index:
        values += struct.pack(">IIII", key_id, val_id, offset, length)
    values += struct.pack(">I", index_offset)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(values)
    return len(index), index_offset


def check(po_entries, lmo_path):
    """Verify every translated po entry is present with the expected text."""
    data = lmo_path.read_bytes()
    if len(data) < 4:
        raise SystemExit("lmo is truncated")
    index_offset = struct.unpack(">I", data[-4:])[0]
    if index_offset >= len(data) or (len(data) - index_offset - 4) % 16:
        raise SystemExit("bad lmo index")
    count = (len(data) - index_offset - 4) // 16
    index = []
    previous = -1
    for i in range(count):
        key_id, val_id, offset, length = struct.unpack(
            ">IIII", data[index_offset + i * 16:index_offset + (i + 1) * 16]
        )
        if key_id < previous:
            raise SystemExit("lmo index is not sorted")
        previous = key_id
        if offset + length > index_offset:
            raise SystemExit("entry points outside the value area")
        index.append((key_id, data[offset:offset + length].decode("utf-8")))

    by_hash = {key: value for key, value in index}
    translated = 0
    for entry in po_entries:
        msgid = entry.get("msgid", "")
        msgstr = entry.get("msgstr", "")
        if not msgid or not msgstr or msgstr == msgid:
            continue
        translated += 1
        key_id = sfh_hash(canon(msgid))
        if by_hash.get(key_id) != msgstr:
            raise SystemExit(
                "mismatch for %r: expected %r, got %r"
                % (msgid, msgstr, by_hash.get(key_id))
            )
    if len(index) != translated + (1 if plural_header(po_entries) else 0):
        raise SystemExit("unexpected number of lmo entries: %d" % len(index))
    return translated


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("po", nargs="?", default=str(DEFAULT_PO))
    parser.add_argument("lmo", nargs="?", default=str(DEFAULT_LMO))
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    po_path = Path(args.po)
    lmo_path = Path(args.lmo)
    entries = parse_po(po_path)
    if not args.check_only:
        count, index_offset = build(entries, lmo_path)
        print("wrote %s: %d entries, index at %d" % (lmo_path, count, index_offset))
    translated = check(entries, lmo_path)
    print("verified %d translated strings in %s" % (translated, lmo_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
