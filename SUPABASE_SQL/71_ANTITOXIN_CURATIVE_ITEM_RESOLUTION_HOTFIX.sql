-- ============================================================
-- RabuShinAIGM Build 6.30.11.1
-- Migration 71 - Antitoxin / Curative Item Resolution Hotfix
--
-- Fixes:
--   * Antitoxin is recognized by RabuShin as a cure for Poisoned.
--   * Curative items can be resolved by exact/normalized item name when
--     the AI GM does not have a usable inventoryItemId.
--   * A valid inventoryItemId still wins when supplied.
--   * If neither id nor name is supplied, a single carried curative
--     stack may be resolved automatically; ambiguous inventories are rejected.
--
-- Run AFTER the Build 6.30.11.1 source hotfix succeeds.
-- Safe to rerun.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_condition_builtin_cures(p_item_name TEXT)
RETURNS TEXT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v TEXT:=lower(trim(COALESCE(p_item_name,'')));
BEGIN
    IF v LIKE '%potion of lesser restoration%' OR v LIKE '%lesser restoration potion%' THEN
        RETURN ARRAY['blinded','deafened','paralyzed','poisoned']::TEXT[];
    ELSIF v LIKE '%potion of greater restoration%' OR v LIKE '%greater restoration potion%' THEN
        RETURN ARRAY['charmed','petrified']::TEXT[];
    ELSIF v LIKE '%potion of cure poison%'
       OR v LIKE '%potion of neutralize poison%'
       OR v LIKE '%antidote potion%'
       OR v LIKE '%antitoxin%'
       OR v LIKE '%anti-toxin%'
       OR v LIKE '%antivenom%' THEN
        -- RabuShin homebrew behavior: Antitoxin/Antivenom cures an
        -- already-active Poisoned condition instead of only granting
        -- advantage against future poison saves.
        RETURN ARRAY['poisoned']::TEXT[];
    ELSIF v LIKE '%potion of cure blindness%' OR v LIKE '%potion of sight restoration%' THEN
        RETURN ARRAY['blinded']::TEXT[];
    ELSIF v LIKE '%potion of cure paralysis%' OR v LIKE '%potion of mobility restoration%' THEN
        RETURN ARRAY['paralyzed']::TEXT[];
    END IF;

    RETURN ARRAY[]::TEXT[];
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_condition_item_cures(
    p_item_name TEXT,
    p_item_data JSONB
)
RETURNS TEXT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_builtin TEXT[]:=public.discord_condition_builtin_cures(p_item_name);
    v_custom JSONB:=COALESCE(p_item_data,'{}'::jsonb)->'cures_conditions';
    v_result TEXT[]:=ARRAY[]::TEXT[];
BEGIN
    SELECT COALESCE(
        ARRAY(
            SELECT DISTINCT cure_name
            FROM (
                SELECT unnest(COALESCE(v_builtin,ARRAY[]::TEXT[])) AS cure_name
                UNION ALL
                SELECT public.discord_condition_normalize(value)
                FROM jsonb_array_elements_text(
                    CASE
                        WHEN jsonb_typeof(v_custom)='array' THEN v_custom
                        ELSE '[]'::jsonb
                    END
                )
            ) cures
            WHERE trim(COALESCE(cure_name,''))<>''
        ),
        ARRAY[]::TEXT[]
    )
    INTO v_result;

    RETURN v_result;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_consume_condition_cure_item_resolved(
    UUID,TEXT,UUID,TEXT,TEXT
);

CREATE OR REPLACE FUNCTION public.discord_gm_consume_condition_cure_item_resolved(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_inventory_item_id UUID,
    p_item_name TEXT,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character_id UUID;
    v_inventory_item_id UUID:=p_inventory_item_id;
    v_name TEXT:=trim(COALESCE(p_item_name,''));
    v_name_key TEXT:=regexp_replace(lower(trim(COALESCE(p_item_name,''))),'[^a-z0-9]+','','g');
    v_candidate_count INTEGER:=0;
BEGIN
    SELECT c.character_id
    INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Character not found: %',p_character_name;
    END IF;

    IF v_inventory_item_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.discord_inventory_items i
            WHERE i.inventory_item_id=v_inventory_item_id
              AND i.character_id=v_character_id
              AND COALESCE(i.quantity,0)>0
        ) THEN
            RAISE EXCEPTION 'The selected curative inventory item is not carried by this character.';
        END IF;
    ELSIF v_name<>'' THEN
        -- Exact normalized-name matching lets "AntiToxin", "Antitoxin",
        -- "Anti Toxin", and "Anti-Toxin" resolve to the same inventory name.
        SELECT COUNT(*),MIN(i.inventory_item_id)
        INTO v_candidate_count,v_inventory_item_id
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND COALESCE(i.quantity,0)>0
          AND regexp_replace(lower(trim(COALESCE(i.item_name,''))),'[^a-z0-9]+','','g')=v_name_key;

        IF v_candidate_count=0 THEN
            RAISE EXCEPTION '% is not carried by %.',v_name,p_character_name;
        END IF;
    ELSE
        -- Safe fallback for natural-language use when there is exactly one
        -- recognized curative stack in the character's inventory.
        SELECT COUNT(*),MIN(i.inventory_item_id)
        INTO v_candidate_count,v_inventory_item_id
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND COALESCE(i.quantity,0)>0
          AND COALESCE(array_length(
                public.discord_condition_item_cures(i.item_name,i.item_data),1
              ),0)>0;

        IF v_candidate_count=0 THEN
            RAISE EXCEPTION '% is not carrying a recognized curative item.',p_character_name;
        ELSIF v_candidate_count>1 THEN
            RAISE EXCEPTION 'More than one curative item is carried. Specify the item name.';
        END IF;
    END IF;

    RETURN public.discord_gm_consume_condition_cure_item(
        p_campaign_id,
        p_character_name,
        v_inventory_item_id,
        p_reason
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_condition_item_cures(TEXT,JSONB)
FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION public.discord_gm_consume_condition_cure_item_resolved(
    UUID,TEXT,UUID,TEXT,TEXT
) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_gm_consume_condition_cure_item_resolved(
    UUID,TEXT,UUID,TEXT,TEXT
) TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
