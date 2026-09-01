-- ============================================================
-- RabuShin Discord - Authoritative GM Inventory / Currency State
-- Safe additive upgrade. Does not delete campaigns or inventory.
-- ============================================================

CREATE OR REPLACE FUNCTION public.discord_gm_adjust_gold(
    p_character_id UUID,
    p_campaign_id UUID,
    p_delta INTEGER
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_gold NUMERIC;
    v_new_gold NUMERIC;
BEGIN
    IF p_character_id IS NULL OR p_campaign_id IS NULL THEN
        RAISE EXCEPTION 'Character and campaign are required.';
    END IF;

    IF COALESCE(p_delta, 0) = 0 THEN
        SELECT c.gold INTO v_gold
        FROM public.discord_characters c
        WHERE c.character_id = p_character_id
          AND c.campaign_id = p_campaign_id;
        IF v_gold IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
        RETURN v_gold;
    END IF;

    IF ABS(p_delta) > 1000000 THEN
        RAISE EXCEPTION 'GP adjustment is outside the allowed range.';
    END IF;

    SELECT c.gold INTO v_gold
    FROM public.discord_characters c
    WHERE c.character_id = p_character_id
      AND c.campaign_id = p_campaign_id
    FOR UPDATE;

    IF v_gold IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    v_new_gold := v_gold + p_delta;
    IF v_new_gold < 0 THEN
        RAISE EXCEPTION 'The character does not have enough GP for this transaction.';
    END IF;

    UPDATE public.discord_characters
    SET gold = v_new_gold,
        updated_at = NOW()
    WHERE character_id = p_character_id
      AND campaign_id = p_campaign_id;

    RETURN v_new_gold;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_add_inventory_item(
    p_character_id UUID,
    p_campaign_id UUID,
    p_item_name TEXT,
    p_quantity INTEGER,
    p_description TEXT DEFAULT '',
    p_source_name TEXT DEFAULT '',
    p_notes TEXT DEFAULT ''
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_name TEXT;
    v_item_id UUID;
    v_quantity INTEGER;
    v_item_data JSONB;
BEGIN
    v_name := TRIM(COALESCE(p_item_name, ''));
    IF LENGTH(v_name) = 0 THEN RAISE EXCEPTION 'Item name is required.'; END IF;
    IF LENGTH(v_name) > 120 THEN RAISE EXCEPTION 'Item name is too long.'; END IF;
    IF COALESCE(p_quantity, 0) < 1 OR p_quantity > 1000 THEN
        RAISE EXCEPTION 'Item quantity must be between 1 and 1000.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.discord_characters c
        WHERE c.character_id = p_character_id
          AND c.campaign_id = p_campaign_id
    ) THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    -- Prefer an unequipped existing stack of the same item. This keeps common
    -- loot such as pelts, rations, arrows, and potions tidy in the inventory.
    SELECT i.inventory_item_id, i.quantity
    INTO v_item_id, v_quantity
    FROM public.discord_inventory_items i
    WHERE i.character_id = p_character_id
      AND LOWER(TRIM(i.item_name)) = LOWER(v_name)
      AND i.equipped = FALSE
    ORDER BY i.created_at
    LIMIT 1
    FOR UPDATE;

    v_item_data := jsonb_strip_nulls(jsonb_build_object(
        'description', NULLIF(TRIM(COALESCE(p_description, '')), ''),
        'gm_managed', TRUE
    ));

    IF v_item_id IS NOT NULL THEN
        v_quantity := v_quantity + p_quantity;
        UPDATE public.discord_inventory_items
        SET quantity = v_quantity,
            source_name = CASE
                WHEN LENGTH(TRIM(COALESCE(p_source_name, ''))) > 0 THEN TRIM(p_source_name)
                ELSE source_name
            END,
            notes = CASE
                WHEN LENGTH(TRIM(COALESCE(p_notes, ''))) > 0 THEN TRIM(p_notes)
                ELSE notes
            END,
            item_data = COALESCE(item_data, '{}'::jsonb) || v_item_data,
            updated_at = NOW()
        WHERE inventory_item_id = v_item_id;
        RETURN v_quantity;
    END IF;

    INSERT INTO public.discord_inventory_items(
        character_id, item_name, quantity, equipped, attuned,
        source_name, notes, item_data
    )
    VALUES(
        p_character_id,
        v_name,
        p_quantity,
        FALSE,
        FALSE,
        TRIM(COALESCE(p_source_name, '')),
        TRIM(COALESCE(p_notes, '')),
        v_item_data
    )
    RETURNING quantity INTO v_quantity;

    RETURN v_quantity;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_remove_inventory_item(
    p_character_id UUID,
    p_campaign_id UUID,
    p_item_name TEXT,
    p_quantity INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_name TEXT;
    v_total INTEGER;
    v_to_remove INTEGER;
    v_take INTEGER;
    v_row RECORD;
BEGIN
    v_name := TRIM(COALESCE(p_item_name, ''));
    IF LENGTH(v_name) = 0 THEN RAISE EXCEPTION 'Item name is required.'; END IF;
    IF COALESCE(p_quantity, 0) < 1 OR p_quantity > 1000 THEN
        RAISE EXCEPTION 'Item quantity must be between 1 and 1000.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.discord_characters c
        WHERE c.character_id = p_character_id
          AND c.campaign_id = p_campaign_id
    ) THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    SELECT COALESCE(SUM(i.quantity), 0)::INTEGER
    INTO v_total
    FROM public.discord_inventory_items i
    WHERE i.character_id = p_character_id
      AND LOWER(TRIM(i.item_name)) = LOWER(v_name);

    IF v_total < p_quantity THEN
        RAISE EXCEPTION 'The character does not carry enough %.', v_name;
    END IF;

    v_to_remove := p_quantity;

    -- Consume unequipped stacks first, then equipped stacks only if necessary.
    FOR v_row IN
        SELECT i.inventory_item_id, i.quantity
        FROM public.discord_inventory_items i
        WHERE i.character_id = p_character_id
          AND LOWER(TRIM(i.item_name)) = LOWER(v_name)
        ORDER BY i.equipped ASC, i.created_at ASC
        FOR UPDATE
    LOOP
        EXIT WHEN v_to_remove <= 0;
        v_take := LEAST(v_row.quantity, v_to_remove);

        IF v_take >= v_row.quantity THEN
            DELETE FROM public.discord_inventory_items
            WHERE inventory_item_id = v_row.inventory_item_id;
        ELSE
            UPDATE public.discord_inventory_items
            SET quantity = quantity - v_take,
                updated_at = NOW()
            WHERE inventory_item_id = v_row.inventory_item_id;
        END IF;

        v_to_remove := v_to_remove - v_take;
    END LOOP;

    RETURN v_total - p_quantity;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_gm_adjust_gold(UUID, UUID, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_gm_add_inventory_item(UUID, UUID, TEXT, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_gm_remove_inventory_item(UUID, UUID, TEXT, INTEGER) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.discord_gm_adjust_gold(UUID, UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_add_inventory_item(UUID, UUID, TEXT, INTEGER, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_remove_inventory_item(UUID, UUID, TEXT, INTEGER) TO service_role;
