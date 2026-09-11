-- ============================================================
-- RabuShinAIGM Build 6.23.1
-- Migration 60 - Character Gender
--
-- Existing characters intentionally remain NULL so the client can
-- require a one-time selection when that character next becomes active.
-- ============================================================

BEGIN;

ALTER TABLE public.discord_characters
    ADD COLUMN IF NOT EXISTS gender TEXT NULL;

ALTER TABLE public.discord_characters
    DROP CONSTRAINT IF EXISTS ck_discord_characters_gender;

ALTER TABLE public.discord_characters
    ADD CONSTRAINT ck_discord_characters_gender
    CHECK (
        gender IS NULL
        OR gender IN ('Male','Female','Nonbinary','Other')
    );

DROP FUNCTION IF EXISTS public.discord_set_character_gender(UUID,UUID,UUID,TEXT);
CREATE OR REPLACE FUNCTION public.discord_set_character_gender(
    p_player_id UUID,
    p_campaign_id UUID,
    p_character_id UUID,
    p_gender TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_gender TEXT;
    v_character public.discord_characters%ROWTYPE;
    v_can_control BOOLEAN:=FALSE;
BEGIN
    v_gender:=CASE LOWER(TRIM(COALESCE(p_gender,'')))
        WHEN 'male' THEN 'Male'
        WHEN 'female' THEN 'Female'
        WHEN 'nonbinary' THEN 'Nonbinary'
        WHEN 'non-binary' THEN 'Nonbinary'
        WHEN 'non binary' THEN 'Nonbinary'
        WHEN 'other' THEN 'Other'
        ELSE NULL
    END;

    IF v_gender IS NULL THEN
        RAISE EXCEPTION 'Choose Male, Female, Nonbinary, or Other.';
    END IF;

    SELECT c.*
    INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND c.character_id=p_character_id
    LIMIT 1;

    IF v_character.character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found in this campaign.';
    END IF;

    v_can_control:=v_character.player_id=p_player_id;

    IF NOT v_can_control
       AND to_regclass('public.discord_solo_party_characters') IS NOT NULL
    THEN
        SELECT EXISTS(
            SELECT 1
            FROM public.discord_solo_party_characters sp
            WHERE sp.campaign_id=p_campaign_id
              AND sp.character_id=p_character_id
              AND (
                    sp.owner_player_id=p_player_id
                 OR sp.control_player_id=p_player_id
              )
        )
        INTO v_can_control;
    END IF;

    IF NOT COALESCE(v_can_control,FALSE) THEN
        RAISE EXCEPTION 'You cannot change this character.';
    END IF;

    UPDATE public.discord_characters c
    SET gender=v_gender,
        character_data=COALESCE(c.character_data,'{}'::JSONB)
            || jsonb_build_object('gender',v_gender),
        updated_at=NOW()
    WHERE c.character_id=p_character_id
      AND c.campaign_id=p_campaign_id;

    RETURN jsonb_build_object(
        'success',TRUE,
        'characterId',p_character_id,
        'gender',v_gender
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_set_character_gender(UUID,UUID,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_set_character_gender(UUID,UUID,UUID,TEXT)
TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
