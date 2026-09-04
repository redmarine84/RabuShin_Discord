-- ============================================================
-- RabuShinAIGM Rules Build 6.15
-- Inns, Taverns, Prepared Meals, Drinks, Lifestyle Lodging
-- Requires Build 6.6.1 multi-currency helper and Build 6.8 survival state.
-- Safe to run more than once.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_inn_lodging_bookings
(
    booking_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    settlement_key TEXT NOT NULL,
    poi_key TEXT NOT NULL,
    inn_name TEXT NOT NULL,
    lifestyle TEXT NOT NULL CHECK (lifestyle IN ('Squalid','Poor','Modest','Comfortable','Wealthy','Aristocratic')),
    days_purchased INTEGER NOT NULL CHECK (days_purchased > 0),
    days_remaining INTEGER NOT NULL CHECK (days_remaining >= 0),
    unit_price_gp NUMERIC(12,2) NOT NULL CHECK (unit_price_gp >= 0),
    total_price_gp NUMERIC(12,2) NOT NULL CHECK (total_price_gp >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_discord_inn_lodging_character
ON public.discord_inn_lodging_bookings(character_id, campaign_id, created_at DESC);

ALTER TABLE public.discord_inn_lodging_bookings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_inn_lodging_bookings FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_inn_lodging_bookings TO service_role;

DROP FUNCTION IF EXISTS public.discord_buy_hospitality_service(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT);
CREATE OR REPLACE FUNCTION public.discord_buy_hospitality_service(
    p_player_id UUID,
    p_campaign_id UUID,
    p_settlement_key TEXT,
    p_poi_key TEXT,
    p_service_key TEXT,
    p_service_name TEXT,
    p_service_category TEXT,
    p_quantity INTEGER,
    p_unit_price_gp NUMERIC,
    p_venue_name TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character_id UUID;
    v_location_settlement_key TEXT;
    v_location_poi_key TEXT;
    v_total_price NUMERIC(12,2);
    v_remaining_gold NUMERIC(12,2);
    v_category TEXT := LOWER(TRIM(COALESCE(p_service_category,'')));
    v_key TEXT := LOWER(TRIM(COALESCE(p_service_key,'')));
    v_lifestyle TEXT;
    v_hydration NUMERIC(10,4) := 0;
    v_hunger_before NUMERIC(6,1) := NULL;
    v_hunger_after NUMERIC(6,1) := NULL;
    v_thirst_before NUMERIC(6,1) := NULL;
    v_thirst_after NUMERIC(6,1) := NULL;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members m
        WHERE m.campaign_id = p_campaign_id AND m.player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    IF COALESCE(p_quantity,0) < 1 OR p_quantity > 20 THEN
        RAISE EXCEPTION 'Quantity must be between 1 and 20.';
    END IF;

    IF COALESCE(p_unit_price_gp,0) < 0 OR p_unit_price_gp > 1000000 THEN
        RAISE EXCEPTION 'Invalid hospitality price.';
    END IF;

    IF ABS(p_unit_price_gp - ROUND(p_unit_price_gp,2)) >= 0.000001 THEN
        RAISE EXCEPTION 'Hospitality prices must resolve to whole copper pieces.';
    END IF;

    SELECT l.settlement_key, l.poi_key
    INTO v_location_settlement_key, v_location_poi_key
    FROM public.discord_player_settlement_locations l
    WHERE l.campaign_id = p_campaign_id
      AND l.player_id = p_player_id
    LIMIT 1;

    IF NOT FOUND
       OR LOWER(TRIM(COALESCE(v_location_settlement_key,''))) <> LOWER(TRIM(COALESCE(p_settlement_key,'')))
       OR LOWER(TRIM(COALESCE(v_location_poi_key,''))) <> LOWER(TRIM(COALESCE(p_poi_key,''))) THEN
        RAISE EXCEPTION 'Your character is not at this Inn or Tavern.';
    END IF;

    SELECT c.character_id
    INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id = p_campaign_id
      AND c.player_id = p_player_id
    LIMIT 1
    FOR UPDATE;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    v_total_price := ROUND(p_unit_price_gp * p_quantity,2);
    v_remaining_gold := public.discord_adjust_currency_value(v_character_id, p_campaign_id, -v_total_price);

    INSERT INTO public.discord_character_survival(character_id, campaign_id)
    VALUES(v_character_id, p_campaign_id)
    ON CONFLICT ON CONSTRAINT discord_character_survival_pkey DO NOTHING;

    IF v_category = 'prepared food' THEN
        SELECT ROUND(LEAST(100.0,GREATEST(0.0,cs.food_credit_lb * 100.0)),1)
        INTO v_hunger_before
        FROM public.discord_character_survival cs
        WHERE cs.character_id = v_character_id
        FOR UPDATE;

        UPDATE public.discord_character_survival cs
        SET food_credit_lb = LEAST(1.0, cs.food_credit_lb + (0.33 * p_quantity)),
            food_deficit_hours = 0,
            last_reason = 'Ate prepared food at ' || COALESCE(NULLIF(TRIM(p_venue_name),''),'an Inn'),
            updated_at = NOW()
        WHERE cs.character_id = v_character_id;

        SELECT ROUND(LEAST(100.0,GREATEST(0.0,cs.food_credit_lb * 100.0)),1)
        INTO v_hunger_after
        FROM public.discord_character_survival cs
        WHERE cs.character_id = v_character_id;

    ELSIF v_category = 'drink' THEN
        -- Water is the strongest survival hydration. Alcoholic drinks restore only
        -- a modest amount of Thirst and are not equivalent to a full clean-water serving.
        v_hydration := CASE
            WHEN v_key = 'water' THEN 0.25
            WHEN v_key LIKE '%wine%' THEN 0.05
            ELSE 0.10
        END;

        SELECT ROUND(LEAST(100.0,GREATEST(0.0,cs.water_credit_gal * 100.0)),1)
        INTO v_thirst_before
        FROM public.discord_character_survival cs
        WHERE cs.character_id = v_character_id
        FOR UPDATE;

        UPDATE public.discord_character_survival cs
        SET water_credit_gal = LEAST(1.0, cs.water_credit_gal + (v_hydration * p_quantity)),
            water_deficit_hours = 0,
            last_reason = 'Had a drink at ' || COALESCE(NULLIF(TRIM(p_venue_name),''),'a Tavern'),
            updated_at = NOW()
        WHERE cs.character_id = v_character_id;

        SELECT ROUND(LEAST(100.0,GREATEST(0.0,cs.water_credit_gal * 100.0)),1)
        INTO v_thirst_after
        FROM public.discord_character_survival cs
        WHERE cs.character_id = v_character_id;

    ELSIF v_category = 'room / lifestyle' THEN
        v_lifestyle := CASE v_key
            WHEN 'room-squalid' THEN 'Squalid'
            WHEN 'room-poor' THEN 'Poor'
            WHEN 'room-modest' THEN 'Modest'
            WHEN 'room-comfortable' THEN 'Comfortable'
            WHEN 'room-wealthy' THEN 'Wealthy'
            WHEN 'room-aristocratic' THEN 'Aristocratic'
            ELSE NULL
        END;

        IF v_lifestyle IS NULL THEN
            RAISE EXCEPTION 'Unknown room lifestyle.';
        END IF;

        INSERT INTO public.discord_inn_lodging_bookings(
            character_id, campaign_id, settlement_key, poi_key, inn_name,
            lifestyle, days_purchased, days_remaining, unit_price_gp, total_price_gp)
        VALUES(
            v_character_id, p_campaign_id, p_settlement_key, p_poi_key,
            COALESCE(NULLIF(TRIM(p_venue_name),''),'Inn'), v_lifestyle,
            p_quantity, p_quantity, ROUND(p_unit_price_gp,2), v_total_price);
    ELSE
        RAISE EXCEPTION 'This hospitality service is not recognized.';
    END IF;

    RETURN jsonb_build_object(
        'success', TRUE,
        'service_key', p_service_key,
        'service_name', p_service_name,
        'service_category', p_service_category,
        'quantity_purchased', p_quantity,
        'unit_price_gp', ROUND(p_unit_price_gp,2),
        'total_price_gp', v_total_price,
        'remaining_gold', v_remaining_gold,
        'hunger_before', v_hunger_before,
        'hunger_after', v_hunger_after,
        'thirst_before', v_thirst_before,
        'thirst_after', v_thirst_after,
        'message', CASE
            WHEN v_category = 'prepared food' THEN p_service_name || ' was served and eaten.'
            WHEN v_category = 'drink' THEN p_service_name || ' was served.'
            WHEN v_category = 'room / lifestyle' THEN p_quantity::TEXT || ' day(s) of ' || v_lifestyle || ' lodging reserved at ' || COALESCE(NULLIF(TRIM(p_venue_name),''),'the Inn') || '.'
            ELSE 'Purchase completed.'
        END
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_buy_hospitality_service(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discord_buy_hospitality_service(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT)
TO service_role;

COMMIT;
