-- ============================================================
-- RabuShinAIGM Build 6.23.1
-- Migration 61 - Gender Bootstrap / discord_get_character repair
--
-- Root cause:
--   Migration 60 added discord_characters.gender and saved it correctly,
--   but discord_get_character(uuid,uuid) still returned its older fixed
--   table signature without the gender column. The ASP.NET client model
--   therefore received Gender="" after every bootstrap and reopened the
--   required-gender prompt indefinitely.
--
-- This migration changes no saved gender values.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.discord_get_character(UUID, UUID);

CREATE OR REPLACE FUNCTION public.discord_get_character(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,
    campaign_id UUID,
    gender TEXT,
    character_name TEXT,
    species_name TEXT,
    class_name TEXT,
    background_name TEXT,
    alignment TEXT,
    level INTEGER,
    experience INTEGER,
    current_hp INTEGER,
    max_hp INTEGER,
    armor_class INTEGER,
    strength INTEGER,
    dexterity INTEGER,
    constitution INTEGER,
    intelligence INTEGER,
    wisdom INTEGER,
    charisma INTEGER,
    initiative INTEGER,
    passive_perception INTEGER,
    proficiency_bonus INTEGER,
    speed INTEGER,
    size_name TEXT,
    gold NUMERIC,
    equipment_complete BOOLEAN,
    spells_complete BOOLEAN,
    character_data JSONB
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        c.character_id,
        c.campaign_id,
        c.gender,
        c.character_name,
        c.species_name,
        c.class_name,
        c.background_name,
        c.alignment,
        c.level,
        c.experience,
        c.current_hp,
        c.max_hp,
        c.armor_class,
        c.strength,
        c.dexterity,
        c.constitution,
        c.intelligence,
        c.wisdom,
        c.charisma,
        c.initiative,
        c.passive_perception,
        c.proficiency_bonus,
        c.speed,
        c.size_name,
        c.gold,
        c.equipment_complete,
        c.spells_complete,
        c.character_data
    FROM public.discord_characters c
    INNER JOIN public.discord_campaign_members m
        ON m.campaign_id = c.campaign_id
       AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id
      AND c.campaign_id = p_campaign_id
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.discord_get_character(UUID, UUID)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discord_get_character(UUID, UUID)
TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
