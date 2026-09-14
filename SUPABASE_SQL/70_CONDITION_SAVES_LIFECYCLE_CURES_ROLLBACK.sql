-- RabuShinAIGM Build 6.30.11 - Migration 70 rollback
-- WARNING: rolling back removes Build 6.30.11 lifecycle metadata, suppressions,
-- and temporary immunities. It does not recreate conditions that were already
-- cured/removed while the build was active.

BEGIN;

DROP TRIGGER IF EXISTS trg_discord_condition_world_time_lifecycle ON public.discord_campaign_world_time;
DROP TRIGGER IF EXISTS trg_discord_condition_source_death_cleanup ON public.discord_campaign_combat_monsters;
DROP TRIGGER IF EXISTS trg_discord_condition_combat_end_cleanup ON public.discord_campaign_combat_state;
DROP TRIGGER IF EXISTS trg_discord_condition_sync_legacy_after_delete ON public.discord_combat_conditions;

DROP FUNCTION IF EXISTS public.discord_condition_sync_legacy_after_delete();
DROP FUNCTION IF EXISTS public.discord_condition_world_time_lifecycle();
DROP FUNCTION IF EXISTS public.discord_condition_source_death_cleanup();
DROP FUNCTION IF EXISTS public.discord_condition_combat_end_cleanup();

DROP FUNCTION IF EXISTS public.discord_gm_resolve_condition_source_los(UUID,TEXT,TEXT,TEXT,BOOLEAN);
DROP FUNCTION IF EXISTS public.discord_gm_dispel_condition_effect(UUID,TEXT,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_consume_condition_cure_item(UUID,TEXT,UUID,TEXT);
DROP FUNCTION IF EXISTS public.discord_condition_builtin_cures(TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_apply_condition_extended(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,INTEGER,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_remove_condition_immunity(UUID,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_set_condition_immunity(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER);
DROP FUNCTION IF EXISTS public.discord_gm_restore_suppressed_condition(UUID,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_restore_suppressed_conditions(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_gm_suppress_condition(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER);
DROP FUNCTION IF EXISTS public.discord_gm_resolve_condition_save(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_resolve_condition_save(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_set_condition_lifecycle(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,TEXT,INTEGER,BOOLEAN,BOOLEAN,BOOLEAN);
DROP FUNCTION IF EXISTS public.discord_condition_find_target(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_condition_world_minute(UUID);

DROP TABLE IF EXISTS public.discord_condition_immunities;
DROP TABLE IF EXISTS public.discord_condition_suppressions;

ALTER TABLE public.discord_combat_conditions
    DROP COLUMN IF EXISTS source_monster_id,
    DROP COLUMN IF EXISTS source_character_id,
    DROP COLUMN IF EXISTS source_entity_type,
    DROP COLUMN IF EXISTS ends_on_source_lost_los,
    DROP COLUMN IF EXISTS ends_on_source_death,
    DROP COLUMN IF EXISTS ends_on_combat_end,
    DROP COLUMN IF EXISTS expires_world_minute,
    DROP COLUMN IF EXISTS spell_name,
    DROP COLUMN IF EXISTS magic_effect,
    DROP COLUMN IF EXISTS repeat_save_timing;

NOTIFY pgrst, 'reload schema';

COMMIT;
