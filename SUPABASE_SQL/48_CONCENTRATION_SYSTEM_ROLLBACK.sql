-- ============================================================
-- RabuShinAIGM Rules Build 6.19.3
-- Migration 48 ROLLBACK - Concentration System
-- Removes only Build 6.19.3 database objects.
-- ============================================================

BEGIN;

DROP TRIGGER IF EXISTS trg_discord_concentration_condition
ON public.discord_combat_conditions;

DROP TRIGGER IF EXISTS trg_discord_concentration_character
ON public.discord_characters;

DROP FUNCTION IF EXISTS public.discord_end_concentration_on_condition();
DROP FUNCTION IF EXISTS public.discord_enforce_concentration_on_character_update();
DROP FUNCTION IF EXISTS public.discord_gm_get_concentration_state(UUID);
DROP FUNCTION IF EXISTS public.discord_get_concentration_state(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_gm_end_concentration(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_start_concentration(UUID,TEXT,TEXT,INTEGER,TEXT);
DROP FUNCTION IF EXISTS public.discord_concentration_save_modifier(UUID);
DROP FUNCTION IF EXISTS public.discord_concentration_is_incapacitated(UUID);

DROP TABLE IF EXISTS public.discord_character_concentration;

COMMIT;
