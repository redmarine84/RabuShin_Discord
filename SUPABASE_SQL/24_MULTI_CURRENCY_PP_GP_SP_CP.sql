-- ============================================================
-- RabuShinAIGM Rules Build 6.6.1
-- Multi-Currency Wallet: PP / GP / SP / CP
--
-- Compatibility design:
--   discord_characters.gold remains the authoritative TOTAL VALUE measured in GP.
--   NUMERIC allows exact sub-GP values down to 1 CP (0.01 GP).
--   The client presents that value as PP / GP / SP / CP.
--
-- Conversion:
--   10 CP = 1 SP
--   10 SP = 1 GP
--   10 GP = 1 PP
--
-- Requires migration 23_SHOP_SELLING.sql.
-- ============================================================

BEGIN;

-- If an earlier test version added an overloaded numeric discord_gm_adjust_gold,
-- remove it. The original INTEGER RPC is intentionally left untouched so the
-- AI GM's existing adjust_gold tool cannot become ambiguous through PostgREST.
DROP FUNCTION IF EXISTS public.discord_gm_adjust_gold(UUID, UUID, NUMERIC);

-- Existing campaigns used whole-GP values. Normalize any existing decimal value
-- to the smallest supported denomination (1 CP = 0.01 GP).
UPDATE public.discord_characters
SET gold = ROUND(GREATEST(COALESCE(gold, 0), 0), 2)
WHERE gold IS DISTINCT FROM ROUND(GREATEST(COALESCE(gold, 0), 0), 2);

-- Internal exact-currency helper used by shop selling. It is deliberately named
-- differently from discord_gm_adjust_gold so the existing integer-only GM RPC
-- remains backward compatible.
DROP FUNCTION IF EXISTS public.discord_adjust_currency_value(UUID, UUID, NUMERIC);
CREATE OR REPLACE FUNCTION public.discord_adjust_currency_value(
    p_character_id UUID,
    p_campaign_id UUID,
    p_delta_gp NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_gold NUMERIC;
    v_delta NUMERIC;
    v_new_gold NUMERIC;
BEGIN
    IF p_character_id IS NULL OR p_campaign_id IS NULL THEN
        RAISE EXCEPTION 'Character and campaign are required.';
    END IF;

    v_delta := ROUND(COALESCE(p_delta_gp, 0), 2);

    -- One copper piece is the smallest supported unit.
    IF ABS(COALESCE(p_delta_gp, 0) - v_delta) >= 0.000001 THEN
        RAISE EXCEPTION 'Currency adjustments must be in whole copper-piece increments (0.01 GP).';
    END IF;
    IF ABS(v_delta) > 1000000 THEN
        RAISE EXCEPTION 'Currency adjustment is outside the allowed range.';
    END IF;

    SELECT ROUND(COALESCE(c.gold, 0), 2)
    INTO v_gold
    FROM public.discord_characters c
    WHERE c.character_id = p_character_id
      AND c.campaign_id = p_campaign_id
    FOR UPDATE;

    IF v_gold IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    v_new_gold := ROUND(v_gold + v_delta, 2);
    IF v_new_gold < 0 THEN
        RAISE EXCEPTION 'The character does not have enough currency for this transaction.';
    END IF;

    UPDATE public.discord_characters c
    SET gold = v_new_gold,
        character_data = COALESCE(c.character_data, '{}'::jsonb)
            || jsonb_build_object('gold', v_new_gold),
        updated_at = NOW()
    WHERE c.character_id = p_character_id
      AND c.campaign_id = p_campaign_id;

    RETURN v_new_gold;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_adjust_currency_value(UUID, UUID, NUMERIC)
FROM PUBLIC, anon, authenticated, service_role;

-- Replace Build 6.6's Sell RPC so fractional resale value uses the exact currency
-- helper instead of the old integer-only GM gold function.
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

    -- Enforce copper-piece precision. For example 0.50 GP = 5 SP and
    -- 0.01 GP = 1 CP are valid; fractions below one copper are not.
    IF ABS(p_unit_price_gp - ROUND(p_unit_price_gp, 2)) >= 0.000001 THEN
        RAISE EXCEPTION 'Merchant offers must resolve to whole copper pieces.';
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

    -- Inventory removal and currency credit are in the same outer transaction.
    -- If either operation fails, PostgreSQL rolls both back.
    v_remaining := public.discord_remove_inventory_quantity(
        p_player_id,
        p_campaign_id,
        p_inventory_item_id,
        p_quantity
    );

    v_total_price := ROUND(p_unit_price_gp * p_quantity, 2);
    v_remaining_gold := public.discord_adjust_currency_value(
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
        'unit_price_gp', ROUND(p_unit_price_gp, 2),
        'total_price_gp', v_total_price,
        'remaining_gold', v_remaining_gold
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_sell_settlement_item(UUID, UUID, TEXT, TEXT, UUID, TEXT, INTEGER, NUMERIC, TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discord_sell_settlement_item(UUID, UUID, TEXT, TEXT, UUID, TEXT, INTEGER, NUMERIC, TEXT)
TO service_role;

COMMENT ON FUNCTION public.discord_adjust_currency_value(UUID, UUID, NUMERIC) IS
'Build 6.6.1 internal exact currency helper. 0.01 GP = 1 CP.';
COMMENT ON FUNCTION public.discord_sell_settlement_item(UUID, UUID, TEXT, TEXT, UUID, TEXT, INTEGER, NUMERIC, TEXT) IS
'Build 6.6.1 shop sale with exact PP/GP/SP/CP-equivalent currency credit.';

COMMIT;
