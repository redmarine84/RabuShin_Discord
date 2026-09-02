-- ============================================================
-- RabuShin Rules Build 6.5
-- Interactive Settlement Maps + Player-Specific POI Movement + Shops
-- Additive migration. Safe to run more than once.
-- Requires the existing Discord campaign/character/inventory schema.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_player_settlement_locations
(
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    settlement_key TEXT NOT NULL DEFAULT '',
    poi_key TEXT NOT NULL DEFAULT '',
    poi_name TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campaign_id, player_id)
);

CREATE INDEX IF NOT EXISTS idx_discord_player_settlement_locations_poi
ON public.discord_player_settlement_locations(campaign_id, settlement_key, poi_key);

ALTER TABLE public.discord_player_settlement_locations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_player_settlement_locations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_player_settlement_locations TO service_role;

DROP FUNCTION IF EXISTS public.discord_get_player_settlement_location(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_player_settlement_location(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    settlement_key TEXT,
    poi_key TEXT,
    poi_name TEXT,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id
          AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    RETURN QUERY
    SELECT l.settlement_key, l.poi_key, l.poi_name, l.updated_at
    FROM public.discord_player_settlement_locations l
    WHERE l.campaign_id = p_campaign_id
      AND l.player_id = p_player_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_set_player_settlement_location(UUID, UUID, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.discord_set_player_settlement_location(
    p_player_id UUID,
    p_campaign_id UUID,
    p_settlement_key TEXT,
    p_poi_key TEXT,
    p_poi_name TEXT
)
RETURNS TABLE(
    settlement_key TEXT,
    poi_key TEXT,
    poi_name TEXT,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_settlement TEXT := LOWER(TRIM(COALESCE(p_settlement_key, '')));
    v_poi TEXT := LOWER(TRIM(COALESCE(p_poi_key, '')));
    v_name TEXT := TRIM(COALESCE(p_poi_name, ''));
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id
          AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    IF v_settlement = '' OR v_poi = '' OR v_name = '' THEN
        RAISE EXCEPTION 'Settlement and point of interest are required.';
    END IF;

    INSERT INTO public.discord_player_settlement_locations(
        campaign_id, player_id, settlement_key, poi_key, poi_name, updated_at)
    VALUES(
        p_campaign_id, p_player_id, v_settlement, v_poi, v_name, NOW())
    ON CONFLICT (campaign_id, player_id)
    DO UPDATE SET
        settlement_key = EXCLUDED.settlement_key,
        poi_key = EXCLUDED.poi_key,
        poi_name = EXCLUDED.poi_name,
        updated_at = NOW();

    RETURN QUERY
    SELECT l.settlement_key, l.poi_key, l.poi_name, l.updated_at
    FROM public.discord_player_settlement_locations l
    WHERE l.campaign_id = p_campaign_id
      AND l.player_id = p_player_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_buy_settlement_item(UUID, UUID, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.discord_buy_settlement_item(
    p_player_id UUID,
    p_campaign_id UUID,
    p_settlement_key TEXT,
    p_poi_key TEXT,
    p_item_name TEXT,
    p_quantity INTEGER,
    p_unit_price_gp INTEGER,
    p_description TEXT DEFAULT '',
    p_source_name TEXT DEFAULT '',
    p_notes TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_gold NUMERIC;
    v_life_state TEXT;
    v_total_price INTEGER;
    v_remaining_gold NUMERIC;
    v_carried INTEGER;
    v_location RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id
          AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    IF TRIM(COALESCE(p_item_name, '')) = '' THEN
        RAISE EXCEPTION 'Item name is required.';
    END IF;
    IF COALESCE(p_quantity, 0) < 1 OR p_quantity > 20 THEN
        RAISE EXCEPTION 'Purchase quantity must be between 1 and 20.';
    END IF;
    IF COALESCE(p_unit_price_gp, 0) < 0 OR p_unit_price_gp > 1000000 THEN
        RAISE EXCEPTION 'Invalid shop price.';
    END IF;

    SELECT l.settlement_key, l.poi_key
    INTO v_location
    FROM public.discord_player_settlement_locations l
    WHERE l.campaign_id = p_campaign_id
      AND l.player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Your character is not currently at that shop.';
    END IF;
    IF LOWER(TRIM(v_location.settlement_key)) <> LOWER(TRIM(COALESCE(p_settlement_key, ''))) OR
       LOWER(TRIM(v_location.poi_key)) <> LOWER(TRIM(COALESCE(p_poi_key, ''))) THEN
        RAISE EXCEPTION 'Your character is not currently at that shop.';
    END IF;

    SELECT c.character_id, c.gold, COALESCE(c.life_state, 'alive')
    INTO v_character_id, v_gold, v_life_state
    FROM public.discord_characters c
    WHERE c.campaign_id = p_campaign_id
      AND c.player_id = p_player_id
    FOR UPDATE;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;
    IF LOWER(COALESCE(v_life_state, 'alive')) = 'dead' THEN
        RAISE EXCEPTION 'A dead character cannot make shop purchases.';
    END IF;

    v_total_price := p_unit_price_gp * p_quantity;
    IF v_gold < v_total_price THEN
        RAISE EXCEPTION 'The character does not have enough GP for this purchase.';
    END IF;

    v_remaining_gold := public.discord_gm_adjust_gold(
        v_character_id,
        p_campaign_id,
        -v_total_price
    );

    v_carried := public.discord_gm_add_inventory_item(
        v_character_id,
        p_campaign_id,
        TRIM(p_item_name),
        p_quantity,
        TRIM(COALESCE(p_description, '')),
        TRIM(COALESCE(p_source_name, '')),
        TRIM(COALESCE(p_notes, ''))
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'item_name', TRIM(p_item_name),
        'quantity_purchased', p_quantity,
        'quantity_carried', v_carried,
        'unit_price_gp', p_unit_price_gp,
        'total_price_gp', v_total_price,
        'remaining_gold', v_remaining_gold
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_player_settlement_location(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_set_player_settlement_location(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_buy_settlement_item(UUID, UUID, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_player_settlement_location(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_player_settlement_location(UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_buy_settlement_item(UUID, UUID, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT, TEXT, TEXT) TO service_role;

COMMIT;
