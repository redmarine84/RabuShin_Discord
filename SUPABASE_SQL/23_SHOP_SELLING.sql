-- RabuShinAIGM Rules Build 6.6
-- Shop selling: player inventory -> merchant, with atomic inventory removal + GP credit.
-- Requires Build 6.5 / migration 22 and the existing inventory RPCs.

BEGIN;

DROP FUNCTION IF EXISTS public.discord_sell_settlement_item(UUID, UUID, TEXT, TEXT, UUID, TEXT, INTEGER, NUMERIC, TEXT);
CREATE OR REPLACE FUNCTION public.discord_sell_settlement_item(
    p_player_id UUID,
    p_campaign_id UUID,
    p_settlement_key TEXT,
    p_poi_key TEXT,
    p_inventory_item_id UUID,
    p_item_name TEXT,
    p_quantity INTEGER,
    p_unit_price_gp NUMERIC,
    p_shop_name TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_life_state TEXT;
    v_location RECORD;
    v_remaining INTEGER;
    v_total_price NUMERIC;
    v_remaining_gold NUMERIC;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id
          AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    IF p_inventory_item_id IS NULL OR TRIM(COALESCE(p_item_name, '')) = '' THEN
        RAISE EXCEPTION 'Inventory item is required.';
    END IF;
    IF COALESCE(p_quantity, 0) < 1 THEN
        RAISE EXCEPTION 'Sell quantity must be at least 1.';
    END IF;
    IF COALESCE(p_unit_price_gp, 0) <= 0 OR p_unit_price_gp > 1000000 THEN
        RAISE EXCEPTION 'Invalid merchant offer.';
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

    SELECT c.character_id, COALESCE(c.life_state, 'alive')
    INTO v_character_id, v_life_state
    FROM public.discord_characters c
    WHERE c.campaign_id = p_campaign_id
      AND c.player_id = p_player_id
    FOR UPDATE;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;
    IF LOWER(COALESCE(v_life_state, 'alive')) = 'dead' THEN
        RAISE EXCEPTION 'A dead character cannot sell items.';
    END IF;

    -- Program.cs has already validated the item belongs to this character, is not
    -- equipped, is accepted by this merchant, and has a server-calculated offer.
    -- The existing inventory removal RPC revalidates ownership and available quantity.
    -- Both operations below execute inside this transaction; any failure rolls both back.
    v_remaining := public.discord_remove_inventory_quantity(
        p_player_id,
        p_campaign_id,
        p_inventory_item_id,
        p_quantity
    );

    v_total_price := p_unit_price_gp * p_quantity;
    v_remaining_gold := public.discord_gm_adjust_gold(
        v_character_id,
        p_campaign_id,
        v_total_price
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'shop_name', TRIM(COALESCE(p_shop_name, '')),
        'item_name', TRIM(p_item_name),
        'quantity_sold', p_quantity,
        'quantity_remaining', v_remaining,
        'unit_price_gp', p_unit_price_gp,
        'total_price_gp', v_total_price,
        'remaining_gold', v_remaining_gold
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_sell_settlement_item(UUID, UUID, TEXT, TEXT, UUID, TEXT, INTEGER, NUMERIC, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discord_sell_settlement_item(UUID, UUID, TEXT, TEXT, UUID, TEXT, INTEGER, NUMERIC, TEXT) TO service_role;

COMMIT;
