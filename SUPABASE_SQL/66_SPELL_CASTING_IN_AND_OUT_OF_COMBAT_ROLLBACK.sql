-- ============================================================
-- RabuShinAIGM Build 6.30.8 / Migration 66 rollback
--
-- Removes the new authoritative cast RPC.
-- Already-consumed spell slots are intentionally NOT refunded because a
-- rollback cannot safely determine which completed casts should be reversed.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.discord_gm_cast_spell(UUID,UUID,TEXT,INTEGER,TEXT);

NOTIFY pgrst,'reload schema';

COMMIT;
