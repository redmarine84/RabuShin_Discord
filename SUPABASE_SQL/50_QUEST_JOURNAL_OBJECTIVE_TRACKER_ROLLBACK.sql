-- Build 6.20.1 / Migration 50 rollback
BEGIN;

DROP FUNCTION IF EXISTS public.discord_gm_get_quest_state(UUID);
DROP FUNCTION IF EXISTS public.discord_gm_set_quest_status(UUID,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_upsert_quest_objective(UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,INTEGER,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_upsert_quest(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_sync_quest_journal(UUID);

DROP INDEX IF EXISTS public.ux_discord_journal_quest_mirror;
ALTER TABLE public.discord_journal_entries DROP COLUMN IF EXISTS quest_id;

DROP TABLE IF EXISTS public.discord_quest_objectives;
DROP TABLE IF EXISTS public.discord_quests;

COMMIT;
