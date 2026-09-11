-- ============================================================
-- RabuShinAIGM Rules Build 6.21.1
-- Weather Gameplay Effects
-- Baseline source commit: 6ccee79ace3813c62be024046769b91b769ba715
-- Requires Migration 54 and Build 6.16 world weather.
-- Safe to run more than once.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_weather_gameplay_effects(
    p_weather_key TEXT,
    p_weather_label TEXT DEFAULT '',
    p_hot_weather BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_key TEXT:=LOWER(TRIM(COALESCE(NULLIF(p_weather_key,''),'clear')));
    v_label TEXT:=TRIM(COALESCE(NULLIF(p_weather_label,''),INITCAP(REPLACE(v_key,'-',' '))));
    v_travel NUMERIC:=1.00;
    v_visibility INTEGER:=0; -- 0 = no weather-imposed cap
    v_ranged_disadv INTEGER:=0; -- 0 = no weather-imposed threshold
    v_difficult BOOLEAN:=FALSE;
    v_fire_suppressed BOOLEAN:=FALSE;
    v_flying_disadv BOOLEAN:=FALSE;
    v_ship_disadv BOOLEAN:=FALSE;
    v_water_mult INTEGER:=CASE WHEN COALESCE(p_hot_weather,FALSE) THEN 2 ELSE 1 END;
    v_summary TEXT:='No significant mechanical weather penalties.';
BEGIN
    CASE v_key
        WHEN 'rain' THEN
            v_travel:=1.10; v_visibility:=180; v_ranged_disadv:=90;
            v_fire_suppressed:=TRUE;
            v_summary:='Rain reduces long-range visibility, hampers exposed ordinary flames, and slows overland travel.';
        WHEN 'fog' THEN
            v_travel:=1.15; v_visibility:=60; v_ranged_disadv:=30;
            v_summary:='Fog sharply limits sight and long-range attacks while slowing navigation.';
        WHEN 'storm' THEN
            v_travel:=1.40; v_visibility:=90; v_ranged_disadv:=60; v_difficult:=TRUE;
            v_fire_suppressed:=TRUE; v_flying_disadv:=TRUE; v_ship_disadv:=TRUE;
            v_summary:='Storm conditions reduce visibility, suppress exposed flames, slow travel, and hinder flying or ship handling.';
        WHEN 'snow' THEN
            v_travel:=1.25; v_visibility:=150; v_ranged_disadv:=90; v_difficult:=TRUE;
            v_summary:='Snow slows travel and makes exposed ground harder to cross while reducing long-range visibility.';
        WHEN 'snowstorm' THEN
            v_travel:=1.60; v_visibility:=60; v_ranged_disadv:=30; v_difficult:=TRUE;
            v_fire_suppressed:=TRUE; v_flying_disadv:=TRUE; v_ship_disadv:=TRUE;
            v_summary:='Snowstorm conditions severely restrict visibility, slow travel, suppress exposed flames, and hinder flight/ships.';
        WHEN 'sandstorm' THEN
            v_travel:=1.70; v_visibility:=30; v_ranged_disadv:=20; v_difficult:=TRUE;
            v_fire_suppressed:=TRUE; v_flying_disadv:=TRUE; v_ship_disadv:=TRUE;
            v_summary:='Sandstorm conditions make navigation extremely slow, visibility very short, and airborne or ship control hazardous.';
        WHEN 'dry-wind' THEN
            v_travel:=1.08; v_visibility:=180; v_ranged_disadv:=120;
            v_flying_disadv:=TRUE; v_ship_disadv:=TRUE;
            v_summary:='Strong dry wind modestly slows travel and can hinder flight, sails, and very long ranged attacks.';
        WHEN 'ash-haze' THEN
            v_travel:=1.15; v_visibility:=90; v_ranged_disadv:=60;
            v_summary:='Ash haze limits sight and long-range attacks and slows careful travel.';
        WHEN 'haze' THEN
            v_travel:=1.15; v_visibility:=120; v_ranged_disadv:=90;
            v_summary:='Heat haze reduces distant visibility and makes navigation slightly slower.';
        WHEN 'overcast' THEN
            v_summary:='Overcast skies have no major direct mechanical penalty.';
        WHEN 'cloudy' THEN
            v_summary:='Cloud cover has no major direct mechanical penalty.';
        WHEN 'hot-clear' THEN
            v_summary:='Extreme heat doubles the daily water requirement while otherwise leaving visibility clear.';
        WHEN 'warm-clear' THEN
            v_summary:='Warm clear weather has no major direct mechanical penalty.';
        WHEN 'cold-clear' THEN
            v_summary:='Cold clear weather has no major direct visibility or travel penalty by itself.';
        ELSE
            v_summary:='No significant mechanical weather penalties.';
    END CASE;

    IF COALESCE(p_hot_weather,FALSE) THEN
        IF v_summary NOT LIKE '%water requirement%' THEN
            v_summary:=v_summary || ' Hot-weather survival doubles the daily water requirement.';
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'weatherKey',v_key,
        'weatherLabel',v_label,
        'travelMultiplier',v_travel,
        'visibilityFeet',v_visibility,
        'rangedDisadvantageBeyondFeet',v_ranged_disadv,
        'difficultTravel',v_difficult,
        'exposedOrdinaryFireSuppressed',v_fire_suppressed,
        'flyingControlChecksDisadvantage',v_flying_disadv,
        'shipHandlingChecksDisadvantage',v_ship_disadv,
        'waterRequirementMultiplier',v_water_mult,
        'summary',v_summary);
END;
$$;

-- Replace the Build 6.21 helper so all existing dynamic travel-plan callers
-- immediately consume the full Build 6.21.1 weather profile.
CREATE OR REPLACE FUNCTION public.discord_weather_travel_multiplier(p_weather_key TEXT)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT COALESCE((public.discord_weather_gameplay_effects(p_weather_key,'',FALSE)->>'travelMultiplier')::NUMERIC,1.0);
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_weather_gameplay_effects(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_weather_gameplay_effects(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_world public.discord_campaign_world_time%ROWTYPE;
    v_effects JSONB;
BEGIN
    SELECT * INTO v_world FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id;
    IF v_world.campaign_id IS NULL THEN
        RETURN jsonb_build_object('available',FALSE);
    END IF;

    v_effects:=public.discord_weather_gameplay_effects(
        v_world.weather_key,v_world.weather_label,v_world.hot_weather);

    RETURN jsonb_build_object(
        'available',TRUE,
        'world',public.discord_build_world_time_state(p_campaign_id),
        'effects',v_effects);
END;
$$;

REVOKE ALL ON FUNCTION public.discord_weather_gameplay_effects(TEXT,TEXT,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_weather_travel_multiplier(TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_weather_gameplay_effects(UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_weather_gameplay_effects(UUID) TO service_role;

COMMIT;
