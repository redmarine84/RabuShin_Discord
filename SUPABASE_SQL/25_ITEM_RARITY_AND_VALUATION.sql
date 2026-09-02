-- RabuShinAIGM Rules Build 6.7
-- Persistent rarity/category/base-value metadata for every inventory item.
-- Requires the existing discord_inventory_items table and Build 6.6.1 currency support.
--
-- Values are stored inside item_data so this migration does not rebuild the inventory table.
-- The server classifies legacy/custom items deterministically and writes the result here.

BEGIN;

DROP FUNCTION IF EXISTS public.discord_apply_inventory_valuations(UUID, UUID, JSONB);
CREATE OR REPLACE FUNCTION public.discord_apply_inventory_valuations(
    p_player_id UUID,
    p_campaign_id UUID,
    p_items JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_item JSONB;
    v_inventory_item_id UUID;
    v_rarity TEXT;
    v_category TEXT;
    v_value_class TEXT;
    v_base_value NUMERIC;
    v_sellable BOOLEAN;
    v_priceless BOOLEAN;
    v_source TEXT;
    v_price_band TEXT;
    v_version TEXT;
    v_count INTEGER := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id
          AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    SELECT c.character_id
    INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id = p_campaign_id
      AND c.player_id = p_player_id
    LIMIT 1;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'Inventory valuation payload must be an array.';
    END IF;

    IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many inventory valuations in one request.';
    END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
    LOOP
        BEGIN
            v_inventory_item_id := NULLIF(TRIM(COALESCE(v_item->>'inventory_item_id', '')), '')::UUID;
        EXCEPTION WHEN invalid_text_representation THEN
            v_inventory_item_id := NULL;
        END;

        IF v_inventory_item_id IS NULL THEN
            CONTINUE;
        END IF;

        v_rarity := TRIM(COALESCE(v_item->>'rarity', 'Common'));
        IF v_rarity NOT IN ('Common','Uncommon','Rare','Very Rare','Legendary','Artifact') THEN
            v_rarity := 'Common';
        END IF;

        v_category := LEFT(TRIM(COALESCE(v_item->>'valuation_category', 'Miscellaneous')), 80);
        v_value_class := LEFT(TRIM(COALESCE(v_item->>'value_class', v_category)), 80);
        v_source := LEFT(TRIM(COALESCE(v_item->>'valuation_source', 'Server valuation')), 160);
        v_price_band := LEFT(TRIM(COALESCE(v_item->>'price_band', '')), 240);
        v_version := LEFT(TRIM(COALESCE(v_item->>'valuation_version', '6.7')), 20);

        BEGIN
            v_base_value := ROUND(GREATEST(COALESCE((v_item->>'base_value_gp')::NUMERIC, 0), 0), 2);
        EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            v_base_value := 0;
        END;
        IF v_base_value > 1000000 THEN v_base_value := 1000000; END IF;

        v_sellable := COALESCE((v_item->>'sellable')::BOOLEAN, TRUE);
        v_priceless := COALESCE((v_item->>'priceless')::BOOLEAN, FALSE);

        IF v_rarity = 'Artifact' OR v_priceless THEN
            v_rarity := 'Artifact';
            v_priceless := TRUE;
            v_sellable := FALSE;
            v_base_value := 0;
        END IF;

        UPDATE public.discord_inventory_items i
        SET item_data = COALESCE(i.item_data, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
                'rarity', v_rarity,
                'valuation_category', v_category,
                'value_class', v_value_class,
                'base_value_gp', v_base_value,
                'sellable', v_sellable,
                'priceless', v_priceless,
                'valuation_source', v_source,
                'price_band', v_price_band,
                'valuation_version', v_version
            )),
            updated_at = NOW()
        WHERE i.inventory_item_id = v_inventory_item_id
          AND i.character_id = v_character_id;

        IF FOUND THEN v_count := v_count + 1; END IF;
    END LOOP;

    RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_apply_inventory_valuations(UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discord_apply_inventory_valuations(UUID, UUID, JSONB) TO service_role;

COMMENT ON FUNCTION public.discord_apply_inventory_valuations(UUID, UUID, JSONB) IS
'Build 6.7 persists authoritative inventory rarity, category, base GP value, and sellability metadata.';

COMMIT;
