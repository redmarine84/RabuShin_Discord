-- RabuShinAIGM Rules Build 6.7.1
-- Interrupted combat setup recovery
-- Run after Build 6.3.3 / migration 20.
-- Safe to run while the campaign is stuck at "Waiting for GM" before initiative.

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_gm_start_combat(
    p_campaign_id UUID,
    p_title TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_title TEXT := LEFT(TRIM(COALESCE(p_title,'')),160);
    v_location TEXT;
    v_location_key TEXT;
    v_active BOOLEAN := FALSE;
    v_existing_title TEXT := '';
    v_current_turn_type TEXT := '';
    v_current_turn_character_id UUID;
    v_current_turn_monster_id UUID;
    v_has_initiative BOOLEAN := FALSE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.is_active=TRUE
    ) THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    SELECT COALESCE(s.active,FALSE), COALESCE(s.title,''),
           COALESCE(s.current_turn_type,''),
           s.current_turn_character_id, s.current_turn_monster_id
    INTO v_active, v_existing_title, v_current_turn_type,
         v_current_turn_character_id, v_current_turn_monster_id
    FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id;

    SELECT EXISTS(
        SELECT 1
        FROM public.discord_campaign_combat_initiative i
        WHERE i.campaign_id=p_campaign_id
    ) INTO v_has_initiative;

    IF COALESCE(v_active,FALSE)=TRUE THEN
        IF COALESCE(v_has_initiative,FALSE)=FALSE
           AND TRIM(COALESCE(v_current_turn_type,''))=''
           AND v_current_turn_character_id IS NULL
           AND v_current_turn_monster_id IS NULL THEN
            IF v_title<>'' AND COALESCE(v_existing_title,'')='' THEN
                UPDATE public.discord_campaign_combat_state
                SET title=v_title, updated_at=NOW()
                WHERE campaign_id=p_campaign_id;
                v_existing_title := v_title;
            END IF;
            RETURN COALESCE(NULLIF(v_existing_title,''), NULLIF(v_title,''), 'Combat Encounter');
        END IF;
        RAISE EXCEPTION 'Combat is already active.';
    END IF;

    IF v_title='' THEN v_title := 'Combat Encounter'; END IF;

    DELETE FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=p_campaign_id;
    DELETE FROM public.discord_campaign_combat_tokens t WHERE t.campaign_id=p_campaign_id;
    DELETE FROM public.discord_campaign_combat_monsters m WHERE m.campaign_id=p_campaign_id;

    INSERT INTO public.discord_campaign_combat_state(
        campaign_id,active,title,round_number,started_at,
        current_turn_type,current_turn_character_id,current_turn_monster_id,
        turn_started_at,updated_at)
    VALUES(
        p_campaign_id,TRUE,v_title,1,NOW(),
        '',NULL,NULL,NULL,NOW())
    ON CONFLICT ON CONSTRAINT discord_campaign_combat_state_pkey DO UPDATE SET
        active=TRUE,
        title=EXCLUDED.title,
        round_number=1,
        started_at=NOW(),
        current_turn_type='',
        current_turn_character_id=NULL,
        current_turn_monster_id=NULL,
        turn_started_at=NULL,
        updated_at=NOW();

    SELECT c.current_location
    INTO v_location
    FROM public.discord_campaigns c
    WHERE c.campaign_id=p_campaign_id;

    SELECT r.location_key
    INTO v_location_key
    FROM public.discord_world_map_resolve_location(v_location) r;

    IF v_location_key IS NOT NULL THEN
        INSERT INTO public.discord_campaign_local_map_state(
            campaign_id,encounter_active,encounter_location_key,
            encounter_reason,activated_at,updated_at)
        VALUES(p_campaign_id,TRUE,v_location_key,v_title,NOW(),NOW())
        ON CONFLICT ON CONSTRAINT discord_campaign_local_map_state_pkey DO UPDATE SET
            encounter_active=TRUE,
            encounter_location_key=EXCLUDED.encounter_location_key,
            encounter_reason=EXCLUDED.encounter_reason,
            activated_at=NOW(),
            updated_at=NOW();
    END IF;

    RETURN v_title;
END;
$$;

UPDATE public.discord_campaign_combat_state s
SET current_turn_type='',
    current_turn_character_id=NULL,
    current_turn_monster_id=NULL,
    turn_started_at=NULL,
    updated_at=NOW()
WHERE s.active=TRUE
  AND NOT EXISTS (
      SELECT 1 FROM public.discord_campaign_combat_initiative i
      WHERE i.campaign_id=s.campaign_id
  );

REVOKE ALL ON FUNCTION public.discord_gm_start_combat(UUID,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_gm_start_combat(UUID,TEXT) TO service_role;

COMMIT;
