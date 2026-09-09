-- ============================================================
-- RabuShinAIGM Discord Rules Build 6.18.1
-- Migration 39 - Ration Portion Normalization
-- ============================================================
-- Fixes legacy inventory items created as plain "Ration" / "Rations"
-- (and named variants ending in Ration/Rations) so they participate in
-- Build 6.10's persistent portion system.
--
-- Rules:
--   explicit (1 day)  -> 3 portions
--   explicit (3 days) -> 9 portions
--   explicit (5 days) -> 15 portions
--   explicit (7 days) -> 21 portions
--   legacy bare Ration/Rations -> 1 day / 3 portions PER inventory quantity
--
-- Safe to run more than once. Existing partially consumed ration-state rows
-- are preserved. Newly split legacy stack rows start full.
-- ============================================================

BEGIN;

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

    -- Build 6.18.1 compatibility: old creation/GM paths could store plain
    -- "Rations" or a food name such as "Dried Fish Rations". With no explicit
    -- size, one inventory quantity means one day (three portions).
    IF v_name ~ '(^|.*[^[:alnum:]_])rations?[[:space:]]*$' THEN RETURN 1; END IF;

    RETURN NULL;
END;
$$;

-- Backfill all ration-like inventory rows immediately. This mirrors Build
-- 6.10's lazy hydration but also repairs characters before their next action.
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
            SET quantity = 1,
                updated_at = NOW()
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

REVOKE ALL ON FUNCTION public.discord_ration_days_from_name(TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discord_ration_days_from_name(TEXT)
TO service_role;

COMMIT;
