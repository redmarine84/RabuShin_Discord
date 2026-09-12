-- ============================================================
-- RabuShinAIGM Build 6.29.3
-- Migration 64 - Equipment Loadout Slot Expansion
-- Forward expansion of Migration 57 slot rules.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_inventory_suggested_equipment_slot(
    p_item_name TEXT,
    p_item_data JSONB DEFAULT '{}'::jsonb
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_name TEXT:=LOWER(TRIM(COALESCE(p_item_name,'')));
    v_type TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'itemType',p_item_data->>'item_type','')));
    v_slot TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'equipmentSlot',p_item_data->>'equipment_slot','')));
    v_props TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'weaponProperties',p_item_data->>'weapon_properties','')));
BEGIN
    IF v_name~'(arrow|bolt|bullet|needle|ammunition)' OR v_type='ammunition' THEN RETURN 'ammunition'; END IF;
    IF v_name LIKE '%shield%' OR v_type='shield' THEN RETURN 'shield'; END IF;
    IF v_name~'(helmet|helm|circlet)' OR v_slot LIKE '%head%' THEN RETURN 'head'; END IF;
    IF v_name~'(glove|gauntlet|bracer)' OR v_slot LIKE '%hand%' OR v_slot LIKE '%arm%' THEN RETURN 'hands'; END IF;
    IF v_name~'(boot|greave)' OR v_slot LIKE '%feet%' THEN RETURN 'feet'; END IF;
    IF v_name LIKE '%ring%' THEN RETURN 'ring_left'; END IF;
    IF v_name~'(necklace|amulet|pendant|brooch)' OR v_slot LIKE '%neck%' THEN RETURN 'neck'; END IF;
    IF v_type='armor' OR v_name~'(chain mail|chain shirt|scale mail|half plate|breastplate|studded leather|leather armor|hide armor|ring mail|splint|plate armor)' THEN RETURN 'armor'; END IF;

    IF v_name LIKE '%javelin%' THEN RETURN 'ranged'; END IF;

    IF v_type='weapon' OR v_name~'(sword|mace|axe|hammer|dagger|spear|staff|club|flail|rapier|scimitar|trident|whip|bow|crossbow|sling|blowgun)' THEN
        IF v_name~'(bow|crossbow|sling|blowgun)'
           OR v_slot LIKE '%ranged%'
           OR v_props~'(ammunition|ranged)'
        THEN
            RETURN 'ranged';
        END IF;
        RETURN 'main_hand';
    END IF;

    RETURN 'accessory_1';
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_slot_accepts_item(
    p_slot_key TEXT,
    p_item_name TEXT,
    p_item_data JSONB DEFAULT '{}'::jsonb
)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_slot TEXT:=LOWER(TRIM(COALESCE(p_slot_key,'')));
    v_name TEXT:=LOWER(TRIM(COALESCE(p_item_name,'')));
    v_type TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'itemType',p_item_data->>'item_type','')));
    v_eslot TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'equipmentSlot',p_item_data->>'equipment_slot','')));
    v_props TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'weaponProperties',p_item_data->>'weapon_properties','')));
    v_shield BOOLEAN;
    v_ammo BOOLEAN;
    v_weapon BOOLEAN;
    v_javelin BOOLEAN;
    v_dedicated_ranged BOOLEAN;
BEGIN
    v_shield:=v_type='shield' OR v_name LIKE '%shield%';
    v_ammo:=v_type='ammunition' OR v_name~'(arrow|bolt|bullet|needle|ammunition)';
    v_javelin:=v_name LIKE '%javelin%';

    v_dedicated_ranged:=
        v_name~'(bow|crossbow|sling|blowgun)'
        OR v_eslot LIKE '%ranged%'
        OR v_props~'(ammunition|ranged)';

    v_weapon:=
        v_type='weapon'
        OR v_name~'(sword|mace|axe|hammer|dagger|spear|javelin|staff|club|flail|rapier|scimitar|trident|whip|bow|crossbow|sling|blowgun)';

    RETURN CASE v_slot
        WHEN 'armor' THEN
            (v_type='armor' OR v_name~'(chain mail|chain shirt|scale mail|half plate|breastplate|studded leather|leather armor|hide armor|ring mail|splint|plate armor)')
            AND NOT v_shield
            AND v_name!~'(helmet|helm|glove|gauntlet|bracer|boot|greave)'
        WHEN 'shield' THEN v_shield
        WHEN 'main_hand' THEN v_weapon AND NOT v_dedicated_ranged
        WHEN 'off_hand' THEN v_shield OR (v_weapon AND NOT v_dedicated_ranged)
        WHEN 'ranged' THEN v_weapon AND (v_dedicated_ranged OR v_javelin)
        WHEN 'ammunition' THEN v_ammo
        WHEN 'head' THEN v_name~'(helmet|helm|circlet)' OR v_eslot LIKE '%head%'
        WHEN 'hands' THEN v_name~'(glove|gauntlet|bracer)' OR v_eslot LIKE '%hand%' OR v_eslot LIKE '%arm%'
        WHEN 'feet' THEN v_name~'(boot|greave)' OR v_eslot LIKE '%feet%'
        WHEN 'neck' THEN v_name~'(necklace|amulet|pendant|brooch)' OR v_eslot LIKE '%neck%'
        WHEN 'ring_left' THEN v_name LIKE '%ring%'
        WHEN 'ring_right' THEN v_name LIKE '%ring%'
        WHEN 'accessory_1' THEN TRUE
        WHEN 'accessory_2' THEN TRUE
        ELSE FALSE
    END;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_recalculate_equipment_ac_from_slots(p_character_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public AS $$
DECLARE
    v_char RECORD;
    v_dex INTEGER;
    v_unarmored INTEGER;
    v_ac INTEGER;
    v_item RECORD;
    v_base INTEGER;
    v_bonus INTEGER;
    v_max_dex INTEGER;
    v_dex_add INTEGER;
    v_shield_bonus INTEGER:=0;
    v_item_type TEXT;
BEGIN
    SELECT c.character_id,c.class_name,c.species_name,c.dexterity,c.constitution,c.wisdom
    INTO v_char
    FROM public.discord_characters c
    WHERE c.character_id=p_character_id;

    IF v_char.character_id IS NULL THEN RETURN NULL; END IF;

    v_dex:=FLOOR((v_char.dexterity-10)/2.0)::INTEGER;

    SELECT COALESCE(MAX(
        GREATEST(
            2,
            COALESCE(
                NULLIF(s.mechanics->>'armorClassBonus','')::INTEGER,
                NULLIF(i.item_data->>'armor_class_bonus','')::INTEGER,
                0
            )
        )
    ),0)
    INTO v_shield_bonus
    FROM public.discord_character_equipment_slots s
    JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
    WHERE s.character_id=p_character_id
      AND s.slot_key IN('shield','off_hand')
      AND (
          LOWER(COALESCE(s.mechanics->>'itemType',i.item_data->>'itemType',i.item_data->>'item_type',''))='shield'
          OR LOWER(i.item_name) LIKE '%shield%'
      );

    v_unarmored:=10+v_dex;
    IF LOWER(COALESCE(v_char.class_name,''))='barbarian' THEN
        v_unarmored:=GREATEST(v_unarmored,10+v_dex+FLOOR((v_char.constitution-10)/2.0)::INTEGER);
    END IF;
    IF LOWER(COALESCE(v_char.class_name,''))='monk' AND v_shield_bonus<=0 THEN
        v_unarmored:=GREATEST(v_unarmored,10+v_dex+FLOOR((v_char.wisdom-10)/2.0)::INTEGER);
    END IF;
    IF LOWER(COALESCE(v_char.species_name,'')) LIKE '%tortle%' THEN
        v_unarmored:=GREATEST(v_unarmored,17);
    END IF;

    v_ac:=v_unarmored;

    SELECT s.slot_key,s.mechanics,i.item_name,i.item_data INTO v_item
    FROM public.discord_character_equipment_slots s
    JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
    WHERE s.character_id=p_character_id AND s.slot_key='armor';

    IF FOUND THEN
        v_base:=COALESCE(
            NULLIF(v_item.mechanics->>'armorClassBase','')::INTEGER,
            NULLIF(v_item.item_data->>'armor_class_base','')::INTEGER,
            public.discord_standard_armor_base(v_item.item_name),
            0
        );
        v_bonus:=COALESCE(
            NULLIF(v_item.mechanics->>'armorClassBonus','')::INTEGER,
            NULLIF(v_item.item_data->>'armor_class_bonus','')::INTEGER,
            0
        );
        v_max_dex:=COALESCE(
            NULLIF(v_item.mechanics->>'maxDexBonus','')::INTEGER,
            NULLIF(v_item.item_data->>'max_dex_bonus','')::INTEGER,
            public.discord_standard_armor_max_dex(v_item.item_name),
            -1
        );

        IF v_base>0 THEN
            v_dex_add:=CASE
                WHEN v_max_dex=0 THEN 0
                WHEN v_max_dex>0 THEN LEAST(v_dex,v_max_dex)
                ELSE v_dex
            END;
            v_ac:=v_base+v_dex_add+GREATEST(0,v_bonus);
        END IF;
    END IF;

    IF v_shield_bonus>0 THEN
        v_ac:=v_ac+v_shield_bonus;
    END IF;

    FOR v_item IN
        SELECT s.slot_key,s.mechanics,i.item_name,i.item_data
        FROM public.discord_character_equipment_slots s
        JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
        WHERE s.character_id=p_character_id
          AND s.slot_key IN('head','neck','hands','feet','ring_left','ring_right','accessory_1','accessory_2')
    LOOP
        IF v_item.slot_key IN('accessory_1','accessory_2') THEN
            v_item_type:=LOWER(COALESCE(
                v_item.mechanics->>'itemType',
                v_item.item_data->>'itemType',
                v_item.item_data->>'item_type',
                ''
            ));

            IF v_item_type<>'accessory'
               AND LOWER(v_item.item_name)!~'(bracelet|charm|talisman|belt|amulet|necklace|pendant|brooch|ring)'
            THEN
                CONTINUE;
            END IF;
        END IF;

        v_bonus:=COALESCE(
            NULLIF(v_item.mechanics->>'armorClassBonus','')::INTEGER,
            NULLIF(v_item.item_data->>'armor_class_bonus','')::INTEGER,
            0
        );

        IF v_bonus>0 THEN
            v_ac:=v_ac+v_bonus;
        END IF;
    END LOOP;

    v_ac:=GREATEST(1,LEAST(40,v_ac));
    UPDATE public.discord_characters
    SET armor_class=v_ac
    WHERE character_id=p_character_id;

    RETURN v_ac;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN COALESCE(
        (SELECT armor_class FROM public.discord_characters WHERE character_id=p_character_id),
        10
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_inventory_suggested_equipment_slot(TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_slot_accepts_item(TEXT,TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_recalculate_equipment_ac_from_slots(UUID) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_inventory_suggested_equipment_slot(TEXT,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_slot_accepts_item(TEXT,TEXT,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_recalculate_equipment_ac_from_slots(UUID) TO service_role;

DO $$
DECLARE v_character RECORD;
BEGIN
    FOR v_character IN SELECT c.character_id FROM public.discord_characters c LOOP
        PERFORM public.discord_recalculate_equipment_ac_from_slots(v_character.character_id);
    END LOOP;
END $$;

NOTIFY pgrst,'reload schema';

COMMIT;
