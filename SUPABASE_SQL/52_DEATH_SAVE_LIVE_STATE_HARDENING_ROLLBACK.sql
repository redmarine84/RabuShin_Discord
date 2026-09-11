-- ============================================================
-- Rollback Migration 52 - Death Save Live State Hardening
-- Restores Build 6.19.1 live-state behavior while preserving the
-- previously-required named primary-key conflict target.
-- ============================================================
BEGIN;

DROP TRIGGER IF EXISTS trg_discord_audit_death_save_state
ON public.discord_character_death_saves;
DROP FUNCTION IF EXISTS public.discord_audit_death_save_state();

CREATE OR REPLACE FUNCTION public.discord_sync_character_death_save_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NEW.life_state='alive' AND COALESCE(NEW.current_hp,0)<=0 THEN
        IF TG_OP='INSERT'
           OR COALESCE(OLD.current_hp,0)>0
           OR COALESCE(OLD.life_state,'alive')<>'alive' THEN
            INSERT INTO public.discord_character_death_saves(
                character_id,campaign_id,successes,failures,stable,
                last_roll,last_result,last_resolved_round,updated_at
            )
            VALUES(NEW.character_id,NEW.campaign_id,0,0,FALSE,NULL,'',NULL,NOW())
            ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO UPDATE
            SET campaign_id=EXCLUDED.campaign_id,successes=0,failures=0,stable=FALSE,
                last_roll=NULL,last_result='',last_resolved_round=NULL,updated_at=NOW();
        ELSE
            INSERT INTO public.discord_character_death_saves(character_id,campaign_id)
            VALUES(NEW.character_id,NEW.campaign_id)
            ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO NOTHING;
        END IF;
    ELSIF COALESCE(NEW.current_hp,0)>0 THEN
        INSERT INTO public.discord_character_death_saves(
            character_id,campaign_id,successes,failures,stable,
            last_roll,last_result,last_resolved_round,updated_at
        )
        VALUES(NEW.character_id,NEW.campaign_id,0,0,FALSE,NULL,'',NULL,NOW())
        ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO UPDATE
        SET campaign_id=EXCLUDED.campaign_id,successes=0,failures=0,stable=FALSE,
            last_resolved_round=NULL,updated_at=NOW();
    END IF;
    RETURN NEW;
END;
$$;

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
    v_round INTEGER;
    v_combat_active BOOLEAN:=FALSE;
    v_current_turn BOOLEAN:=FALSE;
BEGIN
    SELECT c.* INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character.character_id IS NULL THEN RETURN; END IF;

    IF v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0 THEN
        INSERT INTO public.discord_character_death_saves(character_id,campaign_id)
        VALUES(v_character.character_id,p_campaign_id)
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
           v_character.life_state,COALESCE(ds.successes,0),COALESCE(ds.failures,0),
           COALESCE(ds.stable,FALSE),ds.last_roll,COALESCE(ds.last_result,'')::TEXT,
           ds.last_resolved_round,v_round,v_combat_active,v_current_turn,
           (v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0),
           (v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0
             AND NOT COALESCE(ds.stable,FALSE)
             AND (NOT v_combat_active OR ds.last_resolved_round IS DISTINCT FROM v_round)),
           (v_combat_active AND ds.last_resolved_round IS NOT DISTINCT FROM v_round)
    FROM (SELECT 1) q
    LEFT JOIN public.discord_character_death_saves ds
      ON ds.character_id=v_character.character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_resolve_death_save(UUID,UUID,INTEGER);
CREATE OR REPLACE FUNCTION public.discord_resolve_death_save(
    p_player_id UUID,p_campaign_id UUID,p_roll INTEGER
)
RETURNS TABLE(
    character_id UUID,character_name TEXT,roll INTEGER,outcome TEXT,successes INTEGER,failures INTEGER,
    stable BOOLEAN,current_hp INTEGER,max_hp INTEGER,dead BOOLEAN,combat_active BOOLEAN,
    is_current_turn BOOLEAN,message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_state public.discord_character_death_saves%ROWTYPE;
    v_round INTEGER:=NULL;
    v_combat_active BOOLEAN:=FALSE;
    v_current_turn BOOLEAN:=FALSE;
    v_successes INTEGER:=0;
    v_failures INTEGER:=0;
    v_stable BOOLEAN:=FALSE;
    v_outcome TEXT:='';
    v_message TEXT:='';
    v_mark JSONB:=NULL;
BEGIN
    IF p_roll IS NULL OR p_roll<1 OR p_roll>20 THEN
        RAISE EXCEPTION 'Death saving throw must be a natural d20 result from 1 through 20.';
    END IF;

    SELECT c.* INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF v_character.life_state<>'alive' THEN RAISE EXCEPTION '% is already dead.',v_character.character_name; END IF;
    IF COALESCE(v_character.current_hp,0)<>0 THEN
        RAISE EXCEPTION '% is not at 0 HP and does not need a death saving throw.',v_character.character_name;
    END IF;

    SELECT COALESCE(s.active,FALSE),
           CASE WHEN COALESCE(s.active,FALSE) AND s.current_turn_type='character'
                     AND s.current_turn_character_id=v_character.character_id THEN TRUE ELSE FALSE END,
           CASE WHEN COALESCE(s.active,FALSE) THEN GREATEST(1,COALESCE(s.round_number,1)) ELSE NULL END
    INTO v_combat_active,v_current_turn,v_round
    FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id;

    v_combat_active:=COALESCE(v_combat_active,FALSE);
    v_current_turn:=COALESCE(v_current_turn,FALSE);
    IF v_combat_active AND NOT v_current_turn THEN
        RAISE EXCEPTION 'It is not %''s initiative turn.',v_character.character_name;
    END IF;

    INSERT INTO public.discord_character_death_saves(character_id,campaign_id)
    VALUES(v_character.character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO NOTHING;

    SELECT * INTO v_state FROM public.discord_character_death_saves ds
    WHERE ds.character_id=v_character.character_id FOR UPDATE;

    IF COALESCE(v_state.stable,FALSE) THEN
        RAISE EXCEPTION '% is already stable and does not make death saving throws.',v_character.character_name;
    END IF;

    IF v_combat_active AND v_state.last_resolved_round IS NOT DISTINCT FROM v_round THEN
        RETURN QUERY SELECT v_character.character_id,v_character.character_name,
            COALESCE(v_state.last_roll,p_roll),'already_resolved'::TEXT,
            COALESCE(v_state.successes,0),COALESCE(v_state.failures,0),COALESCE(v_state.stable,FALSE),
            COALESCE(v_character.current_hp,0),GREATEST(1,COALESCE(v_character.max_hp,1)),
            FALSE,v_combat_active,v_current_turn,
            'This death saving throw was already resolved for the current round.'::TEXT;
        RETURN;
    END IF;

    v_successes:=COALESCE(v_state.successes,0);
    v_failures:=COALESCE(v_state.failures,0);

    IF p_roll=20 THEN
        UPDATE public.discord_characters c
        SET current_hp=1,character_data=COALESCE(c.character_data,'{}'::jsonb)||jsonb_build_object('current_hp',1),updated_at=NOW()
        WHERE c.character_id=v_character.character_id;
        UPDATE public.discord_character_death_saves ds
        SET successes=0,failures=0,stable=FALSE,last_roll=20,last_result='natural_20',
            last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,updated_at=NOW()
        WHERE ds.character_id=v_character.character_id;
        v_successes:=0;v_failures:=0;v_stable:=FALSE;v_outcome:='natural_20';
        v_message:=v_character.character_name||' rolled a natural 20 and regained 1 HP.';
    ELSIF p_roll>=10 THEN
        v_successes:=LEAST(3,v_successes+1);
        IF v_successes>=3 THEN
            v_successes:=0;v_failures:=0;v_stable:=TRUE;v_outcome:='stabilized';
            v_message:=v_character.character_name||' reached three successful death saving throws and is stable.';
        ELSE
            v_stable:=FALSE;v_outcome:='success';
            v_message:=v_character.character_name||' succeeded on a death saving throw.';
        END IF;
        UPDATE public.discord_character_death_saves ds
        SET successes=v_successes,failures=v_failures,stable=v_stable,last_roll=p_roll,last_result=v_outcome,
            last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,updated_at=NOW()
        WHERE ds.character_id=v_character.character_id;
    ELSE
        IF p_roll=1 THEN v_failures:=LEAST(3,v_failures+2);v_outcome:='natural_1_failure';
        ELSE v_failures:=LEAST(3,v_failures+1);v_outcome:='failure'; END IF;
        IF v_failures>=3 THEN
            v_failures:=3;v_outcome:='dead';
            v_message:=v_character.character_name||' reached three failed death saving throws and died.';
            UPDATE public.discord_character_death_saves ds
            SET successes=v_successes,failures=3,stable=FALSE,last_roll=p_roll,last_result='dead',
                last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,updated_at=NOW()
            WHERE ds.character_id=v_character.character_id;
            v_mark:=public.discord_gm_mark_character_dead(
                p_campaign_id,v_character.character_name,'Failed three death saving throws.');
        ELSE
            v_stable:=FALSE;
            v_message:=CASE WHEN p_roll=1
                THEN v_character.character_name||' rolled a natural 1 and suffered two death saving throw failures.'
                ELSE v_character.character_name||' failed a death saving throw.' END;
            UPDATE public.discord_character_death_saves ds
            SET successes=v_successes,failures=v_failures,stable=FALSE,last_roll=p_roll,last_result=v_outcome,
                last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,updated_at=NOW()
            WHERE ds.character_id=v_character.character_id;
        END IF;
    END IF;

    RETURN QUERY SELECT v_character.character_id,v_character.character_name,p_roll,v_outcome,
        v_successes,v_failures,v_stable,CASE WHEN v_outcome='natural_20' THEN 1 ELSE 0 END,
        GREATEST(1,COALESCE(v_character.max_hp,1)),(v_outcome='dead'),v_combat_active,v_current_turn,v_message;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_sync_character_death_save_state() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_death_save_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_resolve_death_save(UUID,UUID,INTEGER) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_get_death_save_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_resolve_death_save(UUID,UUID,INTEGER) TO service_role;

DROP TABLE IF EXISTS public.discord_death_save_events;
ALTER TABLE public.discord_character_death_saves
    DROP COLUMN IF EXISTS last_resolved_at,
    DROP COLUMN IF EXISTS track_started_at;

NOTIFY pgrst,'reload schema';
COMMIT;
