-- ============================================================
-- RABUSHIN BUILD 2 - WORLD MAP location_key ambiguity fix
-- Fixes PostgreSQL 42702 in discord_get_world_map_state and
-- discord_gm_get_world_map_state.
-- Safe to run more than once.
-- ============================================================

DROP FUNCTION IF EXISTS public.discord_get_world_map_state(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_world_map_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    location_key TEXT,
    location_name TEXT,
    discovered BOOLEAN,
    is_current BOOLEAN,
    discovered_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_location TEXT;
    v_current_chapter INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id
          AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    SELECT c.current_location, c.current_chapter
    INTO v_current_location, v_current_chapter
    FROM public.discord_campaigns c
    WHERE c.campaign_id = p_campaign_id
      AND c.is_active = TRUE;

    IF v_current_location IS NULL THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    INSERT INTO public.discord_world_map_discoveries(
        campaign_id,
        location_key,
        location_name,
        discovery_reason
    )
    SELECT
        p_campaign_id,
        catalog.location_key,
        catalog.location_name,
        'Reached through campaign progression'
    FROM public.discord_world_map_catalog() catalog
    WHERE catalog.chapter_order <= GREATEST(1, LEAST(12, v_current_chapter))
    ON CONFLICT ON CONSTRAINT discord_world_map_discoveries_pkey DO NOTHING;

    INSERT INTO public.discord_world_map_discoveries(
        campaign_id,
        location_key,
        location_name,
        discovery_reason
    )
    SELECT
        p_campaign_id,
        r.location_key,
        r.location_name,
        'Current campaign location'
    FROM public.discord_world_map_resolve_location(v_current_location) r
    ON CONFLICT ON CONSTRAINT discord_world_map_discoveries_pkey DO NOTHING;

    RETURN QUERY
    SELECT
        c.location_key,
        c.location_name,
        (d.location_key IS NOT NULL) AS discovered,
        (LOWER(c.location_name) = LOWER(v_current_location)) AS is_current,
        d.discovered_at
    FROM public.discord_world_map_catalog() c
    LEFT JOIN public.discord_world_map_discoveries d
      ON d.campaign_id = p_campaign_id
     AND d.location_key = c.location_key
    ORDER BY c.location_name;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_world_map_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_world_map_state(p_campaign_id UUID)
RETURNS TABLE(
    location_key TEXT,
    location_name TEXT,
    discovered BOOLEAN,
    is_current BOOLEAN,
    discovered_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_location TEXT;
    v_current_chapter INTEGER;
BEGIN
    SELECT c.current_location, c.current_chapter
    INTO v_current_location, v_current_chapter
    FROM public.discord_campaigns c
    WHERE c.campaign_id = p_campaign_id
      AND c.is_active = TRUE;

    IF v_current_location IS NULL THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    INSERT INTO public.discord_world_map_discoveries(
        campaign_id,
        location_key,
        location_name,
        discovery_reason
    )
    SELECT
        p_campaign_id,
        catalog.location_key,
        catalog.location_name,
        'Reached through campaign progression'
    FROM public.discord_world_map_catalog() catalog
    WHERE catalog.chapter_order <= GREATEST(1, LEAST(12, v_current_chapter))
    ON CONFLICT ON CONSTRAINT discord_world_map_discoveries_pkey DO NOTHING;

    INSERT INTO public.discord_world_map_discoveries(
        campaign_id,
        location_key,
        location_name,
        discovery_reason
    )
    SELECT
        p_campaign_id,
        r.location_key,
        r.location_name,
        'Current campaign location'
    FROM public.discord_world_map_resolve_location(v_current_location) r
    ON CONFLICT ON CONSTRAINT discord_world_map_discoveries_pkey DO NOTHING;

    RETURN QUERY
    SELECT
        c.location_key,
        c.location_name,
        (d.location_key IS NOT NULL) AS discovered,
        (LOWER(c.location_name) = LOWER(v_current_location)) AS is_current,
        d.discovered_at
    FROM public.discord_world_map_catalog() c
    LEFT JOIN public.discord_world_map_discoveries d
      ON d.campaign_id = p_campaign_id
     AND d.location_key = c.location_key
    ORDER BY c.location_name;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_world_map_state(UUID, UUID)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.discord_gm_get_world_map_state(UUID)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_world_map_state(UUID, UUID)
TO service_role;

GRANT EXECUTE ON FUNCTION public.discord_gm_get_world_map_state(UUID)
TO service_role;
