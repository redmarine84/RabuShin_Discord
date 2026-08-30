-- ============================================================
-- RABUSHIN DISCORD - CAMPAIGN DELETE / LEAVE MANAGEMENT
-- Safe to run more than once.
--
-- Owner: may permanently delete the entire campaign.
-- Member: may leave a campaign they do not own. Their character
-- and personal journal data are removed. Shared campaign/chat
-- history remains for the continuing players.
-- ============================================================

DROP FUNCTION IF EXISTS public.discord_delete_campaign(UUID, UUID);
CREATE FUNCTION public.discord_delete_campaign
(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS
$$
DECLARE
    v_owner_player_id UUID;
BEGIN
    SELECT owner_player_id
    INTO v_owner_player_id
    FROM public.discord_campaigns
    WHERE campaign_id = p_campaign_id;

    IF v_owner_player_id IS NULL THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    IF v_owner_player_id <> p_player_id THEN
        RAISE EXCEPTION 'Only the campaign owner can permanently delete this campaign.';
    END IF;

    -- Campaign-related foreign keys use ON DELETE CASCADE, so this
    -- also removes members, characters, inventory, spells, spell
    -- slots, campaign messages, journal entries, and campaign state.
    DELETE FROM public.discord_campaigns
    WHERE campaign_id = p_campaign_id
      AND owner_player_id = p_player_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Campaign could not be deleted.';
    END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_leave_campaign(UUID, UUID);
CREATE FUNCTION public.discord_leave_campaign
(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS
$$
DECLARE
    v_owner_player_id UUID;
BEGIN
    SELECT owner_player_id
    INTO v_owner_player_id
    FROM public.discord_campaigns
    WHERE campaign_id = p_campaign_id;

    IF v_owner_player_id IS NULL THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    IF v_owner_player_id = p_player_id THEN
        RAISE EXCEPTION 'Campaign owners cannot leave their own campaign. Use Delete Campaign instead.';
    END IF;

    IF NOT EXISTS
    (
        SELECT 1
        FROM public.discord_campaign_members
        WHERE campaign_id = p_campaign_id
          AND player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    -- Remove personal campaign data first. Deleting the character
    -- cascades to inventory, character spells, and spell slots.
    DELETE FROM public.discord_journal_entries
    WHERE campaign_id = p_campaign_id
      AND player_id = p_player_id;

    DELETE FROM public.discord_characters
    WHERE campaign_id = p_campaign_id
      AND player_id = p_player_id;

    DELETE FROM public.discord_campaign_members
    WHERE campaign_id = p_campaign_id
      AND player_id = p_player_id;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_delete_campaign(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_leave_campaign(UUID, UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.discord_delete_campaign(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_leave_campaign(UUID, UUID) TO service_role;
