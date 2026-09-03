-- ============================================================
-- RabuShinAIGM Rules Build 6.10
-- Persistent ration packs with 3 unnamed portions per day.
-- 1/3/5/7-day packs = 3/9/15/21 uses; each use restores
-- exactly 33 Hunger percentage points, capped at 100%.
-- Safe to run more than once. Requires Build 6.8 survival and
-- is designed to follow Build 6.9 migration 30.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_ration_state
(
    inventory_item_id UUID PRIMARY KEY
        REFERENCES public.discord_inventory_items(inventory_item_id) ON DELETE CASCADE,
    character_id UUID NOT NULL
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    day_count INTEGER NOT NULL
        CHECK (day_count IN (1, 3, 5, 7)),
    portions_remaining INTEGER NOT NULL
        CHECK (portions_remaining BETWEEN 0 AND 21),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_discord_ration_portions_for_size CHECK (
        portions_remaining <= day_count * 3
    )
);

CREATE INDEX IF NOT EXISTS ix_discord_ration_character
    ON public.discord_ration_state(character_id);
CREATE INDEX IF NOT EXISTS ix_discord_ration_campaign
    ON public.discord_ration_state(campaign_id);

ALTER TABLE public.discord_ration_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_ration_state FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_ration_state TO service_role;

-- Recognizes any food prefix followed by Ration/Rations and one of the
-- authoritative day counts. Examples: Ration (1 day), Rations (5 days),
-- Dried Fish Rations (7 days), Elven Rations (3 days).
CREATE OR REPLACE FUNCTION public.discord_ration_days_from_name(p_item_name TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_name TEXT := LOWER(TRIM(COALESCE(p_item_name, '')));
BEGIN
    IF v_name ~ 'rations?[[:space:]]*\([[:space:]]*1[[:space:]]+days?[[:space:]]*\)[[:space:]]*$' THEN RETURN 1; END IF;
    IF v_name ~ 'rations?[[:space:]]*\([[:space:]]*3[[:space:]]+days?[[:space:]]*\)[[:space:]]*$' THEN RETURN 3; END IF;
    IF v_name ~ 'rations?[[:space:]]*\([[:space:]]*5[[:space:]]+days?[[:space:]]*\)[[:space:]]*$' THEN RETURN 5; END IF;
    IF v_name ~ 'rations?[[:space:]]*\([[:space:]]*7[[:space:]]+days?[[:space:]]*\)[[:space:]]*$' THEN RETURN 7; END IF;
    RETURN NULL;
END;
$$;

-- Existing ration stacks predate per-pack state. Keep the first row and split
-- every extra quantity into a separate quantity-one row. If the first row
-- already has a partially consumed Build 6.10 state, ON CONFLICT preserves it.
DO $$
DECLARE
    v_item RECORD;
    v_copy_id UUID;
    v_number INTEGER;
    v_days INTEGER;
BEGIN
    FOR v_item IN
        SELECT i.*
        FROM public.discord_inventory_items i
        WHERE public.discord_ration_days_from_name(i.item_name) IS NOT NULL
        ORDER BY i.created_at, i.inventory_item_id
    LOOP
        v_days := public.discord_ration_days_from_name(v_item.item_name);

        IF v_item.quantity > 1 THEN
            UPDATE public.discord_inventory_items AS dii
            SET quantity = 1, updated_at = NOW()
            WHERE dii.inventory_item_id = v_item.inventory_item_id;

            FOR v_number IN 2..v_item.quantity LOOP
                INSERT INTO public.discord_inventory_items(
                    character_id, item_name, quantity, equipped, attuned,
                    source_name, notes, item_data, created_at, updated_at)
                VALUES(
                    v_item.character_id, v_item.item_name, 1, FALSE, FALSE,
                    v_item.source_name, v_item.notes, v_item.item_data, NOW(), NOW())
                RETURNING inventory_item_id INTO v_copy_id;

                INSERT INTO public.discord_ration_state(
                    inventory_item_id, character_id, campaign_id,
                    day_count, portions_remaining)
                SELECT v_copy_id, c.character_id, c.campaign_id,
                       v_days, v_days * 3
                FROM public.discord_characters c
                WHERE c.character_id = v_item.character_id;
            END LOOP;
        END IF;

        INSERT INTO public.discord_ration_state(
            inventory_item_id, character_id, campaign_id,
            day_count, portions_remaining)
        SELECT v_item.inventory_item_id, c.character_id, c.campaign_id,
               v_days, v_days * 3
        FROM public.discord_characters c
        WHERE c.character_id = v_item.character_id
        ON CONFLICT ON CONSTRAINT discord_ration_state_pkey DO NOTHING;
    END LOOP;
END;
$$;

-- Hydrates ration state and also handles new shop/GM purchases made after the
-- migration. Normal inventory code may stack identical names; this function
-- turns those stacks back into independent packs without resetting a partially
-- eaten original pack.
DROP FUNCTION IF EXISTS public.discord_get_ration_states(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_ration_states(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    inventory_item_id UUID,
    character_id UUID,
    campaign_id UUID,
    day_count INTEGER,
    portions_remaining INTEGER,
    maximum_portions INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_item RECORD;
    v_copy_id UUID;
    v_number INTEGER;
    v_days INTEGER;
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

    FOR v_item IN
        SELECT i.*
        FROM public.discord_inventory_items i
        WHERE i.character_id = v_character_id
          AND public.discord_ration_days_from_name(i.item_name) IS NOT NULL
        ORDER BY i.created_at, i.inventory_item_id
        FOR UPDATE
    LOOP
        v_days := public.discord_ration_days_from_name(v_item.item_name);

        IF v_item.quantity > 1 THEN
            UPDATE public.discord_inventory_items AS dii
            SET quantity = 1, updated_at = NOW()
            WHERE dii.inventory_item_id = v_item.inventory_item_id;

            FOR v_number IN 2..v_item.quantity LOOP
                INSERT INTO public.discord_inventory_items(
                    character_id, item_name, quantity, equipped, attuned,
                    source_name, notes, item_data, created_at, updated_at)
                VALUES(
                    v_item.character_id, v_item.item_name, 1, FALSE, FALSE,
                    v_item.source_name, v_item.notes, v_item.item_data, NOW(), NOW())
                RETURNING inventory_item_id INTO v_copy_id;

                INSERT INTO public.discord_ration_state(
                    inventory_item_id, character_id, campaign_id,
                    day_count, portions_remaining)
                VALUES(v_copy_id, v_character_id, p_campaign_id, v_days, v_days * 3);
            END LOOP;
        END IF;

        INSERT INTO public.discord_ration_state(
            inventory_item_id, character_id, campaign_id,
            day_count, portions_remaining)
        VALUES(v_item.inventory_item_id, v_character_id, p_campaign_id, v_days, v_days * 3)
        ON CONFLICT ON CONSTRAINT discord_ration_state_pkey DO NOTHING;
    END LOOP;

    RETURN QUERY
    SELECT rs.inventory_item_id, rs.character_id, rs.campaign_id,
           rs.day_count, rs.portions_remaining, rs.day_count * 3
    FROM public.discord_ration_state rs
    JOIN public.discord_inventory_items i ON i.inventory_item_id = rs.inventory_item_id
    WHERE rs.character_id = v_character_id
      AND rs.campaign_id = p_campaign_id
    ORDER BY i.created_at, rs.inventory_item_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_eat_ration_portion(UUID, UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_eat_ration_portion(
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
    v_item_name TEXT;
    v_days INTEGER;
    v_portions INTEGER;
    v_remaining INTEGER;
    v_maximum INTEGER;
    v_enabled BOOLEAN;
    v_state RECORD;
    v_hunger_before NUMERIC;
    v_hunger_after NUMERIC;
    v_restored NUMERIC;
    v_pack_consumed BOOLEAN;
BEGIN
    SELECT c.character_id, c.character_name
    INTO v_character_id, v_character_name
    FROM public.discord_characters c
    JOIN public.discord_campaign_members m
      ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.campaign_id = p_campaign_id AND c.player_id = p_player_id
    LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    -- Lazy initialization covers a ration acquired after the last inventory read.
    SELECT public.discord_ration_days_from_name(i.item_name), i.item_name
    INTO v_days, v_item_name
    FROM public.discord_inventory_items i
    WHERE i.inventory_item_id = p_inventory_item_id
      AND i.character_id = v_character_id
    FOR UPDATE;
    IF NOT FOUND OR v_days IS NULL THEN
        RAISE EXCEPTION 'Ration pack could not be found in this character''s inventory.';
    END IF;

    INSERT INTO public.discord_ration_state(
        inventory_item_id, character_id, campaign_id, day_count, portions_remaining)
    VALUES(p_inventory_item_id, v_character_id, p_campaign_id, v_days, v_days * 3)
    ON CONFLICT ON CONSTRAINT discord_ration_state_pkey DO NOTHING;

    SELECT rs.day_count, rs.portions_remaining
    INTO v_days, v_portions
    FROM public.discord_ration_state rs
    WHERE rs.inventory_item_id = p_inventory_item_id
      AND rs.character_id = v_character_id
      AND rs.campaign_id = p_campaign_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Ration state could not be loaded.'; END IF;
    IF v_portions <= 0 THEN RAISE EXCEPTION 'That ration pack has no portions remaining.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled INTO v_enabled
    FROM public.discord_campaign_survival_settings s
    WHERE s.campaign_id = p_campaign_id;
    IF NOT COALESCE(v_enabled, FALSE) THEN
        RAISE EXCEPTION 'Hunger and Thirst rules are disabled for this campaign.';
    END IF;

    INSERT INTO public.discord_character_survival(character_id, campaign_id)
    VALUES(v_character_id, p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
    SELECT * INTO v_state
    FROM public.discord_character_survival cs
    WHERE cs.character_id = v_character_id
    FOR UPDATE;

    v_hunger_before := ROUND(LEAST(100.0, GREATEST(0.0, v_state.food_credit_lb * 100.0)), 1);

    UPDATE public.discord_character_survival cs
    SET food_credit_lb = LEAST(1.0, cs.food_credit_lb + 0.33),
        food_deficit_hours = 0,
        last_reason = 'Ate one portion from a ration pack.',
        updated_at = NOW()
    WHERE cs.character_id = v_character_id
    RETURNING * INTO v_state;

    v_hunger_after := ROUND(LEAST(100.0, GREATEST(0.0, v_state.food_credit_lb * 100.0)), 1);
    v_restored := ROUND(v_hunger_after - v_hunger_before, 1);
    v_remaining := v_portions - 1;
    v_maximum := v_days * 3;
    v_pack_consumed := v_remaining <= 0;

    IF v_pack_consumed THEN
        -- Deleting the inventory row cascades the ration state row.
        DELETE FROM public.discord_inventory_items AS dii
        WHERE dii.inventory_item_id = p_inventory_item_id
          AND dii.character_id = v_character_id;
    ELSE
        UPDATE public.discord_ration_state rs
        SET portions_remaining = v_remaining,
            updated_at = NOW()
        WHERE rs.inventory_item_id = p_inventory_item_id;
    END IF;

    RETURN jsonb_build_object(
        'success', TRUE,
        'inventoryItemId', p_inventory_item_id,
        'itemName', v_item_name,
        'dayCount', v_days,
        'portionsRemaining', GREATEST(0, v_remaining),
        'maximumPortions', v_maximum,
        'hungerPercentBefore', v_hunger_before,
        'hungerPercentAfter', v_hunger_after,
        'hungerPercentRestored', v_restored,
        'packConsumed', v_pack_consumed,
        'message', CASE
            WHEN v_pack_consumed THEN FORMAT('%s ate one ration portion. Hunger is now %s%%. The ration pack is finished.', v_character_name, v_hunger_after)
            ELSE FORMAT('%s ate one ration portion. Hunger is now %s%%. %s of %s portions remain.', v_character_name, v_hunger_after, v_remaining, v_maximum)
        END
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_ration_days_from_name(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_get_ration_states(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_eat_ration_portion(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_ration_days_from_name(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_ration_states(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_eat_ration_portion(UUID, UUID, UUID) TO service_role;

COMMIT;
