"""Minimal ISO9660 builder for a cloud-init NoCloud seed (pure stdlib).

Why this exists: a disposable Linux guest needs to be provisioned with an
identity the hub chooses (hostname, ssh password) and cloud-init's NoCloud
datasource reads that from a filesystem labeled ``cidata`` — either ISO9660
or vfat. This module writes the ISO9660 variant from nothing but ``struct``
and ``zlib``-free stdlib, so provisioning a guest needs NO installed tool
(hdiutil/genisoimage/mkfs.vfat) and no pip package — the "100% free, nothing
to install" constraint of the guest path holds end to end.

Format scope: a single-volume, single-session ISO9660 with a root directory
only (no subdirectories), which is exactly what NoCloud needs. Files are
stored under BOTH their lowercase names (user-data, meta-data, …) and
UPPERCASE variants pointing at the same extents, so the seed parses
regardless of whether the guest's ISO reader matches case-insensitively
(pycdlib's default) or literally — belt and suspenders for a hand-rolled
container format.

The output is validated in test_fleet_guests.py by walking the directory
records back out of the generated image (and, live, by cloud-init itself on
first boot).

Layout (2048-byte sectors):
    0–15   system area (zeroed)
    16     primary volume descriptor (volume id "CIDATA", both-endian)
    17     volume descriptor set terminator
    18–19  L/M path tables (root only)
    20     root directory
    21..   file extents (one sector per file, or more for large payloads)
"""

from __future__ import annotations

import struct
import time
from pathlib import Path

LOGICAL_BLOCK = 2048
VOLUME_ID = b"CIDATA"

# Directory-record flags: 0 = file, 2 = directory (bit 1).
_FLAG_FILE = 0x00
_FLAG_DIR = 0x02


def _both_endian32(value: int) -> bytes:
    """ISO9660 stores 32-bit numbers twice: little-endian then big-endian."""
    return struct.pack("<I", value) + struct.pack(">I", value)


def _both_endian16(value: int) -> bytes:
    return struct.pack("<H", value) + struct.pack(">H", value)


def _record_date(ts: time.struct_time | None = None) -> bytes:
    """7-byte directory-record date: year-1900, mo, d, h, min, s, gmt offset."""
    ts = ts or time.gmtime()
    return bytes((ts.tm_year - 1900, ts.tm_mon, ts.tm_mday,
                  ts.tm_hour, ts.tm_min, ts.tm_sec, 0))


def _dir_record(identifier: bytes, extent: int, size: int, flags: int) -> bytes:
    """One ISO9660 directory record, padded to an even total length.

    Record layout (offsets from the record start, which includes the length
    byte itself): len(1) ext-attr(1) extent(8) size(8) date(7) flags(1)
    unit(1) gap(1) vol-seq(2) id-len(1) id(n) pad(0/1). The total is
    31 + n rounded up to even — the shape genisoimage writes (minus its
    2-byte system-use trailer, which readers do not require).
    """
    body = (
        struct.pack("<B", 0)                      # extended attribute length
        + _both_endian32(extent)
        + _both_endian32(size)
        + _record_date()
        + struct.pack("<B", flags)
        + struct.pack("<BB", 0, 0)                # file unit size, interleave gap
        + _both_endian16(1)                        # volume sequence number (LE+BE)
        + struct.pack("<B", len(identifier))
        + identifier
    )
    length = 33 + len(body)                        # 33 + n, includes len byte
    length += length % 2                           # records must be even
    return struct.pack("<B", length) + body + b"\x00" * (length - 1 - len(body))


def build_seed_iso(payloads: dict[str, bytes], volume_id: bytes = VOLUME_ID) -> bytes:
    """Build a NoCloud seed ISO from ``{filename: content}``.

    Returns the complete image as bytes. Every filename is stored twice
    (verbatim and UPPERCASE) per the docstring; both records share the same
    extent, so the disk cost is just a handful of extra directory records.
    """
    names = [(name, name.upper()) for name in payloads]
    # Deduplicate: if a caller passes both "user-data" and "USER-DATA", keep
    # the first occurrence (same content anyway — NoCloud reads one of them).
    seen: set[str] = set()
    records: list[tuple[str, bytes]] = []
    for lower, upper in names:
        for cand in (lower, upper):
            if cand not in seen:
                seen.add(cand)
                records.append((cand, payloads[lower]))
    # Also fold in the "." and ".." entries for the root directory.
    total_sectors = 21 + sum(
        (len(data) + LOGICAL_BLOCK - 1) // LOGICAL_BLOCK for _, data in records
    )
    root_extent = 20
    root_size = LOGICAL_BLOCK

    # File extents start right after the root directory sector.
    extents: list[tuple[str, bytes, int]] = []
    cursor = root_extent + 1
    for name, data in records:
        extents.append((name, data, cursor))
        cursor += (len(data) + LOGICAL_BLOCK - 1) // LOGICAL_BLOCK

    # --- Directory records -------------------------------------------------
    dot = _dir_record(b"\x00", root_extent, root_size, _FLAG_DIR)
    dotdot = _dir_record(b"\x01", root_extent, root_size, _FLAG_DIR)
    file_records = [_dir_record(name.encode("ascii"), extent, len(data), _FLAG_FILE)
                    for name, data, extent in extents]
    root_dir = b"".join([dot, dotdot] + file_records)
    if len(root_dir) > root_size:
        raise ValueError(f"seed ISO root directory overflow ({len(root_dir)} bytes)")
    root_dir = root_dir.ljust(root_size, b"\x00")

    # --- Path tables (root only) -------------------------------------------
    # Record: id-len(1), ext-attr(1), extent(4), parent-dir-number(2), id, pad.
    # The root's id is empty (0 bytes) so its record is exactly 8 bytes —
    # padding it further would read as a second, truncated record.
    path_table = struct.pack("<BB", 0, 0) + struct.pack("<I", root_extent) \
        + struct.pack("<H", 1)
    l_path = path_table.ljust(LOGICAL_BLOCK, b"\x00")
    m_path = _reverse_path_table(path_table).ljust(LOGICAL_BLOCK, b"\x00")

    # --- Primary volume descriptor -----------------------------------------
    pvd = bytearray(LOGICAL_BLOCK)
    pvd[0:1] = b"\x01"                            # type: primary volume descriptor
    pvd[1:6] = b"CD001"
    pvd[6:7] = b"\x01"                            # version
    pvd[8:40] = b" " * 32                         # system identifier
    pvd[40:72] = volume_id.ljust(32, b" ")        # volume identifier = CIDATA
    pvd[80:88] = _both_endian32(total_sectors)    # volume space size
    pvd[120:124] = _both_endian16(1)              # volume set size
    pvd[124:128] = _both_endian16(1)              # volume sequence number
    pvd[128:132] = struct.pack("<H", LOGICAL_BLOCK) + struct.pack(">H", LOGICAL_BLOCK)
    pvd[132:140] = _both_endian32(len(path_table))  # path table size
    pvd[140:144] = struct.pack("<I", 18)          # L path table location
    pvd[148:152] = struct.pack(">I", 19)          # M path table location
    pvd[156:190] = _dir_record(b"\x00", root_extent, root_size, _FLAG_DIR)
    pvd[190:318] = b" " * 128                     # volume set identifier
    pvd[318:446] = b" " * 128                     # publisher
    pvd[446:574] = b" " * 128                     # data preparer
    pvd[574:702] = b"VERTUS seed builder".ljust(128, b" ")  # application
    pvd[702:739] = b" " * 37                      # copyright
    pvd[739:776] = b" " * 37                      # abstract
    pvd[776:813] = b" " * 37                      # bibliographic
    now = time.gmtime()
    date = b"%04d%02d%02d%02d%02d%02d00" % (now.tm_year, now.tm_mon, now.tm_mday,
                                            now.tm_hour, now.tm_min, now.tm_sec)
    pvd[813:830] = date
    pvd[830:847] = date
    pvd[847:864] = b"0" * 16 + b"00"
    pvd[864:881] = b"0" * 16 + b"00"
    pvd[881:882] = b"\x01"                        # file structure version

    terminator = bytearray(LOGICAL_BLOCK)
    terminator[0:1] = b"\xff"
    terminator[1:6] = b"CD001"
    terminator[6:7] = b"\x01"

    out = bytearray(total_sectors * LOGICAL_BLOCK)
    out[16 * LOGICAL_BLOCK:17 * LOGICAL_BLOCK] = pvd
    out[17 * LOGICAL_BLOCK:18 * LOGICAL_BLOCK] = terminator
    out[18 * LOGICAL_BLOCK:19 * LOGICAL_BLOCK] = l_path
    out[19 * LOGICAL_BLOCK:20 * LOGICAL_BLOCK] = m_path
    out[20 * LOGICAL_BLOCK:21 * LOGICAL_BLOCK] = root_dir
    for _name, data, extent in extents:
        start = extent * LOGICAL_BLOCK
        out[start:start + len(data)] = data
    return bytes(out)


def _reverse_path_table(table: bytes) -> bytes:
    """The M (big-endian) path table is the L table with each field byte-swapped."""
    out = bytearray()
    pos = 0
    while pos < len(table):
        id_len = table[pos]
        pad = id_len % 2
        entry = table[pos:pos + 10 + id_len + pad]
        out += entry[0:2] + entry[2:6][::-1] + entry[6:8][::-1] \
            + entry[8:10 + id_len] + entry[10 + id_len:10 + id_len + pad]
        pos += len(entry)
    return bytes(out)


def write_seed_iso(path: Path, payloads: dict[str, bytes],
                   volume_id: bytes = VOLUME_ID) -> Path:
    """Build and write a seed ISO to ``path`` (returns the path)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(build_seed_iso(payloads, volume_id=volume_id))
    return path