-- Build 6.20.2 / Migration 51 rollback
BEGIN;

DROP FUNCTION IF EXISTS public.discord_gm_get_codex_state(UUID);
DROP FUNCTION IF EXISTS public.discord_gm_unlock_codex_entry(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_sync_codex_journal(UUID);

DROP INDEX IF EXISTS public.ux_discord_journal_codex_mirror;
ALTER TABLE public.discord_journal_entries DROP COLUMN IF EXISTS codex_entry_id;

DROP TABLE IF EXISTS public.discord_codex_events;
DROP TABLE IF EXISTS public.discord_codex_entries;

COMMIT;
