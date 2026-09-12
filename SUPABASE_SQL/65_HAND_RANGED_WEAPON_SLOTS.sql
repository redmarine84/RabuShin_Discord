-- ============================================================
-- RabuShinAIGM Build 6.30.7
-- Migration 65 - Hand / Ranged Weapon Slots
--
-- Expands Build 6.29.3 so these weapons may use Hand or Ranged:
-- Shortbow, Longbow, Javelin, Spear, Light Crossbow, Heavy Crossbow.
-- ============================================================

BEGIN;

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
    v_thrown_hand_ranged BOOLEAN;
    v_bow_crossbow_hand_ranged BOOLEAN;
    v_hand_ranged BOOLEAN;
    v_dedicated_ranged BOOLEAN;
BEGIN
    v_shield:=v_type='shield' OR v_name LIKE '%shield%';
    v_ammo:=v_type='ammunition' OR v_name~'(arrow|bolt|bullet|needle|ammunition)';

    v_thrown_hand_ranged:=
        v_name LIKE '%javelin%'
        OR v_name LIKE '%spear%';

    v_bow_crossbow_hand_ranged:=
        v_name LIKE '%shortbow%'
        OR v_name LIKE '%longbow%'
        OR (
            v_name LIKE '%crossbow%'
            AND (v_name LIKE '%light%' OR v_name LIKE '%heavy%')
        );

    v_hand_ranged:=v_thrown_hand_ranged OR v_bow_crossbow_hand_ranged;

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

        -- Main Hand may hold the named Hand / Ranged families.
        WHEN 'main_hand' THEN
            v_weapon AND (NOT v_dedicated_ranged OR v_hand_ranged)

        -- Preserve the existing Javelin behavior and extend it to Spear.
        -- Two-handed bows/crossbows are intentionally not allowed in Off Hand.
        WHEN 'off_hand' THEN
            v_shield OR (v_weapon AND (NOT v_dedicated_ranged OR v_thrown_hand_ranged))

        WHEN 'ranged' THEN
            v_weapon AND (v_dedicated_ranged OR v_thrown_hand_ranged)

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

REVOKE ALL ON FUNCTION public.discord_slot_accepts_item(TEXT,TEXT,JSONB) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_slot_accepts_item(TEXT,TEXT,JSONB) TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
