"""Render Doom's MIDI music to compressed audio at import time."""
import ctypes
import os
import shutil
import subprocess
import tempfile

# Ubuntu/Debian ship these with fluidsynth's runtime; the first that exists
# wins. TimGM6mb is the smaller of the two and quite close to the FM-ish
# character of the original.
SOUNDFONTS = (
    "/usr/share/sounds/sf2/TimGM6mb.sf2",
    "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2",
    "/usr/share/soundfonts/FluidR3_GM.sf2",
)

SAMPLE_RATE = 22050.0
GAIN = 0.6
# Vorbis quality 1 at 22 kHz mono is about 110 kbit/s: a Doom track lands
# around 200-300 KB, so the whole soundtrack is under 10 MB.
VORBIS_QUALITY = "1"
AUDIO_FORMAT = "ogg"

FLUID_PLAYER_PLAYING = 1
_MAX_BLOCKS = 200000  # ~10 minutes at 64 samples a block; a stuck loop cannot run away

_PROTOTYPES = (
    ("new_fluid_settings", ctypes.c_void_p, []),
    ("new_fluid_synth", ctypes.c_void_p, [ctypes.c_void_p]),
    ("new_fluid_player", ctypes.c_void_p, [ctypes.c_void_p]),
    ("new_fluid_file_renderer", ctypes.c_void_p, [ctypes.c_void_p]),
    ("fluid_synth_sfload", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]),
    ("fluid_player_add_mem", ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]),
    ("fluid_player_play", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_player_get_status", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_file_renderer_process_block", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_settings_setstr", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
    ("fluid_settings_setnum", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_double]),
    ("fluid_settings_setint", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]),
    ("delete_fluid_file_renderer", None, [ctypes.c_void_p]),
    ("delete_fluid_player", None, [ctypes.c_void_p]),
    ("delete_fluid_synth", None, [ctypes.c_void_p]),
    ("delete_fluid_settings", None, [ctypes.c_void_p]),
)


def _load_library():
    for name in ("libfluidsynth.so.3", "libfluidsynth.so.2", "libfluidsynth.so"):
        try:
            lib = ctypes.CDLL(name)
        except OSError:
            continue
        try:
            for fn, restype, argtypes in _PROTOTYPES:
                func = getattr(lib, fn)
                func.restype = restype
                func.argtypes = argtypes
        except AttributeError:
            continue
        return lib
    return None


def soundfont():
    for path in SOUNDFONTS:
        if os.path.isfile(path):
            return path
    return None


def unavailable_reason():
    """Why rendering cannot run, or None when it can."""
    if _load_library() is None:
        return "libfluidsynth not found"
    if soundfont() is None:
        return "no General MIDI soundfont installed"
    if shutil.which("ffmpeg") is None:
        return "ffmpeg not found"
    return None


def _render_wav(lib, midi, sf2, wav_path):
    settings = lib.new_fluid_settings()
    synth = player = renderer = None
    try:
        lib.fluid_settings_setstr(settings, b"audio.file.name", wav_path.encode())
        lib.fluid_settings_setstr(settings, b"audio.file.type", b"wav")
        # Drive the clock off the samples produced, not the wall clock, or the
        # render takes as long as the track does.
        lib.fluid_settings_setstr(settings, b"player.timing-source", b"sample")
        lib.fluid_settings_setint(settings, b"synth.lock-memory", 0)
        lib.fluid_settings_setnum(settings, b"synth.sample-rate", SAMPLE_RATE)
        lib.fluid_settings_setint(settings, b"synth.audio-channels", 1)
        lib.fluid_settings_setnum(settings, b"synth.gain", GAIN)
        synth = lib.new_fluid_synth(settings)
        if not synth or lib.fluid_synth_sfload(synth, sf2.encode(), 1) < 0:
            return False
        player = lib.new_fluid_player(synth)
        if not player:
            return False
        buf = ctypes.create_string_buffer(midi, len(midi))
        if lib.fluid_player_add_mem(player, buf, len(midi)) != 0:
            return False
        lib.fluid_player_play(player)
        renderer = lib.new_fluid_file_renderer(synth)
        if not renderer:
            return False
        blocks = 0
        while lib.fluid_player_get_status(player) == FLUID_PLAYER_PLAYING:
            if lib.fluid_file_renderer_process_block(renderer) != 0:
                break
            blocks += 1
            if blocks >= _MAX_BLOCKS:
                break
        return blocks > 0
    finally:
        if renderer:
            lib.delete_fluid_file_renderer(renderer)
        if player:
            lib.delete_fluid_player(player)
        if synth:
            lib.delete_fluid_synth(synth)
        lib.delete_fluid_settings(settings)


def render(midi):
    """MIDI bytes -> Ogg Vorbis bytes, or None when it could not be rendered."""
    lib = _load_library()
    sf2 = soundfont()
    if lib is None or sf2 is None or shutil.which("ffmpeg") is None:
        return None
    with tempfile.TemporaryDirectory(prefix="doom-music-") as tmp:
        wav = os.path.join(tmp, "track.wav")
        ogg = os.path.join(tmp, "track.ogg")
        try:
            if not _render_wav(lib, midi, sf2, wav):
                return None
            if not os.path.isfile(wav) or os.path.getsize(wav) < 64:
                return None
            result = subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-i", wav, "-c:a", "libvorbis", "-q:a", VORBIS_QUALITY,
                 "-ac", "1", ogg],
                capture_output=True, timeout=300,
            )
            if result.returncode != 0 or not os.path.isfile(ogg):
                return None
            with open(ogg, "rb") as handle:
                return handle.read()
        except (OSError, subprocess.SubprocessError):
            return None
