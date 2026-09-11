-- ============================================================
-- RabuShinAIGM Rules Build 6.21
-- Dynamic Random Encounters / Authoritative Travel Plans
-- Baseline source commit: 6ccee79ace3813c62be024046769b91b769ba715
-- Requires world map discovery + Build 6.16 world clock/weather.
-- Safe to run more than once.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_dynamic_travel_plans
(
    travel_plan_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    origin_key TEXT NOT NULL,
    origin_name TEXT NOT NULL,
    destination_key TEXT NOT NULL,
    destination_name TEXT NOT NULL,
    terrain_key TEXT NOT NULL,
    route_miles NUMERIC(8,2) NOT NULL CHECK (route_miles > 0),
    progress_percent INTEGER NOT NULL CHECK (progress_percent BETWEEN 0 AND 100),
    nearest_settlement_miles NUMERIC(8,2) NOT NULL CHECK (nearest_settlement_miles >= 0),
    party_average_level NUMERIC(6,2) NOT NULL DEFAULT 1,
    party_size INTEGER NOT NULL DEFAULT 1 CHECK (party_size >= 0),
    start_world_minute BIGINT NOT NULL,
    encounter_world_minute BIGINT NOT NULL,
    arrival_world_minute BIGINT NOT NULL,
    initial_weather_key TEXT NOT NULL DEFAULT 'clear',
    initial_weather_label TEXT NOT NULL DEFAULT 'Clear',
    initial_weather_multiplier NUMERIC(6,3) NOT NULL DEFAULT 1.0,
    day_part TEXT NOT NULL DEFAULT '',
    daylight BOOLEAN NOT NULL DEFAULT TRUE,
    encounter_chance INTEGER NOT NULL CHECK (encounter_chance BETWEEN 0 AND 100),
    encounter_roll INTEGER NOT NULL CHECK (encounter_roll BETWEEN 1 AND 100),
    encounter_triggered BOOLEAN NOT NULL DEFAULT FALSE,
    encounter_type TEXT NOT NULL DEFAULT 'none',
    encounter_key TEXT NOT NULL DEFAULT '',
    encounter_title TEXT NOT NULL DEFAULT '',
    encounter_summary TEXT NOT NULL DEFAULT '',
    threat_tier TEXT NOT NULL DEFAULT 'Low',
    status TEXT NOT NULL DEFAULT 'traveling'
        CHECK (status IN ('traveling','encounter_pending','encounter_resolved','ready','arrived','cancelled')),
    encounter_outcome TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ NULL,
    arrived_at TIMESTAMPTZ NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_dynamic_travel_one_open
ON public.discord_dynamic_travel_plans(campaign_id)
WHERE status IN ('traveling','encounter_pending','encounter_resolved','ready');

CREATE INDEX IF NOT EXISTS ix_discord_dynamic_travel_campaign_created
ON public.discord_dynamic_travel_plans(campaign_id,created_at DESC);

ALTER TABLE public.discord_dynamic_travel_plans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_dynamic_travel_plans FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.discord_dynamic_travel_plans TO service_role;

-- -----------------------------------------------------------------
-- Route terrain. The destination dominates because the latter portion of a
-- journey is normally where its regional terrain becomes most distinctive.
-- -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discord_dynamic_route_terrain(
    p_origin_key TEXT,
    p_destination_key TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_key TEXT := LOWER(TRIM(COALESCE(p_destination_key,'')));
BEGIN
    RETURN CASE v_key
        WHEN 'marrowfen' THEN 'swamp'
        WHEN 'frostharbor' THEN 'tundra_coast'
        WHEN 'sunspire' THEN 'desert'
        WHEN 'blackroot' THEN 'dense_forest'
        WHEN 'aetherfall' THEN 'arcane_highlands'
        WHEN 'stonewake' THEN 'coastal_road'
        WHEN 'emberfall' THEN 'volcanic_road'
        WHEN 'lunareth' THEN 'moonlit_forest'
        WHEN 'high_bastion' THEN 'fortified_road'
        WHEN 'silverreach' THEN 'grassland_road'
        WHEN 'duskmire' THEN 'badlands_crossroads'
        WHEN 'greymoor' THEN 'pastoral_forest'
        ELSE 'wilderness_road'
    END;
END;
$$;

-- Approximate overland miles derived from chapter distance. Adjacent campaign
-- settlements are about an 18-mile travel day at normal 3 mph pace.
CREATE OR REPLACE FUNCTION public.discord_dynamic_route_miles(
    p_origin_key TEXT,
    p_destination_key TEXT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_origin_order INTEGER;
    v_destination_order INTEGER;
BEGIN
    SELECT c.chapter_order INTO v_origin_order
    FROM public.discord_world_map_catalog() c
    WHERE c.location_key=LOWER(TRIM(COALESCE(p_origin_key,''))) LIMIT 1;

    SELECT c.chapter_order INTO v_destination_order
    FROM public.discord_world_map_catalog() c
    WHERE c.location_key=LOWER(TRIM(COALESCE(p_destination_key,''))) LIMIT 1;

    IF v_origin_order IS NULL OR v_destination_order IS NULL THEN RETURN 18.0; END IF;
    RETURN (10 + 8 * GREATEST(1,ABS(v_destination_order-v_origin_order)))::NUMERIC;
END;
$$;

-- Build 6.21 base travel multipliers. Migration 55 replaces this function with
-- the full Weather Gameplay Effects profile without changing callers.
CREATE OR REPLACE FUNCTION public.discord_weather_travel_multiplier(p_weather_key TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE v_key TEXT:=LOWER(TRIM(COALESCE(p_weather_key,'clear')));
BEGIN
    RETURN CASE
        WHEN v_key IN ('sandstorm') THEN 1.70
        WHEN v_key IN ('snowstorm') THEN 1.60
        WHEN v_key IN ('storm') THEN 1.40
        WHEN v_key IN ('snow') THEN 1.25
        WHEN v_key IN ('fog','ash-haze','haze') THEN 1.15
        WHEN v_key IN ('rain') THEN 1.10
        WHEN v_key IN ('dry-wind') THEN 1.08
        ELSE 1.00
    END;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_dynamic_encounter_chance(
    p_terrain TEXT,
    p_nearest_settlement_miles NUMERIC,
    p_weather_key TEXT,
    p_day_part TEXT,
    p_is_daylight BOOLEAN,
    p_party_average_level NUMERIC,
    p_origin_key TEXT,
    p_destination_key TEXT
)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_chance INTEGER:=18;
    v_terrain TEXT:=LOWER(TRIM(COALESCE(p_terrain,'')));
    v_weather TEXT:=LOWER(TRIM(COALESCE(p_weather_key,'')));
    v_day TEXT:=LOWER(TRIM(COALESCE(p_day_part,'')));
    v_origin TEXT:=LOWER(TRIM(COALESCE(p_origin_key,'')));
    v_destination TEXT:=LOWER(TRIM(COALESCE(p_destination_key,'')));
BEGIN
    -- Terrain risk.
    IF v_terrain='swamp' THEN v_chance:=v_chance+10;
    ELSIF v_terrain IN ('dense_forest','moonlit_forest') THEN v_chance:=v_chance+6;
    ELSIF v_terrain IN ('arcane_highlands','tundra_coast','volcanic_road') THEN v_chance:=v_chance+7;
    ELSIF v_terrain IN ('desert','badlands_crossroads') THEN v_chance:=v_chance+5;
    ELSIF v_terrain='fortified_road' THEN v_chance:=v_chance-5;
    END IF;

    -- Distance from the safety and traffic of settlements.
    IF COALESCE(p_nearest_settlement_miles,0)>=7 THEN v_chance:=v_chance+12;
    ELSIF COALESCE(p_nearest_settlement_miles,0)>=4 THEN v_chance:=v_chance+7;
    ELSIF COALESCE(p_nearest_settlement_miles,0)<=1.5 THEN v_chance:=v_chance-6;
    END IF;

    -- Time of day.
    IF NOT COALESCE(p_is_daylight,TRUE) THEN v_chance:=v_chance+10; END IF;
    IF v_day='late night' THEN v_chance:=v_chance+5; END IF;

    -- Weather risk.
    IF v_weather IN ('storm','snowstorm','sandstorm') THEN v_chance:=v_chance+13;
    ELSIF v_weather IN ('fog','rain','ash-haze') THEN v_chance:=v_chance+6;
    END IF;

    -- Higher-level parties attract/seek stronger threats and can tolerate a
    -- modestly denser encounter cadence without making travel constant combat.
    v_chance:=v_chance+LEAST(8,GREATEST(0,FLOOR((COALESCE(p_party_average_level,1)-1)/3.0)::INTEGER*2));

    -- Requested contextual contrast examples.
    IF (v_origin='marrowfen' OR v_destination='marrowfen')
       AND v_weather='storm' AND NOT COALESCE(p_is_daylight,TRUE)
    THEN
        v_chance:=v_chance+16;
    END IF;

    IF (v_origin='high_bastion' OR v_destination='high_bastion')
       AND COALESCE(p_is_daylight,TRUE)
    THEN
        v_chance:=v_chance-10;
    END IF;

    RETURN GREATEST(5,LEAST(85,v_chance));
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_dynamic_encounter_seed(
    p_terrain TEXT,
    p_origin_key TEXT,
    p_destination_key TEXT,
    p_weather_key TEXT,
    p_day_part TEXT,
    p_party_average_level NUMERIC,
    p_variant INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_terrain TEXT:=LOWER(TRIM(COALESCE(p_terrain,'')));
    v_origin TEXT:=LOWER(TRIM(COALESCE(p_origin_key,'')));
    v_destination TEXT:=LOWER(TRIM(COALESCE(p_destination_key,'')));
    v_weather TEXT:=LOWER(TRIM(COALESCE(p_weather_key,'')));
    v_day TEXT:=LOWER(TRIM(COALESCE(p_day_part,'')));
    v_variant INTEGER:=MOD(ABS(COALESCE(p_variant,0)),5);
    v_type TEXT;
    v_key TEXT;
    v_title TEXT;
    v_summary TEXT;
    v_tier TEXT:=CASE
        WHEN COALESCE(p_party_average_level,1)<=2 THEN 'Low'
        WHEN COALESCE(p_party_average_level,1)<=5 THEN 'Moderate'
        WHEN COALESCE(p_party_average_level,1)<=10 THEN 'Severe'
        ELSE 'Epic'
    END;
BEGIN
    -- Marrowfen + storm + night gets a deliberately different encounter family.
    IF (v_origin='marrowfen' OR v_destination='marrowfen')
       AND v_weather='storm' AND v_day IN ('night','late night','evening')
    THEN
        CASE v_variant
            WHEN 0 THEN v_type:='combat'; v_key:='marrowfen_storm_krasis'; v_title:='Krasis in the Black Rain';
                 v_summary:='Shapes move through flooded reeds under lightning. Scale the swamp/Krasis opposition to the living party average level.';
            WHEN 1 THEN v_type:='hazard'; v_key:='marrowfen_flooded_causeway'; v_title:='The Causeway Disappears';
                 v_summary:='Storm water overtakes the raised path. Crossing, rescue, and equipment safety matter before combat does.';
            WHEN 2 THEN v_type:='discovery'; v_key:='marrowfen_wisps'; v_title:='Lights Across the Fen';
                 v_summary:='Unnatural lights drift across storm fog, potentially leading toward danger, shelter, or a hidden clue.';
            WHEN 3 THEN v_type:='social'; v_key:='marrowfen_stranded_ferryman'; v_title:='A Lantern in the Rain';
                 v_summary:='A stranded fen traveler needs help and may know a safer route, local rumor, or warning.';
            ELSE v_type:='hazard'; v_key:='marrowfen_predator_sign'; v_title:='Something Huge Beneath the Water';
                 v_summary:='A massive wake follows the party through flooded ground. Use suspense first and scale any creature to party level.';
        END CASE;
    ELSIF (v_origin='high_bastion' OR v_destination='high_bastion') AND v_day NOT IN ('night','late night') THEN
        CASE v_variant
            WHEN 0 THEN v_type:='social'; v_key:='high_bastion_patrol'; v_title:='High Bastion Road Patrol';
                 v_summary:='A disciplined patrol checks travelers, shares road conditions, and may warn of threats farther from the walls.';
            WHEN 1 THEN v_type:='social'; v_key:='high_bastion_convoy'; v_title:='Protected Merchant Convoy';
                 v_summary:='Merchants travel under guard. The encounter can offer news, trade, or a request for assistance.';
            WHEN 2 THEN v_type:='discovery'; v_key:='high_bastion_training'; v_title:='Field Exercises';
                 v_summary:='Soldiers conduct drills beside the road, showing the region is watched and comparatively secure by daylight.';
            WHEN 3 THEN v_type:='hazard'; v_key:='high_bastion_wagon'; v_title:='Broken Axle on the Kingroad';
                 v_summary:='A wagon blocks part of the maintained road. Aid, delay, or opportunists can shape the scene.';
            ELSE v_type:='discovery'; v_key:='high_bastion_checkpoint_rumor'; v_title:='News at the Checkpoint';
                 v_summary:='Guards relay a credible local development that can seed a side objective or warning.';
        END CASE;
    ELSIF v_terrain='swamp' THEN
        CASE v_variant
            WHEN 0 THEN v_type:='combat'; v_key:='swamp_predators'; v_title:='Predators in the Reeds'; v_summary:='Swamp predators or Krasis-adapted creatures stalk the route. Scale count and CR to party level.';
            WHEN 1 THEN v_type:='hazard'; v_key:='bog_sink'; v_title:='False Ground'; v_summary:='A section of bog gives way beneath the route, threatening delay, separation, or lost gear.';
            WHEN 2 THEN v_type:='social'; v_key:='fen_travelers'; v_title:='Fen Travelers'; v_summary:='Local travelers exchange warnings, directions, or rumors if approached safely.';
            WHEN 3 THEN v_type:='discovery'; v_key:='swamp_ruin'; v_title:='Half-Sunken Ruin'; v_summary:='A structure protrudes from the mire, offering optional exploration and possible lore.';
            ELSE v_type:='hazard'; v_key:='insects_disease'; v_title:='Biting Swarm'; v_summary:='Dense insects and foul water make continued travel uncomfortable and potentially dangerous.';
        END CASE;
    ELSIF v_terrain IN ('tundra_coast','arcane_highlands') THEN
        CASE v_variant
            WHEN 0 THEN v_type:='combat'; v_key:='cold_hunter'; v_title:='Hunter on the Wind'; v_summary:='A cold-region or aerial predator crosses the route. Scale to party level and current weather.';
            WHEN 1 THEN v_type:='hazard'; v_key:='ice_or_scree'; v_title:='Treacherous Ground'; v_summary:='Ice, scree, or a steep crossing slows the party and tests safe passage.';
            WHEN 2 THEN v_type:='social'; v_key:='stranded_travelers'; v_title:='Stranded Travelers'; v_summary:='Travelers need help with shelter, transport, or navigation.';
            WHEN 3 THEN v_type:='discovery'; v_key:='sky_sign'; v_title:='Sign in the Distance'; v_summary:='Tracks, lights, or a distant structure point toward something worth investigating.';
            ELSE v_type:='hazard'; v_key:='sudden_gust'; v_title:='Violent Crosswind'; v_summary:='A sudden gust threatens footing, exposed gear, mounts, or airborne creatures.';
        END CASE;
    ELSIF v_terrain='desert' THEN
        CASE v_variant
            WHEN 0 THEN v_type:='combat'; v_key:='desert_krasis'; v_title:='Movement Under the Sand'; v_summary:='A desert predator or Krasis breaks cover. Scale opposition to party level.';
            WHEN 1 THEN v_type:='hazard'; v_key:='heat_mirage'; v_title:='Mirage and Heat'; v_summary:='Heat distorts landmarks and pressures water planning and navigation.';
            WHEN 2 THEN v_type:='social'; v_key:='desert_caravan'; v_title:='Dusty Caravan'; v_summary:='A caravan can offer news, trade, directions, or a warning.';
            WHEN 3 THEN v_type:='discovery'; v_key:='buried_stones'; v_title:='Buried Waystones'; v_summary:='Old stones emerge from shifting sand, hinting at a forgotten route or ruin.';
            ELSE v_type:='hazard'; v_key:='sand_shelf'; v_title:='Collapsing Sand Shelf'; v_summary:='The route gives way into a difficult depression or buried structure.';
        END CASE;
    ELSIF v_terrain IN ('dense_forest','moonlit_forest','pastoral_forest') THEN
        CASE v_variant
            WHEN 0 THEN v_type:='combat'; v_key:='forest_ambush'; v_title:='Ambush Beneath the Boughs'; v_summary:='Bandits, beasts, or warped creatures use cover along the route. Scale to party level.';
            WHEN 1 THEN v_type:='hazard'; v_key:='fallen_tree'; v_title:='Blocked Trail'; v_summary:='A fallen tree or washout forces a detour or coordinated clearing effort.';
            WHEN 2 THEN v_type:='social'; v_key:='woodland_travelers'; v_title:='Travelers at the Fork'; v_summary:='Hunters, pilgrims, or locals trade information and judge the party by its behavior.';
            WHEN 3 THEN v_type:='discovery'; v_key:='forest_shrine'; v_title:='Forgotten Roadside Shrine'; v_summary:='A neglected shrine or marker offers lore, a clue, or an optional detour.';
            ELSE v_type:='hazard'; v_key:='animal_panic'; v_title:='Something Spooks the Wildlife'; v_summary:='Wildlife bolts across the route, signaling a nearby threat or environmental change.';
        END CASE;
    ELSE
        CASE v_variant
            WHEN 0 THEN v_type:='combat'; v_key:='roadside_hostiles'; v_title:='Roadside Threat'; v_summary:='Hostile creatures or brigands intercept the route. Scale to the living party average level.';
            WHEN 1 THEN v_type:='hazard'; v_key:='road_damage'; v_title:='Damaged Crossing'; v_summary:='A damaged bridge, washout, rockfall, or obstacle complicates passage.';
            WHEN 2 THEN v_type:='social'; v_key:='passing_travelers'; v_title:='Passing Travelers'; v_summary:='Travelers provide a chance for roleplay, news, trade, or aid.';
            WHEN 3 THEN v_type:='discovery'; v_key:='roadside_clue'; v_title:='Clue Beside the Road'; v_summary:='Tracks, abandoned gear, or a landmark points toward a local story.';
            ELSE v_type:='hazard'; v_key:='weather_delay'; v_title:='Travel Complication'; v_summary:='Terrain and weather combine to force a meaningful choice about pace, shelter, or route.';
        END CASE;
    END IF;

    RETURN jsonb_build_object(
        'encounterType',v_type,
        'encounterKey',v_key,
        'encounterTitle',v_title,
        'encounterSummary',v_summary,
        'threatTier',v_tier,
        'partyAverageLevel',ROUND(COALESCE(p_party_average_level,1),2));
END;
$$;

-- -----------------------------------------------------------------
-- Create/reuse an authoritative travel plan. The persisted plan prevents a retry
-- from rerolling away an inconvenient encounter.
-- -----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_prepare_dynamic_travel(UUID,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_prepare_dynamic_travel(
    p_campaign_id UUID,
    p_destination_location TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_origin_name TEXT;
    v_origin_key TEXT;
    v_destination_name TEXT;
    v_destination_key TEXT;
    v_world public.discord_campaign_world_time%ROWTYPE;
    v_world_state JSONB;
    v_existing public.discord_dynamic_travel_plans%ROWTYPE;
    v_terrain TEXT;
    v_route_miles NUMERIC;
    v_progress INTEGER;
    v_nearest NUMERIC;
    v_party_size INTEGER;
    v_party_level NUMERIC;
    v_chance INTEGER;
    v_roll INTEGER;
    v_triggered BOOLEAN;
    v_seed JSONB;
    v_multiplier NUMERIC;
    v_base_minutes BIGINT;
    v_total_minutes BIGINT;
    v_encounter_minutes BIGINT;
    v_plan_id UUID;
    v_day_part TEXT;
    v_daylight BOOLEAN;
BEGIN
    SELECT c.current_location INTO v_origin_name
    FROM public.discord_campaigns c
    WHERE c.campaign_id=p_campaign_id AND c.is_active=TRUE;
    IF v_origin_name IS NULL THEN RAISE EXCEPTION 'Campaign could not be found.'; END IF;

    SELECT r.location_key,r.location_name INTO v_origin_key,v_origin_name
    FROM public.discord_world_map_resolve_location(v_origin_name) r;
    SELECT r.location_key,r.location_name INTO v_destination_key,v_destination_name
    FROM public.discord_world_map_resolve_location(p_destination_location) r;
    IF v_destination_key IS NULL THEN RAISE EXCEPTION 'Unknown Vael Turog destination: %',p_destination_location; END IF;
    IF v_origin_key=v_destination_key THEN
        RETURN jsonb_build_object('success',TRUE,'alreadyThere',TRUE,'destinationName',v_destination_name,'requiredAdvanceHours',0);
    END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.discord_world_map_discoveries d
        WHERE d.campaign_id=p_campaign_id AND d.location_key=v_destination_key
    ) THEN
        RAISE EXCEPTION 'Destination has not been discovered by this campaign.';
    END IF;

    INSERT INTO public.discord_campaign_world_time(campaign_id)
    VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_world_time_pkey DO NOTHING;
    SELECT * INTO v_world FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id FOR UPDATE;
    v_world_state:=public.discord_build_world_time_state(p_campaign_id);
    v_day_part:=COALESCE(v_world_state->>'dayPart','');
    v_daylight:=COALESCE((v_world_state->>'isDaylight')::BOOLEAN,TRUE);

    SELECT * INTO v_existing
    FROM public.discord_dynamic_travel_plans p
    WHERE p.campaign_id=p_campaign_id
      AND p.status IN ('traveling','encounter_pending','encounter_resolved','ready')
    ORDER BY p.created_at DESC LIMIT 1 FOR UPDATE;

    IF v_existing.travel_plan_id IS NOT NULL
       AND v_existing.origin_key=v_origin_key
       AND v_existing.destination_key=v_destination_key
    THEN
        RETURN jsonb_build_object(
            'success',TRUE,'reused',TRUE,'travelPlanId',v_existing.travel_plan_id,
            'originName',v_existing.origin_name,'destinationName',v_existing.destination_name,
            'terrain',v_existing.terrain_key,'routeMiles',v_existing.route_miles,
            'nearestSettlementMiles',v_existing.nearest_settlement_miles,
            'partyAverageLevel',v_existing.party_average_level,'partySize',v_existing.party_size,
            'weatherKey',v_existing.initial_weather_key,'weatherLabel',v_existing.initial_weather_label,
            'weatherTravelMultiplier',v_existing.initial_weather_multiplier,
            'dayPart',v_existing.day_part,'daylight',v_existing.daylight,
            'encounterChance',v_existing.encounter_chance,'encounterRoll',v_existing.encounter_roll,
            'encounterTriggered',v_existing.encounter_triggered,'encounterType',v_existing.encounter_type,
            'encounterKey',v_existing.encounter_key,'encounterTitle',v_existing.encounter_title,
            'encounterSummary',v_existing.encounter_summary,'threatTier',v_existing.threat_tier,
            'status',v_existing.status,
            'requiredAdvanceHoursBeforeEncounter',GREATEST(0,ROUND((v_existing.encounter_world_minute-v_world.world_minute)/60.0,2)),
            'requiredAdvanceHoursToArrival',GREATEST(0,ROUND((v_existing.arrival_world_minute-v_world.world_minute)/60.0,2)));
    END IF;

    IF v_existing.travel_plan_id IS NOT NULL THEN
        UPDATE public.discord_dynamic_travel_plans
        SET status='cancelled',updated_at=NOW()
        WHERE travel_plan_id=v_existing.travel_plan_id;
    END IF;

    SELECT COUNT(*)::INTEGER,COALESCE(AVG(GREATEST(1,COALESCE(c.level,1))),1)
    INTO v_party_size,v_party_level
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND COALESCE(c.life_state,'alive')='alive';

    v_terrain:=public.discord_dynamic_route_terrain(v_origin_key,v_destination_key);
    v_route_miles:=public.discord_dynamic_route_miles(v_origin_key,v_destination_key);
    v_progress:=(20+FLOOR(random()*61))::INTEGER;
    v_nearest:=ROUND(v_route_miles*LEAST(v_progress,100-v_progress)/100.0,2);
    v_multiplier:=public.discord_weather_travel_multiplier(v_world.weather_key);
    v_base_minutes:=CEIL((v_route_miles/3.0)*60.0)::BIGINT;
    v_total_minutes:=GREATEST(30,CEIL(v_base_minutes*v_multiplier)::BIGINT);
    v_encounter_minutes:=GREATEST(15,ROUND(v_total_minutes*(v_progress/100.0))::BIGINT);

    v_chance:=public.discord_dynamic_encounter_chance(
        v_terrain,v_nearest,v_world.weather_key,v_day_part,v_daylight,v_party_level,v_origin_key,v_destination_key);
    v_roll:=(1+FLOOR(random()*100))::INTEGER;
    v_triggered:=v_roll<=v_chance;

    IF v_triggered THEN
        v_seed:=public.discord_dynamic_encounter_seed(
            v_terrain,v_origin_key,v_destination_key,v_world.weather_key,v_day_part,v_party_level,
            FLOOR(random()*2147483647)::INTEGER);
    ELSE
        v_seed:=jsonb_build_object(
            'encounterType','none','encounterKey','','encounterTitle','Uneventful Travel',
            'encounterSummary','No major random encounter interrupts this leg of travel.',
            'threatTier',CASE WHEN v_party_level<=2 THEN 'Low' WHEN v_party_level<=5 THEN 'Moderate' WHEN v_party_level<=10 THEN 'Severe' ELSE 'Epic' END);
    END IF;

    INSERT INTO public.discord_dynamic_travel_plans(
        campaign_id,origin_key,origin_name,destination_key,destination_name,terrain_key,
        route_miles,progress_percent,nearest_settlement_miles,party_average_level,party_size,
        start_world_minute,encounter_world_minute,arrival_world_minute,
        initial_weather_key,initial_weather_label,initial_weather_multiplier,day_part,daylight,
        encounter_chance,encounter_roll,encounter_triggered,encounter_type,encounter_key,
        encounter_title,encounter_summary,threat_tier,status)
    VALUES(
        p_campaign_id,v_origin_key,v_origin_name,v_destination_key,v_destination_name,v_terrain,
        v_route_miles,v_progress,v_nearest,ROUND(v_party_level,2),v_party_size,
        v_world.world_minute,v_world.world_minute+v_encounter_minutes,v_world.world_minute+v_total_minutes,
        v_world.weather_key,v_world.weather_label,v_multiplier,v_day_part,v_daylight,
        v_chance,v_roll,v_triggered,COALESCE(v_seed->>'encounterType','none'),COALESCE(v_seed->>'encounterKey',''),
        COALESCE(v_seed->>'encounterTitle',''),COALESCE(v_seed->>'encounterSummary',''),COALESCE(v_seed->>'threatTier','Low'),
        CASE WHEN v_triggered THEN 'encounter_pending' ELSE 'traveling' END)
    RETURNING travel_plan_id INTO v_plan_id;

    RETURN jsonb_build_object(
        'success',TRUE,'reused',FALSE,'travelPlanId',v_plan_id,
        'originName',v_origin_name,'destinationName',v_destination_name,
        'terrain',v_terrain,'routeMiles',v_route_miles,'nearestSettlementMiles',v_nearest,
        'partyAverageLevel',ROUND(v_party_level,2),'partySize',v_party_size,
        'weatherKey',v_world.weather_key,'weatherLabel',v_world.weather_label,
        'weatherTravelMultiplier',v_multiplier,'dayPart',v_day_part,'daylight',v_daylight,
        'encounterChance',v_chance,'encounterRoll',v_roll,'encounterTriggered',v_triggered,
        'encounterType',COALESCE(v_seed->>'encounterType','none'),'encounterKey',COALESCE(v_seed->>'encounterKey',''),
        'encounterTitle',COALESCE(v_seed->>'encounterTitle',''),'encounterSummary',COALESCE(v_seed->>'encounterSummary',''),
        'threatTier',COALESCE(v_seed->>'threatTier','Low'),
        'requiredAdvanceHoursBeforeEncounter',CASE WHEN v_triggered THEN ROUND(v_encounter_minutes/60.0,2) ELSE NULL END,
        'requiredAdvanceHoursToArrival',ROUND(v_total_minutes/60.0,2));
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_dynamic_travel_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_dynamic_travel_state(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE v_plan public.discord_dynamic_travel_plans%ROWTYPE; v_world BIGINT;
BEGIN
    SELECT * INTO v_plan FROM public.discord_dynamic_travel_plans p
    WHERE p.campaign_id=p_campaign_id
      AND p.status IN ('traveling','encounter_pending','encounter_resolved','ready')
    ORDER BY p.created_at DESC LIMIT 1;
    IF v_plan.travel_plan_id IS NULL THEN RETURN jsonb_build_object('active',FALSE); END IF;
    SELECT w.world_minute INTO v_world FROM public.discord_campaign_world_time w WHERE w.campaign_id=p_campaign_id;
    RETURN jsonb_build_object(
        'active',TRUE,'travelPlanId',v_plan.travel_plan_id,'status',v_plan.status,
        'originName',v_plan.origin_name,'destinationName',v_plan.destination_name,
        'terrain',v_plan.terrain_key,'routeMiles',v_plan.route_miles,
        'nearestSettlementMiles',v_plan.nearest_settlement_miles,
        'partyAverageLevel',v_plan.party_average_level,'partySize',v_plan.party_size,
        'encounterTriggered',v_plan.encounter_triggered,'encounterType',v_plan.encounter_type,
        'encounterTitle',v_plan.encounter_title,'encounterSummary',v_plan.encounter_summary,
        'threatTier',v_plan.threat_tier,'encounterOutcome',v_plan.encounter_outcome,
        'hoursUntilEncounter',GREATEST(0,ROUND((v_plan.encounter_world_minute-COALESCE(v_world,v_plan.start_world_minute))/60.0,2)),
        'hoursUntilArrival',GREATEST(0,ROUND((v_plan.arrival_world_minute-COALESCE(v_world,v_plan.start_world_minute))/60.0,2)));
END;
$$;

-- Resolve the persisted encounter only after the party reaches its travel-time
-- position. The remaining leg is recalculated from CURRENT weather.
DROP FUNCTION IF EXISTS public.discord_gm_resolve_dynamic_travel_encounter(UUID,UUID,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_resolve_dynamic_travel_encounter(
    p_campaign_id UUID,
    p_travel_plan_id UUID,
    p_outcome TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_plan public.discord_dynamic_travel_plans%ROWTYPE;
    v_world public.discord_campaign_world_time%ROWTYPE;
    v_remaining_miles NUMERIC;
    v_multiplier NUMERIC;
    v_remaining_minutes BIGINT;
BEGIN
    SELECT * INTO v_plan FROM public.discord_dynamic_travel_plans p
    WHERE p.travel_plan_id=p_travel_plan_id AND p.campaign_id=p_campaign_id FOR UPDATE;
    IF v_plan.travel_plan_id IS NULL THEN RAISE EXCEPTION 'Travel plan could not be found.'; END IF;
    IF NOT v_plan.encounter_triggered THEN RAISE EXCEPTION 'This travel plan has no encounter to resolve.'; END IF;
    IF v_plan.status<>'encounter_pending' THEN
        RETURN jsonb_build_object('success',TRUE,'alreadyResolved',TRUE,'travelPlanId',v_plan.travel_plan_id,
            'status',v_plan.status,'remainingTravelHours',GREATEST(0,ROUND((v_plan.arrival_world_minute-(SELECT world_minute FROM public.discord_campaign_world_time WHERE campaign_id=p_campaign_id))/60.0,2)));
    END IF;

    SELECT * INTO v_world FROM public.discord_campaign_world_time w
    WHERE w.campaign_id=p_campaign_id FOR UPDATE;
    IF v_world.world_minute<v_plan.encounter_world_minute THEN
        RAISE EXCEPTION 'The party has not yet traveled far enough to reach this encounter.';
    END IF;

    v_remaining_miles:=ROUND(v_plan.route_miles*(100-v_plan.progress_percent)/100.0,2);
    v_multiplier:=public.discord_weather_travel_multiplier(v_world.weather_key);
    v_remaining_minutes:=GREATEST(1,CEIL((v_remaining_miles/3.0)*60.0*v_multiplier)::BIGINT);

    UPDATE public.discord_dynamic_travel_plans p
    SET status='encounter_resolved',
        encounter_outcome=LEFT(TRIM(COALESCE(p_outcome,'')),500),
        arrival_world_minute=v_world.world_minute+v_remaining_minutes,
        resolved_at=NOW(),updated_at=NOW()
    WHERE p.travel_plan_id=v_plan.travel_plan_id;

    RETURN jsonb_build_object(
        'success',TRUE,'travelPlanId',v_plan.travel_plan_id,'status','encounter_resolved',
        'outcome',LEFT(TRIM(COALESCE(p_outcome,'')),500),
        'currentWeatherKey',v_world.weather_key,'currentWeatherLabel',v_world.weather_label,
        'currentWeatherTravelMultiplier',v_multiplier,
        'remainingRouteMiles',v_remaining_miles,
        'remainingTravelHours',ROUND(v_remaining_minutes/60.0,2));
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_check_dynamic_travel_arrival(UUID,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_check_dynamic_travel_arrival(
    p_campaign_id UUID,
    p_destination_location TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_destination_key TEXT;
    v_destination_name TEXT;
    v_plan public.discord_dynamic_travel_plans%ROWTYPE;
    v_world BIGINT;
    v_remaining NUMERIC;
BEGIN
    SELECT r.location_key,r.location_name INTO v_destination_key,v_destination_name
    FROM public.discord_world_map_resolve_location(p_destination_location) r;
    IF v_destination_key IS NULL THEN RAISE EXCEPTION 'Unknown destination.'; END IF;

    SELECT * INTO v_plan FROM public.discord_dynamic_travel_plans p
    WHERE p.campaign_id=p_campaign_id
      AND p.destination_key=v_destination_key
      AND p.status IN ('traveling','encounter_pending','encounter_resolved','ready')
    ORDER BY p.created_at DESC LIMIT 1 FOR UPDATE;

    IF v_plan.travel_plan_id IS NULL THEN
        RETURN jsonb_build_object('readyToArrive',FALSE,'reason','prepare_required','destinationName',v_destination_name,
            'message','Call prepare_dynamic_travel before attempting arrival.');
    END IF;

    SELECT w.world_minute INTO v_world FROM public.discord_campaign_world_time w WHERE w.campaign_id=p_campaign_id;
    v_world:=COALESCE(v_world,v_plan.start_world_minute);

    IF v_plan.encounter_triggered AND v_plan.status='encounter_pending' THEN
        IF v_world<v_plan.encounter_world_minute THEN
            v_remaining:=ROUND((v_plan.encounter_world_minute-v_world)/60.0,2);
            RETURN jsonb_build_object('readyToArrive',FALSE,'reason','advance_to_encounter','travelPlanId',v_plan.travel_plan_id,
                'requiredAdvanceHours',GREATEST(0,v_remaining),'encounterTitle',v_plan.encounter_title,
                'encounterType',v_plan.encounter_type,'encounterSummary',v_plan.encounter_summary,'threatTier',v_plan.threat_tier);
        ELSE
            RETURN jsonb_build_object('readyToArrive',FALSE,'reason','encounter_required','travelPlanId',v_plan.travel_plan_id,
                'requiredAdvanceHours',0,'encounterTitle',v_plan.encounter_title,'encounterType',v_plan.encounter_type,
                'encounterSummary',v_plan.encounter_summary,'threatTier',v_plan.threat_tier,
                'message','Resolve the persisted encounter, then call resolve_dynamic_travel_encounter.');
        END IF;
    END IF;

    IF v_world<v_plan.arrival_world_minute THEN
        v_remaining:=ROUND((v_plan.arrival_world_minute-v_world)/60.0,2);
        RETURN jsonb_build_object('readyToArrive',FALSE,'reason','advance_remaining_time','travelPlanId',v_plan.travel_plan_id,
            'requiredAdvanceHours',GREATEST(0,v_remaining),'destinationName',v_plan.destination_name);
    END IF;

    UPDATE public.discord_dynamic_travel_plans SET status='ready',updated_at=NOW()
    WHERE travel_plan_id=v_plan.travel_plan_id;
    RETURN jsonb_build_object('readyToArrive',TRUE,'reason','ready','travelPlanId',v_plan.travel_plan_id,
        'requiredAdvanceHours',0,'destinationName',v_plan.destination_name);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_complete_dynamic_travel(UUID,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_complete_dynamic_travel(
    p_campaign_id UUID,
    p_destination_location TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE v_key TEXT; v_name TEXT; v_plan_id UUID;
BEGIN
    SELECT r.location_key,r.location_name INTO v_key,v_name
    FROM public.discord_world_map_resolve_location(p_destination_location) r;
    UPDATE public.discord_dynamic_travel_plans p
    SET status='arrived',arrived_at=NOW(),updated_at=NOW()
    WHERE p.travel_plan_id=(
        SELECT p2.travel_plan_id FROM public.discord_dynamic_travel_plans p2
        WHERE p2.campaign_id=p_campaign_id AND p2.destination_key=v_key
          AND p2.status='ready'
        ORDER BY p2.created_at DESC LIMIT 1)
    RETURNING travel_plan_id INTO v_plan_id;
    RETURN jsonb_build_object('success',TRUE,'travelPlanId',v_plan_id,'destinationName',v_name,'status','arrived');
END;
$$;

REVOKE ALL ON FUNCTION public.discord_dynamic_route_terrain(TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_dynamic_route_miles(TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_weather_travel_multiplier(TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_dynamic_encounter_chance(TEXT,NUMERIC,TEXT,TEXT,BOOLEAN,NUMERIC,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_dynamic_encounter_seed(TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_prepare_dynamic_travel(UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_dynamic_travel_state(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_resolve_dynamic_travel_encounter(UUID,UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_check_dynamic_travel_arrival(UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_complete_dynamic_travel(UUID,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_gm_prepare_dynamic_travel(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_dynamic_travel_state(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_resolve_dynamic_travel_encounter(UUID,UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_check_dynamic_travel_arrival(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_complete_dynamic_travel(UUID,TEXT) TO service_role;

COMMIT;
