-- ============================================================
-- RabuShinAIGM Rules Build 6.16
-- World Time, Weather, Travel, Sleeping, and Long Rest Progress
-- Requires Build 6.15 (including migration 35) and Build 6.8+ survival.
-- Safe to run more than once.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_campaign_world_time
(
    campaign_id UUID PRIMARY KEY REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    world_minute BIGINT NOT NULL DEFAULT 480 CHECK (world_minute >= 0),
    weather_key TEXT NOT NULL DEFAULT 'clear',
    weather_label TEXT NOT NULL DEFAULT 'Clear',
    hot_weather BOOLEAN NOT NULL DEFAULT FALSE,
    weather_reason TEXT NOT NULL DEFAULT 'Campaign began under clear skies.',
    weather_segment BIGINT NOT NULL DEFAULT 1,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Build 6.16 turns Build 6.15 lodging days into actual night reservations.
ALTER TABLE public.discord_inn_lodging_bookings
    ADD COLUMN IF NOT EXISTS check_in_night INTEGER NULL,
    ADD COLUMN IF NOT EXISTS paid_through_night INTEGER NULL,
    ADD COLUMN IF NOT EXISTS last_used_night INTEGER NULL;

DROP FUNCTION IF EXISTS public.discord_lodging_night_index(BIGINT);
CREATE OR REPLACE FUNCTION public.discord_lodging_night_index(p_world_minute BIGINT)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT FLOOR((GREATEST(0,COALESCE(p_world_minute,0)) - 360)::NUMERIC / 1440.0)::INTEGER + 1;
$$;

DROP FUNCTION IF EXISTS public.discord_stamp_lodging_world_nights();
CREATE OR REPLACE FUNCTION public.discord_stamp_lodging_world_nights()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_world BIGINT;
    v_night INTEGER;
BEGIN
    INSERT INTO public.discord_campaign_world_time(campaign_id)
    VALUES(NEW.campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

    SELECT w.world_minute INTO v_world
    FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=NEW.campaign_id;

    v_night:=public.discord_lodging_night_index(v_world);
    IF NEW.check_in_night IS NULL THEN NEW.check_in_night:=v_night; END IF;
    IF NEW.paid_through_night IS NULL THEN
        NEW.paid_through_night:=NEW.check_in_night + GREATEST(1,NEW.days_purchased) - 1;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_stamp_lodging_world_nights ON public.discord_inn_lodging_bookings;
CREATE TRIGGER trg_discord_stamp_lodging_world_nights
BEFORE INSERT ON public.discord_inn_lodging_bookings
FOR EACH ROW EXECUTE FUNCTION public.discord_stamp_lodging_world_nights();

-- Backfill any Build 6.15 reservations created before the world clock existed.
UPDATE public.discord_inn_lodging_bookings b
SET check_in_night=COALESCE(
        b.check_in_night,
        public.discord_lodging_night_index(COALESCE(
            (SELECT w.world_minute FROM public.discord_campaign_world_time w WHERE w.campaign_id=b.campaign_id),
            480))),
    paid_through_night=COALESCE(
        b.paid_through_night,
        public.discord_lodging_night_index(COALESCE(
            (SELECT w.world_minute FROM public.discord_campaign_world_time w WHERE w.campaign_id=b.campaign_id),
            480)) + GREATEST(1,b.days_remaining) - 1)
WHERE b.check_in_night IS NULL OR b.paid_through_night IS NULL;

CREATE TABLE IF NOT EXISTS public.discord_character_sleep_sessions
(
    sleep_session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'sleeping' CHECK (status IN ('sleeping','completed','woke_early','interrupted')),
    started_world_minute BIGINT NOT NULL,
    target_world_minute BIGINT NOT NULL,
    ended_world_minute BIGINT NULL,
    starting_hp INTEGER NOT NULL CHECK (starting_hp >= 0),
    starting_max_hp INTEGER NOT NULL CHECK (starting_max_hp > 0),
    missing_hp INTEGER NOT NULL CHECK (missing_hp >= 0),
    safe_location BOOLEAN NOT NULL DEFAULT FALSE,
    paid_lodging BOOLEAN NOT NULL DEFAULT FALSE,
    lodging_booking_id UUID NULL REFERENCES public.discord_inn_lodging_bookings(booking_id) ON DELETE SET NULL,
    inn_name TEXT NOT NULL DEFAULT '',
    lifestyle TEXT NOT NULL DEFAULT '',
    location_description TEXT NOT NULL DEFAULT '',
    reason TEXT NOT NULL DEFAULT '',
    completion_result JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_sleep_one_active_character
ON public.discord_character_sleep_sessions(character_id)
WHERE status='sleeping';

CREATE INDEX IF NOT EXISTS ix_discord_sleep_campaign_status
ON public.discord_character_sleep_sessions(campaign_id,status,started_world_minute);

ALTER TABLE public.discord_campaign_world_time ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_character_sleep_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_campaign_world_time FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.discord_character_sleep_sessions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_campaign_world_time TO service_role;
GRANT ALL ON public.discord_character_sleep_sessions TO service_role;

INSERT INTO public.discord_campaign_world_time(campaign_id)
SELECT c.campaign_id FROM public.discord_campaigns c
ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

-- -----------------------------------------------------------------
-- Build a compact world-state JSON object from the authoritative clock.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_build_world_time_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_build_world_time_state(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_state public.discord_campaign_world_time%ROWTYPE;
    v_day INTEGER;
    v_minute_of_day INTEGER;
    v_hour INTEGER;
    v_minute INTEGER;
    v_period TEXT;
    v_daypart TEXT;
    v_location TEXT;
BEGIN
    SELECT * INTO v_state
    FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id;

    IF v_state.campaign_id IS NULL THEN
        RETURN NULL;
    END IF;

    v_day := FLOOR(v_state.world_minute / 1440.0)::INTEGER + 1;
    v_minute_of_day := MOD(v_state.world_minute,1440)::INTEGER;
    v_hour := FLOOR(v_minute_of_day / 60.0)::INTEGER;
    v_minute := MOD(v_minute_of_day,60);
    v_period := CASE WHEN v_hour < 12 THEN 'AM' ELSE 'PM' END;
    v_daypart := CASE
        WHEN v_hour BETWEEN 5 AND 7 THEN 'Dawn'
        WHEN v_hour BETWEEN 8 AND 11 THEN 'Morning'
        WHEN v_hour BETWEEN 12 AND 16 THEN 'Afternoon'
        WHEN v_hour BETWEEN 17 AND 19 THEN 'Evening'
        WHEN v_hour BETWEEN 20 AND 23 THEN 'Night'
        ELSE 'Late Night'
    END;

    SELECT COALESCE(c.current_location,'Unknown') INTO v_location
    FROM public.discord_campaigns c WHERE c.campaign_id=p_campaign_id;

    RETURN jsonb_build_object(
        'campaignId',p_campaign_id,
        'worldMinute',v_state.world_minute,
        'dayNumber',v_day,
        'minuteOfDay',v_minute_of_day,
        'hour24',v_hour,
        'minute',v_minute,
        'hour12',CASE WHEN MOD(v_hour,12)=0 THEN 12 ELSE MOD(v_hour,12) END,
        'period',v_period,
        'displayTime',LPAD((CASE WHEN MOD(v_hour,12)=0 THEN 12 ELSE MOD(v_hour,12) END)::TEXT,2,'0') || ':' || LPAD(v_minute::TEXT,2,'0') || ' ' || v_period,
        'dayPart',v_daypart,
        'isDaylight',(v_hour>=6 AND v_hour<20),
        'weatherKey',v_state.weather_key,
        'weatherLabel',v_state.weather_label,
        'hotWeather',v_state.hot_weather,
        'weatherReason',v_state.weather_reason,
        'currentLocation',v_location,
        'updatedAt',v_state.updated_at
    );
END;
$$;

-- -----------------------------------------------------------------
-- Deterministic location-aware weather whenever a six-hour segment changes.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_build6_16_weather(TEXT,UUID,BIGINT);
CREATE OR REPLACE FUNCTION public.discord_build6_16_weather(
    p_location TEXT,
    p_campaign_id UUID,
    p_segment BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_location TEXT := LOWER(TRIM(COALESCE(p_location,'')));
    v_roll INTEGER := MOD(ABS(hashtext(COALESCE(p_campaign_id::TEXT,'') || ':' || p_segment::TEXT || ':' || v_location)::BIGINT),100)::INTEGER;
    v_key TEXT;
    v_label TEXT;
    v_hot BOOLEAN := FALSE;
BEGIN
    IF v_location LIKE '%frostharbor%' THEN
        IF v_roll < 35 THEN v_key:='cold-clear'; v_label:='Cold and Clear';
        ELSIF v_roll < 65 THEN v_key:='snow'; v_label:='Light Snow';
        ELSIF v_roll < 85 THEN v_key:='fog'; v_label:='Freezing Fog';
        ELSE v_key:='snowstorm'; v_label:='Snowstorm'; END IF;
    ELSIF v_location LIKE '%sunspire%' THEN
        v_hot := TRUE;
        IF v_roll < 45 THEN v_key:='hot-clear'; v_label:='Hot and Clear';
        ELSIF v_roll < 70 THEN v_key:='dry-wind'; v_label:='Hot Dry Wind';
        ELSIF v_roll < 88 THEN v_key:='haze'; v_label:='Heat Haze';
        ELSE v_key:='sandstorm'; v_label:='Sandstorm'; END IF;
    ELSIF v_location LIKE '%emberfall%' THEN
        v_hot := v_roll < 65;
        IF v_roll < 35 THEN v_key:='warm-clear'; v_label:='Warm and Clear';
        ELSIF v_roll < 65 THEN v_key:='ash-haze'; v_label:='Hot Ash Haze';
        ELSIF v_roll < 85 THEN v_key:='cloudy'; v_label:='Heavy Cloud';
        ELSE v_key:='storm'; v_label:='Thunderstorm'; END IF;
    ELSIF v_location LIKE '%marrowfen%' THEN
        IF v_roll < 25 THEN v_key:='overcast'; v_label:='Overcast';
        ELSIF v_roll < 55 THEN v_key:='fog'; v_label:='Marsh Fog';
        ELSIF v_roll < 82 THEN v_key:='rain'; v_label:='Steady Rain';
        ELSE v_key:='storm'; v_label:='Marsh Thunderstorm'; END IF;
    ELSE
        IF v_roll < 38 THEN v_key:='clear'; v_label:='Clear';
        ELSIF v_roll < 62 THEN v_key:='cloudy'; v_label:='Cloudy';
        ELSIF v_roll < 80 THEN v_key:='rain'; v_label:='Light Rain';
        ELSIF v_roll < 92 THEN v_key:='fog'; v_label:='Fog';
        ELSE v_key:='storm'; v_label:='Storm'; END IF;
    END IF;

    RETURN jsonb_build_object('weatherKey',v_key,'weatherLabel',v_label,'hotWeather',v_hot);
END;
$$;

-- -----------------------------------------------------------------
-- Apply HP recovery for every sleeping character based on WORLD TIME.
-- 8-hour Long Rest: missing HP / 8 per hour, accumulated fractionally.
-- The stored HP remains an integer; completion at 8 hours guarantees full HP
-- because the existing authoritative Long Rest finalizer is then invoked.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_apply_sleep_progress(UUID);
CREATE OR REPLACE FUNCTION public.discord_apply_sleep_progress(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_world BIGINT;
    v_sleep RECORD;
    v_elapsed BIGINT;
    v_exact NUMERIC(14,4);
    v_target_hp INTEGER;
    v_complete JSONB;
    v_results JSONB := '[]'::jsonb;
BEGIN
    SELECT w.world_minute INTO v_world
    FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id
    FOR UPDATE;

    IF v_world IS NULL THEN RETURN '[]'::jsonb; END IF;

    FOR v_sleep IN
        SELECT s.*,c.character_name,c.current_hp,c.max_hp
        FROM public.discord_character_sleep_sessions s
        JOIN public.discord_characters c ON c.character_id=s.character_id
        WHERE s.campaign_id=p_campaign_id AND s.status='sleeping'
        ORDER BY s.started_world_minute,s.created_at
        FOR UPDATE OF s,c
    LOOP
        v_elapsed := LEAST(480,GREATEST(0,v_world-v_sleep.started_world_minute));
        v_exact := CASE WHEN v_sleep.missing_hp<=0 THEN 0
                        ELSE (v_sleep.missing_hp::NUMERIC * v_elapsed::NUMERIC / 480.0) END;
        v_target_hp := LEAST(v_sleep.starting_max_hp,
                             GREATEST(v_sleep.starting_hp,v_sleep.starting_hp + FLOOR(v_exact)::INTEGER));

        UPDATE public.discord_characters c
        SET current_hp=GREATEST(c.current_hp,v_target_hp),
            character_data=jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{current_hp}',to_jsonb(GREATEST(c.current_hp,v_target_hp)),TRUE),
            updated_at=NOW()
        WHERE c.character_id=v_sleep.character_id;

        IF v_elapsed>=480 THEN
            BEGIN
                v_complete := public.discord_gm_complete_long_rest(
                    p_campaign_id,
                    v_sleep.character_name,
                    'Completed 8-hour Long Rest: ' || COALESCE(NULLIF(v_sleep.reason,''),v_sleep.location_description,'Rest'));

                UPDATE public.discord_character_sleep_sessions s
                SET status='completed',ended_world_minute=v_world,completion_result=COALESCE(v_complete,'{}'::jsonb),updated_at=NOW()
                WHERE s.sleep_session_id=v_sleep.sleep_session_id;
            EXCEPTION WHEN OTHERS THEN
                UPDATE public.discord_character_sleep_sessions s
                SET status='interrupted',ended_world_minute=v_world,
                    reason=LEFT(COALESCE(NULLIF(s.reason,''),'Long Rest') || ' | Interrupted: ' || SQLERRM,500),updated_at=NOW()
                WHERE s.sleep_session_id=v_sleep.sleep_session_id;
                v_complete := jsonb_build_object('error',SQLERRM);
            END;
        ELSE
            v_complete := '{}'::jsonb;
        END IF;

        v_results := v_results || jsonb_build_array(jsonb_build_object(
            'characterId',v_sleep.character_id,
            'characterName',v_sleep.character_name,
            'status',CASE WHEN v_elapsed>=480 THEN 'completed' ELSE 'sleeping' END,
            'elapsedMinutes',v_elapsed,
            'hpRecoveryExact',ROUND(v_exact,2),
            'hpTarget',v_target_hp,
            'completion',v_complete));
    END LOOP;

    RETURN v_results;
END;
$$;

-- -----------------------------------------------------------------
-- Set weather explicitly when story events require it.
-- Also keeps Build 6.8 hot-weather survival requirements in sync.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_set_world_weather(UUID,TEXT,TEXT,BOOLEAN,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_set_world_weather(
    p_campaign_id UUID,
    p_weather_key TEXT,
    p_weather_label TEXT,
    p_hot_weather BOOLEAN,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    INSERT INTO public.discord_campaign_world_time(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

    UPDATE public.discord_campaign_world_time w
    SET weather_key=LEFT(LOWER(TRIM(COALESCE(NULLIF(p_weather_key,''),'clear'))),60),
        weather_label=LEFT(TRIM(COALESCE(NULLIF(p_weather_label,''),'Clear')),120),
        hot_weather=COALESCE(p_hot_weather,FALSE),
        weather_reason=LEFT(TRIM(COALESCE(p_reason,'')),240),
        updated_at=NOW()
    WHERE w.campaign_id=p_campaign_id;

    PERFORM public.discord_gm_set_survival_hot_weather(
        p_campaign_id,COALESCE(p_hot_weather,FALSE),LEFT(TRIM(COALESCE(p_reason,'')),200));

    RETURN public.discord_build_world_time_state(p_campaign_id);
END;
$$;

-- -----------------------------------------------------------------
-- Advance the shared campaign clock. All living characters experience the same
-- elapsed world time; survival state and sleeping HP recovery advance together.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_advance_world_time(UUID,NUMERIC,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_advance_world_time(
    p_campaign_id UUID,
    p_hours NUMERIC,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_hours NUMERIC := ROUND(COALESCE(p_hours,0),2);
    v_minutes BIGINT;
    v_before BIGINT;
    v_after BIGINT;
    v_old_segment BIGINT;
    v_new_segment BIGINT;
    v_location TEXT;
    v_weather JSONB;
    v_names TEXT[];
    v_survival JSONB := '{}'::jsonb;
    v_sleep JSONB := '[]'::jsonb;
BEGIN
    IF v_hours<=0 OR v_hours>168 THEN
        RAISE EXCEPTION 'World time must advance between 0 and 168 hours.';
    END IF;

    v_minutes := GREATEST(1,ROUND(v_hours*60.0)::BIGINT);

    INSERT INTO public.discord_campaign_world_time(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

    SELECT w.world_minute INTO v_before
    FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id
    FOR UPDATE;

    v_after := v_before + v_minutes;
    v_old_segment := FLOOR(v_before/360.0)::BIGINT;
    v_new_segment := FLOOR(v_after/360.0)::BIGINT;

    UPDATE public.discord_campaign_world_time w
    SET world_minute=v_after,updated_at=NOW()
    WHERE w.campaign_id=p_campaign_id;

    SELECT ARRAY_AGG(c.character_name ORDER BY c.character_name)
    INTO v_names
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND COALESCE(c.life_state,'alive')='alive';

    IF COALESCE(array_length(v_names,1),0)>0 THEN
        v_survival := public.discord_gm_advance_survival_time(
            p_campaign_id,v_names,v_hours,LEFT(TRIM(COALESCE(p_reason,'World time passed')),200));
    END IF;

    IF v_new_segment<>v_old_segment THEN
        SELECT COALESCE(c.current_location,'') INTO v_location
        FROM public.discord_campaigns c WHERE c.campaign_id=p_campaign_id;
        v_weather := public.discord_build6_16_weather(v_location,p_campaign_id,v_new_segment);

        UPDATE public.discord_campaign_world_time w
        SET weather_key=COALESCE(v_weather->>'weatherKey',w.weather_key),
            weather_label=COALESCE(v_weather->>'weatherLabel',w.weather_label),
            hot_weather=COALESCE((v_weather->>'hotWeather')::BOOLEAN,FALSE),
            weather_reason='Weather changed naturally as world time advanced.',
            weather_segment=v_new_segment,
            updated_at=NOW()
        WHERE w.campaign_id=p_campaign_id;

        PERFORM public.discord_gm_set_survival_hot_weather(
            p_campaign_id,COALESCE((v_weather->>'hotWeather')::BOOLEAN,FALSE),'Build 6.16 world weather');
    END IF;

    v_sleep := public.discord_apply_sleep_progress(p_campaign_id);

    RETURN jsonb_build_object(
        'success',TRUE,
        'hoursAdvanced',ROUND(v_minutes/60.0,2),
        'minutesAdvanced',v_minutes,
        'reason',LEFT(TRIM(COALESCE(p_reason,'')),240),
        'world',public.discord_build_world_time_state(p_campaign_id),
        'survival',v_survival,
        'sleepProgress',v_sleep);
END;
$$;

-- -----------------------------------------------------------------
-- If every CURRENTLY ACTIVE living campaign player is asleep, fast-forward to
-- the latest target among those active sleepers so each receives a full 8 hours.
-- Offline players never block the active party from sleeping.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_maybe_fast_forward_all_sleeping(UUID);
CREATE OR REPLACE FUNCTION public.discord_maybe_fast_forward_all_sleeping(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_active INTEGER:=0;
    v_sleeping INTEGER:=0;
    v_world BIGINT;
    v_target BIGINT;
    v_hours NUMERIC;
BEGIN
    SELECT COUNT(*)::INTEGER INTO v_active
    FROM public.discord_characters c
    JOIN public.discord_campaign_members cm ON cm.campaign_id=c.campaign_id AND cm.player_id=c.player_id
    JOIN public.discord_campaign_presence pr ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE c.campaign_id=p_campaign_id
      AND COALESCE(c.life_state,'alive')='alive'
      AND pr.last_seen_at>=NOW()-INTERVAL '15 seconds';

    IF v_active<=0 THEN RETURN jsonb_build_object('fastForwarded',FALSE,'reason','No active living players.'); END IF;

    SELECT COUNT(*)::INTEGER,MAX(s.target_world_minute)
    INTO v_sleeping,v_target
    FROM public.discord_character_sleep_sessions s
    JOIN public.discord_characters c ON c.character_id=s.character_id
    JOIN public.discord_campaign_presence pr ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE s.campaign_id=p_campaign_id AND s.status='sleeping'
      AND COALESCE(c.life_state,'alive')='alive'
      AND pr.last_seen_at>=NOW()-INTERVAL '15 seconds';

    IF v_sleeping<v_active OR v_target IS NULL THEN
        RETURN jsonb_build_object('fastForwarded',FALSE,'activeLivingPlayers',v_active,'sleepingActivePlayers',v_sleeping);
    END IF;

    SELECT w.world_minute INTO v_world FROM public.discord_campaign_world_time w WHERE w.campaign_id=p_campaign_id;
    IF v_target<=v_world THEN
        PERFORM public.discord_apply_sleep_progress(p_campaign_id);
        RETURN jsonb_build_object('fastForwarded',FALSE,'activeLivingPlayers',v_active,'sleepingActivePlayers',v_sleeping);
    END IF;

    v_hours := ROUND((v_target-v_world)/60.0,2);
    RETURN jsonb_build_object(
        'fastForwarded',TRUE,
        'activeLivingPlayers',v_active,
        'sleepingActivePlayers',v_sleeping,
        'advance',public.discord_gm_advance_world_time(p_campaign_id,v_hours,'All active party members sleep through the Long Rest.'));
END;
$$;

-- -----------------------------------------------------------------
-- Start one character's Long Rest. Paid lodging at their CURRENT Inn is detected
-- server-side and consumes one remaining lodging day exactly once.
-- p_safe_location allows the GM to mark other legitimate safe shelters.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_start_long_rest(UUID,TEXT,BOOLEAN,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_start_long_rest(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_safe_location BOOLEAN,
    p_location_description TEXT,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_char public.discord_characters%ROWTYPE;
    v_world BIGINT;
    v_booking public.discord_inn_lodging_bookings%ROWTYPE;
    v_location RECORD;
    v_safe BOOLEAN:=COALESCE(p_safe_location,FALSE);
    v_paid BOOLEAN:=FALSE;
    v_session UUID;
    v_fast JSONB;
    v_current_night INTEGER;
BEGIN
    INSERT INTO public.discord_campaign_world_time(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

    SELECT * INTO v_char
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND LOWER(c.character_name)=LOWER(TRIM(COALESCE(p_character_name,'')))
    LIMIT 1 FOR UPDATE;

    IF v_char.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF COALESCE(v_char.life_state,'alive')<>'alive' THEN RAISE EXCEPTION '% cannot sleep while dead.',v_char.character_name; END IF;
    IF COALESCE(v_char.current_hp,0)<1 THEN RAISE EXCEPTION '% must have at least 1 HP to begin a Long Rest.',v_char.character_name; END IF;
    IF EXISTS(SELECT 1 FROM public.discord_character_sleep_sessions s WHERE s.character_id=v_char.character_id AND s.status='sleeping') THEN
        RAISE EXCEPTION '% is already sleeping.',v_char.character_name;
    END IF;

    SELECT w.world_minute INTO v_world
    FROM public.discord_campaign_world_time w WHERE w.campaign_id=p_campaign_id FOR UPDATE;
    v_current_night:=public.discord_lodging_night_index(v_world);

    SELECT l.settlement_key,l.poi_key INTO v_location
    FROM public.discord_player_settlement_locations l
    WHERE l.campaign_id=p_campaign_id AND l.player_id=v_char.player_id
    LIMIT 1;

    IF v_location.poi_key IS NOT NULL THEN
        SELECT * INTO v_booking
        FROM public.discord_inn_lodging_bookings b
        WHERE b.character_id=v_char.character_id
          AND b.campaign_id=p_campaign_id
          AND b.days_remaining>0
          AND v_current_night BETWEEN COALESCE(b.check_in_night,v_current_night) AND COALESCE(b.paid_through_night,v_current_night)
          AND COALESCE(b.last_used_night,-2147483648)<>v_current_night
          AND LOWER(b.settlement_key)=LOWER(COALESCE(v_location.settlement_key,''))
          AND LOWER(b.poi_key)=LOWER(COALESCE(v_location.poi_key,''))
        ORDER BY b.created_at
        LIMIT 1 FOR UPDATE;
    END IF;

    IF v_booking.booking_id IS NOT NULL THEN
        UPDATE public.discord_inn_lodging_bookings b
        SET days_remaining=GREATEST(0,b.days_remaining-1),last_used_night=v_current_night,updated_at=NOW()
        WHERE b.booking_id=v_booking.booking_id;
        v_safe:=TRUE;
        v_paid:=TRUE;
    END IF;

    INSERT INTO public.discord_character_sleep_sessions(
        campaign_id,character_id,player_id,status,started_world_minute,target_world_minute,
        starting_hp,starting_max_hp,missing_hp,safe_location,paid_lodging,lodging_booking_id,
        inn_name,lifestyle,location_description,reason)
    VALUES(
        p_campaign_id,v_char.character_id,v_char.player_id,'sleeping',v_world,v_world+480,
        GREATEST(0,v_char.current_hp),GREATEST(1,v_char.max_hp),GREATEST(0,v_char.max_hp-v_char.current_hp),
        v_safe,v_paid,v_booking.booking_id,
        CASE WHEN v_paid THEN COALESCE(v_booking.inn_name,'') ELSE '' END,
        CASE WHEN v_paid THEN COALESCE(v_booking.lifestyle,'') ELSE '' END,
        LEFT(TRIM(COALESCE(p_location_description,'')),240),LEFT(TRIM(COALESCE(p_reason,'')),500))
    RETURNING sleep_session_id INTO v_session;

    v_fast:=public.discord_maybe_fast_forward_all_sleeping(p_campaign_id);

    RETURN jsonb_build_object(
        'success',TRUE,'sleepSessionId',v_session,'characterId',v_char.character_id,'characterName',v_char.character_name,
        'status','sleeping','startedWorldMinute',v_world,'targetWorldMinute',v_world+480,
        'startingHp',v_char.current_hp,'maxHp',v_char.max_hp,'missingHp',GREATEST(0,v_char.max_hp-v_char.current_hp),
        'hpPerHour',ROUND(GREATEST(0,v_char.max_hp-v_char.current_hp)/8.0,2),
        'safeLocation',v_safe,'paidLodging',v_paid,'innName',CASE WHEN v_paid THEN v_booking.inn_name ELSE '' END,
        'lifestyle',CASE WHEN v_paid THEN v_booking.lifestyle ELSE '' END,'fastForward',v_fast,
        'world',public.discord_build_world_time_state(p_campaign_id));
END;
$$;

-- Player-facing world state.
DROP FUNCTION IF EXISTS public.discord_get_world_time_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_world_time_state(p_player_id UUID,p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members cm WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;
    INSERT INTO public.discord_campaign_world_time(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;
    PERFORM public.discord_apply_sleep_progress(p_campaign_id);
    RETURN public.discord_build_world_time_state(p_campaign_id);
END;
$$;

-- GM-facing world state.
DROP FUNCTION IF EXISTS public.discord_gm_get_world_time_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_world_time_state(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    INSERT INTO public.discord_campaign_world_time(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;
    PERFORM public.discord_apply_sleep_progress(p_campaign_id);
    RETURN public.discord_build_world_time_state(p_campaign_id);
END;
$$;

-- Sleeping window state for the current player.
DROP FUNCTION IF EXISTS public.discord_get_sleep_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_sleep_state(p_player_id UUID,p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_char public.discord_characters%ROWTYPE;
    v_sleep public.discord_character_sleep_sessions%ROWTYPE;
    v_world BIGINT;
    v_elapsed BIGINT;
    v_exact NUMERIC(14,4);
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members cm WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    PERFORM public.discord_apply_sleep_progress(p_campaign_id);

    SELECT * INTO v_char FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_char.character_id IS NULL THEN RETURN jsonb_build_object('sleeping',FALSE); END IF;

    SELECT * INTO v_sleep FROM public.discord_character_sleep_sessions s
    WHERE s.character_id=v_char.character_id AND s.campaign_id=p_campaign_id AND s.status='sleeping'
    ORDER BY s.created_at DESC LIMIT 1;
    IF v_sleep.sleep_session_id IS NULL THEN RETURN jsonb_build_object('sleeping',FALSE); END IF;

    SELECT w.world_minute INTO v_world FROM public.discord_campaign_world_time w WHERE w.campaign_id=p_campaign_id;
    v_elapsed:=LEAST(480,GREATEST(0,v_world-v_sleep.started_world_minute));
    v_exact:=CASE WHEN v_sleep.missing_hp<=0 THEN 0 ELSE v_sleep.missing_hp::NUMERIC*v_elapsed::NUMERIC/480.0 END;

    SELECT * INTO v_char FROM public.discord_characters c WHERE c.character_id=v_sleep.character_id;

    RETURN jsonb_build_object(
        'sleeping',TRUE,'sleepSessionId',v_sleep.sleep_session_id,'characterId',v_char.character_id,'characterName',v_char.character_name,
        'status',v_sleep.status,'world',public.discord_build_world_time_state(p_campaign_id),
        'startedWorldMinute',v_sleep.started_world_minute,'targetWorldMinute',v_sleep.target_world_minute,
        'elapsedMinutes',v_elapsed,'remainingMinutes',GREATEST(0,480-v_elapsed),
        'elapsedHours',ROUND(v_elapsed/60.0,2),'remainingHours',ROUND(GREATEST(0,480-v_elapsed)/60.0,2),
        'startingHp',v_sleep.starting_hp,'currentHp',v_char.current_hp,'maxHp',v_char.max_hp,'missingHpAtStart',v_sleep.missing_hp,
        'hpPerHour',ROUND(v_sleep.missing_hp/8.0,2),'hpRecoveryExact',ROUND(v_exact,2),
        'safeLocation',v_sleep.safe_location,'paidLodging',v_sleep.paid_lodging,'innName',v_sleep.inn_name,'lifestyle',v_sleep.lifestyle,
        'locationDescription',v_sleep.location_description,'reason',v_sleep.reason);
END;
$$;

-- Wake early. Recovered HP stays; Long-Rest resources are not restored.
DROP FUNCTION IF EXISTS public.discord_wake_from_long_rest(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_wake_from_long_rest(p_player_id UUID,p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_char public.discord_characters%ROWTYPE;
    v_sleep public.discord_character_sleep_sessions%ROWTYPE;
    v_world BIGINT;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members cm WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    PERFORM public.discord_apply_sleep_progress(p_campaign_id);

    SELECT * INTO v_char FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_char.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT * INTO v_sleep FROM public.discord_character_sleep_sessions s
    WHERE s.character_id=v_char.character_id AND s.campaign_id=p_campaign_id AND s.status='sleeping'
    ORDER BY s.created_at DESC LIMIT 1 FOR UPDATE;
    IF v_sleep.sleep_session_id IS NULL THEN
        RETURN jsonb_build_object('success',TRUE,'sleeping',FALSE,'message','You are already awake.');
    END IF;

    SELECT w.world_minute INTO v_world FROM public.discord_campaign_world_time w WHERE w.campaign_id=p_campaign_id;
    UPDATE public.discord_character_sleep_sessions s
    SET status='woke_early',ended_world_minute=v_world,updated_at=NOW()
    WHERE s.sleep_session_id=v_sleep.sleep_session_id;

    SELECT * INTO v_char FROM public.discord_characters c WHERE c.character_id=v_char.character_id;

    RETURN jsonb_build_object(
        'success',TRUE,'sleeping',FALSE,'wokeEarly',TRUE,'characterName',v_char.character_name,
        'currentHp',v_char.current_hp,'maxHp',v_char.max_hp,'world',public.discord_build_world_time_state(p_campaign_id),
        'message',v_char.character_name || ' wakes before completing the 8-hour Long Rest.');
END;
$$;

-- -----------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------
REVOKE ALL ON FUNCTION public.discord_lodging_night_index(BIGINT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_stamp_lodging_world_nights() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_build_world_time_state(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_build6_16_weather(TEXT,UUID,BIGINT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_apply_sleep_progress(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_set_world_weather(UUID,TEXT,TEXT,BOOLEAN,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_advance_world_time(UUID,NUMERIC,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_maybe_fast_forward_all_sleeping(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_start_long_rest(UUID,TEXT,BOOLEAN,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_world_time_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_world_time_state(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_sleep_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_wake_from_long_rest(UUID,UUID) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_lodging_night_index(BIGINT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_stamp_lodging_world_nights() TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_build_world_time_state(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_build6_16_weather(TEXT,UUID,BIGINT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_apply_sleep_progress(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_world_weather(UUID,TEXT,TEXT,BOOLEAN,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_advance_world_time(UUID,NUMERIC,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_maybe_fast_forward_all_sleeping(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_start_long_rest(UUID,TEXT,BOOLEAN,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_world_time_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_world_time_state(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_sleep_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_wake_from_long_rest(UUID,UUID) TO service_role;

COMMIT;
