-- ============================================================
-- RabuShinAIGM Rules Build 6.19.2
-- Migration 47 - Stable Recovery + Full Action Economy
-- Baseline: 58dc35e748048fbafd1ba04b1fa67363682c9689
--
-- Requires:
--   Build 6.18.4 / Migration 41
--   Build 6.19 / Migration 45
--   Build 6.19.1 / Migration 46
--
-- Stable Recovery:
--   3 successful death saves => Stable at 0 HP
--   one server-generated 1d4 in-game-hour recovery roll
--   automatic recovery to 1 HP when authoritative world_minute reaches due time
--
-- Action Economy:
--   Action, Bonus Action, Reaction, Movement, free Object Interaction
--   split movement, Dash movement, Fighter Action Surge, Conditions/Exhaustion
--   trusted monster walking Speed supplied by server from Monster Codex
-- ============================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- STABLE RECOVERY
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discord_character_stable_recovery
(
    character_id UUID PRIMARY KEY
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    recovery_roll_hours INTEGER NOT NULL CHECK (recovery_roll_hours BETWEEN 1 AND 4),
    stabilized_world_minute BIGINT NOT NULL,
    recovery_due_world_minute BIGINT NOT NULL,
    scheduled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_discord_character_stable_recovery_campaign
ON public.discord_character_stable_recovery(campaign_id);

ALTER TABLE public.discord_character_stable_recovery ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_character_stable_recovery FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.discord_character_stable_recovery TO service_role;

CREATE OR REPLACE FUNCTION public.discord_schedule_stable_recovery()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_world BIGINT;
    v_roll INTEGER;
BEGIN
    IF COALESCE(NEW.stable,FALSE) THEN
        INSERT INTO public.discord_campaign_world_time(campaign_id)
        VALUES(NEW.campaign_id)
        ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

        SELECT w.world_minute INTO v_world
        FROM public.discord_campaign_world_time w
        WHERE w.campaign_id=NEW.campaign_id;

        -- Server-generated 1d4. ON CONFLICT DO NOTHING makes this one roll
        -- persistent for the entire stabilization event.
        v_roll := FLOOR(random()*4)::INTEGER + 1;

        INSERT INTO public.discord_character_stable_recovery(
            character_id,campaign_id,recovery_roll_hours,
            stabilized_world_minute,recovery_due_world_minute,
            scheduled_at,updated_at
        )
        VALUES(
            NEW.character_id,NEW.campaign_id,v_roll,
            COALESCE(v_world,0),COALESCE(v_world,0)+(v_roll*60),
            NOW(),NOW()
        )
        ON CONFLICT (character_id) DO NOTHING;
    ELSE
        DELETE FROM public.discord_character_stable_recovery r
        WHERE r.character_id=NEW.character_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_schedule_stable_recovery
ON public.discord_character_death_saves;

CREATE TRIGGER trg_discord_schedule_stable_recovery
AFTER INSERT OR UPDATE OF stable
ON public.discord_character_death_saves
FOR EACH ROW
EXECUTE FUNCTION public.discord_schedule_stable_recovery();

-- Backfill characters already stable when Migration 47 is applied.
INSERT INTO public.discord_campaign_world_time(campaign_id)
SELECT DISTINCT ds.campaign_id
FROM public.discord_character_death_saves ds
WHERE ds.stable=TRUE
ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

INSERT INTO public.discord_character_stable_recovery(
    character_id,campaign_id,recovery_roll_hours,
    stabilized_world_minute,recovery_due_world_minute
)
SELECT
    ds.character_id,
    ds.campaign_id,
    rolled.roll_hours,
    w.world_minute,
    w.world_minute + rolled.roll_hours*60
FROM public.discord_character_death_saves ds
JOIN public.discord_campaign_world_time w ON w.campaign_id=ds.campaign_id
CROSS JOIN LATERAL (
    SELECT (FLOOR(random()*4)::INTEGER + 1)::INTEGER AS roll_hours
    WHERE ds.character_id IS NOT NULL
) rolled
JOIN public.discord_characters c ON c.character_id=ds.character_id
WHERE ds.stable=TRUE
  AND c.life_state='alive'
  AND COALESCE(c.current_hp,0)=0
ON CONFLICT (character_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.discord_process_stable_recovery(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_world BIGINT:=0;
    v_row RECORD;
    v_results JSONB:='[]'::jsonb;
BEGIN
    SELECT COALESCE(w.world_minute,0) INTO v_world
    FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id;

    -- Remove schedules invalidated by death, outside healing, or a reset save track.
    DELETE FROM public.discord_character_stable_recovery r
    WHERE r.campaign_id=p_campaign_id
      AND NOT EXISTS(
          SELECT 1
          FROM public.discord_characters c
          JOIN public.discord_character_death_saves ds
            ON ds.character_id=c.character_id
          WHERE c.character_id=r.character_id
            AND c.life_state='alive'
            AND COALESCE(c.current_hp,0)=0
            AND ds.stable=TRUE
      );

    FOR v_row IN
        SELECT r.character_id,r.recovery_roll_hours,r.stabilized_world_minute,
               r.recovery_due_world_minute,c.character_name
        FROM public.discord_character_stable_recovery r
        JOIN public.discord_characters c ON c.character_id=r.character_id
        JOIN public.discord_character_death_saves ds ON ds.character_id=r.character_id
        WHERE r.campaign_id=p_campaign_id
          AND r.recovery_due_world_minute<=v_world
          AND c.life_state='alive'
          AND COALESCE(c.current_hp,0)=0
          AND ds.stable=TRUE
        ORDER BY r.recovery_due_world_minute,r.character_id
        FOR UPDATE OF r
    LOOP
        UPDATE public.discord_characters c
        SET current_hp=1,
            character_data=COALESCE(c.character_data,'{}'::jsonb)
                || jsonb_build_object('current_hp',1),
            updated_at=NOW()
        WHERE c.character_id=v_row.character_id
          AND c.life_state='alive'
          AND COALESCE(c.current_hp,0)=0;

        IF FOUND THEN
            v_results:=v_results || jsonb_build_array(jsonb_build_object(
                'characterId',v_row.character_id,
                'characterName',v_row.character_name,
                'recoveryRollHours',v_row.recovery_roll_hours,
                'recoveredAtWorldMinute',v_world,
                'currentHp',1
            ));
        END IF;
    END LOOP;

    RETURN v_results;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_process_stable_recovery_on_world_time()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NEW.world_minute IS DISTINCT FROM OLD.world_minute THEN
        PERFORM public.discord_process_stable_recovery(NEW.campaign_id);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_process_stable_recovery_world_time
ON public.discord_campaign_world_time;

CREATE TRIGGER trg_discord_process_stable_recovery_world_time
AFTER UPDATE OF world_minute
ON public.discord_campaign_world_time
FOR EACH ROW
EXECUTE FUNCTION public.discord_process_stable_recovery_on_world_time();

DROP FUNCTION IF EXISTS public.discord_get_stable_recovery_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_stable_recovery_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    stable BOOLEAN,
    current_hp INTEGER,
    recovery_roll_hours INTEGER,
    stabilized_world_minute BIGINT,
    recovery_due_world_minute BIGINT,
    current_world_minute BIGINT,
    remaining_minutes BIGINT,
    remaining_hours NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    PERFORM public.discord_process_stable_recovery(p_campaign_id);

    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id
    LIMIT 1;

    IF v_character.character_id IS NULL THEN RETURN; END IF;

    RETURN QUERY
    SELECT
        v_character.character_id,
        v_character.character_name,
        COALESCE(ds.stable,FALSE),
        COALESCE(v_character.current_hp,0),
        r.recovery_roll_hours,
        r.stabilized_world_minute,
        r.recovery_due_world_minute,
        COALESCE(w.world_minute,0),
        CASE WHEN r.recovery_due_world_minute IS NULL THEN NULL
             ELSE GREATEST(0,r.recovery_due_world_minute-COALESCE(w.world_minute,0)) END,
        CASE WHEN r.recovery_due_world_minute IS NULL THEN NULL
             ELSE ROUND(GREATEST(0,r.recovery_due_world_minute-COALESCE(w.world_minute,0))::NUMERIC/60.0,2) END
    FROM (SELECT 1) q
    LEFT JOIN public.discord_character_death_saves ds ON ds.character_id=v_character.character_id
    LEFT JOIN public.discord_character_stable_recovery r ON r.character_id=v_character.character_id
    LEFT JOIN public.discord_campaign_world_time w ON w.campaign_id=p_campaign_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- TRUSTED MONSTER WALKING SPEED
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discord_combat_monster_movement_speed
(
    combat_monster_id UUID PRIMARY KEY
        REFERENCES public.discord_campaign_combat_monsters(combat_monster_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    walking_speed_ft INTEGER NOT NULL CHECK (walking_speed_ft BETWEEN 0 AND 1000),
    source TEXT NOT NULL DEFAULT 'Monster Codex',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_discord_combat_monster_movement_speed_campaign
ON public.discord_combat_monster_movement_speed(campaign_id);

ALTER TABLE public.discord_combat_monster_movement_speed ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_combat_monster_movement_speed FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.discord_combat_monster_movement_speed TO service_role;

DROP FUNCTION IF EXISTS public.discord_gm_set_monster_walking_speed(UUID,TEXT[],INTEGER);
CREATE OR REPLACE FUNCTION public.discord_gm_set_monster_walking_speed(
    p_campaign_id UUID,
    p_display_names TEXT[],
    p_speed_ft INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_speed INTEGER:=COALESCE(p_speed_ft,-1);
    v_count INTEGER:=0;
BEGIN
    IF v_speed<0 OR v_speed>1000 THEN
        RAISE EXCEPTION 'Monster walking Speed must be between 0 and 1000 feet.';
    END IF;
    IF COALESCE(array_length(p_display_names,1),0)=0 THEN
        RETURN jsonb_build_object('updated',0,'walkingSpeedFt',v_speed);
    END IF;

    INSERT INTO public.discord_combat_monster_movement_speed(
        combat_monster_id,campaign_id,walking_speed_ft,source,updated_at
    )
    SELECT m.combat_monster_id,m.campaign_id,v_speed,'Monster Codex',NOW()
    FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id
      AND EXISTS(
          SELECT 1 FROM unnest(p_display_names) n
          WHERE lower(trim(n))=lower(m.display_name)
      )
    ON CONFLICT (combat_monster_id) DO UPDATE
    SET walking_speed_ft=EXCLUDED.walking_speed_ft,
        source='Monster Codex',
        updated_at=NOW();

    GET DIAGNOSTICS v_count=ROW_COUNT;

    -- Keep the tactical display token synchronized when it already exists.
    UPDATE public.discord_campaign_combat_tokens t
    SET speed_ft=v_speed,updated_at=NOW()
    FROM public.discord_campaign_combat_monsters m
    WHERE m.combat_monster_id=t.combat_monster_id
      AND m.campaign_id=p_campaign_id
      AND EXISTS(
          SELECT 1 FROM unnest(p_display_names) n
          WHERE lower(trim(n))=lower(m.display_name)
      );

    RETURN jsonb_build_object('updated',v_count,'walkingSpeedFt',v_speed);
END;
$$;

-- ---------------------------------------------------------------------------
-- FULL ACTION ECONOMY
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discord_combat_action_economy
(
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('character','monster')),
    entity_id UUID NOT NULL,
    combat_started_at TIMESTAMPTZ NULL,
    turn_started_at TIMESTAMPTZ NULL,
    action_available BOOLEAN NOT NULL DEFAULT TRUE,
    bonus_action_available BOOLEAN NOT NULL DEFAULT TRUE,
    reaction_available BOOLEAN NOT NULL DEFAULT TRUE,
    object_interaction_available BOOLEAN NOT NULL DEFAULT TRUE,
    surge_action_available BOOLEAN NOT NULL DEFAULT FALSE,
    action_surge_used_this_turn BOOLEAN NOT NULL DEFAULT FALSE,
    dash_count INTEGER NOT NULL DEFAULT 0 CHECK (dash_count BETWEEN 0 AND 10),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(campaign_id,entity_type,entity_id)
);

ALTER TABLE public.discord_combat_action_economy ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_combat_action_economy FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.discord_combat_action_economy TO service_role;

CREATE TABLE IF NOT EXISTS public.discord_character_action_surge
(
    character_id UUID PRIMARY KEY
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    max_charges INTEGER NOT NULL DEFAULT 0 CHECK (max_charges BETWEEN 0 AND 2),
    charges_remaining INTEGER NOT NULL DEFAULT 0 CHECK (charges_remaining BETWEEN 0 AND 2),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.discord_character_action_surge ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_character_action_surge FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.discord_character_action_surge TO service_role;

CREATE OR REPLACE FUNCTION public.discord_sync_fighter_action_surge(
    p_character_id UUID,
    p_refill BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_campaign UUID;
    v_class TEXT;
    v_level INTEGER;
    v_max INTEGER:=0;
BEGIN
    SELECT c.campaign_id,lower(trim(COALESCE(c.class_name,''))),GREATEST(1,COALESCE(c.level,1))
    INTO v_campaign,v_class,v_level
    FROM public.discord_characters c
    WHERE c.character_id=p_character_id;

    IF v_campaign IS NULL THEN RETURN; END IF;

    v_max:=CASE
        WHEN v_class='fighter' AND v_level>=17 THEN 2
        WHEN v_class='fighter' AND v_level>=2 THEN 1
        ELSE 0
    END;

    INSERT INTO public.discord_character_action_surge(
        character_id,campaign_id,max_charges,charges_remaining,updated_at
    )
    VALUES(p_character_id,v_campaign,v_max,v_max,NOW())
    ON CONFLICT(character_id) DO UPDATE
    SET campaign_id=EXCLUDED.campaign_id,
        charges_remaining=CASE
            WHEN COALESCE(p_refill,FALSE) THEN v_max
            WHEN v_max>public.discord_character_action_surge.max_charges
                THEN LEAST(v_max,public.discord_character_action_surge.charges_remaining+
                    (v_max-public.discord_character_action_surge.max_charges))
            ELSE LEAST(v_max,public.discord_character_action_surge.charges_remaining)
        END,
        max_charges=v_max,
        updated_at=NOW();
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_recharge_action_surge_on_rest()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF lower(COALESCE(NEW.rest_type,'')) IN ('short','long') THEN
        PERFORM public.discord_sync_fighter_action_surge(NEW.character_id,TRUE);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_recharge_action_surge_on_rest
ON public.discord_character_rest_state;

CREATE TRIGGER trg_discord_recharge_action_surge_on_rest
AFTER INSERT OR UPDATE OF rest_type,status
ON public.discord_character_rest_state
FOR EACH ROW
EXECUTE FUNCTION public.discord_recharge_action_surge_on_rest();

CREATE OR REPLACE FUNCTION public.discord_action_economy_is_incapacitated(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_entity_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT EXISTS(
        SELECT 1
        FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=p_campaign_id
          AND cc.entity_type=lower(trim(p_entity_type))
          AND (
              (cc.entity_type='character' AND cc.character_id=p_entity_id)
              OR
              (cc.entity_type='monster' AND cc.combat_monster_id=p_entity_id)
          )
          AND cc.condition_name IN ('incapacitated','paralyzed','petrified','stunned','unconscious')
          AND public.discord_condition_is_active(
              cc.campaign_id,cc.duration_type,cc.applied_round,cc.rounds_remaining
          )
    );
$$;

CREATE OR REPLACE FUNCTION public.discord_action_economy_movement_blocked(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_entity_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT EXISTS(
        SELECT 1
        FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=p_campaign_id
          AND cc.entity_type=lower(trim(p_entity_type))
          AND (
              (cc.entity_type='character' AND cc.character_id=p_entity_id)
              OR
              (cc.entity_type='monster' AND cc.combat_monster_id=p_entity_id)
          )
          AND cc.condition_name IN ('grappled','paralyzed','petrified','restrained','stunned','unconscious')
          AND public.discord_condition_is_active(
              cc.campaign_id,cc.duration_type,cc.applied_round,cc.rounds_remaining
          )
    );
$$;

CREATE OR REPLACE FUNCTION public.discord_action_economy_effective_speed(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_entity_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_entity_type,'')));
    v_speed INTEGER:=0;
BEGIN
    IF public.discord_action_economy_movement_blocked(p_campaign_id,v_type,p_entity_id) THEN
        RETURN 0;
    END IF;

    IF v_type='character' THEN
        SELECT COALESCE(public.discord_exhaustion_effective_speed(c.character_id),COALESCE(c.speed,30))
        INTO v_speed
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id AND c.character_id=p_entity_id;
    ELSIF v_type='monster' THEN
        -- Do NOT assume every monster walks 30 ft. A trusted Codex Speed row wins.
        SELECT COALESCE(ms.walking_speed_ft,0)
        INTO v_speed
        FROM public.discord_campaign_combat_monsters m
        LEFT JOIN public.discord_combat_monster_movement_speed ms
          ON ms.combat_monster_id=m.combat_monster_id
        WHERE m.campaign_id=p_campaign_id AND m.combat_monster_id=p_entity_id;
    END IF;

    RETURN GREATEST(0,COALESCE(v_speed,0));
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_action_economy_ensure_entity(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_entity_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_entity_type,'')));
    v_combat public.discord_campaign_combat_state%ROWTYPE;
    v_is_current BOOLEAN:=FALSE;
BEGIN
    IF v_type NOT IN ('character','monster') THEN RETURN; END IF;

    SELECT * INTO v_combat
    FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id;

    IF v_combat.campaign_id IS NULL OR NOT COALESCE(v_combat.active,FALSE) THEN
        RETURN;
    END IF;

    v_is_current:=
        (v_type='character' AND v_combat.current_turn_type='character'
            AND v_combat.current_turn_character_id=p_entity_id)
        OR
        (v_type='monster' AND v_combat.current_turn_type='monster'
            AND v_combat.current_turn_monster_id=p_entity_id);

    INSERT INTO public.discord_combat_action_economy(
        campaign_id,entity_type,entity_id,combat_started_at,turn_started_at,
        action_available,bonus_action_available,reaction_available,
        object_interaction_available,surge_action_available,
        action_surge_used_this_turn,dash_count,updated_at
    )
    VALUES(
        p_campaign_id,v_type,p_entity_id,v_combat.started_at,
        CASE WHEN v_is_current THEN v_combat.turn_started_at ELSE NULL END,
        TRUE,TRUE,TRUE,TRUE,FALSE,FALSE,0,NOW()
    )
    ON CONFLICT(campaign_id,entity_type,entity_id) DO NOTHING;

    -- New combat: initialize once. This is intentionally NOT keyed to a state read.
    UPDATE public.discord_combat_action_economy ae
    SET combat_started_at=v_combat.started_at,
        turn_started_at=CASE WHEN v_is_current THEN v_combat.turn_started_at ELSE NULL END,
        action_available=TRUE,
        bonus_action_available=TRUE,
        reaction_available=TRUE,
        object_interaction_available=TRUE,
        surge_action_available=FALSE,
        action_surge_used_this_turn=FALSE,
        dash_count=0,
        updated_at=NOW()
    WHERE ae.campaign_id=p_campaign_id
      AND ae.entity_type=v_type
      AND ae.entity_id=p_entity_id
      AND ae.combat_started_at IS DISTINCT FROM v_combat.started_at;

    -- New turn for THIS entity: refresh exactly once by turn_started_at.
    -- No token movement is changed here; strict initiative already resets it.
    IF v_is_current THEN
        UPDATE public.discord_combat_action_economy ae
        SET turn_started_at=v_combat.turn_started_at,
            action_available=TRUE,
            bonus_action_available=TRUE,
            reaction_available=TRUE,
            object_interaction_available=TRUE,
            surge_action_available=FALSE,
            action_surge_used_this_turn=FALSE,
            dash_count=0,
            updated_at=NOW()
        WHERE ae.campaign_id=p_campaign_id
          AND ae.entity_type=v_type
          AND ae.entity_id=p_entity_id
          AND ae.turn_started_at IS DISTINCT FROM v_combat.turn_started_at;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_action_economy_build_state(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_entity_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_entity_type,'')));
    v_combat public.discord_campaign_combat_state%ROWTYPE;
    v_row public.discord_combat_action_economy%ROWTYPE;
    v_current BOOLEAN:=FALSE;
    v_incapacitated BOOLEAN:=FALSE;
    v_speed INTEGER:=0;
    v_spent INTEGER:=0;
    v_allowance INTEGER:=0;
    v_surge_max INTEGER:=0;
    v_surge_remaining INTEGER:=0;
BEGIN
    SELECT * INTO v_combat
    FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id;

    IF v_combat.campaign_id IS NULL OR NOT COALESCE(v_combat.active,FALSE) THEN
        RETURN jsonb_build_object(
            'activeCombat',FALSE,'isCurrentTurn',FALSE,
            'actionAvailable',FALSE,'canAction',FALSE,
            'bonusActionAvailable',FALSE,'canBonusAction',FALSE,
            'reactionAvailable',FALSE,'canReaction',FALSE,
            'objectInteractionAvailable',FALSE,'canObjectInteraction',FALSE,
            'surgeActionAvailable',FALSE,'canSurgeAction',FALSE,
            'actionSurgeUsedThisTurn',FALSE,
            'actionSurgeMaxCharges',0,'actionSurgeChargesRemaining',0,
            'effectiveSpeedFt',0,'dashCount',0,'movementAllowanceFt',0,
            'movementSpentFt',0,'movementRemainingFt',0,
            'incapacitated',FALSE,'resourceBlockedReason',''
        );
    END IF;

    PERFORM public.discord_action_economy_ensure_entity(
        p_campaign_id,v_type,p_entity_id);

    IF v_type='character' THEN
        PERFORM public.discord_sync_fighter_action_surge(p_entity_id,FALSE);
        SELECT COALESCE(s.max_charges,0),COALESCE(s.charges_remaining,0)
        INTO v_surge_max,v_surge_remaining
        FROM public.discord_character_action_surge s
        WHERE s.character_id=p_entity_id;
    END IF;

    SELECT * INTO v_row
    FROM public.discord_combat_action_economy ae
    WHERE ae.campaign_id=p_campaign_id
      AND ae.entity_type=v_type
      AND ae.entity_id=p_entity_id;

    v_current:=
        (v_type='character' AND v_combat.current_turn_type='character'
            AND v_combat.current_turn_character_id=p_entity_id)
        OR
        (v_type='monster' AND v_combat.current_turn_type='monster'
            AND v_combat.current_turn_monster_id=p_entity_id);

    v_incapacitated:=public.discord_action_economy_is_incapacitated(
        p_campaign_id,v_type,p_entity_id);
    v_speed:=public.discord_action_economy_effective_speed(
        p_campaign_id,v_type,p_entity_id);

    SELECT COALESCE(t.movement_spent_ft,0)
    INTO v_spent
    FROM public.discord_campaign_combat_tokens t
    WHERE t.campaign_id=p_campaign_id
      AND (
        (v_type='character' AND t.character_id=p_entity_id)
        OR
        (v_type='monster' AND t.combat_monster_id=p_entity_id)
      )
    LIMIT 1;

    v_spent:=COALESCE(v_spent,0);
    v_allowance:=GREATEST(0,v_speed*(1+COALESCE(v_row.dash_count,0)));

    RETURN jsonb_build_object(
        'activeCombat',TRUE,
        'isCurrentTurn',v_current,
        'actionAvailable',COALESCE(v_row.action_available,FALSE),
        'canAction',v_current AND COALESCE(v_row.action_available,FALSE) AND NOT v_incapacitated,
        'bonusActionAvailable',COALESCE(v_row.bonus_action_available,FALSE),
        'canBonusAction',v_current AND COALESCE(v_row.bonus_action_available,FALSE) AND NOT v_incapacitated,
        'reactionAvailable',COALESCE(v_row.reaction_available,FALSE),
        'canReaction',COALESCE(v_row.reaction_available,FALSE) AND NOT v_incapacitated,
        'objectInteractionAvailable',COALESCE(v_row.object_interaction_available,FALSE),
        'canObjectInteraction',v_current AND COALESCE(v_row.object_interaction_available,FALSE) AND NOT v_incapacitated,
        'surgeActionAvailable',COALESCE(v_row.surge_action_available,FALSE),
        'canSurgeAction',v_current AND COALESCE(v_row.surge_action_available,FALSE) AND NOT v_incapacitated,
        'actionSurgeUsedThisTurn',COALESCE(v_row.action_surge_used_this_turn,FALSE),
        'actionSurgeMaxCharges',COALESCE(v_surge_max,0),
        'actionSurgeChargesRemaining',COALESCE(v_surge_remaining,0),
        'effectiveSpeedFt',v_speed,
        'dashCount',COALESCE(v_row.dash_count,0),
        'movementAllowanceFt',v_allowance,
        'movementSpentFt',v_spent,
        'movementRemainingFt',GREATEST(0,v_allowance-v_spent),
        'incapacitated',v_incapacitated,
        'resourceBlockedReason',CASE WHEN v_incapacitated
            THEN 'An active condition prevents Actions, Bonus Actions, and Reactions.'
            ELSE '' END
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_action_economy_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_action_economy_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    active_combat BOOLEAN,
    is_current_turn BOOLEAN,
    action_available BOOLEAN,
    can_action BOOLEAN,
    bonus_action_available BOOLEAN,
    can_bonus_action BOOLEAN,
    reaction_available BOOLEAN,
    can_reaction BOOLEAN,
    object_interaction_available BOOLEAN,
    can_object_interaction BOOLEAN,
    surge_action_available BOOLEAN,
    can_surge_action BOOLEAN,
    action_surge_used_this_turn BOOLEAN,
    action_surge_max_charges INTEGER,
    action_surge_charges_remaining INTEGER,
    effective_speed_ft INTEGER,
    dash_count INTEGER,
    movement_allowance_ft INTEGER,
    movement_spent_ft INTEGER,
    movement_remaining_ft INTEGER,
    incapacitated BOOLEAN,
    resource_blocked_reason TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v JSONB;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id
    LIMIT 1;
    IF v_character.character_id IS NULL THEN RETURN; END IF;

    v:=public.discord_action_economy_build_state(
        p_campaign_id,'character',v_character.character_id);

    RETURN QUERY SELECT
        v_character.character_id,
        v_character.character_name,
        COALESCE((v->>'activeCombat')::BOOLEAN,FALSE),
        COALESCE((v->>'isCurrentTurn')::BOOLEAN,FALSE),
        COALESCE((v->>'actionAvailable')::BOOLEAN,FALSE),
        COALESCE((v->>'canAction')::BOOLEAN,FALSE),
        COALESCE((v->>'bonusActionAvailable')::BOOLEAN,FALSE),
        COALESCE((v->>'canBonusAction')::BOOLEAN,FALSE),
        COALESCE((v->>'reactionAvailable')::BOOLEAN,FALSE),
        COALESCE((v->>'canReaction')::BOOLEAN,FALSE),
        COALESCE((v->>'objectInteractionAvailable')::BOOLEAN,FALSE),
        COALESCE((v->>'canObjectInteraction')::BOOLEAN,FALSE),
        COALESCE((v->>'surgeActionAvailable')::BOOLEAN,FALSE),
        COALESCE((v->>'canSurgeAction')::BOOLEAN,FALSE),
        COALESCE((v->>'actionSurgeUsedThisTurn')::BOOLEAN,FALSE),
        COALESCE((v->>'actionSurgeMaxCharges')::INTEGER,0),
        COALESCE((v->>'actionSurgeChargesRemaining')::INTEGER,0),
        COALESCE((v->>'effectiveSpeedFt')::INTEGER,0),
        COALESCE((v->>'dashCount')::INTEGER,0),
        COALESCE((v->>'movementAllowanceFt')::INTEGER,0),
        COALESCE((v->>'movementSpentFt')::INTEGER,0),
        COALESCE((v->>'movementRemainingFt')::INTEGER,0),
        COALESCE((v->>'incapacitated')::BOOLEAN,FALSE),
        COALESCE(v->>'resourceBlockedReason','')::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_action_economy_spend_internal(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_entity_id UUID,
    p_resource TEXT,
    p_action_kind TEXT DEFAULT '',
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_entity_type,'')));
    v_resource TEXT:=lower(trim(COALESCE(p_resource,'')));
    v_kind TEXT:=lower(trim(COALESCE(p_action_kind,'')));
    v_state JSONB;
    v_current BOOLEAN;
    v_incapacitated BOOLEAN;
BEGIN
    IF v_resource NOT IN ('action','bonus_action','reaction','object_interaction','surge_action') THEN
        RAISE EXCEPTION 'Unsupported action resource: %',p_resource;
    END IF;

    v_state:=public.discord_action_economy_build_state(
        p_campaign_id,v_type,p_entity_id);
    IF NOT COALESCE((v_state->>'activeCombat')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'There is no active combat.';
    END IF;

    v_current:=COALESCE((v_state->>'isCurrentTurn')::BOOLEAN,FALSE);
    v_incapacitated:=COALESCE((v_state->>'incapacitated')::BOOLEAN,FALSE);

    IF v_incapacitated THEN
        RAISE EXCEPTION 'An active condition prevents this action.';
    END IF;
    IF v_resource<>'reaction' AND NOT v_current THEN
        RAISE EXCEPTION 'That resource can only be spent on this combatant''s current turn.';
    END IF;
    IF v_resource='surge_action' AND v_kind='magic' THEN
        RAISE EXCEPTION 'Action Surge''s extra Action cannot be used for the Magic action.';
    END IF;

    CASE v_resource
        WHEN 'action' THEN
            UPDATE public.discord_combat_action_economy ae
            SET action_available=FALSE,updated_at=NOW()
            WHERE ae.campaign_id=p_campaign_id AND ae.entity_type=v_type
              AND ae.entity_id=p_entity_id AND ae.action_available=TRUE;
        WHEN 'bonus_action' THEN
            UPDATE public.discord_combat_action_economy ae
            SET bonus_action_available=FALSE,updated_at=NOW()
            WHERE ae.campaign_id=p_campaign_id AND ae.entity_type=v_type
              AND ae.entity_id=p_entity_id AND ae.bonus_action_available=TRUE;
        WHEN 'reaction' THEN
            UPDATE public.discord_combat_action_economy ae
            SET reaction_available=FALSE,updated_at=NOW()
            WHERE ae.campaign_id=p_campaign_id AND ae.entity_type=v_type
              AND ae.entity_id=p_entity_id AND ae.reaction_available=TRUE;
        WHEN 'object_interaction' THEN
            UPDATE public.discord_combat_action_economy ae
            SET object_interaction_available=FALSE,updated_at=NOW()
            WHERE ae.campaign_id=p_campaign_id AND ae.entity_type=v_type
              AND ae.entity_id=p_entity_id AND ae.object_interaction_available=TRUE;
        WHEN 'surge_action' THEN
            UPDATE public.discord_combat_action_economy ae
            SET surge_action_available=FALSE,updated_at=NOW()
            WHERE ae.campaign_id=p_campaign_id AND ae.entity_type=v_type
              AND ae.entity_id=p_entity_id AND ae.surge_action_available=TRUE;
    END CASE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'The requested % resource has already been spent or is unavailable.',v_resource;
    END IF;

    RETURN public.discord_action_economy_build_state(
        p_campaign_id,v_type,p_entity_id)
        || jsonb_build_object(
            'spentResource',v_resource,
            'actionKind',LEFT(trim(COALESCE(p_action_kind,'')),80),
            'reason',LEFT(trim(COALESCE(p_reason,'')),160)
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_action_economy_dash_internal(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_entity_id UUID,
    p_resource TEXT,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_resource TEXT:=lower(trim(COALESCE(p_resource,'')));
    v_result JSONB;
BEGIN
    -- Build 6.19.2 exposes normal Action Dash and Surge Action Dash.
    -- Bonus Action Dash remains a class-feature concern and is not granted universally.
    IF v_resource NOT IN ('action','surge_action') THEN
        RAISE EXCEPTION 'Dash must spend the normal Action or an available Surge Action.';
    END IF;

    v_result:=public.discord_action_economy_spend_internal(
        p_campaign_id,p_entity_type,p_entity_id,v_resource,'dash',p_reason);

    UPDATE public.discord_combat_action_economy ae
    SET dash_count=LEAST(10,ae.dash_count+1),updated_at=NOW()
    WHERE ae.campaign_id=p_campaign_id
      AND ae.entity_type=lower(trim(p_entity_type))
      AND ae.entity_id=p_entity_id;

    RETURN public.discord_action_economy_build_state(
        p_campaign_id,p_entity_type,p_entity_id)
        || jsonb_build_object(
            'dash',TRUE,'spentResource',v_resource,
            'reason',LEFT(trim(COALESCE(p_reason,'')),160)
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_action_economy_use_surge_internal(
    p_campaign_id UUID,
    p_character_id UUID,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_state JSONB;
BEGIN
    v_state:=public.discord_action_economy_build_state(
        p_campaign_id,'character',p_character_id);

    IF NOT COALESCE((v_state->>'activeCombat')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'There is no active combat.';
    END IF;
    IF NOT COALESCE((v_state->>'isCurrentTurn')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'Action Surge can only be used on this Fighter''s turn.';
    END IF;
    IF COALESCE((v_state->>'incapacitated')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'An active condition prevents Action Surge.';
    END IF;
    IF COALESCE((v_state->>'actionSurgeUsedThisTurn')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'Action Surge can be used only once on a turn.';
    END IF;

    PERFORM public.discord_sync_fighter_action_surge(p_character_id,FALSE);

    UPDATE public.discord_character_action_surge s
    SET charges_remaining=s.charges_remaining-1,updated_at=NOW()
    WHERE s.character_id=p_character_id
      AND s.max_charges>0
      AND s.charges_remaining>0;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'This character has no available Action Surge charge.';
    END IF;

    UPDATE public.discord_combat_action_economy ae
    SET surge_action_available=TRUE,
        action_surge_used_this_turn=TRUE,
        updated_at=NOW()
    WHERE ae.campaign_id=p_campaign_id
      AND ae.entity_type='character'
      AND ae.entity_id=p_character_id;

    RETURN public.discord_action_economy_build_state(
        p_campaign_id,'character',p_character_id)
        || jsonb_build_object(
            'actionSurgeUsed',TRUE,
            'reason',LEFT(trim(COALESCE(p_reason,'')),160)
        );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_player_spend_action_resource(UUID,UUID,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_player_spend_action_resource(
    p_player_id UUID,p_campaign_id UUID,p_resource TEXT,p_action_kind TEXT,p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_character UUID;
BEGIN
    SELECT c.character_id INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    RETURN public.discord_action_economy_spend_internal(
        p_campaign_id,'character',v_character,p_resource,p_action_kind,p_reason);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_player_dash_action(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_player_dash_action(
    p_player_id UUID,p_campaign_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_character UUID;
BEGIN
    SELECT c.character_id INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    RETURN public.discord_action_economy_dash_internal(
        p_campaign_id,'character',v_character,'action','Player Dash');
END;
$$;

DROP FUNCTION IF EXISTS public.discord_player_use_action_surge(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_player_use_action_surge(
    p_player_id UUID,p_campaign_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_character UUID;
BEGIN
    SELECT c.character_id INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    RETURN public.discord_action_economy_use_surge_internal(
        p_campaign_id,v_character,'Player Action Surge');
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_spend_action_resource(UUID,TEXT,TEXT,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_spend_action_resource(
    p_campaign_id UUID,p_entity_type TEXT,p_combatant_name TEXT,
    p_resource TEXT,p_action_kind TEXT,p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_entity_type,'')));
    v_id UUID;
BEGIN
    IF v_type='character' THEN
        SELECT c.character_id INTO v_id FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND lower(c.character_name)=lower(trim(COALESCE(p_combatant_name,''))) LIMIT 1;
    ELSIF v_type='monster' THEN
        SELECT m.combat_monster_id INTO v_id FROM public.discord_campaign_combat_monsters m
        WHERE m.campaign_id=p_campaign_id
          AND lower(m.display_name)=lower(trim(COALESCE(p_combatant_name,''))) LIMIT 1;
    ELSE
        RAISE EXCEPTION 'entityType must be character or monster.';
    END IF;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Combatant could not be found: %',p_combatant_name; END IF;
    RETURN public.discord_action_economy_spend_internal(
        p_campaign_id,v_type,v_id,p_resource,p_action_kind,p_reason);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_dash_action(UUID,TEXT,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_dash_action(
    p_campaign_id UUID,p_entity_type TEXT,p_combatant_name TEXT,
    p_resource TEXT,p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_entity_type,'')));
    v_id UUID;
BEGIN
    IF v_type='character' THEN
        SELECT c.character_id INTO v_id FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND lower(c.character_name)=lower(trim(COALESCE(p_combatant_name,''))) LIMIT 1;
    ELSIF v_type='monster' THEN
        SELECT m.combat_monster_id INTO v_id FROM public.discord_campaign_combat_monsters m
        WHERE m.campaign_id=p_campaign_id
          AND lower(m.display_name)=lower(trim(COALESCE(p_combatant_name,''))) LIMIT 1;
    ELSE
        RAISE EXCEPTION 'entityType must be character or monster.';
    END IF;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Combatant could not be found: %',p_combatant_name; END IF;
    RETURN public.discord_action_economy_dash_internal(
        p_campaign_id,v_type,v_id,p_resource,p_reason);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_use_action_surge(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_use_action_surge(
    p_campaign_id UUID,p_character_name TEXT,p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_character UUID;
BEGIN
    SELECT c.character_id INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,''))) LIMIT 1;
    IF v_character IS NULL THEN RAISE EXCEPTION 'Character could not be found: %',p_character_name; END IF;
    RETURN public.discord_action_economy_use_surge_internal(
        p_campaign_id,v_character,p_reason);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_action_economy_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_action_economy_state(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_token RECORD;
    v_states JSONB:='[]'::jsonb;
    v_name TEXT;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id AND s.active=TRUE
    ) THEN RETURN v_states; END IF;

    PERFORM public.discord_sync_tactical_tokens(p_campaign_id);

    FOR v_token IN
        SELECT t.entity_type,t.character_id,t.combat_monster_id,t.display_name
        FROM public.discord_campaign_combat_tokens t
        WHERE t.campaign_id=p_campaign_id
        ORDER BY t.entity_type,t.display_name,t.token_id
    LOOP
        v_states:=v_states || jsonb_build_array(
            public.discord_action_economy_build_state(
                p_campaign_id,
                v_token.entity_type,
                COALESCE(v_token.character_id,v_token.combat_monster_id)
            ) || jsonb_build_object(
                'entityType',v_token.entity_type,
                'entityId',COALESCE(v_token.character_id,v_token.combat_monster_id),
                'displayName',v_token.display_name
            )
        );
    END LOOP;

    RETURN v_states;
END;
$$;

-- Player voluntary movement now uses the total movement pool:
-- Speed + one additional Speed for each server-authorized Dash.
DROP FUNCTION IF EXISTS public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER);
CREATE OR REPLACE FUNCTION public.discord_move_own_combat_token_costed(
    p_player_id UUID,p_campaign_id UUID,p_grid_x INTEGER,p_grid_y INTEGER,p_move_cost_ft INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_token public.discord_campaign_combat_tokens%ROWTYPE;
    v_state JSONB;
    v_remaining INTEGER;
    v_speed INTEGER;
    v_allowance INTEGER;
    v_cost INTEGER:=GREATEST(0,COALESCE(p_move_cost_ft,0));
BEGIN
    IF p_grid_x NOT BETWEEN 0 AND 19 OR p_grid_y NOT BETWEEN 0 AND 19 THEN
        RAISE EXCEPTION 'Tactical destination must be inside the 20x20 encounter grid.';
    END IF;
    IF v_cost>1000 THEN RAISE EXCEPTION 'Invalid tactical movement cost.'; END IF;
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id AND s.active=TRUE
    ) THEN RAISE EXCEPTION 'There is no active combat.'; END IF;

    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id
    LIMIT 1;
    IF v_character.character_id IS NULL THEN
        RAISE EXCEPTION 'Your campaign character could not be found.';
    END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id
          AND s.current_turn_type='character'
          AND s.current_turn_character_id=v_character.character_id
    ) THEN RAISE EXCEPTION 'It is not your character''s turn.'; END IF;

    PERFORM public.discord_sync_tactical_tokens(p_campaign_id);

    SELECT t.* INTO v_token
    FROM public.discord_campaign_combat_tokens t
    WHERE t.campaign_id=p_campaign_id AND t.character_id=v_character.character_id
    LIMIT 1 FOR UPDATE;
    IF v_token.token_id IS NULL THEN RAISE EXCEPTION 'Your tactical token could not be found.'; END IF;
    IF COALESCE(v_character.current_hp,0)<=0 THEN RAISE EXCEPTION 'Your character cannot move while at 0 HP.'; END IF;

    v_state:=public.discord_action_economy_build_state(
        p_campaign_id,'character',v_character.character_id);
    v_speed:=COALESCE((v_state->>'effectiveSpeedFt')::INTEGER,0);
    v_allowance:=COALESCE((v_state->>'movementAllowanceFt')::INTEGER,0);
    v_remaining:=GREATEST(0,v_allowance-COALESCE(v_token.movement_spent_ft,0));

    IF v_cost>v_remaining THEN
        RAISE EXCEPTION 'That terrain-aware move costs % ft., but only % ft. of movement remains.',v_cost,v_remaining;
    END IF;

    IF EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_tokens t
        LEFT JOIN public.discord_characters c ON c.character_id=t.character_id
        LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=t.combat_monster_id
        WHERE t.campaign_id=p_campaign_id
          AND t.token_id<>v_token.token_id
          AND t.grid_x=p_grid_x AND t.grid_y=p_grid_y
          AND (
            (t.entity_type='character' AND COALESCE(c.current_hp,0)>0)
            OR
            (t.entity_type='monster' AND COALESCE(m.defeated,FALSE)=FALSE)
          )
    ) THEN RAISE EXCEPTION 'Another active combatant already occupies that square.'; END IF;

    UPDATE public.discord_campaign_combat_tokens t
    SET grid_x=p_grid_x,grid_y=p_grid_y,
        movement_spent_ft=t.movement_spent_ft+v_cost,
        updated_at=NOW()
    WHERE t.token_id=v_token.token_id
    RETURNING t.* INTO v_token;

    RETURN jsonb_build_object(
        'token_id',v_token.token_id,'grid_x',v_token.grid_x,'grid_y',v_token.grid_y,
        'move_cost_ft',v_cost,'base_speed_ft',COALESCE(v_character.speed,30),
        'effective_speed_ft',v_speed,'movement_allowance_ft',v_allowance,
        'movement_spent_ft',v_token.movement_spent_ft,
        'movement_remaining_ft',GREATEST(0,v_allowance-v_token.movement_spent_ft)
    );
END;
$$;

-- New GM movement RPC. The C# tactical path still validates terrain/LOS/Prone/
-- Frightened. This layer enforces turn ownership and the authoritative movement
-- pool for voluntary movement; forced movement/teleport never spends movement.
DROP FUNCTION IF EXISTS public.discord_gm_position_combat_token_action_economy(UUID,TEXT,TEXT,INTEGER,INTEGER,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_position_combat_token_action_economy(
    p_campaign_id UUID,p_entity_type TEXT,p_combatant_name TEXT,
    p_grid_x INTEGER,p_grid_y INTEGER,p_distance_ft INTEGER,p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_entity_type,'')));
    v_id UUID;
    v_token public.discord_campaign_combat_tokens%ROWTYPE;
    v_state JSONB;
    v_cost INTEGER:=GREATEST(0,COALESCE(p_distance_ft,0));
    v_reason TEXT:=lower(trim(COALESCE(p_reason,'')));
    v_forced BOOLEAN:=FALSE;
    v_remaining INTEGER:=0;
    v_allowance INTEGER:=0;
BEGIN
    IF v_type NOT IN ('character','monster') THEN RAISE EXCEPTION 'entityType must be character or monster.'; END IF;
    IF p_grid_x NOT BETWEEN 0 AND 19 OR p_grid_y NOT BETWEEN 0 AND 19 THEN
        RAISE EXCEPTION 'Tactical destination must be inside the 20x20 encounter grid.';
    END IF;
    IF v_cost>1000 THEN RAISE EXCEPTION 'Invalid tactical movement cost.'; END IF;

    v_forced:=
        v_reason LIKE '%teleport%' OR v_reason LIKE '%dimension door%' OR v_reason LIKE '%misty step%'
        OR v_reason LIKE '%forced%' OR v_reason LIKE '%shove%' OR v_reason LIKE '%push%'
        OR v_reason LIKE '%pull%' OR v_reason LIKE '%drag%';

    PERFORM public.discord_sync_tactical_tokens(p_campaign_id);

    IF v_type='character' THEN
        SELECT c.character_id INTO v_id
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND lower(c.character_name)=lower(trim(COALESCE(p_combatant_name,'')))
        LIMIT 1;
    ELSE
        SELECT m.combat_monster_id INTO v_id
        FROM public.discord_campaign_combat_monsters m
        WHERE m.campaign_id=p_campaign_id
          AND lower(m.display_name)=lower(trim(COALESCE(p_combatant_name,'')))
        LIMIT 1;
    END IF;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Combatant could not be found: %',p_combatant_name; END IF;

    SELECT t.* INTO v_token
    FROM public.discord_campaign_combat_tokens t
    WHERE t.campaign_id=p_campaign_id
      AND (
        (v_type='character' AND t.character_id=v_id)
        OR
        (v_type='monster' AND t.combat_monster_id=v_id)
      )
    LIMIT 1 FOR UPDATE;
    IF v_token.token_id IS NULL THEN RAISE EXCEPTION 'Tactical token could not be found.'; END IF;

    IF NOT v_forced THEN
        v_state:=public.discord_action_economy_build_state(p_campaign_id,v_type,v_id);
        IF NOT COALESCE((v_state->>'isCurrentTurn')::BOOLEAN,FALSE) THEN
            RAISE EXCEPTION 'Voluntary movement is only legal on this combatant''s turn.';
        END IF;
        IF COALESCE((v_state->>'effectiveSpeedFt')::INTEGER,0)<=0 AND v_cost>0 THEN
            RAISE EXCEPTION 'This combatant currently has 0 ft. Speed.';
        END IF;
        v_allowance:=COALESCE((v_state->>'movementAllowanceFt')::INTEGER,0);
        v_remaining:=GREATEST(0,v_allowance-COALESCE(v_token.movement_spent_ft,0));
        IF v_cost>v_remaining THEN
            RAISE EXCEPTION 'That move costs % ft., but only % ft. remains.',v_cost,v_remaining;
        END IF;
    END IF;

    IF EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_tokens t
        LEFT JOIN public.discord_characters c ON c.character_id=t.character_id
        LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=t.combat_monster_id
        WHERE t.campaign_id=p_campaign_id
          AND t.token_id<>v_token.token_id
          AND t.grid_x=p_grid_x AND t.grid_y=p_grid_y
          AND (
            (t.entity_type='character' AND COALESCE(c.current_hp,0)>0)
            OR
            (t.entity_type='monster' AND COALESCE(m.defeated,FALSE)=FALSE)
          )
    ) THEN RAISE EXCEPTION 'Another active combatant already occupies that square.'; END IF;

    UPDATE public.discord_campaign_combat_tokens t
    SET grid_x=p_grid_x,grid_y=p_grid_y,
        movement_spent_ft=CASE WHEN v_forced THEN t.movement_spent_ft ELSE t.movement_spent_ft+v_cost END,
        updated_at=NOW()
    WHERE t.token_id=v_token.token_id
    RETURNING t.* INTO v_token;

    IF NOT v_forced THEN
        v_state:=public.discord_action_economy_build_state(p_campaign_id,v_type,v_id);
    END IF;

    RETURN jsonb_build_object(
        'tokenId',v_token.token_id,'entityType',v_type,'combatantName',p_combatant_name,
        'gridX',v_token.grid_x,'gridY',v_token.grid_y,'distanceFt',v_cost,
        'forcedMovement',v_forced,'movementSpentFt',v_token.movement_spent_ft,
        'movementRemainingFt',CASE WHEN v_forced THEN NULL ELSE (v_state->>'movementRemainingFt')::INTEGER END,
        'reason',LEFT(trim(COALESCE(p_reason,'')),160)
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- PERMISSIONS
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.discord_schedule_stable_recovery() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_process_stable_recovery(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_process_stable_recovery_on_world_time() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_stable_recovery_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_set_monster_walking_speed(UUID,TEXT[],INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_sync_fighter_action_surge(UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_recharge_action_surge_on_rest() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_action_economy_is_incapacitated(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_action_economy_movement_blocked(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_action_economy_effective_speed(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_action_economy_ensure_entity(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_action_economy_build_state(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_action_economy_spend_internal(UUID,TEXT,UUID,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discord_action_economy_dash_internal(UUID,TEXT,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discord_action_economy_use_surge_internal(UUID,UUID,TEXT) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discord_player_spend_action_resource(UUID,UUID,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_player_dash_action(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_player_use_action_surge(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_spend_action_resource(UUID,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_dash_action(UUID,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_use_action_surge(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_action_economy_state(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_position_combat_token_action_economy(UUID,TEXT,TEXT,INTEGER,INTEGER,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_stable_recovery_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_monster_walking_speed(UUID,TEXT[],INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_action_economy_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_player_spend_action_resource(UUID,UUID,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_player_dash_action(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_player_use_action_surge(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_spend_action_resource(UUID,TEXT,TEXT,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_dash_action(UUID,TEXT,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_use_action_surge(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_action_economy_state(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_position_combat_token_action_economy(UUID,TEXT,TEXT,INTEGER,INTEGER,INTEGER,TEXT) TO service_role;

COMMIT;
