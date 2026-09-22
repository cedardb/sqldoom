"""Audio devices: SQL-owned sound and music assets through pygame's mixer.

SQL decides what plays, how loud and where (sound_events, sound_loops,
map_music); this module only owns channels.
"""
import io

import pygame

import doom_sql as sql


def load_sound_bank(cur):
    """Load the SQL-owned WAV assets through SDL_mixer."""
    if pygame.mixer.get_init() is None:
        return {}
    return {
        name: pygame.mixer.Sound(file=io.BytesIO(bytes(wav_data)))
        for name, wav_data in sql.fetch_sound_assets(cur)
    }


def play_sound_events(events, bank):
    """Submit SQL-positioned events to pygame's audio channels."""
    for _event_id, sound_name, volume, pan in events:
        sound = bank.get(sound_name)
        volume = max(0.0, min(1.0, float(volume)))
        if sound is None or volume <= 0.0:
            continue
        pan = max(-1.0, min(1.0, float(pan)))
        # Channels 0..7 are reserved for stable loops. One-shots round-robin
        # over 8..23, so a busy gunshot can replace another transient sound
        # but can never tear down a door/lift/chainsaw loop.
        channel_index = getattr(play_sound_events, "next_channel", 8)
        channel = pygame.mixer.Channel(channel_index)
        play_sound_events.next_channel = 8 + ((channel_index - 7) % 16)
        channel.set_volume(
            volume * min(1.0, 1.0 - pan),
            volume * min(1.0, 1.0 + pan),
        )
        channel.play(sound)


def sync_sound_loops(loops, bank, active):
    """Reconcile reserved pygame channels to SQL's active-loop set."""
    if pygame.mixer.get_init() is None:
        return
    wanted = {
        loop_key: (sound_name, float(volume), float(pan))
        for loop_key, sound_name, volume, pan in loops
    }
    for loop_key in list(active):
        if loop_key not in wanted:
            active.pop(loop_key)[0].stop()

    used = {entry[0] for entry in active.values()}
    available = [pygame.mixer.Channel(i) for i in range(8)
                 if pygame.mixer.Channel(i) not in used]
    for loop_key, (sound_name, volume, pan) in wanted.items():
        sound = bank.get(sound_name)
        if sound is None:
            continue
        entry = active.get(loop_key)
        if entry is None:
            if not available:
                continue
            channel = available.pop(0)
            active[loop_key] = (channel, sound_name)
            channel.play(sound, loops=-1)
        else:
            channel, previous_name = entry
            if previous_name != sound_name:
                channel.play(sound, loops=-1)
                active[loop_key] = (channel, sound_name)
        volume = max(0.0, min(1.0, volume))
        pan = max(-1.0, min(1.0, pan))
        channel.set_volume(
            volume * min(1.0, 1.0 - pan),
            volume * min(1.0, 1.0 + pan),
        )


def start_stage_music(cur, map_id):
    """Start SQL's selected stage track from an in-memory MIDI stream."""
    if pygame.mixer.get_init() is None:
        return None
    row = sql.fetch_stage_music(cur, map_id)
    pygame.mixer.music.stop()
    if row is None:
        return None
    _name, midi_data = row[0], row[1]
    stream = io.BytesIO(bytes(midi_data))
    try:
        pygame.mixer.music.load(stream, "mid")
        pygame.mixer.music.set_volume(0.55)
        pygame.mixer.music.play(-1)
    except pygame.error as exc:
        print(f"Music decoder unavailable: {exc}")
        return None
    return stream
