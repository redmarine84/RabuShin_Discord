-- ============================================================
-- RabuShinAIGM Rules Build 6.18.4
-- Exhaustion Rules Overhaul
-- Hunger starvation grace, 2/3-water rule, six cumulative effects,
-- Long Rest recovery, Greater Restoration / trusted exhaustion changes.
-- Run after migrations 13, 16, 17, 27, 30, 31, 32, 38, 39, 40.
-- Safe to rerun.
-- ============================================================

BEGIN;

ALTER TABLE public.discord_character_survival
    ADD COLUMN IF NOT EXISTS food_ingested_since_long_rest NUMERIC(10,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS water_ingested_since_long_rest NUMERIC(10,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hydration_window_hours NUMERIC(10,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hydration_consumed_gal NUMERIC(10,4) NOT NULL DEFAULT 0;

-- Existing saves receive credit for the water they already have on hand so
-- applying this migration cannot immediately punish a character mid-day.
UPDATE public.discord_character_survival cs
SET hydration_consumed_gal = GREATEST(cs.hydration_consumed_gal, cs.water_credit_gal)
WHERE cs.hydration_window_hours = 0;

CREATE OR REPLACE FUNCTION public.discord_exhaustion_effective_speed(
    p_character_id UUID
)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT CASE
        WHEN COALESCE(cs.exhaustion_level,0) >= 5 THEN 0
        WHEN COALESCE(cs.exhaustion_level,0) >= 2 THEN FLOOR(COALESCE(c.speed,30) / 2.0)::INTEGER
        ELSE COALESCE(c.speed,30)
    END
    FROM public.discord_characters c
    LEFT JOIN public.discord_character_survival cs ON cs.character_id=c.character_id
    WHERE c.character_id=p_character_id
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.discord_exhaustion_effective_max_hp(
    p_character_id UUID
)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT CASE
        WHEN COALESCE(cs.exhaustion_level,0) >= 4 THEN GREATEST(1,FLOOR(COALESCE(c.max_hp,1) / 2.0)::INTEGER)
        ELSE GREATEST(1,COALESCE(c.max_hp,1))
    END
    FROM public.discord_characters c
    LEFT JOIN public.discord_character_survival cs ON cs.character_id=c.character_id
    WHERE c.character_id=p_character_id
    LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_character_exhaustion(UUID,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_get_character_exhaustion(
    p_campaign_id UUID,
    p_character_name TEXT
)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    exhaustion_level INTEGER,
    effective_speed INTEGER,
    effective_max_hp INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE v_character_id UUID;
BEGIN
    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1;
    IF v_character_id IS NULL THEN RETURN; END IF;

    INSERT INTO public.discord_character_survival(character_id,campaign_id)
    VALUES(v_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY
    SELECT c.character_id,c.character_name,COALESCE(cs.exhaustion_level,0),
           public.discord_exhaustion_effective_speed(c.character_id),
           public.discord_exhaustion_effective_max_hp(c.character_id)
    FROM public.discord_characters c
    JOIN public.discord_character_survival cs ON cs.character_id=c.character_id
    WHERE c.character_id=v_character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_exhaustion_effects(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_exhaustion_effects(p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    exhaustion_level INTEGER,
    effective_speed INTEGER,
    effective_max_hp INTEGER,
    disadvantage_ability_checks BOOLEAN,
    disadvantage_attacks_and_saves BOOLEAN,
    speed_zero BOOLEAN,
    death_at_six BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    INSERT INTO public.discord_character_survival(character_id,campaign_id)
    SELECT c.character_id,c.campaign_id FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY
    SELECT c.character_id,c.character_name,COALESCE(cs.exhaustion_level,0),
           public.discord_exhaustion_effective_speed(c.character_id),
           public.discord_exhaustion_effective_max_hp(c.character_id),
           COALESCE(cs.exhaustion_level,0)>=1,
           COALESCE(cs.exhaustion_level,0)>=3,
           COALESCE(cs.exhaustion_level,0)>=5,
           COALESCE(cs.exhaustion_level,0)>=6
    FROM public.discord_characters c
    JOIN public.discord_character_survival cs ON cs.character_id=c.character_id
    WHERE c.campaign_id=p_campaign_id AND c.life_state='alive'
    ORDER BY lower(c.character_name);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_adjust_exhaustion(UUID,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_adjust_exhaustion(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_delta INTEGER,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_state public.discord_character_survival%ROWTYPE;
    v_before INTEGER;
    v_after INTEGER;
    v_effective_max INTEGER;
BEGIN
    IF COALESCE(p_delta,0)=0 OR ABS(p_delta)>6 THEN
        RAISE EXCEPTION 'Exhaustion adjustment must be between -6 and 6 and cannot be zero.';
    END IF;

    SELECT c.* INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    INSERT INTO public.discord_character_survival(character_id,campaign_id)
    VALUES(v_character.character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    SELECT * INTO v_state FROM public.discord_character_survival cs
    WHERE cs.character_id=v_character.character_id FOR UPDATE;
    v_before:=COALESCE(v_state.exhaustion_level,0);
    v_after:=LEAST(6,GREATEST(0,v_before+p_delta));

    UPDATE public.discord_character_survival cs
    SET exhaustion_level=v_after,
        last_reason=LEFT(TRIM(COALESCE(p_reason,'')),200),
        updated_at=NOW()
    WHERE cs.character_id=v_character.character_id;

    v_effective_max:=CASE WHEN v_after>=4 THEN GREATEST(1,FLOOR(COALESCE(v_character.max_hp,1)/2.0)::INTEGER)
                          ELSE GREATEST(1,COALESCE(v_character.max_hp,1)) END;
    IF COALESCE(v_character.current_hp,0)>v_effective_max THEN
        UPDATE public.discord_characters c
        SET current_hp=v_effective_max,
            character_data=COALESCE(c.character_data,'{}'::jsonb) || jsonb_build_object('current_hp',v_effective_max),
            updated_at=NOW()
        WHERE c.character_id=v_character.character_id;
    END IF;

    IF v_after>=6 AND v_character.life_state='alive' THEN
        PERFORM public.discord_gm_mark_character_dead(
            p_campaign_id,
            v_character.character_name,
            COALESCE(NULLIF(TRIM(p_reason),''),'Exhaustion level 6')
        );
    END IF;

    RETURN jsonb_build_object(
        'authoritative',TRUE,
        'characterId',v_character.character_id,
        'characterName',v_character.character_name,
        'previousLevel',v_before,
        'exhaustionLevel',v_after,
        'deltaApplied',v_after-v_before,
        'effectiveSpeed',public.discord_exhaustion_effective_speed(v_character.character_id),
        'effectiveMaxHp',public.discord_exhaustion_effective_max_hp(v_character.character_id),
        'dead',v_after>=6,
        'reason',LEFT(TRIM(COALESCE(p_reason,'')),200)
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Player / GM survival state: expose starvation and exhaustion effects.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_get_survival_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_survival_state(p_player_id UUID,p_campaign_id UUID)
RETURNS TABLE(
    campaign_id UUID,character_id UUID,enabled BOOLEAN,is_owner BOOLEAN,hot_weather BOOLEAN,
    food_credit_lb NUMERIC,water_credit_gal NUMERIC,food_requirement_lb NUMERIC,water_requirement_gal NUMERIC,
    hunger_percent NUMERIC,thirst_percent NUMERIC,food_deficit_hours NUMERIC,water_deficit_hours NUMERIC,
    exhaustion_level INTEGER,starvation_limit_days INTEGER,starvation_days_without_food INTEGER,
    hydration_window_hours NUMERIC,hydration_consumed_gal NUMERIC,hydration_requirement_gal NUMERIC,
    effective_speed INTEGER,effective_max_hp INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_character_id UUID; v_con INTEGER;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members m WHERE m.campaign_id=p_campaign_id AND m.player_id=p_player_id)
    THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;
    SELECT c.character_id,COALESCE(c.constitution,10) INTO v_character_id,v_con
    FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(v_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY
    SELECT p_campaign_id,v_character_id,s.enabled,(c.owner_player_id=p_player_id),s.hot_weather,
           cs.food_credit_lb,cs.water_credit_gal,1.0::NUMERIC,(CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)::NUMERIC,
           ROUND(LEAST(100.0,GREATEST(0.0,cs.food_credit_lb*100.0)),1),
           ROUND(LEAST(100.0,GREATEST(0.0,cs.water_credit_gal/(CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)*100.0)),1),
           cs.food_deficit_hours,cs.water_deficit_hours,cs.exhaustion_level,
           GREATEST(1,3+FLOOR((v_con-10)/2.0)::INTEGER),
           FLOOR(cs.food_deficit_hours/24.0)::INTEGER,
           cs.hydration_window_hours,cs.hydration_consumed_gal,
           (CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)::NUMERIC,
           public.discord_exhaustion_effective_speed(v_character_id),
           public.discord_exhaustion_effective_max_hp(v_character_id)
    FROM public.discord_campaigns c
    JOIN public.discord_campaign_survival_settings s ON s.campaign_id=c.campaign_id
    JOIN public.discord_character_survival cs ON cs.character_id=v_character_id
    WHERE c.campaign_id=p_campaign_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_set_survival_enabled(UUID,UUID,BOOLEAN);
CREATE OR REPLACE FUNCTION public.discord_set_survival_enabled(p_player_id UUID,p_campaign_id UUID,p_enabled BOOLEAN)
RETURNS TABLE(
    campaign_id UUID,character_id UUID,enabled BOOLEAN,is_owner BOOLEAN,hot_weather BOOLEAN,
    food_credit_lb NUMERIC,water_credit_gal NUMERIC,food_requirement_lb NUMERIC,water_requirement_gal NUMERIC,
    hunger_percent NUMERIC,thirst_percent NUMERIC,food_deficit_hours NUMERIC,water_deficit_hours NUMERIC,
    exhaustion_level INTEGER,starvation_limit_days INTEGER,starvation_days_without_food INTEGER,
    hydration_window_hours NUMERIC,hydration_consumed_gal NUMERIC,hydration_requirement_gal NUMERIC,
    effective_speed INTEGER,effective_max_hp INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaigns c WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_player_id AND c.is_active=TRUE)
    THEN RAISE EXCEPTION 'Only the campaign owner can change Hunger and Thirst rules.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id,enabled,updated_by_player_id,updated_at)
    VALUES(p_campaign_id,COALESCE(p_enabled,FALSE),p_player_id,NOW())
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO UPDATE
    SET enabled=EXCLUDED.enabled,updated_by_player_id=EXCLUDED.updated_by_player_id,updated_at=NOW();

    INSERT INTO public.discord_character_survival(character_id,campaign_id,food_credit_lb,water_credit_gal,hydration_consumed_gal)
    SELECT c.character_id,c.campaign_id,1.0,CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END,
           CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END
    FROM public.discord_characters c JOIN public.discord_campaign_survival_settings s ON s.campaign_id=c.campaign_id
    WHERE c.campaign_id=p_campaign_id
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY SELECT * FROM public.discord_get_survival_state(p_player_id,p_campaign_id);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_survival_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_survival_state(p_campaign_id UUID,p_character_id UUID)
RETURNS TABLE(
    enabled BOOLEAN,hot_weather BOOLEAN,food_credit_lb NUMERIC,water_credit_gal NUMERIC,
    food_requirement_lb NUMERIC,water_requirement_gal NUMERIC,hunger_percent NUMERIC,thirst_percent NUMERIC,
    food_deficit_hours NUMERIC,water_deficit_hours NUMERIC,exhaustion_level INTEGER,
    starvation_limit_days INTEGER,starvation_days_without_food INTEGER,hydration_window_hours NUMERIC,
    hydration_consumed_gal NUMERIC,hydration_requirement_gal NUMERIC,effective_speed INTEGER,effective_max_hp INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_con INTEGER;
BEGIN
    SELECT COALESCE(c.constitution,10) INTO v_con FROM public.discord_characters c
    WHERE c.character_id=p_character_id AND c.campaign_id=p_campaign_id;
    IF v_con IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(p_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY
    SELECT s.enabled,s.hot_weather,cs.food_credit_lb,cs.water_credit_gal,1.0::NUMERIC,
           (CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)::NUMERIC,
           ROUND(LEAST(100.0,GREATEST(0.0,cs.food_credit_lb*100.0)),1),
           ROUND(LEAST(100.0,GREATEST(0.0,cs.water_credit_gal/(CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)*100.0)),1),
           cs.food_deficit_hours,cs.water_deficit_hours,cs.exhaustion_level,
           GREATEST(1,3+FLOOR((v_con-10)/2.0)::INTEGER),FLOOR(cs.food_deficit_hours/24.0)::INTEGER,
           cs.hydration_window_hours,cs.hydration_consumed_gal,
           (CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)::NUMERIC,
           public.discord_exhaustion_effective_speed(p_character_id),public.discord_exhaustion_effective_max_hp(p_character_id)
    FROM public.discord_campaign_survival_settings s
    JOIN public.discord_character_survival cs ON cs.campaign_id=s.campaign_id AND cs.character_id=p_character_id
    WHERE s.campaign_id=p_campaign_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Time advancement. Starvation uses 3 + CON modifier safe days (minimum 1).
-- Water is judged once per completed 24-hour hydration window:
--   >=100% requirement: safe
--   >=2/3 and <100%: DC 15 Constitution save or +1 Exhaustion
--   <2/3: automatic +1 Exhaustion
-- Hot weather doubles the required gallons; it does not invent extra penalties.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_advance_survival_time(UUID,TEXT[],NUMERIC,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_advance_survival_time(
    p_campaign_id UUID,p_character_names TEXT[],p_hours NUMERIC,p_reason TEXT DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_enabled BOOLEAN; v_hot BOOLEAN; v_hours NUMERIC:=ROUND(COALESCE(p_hours,0),2);
    v_water_req NUMERIC; v_food_rate NUMERIC:=1.0/24.0; v_water_rate NUMERIC;
    v_char RECORD; v_state public.discord_character_survival%ROWTYPE;
    v_food_deficit_add NUMERIC; v_water_deficit_add NUMERIC;
    v_safe_days INTEGER; v_food_before_penalty INTEGER; v_food_after_penalty INTEGER;
    v_starvation_add INTEGER; v_water_add INTEGER; v_total_add INTEGER;
    v_hydration_hours NUMERIC; v_hydration_consumed NUMERIC; v_ratio NUMERIC;
    v_roll INTEGER; v_con_mod INTEGER; v_total INTEGER; v_day_result JSONB; v_water_events JSONB;
    v_results JSONB:='[]'::jsonb; v_count INTEGER:=0; v_new_level INTEGER; v_effective_max INTEGER;
BEGIN
    IF v_hours<=0 OR v_hours>168 THEN RAISE EXCEPTION 'Survival time must be between 0 and 168 hours.'; END IF;
    IF COALESCE(array_length(p_character_names,1),0)=0 THEN RAISE EXCEPTION 'At least one character name is required.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled,s.hot_weather INTO v_enabled,v_hot FROM public.discord_campaign_survival_settings s WHERE s.campaign_id=p_campaign_id;
    IF NOT COALESCE(v_enabled,FALSE) THEN
        RETURN jsonb_build_object('enabled',FALSE,'changed',FALSE,'hours',v_hours,'characters','[]'::jsonb);
    END IF;
    v_water_req:=CASE WHEN v_hot THEN 2.0 ELSE 1.0 END;
    v_water_rate:=v_water_req/24.0;

    FOR v_char IN
        SELECT c.character_id,c.character_name,COALESCE(c.constitution,10) AS constitution,c.max_hp,c.current_hp,c.life_state
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id AND c.life_state='alive'
          AND EXISTS(SELECT 1 FROM unnest(p_character_names) n WHERE lower(trim(n))=lower(c.character_name))
        ORDER BY c.character_name
    LOOP
        v_count:=v_count+1;
        INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(v_char.character_id,p_campaign_id)
        ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
        SELECT * INTO v_state FROM public.discord_character_survival cs WHERE cs.character_id=v_char.character_id FOR UPDATE;

        v_food_deficit_add:=GREATEST(0,v_hours-(v_state.food_credit_lb/v_food_rate));
        v_water_deficit_add:=GREATEST(0,v_hours-(v_state.water_credit_gal/v_water_rate));
        v_safe_days:=GREATEST(1,3+FLOOR((v_char.constitution-10)/2.0)::INTEGER);
        v_food_before_penalty:=GREATEST(0,FLOOR(v_state.food_deficit_hours/24.0)::INTEGER-v_safe_days);
        v_food_after_penalty:=GREATEST(0,FLOOR((v_state.food_deficit_hours+v_food_deficit_add)/24.0)::INTEGER-v_safe_days);
        v_starvation_add:=GREATEST(0,v_food_after_penalty-v_food_before_penalty);

        v_hydration_hours:=v_state.hydration_window_hours+v_hours;
        v_hydration_consumed:=v_state.hydration_consumed_gal;
        v_water_add:=0;
        v_water_events:='[]'::jsonb;
        v_con_mod:=FLOOR((v_char.constitution-10)/2.0)::INTEGER;

        WHILE v_hydration_hours>=24 LOOP
            v_ratio:=CASE WHEN v_water_req>0 THEN v_hydration_consumed/v_water_req ELSE 1 END;
            IF v_ratio<0.6666667 THEN
                v_water_add:=v_water_add+1;
                v_day_result:=jsonb_build_object('result','automatic exhaustion','ratio',ROUND(v_ratio,3),'requiredGallons',v_water_req,'consumedGallons',ROUND(v_hydration_consumed,3));
            ELSIF v_ratio<1.0 THEN
                v_roll:=FLOOR(random()*20+1)::INTEGER;
                v_total:=v_roll+v_con_mod;
                IF v_total<15 THEN v_water_add:=v_water_add+1; END IF;
                v_day_result:=jsonb_build_object('result',CASE WHEN v_total>=15 THEN 'save succeeded' ELSE 'save failed - exhaustion' END,
                    'ratio',ROUND(v_ratio,3),'requiredGallons',v_water_req,'consumedGallons',ROUND(v_hydration_consumed,3),
                    'dc',15,'d20',v_roll,'constitutionModifier',v_con_mod,'total',v_total,'success',v_total>=15);
            ELSE
                v_day_result:=jsonb_build_object('result','requirement met','ratio',ROUND(v_ratio,3),'requiredGallons',v_water_req,'consumedGallons',ROUND(v_hydration_consumed,3));
            END IF;
            v_water_events:=v_water_events||jsonb_build_array(v_day_result);
            v_hydration_hours:=v_hydration_hours-24;
            v_hydration_consumed:=0;
        END LOOP;

        v_total_add:=v_starvation_add+v_water_add;
        v_new_level:=LEAST(6,COALESCE(v_state.exhaustion_level,0)+v_total_add);

        UPDATE public.discord_character_survival cs
        SET food_credit_lb=GREATEST(0,cs.food_credit_lb-(v_food_rate*v_hours)),
            water_credit_gal=GREATEST(0,cs.water_credit_gal-(v_water_rate*v_hours)),
            food_deficit_hours=cs.food_deficit_hours+v_food_deficit_add,
            water_deficit_hours=cs.water_deficit_hours+v_water_deficit_add,
            hydration_window_hours=v_hydration_hours,
            hydration_consumed_gal=v_hydration_consumed,
            exhaustion_level=v_new_level,
            last_reason=LEFT(TRIM(COALESCE(p_reason,'')),200),updated_at=NOW()
        WHERE cs.character_id=v_char.character_id RETURNING * INTO v_state;

        v_effective_max:=CASE WHEN v_new_level>=4 THEN GREATEST(1,FLOOR(COALESCE(v_char.max_hp,1)/2.0)::INTEGER) ELSE GREATEST(1,COALESCE(v_char.max_hp,1)) END;
        IF COALESCE(v_char.current_hp,0)>v_effective_max THEN
            UPDATE public.discord_characters c SET current_hp=v_effective_max,
                character_data=COALESCE(c.character_data,'{}'::jsonb)||jsonb_build_object('current_hp',v_effective_max),updated_at=NOW()
            WHERE c.character_id=v_char.character_id;
        END IF;
        IF v_new_level>=6 THEN
            PERFORM public.discord_gm_mark_character_dead(p_campaign_id,v_char.character_name,
                CASE WHEN v_water_add>0 THEN 'Exhaustion level 6 from dehydration' ELSE 'Exhaustion level 6 from starvation' END);
        END IF;

        v_results:=v_results||jsonb_build_array(jsonb_build_object(
            'characterName',v_char.character_name,'foodCreditLb',ROUND(v_state.food_credit_lb,2),
            'waterCreditGallons',ROUND(v_state.water_credit_gal,2),
            'hungerPercent',ROUND(LEAST(100,GREATEST(0,v_state.food_credit_lb*100)),1),
            'thirstPercent',ROUND(LEAST(100,GREATEST(0,v_state.water_credit_gal/v_water_req*100)),1),
            'starvationLimitDays',v_safe_days,'starvationDaysWithoutFood',FLOOR(v_state.food_deficit_hours/24.0)::INTEGER,
            'starvationExhaustionAdded',v_starvation_add,'hydrationDayResults',v_water_events,
            'dehydrationExhaustionAdded',v_water_add,'exhaustionLevel',v_state.exhaustion_level,
            'exhaustionAdded',v_total_add,'effectiveSpeed',public.discord_exhaustion_effective_speed(v_char.character_id),
            'effectiveMaxHp',public.discord_exhaustion_effective_max_hp(v_char.character_id)));
    END LOOP;

    IF v_count=0 THEN RAISE EXCEPTION 'None of the named living characters could be found in this campaign.'; END IF;
    RETURN jsonb_build_object('enabled',TRUE,'changed',TRUE,'hours',v_hours,'hotWeather',v_hot,'characters',v_results);
END;
$$;

-- Generic carried food / drink consumption also counts toward Long Rest
-- recovery and the current 24-hour hydration window.
DROP FUNCTION IF EXISTS public.discord_gm_consume_survival_item(UUID,UUID,UUID,INTEGER,NUMERIC,NUMERIC,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_consume_survival_item(
    p_campaign_id UUID,p_character_id UUID,p_inventory_item_id UUID,p_quantity INTEGER,
    p_food_lb_per_item NUMERIC,p_water_gallons_per_item NUMERIC,p_reason TEXT DEFAULT '')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_enabled BOOLEAN; v_hot BOOLEAN; v_req NUMERIC; v_item RECORD; v_state RECORD;
    v_qty INTEGER:=GREATEST(1,COALESCE(p_quantity,1));
    v_food NUMERIC:=GREATEST(0,COALESCE(p_food_lb_per_item,0))*v_qty;
    v_water NUMERIC:=GREATEST(0,COALESCE(p_water_gallons_per_item,0))*v_qty; v_remaining INTEGER;
BEGIN
    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled,s.hot_weather INTO v_enabled,v_hot FROM public.discord_campaign_survival_settings s WHERE s.campaign_id=p_campaign_id;
    IF NOT COALESCE(v_enabled,FALSE) THEN RAISE EXCEPTION 'Hunger and Thirst rules are disabled for this campaign.'; END IF;
    IF v_food<=0 AND v_water<=0 THEN RAISE EXCEPTION 'This item has no recognized food or drinking-water value.'; END IF;
    v_req:=CASE WHEN v_hot THEN 2.0 ELSE 1.0 END;

    SELECT i.* INTO v_item FROM public.discord_inventory_items i WHERE i.inventory_item_id=p_inventory_item_id AND i.character_id=p_character_id FOR UPDATE;
    IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.discord_characters c WHERE c.character_id=p_character_id AND c.campaign_id=p_campaign_id)
    THEN RAISE EXCEPTION 'Inventory item could not be found for this character.'; END IF;
    IF v_item.quantity<v_qty THEN RAISE EXCEPTION 'Not enough of this inventory item is carried.'; END IF;
    v_remaining:=v_item.quantity-v_qty;
    IF v_remaining<=0 THEN DELETE FROM public.discord_inventory_items i WHERE i.inventory_item_id=p_inventory_item_id;
    ELSE UPDATE public.discord_inventory_items i SET quantity=v_remaining,updated_at=NOW() WHERE i.inventory_item_id=p_inventory_item_id; END IF;

    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(p_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
    UPDATE public.discord_character_survival cs
    SET food_credit_lb=LEAST(1.0,cs.food_credit_lb+v_food),
        water_credit_gal=LEAST(v_req,cs.water_credit_gal+v_water),
        food_deficit_hours=CASE WHEN v_food>0 THEN 0 ELSE cs.food_deficit_hours END,
        water_deficit_hours=CASE WHEN v_water>0 THEN 0 ELSE cs.water_deficit_hours END,
        food_ingested_since_long_rest=cs.food_ingested_since_long_rest+v_food,
        water_ingested_since_long_rest=cs.water_ingested_since_long_rest+v_water,
        hydration_consumed_gal=cs.hydration_consumed_gal+v_water,
        last_reason=LEFT(TRIM(COALESCE(p_reason,'')),200),updated_at=NOW()
    WHERE cs.character_id=p_character_id RETURNING * INTO v_state;

    RETURN jsonb_build_object('authoritative',TRUE,'action','consume_survival_item','itemName',v_item.item_name,
        'quantityConsumed',v_qty,'quantityRemaining',GREATEST(0,v_remaining),'foodAppliedLb',ROUND(v_food,2),
        'waterAppliedGallons',ROUND(v_water,3),'foodCreditLb',ROUND(v_state.food_credit_lb,2),
        'waterCreditGallons',ROUND(v_state.water_credit_gal,2),'hungerPercent',ROUND(LEAST(100,GREATEST(0,v_state.food_credit_lb*100)),1),
        'thirstPercent',ROUND(LEAST(100,GREATEST(0,v_state.water_credit_gal/v_req*100)),1),'hotWeather',v_hot,
        'exhaustionLevel',v_state.exhaustion_level);
END;
$$;

-- Ration portions: +0.33 lb food, reset starvation clock, and record food intake.
DROP FUNCTION IF EXISTS public.discord_eat_ration_portion(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_eat_ration_portion(p_player_id UUID,p_campaign_id UUID,p_inventory_item_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_character_id UUID; v_character_name TEXT; v_item_name TEXT; v_days INTEGER; v_portions INTEGER;
    v_remaining INTEGER; v_maximum INTEGER; v_enabled BOOLEAN; v_state RECORD; v_hunger_before NUMERIC;
    v_hunger_after NUMERIC; v_restored NUMERIC; v_pack_consumed BOOLEAN;
BEGIN
    SELECT c.character_id,c.character_name INTO v_character_id,v_character_name
    FROM public.discord_characters c JOIN public.discord_campaign_members m ON m.campaign_id=c.campaign_id AND m.player_id=p_player_id
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    SELECT public.discord_ration_days_from_name(i.item_name),i.item_name INTO v_days,v_item_name
    FROM public.discord_inventory_items i WHERE i.inventory_item_id=p_inventory_item_id AND i.character_id=v_character_id FOR UPDATE;
    IF NOT FOUND OR v_days IS NULL THEN RAISE EXCEPTION 'Ration pack could not be found in this character''s inventory.'; END IF;
    INSERT INTO public.discord_ration_state(inventory_item_id,character_id,campaign_id,day_count,portions_remaining)
    VALUES(p_inventory_item_id,v_character_id,p_campaign_id,v_days,v_days*3)
    ON CONFLICT ON CONSTRAINT discord_ration_state_pkey DO NOTHING;
    SELECT rs.day_count,rs.portions_remaining INTO v_days,v_portions FROM public.discord_ration_state rs
    WHERE rs.inventory_item_id=p_inventory_item_id AND rs.character_id=v_character_id AND rs.campaign_id=p_campaign_id FOR UPDATE;
    IF NOT FOUND OR v_portions<=0 THEN RAISE EXCEPTION 'That ration pack has no portions remaining.'; END IF;
    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled INTO v_enabled FROM public.discord_campaign_survival_settings s WHERE s.campaign_id=p_campaign_id;
    IF NOT COALESCE(v_enabled,FALSE) THEN RAISE EXCEPTION 'Hunger and Thirst rules are disabled for this campaign.'; END IF;
    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(v_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
    SELECT * INTO v_state FROM public.discord_character_survival cs WHERE cs.character_id=v_character_id FOR UPDATE;
    v_hunger_before:=ROUND(LEAST(100.0,GREATEST(0.0,v_state.food_credit_lb*100.0)),1);
    UPDATE public.discord_character_survival cs SET food_credit_lb=LEAST(1.0,cs.food_credit_lb+0.33),food_deficit_hours=0,
        food_ingested_since_long_rest=cs.food_ingested_since_long_rest+0.33,last_reason='Ate one portion from a ration pack.',updated_at=NOW()
    WHERE cs.character_id=v_character_id RETURNING * INTO v_state;
    v_hunger_after:=ROUND(LEAST(100.0,GREATEST(0.0,v_state.food_credit_lb*100.0)),1); v_restored:=ROUND(v_hunger_after-v_hunger_before,1);
    v_remaining:=v_portions-1; v_maximum:=v_days*3; v_pack_consumed:=v_remaining<=0;
    IF v_pack_consumed THEN DELETE FROM public.discord_inventory_items i WHERE i.inventory_item_id=p_inventory_item_id AND i.character_id=v_character_id;
    ELSE UPDATE public.discord_ration_state rs SET portions_remaining=v_remaining,updated_at=NOW() WHERE rs.inventory_item_id=p_inventory_item_id; END IF;
    RETURN jsonb_build_object('success',TRUE,'inventoryItemId',p_inventory_item_id,'itemName',v_item_name,'dayCount',v_days,
        'portionsRemaining',GREATEST(0,v_remaining),'maximumPortions',v_maximum,'hungerPercentBefore',v_hunger_before,
        'hungerPercentAfter',v_hunger_after,'hungerPercentRestored',v_restored,'packConsumed',v_pack_consumed,
        'message',CASE WHEN v_pack_consumed THEN FORMAT('%s ate one ration portion. Hunger is now %s%%. The ration pack is finished.',v_character_name,v_hunger_after)
        ELSE FORMAT('%s ate one ration portion. Hunger is now %s%%. %s of %s portions remain.',v_character_name,v_hunger_after,v_remaining,v_maximum) END);
END;
$$;

-- Waterskin drinks count as actual daily water intake and Long Rest intake.
DROP FUNCTION IF EXISTS public.discord_drink_waterskin(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_drink_waterskin(p_player_id UUID,p_campaign_id UUID,p_inventory_item_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_character_id UUID; v_character_name TEXT; v_kind TEXT; v_quality TEXT; v_drinks INTEGER; v_remaining INTEGER;
    v_enabled BOOLEAN; v_hot BOOLEAN; v_water_requirement NUMERIC; v_water_delta NUMERIC; v_state RECORD;
    v_hunger_before NUMERIC; v_thirst_before NUMERIC; v_hunger_after NUMERIC; v_thirst_after NUMERIC; v_nauseated BOOLEAN;
BEGIN
    SELECT c.character_id,c.character_name INTO v_character_id,v_character_name
    FROM public.discord_characters c JOIN public.discord_campaign_members m ON m.campaign_id=c.campaign_id AND m.player_id=p_player_id
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    SELECT ws.waterskin_kind,ws.water_quality,ws.drinks_remaining INTO v_kind,v_quality,v_drinks
    FROM public.discord_waterskin_state ws JOIN public.discord_inventory_items i ON i.inventory_item_id=ws.inventory_item_id
    WHERE ws.inventory_item_id=p_inventory_item_id AND ws.character_id=v_character_id AND ws.campaign_id=p_campaign_id AND i.character_id=v_character_id FOR UPDATE OF ws;
    IF NOT FOUND THEN RAISE EXCEPTION 'Waterskin could not be found in this character''s inventory.'; END IF;
    IF v_drinks<=0 OR v_quality='empty' THEN RAISE EXCEPTION 'That waterskin is empty.'; END IF;
    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled,s.hot_weather INTO v_enabled,v_hot FROM public.discord_campaign_survival_settings s WHERE s.campaign_id=p_campaign_id;
    IF NOT COALESCE(v_enabled,FALSE) THEN RAISE EXCEPTION 'Hunger and Thirst rules are disabled for this campaign.'; END IF;
    v_water_requirement:=CASE WHEN v_hot THEN 2.0 ELSE 1.0 END;
    v_water_delta:=v_water_requirement*CASE WHEN v_quality='tainted' THEN 0.01 ELSE 0.10 END;
    v_nauseated:=v_quality='tainted';
    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(v_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
    SELECT * INTO v_state FROM public.discord_character_survival cs WHERE cs.character_id=v_character_id FOR UPDATE;
    v_hunger_before:=ROUND(LEAST(100.0,GREATEST(0.0,v_state.food_credit_lb*100.0)),1);
    v_thirst_before:=ROUND(LEAST(100.0,GREATEST(0.0,v_state.water_credit_gal/v_water_requirement*100.0)),1);
    UPDATE public.discord_character_survival cs
    SET food_credit_lb=CASE WHEN v_nauseated THEN GREATEST(0.0,cs.food_credit_lb-0.30) ELSE cs.food_credit_lb END,
        water_credit_gal=LEAST(v_water_requirement,cs.water_credit_gal+v_water_delta),water_deficit_hours=0,
        water_ingested_since_long_rest=cs.water_ingested_since_long_rest+v_water_delta,
        hydration_consumed_gal=cs.hydration_consumed_gal+v_water_delta,
        last_reason=CASE WHEN v_nauseated THEN 'Drank tainted waterskin water; nausea applied.' ELSE 'Drank one waterskin serving.' END,updated_at=NOW()
    WHERE cs.character_id=v_character_id RETURNING * INTO v_state;
    v_remaining:=v_drinks-1;
    UPDATE public.discord_waterskin_state ws SET drinks_remaining=v_remaining,water_quality=CASE WHEN v_remaining=0 THEN 'empty' ELSE ws.water_quality END,
        source_name=CASE WHEN v_remaining=0 THEN '' ELSE ws.source_name END,updated_at=NOW() WHERE ws.inventory_item_id=p_inventory_item_id;
    v_hunger_after:=ROUND(LEAST(100.0,GREATEST(0.0,v_state.food_credit_lb*100.0)),1);
    v_thirst_after:=ROUND(LEAST(100.0,GREATEST(0.0,v_state.water_credit_gal/v_water_requirement*100.0)),1);
    RETURN jsonb_build_object('success',TRUE,'inventoryItemId',p_inventory_item_id,
        'itemName',CASE WHEN v_kind='magic' THEN 'Magic Waterskin' WHEN v_quality='tainted' THEN 'Waterskin(Tainted)' ELSE 'Waterskin' END,
        'waterskinKind',v_kind,'waterQuality',v_quality,'drinksRemaining',v_remaining,'thirstPercentBefore',v_thirst_before,
        'thirstPercentAfter',v_thirst_after,'hungerPercentBefore',v_hunger_before,'hungerPercentAfter',v_hunger_after,
        'nauseated',v_nauseated,'message',CASE WHEN v_nauseated THEN FORMAT('%s drank tainted water. Thirst is now %s%% and nausea reduced Hunger to %s%%.',v_character_name,v_thirst_after,v_hunger_after)
        ELSE FORMAT('%s drank from the waterskin. Thirst is now %s%%. %s drinks remain.',v_character_name,v_thirst_after,v_remaining) END);
END;
$$;

-- ---------------------------------------------------------------------------
-- Long Rest: reduce Exhaustion by 1 only if both food and drink were ingested
-- since the prior completed Long Rest. Restore HP only up to effective max.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_complete_long_rest(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_complete_long_rest(p_campaign_id UUID,p_character_name TEXT,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE; v_from INTEGER; v_to INTEGER; v_hp_gain INTEGER:=0;
    v_gain_per_level INTEGER:=0; v_subrace_hp_bonus INTEGER:=0; v_new_max INTEGER; v_effective_max INTEGER;
    v_is_caster BOOLEAN:=FALSE; v_hit_dice_restored INTEGER:=0; v_reason TEXT:=LEFT(trim(COALESCE(p_reason,'')),240);
    v_result_data JSONB; v_state public.discord_character_survival%ROWTYPE; v_ex_before INTEGER:=0; v_ex_after INTEGER:=0;
    v_ex_reduced BOOLEAN:=FALSE;
BEGIN
    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE)
    THEN RAISE EXCEPTION 'A Long Rest cannot complete while combat is active.'; END IF;
    SELECT * INTO v_character FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,''))) LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF COALESCE(v_character.life_state,'alive')<>'alive' OR COALESCE(v_character.current_hp,0)<1 THEN RAISE EXCEPTION '% cannot complete a Long Rest while dead or at 0 HP.',v_character.character_name; END IF;
    IF EXISTS(SELECT 1 FROM public.discord_character_level_up_state s WHERE s.character_id=v_character.character_id AND s.pending=TRUE)
    THEN RAISE EXCEPTION '% still has unfinished choices from the previous level up.',v_character.character_name; END IF;

    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(v_character.character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
    SELECT * INTO v_state FROM public.discord_character_survival cs WHERE cs.character_id=v_character.character_id FOR UPDATE;
    v_ex_before:=COALESCE(v_state.exhaustion_level,0);
    v_ex_after:=v_ex_before;
    IF v_ex_before>0 AND v_state.food_ingested_since_long_rest>0 AND v_state.water_ingested_since_long_rest>0 THEN
        v_ex_after:=v_ex_before-1; v_ex_reduced:=TRUE;
    END IF;
    UPDATE public.discord_character_survival cs SET exhaustion_level=v_ex_after,
        food_ingested_since_long_rest=0,water_ingested_since_long_rest=0,
        last_reason=CASE WHEN v_ex_reduced THEN 'Long Rest with food and drink reduced Exhaustion by 1.' ELSE cs.last_reason END,updated_at=NOW()
    WHERE cs.character_id=v_character.character_id;

    v_from:=GREATEST(1,LEAST(20,COALESCE(v_character.level,1))); v_to:=GREATEST(v_from,public.discord_level_for_xp(v_character.experience));
    BEGIN v_subrace_hp_bonus:=GREATEST(0,COALESCE(NULLIF(v_character.character_data #>> '{features,hitPointBonusPerLevel}','')::INTEGER,0));
    EXCEPTION WHEN OTHERS THEN v_subrace_hp_bonus:=0; END;
    v_gain_per_level:=public.discord_fixed_hp_gain(v_character.class_name,v_character.constitution)+v_subrace_hp_bonus;
    v_hp_gain:=GREATEST(0,v_to-v_from)*v_gain_per_level; v_new_max:=GREATEST(1,COALESCE(v_character.max_hp,1)+v_hp_gain);
    v_effective_max:=CASE WHEN v_ex_after>=4 THEN GREATEST(1,FLOOR(v_new_max/2.0)::INTEGER) ELSE v_new_max END;
    v_is_caster:=lower(v_character.class_name) IN ('bard','cleric','druid','paladin','ranger','sorcerer','warlock','wizard');
    v_hit_dice_restored:=GREATEST(0,LEAST(v_from,COALESCE(v_character.hit_dice_spent,0)));

    UPDATE public.discord_characters c SET level=v_to,proficiency_bonus=public.discord_proficiency_for_level(v_to),max_hp=v_new_max,
        current_hp=v_effective_max,hit_dice_spent=0,spells_complete=CASE WHEN v_to>v_from AND v_is_caster THEN FALSE ELSE c.spells_complete END,
        character_data=jsonb_set(jsonb_set(jsonb_set(jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{level}',to_jsonb(v_to),TRUE),
            '{current_hp}',to_jsonb(v_effective_max),TRUE),'{max_hp}',to_jsonb(v_new_max),TRUE),'{proficiency_bonus}',to_jsonb(public.discord_proficiency_for_level(v_to)),TRUE),updated_at=NOW()
    WHERE c.character_id=v_character.character_id;
    UPDATE public.discord_spell_slots SET used_slots=0 WHERE character_id=v_character.character_id;
    DELETE FROM public.discord_character_rest_state r WHERE r.character_id=v_character.character_id;

    IF v_to>v_from THEN
        INSERT INTO public.discord_character_level_up_state(character_id,campaign_id,from_level,to_level,pending,rest_reason,ability_choices,created_at,completed_at)
        VALUES(v_character.character_id,p_campaign_id,v_from,v_to,TRUE,v_reason,'{}'::jsonb,NOW(),NULL)
        ON CONFLICT(character_id) DO UPDATE SET campaign_id=EXCLUDED.campaign_id,from_level=EXCLUDED.from_level,to_level=EXCLUDED.to_level,pending=TRUE,
            rest_reason=EXCLUDED.rest_reason,ability_choices='{}'::jsonb,created_at=NOW(),completed_at=NULL;
    ELSE
        v_result_data:=jsonb_build_object('hpRestoredTo',v_effective_max,'baseMaxHp',v_new_max,'hitDiceRestored',v_hit_dice_restored,
            'spellSlotsRestored',v_is_caster,'leveledUp',FALSE,'fromLevel',v_from,'toLevel',v_to,'exhaustionReduced',v_ex_reduced,'exhaustionLevel',v_ex_after);
        INSERT INTO public.discord_character_rest_state(character_id,campaign_id,rest_type,status,hit_dice_spent_this_rest,reason,roll_log,result_data,created_at,updated_at)
        VALUES(v_character.character_id,p_campaign_id,'long',CASE WHEN v_is_caster THEN 'spell_review' ELSE 'long_complete' END,0,v_reason,'[]'::jsonb,v_result_data,NOW(),NOW())
        ON CONFLICT(character_id) DO UPDATE SET campaign_id=EXCLUDED.campaign_id,rest_type='long',status=EXCLUDED.status,hit_dice_spent_this_rest=0,
            reason=EXCLUDED.reason,roll_log='[]'::jsonb,result_data=EXCLUDED.result_data,created_at=NOW(),updated_at=NOW();
    END IF;

    RETURN jsonb_build_object('characterId',v_character.character_id,'characterName',v_character.character_name,'leveledUp',v_to>v_from,
        'fromLevel',v_from,'toLevel',v_to,'experience',v_character.experience,'hpGain',v_hp_gain,'maxHp',v_new_max,
        'effectiveMaxHp',v_effective_max,'proficiencyBonus',public.discord_proficiency_for_level(v_to),
        'spellSelectionRequired',v_to>v_from AND v_is_caster,'spellReviewAvailable',v_to=v_from AND v_is_caster,
        'hitDiceRestored',v_hit_dice_restored,'exhaustionReduced',v_ex_reduced,'exhaustionLevel',v_ex_after,
        'recoveryFoodMet',v_state.food_ingested_since_long_rest>0,'recoveryDrinkMet',v_state.water_ingested_since_long_rest>0,'reason',v_reason);
END;
$$;

-- Healing respects the Level 4 effective max HP cap.
DROP FUNCTION IF EXISTS public.discord_gm_adjust_character_hp(UUID,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_adjust_character_hp(p_campaign_id UUID,p_character_name TEXT,p_hp_delta INTEGER,p_reason TEXT DEFAULT '')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_character public.discord_characters%ROWTYPE; v_new_hp INTEGER; v_effective_max INTEGER;
BEGIN
    SELECT c.* INTO v_character FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,''))) LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Party character not found: %',p_character_name; END IF;
    IF v_character.life_state='dead' AND COALESCE(p_hp_delta,0)>0 THEN RAISE EXCEPTION '% is dead. Normal healing cannot revive them; use a valid revival effect or the respawn system.',v_character.character_name; END IF;
    v_effective_max:=COALESCE(public.discord_exhaustion_effective_max_hp(v_character.character_id),GREATEST(1,v_character.max_hp));
    v_new_hp:=LEAST(v_effective_max,GREATEST(0,COALESCE(v_character.current_hp,0)+COALESCE(p_hp_delta,0)));
    UPDATE public.discord_characters c SET current_hp=v_new_hp,character_data=COALESCE(c.character_data,'{}'::jsonb)||jsonb_build_object('current_hp',v_new_hp),updated_at=NOW()
    WHERE c.character_id=v_character.character_id;
    RETURN jsonb_build_object('character_id',v_character.character_id,'character_name',v_character.character_name,'current_hp',v_new_hp,
        'max_hp',v_character.max_hp,'effective_max_hp',v_effective_max,'hp_delta',COALESCE(p_hp_delta,0),'life_state',v_character.life_state,
        'reason',LEFT(TRIM(COALESCE(p_reason,'')),160));
END;
$$;

-- Online initiative now carries Exhaustion so the server can force Level 1 disadvantage.
DROP FUNCTION IF EXISTS public.discord_gm_get_initiative_candidates(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_initiative_candidates(p_campaign_id UUID)
RETURNS TABLE(entity_type TEXT,character_id UUID,combat_monster_id UUID,display_name TEXT,monster_name TEXT,initiative_modifier INTEGER,exhaustion_level INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE)
    THEN RAISE EXCEPTION 'No active combat exists for this campaign.'; END IF;
    RETURN QUERY
    SELECT 'character'::text,c.character_id,NULL::uuid,c.character_name,''::text,
           COALESCE(c.initiative,FLOOR((COALESCE(c.dexterity,10)-10)/2.0)::integer),COALESCE(cs.exhaustion_level,0)
    FROM public.discord_characters c
    LEFT JOIN public.discord_character_survival cs ON cs.character_id=c.character_id
    WHERE c.campaign_id=p_campaign_id AND c.life_state='alive'
      AND EXISTS(SELECT 1 FROM public.discord_campaign_presence pr WHERE pr.campaign_id=p_campaign_id AND pr.player_id=c.player_id AND pr.last_seen_at>=NOW()-INTERVAL '15 seconds')
    UNION ALL
    SELECT 'monster'::text,NULL::uuid,m.combat_monster_id,m.display_name,m.monster_name,0,0
    FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND m.defeated=FALSE AND m.disposition='hostile' AND m.current_hp>0;
END;
$$;

-- Tactical player movement enforces Level 2 half speed and Level 5 speed 0.
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

-- Permissions
REVOKE ALL ON FUNCTION public.discord_exhaustion_effective_speed(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_exhaustion_effective_max_hp(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_character_exhaustion(UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_exhaustion_effects(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_adjust_exhaustion(UUID,TEXT,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_survival_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_set_survival_enabled(UUID,UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_survival_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_advance_survival_time(UUID,TEXT[],NUMERIC,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_consume_survival_item(UUID,UUID,UUID,INTEGER,NUMERIC,NUMERIC,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_eat_ration_portion(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_drink_waterskin(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_adjust_character_hp(UUID,TEXT,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_initiative_candidates(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_exhaustion_effective_speed(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_exhaustion_effective_max_hp(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_character_exhaustion(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_exhaustion_effects(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_adjust_exhaustion(UUID,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_survival_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_survival_enabled(UUID,UUID,BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_survival_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_advance_survival_time(UUID,TEXT[],NUMERIC,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_consume_survival_item(UUID,UUID,UUID,INTEGER,NUMERIC,NUMERIC,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_eat_ration_portion(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_drink_waterskin(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_adjust_character_hp(UUID,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_initiative_candidates(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_move_own_combat_token_costed(UUID,UUID,INTEGER,INTEGER,INTEGER) TO service_role;

COMMIT;
