-- ============================================================
-- RabuShinAIGM Rules Build 6.18.5
-- Friends -> Solo Permanent Conversion
-- Migration 42
-- Requires Build 6.17 / migration 37.
-- Safe to run more than once.
-- ============================================================

BEGIN;

-- Permanent audit of campaigns converted from Friends to Solo.
CREATE TABLE IF NOT EXISTS public.discord_campaign_solo_conversions
(
    campaign_id UUID PRIMARY KEY REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    owner_player_id UUID NOT NULL,
    previous_join_code TEXT NOT NULL,
    converted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.discord_campaign_solo_conversions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_campaign_solo_conversions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_campaign_solo_conversions TO service_role;

-- Keep a durable record that a real Discord player has ever been a member.
-- player_id intentionally has no FK so the history survives account cleanup.
CREATE TABLE IF NOT EXISTS public.discord_campaign_real_member_history
(
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    player_id UUID NOT NULL,
    first_joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campaign_id, player_id)
);

ALTER TABLE public.discord_campaign_real_member_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_campaign_real_member_history FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_campaign_real_member_history TO service_role;

-- Backfill every real player who is currently a member.
INSERT INTO public.discord_campaign_real_member_history(campaign_id, player_id, first_joined_at)
SELECT cm.campaign_id, cm.player_id, NOW()
FROM public.discord_campaign_members cm
JOIN public.discord_players p ON p.player_id = cm.player_id
WHERE COALESCE(p.discord_user_id,'') NOT LIKE 'solo:%'
ON CONFLICT (campaign_id, player_id) DO NOTHING;

-- Record future real-player joins even if that player later leaves.
CREATE OR REPLACE FUNCTION public.discord_record_real_campaign_member_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_discord_user_id TEXT;
BEGIN
    SELECT p.discord_user_id
    INTO v_discord_user_id
    FROM public.discord_players p
    WHERE p.player_id = NEW.player_id;

    IF COALESCE(v_discord_user_id,'') NOT LIKE 'solo:%' THEN
        INSERT INTO public.discord_campaign_real_member_history(campaign_id, player_id, first_joined_at)
        VALUES(NEW.campaign_id, NEW.player_id, NOW())
        ON CONFLICT (campaign_id, player_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_record_real_campaign_member_history
ON public.discord_campaign_members;

CREATE TRIGGER trg_discord_record_real_campaign_member_history
AFTER INSERT ON public.discord_campaign_members
FOR EACH ROW
EXECUTE FUNCTION public.discord_record_real_campaign_member_history();

-- Solo is one-way. Once a campaign is Solo, campaign_type can never be changed away from Solo.
CREATE OR REPLACE FUNCTION public.discord_prevent_solo_campaign_reversion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF LOWER(TRIM(COALESCE(OLD.campaign_type,''))) = 'solo'
       AND LOWER(TRIM(COALESCE(NEW.campaign_type,''))) <> 'solo' THEN
        RAISE EXCEPTION 'Solo Play conversion is permanent and cannot be undone.';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_prevent_solo_campaign_reversion
ON public.discord_campaigns;

CREATE TRIGGER trg_discord_prevent_solo_campaign_reversion
BEFORE UPDATE OF campaign_type ON public.discord_campaigns
FOR EACH ROW
EXECUTE FUNCTION public.discord_prevent_solo_campaign_reversion();

-- Server-authoritative eligibility used by Settings.
DROP FUNCTION IF EXISTS public.discord_get_solo_conversion_state(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_solo_conversion_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    eligible BOOLEAN,
    reason TEXT,
    other_real_players BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner UUID;
    v_mode TEXT;
    v_active BOOLEAN;
    v_other BIGINT := 0;
BEGIN
    SELECT c.owner_player_id,
           LOWER(TRIM(COALESCE(c.campaign_type,'friends'))),
           c.is_active
    INTO v_owner, v_mode, v_active
    FROM public.discord_campaigns c
    WHERE c.campaign_id = p_campaign_id;

    IF v_owner IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Campaign could not be found.'::TEXT, 0::BIGINT;
        RETURN;
    END IF;

    IF v_owner <> p_player_id THEN
        RETURN QUERY SELECT FALSE, 'Only the campaign owner can convert this campaign.'::TEXT, 0::BIGINT;
        RETURN;
    END IF;

    IF NOT COALESCE(v_active,FALSE) THEN
        RETURN QUERY SELECT FALSE, 'This campaign is not active.'::TEXT, 0::BIGINT;
        RETURN;
    END IF;

    IF v_mode = 'solo' THEN
        RETURN QUERY SELECT FALSE, 'This campaign is already Solo Play.'::TEXT, 0::BIGINT;
        RETURN;
    END IF;

    SELECT COUNT(DISTINCT evidence.player_id)
    INTO v_other
    FROM (
        SELECT h.player_id
        FROM public.discord_campaign_real_member_history h
        WHERE h.campaign_id = p_campaign_id

        UNION

        -- Legacy evidence: if another real player's character still exists,
        -- that player has previously joined even if their membership was later removed.
        SELECT ch.player_id
        FROM public.discord_characters ch
        JOIN public.discord_players p ON p.player_id = ch.player_id
        WHERE ch.campaign_id = p_campaign_id
          AND COALESCE(p.discord_user_id,'') NOT LIKE 'solo:%'
    ) evidence
    WHERE evidence.player_id <> v_owner;

    IF v_other > 0 THEN
        RETURN QUERY SELECT FALSE,
            'Convert to Solo Play is only available before any other real player has joined this campaign.'::TEXT,
            v_other;
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, ''::TEXT, 0::BIGINT;
END;
$$;

-- Permanent Friends -> Solo conversion.
DROP FUNCTION IF EXISTS public.discord_convert_campaign_to_solo(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_convert_campaign_to_solo(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_owner UUID;
    v_mode TEXT;
    v_active BOOLEAN;
    v_old_join_code TEXT;
    v_eligible BOOLEAN := FALSE;
    v_reason TEXT := '';
BEGIN
    -- Serialize this conversion against join attempts for this campaign.
    PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::TEXT));

    SELECT c.owner_player_id,
           LOWER(TRIM(COALESCE(c.campaign_type,'friends'))),
           c.is_active,
           c.join_code
    INTO v_owner, v_mode, v_active, v_old_join_code
    FROM public.discord_campaigns c
    WHERE c.campaign_id = p_campaign_id
    FOR UPDATE;

    IF v_owner IS NULL THEN RAISE EXCEPTION 'Campaign could not be found.'; END IF;
    IF v_owner <> p_player_id THEN RAISE EXCEPTION 'Only the campaign owner can convert this campaign.'; END IF;
    IF NOT COALESCE(v_active,FALSE) THEN RAISE EXCEPTION 'This campaign is not active.'; END IF;
    IF v_mode = 'solo' THEN RAISE EXCEPTION 'This campaign is already Solo Play.'; END IF;

    SELECT s.eligible, s.reason
    INTO v_eligible, v_reason
    FROM public.discord_get_solo_conversion_state(p_player_id, p_campaign_id) s
    LIMIT 1;

    IF NOT COALESCE(v_eligible,FALSE) THEN
        RAISE EXCEPTION '%', COALESCE(NULLIF(v_reason,''),'This campaign cannot be converted to Solo Play.');
    END IF;

    INSERT INTO public.discord_campaign_solo_conversions(
        campaign_id, owner_player_id, previous_join_code, converted_at)
    VALUES(
        p_campaign_id, p_player_id, COALESCE(v_old_join_code,''), NOW())
    ON CONFLICT (campaign_id) DO NOTHING;

    UPDATE public.discord_campaigns
    SET campaign_type = 'solo',
        -- Invalidate the Friends join code immediately. This token is internal only.
        join_code = 'SOLO-' || UPPER(LEFT(REPLACE(gen_random_uuid()::TEXT,'-',''),20)),
        updated_at = NOW()
    WHERE campaign_id = p_campaign_id;

    -- The owner's existing character becomes Solo slot 1 and active character.
    PERFORM public.discord_solo_ensure_primary(p_player_id, p_campaign_id);

    RETURN p_campaign_id;
END;
$$;

-- Re-define Join Campaign so join and conversion cannot race.
CREATE OR REPLACE FUNCTION public.discord_join_campaign(
    p_player_id UUID,
    p_join_code TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_campaign_id UUID;
    v_mode TEXT;
BEGIN
    SELECT c.campaign_id
    INTO v_campaign_id
    FROM public.discord_campaigns c
    WHERE UPPER(c.join_code)=UPPER(TRIM(COALESCE(p_join_code,'')))
      AND c.is_active=TRUE;

    IF v_campaign_id IS NULL THEN
        RAISE EXCEPTION 'Campaign code was not found.';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(v_campaign_id::TEXT));

    SELECT LOWER(TRIM(COALESCE(c.campaign_type,'friends')))
    INTO v_mode
    FROM public.discord_campaigns c
    WHERE c.campaign_id=v_campaign_id
      AND c.is_active=TRUE;

    IF v_mode IS NULL THEN RAISE EXCEPTION 'Campaign code was not found.'; END IF;
    IF v_mode='solo' THEN RAISE EXCEPTION 'Solo Play campaigns cannot be joined.'; END IF;

    INSERT INTO public.discord_campaign_members(campaign_id,player_id,role)
    VALUES(v_campaign_id,p_player_id,'Player')
    ON CONFLICT DO NOTHING;

    RETURN v_campaign_id;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_record_real_campaign_member_history() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_prevent_solo_campaign_reversion() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_get_solo_conversion_state(UUID,UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_convert_campaign_to_solo(UUID,UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_record_real_campaign_member_history() TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_prevent_solo_campaign_reversion() TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_solo_conversion_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_convert_campaign_to_solo(UUID,UUID) TO service_role;

COMMIT;
