-- ============================================================
-- RabuShinAIGM Rules Build 6.8
-- Hidden five-second AI GM input-idle timeout
--
-- Preserves the absolute visible 30-second typing turn. Each real
-- input event refreshes last_input_at only. If the owner produces no
-- input for five seconds, polling clients clean the stale lease and
-- the AI Game Master composer reopens for the campaign.
-- ============================================================

BEGIN;

ALTER TABLE public.discord_campaign_gm_turn_lock
    ADD COLUMN IF NOT EXISTS last_input_at TIMESTAMPTZ;

UPDATE public.discord_campaign_gm_turn_lock AS turn_lock
SET last_input_at = COALESCE(turn_lock.last_input_at, turn_lock.updated_at, NOW())
WHERE turn_lock.last_input_at IS NULL;

ALTER TABLE public.discord_campaign_gm_turn_lock
    ALTER COLUMN last_input_at SET DEFAULT NOW(),
    ALTER COLUMN last_input_at SET NOT NULL;

DROP FUNCTION IF EXISTS public.discord_get_gm_turn_state(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_gm_turn_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_lock public.discord_campaign_gm_turn_lock%ROWTYPE;
    v_remaining INTEGER := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members AS cm
        WHERE cm.campaign_id = p_campaign_id
          AND cm.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    DELETE FROM public.discord_campaign_gm_turn_lock AS turn_lock
    WHERE turn_lock.campaign_id = p_campaign_id
      AND (
          (turn_lock.processing = FALSE AND (
              turn_lock.expires_at <= NOW()
              OR turn_lock.last_input_at <= NOW() - INTERVAL '5 seconds'
          ))
          OR
          (turn_lock.processing = TRUE AND COALESCE(turn_lock.processing_started_at, turn_lock.updated_at) <= NOW() - INTERVAL '10 minutes')
      );

    SELECT turn_lock.*
    INTO v_lock
    FROM public.discord_campaign_gm_turn_lock AS turn_lock
    WHERE turn_lock.campaign_id = p_campaign_id;

    IF v_lock.campaign_id IS NULL THEN
        RETURN jsonb_build_object(
            'active', FALSE,
            'processing', FALSE,
            'is_owner', FALSE,
            'owner_player_id', NULL,
            'owner_name', '',
            'lock_token', NULL,
            'remaining_seconds', 0,
            'expires_at', NULL
        );
    END IF;

    IF NOT v_lock.processing THEN
        v_remaining := GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_lock.expires_at - NOW())))::INTEGER);
    END IF;

    RETURN jsonb_build_object(
        'active', TRUE,
        'processing', v_lock.processing,
        'is_owner', v_lock.player_id = p_player_id,
        'owner_player_id', v_lock.player_id,
        'owner_name', v_lock.player_name,
        'lock_token', CASE WHEN v_lock.player_id = p_player_id THEN v_lock.lock_token ELSE NULL END,
        'remaining_seconds', v_remaining,
        'expires_at', v_lock.expires_at
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_acquire_gm_turn(UUID, UUID, TEXT);
CREATE OR REPLACE FUNCTION public.discord_acquire_gm_turn(
    p_player_id UUID,
    p_campaign_id UUID,
    p_player_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_lock public.discord_campaign_gm_turn_lock%ROWTYPE;
    v_remaining INTEGER := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members AS cm
        WHERE cm.campaign_id = p_campaign_id
          AND cm.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    DELETE FROM public.discord_campaign_gm_turn_lock AS turn_lock
    WHERE turn_lock.campaign_id = p_campaign_id
      AND (
          (turn_lock.processing = FALSE AND (
              turn_lock.expires_at <= NOW()
              OR turn_lock.last_input_at <= NOW() - INTERVAL '5 seconds'
          ))
          OR
          (turn_lock.processing = TRUE AND COALESCE(turn_lock.processing_started_at, turn_lock.updated_at) <= NOW() - INTERVAL '10 minutes')
      );

    SELECT turn_lock.*
    INTO v_lock
    FROM public.discord_campaign_gm_turn_lock AS turn_lock
    WHERE turn_lock.campaign_id = p_campaign_id
    FOR UPDATE;

    IF v_lock.campaign_id IS NULL THEN
        INSERT INTO public.discord_campaign_gm_turn_lock(
            campaign_id, player_id, player_name, lock_token,
            acquired_at, expires_at, processing, processing_started_at,
            last_input_at, updated_at
        )
        VALUES(
            p_campaign_id,
            p_player_id,
            LEFT(TRIM(COALESCE(p_player_name, 'Player')), 120),
            gen_random_uuid(),
            NOW(),
            NOW() + INTERVAL '30 seconds',
            FALSE,
            NULL,
            NOW(),
            NOW()
        )
        ON CONFLICT ON CONSTRAINT discord_campaign_gm_turn_lock_pkey DO NOTHING
        RETURNING * INTO v_lock;

        IF v_lock.campaign_id IS NULL THEN
            SELECT turn_lock.*
            INTO v_lock
            FROM public.discord_campaign_gm_turn_lock AS turn_lock
            WHERE turn_lock.campaign_id = p_campaign_id;
        END IF;
    END IF;

    IF NOT v_lock.processing THEN
        v_remaining := GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_lock.expires_at - NOW())))::INTEGER);
    END IF;

    RETURN jsonb_build_object(
        'active', TRUE,
        'processing', v_lock.processing,
        'is_owner', v_lock.player_id = p_player_id,
        'owner_player_id', v_lock.player_id,
        'owner_name', v_lock.player_name,
        'lock_token', CASE WHEN v_lock.player_id = p_player_id THEN v_lock.lock_token ELSE NULL END,
        'remaining_seconds', v_remaining,
        'expires_at', v_lock.expires_at
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_touch_gm_turn_input(UUID, UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_touch_gm_turn_input(
    p_player_id UUID,
    p_campaign_id UUID,
    p_lock_token UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_lock public.discord_campaign_gm_turn_lock%ROWTYPE;
    v_remaining INTEGER := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members AS cm
        WHERE cm.campaign_id = p_campaign_id
          AND cm.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    DELETE FROM public.discord_campaign_gm_turn_lock AS turn_lock
    WHERE turn_lock.campaign_id = p_campaign_id
      AND turn_lock.processing = FALSE
      AND (
          turn_lock.expires_at <= NOW()
          OR turn_lock.last_input_at <= NOW() - INTERVAL '5 seconds'
      );

    UPDATE public.discord_campaign_gm_turn_lock AS turn_lock
    SET last_input_at = NOW(),
        updated_at = NOW()
    WHERE turn_lock.campaign_id = p_campaign_id
      AND turn_lock.player_id = p_player_id
      AND turn_lock.lock_token = p_lock_token
      AND turn_lock.processing = FALSE
      AND turn_lock.expires_at > NOW()
    RETURNING * INTO v_lock;

    IF v_lock.campaign_id IS NULL THEN
        RAISE EXCEPTION 'Your five-second AI Game Master input window expired or is owned by another player.';
    END IF;

    v_remaining := GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_lock.expires_at - NOW())))::INTEGER);
    RETURN jsonb_build_object(
        'active', TRUE,
        'processing', FALSE,
        'is_owner', TRUE,
        'owner_player_id', v_lock.player_id,
        'owner_name', v_lock.player_name,
        'lock_token', v_lock.lock_token,
        'remaining_seconds', v_remaining,
        'expires_at', v_lock.expires_at
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_begin_gm_processing(UUID, UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_begin_gm_processing(
    p_player_id UUID,
    p_campaign_id UUID,
    p_lock_token UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_lock public.discord_campaign_gm_turn_lock%ROWTYPE;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members AS cm
        WHERE cm.campaign_id = p_campaign_id
          AND cm.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    DELETE FROM public.discord_campaign_gm_turn_lock AS turn_lock
    WHERE turn_lock.campaign_id = p_campaign_id
      AND turn_lock.processing = FALSE
      AND (
          turn_lock.expires_at <= NOW()
          OR turn_lock.last_input_at <= NOW() - INTERVAL '5 seconds'
      );

    UPDATE public.discord_campaign_gm_turn_lock AS turn_lock
    SET processing = TRUE,
        processing_started_at = NOW(),
        expires_at = NOW() + INTERVAL '10 minutes',
        updated_at = NOW()
    WHERE turn_lock.campaign_id = p_campaign_id
      AND turn_lock.player_id = p_player_id
      AND turn_lock.lock_token = p_lock_token
      AND turn_lock.processing = FALSE
      AND turn_lock.expires_at > NOW()
    RETURNING * INTO v_lock;

    IF v_lock.campaign_id IS NULL THEN
        RAISE EXCEPTION 'Your 30-second AI Game Master turn or five-second input window expired, or the turn is owned by another player.';
    END IF;

    RETURN jsonb_build_object(
        'active', TRUE,
        'processing', TRUE,
        'is_owner', TRUE,
        'owner_player_id', v_lock.player_id,
        'owner_name', v_lock.player_name,
        'lock_token', v_lock.lock_token,
        'remaining_seconds', 0,
        'expires_at', v_lock.expires_at
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_gm_turn_state(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_acquire_gm_turn(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_touch_gm_turn_input(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_begin_gm_processing(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_gm_turn_state(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_acquire_gm_turn(UUID, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_touch_gm_turn_input(UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_begin_gm_processing(UUID, UUID, UUID) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
