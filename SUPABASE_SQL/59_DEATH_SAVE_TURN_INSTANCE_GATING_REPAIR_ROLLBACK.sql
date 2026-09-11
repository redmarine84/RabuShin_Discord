-- ============================================================
-- EMERGENCY ROLLBACK for Migration 59
--
-- This intentionally restores the older Migration 52 ROUND-based
-- Death Save gate. Use only if Migration 59 must be backed out.
-- It does not delete counters or event history.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.discord_get_death_save_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_death_save_state(
    p_player_id UUID,p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,character_name TEXT,current_hp INTEGER,max_hp INTEGER,life_state TEXT,
    successes INTEGER,failures INTEGER,stable BOOLEAN,last_roll INTEGER,last_result TEXT,
    last_resolved_round INTEGER,current_round INTEGER,combat_active BOOLEAN,is_current_turn BOOLEAN,
    active BOOLEAN,requires_save BOOLEAN,resolved_this_round BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_round INTEGER:=NULL;
    v_combat_active BOOLEAN:=FALSE;
    v_current_turn BOOLEAN:=FALSE;
BEGIN
    SELECT c.* INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character.character_id IS NULL THEN RETURN; END IF;

    IF v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0 THEN
        INSERT INTO public.discord_character_death_saves(character_id,campaign_id,track_started_at)
        VALUES(v_character.character_id,p_campaign_id,NOW())
        ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO NOTHING;
    END IF;

    SELECT COALESCE(s.active,FALSE),
           CASE WHEN COALESCE(s.active,FALSE) AND s.current_turn_type='character'
                     AND s.current_turn_character_id=v_character.character_id THEN TRUE ELSE FALSE END,
           CASE WHEN COALESCE(s.active,FALSE) THEN GREATEST(1,COALESCE(s.round_number,1)) ELSE NULL END
    INTO v_combat_active,v_current_turn,v_round
    FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id;

    v_combat_active:=COALESCE(v_combat_active,FALSE);
    v_current_turn:=COALESCE(v_current_turn,FALSE);

    RETURN QUERY
    SELECT v_character.character_id,v_character.character_name,
           COALESCE(v_character.current_hp,0),GREATEST(1,COALESCE(v_character.max_hp,1)),
           v_character.life_state,
           COALESCE(ev.successes_after,ds.successes,0),
           COALESCE(ev.failures_after,ds.failures,0),
           COALESCE(ev.stable_after,ds.stable,FALSE),
           CASE WHEN ev.event_id IS NOT NULL THEN ev.roll ELSE ds.last_roll END,
           COALESCE(ev.outcome,ds.last_result,'')::TEXT,
           CASE WHEN ev.event_id IS NOT NULL THEN ev.resolved_round ELSE ds.last_resolved_round END,
           v_round,v_combat_active,v_current_turn,
           (v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0),
           (v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0
             AND NOT COALESCE(ev.stable_after,ds.stable,FALSE)
             AND (NOT v_combat_active OR COALESCE(ev.resolved_round,ds.last_resolved_round) IS DISTINCT FROM v_round)),
           (v_combat_active AND COALESCE(ev.resolved_round,ds.last_resolved_round) IS NOT DISTINCT FROM v_round)
    FROM public.discord_character_death_saves ds
    LEFT JOIN LATERAL (
        SELECT e.* FROM public.discord_death_save_events e
        WHERE e.character_id=ds.character_id AND e.track_started_at=ds.track_started_at
        ORDER BY e.event_id DESC LIMIT 1
    ) ev ON TRUE
    WHERE ds.character_id=v_character.character_id;
END;
$$;

-- Restore only the duplicate-save gate inside the resolver while preserving
-- the same Migration 52 mechanics. This full definition is deliberately
-- omitted from the emergency rollback to avoid silently reintroducing an
-- obsolete resolver from an unknown later schema.
--
-- If this rollback is ever required, run the repository's authoritative
-- SUPABASE_SQL/52_DEATH_SAVE_LIVE_STATE_HARDENING.sql after this file.
-- That migration recreates discord_resolve_death_save with the matching
-- round-based behavior.

REVOKE ALL ON FUNCTION public.discord_get_death_save_state(UUID,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_get_death_save_state(UUID,UUID) TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
