-- ============================================================
-- RabuShinAIGM Migration 59
-- Death Save Turn-Instance Gating Repair
--
-- Purpose:
--   Restore the Build 6.19.1 Migration 53 behavior after the live
--   database was found to still be using Migration 52 round gating.
--
-- Important:
--   * Does NOT alter death-save counters or event history.
--   * Does NOT touch Builds 6.22 / 6.22.1 / 6.23 objects.
--   * A normal Death Save is consumed only by a save-resolution event
--     at/after the active combat turn_started_at.
--   * damage_at_zero / damage_at_zero_critical do NOT consume the
--     character's normal Death Save for that turn.
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
    v_turn_started_at TIMESTAMPTZ:=NULL;
BEGIN
    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND c.player_id=p_player_id
    LIMIT 1;

    IF v_character.character_id IS NULL THEN RETURN; END IF;

    IF v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0 THEN
        INSERT INTO public.discord_character_death_saves(character_id,campaign_id,track_started_at)
        VALUES(v_character.character_id,p_campaign_id,NOW())
        ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO NOTHING;
    END IF;

    SELECT
        COALESCE(s.active,FALSE),
        CASE
            WHEN COALESCE(s.active,FALSE)
             AND s.current_turn_type='character'
             AND s.current_turn_character_id=v_character.character_id
            THEN TRUE ELSE FALSE
        END,
        CASE
            WHEN COALESCE(s.active,FALSE)
            THEN GREATEST(1,COALESCE(s.round_number,1))
            ELSE NULL
        END,
        CASE WHEN COALESCE(s.active,FALSE) THEN s.turn_started_at ELSE NULL END
    INTO v_combat_active,v_current_turn,v_round,v_turn_started_at
    FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id;

    v_combat_active:=COALESCE(v_combat_active,FALSE);
    v_current_turn:=COALESCE(v_current_turn,FALSE);

    RETURN QUERY
    SELECT
        v_character.character_id,
        v_character.character_name,
        COALESCE(v_character.current_hp,0),
        GREATEST(1,COALESCE(v_character.max_hp,1)),
        v_character.life_state,
        COALESCE(ev.successes_after,ds.successes,0),
        COALESCE(ev.failures_after,ds.failures,0),
        COALESCE(ev.stable_after,ds.stable,FALSE),
        CASE WHEN ev.event_id IS NOT NULL THEN ev.roll ELSE ds.last_roll END,
        COALESCE(ev.outcome,ds.last_result,'')::TEXT,
        CASE WHEN ev.event_id IS NOT NULL THEN ev.resolved_round ELSE ds.last_resolved_round END,
        v_round,
        v_combat_active,
        v_current_turn,
        (v_character.life_state='alive' AND COALESCE(v_character.current_hp,0)<=0),
        (
            v_character.life_state='alive'
            AND COALESCE(v_character.current_hp,0)<=0
            AND NOT COALESCE(ev.stable_after,ds.stable,FALSE)
            AND (
                NOT v_combat_active
                OR turn_ev.event_id IS NULL
            )
        ),
        (
            v_combat_active
            AND turn_ev.event_id IS NOT NULL
        )
    FROM public.discord_character_death_saves ds
    LEFT JOIN LATERAL (
        SELECT e.*
        FROM public.discord_death_save_events e
        WHERE e.character_id=ds.character_id
          AND e.track_started_at=ds.track_started_at
        ORDER BY e.event_id DESC
        LIMIT 1
    ) ev ON TRUE
    LEFT JOIN LATERAL (
        SELECT e.event_id
        FROM public.discord_death_save_events e
        WHERE e.character_id=ds.character_id
          AND e.track_started_at=ds.track_started_at
          AND e.outcome IN (
              'success',
              'failure',
              'natural_1_failure',
              'natural_20',
              'stabilized',
              'dead'
          )
          AND v_combat_active
          AND v_turn_started_at IS NOT NULL
          AND e.resolved_at>=v_turn_started_at
        ORDER BY e.resolved_at DESC,e.event_id DESC
        LIMIT 1
    ) turn_ev ON TRUE
    WHERE ds.character_id=v_character.character_id;
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
    v_round INTEGER:=NULL;
    v_combat_active BOOLEAN:=FALSE;
    v_current_turn BOOLEAN:=FALSE;
    v_turn_started_at TIMESTAMPTZ:=NULL;

    v_row_successes INTEGER:=0;
    v_row_failures INTEGER:=0;
    v_row_stable BOOLEAN:=FALSE;
    v_row_last_roll INTEGER:=NULL;
    v_row_last_result TEXT:='';
    v_row_last_resolved_round INTEGER:=NULL;
    v_track_started_at TIMESTAMPTZ:=NULL;

    v_event_found BOOLEAN:=FALSE;
    v_event_roll INTEGER:=NULL;
    v_event_outcome TEXT:=NULL;
    v_event_successes INTEGER:=NULL;
    v_event_failures INTEGER:=NULL;
    v_event_stable BOOLEAN:=NULL;
    v_event_resolved_round INTEGER:=NULL;

    v_turn_event_found BOOLEAN:=FALSE;

    v_successes INTEGER:=0;
    v_failures INTEGER:=0;
    v_stable BOOLEAN:=FALSE;
    v_last_resolved_round INTEGER:=NULL;
    v_outcome TEXT:='';
    v_message TEXT:='';
    v_mark JSONB:=NULL;
BEGIN
    IF p_roll IS NULL OR p_roll<1 OR p_roll>20 THEN
        RAISE EXCEPTION 'Death saving throw must be a natural d20 result from 1 through 20.';
    END IF;

    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND c.player_id=p_player_id
    LIMIT 1
    FOR UPDATE;

    IF v_character.character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    IF v_character.life_state<>'alive' THEN
        RAISE EXCEPTION '% is already dead.',v_character.character_name;
    END IF;

    IF COALESCE(v_character.current_hp,0)<>0 THEN
        RAISE EXCEPTION '% is not at 0 HP and does not need a death saving throw.',
            v_character.character_name;
    END IF;

    SELECT
        COALESCE(s.active,FALSE),
        CASE
            WHEN COALESCE(s.active,FALSE)
             AND s.current_turn_type='character'
             AND s.current_turn_character_id=v_character.character_id
            THEN TRUE ELSE FALSE
        END,
        CASE
            WHEN COALESCE(s.active,FALSE)
            THEN GREATEST(1,COALESCE(s.round_number,1))
            ELSE NULL
        END,
        CASE WHEN COALESCE(s.active,FALSE) THEN s.turn_started_at ELSE NULL END
    INTO v_combat_active,v_current_turn,v_round,v_turn_started_at
    FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id;

    v_combat_active:=COALESCE(v_combat_active,FALSE);
    v_current_turn:=COALESCE(v_current_turn,FALSE);

    IF v_combat_active AND NOT v_current_turn THEN
        RAISE EXCEPTION 'It is not %''s initiative turn.',v_character.character_name;
    END IF;

    IF v_combat_active AND v_turn_started_at IS NULL THEN
        RAISE EXCEPTION 'The active combat turn has no turn_started_at timestamp; refusing to risk resolving a duplicate Death Save.';
    END IF;

    INSERT INTO public.discord_character_death_saves(
        character_id,campaign_id,track_started_at
    )
    VALUES(v_character.character_id,p_campaign_id,NOW())
    ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey
    DO NOTHING;

    SELECT
        COALESCE(ds.successes,0),
        COALESCE(ds.failures,0),
        COALESCE(ds.stable,FALSE),
        ds.last_roll,
        COALESCE(ds.last_result,''),
        ds.last_resolved_round,
        ds.track_started_at
    INTO
        v_row_successes,
        v_row_failures,
        v_row_stable,
        v_row_last_roll,
        v_row_last_result,
        v_row_last_resolved_round,
        v_track_started_at
    FROM public.discord_character_death_saves ds
    WHERE ds.character_id=v_character.character_id
    FOR UPDATE;

    SELECT
        TRUE,
        e.roll,
        e.outcome,
        e.successes_after,
        e.failures_after,
        e.stable_after,
        e.resolved_round
    INTO
        v_event_found,
        v_event_roll,
        v_event_outcome,
        v_event_successes,
        v_event_failures,
        v_event_stable,
        v_event_resolved_round
    FROM public.discord_death_save_events e
    WHERE e.character_id=v_character.character_id
      AND e.track_started_at=v_track_started_at
    ORDER BY e.event_id DESC
    LIMIT 1;

    v_event_found:=COALESCE(v_event_found,FALSE);

    IF v_event_found THEN
        v_successes:=COALESCE(v_event_successes,0);
        v_failures:=COALESCE(v_event_failures,0);
        v_stable:=COALESCE(v_event_stable,FALSE);
        v_last_resolved_round:=v_event_resolved_round;
    ELSE
        v_successes:=v_row_successes;
        v_failures:=v_row_failures;
        v_stable:=v_row_stable;
        v_last_resolved_round:=v_row_last_resolved_round;
    END IF;

    IF v_stable THEN
        RAISE EXCEPTION '% is already stable and does not make death saving throws.',
            v_character.character_name;
    END IF;

    -- Migration 59 / restored Migration 53 rule:
    -- Only an actual routine Death Save resolution in THIS combat turn instance
    -- consumes the character's save. Damage-at-zero events do not.
    IF v_combat_active THEN
        SELECT TRUE
        INTO v_turn_event_found
        FROM public.discord_death_save_events e
        WHERE e.character_id=v_character.character_id
          AND e.track_started_at=v_track_started_at
          AND e.outcome IN (
              'success',
              'failure',
              'natural_1_failure',
              'natural_20',
              'stabilized',
              'dead'
          )
          AND e.resolved_at>=v_turn_started_at
        ORDER BY e.resolved_at DESC,e.event_id DESC
        LIMIT 1;

        v_turn_event_found:=COALESCE(v_turn_event_found,FALSE);

        IF v_turn_event_found THEN
            RETURN QUERY
            SELECT
                v_character.character_id,
                v_character.character_name,
                COALESCE(v_event_roll,v_row_last_roll,p_roll),
                'already_resolved'::TEXT,
                v_successes,
                v_failures,
                v_stable,
                COALESCE(v_character.current_hp,0),
                GREATEST(1,COALESCE(v_character.max_hp,1)),
                FALSE,
                v_combat_active,
                v_current_turn,
                'This death saving throw was already resolved for the current turn.'::TEXT;
            RETURN;
        END IF;
    END IF;

    IF p_roll=20 THEN
        UPDATE public.discord_characters c
        SET current_hp=1,
            character_data=COALESCE(c.character_data,'{}'::jsonb)
                || jsonb_build_object('current_hp',1),
            updated_at=NOW()
        WHERE c.character_id=v_character.character_id;

        v_successes:=0;
        v_failures:=0;
        v_stable:=FALSE;
        v_outcome:='natural_20';
        v_message:=v_character.character_name ||
            ' rolled a natural 20 and regained 1 HP.';

        UPDATE public.discord_character_death_saves ds
        SET successes=v_successes,
            failures=v_failures,
            stable=v_stable,
            last_roll=p_roll,
            last_result=v_outcome,
            last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
            last_resolved_at=NOW(),
            updated_at=NOW()
        WHERE ds.character_id=v_character.character_id;

    ELSIF p_roll>=10 THEN
        v_successes:=LEAST(3,v_successes+1);

        IF v_successes>=3 THEN
            v_successes:=0;
            v_failures:=0;
            v_stable:=TRUE;
            v_outcome:='stabilized';
            v_message:=v_character.character_name ||
                ' reached three successful death saving throws and is stable.';
        ELSE
            v_stable:=FALSE;
            v_outcome:='success';
            v_message:=v_character.character_name ||
                ' succeeded on a death saving throw.';
        END IF;

        UPDATE public.discord_character_death_saves ds
        SET successes=v_successes,
            failures=v_failures,
            stable=v_stable,
            last_roll=p_roll,
            last_result=v_outcome,
            last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
            last_resolved_at=NOW(),
            updated_at=NOW()
        WHERE ds.character_id=v_character.character_id;

    ELSE
        IF p_roll=1 THEN
            v_failures:=LEAST(3,v_failures+2);
            v_outcome:='natural_1_failure';
        ELSE
            v_failures:=LEAST(3,v_failures+1);
            v_outcome:='failure';
        END IF;

        IF v_failures>=3 THEN
            v_failures:=3;
            v_stable:=FALSE;
            v_outcome:='dead';
            v_message:=v_character.character_name ||
                ' reached three failed death saving throws and died.';

            UPDATE public.discord_character_death_saves ds
            SET successes=v_successes,
                failures=v_failures,
                stable=v_stable,
                last_roll=p_roll,
                last_result=v_outcome,
                last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
                last_resolved_at=NOW(),
                updated_at=NOW()
            WHERE ds.character_id=v_character.character_id;

            v_mark:=public.discord_gm_mark_character_dead(
                p_campaign_id,
                v_character.character_name,
                'Failed three death saving throws.'
            );
        ELSE
            v_stable:=FALSE;
            v_message:=CASE
                WHEN p_roll=1 THEN v_character.character_name ||
                    ' rolled a natural 1 and suffered two death saving throw failures.'
                ELSE v_character.character_name ||
                    ' failed a death saving throw.'
            END;

            UPDATE public.discord_character_death_saves ds
            SET successes=v_successes,
                failures=v_failures,
                stable=v_stable,
                last_roll=p_roll,
                last_result=v_outcome,
                last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
                last_resolved_at=NOW(),
                updated_at=NOW()
            WHERE ds.character_id=v_character.character_id;
        END IF;
    END IF;

    RETURN QUERY
    SELECT
        v_character.character_id,
        v_character.character_name,
        p_roll,
        v_outcome,
        v_successes,
        v_failures,
        v_stable,
        CASE WHEN v_outcome='natural_20' THEN 1 ELSE 0 END,
        GREATEST(1,COALESCE(v_character.max_hp,1)),
        (v_outcome='dead'),
        v_combat_active,
        v_current_turn,
        v_message;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_death_save_state(UUID,UUID)
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_resolve_death_save(UUID,UUID,INTEGER)
FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_death_save_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_resolve_death_save(UUID,UUID,INTEGER) TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
