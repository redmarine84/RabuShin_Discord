-- ============================================================
-- RabuShinAIGM Rules Build 6.19.2
-- Migration 47 DATABASE ROLLBACK
--
-- Restores the Build 6.18.4 player costed-movement RPC and removes only
-- objects introduced by Migration 47. Build 6.19.1 death-save objects remain.
-- ============================================================

BEGIN;

DROP TRIGGER IF EXISTS trg_discord_process_stable_recovery_world_time
ON public.discord_campaign_world_time;

DROP TRIGGER IF EXISTS trg_discord_schedule_stable_recovery
ON public.discord_character_death_saves;

DROP TRIGGER IF EXISTS trg_discord_recharge_action_surge_on_rest
ON public.discord_character_rest_state;

DROP FUNCTION IF EXISTS public.discord_gm_position_combat_token_action_economy(UUID,TEXT,TEXT,INTEGER,INTEGER,INTEGER,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_get_action_economy_state(UUID);
DROP FUNCTION IF EXISTS public.discord_gm_use_action_surge(UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_dash_action(UUID,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_gm_spend_action_resource(UUID,TEXT,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_player_use_action_surge(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_player_dash_action(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_player_spend_action_resource(UUID,UUID,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_get_action_economy_state(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_action_economy_use_surge_internal(UUID,UUID,TEXT);
DROP FUNCTION IF EXISTS public.discord_action_economy_dash_internal(UUID,TEXT,UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_action_economy_spend_internal(UUID,TEXT,UUID,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_action_economy_build_state(UUID,TEXT,UUID);
DROP FUNCTION IF EXISTS public.discord_action_economy_ensure_entity(UUID,TEXT,UUID);
DROP FUNCTION IF EXISTS public.discord_action_economy_effective_speed(UUID,TEXT,UUID);
DROP FUNCTION IF EXISTS public.discord_action_economy_movement_blocked(UUID,TEXT,UUID);
DROP FUNCTION IF EXISTS public.discord_action_economy_is_incapacitated(UUID,TEXT,UUID);
DROP FUNCTION IF EXISTS public.discord_recharge_action_surge_on_rest();
DROP FUNCTION IF EXISTS public.discord_sync_fighter_action_surge(UUID,BOOLEAN);
DROP FUNCTION IF EXISTS public.discord_gm_set_monster_walking_speed(UUID,TEXT[],INTEGER);

DROP FUNCTION IF EXISTS public.discord_get_stable_recovery_state(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_process_stable_recovery_on_world_time();
DROP FUNCTION IF EXISTS public.discord_process_stable_recovery(UUID);
DROP FUNCTION IF EXISTS public.discord_schedule_stable_recovery();

DROP TABLE IF EXISTS public.discord_combat_action_economy;
DROP TABLE IF EXISTS public.discord_character_action_surge;
DROP TABLE IF EXISTS public.discord_combat_monster_movement_speed;
DROP TABLE IF EXISTS public.discord_character_stable_recovery;

-- Restore exact Build 6.18.4 / Migration 41 player costed movement behavior.
DROP FUNCTION IF EXISTS public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER);
CREATE OR REPLACE FUNCTION public.discord_move_own_combat_token_costed(p_player_id UUID,p_campaign_id UUID,p_grid_x INTEGER,p_grid_y INTEGER,p_move_cost_ft INTEGER)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE; v_token public.discord_campaign_combat_tokens%ROWTYPE;
    v_remaining INTEGER; v_effective_speed INTEGER; v_cost INTEGER:=GREATEST(0,COALESCE(p_move_cost_ft,0));
BEGIN
    IF p_grid_x NOT BETWEEN 0 AND 19 OR p_grid_y NOT BETWEEN 0 AND 19 THEN RAISE EXCEPTION 'Tactical destination must be inside the 20x20 encounter grid.'; END IF;
    IF v_cost>1000 THEN RAISE EXCEPTION 'Invalid tactical movement cost.'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members cm WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id)
    THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE)
    THEN RAISE EXCEPTION 'There is no active combat.'; END IF;
    SELECT c.* INTO v_character FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Your campaign character could not be found.'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.current_turn_type='character' AND s.current_turn_character_id=v_character.character_id)
    THEN RAISE EXCEPTION 'It is not your character''s turn.'; END IF;
    PERFORM public.discord_sync_tactical_tokens(p_campaign_id);
    SELECT t.* INTO v_token FROM public.discord_campaign_combat_tokens t WHERE t.campaign_id=p_campaign_id AND t.character_id=v_character.character_id LIMIT 1 FOR UPDATE;
    IF v_token.token_id IS NULL THEN RAISE EXCEPTION 'Your tactical token could not be found.'; END IF;
    IF COALESCE(v_character.current_hp,0)<=0 THEN RAISE EXCEPTION 'Your character cannot move while at 0 HP.'; END IF;
    v_effective_speed:=COALESCE(public.discord_exhaustion_effective_speed(v_character.character_id),COALESCE(v_character.speed,30));
    v_remaining:=GREATEST(0,v_effective_speed-COALESCE(v_token.movement_spent_ft,0));
    IF v_cost>v_remaining THEN RAISE EXCEPTION 'That terrain-aware move costs % ft., but only % ft. of movement remains after Exhaustion.',v_cost,v_remaining; END IF;
    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_tokens t
        LEFT JOIN public.discord_characters c ON c.character_id=t.character_id
        LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=t.combat_monster_id
        WHERE t.campaign_id=p_campaign_id AND t.token_id<>v_token.token_id AND t.grid_x=p_grid_x AND t.grid_y=p_grid_y
          AND ((t.entity_type='character' AND COALESCE(c.current_hp,0)>0) OR (t.entity_type='monster' AND COALESCE(m.defeated,FALSE)=FALSE)))
    THEN RAISE EXCEPTION 'Another active combatant already occupies that square.'; END IF;
    UPDATE public.discord_campaign_combat_tokens t SET grid_x=p_grid_x,grid_y=p_grid_y,movement_spent_ft=t.movement_spent_ft+v_cost,updated_at=NOW()
    WHERE t.token_id=v_token.token_id RETURNING t.* INTO v_token;
    RETURN jsonb_build_object('token_id',v_token.token_id,'grid_x',v_token.grid_x,'grid_y',v_token.grid_y,'move_cost_ft',v_cost,
        'base_speed_ft',COALESCE(v_character.speed,30),'effective_speed_ft',v_effective_speed,'movement_spent_ft',v_token.movement_spent_ft,
        'movement_remaining_ft',GREATEST(0,v_effective_speed-v_token.movement_spent_ft));
END;
$$;

REVOKE ALL ON FUNCTION public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER)
TO service_role;

COMMIT;
