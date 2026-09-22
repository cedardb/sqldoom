
CREATE OR REPLACE FUNCTION doom_light_index(
  p_sector_light double precision, p_extra integer, p_attenuation integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
SELECT GREATEST(0, LEAST(31,
  (15 - LEAST(15, GREATEST(0, FLOOR(p_sector_light / 16.0)::int + p_extra))) * 4
  - p_attenuation))
$$;

-- scalelight, for walls and sprites: attenuation by 1/depth.
CREATE OR REPLACE FUNCTION doom_light_scale(p_depth double precision)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
SELECT FLOOR(LEAST(47.0, GREATEST(0.0, 2560.0 / NULLIF(p_depth, 0.0))) / 2.0)::int
$$;

-- zlight, for planes, which vanilla indexes by a distance step instead.
CREATE OR REPLACE FUNCTION doom_light_zdepth(p_depth double precision)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
SELECT FLOOR(80.0 / (LEAST(127, FLOOR(p_depth / 16.0)::int) + 1))::int
$$;
