-- RabuShinAIGM Discord - Character alignment gauge, Tortle/half-race feature metadata,
-- racial trait persistence, and editable character details.
-- Run AFTER 14_LIVE_CHAT_GM_TURN_LOCK.sql.

BEGIN;

ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS secondary_heritage TEXT NOT NULL DEFAULT '';
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS appearance TEXT NOT NULL DEFAULT '';
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS personality TEXT NOT NULL DEFAULT '';
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS backstory TEXT NOT NULL DEFAULT '';
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS notes TEXT NOT NULL DEFAULT '';
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS racial_traits JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS alignment_deed_balance INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS alignment_good_deeds INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS alignment_evil_deeds INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS alignment_changed_at TIMESTAMPTZ;

-- Recover details from the JSON snapshot for existing characters where possible.
UPDATE public.discord_characters
SET appearance = COALESCE(NULLIF(appearance, ''), NULLIF(character_data->>'appearance',''), NULLIF(character_data #>> '{snapshot,Appearance}',''), ''),
    personality = COALESCE(NULLIF(personality, ''), NULLIF(character_data->>'personality',''), NULLIF(character_data #>> '{snapshot,Personality}',''), ''),
    backstory = COALESCE(NULLIF(backstory, ''), NULLIF(character_data->>'backstory',''), NULLIF(character_data #>> '{snapshot,Backstory}',''), ''),
    notes = COALESCE(NULLIF(notes, ''), NULLIF(character_data->>'notes',''), NULLIF(character_data #>> '{snapshot,Notes}',''), ''),
    secondary_heritage = COALESCE(NULLIF(secondary_heritage, ''), NULLIF(character_data #>> '{features,secondaryHeritage}',''), '');

-- Normalize the app's old "Neutral" label to the requested alignment ladder name.
UPDATE public.discord_characters
SET alignment = 'True Neutral'
WHERE LOWER(TRIM(alignment)) IN ('neutral', 'true neutral');

CREATE TABLE IF NOT EXISTS public.discord_alignment_events
(
    alignment_event_id BIGSERIAL PRIMARY KEY,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    direction TEXT NOT NULL CHECK (direction IN ('good','evil')),
    reason TEXT NOT NULL DEFAULT '',
    previous_alignment TEXT NOT NULL,
    new_alignment TEXT NOT NULL,
    balance_after INTEGER NOT NULL,
    changed_alignment BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_discord_alignment_events_character ON public.discord_alignment_events(character_id, created_at DESC);
ALTER TABLE public.discord_alignment_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_alignment_events FROM anon, authenticated;
GRANT ALL ON public.discord_alignment_events TO service_role;

DROP FUNCTION IF EXISTS public.discord_set_character_features(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB);
CREATE OR REPLACE FUNCTION public.discord_set_character_features(
    p_player_id UUID,
    p_campaign_id UUID,
    p_character_id UUID,
    p_secondary_heritage TEXT,
    p_appearance TEXT,
    p_personality TEXT,
    p_backstory TEXT,
    p_notes TEXT,
    p_racial_traits JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_characters
        WHERE character_id = p_character_id AND campaign_id = p_campaign_id AND player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'Character not found or access denied.';
    END IF;

    UPDATE public.discord_characters
    SET secondary_heritage = COALESCE(TRIM(p_secondary_heritage), ''),
        appearance = COALESCE(p_appearance, ''),
        personality = COALESCE(p_personality, ''),
        backstory = COALESCE(p_backstory, ''),
        notes = COALESCE(p_notes, ''),
        racial_traits = COALESCE(p_racial_traits, '{}'::jsonb),
        character_data = COALESCE(character_data, '{}'::jsonb) || jsonb_build_object(
            'appearance', COALESCE(p_appearance, ''),
            'personality', COALESCE(p_personality, ''),
            'backstory', COALESCE(p_backstory, ''),
            'notes', COALESCE(p_notes, ''),
            'features', COALESCE(p_racial_traits, '{}'::jsonb)
        ),
        updated_at = NOW()
    WHERE character_id = p_character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_character_features(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_character_features(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID,
    background_name TEXT,
    alignment TEXT,
    alignment_deed_balance INTEGER,
    alignment_good_deeds INTEGER,
    alignment_evil_deeds INTEGER,
    secondary_heritage TEXT,
    appearance TEXT,
    personality TEXT,
    backstory TEXT,
    notes TEXT,
    racial_traits JSONB)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.character_id, c.background_name, c.alignment,
           c.alignment_deed_balance, c.alignment_good_deeds, c.alignment_evil_deeds,
           c.secondary_heritage, c.appearance, c.personality, c.backstory, c.notes, c.racial_traits
    FROM public.discord_characters c
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id
    LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.discord_update_character_details(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.discord_update_character_details(
    p_player_id UUID,
    p_campaign_id UUID,
    p_background TEXT,
    p_appearance TEXT,
    p_personality TEXT,
    p_backstory TEXT,
    p_notes TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_characters
        WHERE player_id = p_player_id AND campaign_id = p_campaign_id
    ) THEN
        RAISE EXCEPTION 'Character not found or access denied.';
    END IF;

    UPDATE public.discord_characters
    SET background_name = LEFT(COALESCE(TRIM(p_background), ''), 120),
        appearance = LEFT(COALESCE(p_appearance, ''), 8000),
        personality = LEFT(COALESCE(p_personality, ''), 8000),
        backstory = LEFT(COALESCE(p_backstory, ''), 12000),
        notes = LEFT(COALESCE(p_notes, ''), 12000),
        character_data = COALESCE(character_data, '{}'::jsonb) || jsonb_build_object(
            'background_name', LEFT(COALESCE(TRIM(p_background), ''), 120),
            'appearance', LEFT(COALESCE(p_appearance, ''), 8000),
            'personality', LEFT(COALESCE(p_personality, ''), 8000),
            'backstory', LEFT(COALESCE(p_backstory, ''), 12000),
            'notes', LEFT(COALESCE(p_notes, ''), 12000)
        ),
        updated_at = NOW()
    WHERE player_id = p_player_id AND campaign_id = p_campaign_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_record_alignment_deed(UUID, UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_record_alignment_deed(
    p_character_id UUID,
    p_campaign_id UUID,
    p_direction TEXT,
    p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_direction TEXT := LOWER(TRIM(COALESCE(p_direction, '')));
    v_alignment TEXT;
    v_previous TEXT;
    v_new TEXT;
    v_balance INTEGER;
    v_good INTEGER;
    v_evil INTEGER;
    v_index INTEGER;
    v_changed BOOLEAN := FALSE;
    v_ladder TEXT[] := ARRAY[
        'Lawful Good','Neutral Good','Chaotic Good',
        'Lawful Neutral','True Neutral','Chaotic Neutral',
        'Lawful Evil','Neutral Evil','Chaotic Evil'
    ];
BEGIN
    IF v_direction NOT IN ('good','evil') THEN
        RAISE EXCEPTION 'Alignment direction must be good or evil.';
    END IF;

    SELECT c.alignment, c.alignment_deed_balance, c.alignment_good_deeds, c.alignment_evil_deeds
    INTO v_alignment, v_balance, v_good, v_evil
    FROM public.discord_characters c
    WHERE c.character_id = p_character_id AND c.campaign_id = p_campaign_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Character not found.'; END IF;

    v_index := CASE LOWER(TRIM(COALESCE(v_alignment,'')))
        WHEN 'lawful good' THEN 1 WHEN 'neutral good' THEN 2 WHEN 'chaotic good' THEN 3
        WHEN 'lawful neutral' THEN 4 WHEN 'neutral' THEN 5 WHEN 'true neutral' THEN 5 WHEN 'chaotic neutral' THEN 6
        WHEN 'lawful evil' THEN 7 WHEN 'neutral evil' THEN 8 WHEN 'chaotic evil' THEN 9
        ELSE 5 END;
    v_previous := v_ladder[v_index];

    IF v_direction = 'good' THEN
        v_balance := v_balance - 1;
        v_good := v_good + 1;
    ELSE
        v_balance := v_balance + 1;
        v_evil := v_evil + 1;
    END IF;

    v_new := v_previous;
    IF v_balance <= -9 THEN
        v_index := GREATEST(1, v_index - 1);
        v_new := v_ladder[v_index];
        v_balance := 0;
        v_changed := v_new <> v_previous;
    ELSIF v_balance >= 9 THEN
        v_index := LEAST(9, v_index + 1);
        v_new := v_ladder[v_index];
        v_balance := 0;
        v_changed := v_new <> v_previous;
    END IF;

    UPDATE public.discord_characters
    SET alignment = v_new,
        alignment_deed_balance = v_balance,
        alignment_good_deeds = v_good,
        alignment_evil_deeds = v_evil,
        alignment_changed_at = CASE WHEN v_changed THEN NOW() ELSE alignment_changed_at END,
        character_data = COALESCE(character_data, '{}'::jsonb) || jsonb_build_object(
            'alignment', v_new,
            'alignmentGauge', jsonb_build_object('balance', v_balance, 'goodDeeds', v_good, 'evilDeeds', v_evil)
        ),
        updated_at = NOW()
    WHERE character_id = p_character_id;

    INSERT INTO public.discord_alignment_events(
        campaign_id, character_id, direction, reason, previous_alignment, new_alignment, balance_after, changed_alignment)
    VALUES (
        p_campaign_id, p_character_id, v_direction, LEFT(COALESCE(p_reason,''), 500),
        v_previous, v_new, v_balance, v_changed);

    RETURN jsonb_build_object(
        'alignment', v_new,
        'alignmentDeedBalance', v_balance,
        'goodDeeds', v_good,
        'evilDeeds', v_evil,
        'changed', v_changed,
        'previousAlignment', v_previous
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_set_character_features(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_get_character_features(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_update_character_details(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_record_alignment_deed(UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discord_set_character_features(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_character_features(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_update_character_details(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_record_alignment_deed(UUID, UUID, TEXT, TEXT) TO service_role;

COMMIT;
