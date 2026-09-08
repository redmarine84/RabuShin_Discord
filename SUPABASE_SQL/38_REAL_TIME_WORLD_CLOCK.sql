-- ============================================================
-- RabuShinAIGM Rules Build 6.18
-- Real-Time World Clock + Pause + Weather/Day-Night Synchronization
-- Requires Build 6.17 / migration 37 and Build 6.16 / migration 36.
-- Safe to run more than once.
--
-- Desktop parity:
--   1 game minute = 2.5 real seconds (24x real-time)
--   Automatic time advances only while at least one active living party
--   character is awake. If all currently active living characters sleep,
--   the existing Build 6.16 Long Rest fast-forward is used. Offline party
--   members do not block sleeping. No time catches up while nobody plays.
-- ============================================================

BEGIN;

ALTER TABLE public.discord_campaign_world_time
    ADD COLUMN IF NOT EXISTS auto_clock_paused BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS auto_clock_anchor_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS auto_clock_remainder_seconds NUMERIC(12,6) NOT NULL DEFAULT 0;

UPDATE public.discord_campaign_world_time
SET auto_clock_anchor_at=COALESCE(auto_clock_anchor_at,NOW()),
    auto_clock_remainder_seconds=GREATEST(0,LEAST(2.499999,COALESCE(auto_clock_remainder_seconds,0)));

-- -----------------------------------------------------------------
-- Build a compact world-state JSON object from the authoritative clock.
-- Build 6.18 adds real-time clock metadata while retaining the Build 6.16
-- contract used by the client and AI GM.
-- -----------------------------------------------------------------
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
    v_active INTEGER:=0;
    v_sleeping INTEGER:=0;
    v_awake INTEGER:=0;
    v_running BOOLEAN:=FALSE;
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

    SELECT COUNT(*)::INTEGER INTO v_active
    FROM public.discord_characters c
    JOIN public.discord_campaign_members cm
      ON cm.campaign_id=c.campaign_id AND cm.player_id=c.player_id
    JOIN public.discord_campaign_presence pr
      ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE c.campaign_id=p_campaign_id
      AND COALESCE(c.life_state,'alive')='alive'
      AND pr.last_seen_at>=NOW()-INTERVAL '15 seconds';

    SELECT COUNT(*)::INTEGER INTO v_sleeping
    FROM public.discord_character_sleep_sessions s
    JOIN public.discord_characters c ON c.character_id=s.character_id
    JOIN public.discord_campaign_presence pr
      ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE s.campaign_id=p_campaign_id
      AND s.status='sleeping'
      AND COALESCE(c.life_state,'alive')='alive'
      AND pr.last_seen_at>=NOW()-INTERVAL '15 seconds';

    v_awake:=GREATEST(0,v_active-v_sleeping);
    v_running:=(NOT COALESCE(v_state.auto_clock_paused,FALSE)) AND v_active>0 AND v_awake>0;

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
        'updatedAt',v_state.updated_at,
        'autoClockPaused',COALESCE(v_state.auto_clock_paused,FALSE),
        'autoClockRunning',v_running,
        'autoClockRemainderSeconds',COALESCE(v_state.auto_clock_remainder_seconds,0),
        'autoClockAnchorAt',v_state.auto_clock_anchor_at,
        'realSecondsPerGameMinute',2.5,
        'activeLivingPlayers',v_active,
        'sleepingActivePlayers',v_sleeping,
        'awakeActivePlayers',v_awake,
        'serverNow',NOW()
    );
END;
$$;

-- -----------------------------------------------------------------
-- Minute-accurate advancement. Build 6.16 rounded every small time advance
-- to hundredths of an hour, which would drift badly at the new 24x clock.
-- This helper keeps survival, weather, and sleeping recovery synchronized to
-- the exact number of game minutes that actually elapsed.
-- -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discord_gm_advance_world_minutes(
    p_campaign_id UUID,
    p_minutes BIGINT,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_minutes BIGINT:=COALESCE(p_minutes,0);
    v_hours NUMERIC(18,8);
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
    IF v_minutes<=0 OR v_minutes>10080 THEN
        RAISE EXCEPTION 'World time must advance between 1 minute and 168 hours.';
    END IF;

    v_hours:=v_minutes::NUMERIC/60.0;

    INSERT INTO public.discord_campaign_world_time(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

    SELECT w.world_minute INTO v_before
    FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id
    FOR UPDATE;

    v_after:=v_before+v_minutes;
    v_old_segment:=FLOOR(v_before/360.0)::BIGINT;
    v_new_segment:=FLOOR(v_after/360.0)::BIGINT;

    UPDATE public.discord_campaign_world_time w
    SET world_minute=v_after,
        auto_clock_anchor_at=NOW(),
        updated_at=NOW()
    WHERE w.campaign_id=p_campaign_id;

    SELECT ARRAY_AGG(c.character_name ORDER BY c.character_name)
    INTO v_names
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND COALESCE(c.life_state,'alive')='alive';

    IF COALESCE(array_length(v_names,1),0)>0 THEN
        v_survival:=public.discord_gm_advance_survival_time(
            p_campaign_id,v_names,v_hours,LEFT(TRIM(COALESCE(p_reason,'World time passed')),200));
    END IF;

    IF v_new_segment<>v_old_segment THEN
        SELECT COALESCE(c.current_location,'') INTO v_location
        FROM public.discord_campaigns c WHERE c.campaign_id=p_campaign_id;
        v_weather:=public.discord_build6_16_weather(v_location,p_campaign_id,v_new_segment);

        UPDATE public.discord_campaign_world_time w
        SET weather_key=COALESCE(v_weather->>'weatherKey',w.weather_key),
            weather_label=COALESCE(v_weather->>'weatherLabel',w.weather_label),
            hot_weather=COALESCE((v_weather->>'hotWeather')::BOOLEAN,FALSE),
            weather_reason='Weather changed naturally as world time advanced.',
            weather_segment=v_new_segment,
            updated_at=NOW()
        WHERE w.campaign_id=p_campaign_id;

        PERFORM public.discord_gm_set_survival_hot_weather(
            p_campaign_id,COALESCE((v_weather->>'hotWeather')::BOOLEAN,FALSE),'Build 6.18 real-time world weather');
    END IF;

    v_sleep:=public.discord_apply_sleep_progress(p_campaign_id);

    RETURN jsonb_build_object(
        'success',TRUE,
        'hoursAdvanced',ROUND(v_hours,2),
        'minutesAdvanced',v_minutes,
        'reason',LEFT(TRIM(COALESCE(p_reason,'')),240),
        'world',public.discord_build_world_time_state(p_campaign_id),
        'survival',v_survival,
        'sleepProgress',v_sleep);
END;
$$;

-- Preserve every existing Build 6.16 caller while routing through the exact
-- minute helper above.
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
    v_hours NUMERIC:=COALESCE(p_hours,0);
    v_minutes BIGINT;
BEGIN
    IF v_hours<=0 OR v_hours>168 THEN
        RAISE EXCEPTION 'World time must advance between 0 and 168 hours.';
    END IF;
    v_minutes:=GREATEST(1,ROUND(v_hours*60.0)::BIGINT);
    RETURN public.discord_gm_advance_world_minutes(p_campaign_id,v_minutes,p_reason);
END;
$$;

-- -----------------------------------------------------------------
-- Reconcile measured REAL elapsed time into authoritative game minutes.
-- This mirrors Desktop Build 6.18.4: 2.5 real sec = 1 game minute.
-- Presence is evaluated BEFORE a returning player's presence is refreshed,
-- so an empty campaign never catches up hours of offline time.
-- -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discord_reconcile_real_time_world(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_state public.discord_campaign_world_time%ROWTYPE;
    v_now TIMESTAMPTZ:=clock_timestamp();
    v_active INTEGER:=0;
    v_sleeping INTEGER:=0;
    v_awake INTEGER:=0;
    v_elapsed NUMERIC(18,6):=0;
    v_total NUMERIC(18,6):=0;
    v_minutes BIGINT:=0;
    v_remainder NUMERIC(12,6):=0;
    v_advance JSONB;
    v_fast JSONB;
BEGIN
    INSERT INTO public.discord_campaign_world_time(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;

    SELECT * INTO v_state
    FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id
    FOR UPDATE;

    SELECT COUNT(*)::INTEGER INTO v_active
    FROM public.discord_characters c
    JOIN public.discord_campaign_members cm
      ON cm.campaign_id=c.campaign_id AND cm.player_id=c.player_id
    JOIN public.discord_campaign_presence pr
      ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE c.campaign_id=p_campaign_id
      AND COALESCE(c.life_state,'alive')='alive'
      AND pr.last_seen_at>=v_now-INTERVAL '15 seconds';

    SELECT COUNT(*)::INTEGER INTO v_sleeping
    FROM public.discord_character_sleep_sessions s
    JOIN public.discord_characters c ON c.character_id=s.character_id
    JOIN public.discord_campaign_presence pr
      ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE s.campaign_id=p_campaign_id
      AND s.status='sleeping'
      AND COALESCE(c.life_state,'alive')='alive'
      AND pr.last_seen_at>=v_now-INTERVAL '15 seconds';

    v_awake:=GREATEST(0,v_active-v_sleeping);

    -- Owner Pause freezes automatic progression only. Fractional progress is
    -- retained, just like the desktop accumulator.
    IF COALESCE(v_state.auto_clock_paused,FALSE) THEN
        UPDATE public.discord_campaign_world_time
        SET auto_clock_anchor_at=v_now
        WHERE campaign_id=p_campaign_id;
        RETURN public.discord_build_world_time_state(p_campaign_id);
    END IF;

    -- Nobody was actively playing before this request. Reset the real-time
    -- anchor and fraction; never convert offline time into campaign time.
    IF v_active<=0 THEN
        UPDATE public.discord_campaign_world_time
        SET auto_clock_anchor_at=v_now,
            auto_clock_remainder_seconds=0
        WHERE campaign_id=p_campaign_id;
        RETURN public.discord_build_world_time_state(p_campaign_id);
    END IF;

    -- Existing Build 6.16 behavior: all currently active living characters
    -- sleeping means fast-forward the Long Rest. Offline characters do not block.
    IF v_awake<=0 AND v_sleeping>=v_active THEN
        UPDATE public.discord_campaign_world_time
        SET auto_clock_anchor_at=v_now,
            auto_clock_remainder_seconds=0
        WHERE campaign_id=p_campaign_id;
        v_fast:=public.discord_maybe_fast_forward_all_sleeping(p_campaign_id);
        RETURN public.discord_build_world_time_state(p_campaign_id);
    END IF;

    v_elapsed:=GREATEST(0,EXTRACT(EPOCH FROM (v_now-v_state.auto_clock_anchor_at))::NUMERIC);
    v_total:=COALESCE(v_state.auto_clock_remainder_seconds,0)+v_elapsed;
    v_minutes:=FLOOR(v_total/2.5)::BIGINT;
    v_remainder:=v_total-(v_minutes::NUMERIC*2.5);

    UPDATE public.discord_campaign_world_time
    SET auto_clock_anchor_at=v_now,
        auto_clock_remainder_seconds=GREATEST(0,LEAST(2.499999,v_remainder))
    WHERE campaign_id=p_campaign_id;

    IF v_minutes>0 THEN
        v_advance:=public.discord_gm_advance_world_minutes(
            p_campaign_id,
            LEAST(v_minutes,10080),
            'Real-time world clock (24x).');
    ELSE
        PERFORM public.discord_apply_sleep_progress(p_campaign_id);
    END IF;

    RETURN public.discord_build_world_time_state(p_campaign_id);
END;
$$;

-- -----------------------------------------------------------------
-- Owner-only Pause / Resume for the automatic clock. Manual GM time changes,
-- travel, Short Rest, and Long Rest remain allowed while paused.
-- -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discord_set_world_clock_paused(
    p_player_id UUID,
    p_campaign_id UUID,
    p_paused BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id
          AND c.owner_player_id=p_player_id
          AND c.is_active=TRUE
    ) THEN
        RAISE EXCEPTION 'Only the campaign owner can pause or resume world time.';
    END IF;

    PERFORM public.discord_reconcile_real_time_world(p_campaign_id);

    UPDATE public.discord_campaign_world_time w
    SET auto_clock_paused=COALESCE(p_paused,FALSE),
        auto_clock_anchor_at=clock_timestamp(),
        updated_at=NOW()
    WHERE w.campaign_id=p_campaign_id;

    RETURN public.discord_build_world_time_state(p_campaign_id);
END;
$$;

-- -----------------------------------------------------------------
-- Presence update with PRE-TOUCH reconciliation. This is what prevents the
-- first request after an idle/offline period from turning that offline gap into
-- game time. Build 6.17 Solo presence mirroring is preserved exactly.
-- -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discord_touch_campaign_presence(
    p_player_id UUID,
    p_campaign_id UUID
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_seen TIMESTAMPTZ := NOW();
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;

    PERFORM public.discord_reconcile_real_time_world(p_campaign_id);

    INSERT INTO public.discord_campaign_presence(campaign_id,player_id,last_seen_at)
    VALUES(p_campaign_id,p_player_id,v_seen)
    ON CONFLICT (campaign_id,player_id) DO UPDATE SET last_seen_at=EXCLUDED.last_seen_at;

    IF EXISTS(
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo'
    ) THEN
        PERFORM public.discord_solo_ensure_primary(p_player_id,p_campaign_id);
        INSERT INTO public.discord_campaign_presence(campaign_id,player_id,last_seen_at)
        SELECT p_campaign_id,sp.control_player_id,v_seen
        FROM public.discord_solo_party_characters sp
        WHERE sp.campaign_id=p_campaign_id AND sp.owner_player_id=p_player_id
        ON CONFLICT (campaign_id,player_id) DO UPDATE SET last_seen_at=EXCLUDED.last_seen_at;
    END IF;

    RETURN v_seen;
END;
$$;

-- Player-facing world state also reconciles defensively in case a caller does
-- not use the normal Program.cs presence path.
CREATE OR REPLACE FUNCTION public.discord_get_world_time_state(p_player_id UUID,p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;

    INSERT INTO public.discord_campaign_world_time(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;
    PERFORM public.discord_reconcile_real_time_world(p_campaign_id);
    RETURN public.discord_build_world_time_state(p_campaign_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_get_world_time_state(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    INSERT INTO public.discord_campaign_world_time(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;
    PERFORM public.discord_reconcile_real_time_world(p_campaign_id);
    RETURN public.discord_build_world_time_state(p_campaign_id);
END;
$$;

REVOKE ALL ON FUNCTION public.discord_gm_advance_world_minutes(UUID,BIGINT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_reconcile_real_time_world(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_set_world_clock_paused(UUID,UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_gm_advance_world_minutes(UUID,BIGINT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_reconcile_real_time_world(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_world_clock_paused(UUID,UUID,BOOLEAN) TO service_role;

COMMIT;
