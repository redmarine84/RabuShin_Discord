-- ============================================================
-- RabuShinAIGM Build 6.30.11.2
-- Migration 72 - UUID Curative Resolver Hotfix
--
-- Fixes PostgreSQL error:
--   function min(uuid) does not exist
--
-- Migration 71 used an aggregate on inventory_item_id while that column
-- is UUID. This replacement resolves the candidate count first, then
-- selects the UUID with ORDER BY ... LIMIT 1.
--
-- Run AFTER Migration 71.
-- Safe to rerun.
-- ============================================================

BEGIN;

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
    v_name_key TEXT:=regexp_replace(
        lower(trim(COALESCE(p_item_name,''))),
        '[^a-z0-9]+',
        '',
        'g'
    );
    v_candidate_count INTEGER:=0;
BEGIN
    SELECT c.character_id
    INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    ORDER BY c.character_id
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
        SELECT COUNT(*)
        INTO v_candidate_count
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND COALESCE(i.quantity,0)>0
          AND regexp_replace(
                lower(trim(COALESCE(i.item_name,''))),
                '[^a-z0-9]+',
                '',
                'g'
              )=v_name_key;

        IF v_candidate_count=0 THEN
            RAISE EXCEPTION '% is not carried by %.',v_name,p_character_name;
        END IF;

        SELECT i.inventory_item_id
        INTO v_inventory_item_id
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND COALESCE(i.quantity,0)>0
          AND regexp_replace(
                lower(trim(COALESCE(i.item_name,''))),
                '[^a-z0-9]+',
                '',
                'g'
              )=v_name_key
        ORDER BY i.created_at,i.inventory_item_id
        LIMIT 1;

    ELSE
        SELECT COUNT(*)
        INTO v_candidate_count
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND COALESCE(i.quantity,0)>0
          AND COALESCE(
                array_length(
                    public.discord_condition_item_cures(i.item_name,i.item_data),
                    1
                ),
                0
              )>0;

        IF v_candidate_count=0 THEN
            RAISE EXCEPTION '% is not carrying a recognized curative item.',p_character_name;
        ELSIF v_candidate_count>1 THEN
            RAISE EXCEPTION 'More than one curative item is carried. Specify the item name.';
        END IF;

        SELECT i.inventory_item_id
        INTO v_inventory_item_id
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND COALESCE(i.quantity,0)>0
          AND COALESCE(
                array_length(
                    public.discord_condition_item_cures(i.item_name,i.item_data),
                    1
                ),
                0
              )>0
        ORDER BY i.created_at,i.inventory_item_id
        LIMIT 1;
    END IF;

    IF v_inventory_item_id IS NULL THEN
        RAISE EXCEPTION 'Unable to resolve the carried curative inventory item.';
    END IF;

    RETURN public.discord_gm_consume_condition_cure_item(
        p_campaign_id,
        p_character_name,
        v_inventory_item_id,
        p_reason
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_gm_consume_condition_cure_item_resolved(
    UUID,TEXT,UUID,TEXT,TEXT
) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_gm_consume_condition_cure_item_resolved(
    UUID,TEXT,UUID,TEXT,TEXT
) TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
