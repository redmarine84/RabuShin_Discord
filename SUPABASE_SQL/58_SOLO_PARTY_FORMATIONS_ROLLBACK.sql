BEGIN;
DROP FUNCTION IF EXISTS public.discord_gm_get_solo_formation(UUID);
DROP FUNCTION IF EXISTS public.discord_set_solo_formation(UUID,UUID,TEXT,JSONB);
DROP FUNCTION IF EXISTS public.discord_get_solo_formation(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_formation_builtin_offset(TEXT,INTEGER);
DROP TABLE IF EXISTS public.discord_solo_formation_settings;
COMMIT;
