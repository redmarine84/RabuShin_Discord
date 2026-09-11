-- ============================================================
-- RabuShinAIGM Build 6.23.1
-- Migration 60 - Character Gender EMERGENCY ROLLBACK
--
-- WARNING: dropping the column removes saved gender values.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.discord_set_character_gender(UUID,UUID,UUID,TEXT);

ALTER TABLE public.discord_characters
    DROP CONSTRAINT IF EXISTS ck_discord_characters_gender;

ALTER TABLE public.discord_characters
    DROP COLUMN IF EXISTS gender;

NOTIFY pgrst,'reload schema';

COMMIT;
