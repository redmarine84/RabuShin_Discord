BEGIN;
DO $$ BEGIN
    IF to_regclass('public.discord_character_equipment_slots') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_discord_equipment_slots_changed ON public.discord_character_equipment_slots;
    END IF;
END $$;
DROP FUNCTION IF EXISTS public.discord_gm_get_character_equipment(UUID,TEXT);
DROP FUNCTION IF EXISTS public.discord_set_character_derived_ac(UUID,UUID,INTEGER);
DROP FUNCTION IF EXISTS public.discord_clear_equipment_slot(UUID,UUID,TEXT);
DROP FUNCTION IF EXISTS public.discord_set_equipment_slot(UUID,UUID,UUID,TEXT,JSONB);
DROP FUNCTION IF EXISTS public.discord_get_equipment_slots(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_equipment_slots_changed();
DROP FUNCTION IF EXISTS public.discord_recalculate_equipment_ac_from_slots(UUID);
DROP FUNCTION IF EXISTS public.discord_standard_armor_max_dex(TEXT);
DROP FUNCTION IF EXISTS public.discord_standard_armor_base(TEXT);
DROP FUNCTION IF EXISTS public.discord_sync_equipped_flags(UUID);
DROP FUNCTION IF EXISTS public.discord_slot_accepts_item(TEXT,TEXT,JSONB);
DROP FUNCTION IF EXISTS public.discord_inventory_suggested_equipment_slot(TEXT,JSONB);
DO $$ BEGIN
    IF to_regclass('public.discord_equipment_ac_baseline') IS NOT NULL THEN
        UPDATE public.discord_characters c SET armor_class=b.previous_armor_class
        FROM public.discord_equipment_ac_baseline b WHERE b.character_id=c.character_id;
    END IF;
END $$;
DROP TABLE IF EXISTS public.discord_character_equipment_slots;
DROP TABLE IF EXISTS public.discord_equipment_ac_baseline;
COMMIT;
