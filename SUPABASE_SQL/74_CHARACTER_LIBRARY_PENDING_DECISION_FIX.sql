-- ============================================================
-- RabuShinAIGM Build 6.30.12.3
-- Migration 74 - Character Library Pending Decision Ambiguity Fix
--
-- Fixes PostgreSQL 42702:
-- column reference "character_id" is ambiguous
-- ============================================================

CREATE OR REPLACE FUNCTION public.discord_resolve_pending_character(
    p_player_id UUID,
    p_character_id UUID,
    p_action TEXT,
    p_replace_character_id UUID DEFAULT NULL
) RETURNS TABLE(
    character_id UUID,
    character_status TEXT,
    library_slot INTEGER,
    was_deleted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_action TEXT := LOWER(TRIM(COALESCE(p_action,'')));
    v_slot INTEGER;
BEGIN
    PERFORM 1
    FROM public.discord_players AS p
    WHERE p.player_id = p_player_id
    FOR UPDATE;

    PERFORM 1
    FROM public.discord_characters AS c
    WHERE c.character_id = p_character_id
      AND c.owner_player_id = p_player_id
      AND c.campaign_id IS NULL
      AND c.character_status = 'pending_storage'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'This character is not waiting for a Store/Delete decision.';
    END IF;

    IF v_action = 'delete' THEN
        DELETE FROM public.discord_characters AS c
        WHERE c.character_id = p_character_id;

        RETURN QUERY
        SELECT
            p_character_id,
            'deleted'::TEXT,
            NULL::INTEGER,
            TRUE;

        RETURN;
    END IF;

    IF v_action <> 'store' THEN
        RAISE EXCEPTION 'Choose Store Character or Delete Character.';
    END IF;

    SELECT gs
    INTO v_slot
    FROM generate_series(1,10) AS gs
    WHERE NOT EXISTS(
        SELECT 1
        FROM public.discord_characters AS c
        WHERE c.owner_player_id = p_player_id
          AND c.library_slot = gs
    )
    ORDER BY gs
    LIMIT 1;

    IF v_slot IS NULL AND p_replace_character_id IS NOT NULL THEN

        SELECT c.library_slot
        INTO v_slot
        FROM public.discord_characters AS c
        WHERE c.character_id = p_replace_character_id
          AND c.owner_player_id = p_player_id
          AND c.library_slot IS NOT NULL
          AND c.campaign_id IS NULL
          AND c.character_status = 'available'
        FOR UPDATE;

        IF v_slot IS NULL THEN
            RAISE EXCEPTION 'The replacement character must be an available Character Library character.';
        END IF;

        DELETE FROM public.discord_characters AS c
        WHERE c.character_id = p_replace_character_id
          AND c.owner_player_id = p_player_id
          AND c.campaign_id IS NULL
          AND c.character_status = 'available';
    END IF;

    IF v_slot IS NULL THEN
        RAISE EXCEPTION 'CHARACTER_LIBRARY_FULL: Delete an available stored character or delete the character you are trying to store.';
    END IF;

    UPDATE public.discord_characters AS c
    SET library_slot = v_slot,
        character_status = 'available',
        pending_reason = '',
        updated_at = NOW()
    WHERE c.character_id = p_character_id;

    RETURN QUERY
    SELECT
        p_character_id,
        'available'::TEXT,
        v_slot,
        FALSE;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_resolve_pending_character(UUID,UUID,TEXT,UUID)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_resolve_pending_character(UUID,UUID,TEXT,UUID)
TO service_role;