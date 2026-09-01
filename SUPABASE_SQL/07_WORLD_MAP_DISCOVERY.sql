-- ============================================================
-- RABUSHIN VISUALS BUILD 2 - WORLD MAP / DISCOVERY / FAST TRAVEL
-- Safe to run more than once.
-- Run in Supabase SQL Editor after the previous RabuShin SQL upgrades.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.discord_world_map_discoveries
(
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    location_key TEXT NOT NULL,
    location_name TEXT NOT NULL,
    discovery_reason TEXT NOT NULL DEFAULT '',
    discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campaign_id, location_key)
);

CREATE INDEX IF NOT EXISTS idx_discord_world_map_campaign
    ON public.discord_world_map_discoveries(campaign_id);

ALTER TABLE public.discord_world_map_discoveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_world_map_discoveries FROM anon, authenticated;
GRANT ALL ON public.discord_world_map_discoveries TO service_role;

CREATE OR REPLACE FUNCTION public.discord_world_map_catalog()
RETURNS TABLE(location_key TEXT, location_name TEXT, chapter_order INTEGER)
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT * FROM (VALUES
        ('greymoor'::TEXT, 'Greymoor Hollow'::TEXT, 1),
        ('stonewake', 'Stonewake Port', 2),
        ('emberfall', 'Emberfall', 3),
        ('lunareth', 'Lunareth', 4),
        ('high_bastion', 'High Bastion', 5),
        ('marrowfen', 'Marrowfen', 6),
        ('silverreach', 'Silverreach', 7),
        ('duskmire', 'Duskmire Crossing', 8),
        ('frostharbor', 'Frostharbor', 9),
        ('sunspire', 'Sunspire', 10),
        ('blackroot', 'Blackroot Enclave', 11),
        ('aetherfall', 'Aetherfall', 12)
    ) AS v(location_key, location_name, chapter_order);
$$;

CREATE OR REPLACE FUNCTION public.discord_world_map_resolve_location(p_location_name TEXT)
RETURNS TABLE(location_key TEXT, location_name TEXT)
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT c.location_key, c.location_name
    FROM public.discord_world_map_catalog() c
    WHERE LOWER(c.location_name) = LOWER(TRIM(COALESCE(p_location_name, '')))
       OR LOWER(c.location_key) = LOWER(TRIM(COALESCE(p_location_name, '')))
       OR (LOWER(TRIM(COALESCE(p_location_name, ''))) = 'duskmire' AND c.location_key = 'duskmire')
    LIMIT 1;
$$;

-- Preserve the original WinForms seed behavior: a campaign automatically knows
-- each settlement reached by its chapter progression, plus its current location.
INSERT INTO public.discord_world_map_discoveries(campaign_id, location_key, location_name, discovery_reason)
SELECT c.campaign_id, catalog.location_key, catalog.location_name, 'Reached through campaign progression'
FROM public.discord_campaigns c
JOIN public.discord_world_map_catalog() catalog
  ON catalog.chapter_order <= GREATEST(1, LEAST(12, c.current_chapter))
ON CONFLICT (campaign_id, location_key) DO NOTHING;

INSERT INTO public.discord_world_map_discoveries(campaign_id, location_key, location_name, discovery_reason)
SELECT c.campaign_id, r.location_key, r.location_name, 'Current campaign location'
FROM public.discord_campaigns c
CROSS JOIN LATERAL public.discord_world_map_resolve_location(c.current_location) r
ON CONFLICT (campaign_id, location_key) DO NOTHING;

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

    INSERT INTO public.discord_world_map_discoveries(campaign_id, location_key, location_name, discovery_reason)
    SELECT p_campaign_id, catalog.location_key, catalog.location_name, 'Reached through campaign progression'
    FROM public.discord_world_map_catalog() catalog
    WHERE catalog.chapter_order <= GREATEST(1, LEAST(12, v_current_chapter))
    ON CONFLICT (campaign_id, location_key) DO NOTHING;

    INSERT INTO public.discord_world_map_discoveries(campaign_id, location_key, location_name, discovery_reason)
    SELECT p_campaign_id, r.location_key, r.location_name, 'Current campaign location'
    FROM public.discord_world_map_resolve_location(v_current_location) r
    ON CONFLICT (campaign_id, location_key) DO NOTHING;

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

    INSERT INTO public.discord_world_map_discoveries(campaign_id, location_key, location_name, discovery_reason)
    SELECT p_campaign_id, catalog.location_key, catalog.location_name, 'Reached through campaign progression'
    FROM public.discord_world_map_catalog() catalog
    WHERE catalog.chapter_order <= GREATEST(1, LEAST(12, v_current_chapter))
    ON CONFLICT (campaign_id, location_key) DO NOTHING;

    INSERT INTO public.discord_world_map_discoveries(campaign_id, location_key, location_name, discovery_reason)
    SELECT p_campaign_id, r.location_key, r.location_name, 'Current campaign location'
    FROM public.discord_world_map_resolve_location(v_current_location) r
    ON CONFLICT (campaign_id, location_key) DO NOTHING;

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

DROP FUNCTION IF EXISTS public.discord_gm_discover_world_location(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_discover_world_location(
    p_campaign_id UUID,
    p_location_name TEXT,
    p_reason TEXT DEFAULT ''
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_key TEXT;
    v_name TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id = p_campaign_id AND c.is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    SELECT r.location_key, r.location_name
    INTO v_key, v_name
    FROM public.discord_world_map_resolve_location(p_location_name) r;

    IF v_key IS NULL THEN
        RAISE EXCEPTION 'Unknown Vael Turog settlement: %', p_location_name;
    END IF;

    INSERT INTO public.discord_world_map_discoveries(
        campaign_id, location_key, location_name, discovery_reason, discovered_at)
    VALUES(
        p_campaign_id, v_key, v_name, LEFT(TRIM(COALESCE(p_reason, '')), 240), NOW())
    ON CONFLICT (campaign_id, location_key) DO UPDATE SET
        location_name = EXCLUDED.location_name,
        discovery_reason = CASE
            WHEN public.discord_world_map_discoveries.discovery_reason = '' THEN EXCLUDED.discovery_reason
            ELSE public.discord_world_map_discoveries.discovery_reason
        END;

    RETURN v_name;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_travel_to_world_location(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_travel_to_world_location(
    p_campaign_id UUID,
    p_location_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_key TEXT;
    v_name TEXT;
BEGIN
    SELECT r.location_key, r.location_name
    INTO v_key, v_name
    FROM public.discord_world_map_resolve_location(p_location_name) r;

    IF v_key IS NULL THEN
        RAISE EXCEPTION 'Unknown Vael Turog settlement: %', p_location_name;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_world_map_discoveries d
        WHERE d.campaign_id = p_campaign_id
          AND d.location_key = v_key
    ) THEN
        RAISE EXCEPTION '% has not been discovered by this campaign.', v_name;
    END IF;

    UPDATE public.discord_campaigns
    SET current_location = v_name,
        updated_at = NOW()
    WHERE campaign_id = p_campaign_id
      AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    RETURN v_name;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_world_map_catalog() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_world_map_resolve_location(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_get_world_map_state(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_world_map_state(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_discover_world_location(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_travel_to_world_location(UUID, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_world_map_catalog() TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_world_map_resolve_location(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_world_map_state(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_world_map_state(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_discover_world_location(UUID, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_travel_to_world_location(UUID, TEXT) TO service_role;
