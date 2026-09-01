-- RabuShinAIGM Discord - Build 1 Visuals: Character Portraits + Party Viewer
-- Safe upgrade: preserves all existing campaigns, characters, inventory, spells, chat, journals, and API keys.

BEGIN;

ALTER TABLE public.discord_characters
    ADD COLUMN IF NOT EXISTS portrait_path TEXT;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'character-portraits',
    'character-portraits',
    FALSE,
    5242880,
    ARRAY['image/png','image/jpeg','image/webp']::TEXT[]
)
ON CONFLICT (id) DO UPDATE
SET public = FALSE,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP FUNCTION IF EXISTS public.discord_get_party(UUID, UUID);

CREATE OR REPLACE FUNCTION public.discord_get_party(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID, player_id UUID, display_name TEXT, discord_username TEXT,
    character_name TEXT, species_name TEXT, class_name TEXT, background_name TEXT, alignment TEXT,
    level INTEGER, current_hp INTEGER, max_hp INTEGER, armor_class INTEGER,
    strength INTEGER, dexterity INTEGER, constitution INTEGER, intelligence INTEGER, wisdom INTEGER, charisma INTEGER,
    initiative INTEGER, passive_perception INTEGER, proficiency_bonus INTEGER, speed INTEGER,
    portrait_path TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT c.character_id, c.player_id, COALESCE(p.display_name,p.discord_username), p.discord_username,
           c.character_name, c.species_name, c.class_name, c.background_name, c.alignment,
           c.level, c.current_hp, c.max_hp, c.armor_class,
           c.strength, c.dexterity, c.constitution, c.intelligence, c.wisdom, c.charisma,
           c.initiative, c.passive_perception, c.proficiency_bonus, c.speed,
           c.portrait_path
    FROM public.discord_characters c
    INNER JOIN public.discord_players p ON p.player_id = c.player_id
    INNER JOIN public.discord_campaign_members viewer
        ON viewer.campaign_id = c.campaign_id AND viewer.player_id = p_player_id
    WHERE c.campaign_id = p_campaign_id
    ORDER BY c.character_name;
$$;

CREATE OR REPLACE FUNCTION public.discord_set_character_portrait(
    p_player_id UUID,
    p_campaign_id UUID,
    p_portrait_path TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_character_id UUID;
BEGIN
    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    INNER JOIN public.discord_campaign_members m
        ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id
    LIMIT 1;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    UPDATE public.discord_characters
    SET portrait_path = NULLIF(TRIM(COALESCE(p_portrait_path, '')), ''),
        updated_at = NOW()
    WHERE character_id = v_character_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.discord_get_party(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_character_portrait(UUID, UUID, TEXT) TO service_role;

COMMIT;
