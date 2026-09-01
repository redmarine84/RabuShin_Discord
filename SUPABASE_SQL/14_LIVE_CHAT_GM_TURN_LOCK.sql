-- ============================================================
-- RabuShinAIGM Multiplayer Live Chat + AI GM Turn Lock
-- Build after Visuals 5.1
--
-- Adds a server-authoritative 30-second typing lease for the
-- shared AI Game Master conversation. Campaign Chat remains
-- unlocked but is live-polled by the client.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_campaign_gm_turn_lock
(
    campaign_id UUID PRIMARY KEY REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    player_name TEXT NOT NULL DEFAULT '',
    lock_token UUID NOT NULL DEFAULT gen_random_uuid(),
    acquired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    processing BOOLEAN NOT NULL DEFAULT FALSE,
    processing_started_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_discord_gm_turn_lock_player
    ON public.discord_campaign_gm_turn_lock(player_id);

ALTER TABLE public.discord_campaign_gm_turn_lock ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_campaign_gm_turn_lock FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_campaign_gm_turn_lock TO service_role;

-- Return the current authoritative lock state. Expired typing
-- leases and abandoned processing leases are cleaned here.
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
        FROM public.discord_campaign_members cm
        WHERE cm.campaign_id = p_campaign_id
          AND cm.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    DELETE FROM public.discord_campaign_gm_turn_lock l
    WHERE l.campaign_id = p_campaign_id
      AND (
          (l.processing = FALSE AND l.expires_at <= NOW())
          OR
          (l.processing = TRUE AND COALESCE(l.processing_started_at, l.updated_at) <= NOW() - INTERVAL '10 minutes')
      );

    SELECT l.*
    INTO v_lock
    FROM public.discord_campaign_gm_turn_lock l
    WHERE l.campaign_id = p_campaign_id;

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
        v_remaining := GREATEST(
            0,
            CEIL(EXTRACT(EPOCH FROM (v_lock.expires_at - NOW())))::INTEGER
        );
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

-- Atomically claim the typing lease. If another player owns it,
-- their state is returned instead and the caller does not acquire it.
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
        FROM public.discord_campaign_members cm
        WHERE cm.campaign_id = p_campaign_id
          AND cm.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    DELETE FROM public.discord_campaign_gm_turn_lock l
    WHERE l.campaign_id = p_campaign_id
      AND (
          (l.processing = FALSE AND l.expires_at <= NOW())
          OR
          (l.processing = TRUE AND COALESCE(l.processing_started_at, l.updated_at) <= NOW() - INTERVAL '10 minutes')
      );

    SELECT l.*
    INTO v_lock
    FROM public.discord_campaign_gm_turn_lock l
    WHERE l.campaign_id = p_campaign_id
    FOR UPDATE;

    IF v_lock.campaign_id IS NULL THEN
        INSERT INTO public.discord_campaign_gm_turn_lock(
            campaign_id, player_id, player_name, lock_token,
            acquired_at, expires_at, processing, processing_started_at, updated_at
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
            NOW()
        )
        ON CONFLICT (campaign_id) DO NOTHING
        RETURNING * INTO v_lock;

        -- Another concurrent caller may have won the unique-row race.
        IF v_lock.campaign_id IS NULL THEN
            SELECT l.*
            INTO v_lock
            FROM public.discord_campaign_gm_turn_lock l
            WHERE l.campaign_id = p_campaign_id;
        END IF;
    END IF;

    IF NOT v_lock.processing THEN
        v_remaining := GREATEST(
            0,
            CEIL(EXTRACT(EPOCH FROM (v_lock.expires_at - NOW())))::INTEGER
        );
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

-- Convert a valid, unexpired typing lease into a processing lease.
-- This is called by the ASP.NET server immediately before it writes
-- the player's GM message and asks OpenAI for the response.
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
        FROM public.discord_campaign_members cm
        WHERE cm.campaign_id = p_campaign_id
          AND cm.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    DELETE FROM public.discord_campaign_gm_turn_lock l
    WHERE l.campaign_id = p_campaign_id
      AND l.processing = FALSE
      AND l.expires_at <= NOW();

    UPDATE public.discord_campaign_gm_turn_lock l
    SET processing = TRUE,
        processing_started_at = NOW(),
        expires_at = NOW() + INTERVAL '10 minutes',
        updated_at = NOW()
    WHERE l.campaign_id = p_campaign_id
      AND l.player_id = p_player_id
      AND l.lock_token = p_lock_token
      AND l.processing = FALSE
      AND l.expires_at > NOW()
    RETURNING * INTO v_lock;

    IF v_lock.campaign_id IS NULL THEN
        RAISE EXCEPTION 'Your 30-second AI Game Master turn expired or is owned by another player.';
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

-- Release only the matching owner's matching lease. The server calls
-- this in a finally block after the GM response succeeds or fails.
DROP FUNCTION IF EXISTS public.discord_release_gm_turn(UUID, UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_release_gm_turn(
    p_player_id UUID,
    p_campaign_id UUID,
    p_lock_token UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted INTEGER := 0;
BEGIN
    DELETE FROM public.discord_campaign_gm_turn_lock l
    WHERE l.campaign_id = p_campaign_id
      AND l.player_id = p_player_id
      AND l.lock_token = p_lock_token;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_gm_turn_state(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_acquire_gm_turn(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_begin_gm_processing(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_release_gm_turn(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_gm_turn_state(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_acquire_gm_turn(UUID, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_begin_gm_processing(UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_release_gm_turn(UUID, UUID, UUID) TO service_role;

COMMIT;
