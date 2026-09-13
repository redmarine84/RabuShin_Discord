-- ============================================================
-- RabuShinAIGM Build 6.30.10
-- Migration 69 - Common Crafting Materials & Woodland Foraging
-- Baseline: Build 6.30.9 + Migration 68
-- ============================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.discord_crafting_material_family(
    p_item_name TEXT,
    p_item_data JSONB DEFAULT '{}'::jsonb
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_name TEXT:=LOWER(TRIM(COALESCE(p_item_name,'')));
    v_explicit TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'crafting_family','')));
BEGIN
    IF v_explicit<>'' THEN RETURN v_explicit; END IF;
    IF v_name='' THEN RETURN NULL; END IF;

    -- Build 6.30.10 common crafting materials. Measured-unit matches stay
    -- ahead of the broader legacy material patterns below.
    IF v_name='cloth' OR v_name='rag' OR v_name='rags' OR
       v_name='cloth rag' OR v_name='cloth rags' OR v_name LIKE '%cloth rag%' THEN RETURN 'cloth'; END IF;
    IF v_name='stick' OR v_name='wooden stick' OR v_name='wood stick' OR
       v_name LIKE 'stick %' OR v_name LIKE '% wooden stick' THEN RETURN 'stick'; END IF;
    IF v_name LIKE '%oil%' AND v_name LIKE '%1 oz%' THEN RETURN 'oil_oz'; END IF;
    IF v_name LIKE '%fat%' AND v_name LIKE '%1 oz%' THEN RETURN 'fat_oz'; END IF;
    IF v_name LIKE '%flax%' AND v_name LIKE '%1 lb%' THEN RETURN 'flax_lb'; END IF;
    IF v_name LIKE '%wool%' AND v_name LIKE '%1 lb%' THEN RETURN 'wool_lb'; END IF;
    IF v_name LIKE '%seed%' AND v_name LIKE '%1 lb%' THEN RETURN 'seed_lb'; END IF;
    IF (v_name LIKE '%nut%' OR v_name LIKE '%peanut%' OR v_name LIKE '%legume%' OR
        v_name LIKE '%bean%' OR v_name LIKE '%pea%') AND v_name LIKE '%1 lb%' THEN RETURN 'nut_legume_lb'; END IF;
    IF (v_name LIKE '%vegetable%' OR v_name LIKE '%olive%') AND v_name LIKE '%1 lb%' THEN RETURN 'vegetable_lb'; END IF;

    -- Existing Build 6.26 families.
    IF v_name='tanned leather' OR v_name='prepared leather' THEN RETURN 'leather'; END IF;
    IF v_name='cordage' OR v_name LIKE '%leather cord%' OR v_name LIKE '%plant cord%' OR v_name LIKE '%twine%' THEN RETURN 'cordage'; END IF;
    IF v_name LIKE '%dragon%' AND v_name LIKE '%blood%' THEN RETURN 'dragon_blood'; END IF;
    IF v_name LIKE '%dragon%' AND v_name LIKE '%scale%' THEN RETURN 'dragon_scale'; END IF;
    IF v_name ~ '(healing|medicinal).*(herb|plant|root|flower|moss)' OR
       v_name ~ '(herb|plant|root|flower|moss).*(healing|medicinal)' OR
       v_name ~ '(^| )(herb|herbs)( |$)' THEN RETURN 'healing_herb'; END IF;
    IF v_name ~ '(venom|poison).*(gland|sac)' OR v_name ~ '(gland|sac).*(venom|poison)' THEN RETURN 'venom'; END IF;
    IF v_name ~ '(chitin|carapace|shell)' THEN RETURN 'chitin_shell'; END IF;
    IF v_name ~ '(bone|horn|antler|claw|talon|fang|tooth|teeth|tusk)' THEN RETURN 'bone_horn'; END IF;
    IF v_name ~ '(pelt|hide|skin)' THEN RETURN 'pelt_hide'; END IF;
    IF v_name ~ '(meat|flesh)' AND v_name NOT LIKE '%ration%' AND v_name NOT LIKE '%prepared%' THEN RETURN 'monster_meat'; END IF;
    IF v_name ~ '(plant fiber|vine fiber|fibrous vine|sinew)' THEN RETURN 'plant_fiber'; END IF;
    IF v_name ~ '(ooze|slime|membrane)' THEN RETURN 'ooze_residue'; END IF;
    IF v_name ~ '(elemental essence|cinder core|frost crystal|elemental dust|elemental stone)' THEN RETURN 'elemental_essence'; END IF;
    IF v_name LIKE '%ectoplasm%' THEN RETURN 'ectoplasm'; END IF;
    IF v_name ~ '(construct component|arcane scrap)' THEN RETURN 'construct_salvage'; END IF;
    IF v_name='vial' OR v_name LIKE '%empty vial%' OR v_name LIKE '%glass vial%' THEN RETURN 'vial'; END IF;
    RETURN NULL;
END;
$$;

-- Backward-compatible alternative ingredient support.
-- Old recipes keep {"family":"x"}; new recipes may use {"families":["x","y"]}.
CREATE OR REPLACE FUNCTION public.discord_crafting_requirement_families(p_requirement JSONB)
RETURNS TEXT[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_families TEXT[]:=ARRAY[]::TEXT[];
BEGIN
    IF p_requirement IS NULL OR jsonb_typeof(p_requirement)<>'object' THEN
        RETURN v_families;
    END IF;

    IF jsonb_typeof(p_requirement->'families')='array' THEN
        SELECT COALESCE(array_agg(LOWER(TRIM(value))),ARRAY[]::TEXT[])
        INTO v_families
        FROM jsonb_array_elements_text(p_requirement->'families')
        WHERE TRIM(value)<>'';
    ELSIF TRIM(COALESCE(p_requirement->>'family',''))<>'' THEN
        v_families:=ARRAY[LOWER(TRIM(p_requirement->>'family'))];
    END IF;

    RETURN v_families;
END;
$$;

INSERT INTO public.discord_crafting_recipes(
    recipe_key,recipe_name,category,description,ingredients,
    output_item_name,output_quantity,output_item_data,sort_order
)
VALUES
(
    'common_torch','Torch','Fieldcraft',
    'Wrap cloth or rags around a stick and soak the wrapping with one ounce of oil or rendered animal/monster fat.',
    '[{"family":"stick","label":"Stick","quantity":1},{"family":"cloth","label":"Cloth / Rags","quantity":1},{"families":["oil_oz","fat_oz"],"label":"Oil or Animal/Monster Fat (1 oz)","quantity":1}]'::jsonb,
    'Torch',1,
    '{"item_type":"Adventuring Gear","weight":1,"description":"A simple hand-made torch of wood, cloth, and combustible oil or fat."}'::jsonb,
    10
),
(
    'pressed_oil','Oil - Pressed','Common Crafting',
    'Press one pound of oil-bearing vegetables such as olives, seeds, nuts, or legumes into usable lamp and crafting oil.',
    '[{"families":["vegetable_lb","seed_lb","nut_legume_lb"],"label":"Vegetables, Seeds, Nuts, or Legumes (1 lb)","quantity":1}]'::jsonb,
    'Oil (1 oz)',8,
    '{"item_type":"Crafting Material","crafting_family":"oil_oz","weight":0.0625,"description":"One measured ounce of vegetable or seed oil for lamps and crafting."}'::jsonb,
    11
),
(
    'rendered_oil','Oil - Rendered Fat','Common Crafting',
    'Render one pound (16 oz) of animal or monster fat into eight ounces of usable lamp and crafting oil.',
    '[{"family":"fat_oz","label":"Animal / Monster Fat (1 oz)","quantity":16}]'::jsonb,
    'Oil (1 oz)',8,
    '{"item_type":"Crafting Material","crafting_family":"oil_oz","weight":0.0625,"description":"One measured ounce of rendered oil for lamps and crafting."}'::jsonb,
    12
),
(
    'common_cloth','Cloth','Textiles',
    'Spin and weave one pound of flax or wool into five usable pieces of cloth.',
    '[{"families":["flax_lb","wool_lb"],"label":"Flax or Wool (1 lb)","quantity":1}]'::jsonb,
    'Cloth',5,
    '{"item_type":"Crafting Material","crafting_family":"cloth","weight":0.2,"description":"A usable piece of woven cloth for fieldcraft, repairs, and other recipes."}'::jsonb,
    13
)
ON CONFLICT(recipe_key) DO UPDATE SET
    recipe_name=EXCLUDED.recipe_name,
    category=EXCLUDED.category,
    description=EXCLUDED.description,
    ingredients=EXCLUDED.ingredients,
    output_item_name=EXCLUDED.output_item_name,
    output_quantity=EXCLUDED.output_quantity,
    output_item_data=EXCLUDED.output_item_data,
    sort_order=EXCLUDED.sort_order;

CREATE OR REPLACE FUNCTION public.discord_get_crafting_state(p_player_id UUID,p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_player UUID;
    v_character_id UUID;
    v_character_name TEXT;
    v_recipe RECORD;
    v_req JSONB;
    v_requirements JSONB;
    v_recipes JSONB:='[]'::jsonb;
    v_materials JSONB:='[]'::jsonb;
    v_available INTEGER;
    v_needed INTEGER;
    v_can BOOLEAN;
    v_families TEXT[];
    v_family TEXT;
    v_label TEXT;
    v_item RECORD;
BEGIN
    v_player:=public.discord_resolve_active_player(p_player_id,p_campaign_id);
    SELECT c.character_id,c.character_name INTO v_character_id,v_character_name
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=v_player LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Active campaign character could not be found.'; END IF;

    FOR v_item IN
        SELECT i.item_name,SUM(i.quantity)::INTEGER AS quantity,
               public.discord_crafting_material_family(i.item_name,i.item_data) AS family
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND public.discord_crafting_material_family(i.item_name,i.item_data) IS NOT NULL
        GROUP BY i.item_name,public.discord_crafting_material_family(i.item_name,i.item_data)
        ORDER BY i.item_name
    LOOP
        v_materials:=v_materials||jsonb_build_array(jsonb_build_object(
            'itemName',v_item.item_name,'quantity',v_item.quantity,'family',v_item.family,
            'familyLabel',CASE v_item.family
                WHEN 'stick' THEN 'Stick'
                WHEN 'cloth' THEN 'Cloth / Rags'
                WHEN 'oil_oz' THEN 'Oil (oz)'
                WHEN 'fat_oz' THEN 'Animal / Monster Fat (oz)'
                WHEN 'vegetable_lb' THEN 'Vegetables (lb)'
                WHEN 'seed_lb' THEN 'Seeds (lb)'
                WHEN 'nut_legume_lb' THEN 'Nuts / Legumes (lb)'
                WHEN 'flax_lb' THEN 'Flax (lb)'
                WHEN 'wool_lb' THEN 'Wool (lb)'
                WHEN 'dragon_scale' THEN 'Dragon Scale'
                WHEN 'healing_herb' THEN 'Medicinal Herb'
                WHEN 'venom' THEN 'Venom'
                WHEN 'chitin_shell' THEN 'Chitin / Shell'
                WHEN 'bone_horn' THEN 'Bonecraft'
                WHEN 'pelt_hide' THEN 'Pelt / Hide'
                WHEN 'monster_meat' THEN 'Monster Meat'
                WHEN 'plant_fiber' THEN 'Plant Fiber'
                WHEN 'leather' THEN 'Leather'
                WHEN 'cordage' THEN 'Cordage'
                WHEN 'vial' THEN 'Vial'
                ELSE 'Material' END));
    END LOOP;

    FOR v_recipe IN SELECT * FROM public.discord_crafting_recipes ORDER BY sort_order,recipe_name LOOP
        v_requirements:='[]'::jsonb;
        v_can:=TRUE;
        FOR v_req IN SELECT value FROM jsonb_array_elements(v_recipe.ingredients) LOOP
            v_families:=public.discord_crafting_requirement_families(v_req);
            IF COALESCE(cardinality(v_families),0)=0 THEN
                RAISE EXCEPTION 'Recipe % contains an invalid material requirement.',v_recipe.recipe_name;
            END IF;
            v_family:=v_families[1];
            v_label:=COALESCE(NULLIF(v_req->>'label',''),v_family);
            v_needed:=GREATEST(1,COALESCE((v_req->>'quantity')::INTEGER,1));
            SELECT COALESCE(SUM(i.quantity),0)::INTEGER INTO v_available
            FROM public.discord_inventory_items i
            WHERE i.character_id=v_character_id
              AND NOT COALESCE(i.equipped,FALSE)
              AND public.discord_crafting_material_family(i.item_name,i.item_data)=ANY(v_families);
            IF v_available<v_needed THEN v_can:=FALSE; END IF;
            v_requirements:=v_requirements||jsonb_build_array(jsonb_build_object(
                'family',v_family,'families',to_jsonb(v_families),'label',v_label,
                'needed',v_needed,'available',v_available));
        END LOOP;
        v_recipes:=v_recipes||jsonb_build_array(jsonb_build_object(
            'recipeKey',v_recipe.recipe_key,'recipeName',v_recipe.recipe_name,'category',v_recipe.category,
            'description',v_recipe.description,'requirements',v_requirements,'canCraft',v_can,
            'outputItemName',v_recipe.output_item_name,'outputQuantity',v_recipe.output_quantity));
    END LOOP;

    RETURN jsonb_build_object('characterId',v_character_id,'characterName',v_character_name,'materials',v_materials,'recipes',v_recipes);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_craft_recipe(
    p_player_id UUID,
    p_campaign_id UUID,
    p_recipe_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_player UUID;
    v_character_id UUID;
    v_character_name TEXT;
    v_recipe public.discord_crafting_recipes%ROWTYPE;
    v_req JSONB;
    v_families TEXT[];
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
        v_families:=public.discord_crafting_requirement_families(v_req);
        IF COALESCE(cardinality(v_families),0)=0 THEN
            RAISE EXCEPTION 'Recipe % contains an invalid material requirement.',v_recipe.recipe_name;
        END IF;
        v_needed:=GREATEST(1,COALESCE((v_req->>'quantity')::INTEGER,1));
        SELECT COALESCE(SUM(i.quantity),0)::INTEGER INTO v_available
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND NOT COALESCE(i.equipped,FALSE)
          AND public.discord_crafting_material_family(i.item_name,i.item_data)=ANY(v_families);
        IF v_available<v_needed THEN
            RAISE EXCEPTION 'Not enough % to craft %.',
                COALESCE(NULLIF(v_req->>'label',''),array_to_string(v_families,' / ')),v_recipe.recipe_name;
        END IF;
    END LOOP;

    FOR v_req IN SELECT value FROM jsonb_array_elements(v_recipe.ingredients) LOOP
        v_families:=public.discord_crafting_requirement_families(v_req);
        v_remaining:=GREATEST(1,COALESCE((v_req->>'quantity')::INTEGER,1));
        FOR v_item IN
            SELECT i.inventory_item_id,i.item_name,i.quantity,
                   public.discord_crafting_material_family(i.item_name,i.item_data) AS family
            FROM public.discord_inventory_items i
            WHERE i.character_id=v_character_id
              AND NOT COALESCE(i.equipped,FALSE)
              AND public.discord_crafting_material_family(i.item_name,i.item_data)=ANY(v_families)
            ORDER BY i.created_at,i.inventory_item_id
            FOR UPDATE
        LOOP
            EXIT WHEN v_remaining<=0;
            v_take:=LEAST(v_remaining,v_item.quantity);
            v_consumed:=v_consumed||jsonb_build_array(jsonb_build_object(
                'inventoryItemId',v_item.inventory_item_id,'itemName',v_item.item_name,
                'quantity',v_take,'family',v_item.family));
            IF v_take>=v_item.quantity THEN
                DELETE FROM public.discord_inventory_items WHERE inventory_item_id=v_item.inventory_item_id;
            ELSE
                UPDATE public.discord_inventory_items
                SET quantity=quantity-v_take,updated_at=NOW()
                WHERE inventory_item_id=v_item.inventory_item_id;
            END IF;
            v_remaining:=v_remaining-v_take;
        END LOOP;
    END LOOP;

    -- Preserve the Build 6.26 waterskin-aware output path.
    IF LOWER(TRIM(v_recipe.output_item_name))='waterskin' THEN
        PERFORM public.discord_gm_add_inventory_item(
            v_character_id,p_campaign_id,'Waterskin',v_recipe.output_quantity,
            COALESCE(v_recipe.output_item_data->>'description','A durable leather water container. It holds 30 drinks, equal to 3 days of water.'),
            'Crafting','Crafted with Build 6.30.10'
        );
        SELECT i.inventory_item_id INTO v_output_id
        FROM public.discord_inventory_items i
        INNER JOIN public.discord_waterskin_state ws ON ws.inventory_item_id=i.inventory_item_id
        WHERE i.character_id=v_character_id
          AND LOWER(TRIM(i.item_name))='waterskin'
          AND ws.campaign_id=p_campaign_id
        ORDER BY i.created_at DESC,i.inventory_item_id DESC LIMIT 1;
    ELSE
        SELECT i.inventory_item_id INTO v_output_id
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character_id
          AND LOWER(i.item_name)=LOWER(v_recipe.output_item_name)
          AND NOT COALESCE(i.equipped,FALSE)
        ORDER BY i.inventory_item_id LIMIT 1 FOR UPDATE;

        IF v_output_id IS NULL THEN
            INSERT INTO public.discord_inventory_items(
                character_id,item_name,quantity,equipped,attuned,source_name,notes,item_data)
            VALUES(
                v_character_id,v_recipe.output_item_name,v_recipe.output_quantity,FALSE,FALSE,
                'Crafting','Crafted with Build 6.30.10',v_recipe.output_item_data)
            RETURNING inventory_item_id INTO v_output_id;
        ELSE
            UPDATE public.discord_inventory_items
            SET quantity=quantity+v_recipe.output_quantity,
                item_data=CASE WHEN COALESCE(item_data,'{}'::jsonb)='{}'::jsonb THEN v_recipe.output_item_data ELSE item_data END,
                updated_at=NOW()
            WHERE inventory_item_id=v_output_id;
        END IF;
    END IF;

    INSERT INTO public.discord_crafting_events(
        campaign_id,character_id,recipe_key,recipe_name,ingredients,output_item_name,output_quantity)
    VALUES(
        p_campaign_id,v_character_id,v_recipe.recipe_key,v_recipe.recipe_name,v_consumed,
        v_recipe.output_item_name,v_recipe.output_quantity);

    RETURN jsonb_build_object(
        'success',TRUE,'characterId',v_character_id,'characterName',v_character_name,
        'recipeKey',v_recipe.recipe_key,'recipeName',v_recipe.recipe_name,
        'outputItemName',v_recipe.output_item_name,'outputQuantity',v_recipe.output_quantity,
        'inventoryItemId',v_output_id,
        'message','Crafted '||v_recipe.output_quantity::TEXT||' × '||v_recipe.output_item_name||'.');
END;
$$;

CREATE TABLE IF NOT EXISTS public.discord_woodland_forage_events
(
    forage_event_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    d20_roll INTEGER NOT NULL CHECK(d20_roll BETWEEN 1 AND 20),
    ability_modifier INTEGER NOT NULL,
    proficiency_applied BOOLEAN NOT NULL DEFAULT FALSE,
    total INTEGER NOT NULL,
    dc INTEGER NOT NULL DEFAULT 10,
    success BOOLEAN NOT NULL,
    item_name TEXT NULL,
    quantity_gained INTEGER NOT NULL DEFAULT 0,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_discord_woodland_forage_character
ON public.discord_woodland_forage_events(character_id,attempted_at DESC);

ALTER TABLE public.discord_woodland_forage_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_woodland_forage_events FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.discord_woodland_forage_events TO service_role;

DROP FUNCTION IF EXISTS public.discord_forage_wooded_area(UUID,UUID,INTEGER);
CREATE OR REPLACE FUNCTION public.discord_forage_wooded_area(
    p_player_id UUID,
    p_campaign_id UUID,
    p_d20_roll INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public AS $$
DECLARE
    v_player UUID;
    v_character RECORD;
    v_ability_mod INTEGER;
    v_prof BOOLEAN:=FALSE;
    v_total INTEGER;
    v_dc INTEGER:=10;
    v_success BOOLEAN;
    v_pick INTEGER;
    v_item_name TEXT:=NULL;
    v_family TEXT:=NULL;
    v_description TEXT:=NULL;
    v_weight NUMERIC:=1;
    v_quantity INTEGER:=0;
    v_output_id UUID;
    v_item_data JSONB:='{}'::jsonb;
BEGIN
    IF p_d20_roll NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Foraging d20 roll must be between 1 and 20.'; END IF;

    v_player:=public.discord_resolve_active_player(p_player_id,p_campaign_id);
    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=v_player
    LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Active campaign character could not be found.'; END IF;

    v_ability_mod:=FLOOR((COALESCE(v_character.wisdom,10)-10)/2.0)::INTEGER;
    v_prof:=public.discord_character_has_skill_proficiency(v_character.character_data,'Survival')
            OR public.discord_character_has_skill_proficiency(v_character.character_data,'Nature');
    v_total:=p_d20_roll+v_ability_mod+CASE WHEN v_prof THEN COALESCE(v_character.proficiency_bonus,2) ELSE 0 END;
    v_success:=v_total>=v_dc;

    IF v_success THEN
        v_pick:=FLOOR(random()*5)::INTEGER;
        CASE v_pick
            WHEN 0 THEN
                v_item_name:='Stick'; v_family:='stick'; v_weight:=0.5;
                v_description:='A dry, sturdy stick gathered in a wooded area for fieldcraft or fire-making.';
            WHEN 1 THEN
                v_item_name:='Seeds (1 lb)'; v_family:='seed_lb'; v_weight:=1;
                v_description:='One pound of gathered wild seeds suitable for food, trade, or pressing into oil.';
            WHEN 2 THEN
                v_item_name:='Nuts (1 lb)'; v_family:='nut_legume_lb'; v_weight:=1;
                v_description:='One pound of gathered edible nuts suitable for food or pressing into oil.';
            WHEN 3 THEN
                v_item_name:='Legumes (1 lb)'; v_family:='nut_legume_lb'; v_weight:=1;
                v_description:='One pound of gathered wild legumes suitable for food or pressing into oil.';
            ELSE
                v_item_name:='Flax (1 lb)'; v_family:='flax_lb'; v_weight:=1;
                v_description:='One pound of gathered flax fiber suitable for spinning and weaving into cloth.';
        END CASE;

        v_quantity:=CASE WHEN v_total>=15 OR p_d20_roll=20 THEN 2 ELSE 1 END;
        v_item_data:=jsonb_build_object(
            'item_type','Crafting Material','crafting_family',v_family,'weight',v_weight,
            'description',v_description,'foraged_biome','wooded');

        SELECT i.inventory_item_id INTO v_output_id
        FROM public.discord_inventory_items i
        WHERE i.character_id=v_character.character_id
          AND LOWER(i.item_name)=LOWER(v_item_name)
          AND NOT COALESCE(i.equipped,FALSE)
        ORDER BY i.created_at,i.inventory_item_id LIMIT 1 FOR UPDATE;

        IF v_output_id IS NULL THEN
            INSERT INTO public.discord_inventory_items(
                character_id,item_name,quantity,equipped,attuned,source_name,notes,item_data)
            VALUES(
                v_character.character_id,v_item_name,v_quantity,FALSE,FALSE,
                'Woodland Foraging','Gathered in a wooded area with Build 6.30.10.',v_item_data)
            RETURNING inventory_item_id INTO v_output_id;
        ELSE
            UPDATE public.discord_inventory_items
            SET quantity=quantity+v_quantity,
                item_data=COALESCE(item_data,'{}'::jsonb)||v_item_data,
                updated_at=NOW()
            WHERE inventory_item_id=v_output_id;
        END IF;
    END IF;

    INSERT INTO public.discord_woodland_forage_events(
        campaign_id,character_id,d20_roll,ability_modifier,proficiency_applied,total,dc,
        success,item_name,quantity_gained)
    VALUES(
        p_campaign_id,v_character.character_id,p_d20_roll,v_ability_mod,v_prof,v_total,v_dc,
        v_success,v_item_name,v_quantity);

    RETURN jsonb_build_object(
        'success',v_success,'roll',p_d20_roll,'abilityModifier',v_ability_mod,
        'proficiencyApplied',v_prof,'total',v_total,'dc',v_dc,
        'itemName',v_item_name,'quantityGained',v_quantity,'inventoryItemId',v_output_id,
        'message',CASE
            WHEN v_success THEN 'Woodland search succeeded: found '||v_quantity::TEXT||' × '||v_item_name||
                                ' (check '||v_total::TEXT||' vs DC '||v_dc::TEXT||').'
            ELSE 'Woodland search found no usable materials (check '||v_total::TEXT||' vs DC '||v_dc::TEXT||').'
        END);
END;
$$;

REVOKE ALL ON FUNCTION public.discord_crafting_material_family(TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_crafting_requirement_families(JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_crafting_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_craft_recipe(UUID,UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_forage_wooded_area(UUID,UUID,INTEGER) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_get_crafting_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_craft_recipe(UUID,UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_forage_wooded_area(UUID,UUID,INTEGER) TO service_role;

NOTIFY pgrst,'reload schema';
COMMIT;
