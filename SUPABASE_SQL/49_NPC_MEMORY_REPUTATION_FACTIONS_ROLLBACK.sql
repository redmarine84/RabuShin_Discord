-- RabuShinAIGM Build 6.20 / Migration 49 rollback
BEGIN;

DROP FUNCTION IF EXISTS public.discord_gm_get_social_state(UUID);
DROP FUNCTION IF EXISTS public.discord_gm_adjust_faction_reputation(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_remember_npc_interaction(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER);
DROP FUNCTION IF EXISTS public.discord_social_resolve_character(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_social_tier(INTEGER);
DROP FUNCTION IF EXISTS public.discord_social_key(TEXT);

DROP TABLE IF EXISTS public.discord_faction_reputation_events;
DROP TABLE IF EXISTS public.discord_faction_reputation;
DROP TABLE IF EXISTS public.discord_npc_memories;
DROP TABLE IF EXISTS public.discord_npc_opinions;
DROP TABLE IF EXISTS public.discord_campaign_npcs;
DROP TABLE IF EXISTS public.discord_campaign_factions;

COMMIT;
