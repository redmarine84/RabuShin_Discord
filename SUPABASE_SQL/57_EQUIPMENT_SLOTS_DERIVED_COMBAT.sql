-- ============================================================
-- RabuShinAIGM Rules Build 6.22.1
-- Equipment Slots + Automatic AC / Weapon Availability
-- Migration 57
-- Requires migration 56 and Build 6.17 active-player resolver.
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_equipment_ac_baseline
(
    character_id UUID PRIMARY KEY REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    previous_armor_class INTEGER NOT NULL
);

INSERT INTO public.discord_equipment_ac_baseline(character_id,previous_armor_class)
SELECT c.character_id,c.armor_class FROM public.discord_characters c
ON CONFLICT(character_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.discord_character_equipment_slots
(
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    slot_key TEXT NOT NULL CHECK(slot_key IN (
        'armor','shield','main_hand','off_hand','ranged','ammunition','head','neck','hands','feet',
        'ring_left','ring_right','accessory_1','accessory_2')),
    inventory_item_id UUID NOT NULL REFERENCES public.discord_inventory_items(inventory_item_id) ON DELETE CASCADE,
    mechanics JSONB NOT NULL DEFAULT '{}'::jsonb,
    equipped_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(character_id,slot_key),
    UNIQUE(inventory_item_id)
);

CREATE INDEX IF NOT EXISTS ix_discord_equipment_slots_character ON public.discord_character_equipment_slots(character_id);
ALTER TABLE public.discord_equipment_ac_baseline ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_character_equipment_slots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_equipment_ac_baseline FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.discord_character_equipment_slots FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.discord_equipment_ac_baseline TO service_role;
GRANT ALL ON public.discord_character_equipment_slots TO service_role;

CREATE OR REPLACE FUNCTION public.discord_inventory_suggested_equipment_slot(p_item_name TEXT,p_item_data JSONB DEFAULT '{}'::jsonb)
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
    IF v_name~'(bracelet|charm|talisman|belt)' OR v_type='accessory' THEN RETURN 'accessory_1'; END IF;
    IF v_type='armor' OR v_name~'(chain mail|chain shirt|scale mail|half plate|breastplate|studded leather|leather armor|hide armor|ring mail|splint|plate armor)' THEN RETURN 'armor'; END IF;
    IF v_type='weapon' OR v_name~'(sword|mace|axe|hammer|dagger|spear|staff|club|flail|rapier|scimitar|trident|whip|bow|crossbow|sling)' THEN
        IF v_name~'(bow|crossbow|sling|blowgun)' OR v_props~'(ammunition|ranged)' THEN RETURN 'ranged'; END IF;
        RETURN 'main_hand';
    END IF;
    IF v_type='accessory' THEN RETURN 'accessory_1'; END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_slot_accepts_item(p_slot_key TEXT,p_item_name TEXT,p_item_data JSONB DEFAULT '{}'::jsonb)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_slot TEXT:=LOWER(TRIM(COALESCE(p_slot_key,'')));
    v_name TEXT:=LOWER(TRIM(COALESCE(p_item_name,'')));
    v_type TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'itemType',p_item_data->>'item_type','')));
    v_eslot TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'equipmentSlot',p_item_data->>'equipment_slot','')));
    v_props TEXT:=LOWER(TRIM(COALESCE(p_item_data->>'weaponProperties',p_item_data->>'weapon_properties','')));
    v_ranged BOOLEAN;
BEGIN
    v_ranged:=v_name~'(bow|crossbow|sling|blowgun)' OR v_props~'(ammunition|ranged)';
    RETURN CASE v_slot
        WHEN 'armor' THEN (v_type='armor' OR v_name~'(chain mail|chain shirt|scale mail|half plate|breastplate|studded leather|leather armor|hide armor|ring mail|splint|plate armor)')
                           AND v_name NOT LIKE '%shield%' AND v_name!~'(helmet|helm|glove|gauntlet|bracer|boot|greave)'
        WHEN 'shield' THEN v_type='shield' OR v_name LIKE '%shield%'
        WHEN 'main_hand' THEN (v_type='weapon' OR v_name~'(sword|mace|axe|hammer|dagger|spear|staff|club|flail|rapier|scimitar|trident|whip)') AND NOT v_ranged
        WHEN 'off_hand' THEN (v_type='weapon' OR v_name~'(sword|mace|axe|hammer|dagger|spear|staff|club|flail|rapier|scimitar|trident|whip)') AND NOT v_ranged
        WHEN 'ranged' THEN (v_type='weapon' OR v_name~'(bow|crossbow|sling)') AND v_ranged
        WHEN 'ammunition' THEN v_type='ammunition' OR v_name~'(arrow|bolt|bullet|needle|ammunition)'
        WHEN 'head' THEN v_name~'(helmet|helm|circlet)' OR v_eslot LIKE '%head%'
        WHEN 'hands' THEN v_name~'(glove|gauntlet|bracer)' OR v_eslot LIKE '%hand%' OR v_eslot LIKE '%arm%'
        WHEN 'feet' THEN v_name~'(boot|greave)' OR v_eslot LIKE '%feet%'
        WHEN 'neck' THEN v_name~'(necklace|amulet|pendant|brooch)' OR v_eslot LIKE '%neck%'
        WHEN 'ring_left' THEN v_name LIKE '%ring%'
        WHEN 'ring_right' THEN v_name LIKE '%ring%'
        WHEN 'accessory_1' THEN (v_type='accessory' OR v_name~'(bracelet|charm|talisman|belt)') AND v_name NOT LIKE '%ring%' AND v_name!~'(necklace|amulet|pendant|brooch)'
        WHEN 'accessory_2' THEN (v_type='accessory' OR v_name~'(bracelet|charm|talisman|belt)') AND v_name NOT LIKE '%ring%' AND v_name!~'(necklace|amulet|pendant|brooch)'
        ELSE FALSE END;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN FALSE;
END;
$$;

-- Preserve legacy Equipped items by assigning each to its first sensible slot.
WITH ranked AS
(
    SELECT i.character_id,i.inventory_item_id,
           public.discord_inventory_suggested_equipment_slot(i.item_name,i.item_data) AS slot_key,
           ROW_NUMBER() OVER(PARTITION BY i.character_id,public.discord_inventory_suggested_equipment_slot(i.item_name,i.item_data)
                             ORDER BY i.inventory_item_id) AS rn
    FROM public.discord_inventory_items i
    WHERE COALESCE(i.equipped,FALSE)
)
INSERT INTO public.discord_character_equipment_slots(character_id,slot_key,inventory_item_id)
SELECT character_id,slot_key,inventory_item_id FROM ranked
WHERE slot_key IS NOT NULL AND rn=1
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.discord_sync_equipped_flags(p_character_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    UPDATE public.discord_inventory_items i
    SET equipped=EXISTS(
        SELECT 1 FROM public.discord_character_equipment_slots s
        WHERE s.character_id=p_character_id AND s.inventory_item_id=i.inventory_item_id)
    WHERE i.character_id=p_character_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_standard_armor_base(p_item_name TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$
SELECT CASE LOWER(TRIM(COALESCE(p_item_name,'')))
 WHEN 'padded armor' THEN 11 WHEN 'leather armor' THEN 11 WHEN 'studded leather armor' THEN 12
 WHEN 'hide armor' THEN 12 WHEN 'chain shirt' THEN 13 WHEN 'scale mail' THEN 14 WHEN 'breastplate' THEN 14 WHEN 'half plate' THEN 15
 WHEN 'ring mail' THEN 14 WHEN 'chain mail' THEN 16 WHEN 'splint armor' THEN 17 WHEN 'plate armor' THEN 18
 ELSE 0 END;
$$;

CREATE OR REPLACE FUNCTION public.discord_standard_armor_max_dex(p_item_name TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$
SELECT CASE LOWER(TRIM(COALESCE(p_item_name,'')))
 WHEN 'hide armor' THEN 2 WHEN 'chain shirt' THEN 2 WHEN 'scale mail' THEN 2 WHEN 'breastplate' THEN 2 WHEN 'half plate' THEN 2
 WHEN 'ring mail' THEN 0 WHEN 'chain mail' THEN 0 WHEN 'splint armor' THEN 0 WHEN 'plate armor' THEN 0
 ELSE -1 END;
$$;

CREATE OR REPLACE FUNCTION public.discord_recalculate_equipment_ac_from_slots(p_character_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
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
    v_has_shield BOOLEAN:=FALSE;
BEGIN
    SELECT c.character_id,c.class_name,c.species_name,c.dexterity,c.constitution,c.wisdom INTO v_char
    FROM public.discord_characters c WHERE c.character_id=p_character_id;
    IF v_char.character_id IS NULL THEN RETURN NULL; END IF;
    v_dex:=FLOOR((v_char.dexterity-10)/2.0)::INTEGER;
    SELECT EXISTS(SELECT 1 FROM public.discord_character_equipment_slots s WHERE s.character_id=p_character_id AND s.slot_key='shield') INTO v_has_shield;
    v_unarmored:=10+v_dex;
    IF LOWER(COALESCE(v_char.class_name,''))='barbarian' THEN v_unarmored:=GREATEST(v_unarmored,10+v_dex+FLOOR((v_char.constitution-10)/2.0)::INTEGER); END IF;
    IF LOWER(COALESCE(v_char.class_name,''))='monk' AND NOT v_has_shield THEN v_unarmored:=GREATEST(v_unarmored,10+v_dex+FLOOR((v_char.wisdom-10)/2.0)::INTEGER); END IF;
    IF LOWER(COALESCE(v_char.species_name,'')) LIKE '%tortle%' THEN v_unarmored:=GREATEST(v_unarmored,17); END IF;
    v_ac:=v_unarmored;

    SELECT s.slot_key,s.mechanics,i.item_name,i.item_data INTO v_item
    FROM public.discord_character_equipment_slots s
    JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
    WHERE s.character_id=p_character_id AND s.slot_key='armor';
    IF FOUND THEN
        v_base:=COALESCE(NULLIF(v_item.mechanics->>'armorClassBase','')::INTEGER,
                         NULLIF(v_item.item_data->>'armor_class_base','')::INTEGER,
                         public.discord_standard_armor_base(v_item.item_name),0);
        v_bonus:=COALESCE(NULLIF(v_item.mechanics->>'armorClassBonus','')::INTEGER,
                          NULLIF(v_item.item_data->>'armor_class_bonus','')::INTEGER,0);
        v_max_dex:=COALESCE(NULLIF(v_item.mechanics->>'maxDexBonus','')::INTEGER,
                            NULLIF(v_item.item_data->>'max_dex_bonus','')::INTEGER,
                            public.discord_standard_armor_max_dex(v_item.item_name),-1);
        IF v_base>0 THEN
            v_dex_add:=CASE WHEN v_max_dex=0 THEN 0 WHEN v_max_dex>0 THEN LEAST(v_dex,v_max_dex) ELSE v_dex END;
            v_ac:=v_base+v_dex_add+GREATEST(0,v_bonus);
        END IF;
    END IF;

    FOR v_item IN
        SELECT s.slot_key,s.mechanics,i.item_name,i.item_data
        FROM public.discord_character_equipment_slots s
        JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
        WHERE s.character_id=p_character_id AND s.slot_key IN('shield','head','neck','hands','feet','ring_left','ring_right','accessory_1','accessory_2')
    LOOP
        v_bonus:=COALESCE(NULLIF(v_item.mechanics->>'armorClassBonus','')::INTEGER,
                          NULLIF(v_item.item_data->>'armor_class_bonus','')::INTEGER,0);
        IF v_item.slot_key='shield' AND v_bonus<=0 THEN v_bonus:=2; END IF;
        IF v_bonus>0 THEN v_ac:=v_ac+v_bonus; END IF;
    END LOOP;

    v_ac:=GREATEST(1,LEAST(40,v_ac));
    UPDATE public.discord_characters SET armor_class=v_ac WHERE character_id=p_character_id;
    RETURN v_ac;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN COALESCE((SELECT armor_class FROM public.discord_characters WHERE character_id=p_character_id),10);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_equipment_slots_changed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_character_id UUID;
BEGIN
    v_character_id:=CASE WHEN TG_OP='DELETE' THEN OLD.character_id ELSE NEW.character_id END;
    PERFORM public.discord_sync_equipped_flags(v_character_id);
    PERFORM public.discord_recalculate_equipment_ac_from_slots(v_character_id);
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_equipment_slots_changed ON public.discord_character_equipment_slots;
CREATE TRIGGER trg_discord_equipment_slots_changed
AFTER INSERT OR UPDATE OR DELETE ON public.discord_character_equipment_slots
FOR EACH ROW EXECUTE FUNCTION public.discord_equipment_slots_changed();

-- Normalize legacy hand conflicts: a weapon occupying the actual Main Hand and
-- requiring two hands cannot retain a legacy Shield/Off Hand entry. The dedicated
-- Ranged slot remains independent so a stowed/slung ranged weapon can still be shown.
DELETE FROM public.discord_character_equipment_slots secondary
USING public.discord_character_equipment_slots main_slot
JOIN public.discord_inventory_items main_item ON main_item.inventory_item_id=main_slot.inventory_item_id
WHERE secondary.character_id=main_slot.character_id
  AND secondary.slot_key IN('shield','off_hand')
  AND main_slot.slot_key='main_hand'
  AND (
      LOWER(COALESCE(main_slot.mechanics->>'weaponProperties',main_item.item_data->>'weapon_properties','')) LIKE '%two-handed%'
      OR LOWER(main_item.item_name)~'(greatclub|greatsword|greataxe|maul|glaive|halberd|pike|longbow|heavy crossbow)'
  );

-- Normalize legacy Equipped booleans into the new slot authority and immediately
-- derive AC for every existing character. The pre-migration values remain in
-- discord_equipment_ac_baseline for rollback.
DO $$
DECLARE v_character RECORD;
BEGIN
    FOR v_character IN SELECT c.character_id FROM public.discord_characters c LOOP
        PERFORM public.discord_sync_equipped_flags(v_character.character_id);
        PERFORM public.discord_recalculate_equipment_ac_from_slots(v_character.character_id);
    END LOOP;
END $$;

DROP FUNCTION IF EXISTS public.discord_get_equipment_slots(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_equipment_slots(p_player_id UUID,p_campaign_id UUID)
RETURNS TABLE(slot_key TEXT,inventory_item_id UUID,item_name TEXT,mechanics JSONB)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_player UUID; v_character_id UUID;
BEGIN
    v_player:=public.discord_resolve_active_player(p_player_id,p_campaign_id);
    SELECT c.character_id INTO v_character_id FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=v_player LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Active campaign character could not be found.'; END IF;
    RETURN QUERY
    WITH keys(slot_key,sort_order) AS (VALUES
      ('armor',10),('shield',20),('main_hand',30),('off_hand',40),('ranged',50),('ammunition',60),
      ('head',70),('neck',80),('hands',90),('feet',100),('ring_left',110),('ring_right',120),('accessory_1',130),('accessory_2',140))
    SELECT k.slot_key,s.inventory_item_id,COALESCE(i.item_name,''),COALESCE(s.mechanics,'{}'::jsonb)
    FROM keys k
    LEFT JOIN public.discord_character_equipment_slots s ON s.character_id=v_character_id AND s.slot_key=k.slot_key
    LEFT JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
    ORDER BY k.sort_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_set_equipment_slot(
 p_player_id UUID,p_campaign_id UUID,p_inventory_item_id UUID,p_slot_key TEXT,p_mechanics JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_player UUID; v_character_id UUID; v_item_name TEXT; v_item_data JSONB; v_slot TEXT;
    v_props TEXT; v_two_handed BOOLEAN;
BEGIN
    v_slot:=LOWER(REPLACE(REPLACE(TRIM(COALESCE(p_slot_key,'')),' ','_'),'-','_'));
    v_player:=public.discord_resolve_active_player(p_player_id,p_campaign_id);
    SELECT c.character_id INTO v_character_id FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=v_player LIMIT 1 FOR UPDATE;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Active campaign character could not be found.'; END IF;
    SELECT i.item_name,i.item_data INTO v_item_name,v_item_data FROM public.discord_inventory_items i
    WHERE i.inventory_item_id=p_inventory_item_id AND i.character_id=v_character_id FOR UPDATE;
    IF v_item_name IS NULL THEN RAISE EXCEPTION 'Inventory item does not belong to the active character.'; END IF;
    IF NOT public.discord_slot_accepts_item(v_slot,v_item_name,COALESCE(v_item_data,'{}'::jsonb)||COALESCE(p_mechanics,'{}'::jsonb)) THEN
        RAISE EXCEPTION '% cannot be equipped in the % slot.',v_item_name,v_slot;
    END IF;

    v_props:=LOWER(COALESCE(p_mechanics->>'weaponProperties',v_item_data->>'weapon_properties',''));
    v_two_handed:=v_props LIKE '%two-handed%' OR LOWER(v_item_name)~'(greatclub|greatsword|greataxe|maul|glaive|halberd|pike|longbow|heavy crossbow)';
    IF v_slot='shield' THEN
        DELETE FROM public.discord_character_equipment_slots WHERE character_id=v_character_id AND slot_key='off_hand';
        DELETE FROM public.discord_character_equipment_slots s
        USING public.discord_inventory_items i
        WHERE s.character_id=v_character_id AND s.inventory_item_id=i.inventory_item_id AND s.slot_key='main_hand'
          AND (LOWER(COALESCE(s.mechanics->>'weaponProperties',i.item_data->>'weapon_properties','')) LIKE '%two-handed%'
               OR LOWER(i.item_name)~'(greatclub|greatsword|greataxe|maul|glaive|halberd|pike|longbow|heavy crossbow)');
    END IF;
    IF v_slot='off_hand' THEN
        DELETE FROM public.discord_character_equipment_slots WHERE character_id=v_character_id AND slot_key='shield';
        DELETE FROM public.discord_character_equipment_slots s
        USING public.discord_inventory_items i
        WHERE s.character_id=v_character_id AND s.inventory_item_id=i.inventory_item_id AND s.slot_key='main_hand'
          AND (LOWER(COALESCE(s.mechanics->>'weaponProperties',i.item_data->>'weapon_properties','')) LIKE '%two-handed%'
               OR LOWER(i.item_name)~'(greatclub|greatsword|greataxe|maul|glaive|halberd|pike|longbow|heavy crossbow)');
    END IF;
    IF v_two_handed AND v_slot='main_hand' THEN
        DELETE FROM public.discord_character_equipment_slots WHERE character_id=v_character_id AND slot_key IN('shield','off_hand');
    END IF;

    DELETE FROM public.discord_character_equipment_slots WHERE inventory_item_id=p_inventory_item_id;
    INSERT INTO public.discord_character_equipment_slots(character_id,slot_key,inventory_item_id,mechanics,equipped_at)
    VALUES(v_character_id,v_slot,p_inventory_item_id,COALESCE(p_mechanics,'{}'::jsonb),NOW())
    ON CONFLICT(character_id,slot_key) DO UPDATE SET inventory_item_id=EXCLUDED.inventory_item_id,mechanics=EXCLUDED.mechanics,equipped_at=NOW();
    PERFORM public.discord_sync_equipped_flags(v_character_id);
    RETURN jsonb_build_object('success',TRUE,'characterId',v_character_id,'slotKey',v_slot,'inventoryItemId',p_inventory_item_id,'itemName',v_item_name,
      'armorClass',public.discord_recalculate_equipment_ac_from_slots(v_character_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_clear_equipment_slot(p_player_id UUID,p_campaign_id UUID,p_slot_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_player UUID; v_character_id UUID; v_slot TEXT; v_item_name TEXT;
BEGIN
    v_slot:=LOWER(REPLACE(REPLACE(TRIM(COALESCE(p_slot_key,'')),' ','_'),'-','_'));
    v_player:=public.discord_resolve_active_player(p_player_id,p_campaign_id);
    SELECT c.character_id INTO v_character_id FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=v_player LIMIT 1 FOR UPDATE;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Active campaign character could not be found.'; END IF;
    SELECT i.item_name INTO v_item_name FROM public.discord_character_equipment_slots s
    JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
    WHERE s.character_id=v_character_id AND s.slot_key=v_slot;
    DELETE FROM public.discord_character_equipment_slots WHERE character_id=v_character_id AND slot_key=v_slot;
    PERFORM public.discord_sync_equipped_flags(v_character_id);
    RETURN jsonb_build_object('success',TRUE,'characterId',v_character_id,'slotKey',v_slot,'itemName',COALESCE(v_item_name,''),
      'armorClass',public.discord_recalculate_equipment_ac_from_slots(v_character_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_set_character_derived_ac(p_player_id UUID,p_campaign_id UUID,p_armor_class INTEGER)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_player UUID; v_character_id UUID; v_ac INTEGER;
BEGIN
    v_ac:=GREATEST(1,LEAST(40,COALESCE(p_armor_class,10)));
    v_player:=public.discord_resolve_active_player(p_player_id,p_campaign_id);
    SELECT c.character_id INTO v_character_id FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=v_player LIMIT 1 FOR UPDATE;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Active campaign character could not be found.'; END IF;
    UPDATE public.discord_characters SET armor_class=v_ac WHERE character_id=v_character_id;
    RETURN jsonb_build_object('success',TRUE,'characterId',v_character_id,'armorClass',v_ac);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_get_character_equipment(p_campaign_id UUID,p_character_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_character_id UUID; v_ac INTEGER;
BEGIN
    SELECT c.character_id,c.armor_class INTO v_character_id,v_ac FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND LOWER(c.character_name)=LOWER(TRIM(COALESCE(p_character_name,''))) LIMIT 1;
    IF v_character_id IS NULL THEN RETURN '{}'::jsonb; END IF;
    RETURN jsonb_build_object('characterId',v_character_id,'armorClass',v_ac,'slots',COALESCE((
      SELECT jsonb_agg(jsonb_build_object('slotKey',s.slot_key,'itemName',i.item_name,'itemData',i.item_data,'mechanics',s.mechanics) ORDER BY s.slot_key)
      FROM public.discord_character_equipment_slots s JOIN public.discord_inventory_items i ON i.inventory_item_id=s.inventory_item_id
      WHERE s.character_id=v_character_id),'[]'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION public.discord_inventory_suggested_equipment_slot(TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_slot_accepts_item(TEXT,TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_sync_equipped_flags(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_standard_armor_base(TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_standard_armor_max_dex(TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_recalculate_equipment_ac_from_slots(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_equipment_slots(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_set_equipment_slot(UUID,UUID,UUID,TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_clear_equipment_slot(UUID,UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_set_character_derived_ac(UUID,UUID,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_character_equipment(UUID,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_inventory_suggested_equipment_slot(TEXT,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_slot_accepts_item(TEXT,TEXT,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_sync_equipped_flags(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_standard_armor_base(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_standard_armor_max_dex(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_recalculate_equipment_ac_from_slots(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_equipment_slots(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_equipment_slot(UUID,UUID,UUID,TEXT,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_clear_equipment_slot(UUID,UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_character_derived_ac(UUID,UUID,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_character_equipment(UUID,TEXT) TO service_role;

COMMIT;
