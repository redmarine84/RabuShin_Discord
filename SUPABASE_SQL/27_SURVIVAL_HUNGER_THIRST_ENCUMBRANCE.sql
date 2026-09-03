-- ============================================================
-- RabuShinAIGM Rules Build 6.8
-- Hunger / Thirst toggle + survival time + item physical data
-- + Strength x 15 carrying-capacity support.
-- Safe to run more than once.
-- Revised: fixes PostgreSQL 42702 by using named constraints anywhere a
-- RETURNS TABLE output variable could collide with an ON CONFLICT column.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_campaign_survival_settings
(
    campaign_id UUID PRIMARY KEY REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    hot_weather BOOLEAN NOT NULL DEFAULT FALSE,
    weather_reason TEXT NOT NULL DEFAULT '',
    updated_by_player_id UUID NULL REFERENCES public.discord_players(player_id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.discord_character_survival
(
    character_id UUID PRIMARY KEY REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    food_credit_lb NUMERIC(10,4) NOT NULL DEFAULT 1.0 CHECK (food_credit_lb >= 0),
    water_credit_gal NUMERIC(10,4) NOT NULL DEFAULT 1.0 CHECK (water_credit_gal >= 0),
    food_deficit_hours NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (food_deficit_hours >= 0),
    water_deficit_hours NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (water_deficit_hours >= 0),
    exhaustion_level INTEGER NOT NULL DEFAULT 0 CHECK (exhaustion_level BETWEEN 0 AND 6),
    last_reason TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_discord_character_survival_campaign
    ON public.discord_character_survival(campaign_id);

ALTER TABLE public.discord_campaign_survival_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_character_survival ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_campaign_survival_settings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.discord_character_survival FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_campaign_survival_settings TO service_role;
GRANT ALL ON public.discord_character_survival TO service_role;

INSERT INTO public.discord_campaign_survival_settings(campaign_id, enabled, hot_weather)
SELECT c.campaign_id, FALSE, FALSE
FROM public.discord_campaigns c
ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;

INSERT INTO public.discord_character_survival(character_id, campaign_id, food_credit_lb, water_credit_gal)
SELECT c.character_id, c.campaign_id, 1.0, 1.0
FROM public.discord_characters c
ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

-- Build 6.8 extends the existing Build 6.7 valuation persistence RPC with
-- physical weight and food/water metadata. Existing value metadata is preserved.
DROP FUNCTION IF EXISTS public.discord_apply_inventory_valuations(UUID, UUID, JSONB);
CREATE OR REPLACE FUNCTION public.discord_apply_inventory_valuations(
    p_player_id UUID,
    p_campaign_id UUID,
    p_items JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_item JSONB;
    v_inventory_item_id UUID;
    v_rarity TEXT;
    v_category TEXT;
    v_value_class TEXT;
    v_base_value NUMERIC;
    v_sellable BOOLEAN;
    v_priceless BOOLEAN;
    v_source TEXT;
    v_price_band TEXT;
    v_version TEXT;
    v_weight NUMERIC;
    v_food NUMERIC;
    v_water NUMERIC;
    v_physical_version TEXT;
    v_count INTEGER := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id = p_campaign_id AND c.player_id = p_player_id
    LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'Inventory valuation payload must be an array.';
    END IF;
    IF jsonb_array_length(p_items) > 500 THEN RAISE EXCEPTION 'Too many inventory valuations in one request.'; END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
    LOOP
        BEGIN
            v_inventory_item_id := NULLIF(TRIM(COALESCE(v_item->>'inventory_item_id', '')), '')::UUID;
        EXCEPTION WHEN invalid_text_representation THEN
            v_inventory_item_id := NULL;
        END;
        IF v_inventory_item_id IS NULL THEN CONTINUE; END IF;

        v_rarity := TRIM(COALESCE(v_item->>'rarity', 'Common'));
        IF v_rarity NOT IN ('Common','Uncommon','Rare','Very Rare','Legendary','Artifact') THEN v_rarity := 'Common'; END IF;
        v_category := LEFT(TRIM(COALESCE(v_item->>'valuation_category', 'Miscellaneous')), 80);
        v_value_class := LEFT(TRIM(COALESCE(v_item->>'value_class', v_category)), 80);
        v_source := LEFT(TRIM(COALESCE(v_item->>'valuation_source', 'Server valuation')), 160);
        v_price_band := LEFT(TRIM(COALESCE(v_item->>'price_band', '')), 240);
        v_version := LEFT(TRIM(COALESCE(v_item->>'valuation_version', '6.8')), 20);
        v_physical_version := LEFT(TRIM(COALESCE(v_item->>'physical_profile_version', '6.8')), 20);

        BEGIN v_base_value := ROUND(GREATEST(COALESCE((v_item->>'base_value_gp')::NUMERIC, 0), 0), 2);
        EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN v_base_value := 0; END;
        BEGIN v_weight := ROUND(GREATEST(COALESCE((v_item->>'weight_lb')::NUMERIC, 1), 0), 2);
        EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN v_weight := 1; END;
        BEGIN v_food := ROUND(GREATEST(COALESCE((v_item->>'food_lb')::NUMERIC, 0), 0), 2);
        EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN v_food := 0; END;
        BEGIN v_water := ROUND(GREATEST(COALESCE((v_item->>'water_gallons')::NUMERIC, 0), 0), 3);
        EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN v_water := 0; END;

        v_base_value := LEAST(v_base_value, 1000000);
        v_weight := LEAST(v_weight, 100000);
        v_food := LEAST(v_food, 1000);
        v_water := LEAST(v_water, 1000);
        v_sellable := COALESCE((v_item->>'sellable')::BOOLEAN, TRUE);
        v_priceless := COALESCE((v_item->>'priceless')::BOOLEAN, FALSE);

        IF v_rarity = 'Artifact' OR v_priceless THEN
            v_rarity := 'Artifact'; v_priceless := TRUE; v_sellable := FALSE; v_base_value := 0;
        END IF;

        UPDATE public.discord_inventory_items i
        SET item_data = COALESCE(i.item_data, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
                'rarity', v_rarity,
                'valuation_category', v_category,
                'value_class', v_value_class,
                'base_value_gp', v_base_value,
                'sellable', v_sellable,
                'priceless', v_priceless,
                'valuation_source', v_source,
                'price_band', v_price_band,
                'valuation_version', v_version,
                'weight_lb', v_weight,
                'food_lb', v_food,
                'water_gallons', v_water,
                'physical_profile_version', v_physical_version
            )),
            updated_at = NOW()
        WHERE i.inventory_item_id = v_inventory_item_id AND i.character_id = v_character_id;
        IF FOUND THEN v_count := v_count + 1; END IF;
    END LOOP;

    RETURN v_count;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_survival_state(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_survival_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    campaign_id UUID,
    character_id UUID,
    enabled BOOLEAN,
    is_owner BOOLEAN,
    hot_weather BOOLEAN,
    food_credit_lb NUMERIC,
    water_credit_gal NUMERIC,
    food_requirement_lb NUMERIC,
    water_requirement_gal NUMERIC,
    hunger_percent NUMERIC,
    thirst_percent NUMERIC,
    food_deficit_hours NUMERIC,
    water_deficit_hours NUMERIC,
    exhaustion_level INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id AND m.player_id = p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;

    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id = p_campaign_id AND c.player_id = p_player_id
    LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    INSERT INTO public.discord_character_survival(character_id, campaign_id)
    VALUES(v_character_id, p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY
    SELECT
        p_campaign_id,
        v_character_id,
        s.enabled,
        (c.owner_player_id = p_player_id),
        s.hot_weather,
        cs.food_credit_lb,
        cs.water_credit_gal,
        1.0::NUMERIC,
        (CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)::NUMERIC,
        ROUND(LEAST(100.0, GREATEST(0.0, cs.food_credit_lb * 100.0)), 1),
        ROUND(LEAST(100.0, GREATEST(0.0, cs.water_credit_gal / (CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END) * 100.0)), 1),
        cs.food_deficit_hours,
        cs.water_deficit_hours,
        cs.exhaustion_level
    FROM public.discord_campaigns c
    JOIN public.discord_campaign_survival_settings s ON s.campaign_id = c.campaign_id
    JOIN public.discord_character_survival cs ON cs.character_id = v_character_id
    WHERE c.campaign_id = p_campaign_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_set_survival_enabled(UUID, UUID, BOOLEAN);
CREATE OR REPLACE FUNCTION public.discord_set_survival_enabled(
    p_player_id UUID,
    p_campaign_id UUID,
    p_enabled BOOLEAN
)
RETURNS TABLE(
    campaign_id UUID,
    character_id UUID,
    enabled BOOLEAN,
    is_owner BOOLEAN,
    hot_weather BOOLEAN,
    food_credit_lb NUMERIC,
    water_credit_gal NUMERIC,
    food_requirement_lb NUMERIC,
    water_requirement_gal NUMERIC,
    hunger_percent NUMERIC,
    thirst_percent NUMERIC,
    food_deficit_hours NUMERIC,
    water_deficit_hours NUMERIC,
    exhaustion_level INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id = p_campaign_id AND c.owner_player_id = p_player_id AND c.is_active = TRUE
    ) THEN RAISE EXCEPTION 'Only the campaign owner can change Hunger and Thirst rules.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id, enabled, updated_by_player_id, updated_at)
    VALUES(p_campaign_id, COALESCE(p_enabled,FALSE), p_player_id, NOW())
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO UPDATE
    SET enabled = EXCLUDED.enabled, updated_by_player_id = EXCLUDED.updated_by_player_id, updated_at = NOW();

    INSERT INTO public.discord_character_survival(character_id, campaign_id, food_credit_lb, water_credit_gal)
    SELECT c.character_id, c.campaign_id, 1.0,
           CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END
    FROM public.discord_characters c
    JOIN public.discord_campaign_survival_settings s ON s.campaign_id = c.campaign_id
    WHERE c.campaign_id = p_campaign_id
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY SELECT * FROM public.discord_get_survival_state(p_player_id, p_campaign_id);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_survival_state(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_survival_state(
    p_campaign_id UUID,
    p_character_id UUID
)
RETURNS TABLE(
    enabled BOOLEAN,
    hot_weather BOOLEAN,
    food_credit_lb NUMERIC,
    water_credit_gal NUMERIC,
    food_requirement_lb NUMERIC,
    water_requirement_gal NUMERIC,
    hunger_percent NUMERIC,
    thirst_percent NUMERIC,
    food_deficit_hours NUMERIC,
    water_deficit_hours NUMERIC,
    exhaustion_level INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.discord_characters c WHERE c.character_id=p_character_id AND c.campaign_id=p_campaign_id)
    THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(p_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    RETURN QUERY
    SELECT s.enabled, s.hot_weather, cs.food_credit_lb, cs.water_credit_gal,
           1.0::NUMERIC, (CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)::NUMERIC,
           ROUND(LEAST(100.0,GREATEST(0.0,cs.food_credit_lb*100.0)),1),
           ROUND(LEAST(100.0,GREATEST(0.0,cs.water_credit_gal/(CASE WHEN s.hot_weather THEN 2.0 ELSE 1.0 END)*100.0)),1),
           cs.food_deficit_hours, cs.water_deficit_hours, cs.exhaustion_level
    FROM public.discord_campaign_survival_settings s
    JOIN public.discord_character_survival cs ON cs.campaign_id=s.campaign_id AND cs.character_id=p_character_id
    WHERE s.campaign_id=p_campaign_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_set_survival_hot_weather(UUID, BOOLEAN, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_set_survival_hot_weather(
    p_campaign_id UUID,
    p_hot_weather BOOLEAN,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.discord_campaigns c WHERE c.campaign_id=p_campaign_id AND c.is_active=TRUE)
    THEN RAISE EXCEPTION 'Campaign could not be found.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id,hot_weather,weather_reason,updated_at)
    VALUES(p_campaign_id,COALESCE(p_hot_weather,FALSE),LEFT(TRIM(COALESCE(p_reason,'')),200),NOW())
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO UPDATE
    SET hot_weather=EXCLUDED.hot_weather, weather_reason=EXCLUDED.weather_reason, updated_at=NOW();

    IF COALESCE(p_hot_weather,FALSE)=FALSE THEN
        UPDATE public.discord_character_survival cs
        SET water_credit_gal=LEAST(cs.water_credit_gal,1.0),updated_at=NOW()
        WHERE cs.campaign_id=p_campaign_id;
    END IF;

    RETURN jsonb_build_object('enabled',(SELECT dcss.enabled FROM public.discord_campaign_survival_settings AS dcss WHERE dcss.campaign_id=p_campaign_id),
                              'hotWeather',COALESCE(p_hot_weather,FALSE),
                              'waterRequirementGallons',CASE WHEN COALESCE(p_hot_weather,FALSE) THEN 2 ELSE 1 END,
                              'reason',LEFT(TRIM(COALESCE(p_reason,'')),200));
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_advance_survival_time(UUID, TEXT[], NUMERIC, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_advance_survival_time(
    p_campaign_id UUID,
    p_character_names TEXT[],
    p_hours NUMERIC,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_enabled BOOLEAN;
    v_hot BOOLEAN;
    v_hours NUMERIC := ROUND(COALESCE(p_hours,0),2);
    v_water_req NUMERIC;
    v_food_rate NUMERIC := 1.0/24.0;
    v_water_rate NUMERIC;
    v_char RECORD;
    v_state RECORD;
    v_food_deficit_add NUMERIC;
    v_water_deficit_add NUMERIC;
    v_food_before_bucket INTEGER;
    v_food_after_bucket INTEGER;
    v_water_before_bucket INTEGER;
    v_water_after_bucket INTEGER;
    v_exhaustion_add INTEGER;
    v_results JSONB := '[]'::jsonb;
    v_count INTEGER := 0;
BEGIN
    IF v_hours <= 0 OR v_hours > 168 THEN RAISE EXCEPTION 'Survival time must be between 0 and 168 hours.'; END IF;
    IF COALESCE(array_length(p_character_names,1),0)=0 THEN RAISE EXCEPTION 'At least one character name is required.'; END IF;

    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled,s.hot_weather INTO v_enabled,v_hot FROM public.discord_campaign_survival_settings s WHERE s.campaign_id=p_campaign_id;
    IF NOT COALESCE(v_enabled,FALSE) THEN
        RETURN jsonb_build_object('enabled',FALSE,'changed',FALSE,'hours',v_hours,'characters','[]'::jsonb);
    END IF;

    v_water_req := CASE WHEN v_hot THEN 2.0 ELSE 1.0 END;
    v_water_rate := v_water_req/24.0;

    FOR v_char IN
        SELECT c.character_id,c.character_name
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND EXISTS (SELECT 1 FROM unnest(p_character_names) n WHERE lower(trim(n))=lower(c.character_name))
        ORDER BY c.character_name
    LOOP
        v_count := v_count + 1;
        INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(v_char.character_id,p_campaign_id)
        ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
        SELECT * INTO v_state FROM public.discord_character_survival cs WHERE cs.character_id=v_char.character_id FOR UPDATE;

        v_food_deficit_add := GREATEST(0, v_hours - (v_state.food_credit_lb / v_food_rate));
        v_water_deficit_add := GREATEST(0, v_hours - (v_state.water_credit_gal / v_water_rate));
        v_food_before_bucket := FLOOR(v_state.food_deficit_hours/24.0);
        v_food_after_bucket := FLOOR((v_state.food_deficit_hours+v_food_deficit_add)/24.0);
        v_water_before_bucket := FLOOR(v_state.water_deficit_hours/24.0);
        v_water_after_bucket := FLOOR((v_state.water_deficit_hours+v_water_deficit_add)/24.0);
        v_exhaustion_add := GREATEST(0,v_food_after_bucket-v_food_before_bucket)+GREATEST(0,v_water_after_bucket-v_water_before_bucket);

        UPDATE public.discord_character_survival cs
        SET food_credit_lb=GREATEST(0,cs.food_credit_lb-(v_food_rate*v_hours)),
            water_credit_gal=GREATEST(0,cs.water_credit_gal-(v_water_rate*v_hours)),
            food_deficit_hours=cs.food_deficit_hours+v_food_deficit_add,
            water_deficit_hours=cs.water_deficit_hours+v_water_deficit_add,
            exhaustion_level=LEAST(6,cs.exhaustion_level+v_exhaustion_add),
            last_reason=LEFT(TRIM(COALESCE(p_reason,'')),200),updated_at=NOW()
        WHERE cs.character_id=v_char.character_id
        RETURNING * INTO v_state;

        v_results := v_results || jsonb_build_array(jsonb_build_object(
            'characterName',v_char.character_name,
            'foodCreditLb',ROUND(v_state.food_credit_lb,2),
            'waterCreditGallons',ROUND(v_state.water_credit_gal,2),
            'hungerPercent',ROUND(LEAST(100,GREATEST(0,v_state.food_credit_lb*100)),1),
            'thirstPercent',ROUND(LEAST(100,GREATEST(0,v_state.water_credit_gal/v_water_req*100)),1),
            'exhaustionLevel',v_state.exhaustion_level,
            'exhaustionAdded',v_exhaustion_add));
    END LOOP;

    IF v_count=0 THEN RAISE EXCEPTION 'None of the named characters could be found in this campaign.'; END IF;
    RETURN jsonb_build_object('enabled',TRUE,'changed',TRUE,'hours',v_hours,'hotWeather',v_hot,'characters',v_results);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_consume_survival_item(UUID, UUID, UUID, INTEGER, NUMERIC, NUMERIC, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_consume_survival_item(
    p_campaign_id UUID,
    p_character_id UUID,
    p_inventory_item_id UUID,
    p_quantity INTEGER,
    p_food_lb_per_item NUMERIC,
    p_water_gallons_per_item NUMERIC,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_enabled BOOLEAN;
    v_hot BOOLEAN;
    v_req NUMERIC;
    v_item RECORD;
    v_state RECORD;
    v_qty INTEGER := GREATEST(1,COALESCE(p_quantity,1));
    v_food NUMERIC := GREATEST(0,COALESCE(p_food_lb_per_item,0))*v_qty;
    v_water NUMERIC := GREATEST(0,COALESCE(p_water_gallons_per_item,0))*v_qty;
    v_remaining INTEGER;
BEGIN
    INSERT INTO public.discord_campaign_survival_settings(campaign_id) VALUES(p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_campaign_survival_settings_pkey DO NOTHING;
    SELECT s.enabled,s.hot_weather INTO v_enabled,v_hot FROM public.discord_campaign_survival_settings s WHERE s.campaign_id=p_campaign_id;
    IF NOT COALESCE(v_enabled,FALSE) THEN RAISE EXCEPTION 'Hunger and Thirst rules are disabled for this campaign.'; END IF;
    IF v_food<=0 AND v_water<=0 THEN RAISE EXCEPTION 'This item has no recognized food or drinking-water value.'; END IF;
    v_req := CASE WHEN v_hot THEN 2.0 ELSE 1.0 END;

    SELECT i.* INTO v_item FROM public.discord_inventory_items i
    WHERE i.inventory_item_id=p_inventory_item_id AND i.character_id=p_character_id FOR UPDATE;
    IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM public.discord_characters c WHERE c.character_id=p_character_id AND c.campaign_id=p_campaign_id)
    THEN RAISE EXCEPTION 'Inventory item could not be found for this character.'; END IF;
    IF v_item.quantity<v_qty THEN RAISE EXCEPTION 'Not enough of this inventory item is carried.'; END IF;

    v_remaining := v_item.quantity-v_qty;
    IF v_remaining<=0 THEN
        DELETE FROM public.discord_inventory_items AS dii
        WHERE dii.inventory_item_id=p_inventory_item_id;
    ELSE
        UPDATE public.discord_inventory_items AS dii
        SET quantity=v_remaining,updated_at=NOW()
        WHERE dii.inventory_item_id=p_inventory_item_id;
    END IF;

    INSERT INTO public.discord_character_survival(character_id,campaign_id) VALUES(p_character_id,p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;
    UPDATE public.discord_character_survival cs
    SET food_credit_lb=LEAST(1.0,cs.food_credit_lb+v_food),
        water_credit_gal=LEAST(v_req,cs.water_credit_gal+v_water),
        food_deficit_hours=CASE WHEN v_food>0 THEN 0 ELSE cs.food_deficit_hours END,
        water_deficit_hours=CASE WHEN v_water>0 THEN 0 ELSE cs.water_deficit_hours END,
        last_reason=LEFT(TRIM(COALESCE(p_reason,'')),200),updated_at=NOW()
    WHERE cs.character_id=p_character_id
    RETURNING * INTO v_state;

    RETURN jsonb_build_object(
        'authoritative',TRUE,'action','consume_survival_item','itemName',v_item.item_name,'quantityConsumed',v_qty,'quantityRemaining',GREATEST(0,v_remaining),
        'foodAppliedLb',ROUND(v_food,2),'waterAppliedGallons',ROUND(v_water,3),
        'foodCreditLb',ROUND(v_state.food_credit_lb,2),'waterCreditGallons',ROUND(v_state.water_credit_gal,2),
        'hungerPercent',ROUND(LEAST(100,GREATEST(0,v_state.food_credit_lb*100)),1),
        'thirstPercent',ROUND(LEAST(100,GREATEST(0,v_state.water_credit_gal/v_req*100)),1),
        'hotWeather',v_hot,'exhaustionLevel',v_state.exhaustion_level);
END;
$$;

REVOKE ALL ON FUNCTION public.discord_apply_inventory_valuations(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_survival_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_set_survival_enabled(UUID,UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_survival_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_set_survival_hot_weather(UUID,BOOLEAN,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_advance_survival_time(UUID,TEXT[],NUMERIC,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_consume_survival_item(UUID,UUID,UUID,INTEGER,NUMERIC,NUMERIC,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_apply_inventory_valuations(UUID,UUID,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_survival_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_survival_enabled(UUID,UUID,BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_survival_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_survival_hot_weather(UUID,BOOLEAN,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_advance_survival_time(UUID,TEXT[],NUMERIC,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_consume_survival_item(UUID,UUID,UUID,INTEGER,NUMERIC,NUMERIC,TEXT) TO service_role;

COMMENT ON TABLE public.discord_campaign_survival_settings IS 'Build 6.8 campaign-wide Hunger/Thirst toggle and hot-weather state.';
COMMENT ON TABLE public.discord_character_survival IS 'Build 6.8 per-character food/water credit and survival Exhaustion.';

COMMIT;
