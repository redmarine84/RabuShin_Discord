-- RabuShinAIGM Rules Build 6.14.2
-- Respawn donation flow fix:
--   * Only currently active campaign players are prompted/count as donors.
--   * Donor Yes is persisted before donating.
--   * Donations are exactly 1 GP per click/server transaction.
--   * The shared fund can never exceed the 10 GP requirement.
--   * When the fund reaches the requirement, it waits for explicit Respawn.
-- Requires Build 6.2.2 campaign presence (discord_campaign_presence).

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_respawn_player_is_active(
    p_campaign_id UUID,
    p_player_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT EXISTS(
        SELECT 1
        FROM public.discord_campaign_members cm
        JOIN public.discord_campaign_presence pr
          ON pr.campaign_id=cm.campaign_id
         AND pr.player_id=cm.player_id
        WHERE cm.campaign_id=p_campaign_id
          AND cm.player_id=p_player_id
          AND pr.last_seen_at >= NOW() - INTERVAL '15 seconds'
    );
$$;

-- Use only active living party members when deciding whether the party can still
-- fund the Respawn. Existing GP already donated remains in the shared fund even
-- if its donor later disconnects.
CREATE OR REPLACE FUNCTION public.discord_maybe_apply_rag_respawn(p_death_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
    v_eligible INTEGER := 0;
    v_answered INTEGER := 0;
    v_donated INTEGER := 0;
    v_potential INTEGER := 0;
BEGIN
    SELECT * INTO v_death FROM public.discord_character_deaths
    WHERE death_id=p_death_id AND status='awaiting_donations';
    IF v_death.death_id IS NULL THEN RETURN NULL; END IF;

    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_donated
    FROM public.discord_death_donations WHERE death_id=p_death_id;
    IF v_donated>=v_death.required_gp THEN RETURN NULL; END IF;

    SELECT COUNT(*)::INTEGER INTO v_eligible
    FROM public.discord_characters c
    JOIN public.discord_campaign_members cm
      ON cm.campaign_id=c.campaign_id AND cm.player_id=c.player_id
    JOIN public.discord_campaign_presence pr
      ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE c.campaign_id=v_death.campaign_id
      AND c.player_id<>v_death.player_id
      AND c.life_state='alive'
      AND pr.last_seen_at >= NOW() - INTERVAL '15 seconds';

    IF v_eligible=0 THEN RETURN public.discord_apply_rag_respawn(p_death_id); END IF;

    SELECT COUNT(*)::INTEGER INTO v_answered
    FROM public.discord_death_donor_decisions dd
    JOIN public.discord_characters c
      ON c.player_id=dd.player_id AND c.campaign_id=v_death.campaign_id
    JOIN public.discord_campaign_presence pr
      ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE dd.death_id=p_death_id
      AND c.life_state='alive'
      AND c.player_id<>v_death.player_id
      AND pr.last_seen_at >= NOW() - INTERVAL '15 seconds';

    IF v_answered<v_eligible THEN RETURN NULL; END IF;

    SELECT v_donated + COALESCE(SUM(FLOOR(GREATEST(c.gold,0))::INTEGER),0)
    INTO v_potential
    FROM public.discord_characters c
    JOIN public.discord_death_donor_decisions dd
      ON dd.player_id=c.player_id AND dd.death_id=p_death_id
    JOIN public.discord_campaign_presence pr
      ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
    WHERE c.campaign_id=v_death.campaign_id
      AND c.life_state='alive'
      AND c.player_id<>v_death.player_id
      AND dd.decision='donate'
      AND pr.last_seen_at >= NOW() - INTERVAL '15 seconds';

    IF COALESCE(v_potential,v_donated)<v_death.required_gp THEN
        RETURN public.discord_apply_rag_respawn(p_death_id);
    END IF;
    RETURN NULL;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_death_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_death_state(p_player_id UUID,p_campaign_id UUID)
RETURNS TABLE(
    death_id UUID,dead_player_id UUID,dead_character_name TEXT,status TEXT,required_gp INTEGER,
    donated_gp INTEGER,remaining_gp INTEGER,viewer_is_dead_player BOOLEAN,viewer_is_eligible_donor BOOLEAN,
    viewer_decision TEXT,viewer_donated_gp INTEGER,viewer_gold NUMERIC,dead_character_gold NUMERIC,
    eligible_donor_count INTEGER,answered_donor_count INTEGER,can_finalize BOOLEAN,cause TEXT,created_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members cm WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    SELECT * INTO v_death FROM public.discord_character_deaths d
    WHERE d.campaign_id=p_campaign_id
      AND d.status<>'resolved'
      AND (
        d.player_id=p_player_id
        OR (
            d.status='awaiting_donations'
            AND public.discord_respawn_player_is_active(p_campaign_id,p_player_id)
            AND EXISTS(
                SELECT 1 FROM public.discord_characters vc
                WHERE vc.campaign_id=p_campaign_id
                  AND vc.player_id=p_player_id
                  AND vc.life_state='alive'
                  AND vc.player_id<>d.player_id
            )
        )
      )
    ORDER BY CASE WHEN d.player_id=p_player_id THEN 0 ELSE 1 END, d.created_at ASC
    LIMIT 1;

    IF v_death.death_id IS NULL THEN RETURN; END IF;

    RETURN QUERY
    SELECT v_death.death_id,v_death.player_id,v_death.character_name,v_death.status,v_death.required_gp,
        COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id),0),
        GREATEST(0,v_death.required_gp-COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id),0)),
        p_player_id=v_death.player_id,
        (
            public.discord_respawn_player_is_active(p_campaign_id,p_player_id)
            AND EXISTS(
                SELECT 1 FROM public.discord_characters vc
                WHERE vc.campaign_id=p_campaign_id
                  AND vc.player_id=p_player_id
                  AND vc.life_state='alive'
                  AND vc.player_id<>v_death.player_id
            )
        ),
        COALESCE((SELECT dd.decision FROM public.discord_death_donor_decisions dd WHERE dd.death_id=v_death.death_id AND dd.player_id=p_player_id),''),
        COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id AND x.donor_player_id=p_player_id),0),
        COALESCE((SELECT vc.gold FROM public.discord_characters vc WHERE vc.campaign_id=p_campaign_id AND vc.player_id=p_player_id),0),
        COALESCE((SELECT dc.gold FROM public.discord_characters dc WHERE dc.character_id=v_death.character_id),0),
        (
            SELECT COUNT(*)::INTEGER
            FROM public.discord_characters c
            JOIN public.discord_campaign_presence pr
              ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
            WHERE c.campaign_id=p_campaign_id
              AND c.player_id<>v_death.player_id
              AND c.life_state='alive'
              AND pr.last_seen_at >= NOW() - INTERVAL '15 seconds'
        ),
        (
            SELECT COUNT(*)::INTEGER
            FROM public.discord_death_donor_decisions dd
            JOIN public.discord_characters c
              ON c.player_id=dd.player_id AND c.campaign_id=p_campaign_id
            JOIN public.discord_campaign_presence pr
              ON pr.campaign_id=c.campaign_id AND pr.player_id=c.player_id
            WHERE dd.death_id=v_death.death_id
              AND c.player_id<>v_death.player_id
              AND c.life_state='alive'
              AND pr.last_seen_at >= NOW() - INTERVAL '15 seconds'
        ),
        COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id),0)>=v_death.required_gp,
        v_death.cause,v_death.created_at;
END;
$$;

-- Persist the donor's Yes before showing the 1 GP donation button.
DROP FUNCTION IF EXISTS public.discord_accept_respawn_donation(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_accept_respawn_donation(
    p_player_id UUID,p_campaign_id UUID,p_death_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
    v_donor public.discord_characters%ROWTYPE;
    v_total INTEGER;
BEGIN
    SELECT * INTO v_death FROM public.discord_character_deaths d
    WHERE d.death_id=p_death_id AND d.campaign_id=p_campaign_id AND d.status='awaiting_donations' FOR UPDATE;
    IF v_death.death_id IS NULL THEN RAISE EXCEPTION 'That Respawn fund is no longer open.'; END IF;
    IF p_player_id=v_death.player_id THEN RAISE EXCEPTION 'The dead player cannot donate to their own Respawn fund.'; END IF;
    IF NOT public.discord_respawn_player_is_active(p_campaign_id,p_player_id) THEN
        RAISE EXCEPTION 'Only an active campaign player can answer this donation request.';
    END IF;

    SELECT * INTO v_donor FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id AND c.life_state='alive' FOR UPDATE;
    IF v_donor.character_id IS NULL THEN RAISE EXCEPTION 'Only a living party character can donate.'; END IF;
    IF COALESCE(v_donor.gold,0)<1 THEN RAISE EXCEPTION '% does not have 1 GP available to donate.',v_donor.character_name; END IF;

    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_total
    FROM public.discord_death_donations WHERE death_id=p_death_id;
    IF v_total>=v_death.required_gp THEN
        RETURN jsonb_build_object('outcome','funded','character_name',v_death.character_name,'donated_gp',v_total,'remaining_gp',0,'can_finalize',TRUE);
    END IF;

    INSERT INTO public.discord_death_donor_decisions(death_id,player_id,decision)
    VALUES(p_death_id,p_player_id,'donate')
    ON CONFLICT(death_id,player_id) DO UPDATE SET decision='donate',updated_at=NOW();

    RETURN jsonb_build_object(
        'outcome','accepted',
        'character_name',v_death.character_name,
        'donor_character_name',v_donor.character_name,
        'donated_gp',v_total,
        'remaining_gp',GREATEST(0,v_death.required_gp-v_total),
        'can_finalize',v_total>=v_death.required_gp);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_donate_to_respawn(UUID,UUID,UUID,INTEGER);
CREATE OR REPLACE FUNCTION public.discord_donate_to_respawn(
    p_player_id UUID,p_campaign_id UUID,p_death_id UUID,p_amount_gp INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
    v_donor public.discord_characters%ROWTYPE;
    v_total INTEGER;
    v_remaining INTEGER;
    v_rag JSONB;
    v_decision TEXT;
BEGIN
    -- This row lock serializes simultaneous donation clicks from different players.
    SELECT * INTO v_death FROM public.discord_character_deaths d
    WHERE d.death_id=p_death_id AND d.campaign_id=p_campaign_id AND d.status='awaiting_donations' FOR UPDATE;
    IF v_death.death_id IS NULL THEN RAISE EXCEPTION 'That Respawn fund is no longer open.'; END IF;
    IF p_player_id=v_death.player_id THEN RAISE EXCEPTION 'The dead character cannot donate to their own Respawn fund.'; END IF;
    IF COALESCE(p_amount_gp,0)<>1 THEN RAISE EXCEPTION 'Respawn donations are exactly 1 GP at a time.'; END IF;
    IF NOT public.discord_respawn_player_is_active(p_campaign_id,p_player_id) THEN
        RAISE EXCEPTION 'Only an active campaign player can donate.';
    END IF;

    SELECT * INTO v_donor FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id AND c.life_state='alive' FOR UPDATE;
    IF v_donor.character_id IS NULL THEN RAISE EXCEPTION 'Only a living party character can donate.'; END IF;

    SELECT dd.decision INTO v_decision
    FROM public.discord_death_donor_decisions dd
    WHERE dd.death_id=p_death_id AND dd.player_id=p_player_id;
    IF COALESCE(v_decision,'')<>'donate' THEN
        RAISE EXCEPTION 'Choose Yes before donating to this Respawn fund.';
    END IF;

    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_total
    FROM public.discord_death_donations WHERE death_id=p_death_id;
    v_remaining:=GREATEST(0,v_death.required_gp-v_total);
    IF v_remaining<=0 THEN RAISE EXCEPTION 'The Respawn fund already has enough GP. Click Respawn %.',v_death.character_name; END IF;
    IF COALESCE(v_donor.gold,0)<1 THEN RAISE EXCEPTION '% does not have 1 GP available.',v_donor.character_name; END IF;

    UPDATE public.discord_characters c
    SET gold=c.gold-1,
        character_data=COALESCE(c.character_data,'{}'::jsonb) || jsonb_build_object('gold',c.gold-1),
        updated_at=NOW()
    WHERE c.character_id=v_donor.character_id;

    INSERT INTO public.discord_death_donations(death_id,donor_player_id,amount_gp)
    VALUES(p_death_id,p_player_id,1);

    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_total
    FROM public.discord_death_donations WHERE death_id=p_death_id;

    -- Never auto-finalize a fully funded Respawn. The explicit Respawn {name}
    -- button remains the final action.
    IF v_total<v_death.required_gp THEN
        v_rag:=public.discord_maybe_apply_rag_respawn(p_death_id);
        IF v_rag IS NOT NULL THEN RETURN v_rag; END IF;
    END IF;

    RETURN jsonb_build_object(
        'outcome','donated',
        'donor_character_name',v_donor.character_name,
        'donated_now',1,
        'donated_gp',LEAST(v_total,v_death.required_gp),
        'remaining_gp',GREATEST(0,v_death.required_gp-v_total),
        'can_finalize',v_total>=v_death.required_gp,
        'remaining_gold',GREATEST(0,COALESCE(v_donor.gold,0)-1));
END;
$$;

DROP FUNCTION IF EXISTS public.discord_decline_respawn_donation(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_decline_respawn_donation(p_player_id UUID,p_campaign_id UUID,p_death_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
    v_existing INTEGER;
    v_rag JSONB;
BEGIN
    SELECT * INTO v_death FROM public.discord_character_deaths d
    WHERE d.death_id=p_death_id AND d.campaign_id=p_campaign_id AND d.status='awaiting_donations' FOR UPDATE;
    IF v_death.death_id IS NULL THEN RAISE EXCEPTION 'That Respawn fund is no longer open.'; END IF;
    IF p_player_id=v_death.player_id THEN RAISE EXCEPTION 'The dead player cannot answer the party donation prompt.'; END IF;
    IF NOT public.discord_respawn_player_is_active(p_campaign_id,p_player_id) THEN
        RAISE EXCEPTION 'Only an active campaign player can answer this donation request.';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id AND c.life_state='alive') THEN
        RAISE EXCEPTION 'Only a living party character can answer this prompt.';
    END IF;

    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_existing
    FROM public.discord_death_donations
    WHERE death_id=p_death_id AND donor_player_id=p_player_id;
    IF v_existing>0 THEN RAISE EXCEPTION 'You already donated to this Respawn fund.'; END IF;

    INSERT INTO public.discord_death_donor_decisions(death_id,player_id,decision)
    VALUES(p_death_id,p_player_id,'decline')
    ON CONFLICT(death_id,player_id) DO UPDATE SET decision='decline',updated_at=NOW();

    v_rag:=public.discord_maybe_apply_rag_respawn(p_death_id);
    IF v_rag IS NOT NULL THEN RETURN v_rag; END IF;
    RETURN jsonb_build_object('outcome','declined');
END;
$$;

REVOKE ALL ON FUNCTION public.discord_respawn_player_is_active(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_death_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_accept_respawn_donation(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_donate_to_respawn(UUID,UUID,UUID,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_decline_respawn_donation(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_respawn_player_is_active(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_death_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_accept_respawn_donation(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_donate_to_respawn(UUID,UUID,UUID,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_decline_respawn_donation(UUID,UUID,UUID) TO service_role;

COMMIT;
