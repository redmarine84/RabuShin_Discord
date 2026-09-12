-- ============================================================
-- RabuShinAIGM Build 6.26 / Migration 62 rollback
-- Restores Build 6.22 crafting behavior and removes Build 6.26 harvest tables.
-- Existing successfully harvested/crafted inventory items are intentionally
-- NOT deleted from player inventories.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.discord_attempt_monster_harvest(UUID,UUID,UUID,INTEGER);
DROP FUNCTION IF EXISTS public.discord_get_monster_harvest_state(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_seed_monster_harvest_source(UUID,UUID,JSONB);
DROP FUNCTION IF EXISTS public.discord_get_unseeded_defeated_monsters(UUID);
DROP FUNCTION IF EXISTS public.discord_character_has_skill_proficiency(JSONB,TEXT);

DROP TABLE IF EXISTS public.discord_monster_harvest_attempts;
DROP TABLE IF EXISTS public.discord_monster_harvest_entries;
DROP TABLE IF EXISTS public.discord_monster_harvest_sources;

DELETE FROM public.discord_crafting_recipes
WHERE recipe_key IN ('field_cordage','waterskin','dragon_blood_tempering','ooze_adhesive','elemental_reagent');

CREATE OR REPLACE FUNCTION public.discord_crafting_material_family(p_item_name TEXT,p_item_data JSONB DEFAULT '{}'::jsonb)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_name TEXT:=LOWER(TRIM(COALESCE(p_item_name,'')));
BEGIN
    IF v_name='' THEN RETURN NULL; END IF;
    IF (v_name LIKE '%dragon%' AND v_name LIKE '%scale%') THEN RETURN 'dragon_scale'; END IF;
    IF v_name ~ '(healing|medicinal).*(herb|plant|root|flower|moss)' OR v_name ~ '(herb|plant|root|flower|moss).*(healing|medicinal)' OR v_name ~ '(^| )(herb|herbs)( |$)' THEN RETURN 'healing_herb'; END IF;
    IF v_name ~ '(venom|poison).*(gland|sac)' OR v_name ~ '(gland|sac).*(venom|poison)' THEN RETURN 'venom'; END IF;
    IF v_name ~ '(chitin|carapace|shell)' THEN RETURN 'chitin_shell'; END IF;
    IF v_name ~ '(bone|horn|antler|claw|talon|fang|tooth|teeth)' THEN RETURN 'bone_horn'; END IF;
    IF v_name ~ '(pelt|hide|skin)' THEN RETURN 'pelt_hide'; END IF;
    IF v_name ~ '(meat|flesh)' AND v_name NOT LIKE '%ration%' AND v_name NOT LIKE '%prepared%' THEN RETURN 'monster_meat'; END IF;
    IF v_name='vial' OR v_name LIKE '%empty vial%' OR v_name LIKE '%glass vial%' THEN RETURN 'vial'; END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_craft_recipe(p_player_id UUID,p_campaign_id UUID,p_recipe_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_player UUID;
    v_character_id UUID;
    v_character_name TEXT;
    v_recipe public.discord_crafting_recipes%ROWTYPE;
    v_req JSONB;
    v_family TEXT;
    v_needed INTEGER;
    v_available INTEGER;
    v_remaining INTEGER;
    v_take INTEGER;
    v_item RECORD;
    v_output_id UUID;
    v_consumed JSONB:='[]'::jsonb;
BEGIN
    v_player:=public.discord_resolve_active_player(p_player_id,p_campaign_id);
    SELECT c.character_id,c.character_name INTO v_character_id,v_character_name
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=v_player LIMIT 1 FOR UPDATE;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Active campaign character could not be found.'; END IF;

    SELECT * INTO v_recipe FROM public.discord_crafting_recipes r
    WHERE r.recipe_key=LOWER(TRIM(COALESCE(p_recipe_key,'')));
    IF v_recipe.recipe_key IS NULL THEN RAISE EXCEPTION 'Unknown crafting recipe.'; END IF;

    FOR v_req IN SELECT value FROM jsonb_array_elements(v_recipe.ingredients) LOOP
        v_family:=COALESCE(v_req->>'family','');
        v_needed:=GREATEST(1,COALESCE((v_req->>'quantity')::INTEGER,1));
        SELECT COALESCE(SUM(i.quantity),0)::INTEGER INTO v_available
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id AND NOT COALESCE(i.equipped,FALSE)
          AND public.discord_crafting_material_family(i.item_name,i.item_data)=v_family;
        IF v_available<v_needed THEN
            RAISE EXCEPTION 'Not enough % to craft %.',COALESCE(v_req->>'label',v_family),v_recipe.recipe_name;
        END IF;
    END LOOP;

    FOR v_req IN SELECT value FROM jsonb_array_elements(v_recipe.ingredients) LOOP
        v_family:=COALESCE(v_req->>'family','');
        v_remaining:=GREATEST(1,COALESCE((v_req->>'quantity')::INTEGER,1));
        FOR v_item IN
            SELECT i.inventory_item_id,i.item_name,i.quantity
            FROM public.discord_inventory_items i
            WHERE i.character_id=v_character_id AND NOT COALESCE(i.equipped,FALSE)
              AND public.discord_crafting_material_family(i.item_name,i.item_data)=v_family
            ORDER BY i.inventory_item_id FOR UPDATE
        LOOP
            EXIT WHEN v_remaining<=0;
            v_take:=LEAST(v_remaining,v_item.quantity);
            v_consumed:=v_consumed||jsonb_build_array(jsonb_build_object(
                'inventoryItemId',v_item.inventory_item_id,'itemName',v_item.item_name,'quantity',v_take,'family',v_family));
            IF v_take>=v_item.quantity THEN
                DELETE FROM public.discord_inventory_items WHERE inventory_item_id=v_item.inventory_item_id;
            ELSE
                UPDATE public.discord_inventory_items SET quantity=quantity-v_take WHERE inventory_item_id=v_item.inventory_item_id;
            END IF;
            v_remaining:=v_remaining-v_take;
        END LOOP;
    END LOOP;

    SELECT i.inventory_item_id INTO v_output_id
    FROM public.discord_inventory_items i
    WHERE i.character_id=v_character_id AND LOWER(i.item_name)=LOWER(v_recipe.output_item_name)
      AND NOT COALESCE(i.equipped,FALSE)
    ORDER BY i.inventory_item_id LIMIT 1 FOR UPDATE;

    IF v_output_id IS NULL THEN
        INSERT INTO public.discord_inventory_items(character_id,item_name,quantity,equipped,attuned,source_name,notes,item_data)
        VALUES(v_character_id,v_recipe.output_item_name,v_recipe.output_quantity,FALSE,FALSE,'Crafting',
               'Crafted with Build 6.22',v_recipe.output_item_data)
        RETURNING inventory_item_id INTO v_output_id;
    ELSE
        UPDATE public.discord_inventory_items
        SET quantity=quantity+v_recipe.output_quantity,
            item_data=CASE WHEN item_data='{}'::jsonb THEN v_recipe.output_item_data ELSE item_data END
        WHERE inventory_item_id=v_output_id;
    END IF;

    INSERT INTO public.discord_crafting_events(campaign_id,character_id,recipe_key,recipe_name,ingredients,output_item_name,output_quantity)
    VALUES(p_campaign_id,v_character_id,v_recipe.recipe_key,v_recipe.recipe_name,v_consumed,v_recipe.output_item_name,v_recipe.output_quantity);

    RETURN jsonb_build_object('success',TRUE,'characterId',v_character_id,'characterName',v_character_name,
        'recipeKey',v_recipe.recipe_key,'recipeName',v_recipe.recipe_name,'outputItemName',v_recipe.output_item_name,
        'outputQuantity',v_recipe.output_quantity,'inventoryItemId',v_output_id,
        'message','Crafted '||v_recipe.output_quantity::TEXT||' × '||v_recipe.output_item_name||'.');
END;
$$;

REVOKE ALL ON FUNCTION public.discord_craft_recipe(UUID,UUID,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_craft_recipe(UUID,UUID,TEXT) TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
