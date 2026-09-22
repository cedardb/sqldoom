SELECT ma.name,ma.midi_data,ma.audio_data,ma.audio_format
FROM map_music mm
JOIN music_assets ma ON ma.name=mm.music_name
WHERE mm.map_id=$1;
