-- ============================================================
-- RabuShinAIGM Rules Build 6.9
-- Persistent individual waterskins, 30-drink capacity, drinking,
-- tainted water, boiling, source filling, and magic purification.
-- Safe to run more than once. Requires Build 6.8 migration 27/28.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_waterskin_state
(
    inventory_item_id UUID PRIMARY KEY
        REFERENCES public.discord_inventory_items(inventory_item_id) ON DELETE CASCADE,
    character_id UUID NOT NULL
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    waterskin_kind TEXT NOT NULL DEFAULT 'basic'
        CHECK (waterskin_kind IN ('basic', 'magic')),
    drinks_remaining INTEGER NOT NULL DEFAULT 0
        CHECK (drinks_remaining BETWEEN 0 AND 30),
    water_quality TEXT NOT NULL DEFAULT 'empty'
        CHECK (water_quality IN ('empty', 'clean', 'tainted')),
    source_name TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_discord_waterskin_contents CHECK (
        (drinks_remaining = 0 AND water_quality = 'empty') OR
        (drinks_remaining > 0 AND water_quality IN ('clean', 'tainted'))
    )
);

CREATE INDEX IF NOT EXISTS ix_discord_waterskin_character
    ON public.discord_waterskin_state(character_id);
CREATE INDEX IF NOT EXISTS ix_discord_waterskin_campaign
    ON public.discord_waterskin_state(campaign_id);

ALTER TABLE public.discord_waterskin_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_waterskin_state FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_waterskin_state TO service_role;

-- Existing waterskin stacks predate individual container state. Preserve the
-- first item and split each additional quantity into its own inventory row.
DO $$
DECLARE
    v_item RECORD;
    v_copy_id UUID;
    v_number INTEGER;
    v_normalized TEXT;
    v_kind TEXT;
    v_quality TEXT;
    v_drinks INTEGER;
BEGIN
    FOR v_item IN
        SELECT i.*
        FROM public.discord_inventory_items i
        WHERE TRIM(REGEXP_REPLACE(LOWER(TRIM(i.item_name)), '[^a-z0-9]+', ' ', 'g')) IN (
            'waterskin', 'waterskin full', 'full waterskin', 'waterskin tainted',
            'magic waterskin', 'magic waterskin full', 'full magic waterskin'
        )
        ORDER BY i.created_at, i.inventory_item_id
    LOOP
        v_normalized := TRIM(REGEXP_REPLACE(LOWER(TRIM(v_item.item_name)), '[^a-z0-9]+', ' ', 'g'));
        v_kind := CASE WHEN v_normalized LIKE '%magic%' THEN 'magic' ELSE 'basic' END;
        v_quality := CASE
            WHEN v_normalized = 'waterskin tainted' THEN 'tainted'
            WHEN v_normalized IN ('waterskin full', 'full waterskin', 'magic waterskin full', 'full magic waterskin') THEN 'clean'
            ELSE 'empty'
        END;
        v_drinks := CASE WHEN v_quality = 'empty' THEN 0 ELSE 30 END;

        UPDATE public.discord_inventory_items AS dii
        SET item_name = CASE WHEN v_kind = 'magic' THEN 'Magic Waterskin' ELSE 'Waterskin' END,
            updated_at = NOW()
        WHERE dii.inventory_item_id = v_item.inventory_item_id;

        IF v_item.quantity > 1 THEN
            UPDATE public.discord_inventory_items AS dii
            SET quantity = 1, updated_at = NOW()
            WHERE dii.inventory_item_id = v_item.inventory_item_id;

            FOR v_number IN 2..v_item.quantity LOOP
                INSERT INTO public.discord_inventory_items(
                    character_id, item_name, quantity, equipped, attuned,
                    source_name, notes, item_data, created_at, updated_at)
                VALUES(
                    v_item.character_id, CASE WHEN v_kind = 'magic' THEN 'Magic Waterskin' ELSE 'Waterskin' END, 1, FALSE, FALSE,
                    v_item.source_name, v_item.notes, v_item.item_data, NOW(), NOW())
                RETURNING inventory_item_id INTO v_copy_id;

                INSERT INTO public.discord_waterskin_state(
                    inventory_item_id, character_id, campaign_id, waterskin_kind,
                    drinks_remaining, water_quality, source_name)
                SELECT v_copy_id, c.character_id, c.campaign_id, v_kind,
                       v_drinks, v_quality,
                       CASE WHEN v_quality = 'empty' THEN '' ELSE v_item.source_name END
                FROM public.discord_characters c
                WHERE c.character_id = v_item.character_id;
            END LOOP;
        END IF;

        INSERT INTO public.discord_waterskin_state(
            inventory_item_id, character_id, campaign_id, waterskin_kind,
            drinks_remaining, water_quality, source_name)
        SELECT v_item.inventory_item_id, c.character_id, c.campaign_id, v_kind,
               v_drinks, v_quality,
               CASE WHEN v_quality = 'empty' THEN '' ELSE v_item.source_name END
        FROM public.discord_characters c
        WHERE c.character_id = v_item.character_id
        ON CONFLICT ON CONSTRAINT discord_waterskin_state_pkey DO NOTHING;
    END LOOP;
END;
$$;

-- Build 6.9 preserves the normal tidy stacking behavior for every other item,
-- but waterskins are always inserted as quantity-one rows so their contents
-- cannot leak into another container.
DROP FUNCTION IF EXISTS public.discord_gm_add_inventory_item(UUID, UUID, TEXT, INTEGER, TEXT, TEXT, TEXT);
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
    v_normalized TEXT;
    v_item_id UUID;
    v_quantity INTEGER;
    v_item_data JSONB;
    v_kind TEXT;
    v_quality TEXT;
    v_drinks INTEGER;
    v_index INTEGER;
    v_description TEXT;
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

    v_normalized := TRIM(REGEXP_REPLACE(LOWER(v_name), '[^a-z0-9]+', ' ', 'g'));
    IF v_normalized IN (
        'waterskin', 'waterskin full', 'full waterskin', 'waterskin tainted',
        'magic waterskin', 'magic waterskin full', 'full magic waterskin'
    ) THEN
        v_kind := CASE WHEN v_normalized LIKE '%magic%' THEN 'magic' ELSE 'basic' END;
        v_quality := CASE
            WHEN v_normalized = 'waterskin tainted' THEN 'tainted'
            WHEN v_normalized IN ('waterskin full', 'full waterskin', 'magic waterskin full', 'full magic waterskin') THEN 'clean'
            ELSE 'empty'
        END;
        v_drinks := CASE WHEN v_quality = 'empty' THEN 0 ELSE 30 END;
        v_description := TRIM(COALESCE(p_description, ''));
        IF v_description = '' THEN
            v_description := 'A durable leather water container. It holds 30 drinks, equal to 3 days of water.';
            IF v_kind = 'magic' THEN
                v_description := v_description || ' Magically purifies water. Any water that is used to fill the Magic Waterskin is purified water and safe to drink.';
            END IF;
        END IF;

        v_item_data := jsonb_strip_nulls(jsonb_build_object(
            'description', v_description,
            'gm_managed', TRUE,
            'waterskin_mechanics_version', '6.9'
        ));

        FOR v_index IN 1..p_quantity LOOP
            INSERT INTO public.discord_inventory_items(
                character_id, item_name, quantity, equipped, attuned,
                source_name, notes, item_data)
            VALUES(
                p_character_id, CASE WHEN v_kind = 'magic' THEN 'Magic Waterskin' ELSE 'Waterskin' END, 1, FALSE, FALSE,
                TRIM(COALESCE(p_source_name, '')),
                TRIM(COALESCE(p_notes, '')),
                v_item_data)
            RETURNING inventory_item_id INTO v_item_id;

            INSERT INTO public.discord_waterskin_state(
                inventory_item_id, character_id, campaign_id, waterskin_kind,
                drinks_remaining, water_quality, source_name)
            VALUES(
                v_item_id, p_character_id, p_campaign_id, v_kind,
                v_drinks, v_quality,
                CASE WHEN v_quality = 'empty' THEN '' ELSE TRIM(COALESCE(p_source_name, '')) END);
        END LOOP;

        SELECT COUNT(*)::INTEGER INTO v_quantity
        FROM public.discord_waterskin_state ws
        WHERE ws.character_id = p_character_id
          AND ws.campaign_id = p_campaign_id
          AND ws.waterskin_kind = v_kind;
        RETURN v_quantity;
    END IF;

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
        UPDATE public.discord_inventory_items AS dii
        SET quantity = v_quantity,
            source_name = CASE
                WHEN LENGTH(TRIM(COALESCE(p_source_name, ''))) > 0 THEN TRIM(p_source_name)
                ELSE dii.source_name
            END,
            notes = CASE
                WHEN LENGTH(TRIM(COALESCE(p_notes, ''))) > 0 THEN TRIM(p_notes)
                ELSE dii.notes
            END,
            item_data = COALESCE(dii.item_data, '{}'::jsonb) || v_item_data,
            updated_at = NOW()
        WHERE dii.inventory_item_id = v_item_id;
        RETURN v_quantity;
    END IF;

    INSERT INTO public.discord_inventory_items(
        character_id, item_name, quantity, equipped, attuned,
        source_name, notes, item_data)
    VALUES(
        p_character_id, v_name, p_quantity, FALSE, FALSE,
        TRIM(COALESCE(p_source_name, '')),
        TRIM(COALESCE(p_notes, '')),
        v_item_data)
    RETURNING quantity INTO v_quantity;

    RETURN v_quantity;
END;
$$;

-- Characters created after Build 6.9 can also receive waterskins in starting
-- equipment. Split only those containers; preserve the established behavior
-- and equipped flags for every other starting item.
CREATE OR REPLACE FUNCTION public.discord_set_starting_equipment(
    p_player_id UUID,
    p_campaign_id UUID,
    p_gold NUMERIC,
    p_items JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_done BOOLEAN;
    v_item JSONB;
    v_name TEXT;
    v_normalized TEXT;
    v_quantity INTEGER;
    v_index INTEGER;
    v_item_id UUID;
    v_kind TEXT;
    v_quality TEXT;
    v_drinks INTEGER;
BEGIN
    SELECT c.character_id, c.equipment_complete
    INTO v_character_id, v_done
    FROM public.discord_characters c
    JOIN public.discord_campaign_members m
      ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id
    LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF v_done THEN RAISE EXCEPTION 'Starting equipment has already been selected.'; END IF;

    DELETE FROM public.discord_inventory_items AS dii
    WHERE dii.character_id = v_character_id;

    FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
    LOOP
        v_name := TRIM(COALESCE(v_item->>'item_name', ''));
        IF v_name = '' THEN CONTINUE; END IF;
        v_quantity := GREATEST(1, COALESCE(NULLIF(v_item->>'quantity', '')::INTEGER, 1));
        v_normalized := TRIM(REGEXP_REPLACE(LOWER(v_name), '[^a-z0-9]+', ' ', 'g'));

        IF v_normalized IN (
            'waterskin', 'waterskin full', 'full waterskin', 'waterskin tainted',
            'magic waterskin', 'magic waterskin full', 'full magic waterskin'
        ) THEN
            v_kind := CASE WHEN v_normalized LIKE '%magic%' THEN 'magic' ELSE 'basic' END;
            v_quality := CASE
                WHEN v_normalized = 'waterskin tainted' THEN 'tainted'
                WHEN v_normalized IN ('waterskin full', 'full waterskin', 'magic waterskin full', 'full magic waterskin') THEN 'clean'
                ELSE 'empty'
            END;
            v_drinks := CASE WHEN v_quality = 'empty' THEN 0 ELSE 30 END;

            FOR v_index IN 1..v_quantity LOOP
                INSERT INTO public.discord_inventory_items(
                    character_id, item_name, quantity, equipped, attuned,
                    source_name, notes, item_data)
                VALUES(
                    v_character_id, CASE WHEN v_kind = 'magic' THEN 'Magic Waterskin' ELSE 'Waterskin' END, 1, FALSE, FALSE,
                    COALESCE(v_item->>'source_name', ''),
                    COALESCE(v_item->>'notes', ''),
                    v_item || jsonb_build_object('waterskin_mechanics_version', '6.9'))
                RETURNING inventory_item_id INTO v_item_id;

                INSERT INTO public.discord_waterskin_state(
                    inventory_item_id, character_id, campaign_id, waterskin_kind,
                    drinks_remaining, water_quality, source_name)
                VALUES(
                    v_item_id, v_character_id, p_campaign_id, v_kind,
                    v_drinks, v_quality,
                    CASE WHEN v_quality = 'empty' THEN '' ELSE COALESCE(v_item->>'source_name', 'Starting equipment') END);
            END LOOP;
        ELSE
            INSERT INTO public.discord_inventory_items(
                character_id, item_name, quantity, equipped, attuned,
                source_name, notes, item_data)
            VALUES(
                v_character_id,
                v_name,
                v_quantity,
                COALESCE((v_item->>'equipped')::BOOLEAN, FALSE),
                FALSE,
                COALESCE(v_item->>'source_name', ''),
                COALESCE(v_item->>'notes', ''),
                v_item);
        END IF;
    END LOOP;

    UPDATE public.discord_characters AS dc
    SET gold = GREATEST(0, COALESCE(p_gold, 0)),
        equipment_complete = TRUE,
        updated_at = NOW()
    WHERE dc.character_id = v_character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_waterskin_states(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_waterskin_states(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    inventory_item_id UUID,
    character_id UUID,
    campaign_id UUID,
    waterskin_kind TEXT,
    drinks_remaining INTEGER,
    water_quality TEXT,
    source_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id AND m.player_id = p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;

    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id = p_campaign_id AND c.player_id = p_player_id
    LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    RETURN QUERY
    SELECT ws.inventory_item_id, ws.character_id, ws.campaign_id,
           ws.waterskin_kind, ws.drinks_remaining, ws.water_quality, ws.source_name
    FROM public.discord_waterskin_state ws
    JOIN public.discord_inventory_items i ON i.inventory_item_id = ws.inventory_item_id
    WHERE ws.character_id = v_character_id
      AND ws.campaign_id = p_campaign_id
    ORDER BY i.created_at, ws.inventory_item_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_drink_waterskin(UUID, UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_drink_waterskin(
    p_player_id UUID,
    p_campaign_id UUID,
    p_inventory_item_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_character_name TEXT;
    v_kind TEXT;
    v_quality TEXT;
    v_drinks INTEGER;
    v_remaining INTEGER;
    v_enabled BOOLEAN;
    v_hot BOOLEAN;
    v_water_requirement NUMERIC;
    v_water_delta NUMERIC;
    v_state RECORD;
    v_hunger_before NUMERIC;
    v_thirst_before NUMERIC;
    v_hunger_after NUMERIC;
    v_thirst_after NUMERIC;
    v_nauseated BOOLEAN;
BEGIN
    SELECT c.character_id, c.character_name
    INTO v_character_id, v_character_name
    FROM public.discord_characters c
    JOIN public.discord_campaign_members m
      ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.campaign_id = p_campaign_id AND c.player_id = p_player_id
    LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT ws.waterskin_kind, ws.water_quality, ws.drinks_remaining
    INTO v_kind, v_quality, v_drinks
    FROM public.discord_waterskin_state ws
    JOIN public.discord_inventory_items i ON i.inventory_item_id = ws.inventory_item_id
    WHERE ws.inventory_item_id = p_inventory_item_id
      AND ws.character_id = v_character_id
      AND ws.campaign_id = p_campaign_id
      AND i.character_id = v_character_id
    FOR UPDATE OF ws;
    IF NOT FOUND THEN RAISE EXCEPTION 'Waterskin could not be found in this character''s inventory.'; END IF;
    IF v_drinks <= 0 OR v_quality = 'empty' THEN RAISE EXCEPTION 'That waterskin is empty.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled, s.hot_weather INTO v_enabled, v_hot
    FROM public.discord_campaign_survival_settings s
    WHERE s.campaign_id = p_campaign_id;
    IF NOT COALESCE(v_enabled, FALSE) THEN
        RAISE EXCEPTION 'Hunger and Thirst rules are disabled for this campaign.';
    END IF;

    v_water_requirement := CASE WHEN v_hot THEN 2.0 ELSE 1.0 END;
    v_water_delta := v_water_requirement * CASE WHEN v_quality = 'tainted' THEN 0.01 ELSE 0.10 END;
    v_nauseated := v_quality = 'tainted';

    INSERT INTO public.discord_character_survival(character_id, campaign_id)
    VALUES(v_character_id, p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
    SELECT * INTO v_state
    FROM public.discord_character_survival cs
    WHERE cs.character_id = v_character_id
    FOR UPDATE;

    v_hunger_before := ROUND(LEAST(100.0, GREATEST(0.0, v_state.food_credit_lb * 100.0)), 1);
    v_thirst_before := ROUND(LEAST(100.0, GREATEST(0.0, v_state.water_credit_gal / v_water_requirement * 100.0)), 1);

    UPDATE public.discord_character_survival cs
    SET food_credit_lb = CASE
            WHEN v_nauseated THEN GREATEST(0.0, cs.food_credit_lb - 0.30)
            ELSE cs.food_credit_lb
        END,
        water_credit_gal = LEAST(v_water_requirement, cs.water_credit_gal + v_water_delta),
        water_deficit_hours = 0,
        last_reason = CASE
            WHEN v_nauseated THEN 'Drank tainted waterskin water; nausea applied.'
            ELSE 'Drank one waterskin serving.'
        END,
        updated_at = NOW()
    WHERE cs.character_id = v_character_id
    RETURNING * INTO v_state;

    v_remaining := v_drinks - 1;
    UPDATE public.discord_waterskin_state ws
    SET drinks_remaining = v_remaining,
        water_quality = CASE WHEN v_remaining = 0 THEN 'empty' ELSE ws.water_quality END,
        source_name = CASE WHEN v_remaining = 0 THEN '' ELSE ws.source_name END,
        updated_at = NOW()
    WHERE ws.inventory_item_id = p_inventory_item_id;

    v_hunger_after := ROUND(LEAST(100.0, GREATEST(0.0, v_state.food_credit_lb * 100.0)), 1);
    v_thirst_after := ROUND(LEAST(100.0, GREATEST(0.0, v_state.water_credit_gal / v_water_requirement * 100.0)), 1);

    RETURN jsonb_build_object(
        'success', TRUE,
        'inventoryItemId', p_inventory_item_id,
        'itemName', CASE WHEN v_kind = 'magic' THEN 'Magic Waterskin'
                         WHEN v_quality = 'tainted' THEN 'Waterskin(Tainted)'
                         ELSE 'Waterskin' END,
        'waterskinKind', v_kind,
        'waterQuality', v_quality,
        'drinksRemaining', v_remaining,
        'thirstPercentBefore', v_thirst_before,
        'thirstPercentAfter', v_thirst_after,
        'hungerPercentBefore', v_hunger_before,
        'hungerPercentAfter', v_hunger_after,
        'nauseated', v_nauseated,
        'message', CASE WHEN v_nauseated
            THEN FORMAT('%s drank tainted water, became nauseated, lost 30%% Hunger, and gained 1%% Thirst. %s drink(s) remain.', v_character_name, v_remaining)
            ELSE FORMAT('%s drank from the waterskin and gained 10%% Thirst. %s drink(s) remain.', v_character_name, v_remaining)
        END
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_fill_waterskin(UUID, UUID, UUID, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_fill_waterskin(
    p_campaign_id UUID,
    p_character_id UUID,
    p_inventory_item_id UUID,
    p_source_name TEXT,
    p_source_quality TEXT,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind TEXT;
    v_drinks INTEGER;
    v_requested_quality TEXT;
    v_final_quality TEXT;
    v_source TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_characters c
        WHERE c.character_id = p_character_id AND c.campaign_id = p_campaign_id
    ) THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT ws.waterskin_kind, ws.drinks_remaining
    INTO v_kind, v_drinks
    FROM public.discord_waterskin_state ws
    JOIN public.discord_inventory_items i ON i.inventory_item_id = ws.inventory_item_id
    WHERE ws.inventory_item_id = p_inventory_item_id
      AND ws.character_id = p_character_id
      AND ws.campaign_id = p_campaign_id
      AND i.character_id = p_character_id
    FOR UPDATE OF ws;
    IF NOT FOUND THEN RAISE EXCEPTION 'Waterskin could not be found in this character''s inventory.'; END IF;
    IF v_drinks > 0 THEN RAISE EXCEPTION 'The waterskin must be empty before it can be filled.'; END IF;

    v_source := LEFT(TRIM(COALESCE(p_source_name, 'water source')), 120);
    IF v_source = '' THEN v_source := 'water source'; END IF;
    v_requested_quality := LOWER(TRIM(COALESCE(p_source_quality, 'questionable')));
    IF v_requested_quality NOT IN ('clean', 'questionable', 'tainted') THEN
        RAISE EXCEPTION 'Water source quality must be clean or questionable.';
    END IF;
    v_final_quality := CASE
        WHEN v_kind = 'magic' THEN 'clean'
        WHEN v_requested_quality = 'clean' THEN 'clean'
        ELSE 'tainted'
    END;

    UPDATE public.discord_waterskin_state ws
    SET drinks_remaining = 30,
        water_quality = v_final_quality,
        source_name = v_source,
        updated_at = NOW()
    WHERE ws.inventory_item_id = p_inventory_item_id;

    RETURN jsonb_build_object(
        'authoritative', TRUE,
        'action', 'fill_waterskin',
        'inventoryItemId', p_inventory_item_id,
        'itemName', CASE WHEN v_kind = 'magic' THEN 'Magic Waterskin'
                         WHEN v_final_quality = 'tainted' THEN 'Waterskin(Tainted)'
                         ELSE 'Waterskin' END,
        'waterskinKind', v_kind,
        'drinksRemaining', 30,
        'waterQuality', v_final_quality,
        'sourceName', v_source,
        'purifiedByMagic', v_kind = 'magic' AND v_requested_quality <> 'clean',
        'reason', LEFT(TRIM(COALESCE(p_reason, '')), 200)
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_boil_waterskin(UUID, UUID, UUID, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_boil_waterskin(
    p_campaign_id UUID,
    p_character_id UUID,
    p_inventory_item_id UUID,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind TEXT;
    v_quality TEXT;
    v_drinks INTEGER;
    v_source TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_characters c
        WHERE c.character_id = p_character_id AND c.campaign_id = p_campaign_id
    ) THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT ws.waterskin_kind, ws.water_quality, ws.drinks_remaining, ws.source_name
    INTO v_kind, v_quality, v_drinks, v_source
    FROM public.discord_waterskin_state ws
    JOIN public.discord_inventory_items i ON i.inventory_item_id = ws.inventory_item_id
    WHERE ws.inventory_item_id = p_inventory_item_id
      AND ws.character_id = p_character_id
      AND ws.campaign_id = p_campaign_id
      AND i.character_id = p_character_id
    FOR UPDATE OF ws;
    IF NOT FOUND THEN RAISE EXCEPTION 'Waterskin could not be found in this character''s inventory.'; END IF;
    IF v_kind = 'magic' THEN RAISE EXCEPTION 'Magic Waterskin water is already purified.'; END IF;
    IF v_drinks <= 0 THEN RAISE EXCEPTION 'The waterskin is empty.'; END IF;
    IF v_quality <> 'tainted' THEN RAISE EXCEPTION 'The water in this waterskin is already safe to drink.'; END IF;

    UPDATE public.discord_waterskin_state ws
    SET water_quality = 'clean',
        source_name = LEFT('Boiled ' || COALESCE(NULLIF(v_source, ''), 'water'), 120),
        updated_at = NOW()
    WHERE ws.inventory_item_id = p_inventory_item_id;

    RETURN jsonb_build_object(
        'authoritative', TRUE,
        'action', 'boil_waterskin',
        'inventoryItemId', p_inventory_item_id,
        'itemName', 'Waterskin',
        'waterskinKind', 'basic',
        'drinksRemaining', v_drinks,
        'waterQuality', 'clean',
        'sourceName', LEFT('Boiled ' || COALESCE(NULLIF(v_source, ''), 'water'), 120),
        'reason', LEFT(TRIM(COALESCE(p_reason, '')), 200)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_gm_add_inventory_item(UUID, UUID, TEXT, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_set_starting_equipment(UUID, UUID, NUMERIC, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_get_waterskin_states(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_drink_waterskin(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_fill_waterskin(UUID, UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_boil_waterskin(UUID, UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_gm_add_inventory_item(UUID, UUID, TEXT, INTEGER, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_starting_equipment(UUID, UUID, NUMERIC, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_waterskin_states(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_drink_waterskin(UUID, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_fill_waterskin(UUID, UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_boil_waterskin(UUID, UUID, UUID, TEXT) TO service_role;

COMMENT ON TABLE public.discord_waterskin_state IS
'Build 6.9 authoritative per-container waterskin contents: 30 drinks, quality, and fill source.';

NOTIFY pgrst, 'reload schema';

COMMIT;
