#!/usr/bin/env python3
""" Load classic maps from a WAD into CedarDB. """

import argparse
import io
import os
import re
import struct
import time
import wave
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Dict, List, Tuple

import psycopg2
from psycopg2.extras import execute_values

import midi_render
from cedarscript_runtime import install_cedarscript_runtime
from wad_sql import (
    install_loader_functions,
    load_game_data,
    stamp_line_specials,
    materialize_ui_pixels,
    materialize_render_segs,
    materialize_render_things,
    refresh_derived,
)


LE = "<"  # little-endian struct prefix
DEFAULT_SCHEMA = Path(__file__).resolve().parent / "sql" / "schema.sql"


def progress(message: str):
    print(f"[wad-loader] {message}", flush=True)


# The real vanilla status bar: background, big red digit font (health/armor),
# and the mugshot face states (normal x5 health tiers x3 eye positions, pain,
# god mode, evil grin, dead). Composited by sql/renderer.sql at fixed brightness,
# after the dynamically lit world pixels.
UI_PATCH_NAMES = (
    "STBAR",
    "STTNUM0", "STTNUM1", "STTNUM2", "STTNUM3", "STTNUM4",
    "STTNUM5", "STTNUM6", "STTNUM7", "STTNUM8", "STTNUM9",
    "STTMINUS", "STTPRCNT",
    "STFST00", "STFST01", "STFST02",
    "STFST10", "STFST11", "STFST12",
    "STFST20", "STFST21", "STFST22",
    "STFST30", "STFST31", "STFST32",
    "STFST40", "STFST41", "STFST42",
    "STFTL00", "STFTL10", "STFTL20", "STFTL30", "STFTL40",
    "STFTR00", "STFTR10", "STFTR20", "STFTR30", "STFTR40",
    "STFOUCH0", "STFOUCH1", "STFOUCH2", "STFOUCH3", "STFOUCH4",
    "STFEVL0", "STFEVL1", "STFEVL2", "STFEVL3", "STFEVL4",
    "STFGOD0", "STFDEAD0",
    # Small digit font for the sub-box showing all 4 ammo types at once.
    "STYSNUM0", "STYSNUM1", "STYSNUM2", "STYSNUM3", "STYSNUM4",
    "STYSNUM5", "STYSNUM6", "STYSNUM7", "STYSNUM8", "STYSNUM9",
    # Single-player ARMS panel: gray means unowned, yellow means owned.
    "STARMS", "STGNUM2", "STGNUM3", "STGNUM4", "STGNUM5",
    "STGNUM6", "STGNUM7",
    # Blue/yellow/red key cards and skull keys. E1M2 uses STKEYS2 (red card).
    "STKEYS0", "STKEYS1", "STKEYS2", "STKEYS3", "STKEYS4", "STKEYS5",
    # ---- Title and menu ----
    # Same patch format as the status bar, so they ride the same loader and
    # get the same transparency mask; the menu is then composited by the very
    # query that composites the HUD.
    "TITLEPIC", "CREDIT", "HELP1", "M_DOOM",
    "M_NGAME", "M_OPTION", "M_LOADG", "M_SAVEG", "M_QUITG", "M_RDTHIS",
    "M_NEWG", "M_EPISOD", "M_EPI1", "M_EPI2", "M_EPI3", "M_EPI4",
    "M_SKILL", "M_JKILL", "M_ROUGH", "M_HURT", "M_ULTRA", "M_NMARE",
    "M_SKULL1", "M_SKULL2", "M_PAUSE",
    # Load/Save slot bevels (M_DrawSaveLoadBorder) and their headings.
    "M_LSLEFT", "M_LSCNTR", "M_LSRGHT", "M_LGTTL", "M_SGTTL",
    # ---- Intermission ----
    # Episode background, the two headings, the stat labels, and the number
    # font the percentages and times are spelled out with.
    "WIMAP0", "WIMAP1", "WIMAP2", "INTERPIC",
 # ---- Finale endings: E2 victory, E3 bunny scroll and THE END, E4 ----
 "VICTORY2", "ENDPIC", "PFUB1", "PFUB2",
 "END0", "END1", "END2", "END3", "END4", "END5", "END6",
    "WIF", "WIENTER", "WIOSTK", "WIOSTI", "WISCRT2", "WITIME", "WIPAR",
    "WIPCNT", "WICOLON", "WIMINUS", "WISUCKS", "WIURH0", "WIURH1", "WISPLAT",
    "WINUM0", "WINUM1", "WINUM2", "WINUM3", "WINUM4",
    "WINUM5", "WINUM6", "WINUM7", "WINUM8", "WINUM9",
) + tuple(
    # Level-name banners, ExMy -> WILV(x-1)(y-1).
    f"WILV{e}{m}" for e in range(4) for m in range(9)
) + tuple(
    # The HU text font, one patch per character: STCFN + zero-padded ASCII.
    # Doom only ships 33..95, i.e. '!'..'_', which is why it uppercases every
    # string it draws. STCFN121 exists in the IWAD too and is loaded so the
    # set matches the WAD rather than the documentation.
    f"STCFN{code:03d}" for code in list(range(33, 96)) + [121]
)


def load_ui_patches(fp, cur, lumps):
    """Decode the real status-bar patches (STBAR/STTNUM/STFST/...) verbatim."""
    cur.execute("TRUNCATE ui_patches;")
    cur.execute("TRUNCATE ui_patch_pixels;")

    lmap = {l["name"]: l for l in lumps}
    rows = []
    pixel_rows = []
    skipped = []
    for name in UI_PATCH_NAMES:
        lump = lmap.get(name)
        if lump is None or lump["size"] <= 0:
            skipped.append(name)
            continue
        try:
            fp.seek(lump["ofs"])
            width, height, left, top, cols = _decode_patch(fp.read(lump["size"]))
        except (ValueError, struct.error):
            skipped.append(name)
            continue
        pixels = bytearray(width * height)
        mask = bytearray(width * height)
        for u, posts in cols.items():
            for top_delta, post_pixels in posts:
                for row, palette_index in enumerate(post_pixels):
                    v = top_delta + row
                    if 0 <= v < height:
                        offset = v * width + u
                        pixels[offset] = palette_index
                        mask[offset] = 1
                        pixel_rows.append((name, u, v, palette_index))
        rows.append((
            name, width, height, left, top,
            psycopg2.Binary(bytes(pixels)), psycopg2.Binary(bytes(mask)),
        ))

    if rows:
        execute_values(
            cur,
            """INSERT INTO ui_patches
               (name, width, height, left_offset, top_offset, pixels, mask)
               VALUES %s""",
            rows, page_size=100,
        )
        execute_values(
            cur,
            """INSERT INTO ui_patch_pixels
               (name, dx, dy, palette_index) VALUES %s""",
            pixel_rows, page_size=5000,
        )
        materialize_ui_pixels(cur)
    return len(rows), skipped


def load_sounds(fp, cur, lumps):
    """Load the last occurrence of every Doom DMX DS* sound as a WAV."""
    cur.execute("TRUNCATE sound_assets;")

    # WAD lookup semantics are last-lump-wins. Registered/Ultimate IWADs can
    # contain duplicate DS names, so keying the decoded rows by name matters.
    rows = {}
    total_samples = 0
    for lump in lumps:
        name = lump["name"]
        if not name.startswith("DS") or lump["size"] < 8:
            continue
        fp.seek(lump["ofs"])
        raw = fp.read(lump["size"])
        sample_format, sample_rate, sample_count = struct.unpack(
            LE + "HHI", raw[:8]
        )
        if sample_format != 3 or sample_rate <= 0:
            continue
        sample_count = min(sample_count, len(raw) - 8)
        samples = raw[8:8 + sample_count]
        wav_buffer = io.BytesIO()
        with wave.open(wav_buffer, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(1)
            wav_file.setframerate(sample_rate)
            wav_file.writeframes(samples)
        rows[name] = (name, psycopg2.Binary(wav_buffer.getvalue()), len(samples))

    if rows:
        execute_values(
            cur,
            """INSERT INTO sound_assets (name, wav_data)
               VALUES %s""",
            [(name, wav_data) for name, wav_data, _ in rows.values()],
            page_size=200,
        )
        total_samples = sum(row[2] for row in rows.values())
    return len(rows), total_samples


MUS_CONTROLLER_TO_MIDI = (
    0, 32, 1, 7, 10, 11, 91, 93, 64, 67, 120, 123, 126, 127, 121,
)

DOOM2_MAP_MUSIC = (
    "RUNNIN", "STALKS", "COUNTD", "BETWEE", "DOOM", "THE_DA",
    "SHAWN", "DDTBLU", "IN_CIT", "DEAD", "STLKS2", "THEDA2",
    "DOOM2", "DDTBL2", "RUNNI2", "DEAD2", "STLKS3", "ROMERO",
    "SHAWN2", "MESSAG", "COUNT2", "DDTBL3", "AMPIE", "THEDA3",
    "ADRIAN", "MESSG2", "ROMER2", "TENSE", "SHAWN3", "OPENIN",
    "EVIL", "ULTIMA",
)

ULTIMATE_DOOM_E4_MUSIC = (
    "E3M4", "E3M2", "E3M3", "E1M5", "E2M7",
    "E2M4", "E2M6", "E2M5", "E1M9",
)


def _midi_varlen(value):
    value = max(0, int(value))
    encoded = [value & 0x7F]
    value >>= 7
    while value:
        encoded.append(0x80 | (value & 0x7F))
        value >>= 7
    return bytes(reversed(encoded))


def _mus_channel(channel):
    if channel == 15:
        return 9
    return channel if channel < 9 else channel + 1


def mus_to_midi(data):
    """Convert Doom's compact MUS event stream to a format-0 MIDI file.
    Division 70 at 500,000 us/quarter gives MUS's native 140 ticks/second.
    """
    if len(data) < 16 or data[:4] != b"MUS\x1a":
        raise ValueError("not a Doom MUS lump")
    score_length, score_start = struct.unpack_from(LE + "HH", data, 4)
    end = min(len(data), score_start + score_length)
    pos = score_start
    velocities = [127] * 16
    pending_delta = 0
    track = bytearray(b"\x00\xff\x51\x03\x07\xa1\x20")

    while pos < end:
        descriptor = data[pos]
        pos += 1
        channel = descriptor & 0x0F
        event_type = (descriptor >> 4) & 0x07
        last_in_group = descriptor & 0x80
        midi_channel = _mus_channel(channel)
        event = None

        if event_type == 0:  # release note
            if pos >= end:
                break
            note = data[pos] & 0x7F
            pos += 1
            event = bytes((0x80 | midi_channel, note, 0))
        elif event_type == 1:  # play note, optional new channel velocity
            if pos >= end:
                break
            note = data[pos]
            pos += 1
            if note & 0x80:
                if pos >= end:
                    break
                velocities[channel] = data[pos] & 0x7F
                pos += 1
            event = bytes((
                0x90 | midi_channel, note & 0x7F, velocities[channel],
            ))
        elif event_type == 2:  # pitch wheel: MUS 0..255 -> MIDI 0..16320
            if pos >= end:
                break
            pitch = data[pos] << 6
            pos += 1
            event = bytes((0xE0 | midi_channel, pitch & 0x7F,
                           (pitch >> 7) & 0x7F))
        elif event_type == 3:  # system controller
            if pos >= end:
                break
            controller = data[pos]
            pos += 1
            if controller >= len(MUS_CONTROLLER_TO_MIDI):
                raise ValueError(f"invalid MUS system controller {controller}")
            event = bytes((0xB0 | midi_channel,
                           MUS_CONTROLLER_TO_MIDI[controller], 0))
        elif event_type == 4:  # controller or patch change
            if pos + 1 >= end:
                break
            controller, value = data[pos], data[pos + 1]
            pos += 2
            if controller == 0:
                event = bytes((0xC0 | midi_channel, value & 0x7F))
            else:
                if controller >= len(MUS_CONTROLLER_TO_MIDI):
                    raise ValueError(f"invalid MUS controller {controller}")
                event = bytes((0xB0 | midi_channel,
                               MUS_CONTROLLER_TO_MIDI[controller],
                               value & 0x7F))
        elif event_type == 6:  # score end
            break
        else:
            raise ValueError(f"unsupported MUS event type {event_type}")

        if event is not None:
            track.extend(_midi_varlen(pending_delta))
            track.extend(event)
            pending_delta = 0

        if last_in_group:
            delay = 0
            while pos < end:
                value = data[pos]
                pos += 1
                delay = (delay << 7) | (value & 0x7F)
                if not value & 0x80:
                    break
            pending_delta += delay

    track.extend(_midi_varlen(pending_delta))
    track.extend(b"\xff\x2f\x00")
    return (
        b"MThd" + struct.pack(">IHHH", 6, 0, 1, 70)
        + b"MTrk" + struct.pack(">I", len(track)) + bytes(track)
    )


def music_lump_for_map(map_name):
    map_name = map_name.upper()
    if re.match(r"^E[1-3]M[1-9]$", map_name):
        return "D_" + map_name
    match = re.match(r"^E4M([1-9])$", map_name)
    if match:
        return "D_" + ULTIMATE_DOOM_E4_MUSIC[int(match.group(1)) - 1]
    match = re.match(r"^MAP([0-9][0-9])$", map_name)
    if match:
        index = int(match.group(1)) - 1
        if 0 <= index < len(DOOM2_MAP_MUSIC):
            return "D_" + DOOM2_MAP_MUSIC[index]
    return None


def sky_lump_for_map(map_name):
    """The wall texture drawn where a ceiling is F_SKY1.

    G_DoLoadLevel picks it two different ways: by episode for Doom, and by
    map number for Doom II, where SKY1 runs to MAP11 and SKY2 to MAP20.
    """
    map_name = map_name.upper()
    match = re.match(r"^E([1-4])M[1-9]$", map_name)
    if match:
        return "SKY" + match.group(1)
    match = re.match(r"^MAP([0-9][0-9])$", map_name)
    if match:
        number = int(match.group(1))
        return "SKY1" if number < 12 else "SKY2" if number < 21 else "SKY3"
    return None


def render_music(midis):
    """{name: midi} -> {name: ogg or None}, rendered across the cores."""
    if not midis:
        return {}
    workers = min(8, len(midis), os.cpu_count() or 1)
    out = {}
    with ProcessPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(midi_render.render, midi): name
                   for name, midi in midis.items()}
        for future in as_completed(futures):
            name = futures[future]
            try:
                out[name] = future.result()
            except Exception:
                out[name] = None
    return out


def load_music(fp, cur, lumps, render_audio=True, map_names=()):
    """Load MUS originals plus preconverted MIDI and rebuild map selection."""
    rows = {}
    midis = {}
    for lump in lumps:
        name = lump["name"]
        if not name.startswith("D_") or lump["size"] < 16:
            continue
        fp.seek(lump["ofs"])
        mus = fp.read(lump["size"])
        if not mus.startswith(b"MUS\x1a"):
            continue
        try:
            midi = mus_to_midi(mus)
        except ValueError:
            continue
        midis[name] = midi
        rows[name] = (
            name, psycopg2.Binary(mus), psycopg2.Binary(midi), len(midi),
            None, None, 0,
        )

    cur.execute("SELECT name FROM maps")
    known = {name for (name,) in cur.fetchall()} | {n.upper() for n in map_names}
    wanted = {music_lump_for_map(name) for name in known}
    wanted &= set(rows)
    if render_audio and wanted:
        for name, audio in render_music(
                {name: midis[name] for name in sorted(wanted)}).items():
            if audio:
                head = rows[name]
                rows[name] = (head[0], head[1], head[2], head[3],
                              psycopg2.Binary(audio), midi_render.AUDIO_FORMAT,
                              len(audio))

    cur.execute("TRUNCATE music_assets;")
    cur.execute("TRUNCATE map_music;")
    if rows:
        execute_values(
            cur,
            """INSERT INTO music_assets
                 (name,mus_data,midi_data,audio_data,audio_format) VALUES %s""",
            [(name, mus, midi, audio, fmt)
             for name, mus, midi, _, audio, fmt, _ in rows.values()],
            page_size=100,
        )
    cur.execute("SELECT map_id,name FROM maps")
    mappings = [
        (map_id, music_lump_for_map(map_name))
        for map_id, map_name in cur.fetchall()
    ]
    mappings = [row for row in mappings if row[1] in rows]
    if mappings:
        execute_values(
            cur, "INSERT INTO map_music (map_id,music_name) VALUES %s",
            mappings, page_size=100,
        )
    return (len(rows), sum(row[3] for row in rows.values()),
            sum(row[6] for row in rows.values()))

# WAD parsing helpers
# -------------------------

def _read_at(f, offset: int, size: int) -> bytes:
    f.seek(offset)
    return f.read(size)


def _unpack(fmt: str, data: bytes):
    return struct.unpack(LE + fmt, data)


def _cstr8(raw8: bytes) -> str:
    """
    8-byte ASCII (not guaranteed NUL-terminated).
    psycopg2 forbids NUL in text, so remove ALL 0x00 bytes (not only trailing),
    then strip spaces and uppercase.
    """
    s = raw8.replace(b"\x00", b"").decode("ascii", errors="ignore")
    return s.strip().upper()

def _nullable_tex(raw8: bytes):
    s = _cstr8(raw8)
    # Doom uses "-" to mean "no texture". Keep "-" as-is; empty -> NULL.
    return s if s != "" else None

def _is_map_marker(name: str) -> bool:
    return bool(re.match(r"^E[1-4]M[1-9]$", name) or re.match(r"^MAP[0-9][0-9]$", name))


def parse_wad(fp) -> Tuple[str, List[Dict]]:
    """
    Returns (wad_type, lumps) where lumps is a list of dicts with keys name, ofs, size
    """
    hdr = _read_at(fp, 0, 12)
    ident, numlumps, dir_ofs = _unpack("4sii", hdr)
    ident = ident.decode("ascii", errors="ignore").upper()
    if ident not in ("IWAD", "PWAD"):
        raise ValueError(f"Not a WAD (ident={ident})")
    lumps = []
    for i in range(numlumps):
        entry = _read_at(fp, dir_ofs + i * 16, 16)
        filepos, size, name = _unpack("ii8s", entry)
        lumps.append({"name": _cstr8(name), "ofs": filepos, "size": size})
    return ident, lumps


def _slice_bytes(fp, ofs: int, size: int) -> bytes:
    return _read_at(fp, ofs, size)


def _rows_from_lump(fp, lump: Dict, struct_fmt: str, rec_size: int) -> List[Tuple]:
    raw = _slice_bytes(fp, lump["ofs"], lump["size"])
    cnt = lump["size"] // rec_size
    rows = []
    off = 0
    s = struct.Struct(LE + struct_fmt)
    for _ in range(cnt):
        rows.append(s.unpack_from(raw, off))
        off += rec_size
    return rows


def _gather_map_lumps(lumps: List[Dict], start_idx: int) -> Tuple[str, Dict[str, Dict]]:
    marker = lumps[start_idx]["name"]
    end = len(lumps)
    for j in range(start_idx + 1, len(lumps)):
        if _is_map_marker(lumps[j]["name"]):
            end = j
            break
    by_name = {lumps[i]["name"]: lumps[i] for i in range(start_idx + 1, end)}
    if "BEHAVIOR" in by_name:
        raise ValueError(f"Map {marker} appears to be Hexen-format (BEHAVIOR lump present).")
    return marker, by_name


# -------------------------
# DB helpers
# -------------------------

def _connect(args):
    if args.dsn:
        return psycopg2.connect(args.dsn)
    # fall back to discrete params or env PG* defaults
    return psycopg2.connect(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        dbname=args.dbname,
    )


def _split_statements(sql: str):
    """Split a schema script into single statements."""
    statements, current = [], []
    in_string = in_comment = False
    index = 0
    while index < len(sql):
        char = sql[index]
        if in_comment:
            if char == "\n":
                in_comment = False
                current.append(char)
        elif in_string:
            current.append(char)
            if char == "'":
                # '' is an escaped quote, not the end of the string.
                if sql[index + 1:index + 2] == "'":
                    current.append("'")
                    index += 1
                else:
                    in_string = False
        elif char == "-" and sql[index + 1:index + 2] == "-":
            in_comment = True
            index += 1
        elif char == "'":
            in_string = True
            current.append(char)
        elif char == ";":
            statement = "".join(current).strip()
            if statement:
                statements.append(statement)
            current = []
        else:
            current.append(char)
        index += 1
    tail = "".join(current).strip()
    if tail:
        statements.append(tail)
    return statements


def apply_schema(cur, path: str):
    if not path:
        return
    with open(path, "r", encoding="utf-8") as f:
        sql = f.read()
    # One statement per execute.
    for statement in _split_statements(sql):
        m = re.match(r"CREATE TYPE (\w+) AS ENUM", statement)
        if m:  # no IF NOT EXISTS for types; the schema is applied on every import
            cur.execute("SELECT 1 FROM pg_type WHERE typname = %s", (m.group(1),))
            if cur.fetchone():
                continue
        cur.execute(statement)


def insert_wad(cur, wad_type: str, wad_path: str) -> int:
    cur.execute(
        "INSERT INTO wads (wad_type, wad_path) VALUES (%s, %s) RETURNING wad_id;",
        (wad_type, os.path.abspath(wad_path)),
    )
    return cur.fetchone()[0]


LOADER_MAP_TABLES = (
    "blockmaps", "linedefs", "map_music", "node_children", "nodes",
    "reject_lumps", "render_segs", "render_things", "sector_sound_origins",
    "sectors", "segs", "sidedefs", "ssectors", "things", "vertexes",
)


def _per_map_delete_order(cur):
    """LOADER_MAP_TABLES, children before the parents they reference."""
    cur.execute(
        """SELECT tc.table_name, ccu.table_name
           FROM information_schema.table_constraints tc
           JOIN information_schema.constraint_column_usage ccu
             ON ccu.constraint_name = tc.constraint_name
           WHERE tc.constraint_type = 'FOREIGN KEY'
             AND tc.table_schema = 'public'
           GROUP BY 1, 2"""
    )
    tables = set(LOADER_MAP_TABLES)
    parents = {t: set() for t in tables}
    for child, parent in cur.fetchall():
        if child in tables and parent in tables and child != parent:
            parents[child].add(parent)
    # Emit a table once nothing still queued references it, so a child always
    # lands before the parent it points at -- the order a DELETE needs.
    ordered, remaining = [], dict(parents)
    while remaining:
        referenced = {p for t in remaining for p in parents[t]}
        free = sorted(t for t in remaining if t not in referenced)
        if not free:                      # a cycle would hang the loop
            ordered.extend(sorted(remaining))
            break
        ordered.extend(free)
        for t in free:
            del remaining[t]
    return ordered


def clear_map(cur, map_id: int) -> None:
    """Drop everything this loader owns for a map, children first."""
    for table in _per_map_delete_order(cur):
        cur.execute(f"DELETE FROM {table} WHERE map_id = %s", (map_id,))


def insert_map(cur, wad_id: int, name: str) -> int:
    cur.execute("SELECT map_id FROM maps WHERE name = %s ORDER BY map_id", (name,))
    existing = [row[0] for row in cur.fetchall()]
    for stale in existing[1:]:            # duplicates from before this change
        clear_map(cur, stale)
        cur.execute("DELETE FROM maps WHERE map_id = %s", (stale,))
    if existing:
        map_id = existing[0]
        clear_map(cur, map_id)
        cur.execute(
            "UPDATE maps SET wad_id = %s, sky_texture = %s WHERE map_id = %s",
            (wad_id, sky_lump_for_map(name), map_id),
        )
    else:
        cur.execute(
            "INSERT INTO maps (wad_id, name, sky_texture) VALUES (%s, %s, %s) "
            "RETURNING map_id;",
            (wad_id, name, sky_lump_for_map(name)),
        )
        map_id = cur.fetchone()[0]
    music_name = music_lump_for_map(name)
    if music_name is not None:
        cur.execute(
            """INSERT INTO map_music (map_id,music_name)
               SELECT %s,%s FROM music_assets WHERE name=%s
               ON CONFLICT (map_id) DO UPDATE
               SET music_name=EXCLUDED.music_name""",
            (map_id, music_name, music_name),
        )
    return map_id


# -------------------------
# Texture loading (WAD-global)
# -------------------------

def _lump_map(lumps):
    """name -> (ofs, size); first occurrence wins."""
    m = {}
    for l in lumps:
        m.setdefault(l["name"], (l["ofs"], l["size"]))
    return m


def _read_lump(fp, entry):
    ofs, size = entry
    fp.seek(ofs)
    return fp.read(size)


def _load_palettes(fp, lmap):
    """Return every PLAYPAL palette as a list of 256 (r,g,b) tuples."""
    if "PLAYPAL" not in lmap:
        return None
    raw = _read_lump(fp, lmap["PLAYPAL"])
    count = max(1, len(raw) // 768)
    return [
        [(raw[p * 768 + i * 3], raw[p * 768 + i * 3 + 1],
          raw[p * 768 + i * 3 + 2]) for i in range(256)]
        for p in range(count)
    ]


def _load_palette(fp, lmap):
    """Return palette 0 as a list of 256 (r,g,b) tuples, or None."""
    palettes = _load_palettes(fp, lmap)
    return None if palettes is None else palettes[0]


def _load_colormap(fp, lmap, palettes):
    """Return COLORMAP rows as (pal, level, source, mapped, r, g, b). """
    if "COLORMAP" not in lmap:
        return []
    raw = _read_lump(fp, lmap["COLORMAP"])
    levels = min(34, len(raw) // 256)
    rows = []
    for pal, palette in enumerate(palettes):
        for level in range(levels):
            base = level * 256
            for source in range(256):
                mapped = raw[base + source]
                r, g, b = palette[mapped]
                rows.append((pal, level, source, mapped, r, g, b))
    return rows


def _load_pnames(fp, lmap):
    """Return list of patch names indexed by PNAMES index, or None."""
    if "PNAMES" not in lmap:
        return None
    raw = _read_lump(fp, lmap["PNAMES"])
    cnt = struct.unpack(LE + "i", raw[:4])[0]
    names = []
    o = 4
    for _ in range(cnt):
        names.append(_cstr8(raw[o:o + 8]))
        o += 8
    return names


def _decode_patch(data: bytes):
    """Decode a Doom picture/patch lump into (w, h, left, top, cols).
    cols[x] is a list of (topdelta, pixel_bytes) posts. Pixel index 0 is a
    valid opaque colour for wall textures (not transparent)."""
    w, h, left_offset, top_offset = struct.unpack(LE + "hhhh", data[:8])
    if w <= 0 or h <= 0 or 8 + 4 * w > len(data):
        raise ValueError("invalid Doom patch dimensions")
    colofs = struct.unpack(LE + "%di" % w, data[8:8 + 4 * w])
    cols = {}
    for x in range(w):
        o = colofs[x]
        posts = []
        while 0 <= o < len(data):
            td = data[o]; o += 1
            if td == 0xFF:               # end-of-column sentinel
                break
            ln = data[o]; o += 1
            o += 1                        # unused padding byte
            px = data[o:o + ln]; o += ln
            o += 1                        # unused padding byte
            posts.append((td, px))
        cols[x] = posts
    return w, h, left_offset, top_offset, cols


def _load_patches(fp, lumps):
    """Decode every patch lump between P_START and P_END."""
    names = [l["name"] for l in lumps]
    if "P_START" not in names or "P_END" not in names:
        return {}
    i, j = names.index("P_START"), names.index("P_END")
    cache = {}
    for l in lumps[i + 1:j]:
        if l["size"] <= 0:
            continue
        try:
            fp.seek(l["ofs"])
            cache[l["name"]] = _decode_patch(fp.read(l["size"]))
        except Exception:
            continue
    return cache


def _parse_texture_lump(fp, lmap, lump_name):
    """Parse TEXTURE1/TEXTURE2 into (name, width, height, [(ox,oy,pidx),...])."""
    if lump_name not in lmap:
        return []
    entry = lmap[lump_name]
    fp.seek(entry[0])
    data = fp.read(entry[1])
    n = struct.unpack(LE + "i", data[:4])[0]
    offs = struct.unpack(LE + "%di" % n, data[4:4 + 4 * n])
    out = []
    for o in offs:
        name = _cstr8(data[o:o + 8])
        # masked(int32), width(int16), height(int16), columndir(int32), patchcount(int16)
        _masked, width, height, _coldir, patchcount = struct.unpack(LE + "ihhih", data[o + 8:o + 22])
        patches = []
        po = o + 22
        for _ in range(patchcount):
            ox, oy, pi, _sd, _cm = struct.unpack(LE + "hhhhh", data[po:po + 10])
            patches.append((ox, oy, pi))
            po += 10
        out.append((name, width, height, patches))
    return out


def _load_sprites(fp, cur, lumps):
    """Decode transparent sprite posts and their angle/frame registrations."""
    names = [l["name"] for l in lumps]
    if "S_START" not in names or "S_END" not in names:
        return 0, 0

    start, end = names.index("S_START"), names.index("S_END")
    frame_rows = {}
    lump_rows = {}
    pixel_count = 0

    for lump in lumps[start + 1:end]:
        match = re.match(
            r"^([A-Z0-9]{4})([A-Z])([0-8])(?:([A-Z])([0-8]))?$",
            lump["name"],
        )
        if not match or lump["size"] < 12:
            continue
        try:
            fp.seek(lump["ofs"])
            width, height, left, top, cols = _decode_patch(
                fp.read(lump["size"])
            )
        except (ValueError, struct.error):
            continue

        sprite, frame1, rotation1, frame2, rotation2 = match.groups()
        frame_rows[(sprite, frame1, int(rotation1))] = (
            sprite, frame1, int(rotation1), lump["name"], False,
            width, height, left, top,
        )
        if frame2 is not None:
            frame_rows[(sprite, frame2, int(rotation2))] = (
                sprite, frame2, int(rotation2), lump["name"], True,
                width, height, left, top,
            )

        pixels = bytearray(width * height)
        mask = bytearray(width * height)
        for u, posts in cols.items():
            for top_delta, post_pixels in posts:
                for row, palette_index in enumerate(post_pixels):
                    v = top_delta + row
                    if 0 <= v < height:
                        offset = v * width + u
                        pixels[offset] = palette_index
                        mask[offset] = 1
                        pixel_count += 1
        lump_rows[lump["name"]] = (
            lump["name"], psycopg2.Binary(bytes(pixels)),
            psycopg2.Binary(bytes(mask)),
        )

    if lump_rows:
        execute_values(
            cur,
            """INSERT INTO sprite_lumps (lump_name, pixels, mask)
               VALUES %s""",
            list(lump_rows.values()),
            page_size=200,
        )
    if frame_rows:
        execute_values(
            cur,
            """INSERT INTO sprite_frames
               (sprite, frame, rotation, lump_name, flipped,
                width, height, left_offset, top_offset)
               VALUES %s""",
            list(frame_rows.values()),
            page_size=2000,
        )
    return len(lump_rows), pixel_count


def load_sprites(fp, cur, lumps):
    """Refresh sprite-only assets without rebuilding wall/flat textures."""
    cur.execute("TRUNCATE sprite_frames;")
    cur.execute("TRUNCATE sprite_lumps;")
    cur.execute("TRUNCATE render_things;")
    return _load_sprites(fp, cur, lumps)


def load_textures(fp, cur, lumps, map_names=()):
    """Populate wall, flat, COLORMAP, and sprite data from the WAD.
    Silently skips if the WAD has no texture lumps (e.g. a map-only PWAD)."""
    lmap = _lump_map(lumps)
    palette = _load_palette(fp, lmap)
    if palette is None:
        progress("No PLAYPAL lump; skipping global texture assets.")
        return
    progress("Preparing global texture and sprite tables...")
    progress("Decoding wall patches and texture definitions...")
    pnames = _load_pnames(fp, lmap) or []
    patch_cache = _load_patches(fp, lumps)
    texdefs = _parse_texture_lump(fp, lmap, "TEXTURE1") + _parse_texture_lump(fp, lmap, "TEXTURE2")
    progress(
        f"Decoded {len(patch_cache)} patches and {len(texdefs)} wall textures."
    )

    cur.execute("""TRUNCATE walltex_meta;
                   TRUNCATE flat_textures;
                   TRUNCATE colormap_rgb;""")

    palettes = _load_palettes(fp, lmap) or [palette]
    colormap_rows = _load_colormap(fp, lmap, palettes)
    if not colormap_rows:
        # Identity fallback for unusual WADs without COLORMAP.
        colormap_rows = [
            (pal, level, source, source, *pal_colors[source])
            for pal, pal_colors in enumerate(palettes)
            for level in range(32) for source in range(256)
        ]
    progress(f"Loading {len(colormap_rows)} COLORMAP entries...")
    colormap_rows = [
        row + (psycopg2.Binary(bytes(row[4:7])),)
        for row in colormap_rows
    ]
    execute_values(
        cur,
        """INSERT INTO colormap_rgb
           (pal, level, palette_index, mapped_index, r, g, b, rgb) VALUES %s""",
        colormap_rows,
        page_size=2000,
    )
    # --- Wall textures: one packed palette-index BYTEA per texture ---
    progress(f"Compositing and loading {len(texdefs)} wall textures...")
    meta_rows = []
    n_wall_px = 0
    for texture_index, (name, w, h, patches) in enumerate(texdefs, 1):
        if w <= 0 or h <= 0:
            continue
        # Zero is also the original fallback for texels uncovered by patches.
        tex = bytearray(w * h)
        for ox, oy, pi in patches:
            if pi < 0 or pi >= len(pnames):
                continue
            pname = pnames[pi]
            patch = patch_cache.get(pname)
            if patch is None:
                continue
            pw, _ph, _left, _top, cols = patch
            for x in range(pw):
                tx = ox + x
                if tx < 0 or tx >= w:
                    continue
                for td, pxbytes in cols.get(x, []):
                    for row, palette_index in enumerate(pxbytes):
                        ty = oy + td + row
                        if 0 <= ty < h:
                            tex[ty * w + tx] = palette_index
        meta_rows.append((name, w, h, psycopg2.Binary(bytes(tex))))
        n_wall_px += len(tex)
        if texture_index % 25 == 0 or texture_index == len(texdefs):
            progress(f"Wall textures: {texture_index}/{len(texdefs)} complete.")
    execute_values(cur,
        """INSERT INTO walltex_meta
           (name, width, height, palette_indices) VALUES %s""",
        meta_rows, page_size=500)

    # --- Flats: one packed 64x64 palette-index BYTEA per lump ---
    names = [l["name"] for l in lumps]
    flat_rows = []
    n_flats = 0
    if "F_START" in names and "F_END" in names:
        i, j = names.index("F_START"), names.index("F_END")
        for l in lumps[i + 1:j]:
            if l["size"] != 4096:
                continue
            fp.seek(l["ofs"])
            raw = fp.read(4096)
            name = l["name"]
            flat_rows.append((name, psycopg2.Binary(raw)))
            n_flats += 1
    progress(f"Loading {n_flats} packed flats ({n_flats * 4096} pixels)...")
    execute_values(cur,
        """INSERT INTO flat_textures
           (name, palette_indices) VALUES %s""",
        flat_rows, page_size=500)

    progress("Decoding and loading status-bar patches...")
    n_ui_patches, ui_skipped = load_ui_patches(fp, cur, lumps)
    progress(f"Loaded {n_ui_patches} status-bar patches.")
    if ui_skipped:
        progress(f"  WARNING: {len(ui_skipped)} UI patches are not in this WAD "
                 f"and will render as holes: {', '.join(ui_skipped)}")

    progress("Decoding and loading Doom sound effects...")
    n_sounds, n_sound_samples = load_sounds(fp, cur, lumps)
    progress(
        f"Loaded {n_sounds} sound effects ({n_sound_samples} PCM samples)."
    )
    progress("Converting and loading Doom music...")
    why = midi_render.unavailable_reason()
    if why:
        progress(f"  Music will have no rendered audio ({why}); "
                 "browser clients play no music.")
    n_music, n_midi_bytes, n_audio_bytes = load_music(
        fp, cur, lumps, render_audio=not why, map_names=map_names)
    detail = f"{n_music} music tracks ({n_midi_bytes} MIDI bytes"
    if n_audio_bytes:
        detail += f", {n_audio_bytes // 1024} KiB rendered audio"
    progress(f"Loaded {detail}).")

    progress("Decoding and loading sprites and gameplay definitions...")
    n_sprites, n_sprite_px = load_sprites(fp, cur, lumps)
    progress(
        f"Loaded {len(meta_rows)} wall textures ({n_wall_px} px), "
        f"{n_flats} flats, and {n_sprites} sprites ({n_sprite_px} opaque px)."
    )


# -------------------------
# Loader (per map)
# -------------------------

def load_map(fp, cur, map_id: int, by_name: Dict[str, Dict]):
    # VERTEXES
    if "VERTEXES" in by_name:
        rows = _rows_from_lump(fp, by_name["VERTEXES"], "hh", 4)
        data = [(idx, map_id, x, y) for idx, (x, y) in enumerate(rows)]
        execute_values(cur,
            "INSERT INTO vertexes (id, map_id, x, y) VALUES %s",
            data, page_size=1000
        )

    # SECTORS
    if "SECTORS" in by_name:
        raw = _slice_bytes(fp, by_name["SECTORS"]["ofs"], by_name["SECTORS"]["size"])
        rec_size = 26
        cnt = len(raw) // rec_size
        data = []
        for idx in range(cnt):
            off = idx * rec_size
            floor_h, ceil_h = _unpack("hh", raw[off:off + 4])
            floor_tex = _nullable_tex(raw[off + 4:off + 12])
            ceil_tex = _nullable_tex(raw[off + 12:off + 20])
            light, special, tag = _unpack("hhh", raw[off + 20:off + 26])
            data.append((idx, map_id, floor_h, ceil_h, floor_h, ceil_h,
                         floor_tex, floor_tex, ceil_tex, light, light,
                         special, tag))
        execute_values(cur,
            """INSERT INTO sectors
               (id, map_id, floor_height, ceil_height,
                spawn_floor_height, spawn_ceil_height, spawn_floor_tex,
                floor_tex, ceil_tex, light_level, spawn_light_level,
                special, tag)
               VALUES %s""",
            data, page_size=1000
        )

    # SIDEDEFS
    if "SIDEDEFS" in by_name:
        raw = _slice_bytes(fp, by_name["SIDEDEFS"]["ofs"], by_name["SIDEDEFS"]["size"])
        rec_size = 30
        cnt = len(raw) // rec_size
        data = []
        for idx in range(cnt):
            off = idx * rec_size
            x_off, y_off = _unpack("hh", raw[off:off + 4])
            up = _nullable_tex(raw[off + 4:off + 12])
            low = _nullable_tex(raw[off + 12:off + 20])
            mid = _nullable_tex(raw[off + 20:off + 28])
            sector_id, = _unpack("h", raw[off + 28:off + 30])
            data.append((idx, map_id, x_off, y_off, up, low, mid, sector_id))
        execute_values(cur,
            """INSERT INTO sidedefs
               (id, map_id, x_offset, y_offset, upper_tex, lower_tex, mid_tex, sector_id)
               VALUES %s""",
            data, page_size=1000
        )

    # LINEDEFS
    if "LINEDEFS" in by_name:
        rows = _rows_from_lump(fp, by_name["LINEDEFS"], "HHHHHHH", 14)
        data = []
        for idx, (v1, v2, flags, special, tag, right_sd, left_sd) in enumerate(rows):
            right_sd = -1 if right_sd == 0xFFFF else right_sd
            left_sd = -1 if left_sd == 0xFFFF else left_sd
            data.append((idx, map_id, v1, v2, flags, special, tag, right_sd, left_sd))
        execute_values(cur,
            """INSERT INTO linedefs
               (id, map_id, v1_id, v2_id, flags, special, tag, right_sd_id, left_sd_id)
               VALUES %s""",
            data, page_size=1000
        )

    # THINGS
    if "THINGS" in by_name:
        rows = _rows_from_lump(fp, by_name["THINGS"], "hhhhH", 10)
        data = [(idx, map_id, x, y, angle, typ, flags, x, y, angle)
                for idx, (x, y, angle, typ, flags) in enumerate(rows)]
        execute_values(cur,
            """INSERT INTO things
               (id, map_id, x, y, angle, type, flags,
                spawn_x, spawn_y, spawn_angle)
               VALUES %s""",
            data, page_size=1000
        )

    # SEGS
    if "SEGS" in by_name:
        rows = _rows_from_lump(fp, by_name["SEGS"], "HHhHhh", 12)
        data = [(idx, map_id, v1, v2, angle, ld, dir_, off_)
                for idx, (v1, v2, angle, ld, dir_, off_) in enumerate(rows)]
        execute_values(cur,
            "INSERT INTO segs (id, map_id, v1_id, v2_id, angle, linedef_id, direction, offs) VALUES %s",
            data, page_size=1000
        )

    # SSECTORS
    if "SSECTORS" in by_name:
        rows = _rows_from_lump(fp, by_name["SSECTORS"], "HH", 4)
        data = [(idx, map_id, cnt, first)
                for idx, (cnt, first) in enumerate(rows)]
        execute_values(cur,
            "INSERT INTO ssectors (id, map_id, seg_count, first_seg_id) VALUES %s",
            data, page_size=1000
        )

    # --- NODES (relational children) ---
    if "NODES" in by_name:
        raw = _slice_bytes(fp, by_name["NODES"]["ofs"], by_name["NODES"]["size"])
        rec_size = 28
        cnt = len(raw) // rec_size

        nodes_data = []         # (id, map_id, x, y, dx, dy)
        children_data = []      # (map_id, node_id, side, child_kind, child_node_id, child_ssector_id,
                                #  bbox_top, bbox_bottom, bbox_left, bbox_right)

        for idx in range(cnt):
            off = idx * rec_size
            x, y, dx, dy = _unpack("hhhh", raw[off:off+8])
            rtop, rbot, rleft, rright = _unpack("hhhh", raw[off+8:off+16])
            ltop, lbot, lleft, lright = _unpack("hhhh", raw[off+16:off+24])
            rchild_u16, lchild_u16 = _unpack("HH", raw[off+24:off+28])

            nodes_data.append((idx, map_id, x, y, dx, dy))

            # decode child: bit15 set => SSECTOR; else NODE
            def decode_child(u16):
                if (u16 & 0x8000) != 0:
                    return ('SSECTOR', None, u16 & 0x7FFF)
                else:
                    return ('NODE', u16, None)

            rk, rnode, rssec = decode_child(rchild_u16)
            lk, lnode, lssec = decode_child(lchild_u16)

            children_data.append((map_id, idx, 'R', rk, rnode, rssec, rtop, rbot, rleft, rright))
            children_data.append((map_id, idx, 'L', lk, lnode, lssec, ltop, lbot, lleft, lright))

        # bulk insert
        execute_values(cur,
            "INSERT INTO nodes (id, map_id, x, y, dx, dy) VALUES %s",
            nodes_data, page_size=1000
        )
        execute_values(cur,
            """INSERT INTO node_children
            (map_id, node_id, side, child_kind, child_node_id, child_ssector_id,
                bbox_top, bbox_bottom, bbox_left, bbox_right)
            VALUES %s""",
            children_data, page_size=1000
        )


    # REJECT
    if "REJECT" in by_name:
        data = _slice_bytes(fp, by_name["REJECT"]["ofs"], by_name["REJECT"]["size"])
        cur.execute(
            "INSERT INTO reject_lumps (map_id, data) VALUES (%s, %s) ON CONFLICT (map_id) DO UPDATE SET data = EXCLUDED.data;",
            (map_id, psycopg2.Binary(data)),
        )

    # BLOCKMAP
    if "BLOCKMAP" in by_name:
        data = _slice_bytes(fp, by_name["BLOCKMAP"]["ofs"], by_name["BLOCKMAP"]["size"])
        if len(data) >= 8:
            origin_x, origin_y, cols, rows = _unpack("hhhh", data[:8])
        else:
            origin_x = origin_y = cols = rows = 0
        cur.execute(
            """INSERT INTO blockmaps (map_id, origin_x, origin_y, cols, rows, payload)
               VALUES (%s, %s, %s, %s, %s, %s)
               ON CONFLICT (map_id) DO UPDATE
               SET origin_x = EXCLUDED.origin_x,
                   origin_y = EXCLUDED.origin_y,
                   cols = EXCLUDED.cols,
                   rows = EXCLUDED.rows,
                   payload = EXCLUDED.payload;""",
            (map_id, origin_x, origin_y, cols, rows, psycopg2.Binary(data)),
        )

    progress("  Materializing renderer segment cache...")
    materialize_render_segs(cur, map_id)
    progress("  Materializing renderer Thing cache...")
    materialize_render_things(cur, map_id)


# -------------------------
# Main
# -------------------------

def main():
    ap = argparse.ArgumentParser(description="Load classic DOOM WAD maps into PostgreSQL.")
    ap.add_argument("wad", help="Path to IWAD/PWAD file")
    ap.add_argument("maps", nargs="*", help="Optional map names to load (e.g., MAP01 E1M1)")
    ap.add_argument(
        "--schema",
        default=DEFAULT_SCHEMA,
        help="Schema path (default: sql/schema.sql; applied idempotently)",
    )
    ap.add_argument("--dsn", help="Postgres DSN, e.g. postgresql://user:pass@host:5432/db")
    ap.add_argument("--host", default=os.getenv("PGHOST"))
    ap.add_argument("--port", default=os.getenv("PGPORT"))
    ap.add_argument("--user", default=os.getenv("PGUSER"))
    ap.add_argument("--password", default=os.getenv("PGPASSWORD"))
    ap.add_argument("--dbname", default=os.getenv("PGDATABASE"))
    args = ap.parse_args()

    total_started = time.perf_counter()
    progress(f"Reading {os.path.abspath(args.wad)}...")
    with open(args.wad, "rb") as fp:
        wad_type, lumps = parse_wad(fp)
        available_maps = [l["name"] for l in lumps if _is_map_marker(l["name"])]
        requested_maps = {name.upper() for name in args.maps}
        selected_maps = [
            name for name in available_maps
            if not requested_maps or name.upper() in requested_maps
        ]
        selected_label = ", ".join(selected_maps) if selected_maps else "none"
        progress(
            f"Found {wad_type} with {len(lumps)} lumps and "
            f"{len(available_maps)} maps; selected: {selected_label}."
        )

        progress("Connecting to the database...")
        conn = _connect(args)
        progress("Connected.")
        try:
            # CedarDB requires CREATE INDEX outside a transaction.
            phase_started = time.perf_counter()
            progress(f"Applying schema from {args.schema}...")
            conn.autocommit = True
            with conn.cursor() as cur:
                apply_schema(cur, args.schema)
                install_loader_functions(cur)
            conn.autocommit = False
            progress(
                "Schema and SQL loader functions applied in "
                f"{time.perf_counter() - phase_started:.1f}s."
            )
            phase_started = time.perf_counter()
            progress("Installing the SQL game-tic runtime...")
            conn.autocommit = True
            with conn.cursor() as cur:
                install_cedarscript_runtime(cur)
            conn.autocommit = False
            progress(
                "SQL game-tic runtime installed in "
                f"{time.perf_counter() - phase_started:.1f}s."
            )
            with conn:
                with conn.cursor() as cur:
                    # Insert WAD row and get wad_id
                    wad_id = insert_wad(cur, wad_type, args.wad)
                    progress(f"Created WAD record {wad_id}; loading global assets...")

                    progress("Loading SQL gameplay catalogs...")
                    load_game_data(cur)
                    # Load WAD-global textures (flats + composited wall textures)
                    load_textures(fp, cur, lumps, selected_maps)
                    # Sprite definitions were refreshed; restore caches for
                    # maps that were already present before this import.
                    progress("Refreshing renderer Thing caches for existing maps...")
                    materialize_render_things(cur)
            progress("Global assets committed.")

            # Process each map in its own transaction for clean rollbacks
            selected_index = 0
            for i, L in enumerate(lumps):
                if not _is_map_marker(L["name"]):
                    continue
                marker, by_name = _gather_map_lumps(lumps, i)
                if requested_maps and marker.upper() not in requested_maps:
                    continue

                selected_index += 1
                phase_started = time.perf_counter()
                progress(
                    f"[{selected_index}/{len(selected_maps)}] Loading map {marker}..."
                )
                with conn:
                    with conn.cursor() as cur:
                        map_id = insert_map(cur, wad_id, marker)
                        load_map(fp, cur, map_id, by_name)
                        # commit happens via context manager
                progress(
                    f"[{selected_index}/{len(selected_maps)}] Loaded {marker} "
                    f"as map_id={map_id} in "
                    f"{time.perf_counter() - phase_started:.1f}s."
                )

            # The crossing flags are a cache of line_special_defs, so they
            # are refreshed once every map is in -- both the ones just loaded
            # and any that were already there when the catalogue changed.
            with conn:
                with conn.cursor() as cur:
                    progress("Stamping line special flags...")
                    stamp_line_specials(cur)
                    progress("Refreshing derived geometry...")
                    refresh_derived(cur)

            # Leave the optimizer with fresh statistics. Without them the
            # game tic plans badly -- measured at 8.4 ms per tic against
            # 2.5 ms after ANALYZE -- and the tic runs 35 times a second, so
            # the renderer loses that time. Costs about 0.1 s here.
            progress("Refreshing optimizer statistics...")
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("ANALYZE")
            conn.autocommit = False

            progress(
                f"Import complete: {selected_index} maps loaded in "
                f"{time.perf_counter() - total_started:.1f}s."
            )

        finally:
            conn.close()


if __name__ == "__main__":
    main()
