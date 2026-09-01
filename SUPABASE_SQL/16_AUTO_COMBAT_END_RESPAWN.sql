-- RabuShinAIGM Discord Build 6.2
-- Automatic combat completion + server-authoritative death / respawn / donation workflow.
-- Run AFTER the Character Features migration and Combat Build 6.1 migration.

BEGIN;

-- -----------------------------------------------------------------------------
-- Combat disposition + character life state
-- -----------------------------------------------------------------------------
ALTER TABLE public.discord_campaign_combat_monsters
    ADD COLUMN IF NOT EXISTS disposition TEXT NOT NULL DEFAULT 'hostile';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname='ck_discord_combat_monster_disposition'
          AND conrelid='public.discord_campaign_combat_monsters'::regclass
    ) THEN
        ALTER TABLE public.discord_campaign_combat_monsters
        ADD CONSTRAINT ck_discord_combat_monster_disposition
        CHECK (disposition IN ('hostile','defeated','fled','nonhostile','surrendered'));
    END IF;
END $$;

UPDATE public.discord_campaign_combat_monsters
SET disposition='defeated'
WHERE defeated=TRUE OR current_hp<=0;

ALTER TABLE public.discord_characters
    ADD COLUMN IF NOT EXISTS life_state TEXT NOT NULL DEFAULT 'alive';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname='ck_discord_character_life_state'
          AND conrelid='public.discord_characters'::regclass
    ) THEN
        ALTER TABLE public.discord_characters
        ADD CONSTRAINT ck_discord_character_life_state
        CHECK (life_state IN ('alive','dead'));
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Death / respawn persistence
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discord_character_deaths (
    death_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    character_id UUID NULL REFERENCES public.discord_characters(character_id) ON DELETE SET NULL,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    character_name TEXT NOT NULL,
    max_hp INTEGER NOT NULL DEFAULT 1,
    cause TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'awaiting_choice'
        CHECK (status IN ('awaiting_choice','awaiting_donations','resolved')),
    resolution TEXT NOT NULL DEFAULT '',
    required_gp INTEGER NOT NULL DEFAULT 10 CHECK (required_gp > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_character_death_active
ON public.discord_character_deaths(campaign_id, player_id)
WHERE status <> 'resolved';

CREATE INDEX IF NOT EXISTS ix_discord_character_deaths_campaign
ON public.discord_character_deaths(campaign_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.discord_death_donations (
    donation_id BIGSERIAL PRIMARY KEY,
    death_id UUID NOT NULL REFERENCES public.discord_character_deaths(death_id) ON DELETE CASCADE,
    donor_player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    amount_gp INTEGER NOT NULL CHECK (amount_gp > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS ix_discord_death_donations_death
ON public.discord_death_donations(death_id, created_at);

CREATE TABLE IF NOT EXISTS public.discord_death_donor_decisions (
    death_id UUID NOT NULL REFERENCES public.discord_character_deaths(death_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    decision TEXT NOT NULL CHECK (decision IN ('donate','decline')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (death_id, player_id)
);

CREATE TABLE IF NOT EXISTS public.discord_character_graveyard (
    grave_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    original_character_id UUID NOT NULL,
    character_name TEXT NOT NULL,
    death_id UUID NULL REFERENCES public.discord_character_deaths(death_id) ON DELETE SET NULL,
    cause TEXT NOT NULL DEFAULT '',
    character_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    inventory_snapshot JSONB NOT NULL DEFAULT '[]'::jsonb,
    spells_snapshot JSONB NOT NULL DEFAULT '[]'::jsonb,
    slots_snapshot JSONB NOT NULL DEFAULT '[]'::jsonb,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.discord_character_deaths ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_death_donations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_death_donor_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_character_graveyard ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_character_deaths, public.discord_death_donations,
    public.discord_death_donor_decisions, public.discord_character_graveyard FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_character_deaths, public.discord_death_donations,
    public.discord_death_donor_decisions, public.discord_character_graveyard TO service_role;

-- -----------------------------------------------------------------------------
-- Internal helpers for respawn money handling
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discord_refund_death_donations(p_death_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_campaign UUID;
    v_row RECORD;
    v_refunded INTEGER := 0;
BEGIN
    SELECT d.campaign_id INTO v_campaign
    FROM public.discord_character_deaths d WHERE d.death_id=p_death_id;
    IF v_campaign IS NULL THEN RETURN 0; END IF;

    FOR v_row IN
        SELECT donor_player_id, SUM(amount_gp)::INTEGER AS amount
        FROM public.discord_death_donations
        WHERE death_id=p_death_id
        GROUP BY donor_player_id
    LOOP
        UPDATE public.discord_characters c
        SET gold=COALESCE(c.gold,0)+v_row.amount,
            character_data=COALESCE(c.character_data,'{}'::jsonb) ||
                jsonb_build_object('gold',COALESCE(c.gold,0)+v_row.amount),
            updated_at=NOW()
        WHERE c.campaign_id=v_campaign AND c.player_id=v_row.donor_player_id
          AND c.life_state='alive';
        v_refunded:=v_refunded+v_row.amount;
    END LOOP;

    DELETE FROM public.discord_death_donations WHERE death_id=p_death_id;
    RETURN v_refunded;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_apply_rag_respawn(p_death_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
    v_character public.discord_characters%ROWTYPE;
    v_hp INTEGER;
    v_refunded INTEGER;
BEGIN
    SELECT * INTO v_death FROM public.discord_character_deaths
    WHERE death_id=p_death_id AND status='awaiting_donations' FOR UPDATE;
    IF v_death.death_id IS NULL THEN
        RAISE EXCEPTION 'That death is not awaiting party donations.';
    END IF;

    SELECT * INTO v_character FROM public.discord_characters
    WHERE character_id=v_death.character_id AND campaign_id=v_death.campaign_id FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Dead character could not be found.'; END IF;

    v_refunded:=public.discord_refund_death_donations(p_death_id);
    DELETE FROM public.discord_inventory_items WHERE character_id=v_character.character_id;
    INSERT INTO public.discord_inventory_items(
        character_id,item_name,quantity,equipped,attuned,source_name,notes,item_data)
    VALUES(
        v_character.character_id,'Cloth Rags',1,TRUE,FALSE,'Respawn',
        'All previous carried and equipped possessions were lost during unpaid respawn.',
        jsonb_build_object('name','Cloth Rags','description','Simple cloth rags provided after an unpaid respawn.'));

    v_hp:=GREATEST(1,FLOOR(COALESCE(v_character.max_hp,1)/2.0)::INTEGER);
    UPDATE public.discord_characters c
    SET gold=0,current_hp=v_hp,life_state='alive',
        character_data=COALESCE(c.character_data,'{}'::jsonb) ||
            jsonb_build_object('gold',0,'current_hp',v_hp,'lifeState','alive'),
        updated_at=NOW()
    WHERE c.character_id=v_character.character_id;

    UPDATE public.discord_character_deaths
    SET status='resolved',resolution='rag_respawn',resolved_at=NOW()
    WHERE death_id=p_death_id;

    RETURN jsonb_build_object(
        'outcome','rag_respawn','character_name',v_character.character_name,
        'current_hp',v_hp,'max_hp',v_character.max_hp,'gold',0,'refunded_gp',v_refunded);
END;
$$;

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

    SELECT COUNT(*) INTO v_eligible
    FROM public.discord_characters c
    JOIN public.discord_campaign_members cm ON cm.campaign_id=c.campaign_id AND cm.player_id=c.player_id
    WHERE c.campaign_id=v_death.campaign_id
      AND c.player_id<>v_death.player_id
      AND c.life_state='alive';

    IF v_eligible=0 THEN RETURN public.discord_apply_rag_respawn(p_death_id); END IF;

    SELECT COUNT(*) INTO v_answered
    FROM public.discord_death_donor_decisions dd
    JOIN public.discord_characters c ON c.player_id=dd.player_id AND c.campaign_id=v_death.campaign_id
    WHERE dd.death_id=p_death_id AND c.life_state='alive' AND c.player_id<>v_death.player_id;

    IF v_answered<v_eligible THEN RETURN NULL; END IF;

    SELECT v_donated + COALESCE(SUM(FLOOR(GREATEST(c.gold,0))::INTEGER),0)
    INTO v_potential
    FROM public.discord_characters c
    JOIN public.discord_death_donor_decisions dd ON dd.player_id=c.player_id AND dd.death_id=p_death_id
    WHERE c.campaign_id=v_death.campaign_id
      AND c.life_state='alive'
      AND c.player_id<>v_death.player_id
      AND dd.decision='donate';

    IF COALESCE(v_potential,v_donated)<v_death.required_gp THEN
        RETURN public.discord_apply_rag_respawn(p_death_id);
    END IF;
    RETURN NULL;
END;
$$;

-- -----------------------------------------------------------------------------
-- Authoritative character death / normal D&D revival tools
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_mark_character_dead(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_mark_character_dead(
    p_campaign_id UUID,p_character_name TEXT,p_cause TEXT DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_death UUID;
    v_advanced JSONB := NULL;
BEGIN
    SELECT * INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Party character not found: %',p_character_name; END IF;

    SELECT d.death_id INTO v_death FROM public.discord_character_deaths d
    WHERE d.campaign_id=p_campaign_id AND d.player_id=v_character.player_id AND d.status<>'resolved'
    LIMIT 1;
    IF v_death IS NULL THEN
        INSERT INTO public.discord_character_deaths(
            campaign_id,character_id,player_id,character_name,max_hp,cause,status,required_gp)
        VALUES(p_campaign_id,v_character.character_id,v_character.player_id,v_character.character_name,
            GREATEST(1,v_character.max_hp),LEFT(COALESCE(p_cause,''),500),'awaiting_choice',10)
        RETURNING death_id INTO v_death;
    END IF;

    UPDATE public.discord_characters c
    SET current_hp=0,life_state='dead',
        character_data=COALESCE(c.character_data,'{}'::jsonb) || jsonb_build_object('current_hp',0,'lifeState','dead'),
        updated_at=NOW()
    WHERE c.character_id=v_character.character_id;

    -- A total-party death ends the fight. Otherwise, if the character died on their own
    -- active initiative turn, immediately move past them without requiring End Turn.
    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE)
       AND NOT EXISTS(SELECT 1 FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id AND c.life_state='alive') THEN
        PERFORM public.discord_gm_end_combat(p_campaign_id,'All player characters are dead.');
        v_advanced:=jsonb_build_object('combat_ended',TRUE,'reason','All player characters are dead.');
    ELSIF EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id AND s.active=TRUE
          AND s.current_turn_type='character' AND s.current_turn_character_id=v_character.character_id
    ) AND EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=p_campaign_id
    ) THEN
        v_advanced:=public.discord_advance_combat_turn_internal(p_campaign_id,v_character.character_name || ' died',TRUE);
    END IF;

    DELETE FROM public.discord_campaign_combat_tokens
    WHERE campaign_id=p_campaign_id AND character_id=v_character.character_id;

    RETURN jsonb_build_object(
        'death_id',v_death,'character_id',v_character.character_id,'character_name',v_character.character_name,
        'life_state','dead','cause',LEFT(COALESCE(p_cause,''),500),'combat_advanced',v_advanced);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_revive_character(UUID,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_revive_character(
    p_campaign_id UUID,p_character_name TEXT,p_hit_points INTEGER DEFAULT 1,p_reason TEXT DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_death UUID;
    v_hp INTEGER;
    v_refunded INTEGER := 0;
BEGIN
    SELECT * INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Party character not found: %',p_character_name; END IF;
    IF v_character.life_state<>'dead' THEN RAISE EXCEPTION '% is not dead.',v_character.character_name; END IF;

    SELECT d.death_id INTO v_death FROM public.discord_character_deaths d
    WHERE d.campaign_id=p_campaign_id AND d.player_id=v_character.player_id AND d.status<>'resolved'
    ORDER BY d.created_at DESC LIMIT 1 FOR UPDATE;
    IF v_death IS NULL THEN RAISE EXCEPTION 'No active death record exists for %.',v_character.character_name; END IF;

    v_refunded:=public.discord_refund_death_donations(v_death);
    v_hp:=LEAST(GREATEST(1,COALESCE(p_hit_points,1)),GREATEST(1,v_character.max_hp));
    UPDATE public.discord_characters c
    SET current_hp=v_hp,life_state='alive',
        character_data=COALESCE(c.character_data,'{}'::jsonb) || jsonb_build_object('current_hp',v_hp,'lifeState','alive'),
        updated_at=NOW()
    WHERE c.character_id=v_character.character_id;
    UPDATE public.discord_character_deaths
    SET status='resolved',resolution='rules_revival',resolved_at=NOW()
    WHERE death_id=v_death;

    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        PERFORM public.discord_sync_tactical_tokens(p_campaign_id);
    END IF;

    RETURN jsonb_build_object('character_name',v_character.character_name,'current_hp',v_hp,'max_hp',v_character.max_hp,
        'resolution','rules_revival','reason',LEFT(COALESCE(p_reason,''),500),'refunded_gp',v_refunded);
END;
$$;

-- Healing a truly dead character is not a substitute for a revival effect.
DROP FUNCTION IF EXISTS public.discord_gm_adjust_character_hp(UUID, TEXT, INTEGER, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_adjust_character_hp(
    p_campaign_id UUID,p_character_name TEXT,p_hp_delta INTEGER,p_reason TEXT DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_new_hp INTEGER;
BEGIN
    SELECT c.* INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,''))) LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Party character not found: %',p_character_name; END IF;
    IF v_character.life_state='dead' AND COALESCE(p_hp_delta,0)>0 THEN
        RAISE EXCEPTION '% is dead. Normal healing cannot revive them; use a valid revival effect or the respawn system.',v_character.character_name;
    END IF;
    v_new_hp:=LEAST(COALESCE(v_character.max_hp,1),GREATEST(0,COALESCE(v_character.current_hp,0)+COALESCE(p_hp_delta,0)));
    UPDATE public.discord_characters c SET current_hp=v_new_hp,
        character_data=COALESCE(c.character_data,'{}'::jsonb) || jsonb_build_object('current_hp',v_new_hp),updated_at=NOW()
    WHERE c.character_id=v_character.character_id;
    RETURN jsonb_build_object('character_id',v_character.character_id,'character_name',v_character.character_name,
        'current_hp',v_new_hp,'max_hp',v_character.max_hp,'hp_delta',COALESCE(p_hp_delta,0),
        'life_state',v_character.life_state,'reason',LEFT(TRIM(COALESCE(p_reason,'')),160));
END;
$$;

-- -----------------------------------------------------------------------------
-- Player-facing death state and respawn decisions
-- -----------------------------------------------------------------------------
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
    WHERE d.campaign_id=p_campaign_id AND d.status<>'resolved'
      AND (d.player_id=p_player_id OR d.status='awaiting_donations')
    ORDER BY CASE WHEN d.player_id=p_player_id THEN 0 ELSE 1 END, d.created_at ASC
    LIMIT 1;
    IF v_death.death_id IS NULL THEN RETURN; END IF;

    RETURN QUERY
    SELECT v_death.death_id,v_death.player_id,v_death.character_name,v_death.status,v_death.required_gp,
        COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id),0),
        GREATEST(0,v_death.required_gp-COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id),0)),
        p_player_id=v_death.player_id,
        EXISTS(SELECT 1 FROM public.discord_characters vc WHERE vc.campaign_id=p_campaign_id AND vc.player_id=p_player_id AND vc.life_state='alive' AND vc.player_id<>v_death.player_id),
        COALESCE((SELECT dd.decision FROM public.discord_death_donor_decisions dd WHERE dd.death_id=v_death.death_id AND dd.player_id=p_player_id),''),
        COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id AND x.donor_player_id=p_player_id),0),
        COALESCE((SELECT vc.gold FROM public.discord_characters vc WHERE vc.campaign_id=p_campaign_id AND vc.player_id=p_player_id),0),
        COALESCE((SELECT dc.gold FROM public.discord_characters dc WHERE dc.character_id=v_death.character_id),0),
        (SELECT COUNT(*)::INTEGER FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id AND c.player_id<>v_death.player_id AND c.life_state='alive'),
        (SELECT COUNT(*)::INTEGER FROM public.discord_death_donor_decisions dd JOIN public.discord_characters c ON c.player_id=dd.player_id AND c.campaign_id=p_campaign_id WHERE dd.death_id=v_death.death_id AND c.player_id<>v_death.player_id AND c.life_state='alive'),
        COALESCE((SELECT SUM(x.amount_gp)::INTEGER FROM public.discord_death_donations x WHERE x.death_id=v_death.death_id),0)>=v_death.required_gp,
        v_death.cause,v_death.created_at;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_choose_respawn(UUID,UUID,BOOLEAN);
CREATE OR REPLACE FUNCTION public.discord_choose_respawn(p_player_id UUID,p_campaign_id UUID,p_respawn BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
    v_character public.discord_characters%ROWTYPE;
    v_hp INTEGER;
    v_inventory JSONB;
    v_spells JSONB;
    v_slots JSONB;
    v_rag JSONB;
BEGIN
    SELECT * INTO v_death FROM public.discord_character_deaths d
    WHERE d.campaign_id=p_campaign_id AND d.player_id=p_player_id AND d.status='awaiting_choice'
    ORDER BY d.created_at DESC LIMIT 1 FOR UPDATE;
    IF v_death.death_id IS NULL THEN RAISE EXCEPTION 'No respawn decision is currently waiting for you.'; END IF;

    SELECT * INTO v_character FROM public.discord_characters c
    WHERE c.character_id=v_death.character_id AND c.player_id=p_player_id FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Dead character could not be found.'; END IF;

    IF NOT COALESCE(p_respawn,FALSE) THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(i)),'[]'::jsonb) INTO v_inventory FROM public.discord_inventory_items i WHERE i.character_id=v_character.character_id;
        SELECT COALESCE(jsonb_agg(to_jsonb(s)),'[]'::jsonb) INTO v_spells FROM public.discord_character_spells s WHERE s.character_id=v_character.character_id;
        SELECT COALESCE(jsonb_agg(to_jsonb(ss)),'[]'::jsonb) INTO v_slots FROM public.discord_spell_slots ss WHERE ss.character_id=v_character.character_id;
        INSERT INTO public.discord_character_graveyard(
            campaign_id,player_id,original_character_id,character_name,death_id,cause,character_snapshot,inventory_snapshot,spells_snapshot,slots_snapshot)
        VALUES(v_death.campaign_id,v_death.player_id,v_character.character_id,v_character.character_name,v_death.death_id,v_death.cause,
            to_jsonb(v_character),v_inventory,v_spells,v_slots);
        UPDATE public.discord_character_deaths SET status='resolved',resolution='new_character',resolved_at=NOW() WHERE death_id=v_death.death_id;
        DELETE FROM public.discord_characters WHERE character_id=v_character.character_id;
        RETURN jsonb_build_object('outcome','new_character','requires_new_character',TRUE,'character_name',v_character.character_name);
    END IF;

    IF COALESCE(v_character.gold,0)>=v_death.required_gp THEN
        v_hp:=GREATEST(1,FLOOR(COALESCE(v_character.max_hp,1)/2.0)::INTEGER);
        UPDATE public.discord_characters c
        SET gold=c.gold-v_death.required_gp,current_hp=v_hp,life_state='alive',
            character_data=COALESCE(c.character_data,'{}'::jsonb) ||
                jsonb_build_object('gold',c.gold-v_death.required_gp,'current_hp',v_hp,'lifeState','alive'),updated_at=NOW()
        WHERE c.character_id=v_character.character_id;
        UPDATE public.discord_character_deaths SET status='resolved',resolution='self_paid_respawn',resolved_at=NOW() WHERE death_id=v_death.death_id;
        IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
            PERFORM public.discord_sync_tactical_tokens(p_campaign_id);
        END IF;
        RETURN jsonb_build_object('outcome','self_paid_respawn','character_name',v_character.character_name,'paid_gp',v_death.required_gp,
            'current_hp',v_hp,'max_hp',v_character.max_hp,'remaining_gold',v_character.gold-v_death.required_gp);
    END IF;

    UPDATE public.discord_character_deaths SET status='awaiting_donations' WHERE death_id=v_death.death_id;
    v_rag:=public.discord_maybe_apply_rag_respawn(v_death.death_id);
    IF v_rag IS NOT NULL THEN RETURN v_rag; END IF;
    RETURN jsonb_build_object('outcome','awaiting_donations','character_name',v_character.character_name,'required_gp',v_death.required_gp,
        'dead_character_gold',v_character.gold);
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
BEGIN
    SELECT * INTO v_death FROM public.discord_character_deaths d
    WHERE d.death_id=p_death_id AND d.campaign_id=p_campaign_id AND d.status='awaiting_donations' FOR UPDATE;
    IF v_death.death_id IS NULL THEN RAISE EXCEPTION 'That revival fund is no longer open.'; END IF;
    IF p_player_id=v_death.player_id THEN RAISE EXCEPTION 'The dead character cannot donate to their own party revival fund.'; END IF;

    SELECT * INTO v_donor FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id AND c.life_state='alive' FOR UPDATE;
    IF v_donor.character_id IS NULL THEN RAISE EXCEPTION 'Only a living party character can donate.'; END IF;
    IF COALESCE(p_amount_gp,0)<=0 THEN RAISE EXCEPTION 'Donation must be at least 1 GP.'; END IF;

    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_total FROM public.discord_death_donations WHERE death_id=p_death_id;
    v_remaining:=GREATEST(0,v_death.required_gp-v_total);
    IF v_remaining<=0 THEN RAISE EXCEPTION 'The revival fund already has enough GP. Click Revive.'; END IF;
    IF p_amount_gp>v_remaining THEN RAISE EXCEPTION 'Only % GP is still needed.',v_remaining; END IF;
    IF COALESCE(v_donor.gold,0)<p_amount_gp THEN RAISE EXCEPTION '% does not have % GP available.',v_donor.character_name,p_amount_gp; END IF;

    UPDATE public.discord_characters c
    SET gold=c.gold-p_amount_gp,
        character_data=COALESCE(c.character_data,'{}'::jsonb) || jsonb_build_object('gold',c.gold-p_amount_gp),updated_at=NOW()
    WHERE c.character_id=v_donor.character_id;
    INSERT INTO public.discord_death_donations(death_id,donor_player_id,amount_gp) VALUES(p_death_id,p_player_id,p_amount_gp);
    INSERT INTO public.discord_death_donor_decisions(death_id,player_id,decision)
    VALUES(p_death_id,p_player_id,'donate')
    ON CONFLICT(death_id,player_id) DO UPDATE SET decision='donate',updated_at=NOW();

    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_total FROM public.discord_death_donations WHERE death_id=p_death_id;
    IF v_total<v_death.required_gp THEN
        v_rag:=public.discord_maybe_apply_rag_respawn(p_death_id);
        IF v_rag IS NOT NULL THEN RETURN v_rag; END IF;
    END IF;
    RETURN jsonb_build_object('outcome','donated','donor_character_name',v_donor.character_name,'donated_now',p_amount_gp,
        'donated_gp',v_total,'remaining_gp',GREATEST(0,v_death.required_gp-v_total),'can_finalize',v_total>=v_death.required_gp,
        'remaining_gold',GREATEST(0,COALESCE(v_donor.gold,0)-p_amount_gp));
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
    WHERE d.death_id=p_death_id AND d.campaign_id=p_campaign_id AND d.status='awaiting_donations';
    IF v_death.death_id IS NULL THEN RAISE EXCEPTION 'That revival fund is no longer open.'; END IF;
    IF p_player_id=v_death.player_id THEN RAISE EXCEPTION 'The dead player cannot answer the party donation prompt.'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id AND c.life_state='alive') THEN
        RAISE EXCEPTION 'Only a living party character can answer this prompt.';
    END IF;
    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_existing FROM public.discord_death_donations WHERE death_id=p_death_id AND donor_player_id=p_player_id;
    IF v_existing>0 THEN RAISE EXCEPTION 'You already donated to this revival fund.'; END IF;

    INSERT INTO public.discord_death_donor_decisions(death_id,player_id,decision)
    VALUES(p_death_id,p_player_id,'decline')
    ON CONFLICT(death_id,player_id) DO UPDATE SET decision='decline',updated_at=NOW();
    v_rag:=public.discord_maybe_apply_rag_respawn(p_death_id);
    IF v_rag IS NOT NULL THEN RETURN v_rag; END IF;
    RETURN jsonb_build_object('outcome','declined');
END;
$$;

DROP FUNCTION IF EXISTS public.discord_finalize_party_respawn(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_finalize_party_respawn(p_player_id UUID,p_campaign_id UUID,p_death_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_death public.discord_character_deaths%ROWTYPE;
    v_character public.discord_characters%ROWTYPE;
    v_total INTEGER;
    v_hp INTEGER;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members cm WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;
    SELECT * INTO v_death FROM public.discord_character_deaths d
    WHERE d.death_id=p_death_id AND d.campaign_id=p_campaign_id AND d.status='awaiting_donations' FOR UPDATE;
    IF v_death.death_id IS NULL THEN RAISE EXCEPTION 'That revival fund is no longer open.'; END IF;
    SELECT COALESCE(SUM(amount_gp),0)::INTEGER INTO v_total FROM public.discord_death_donations WHERE death_id=p_death_id;
    IF v_total<v_death.required_gp THEN RAISE EXCEPTION '% more GP is needed before revival.',v_death.required_gp-v_total; END IF;

    SELECT * INTO v_character FROM public.discord_characters c WHERE c.character_id=v_death.character_id FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Dead character could not be found.'; END IF;
    v_hp:=GREATEST(1,FLOOR(COALESCE(v_character.max_hp,1)/2.0)::INTEGER);
    UPDATE public.discord_characters c
    SET current_hp=v_hp,life_state='alive',
        character_data=COALESCE(c.character_data,'{}'::jsonb) || jsonb_build_object('current_hp',v_hp,'lifeState','alive'),updated_at=NOW()
    WHERE c.character_id=v_character.character_id;
    UPDATE public.discord_character_deaths SET status='resolved',resolution='party_paid_respawn',resolved_at=NOW() WHERE death_id=p_death_id;
    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        PERFORM public.discord_sync_tactical_tokens(p_campaign_id);
    END IF;
    RETURN jsonb_build_object('outcome','party_paid_respawn','character_name',v_character.character_name,'current_hp',v_hp,
        'max_hp',v_character.max_hp,'donated_gp',v_total);
END;
$$;

-- -----------------------------------------------------------------------------
-- Combat disposition and automatic completion
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_set_enemy_disposition(UUID,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_set_enemy_disposition(
    p_campaign_id UUID,p_display_name TEXT,p_disposition TEXT,p_reason TEXT DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_row public.discord_campaign_combat_monsters%ROWTYPE;
    v_status TEXT:=lower(trim(COALESCE(p_disposition,'')));
    v_hostiles INTEGER;
    v_ended BOOLEAN:=FALSE;
    v_end_reason TEXT:='';
BEGIN
    IF v_status NOT IN ('hostile','defeated','fled','nonhostile','surrendered') THEN
        RAISE EXCEPTION 'Enemy disposition must be hostile, defeated, fled, nonhostile, or surrendered.';
    END IF;
    SELECT * INTO v_row FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND lower(m.display_name)=lower(trim(COALESCE(p_display_name,''))) LIMIT 1 FOR UPDATE;
    IF v_row.combat_monster_id IS NULL THEN RAISE EXCEPTION 'Combat monster not found: %',p_display_name; END IF;

    UPDATE public.discord_campaign_combat_monsters m
    SET disposition=v_status,
        defeated=CASE WHEN v_status='hostile' THEN FALSE ELSE TRUE END,
        conditions=CASE WHEN v_status='hostile' THEN m.conditions
            WHEN v_status='defeated' THEN LEFT(COALESCE(NULLIF(TRIM(m.conditions),''),'Defeated'),240)
            ELSE LEFT(INITCAP(v_status) || CASE WHEN TRIM(COALESCE(p_reason,''))<>'' THEN ': '||TRIM(p_reason) ELSE '' END,240) END,
        updated_at=NOW()
    WHERE m.combat_monster_id=v_row.combat_monster_id
    RETURNING * INTO v_row;

    IF v_status<>'hostile' THEN
        DELETE FROM public.discord_campaign_combat_tokens WHERE combat_monster_id=v_row.combat_monster_id;
    ELSE
        PERFORM public.discord_sync_tactical_tokens(p_campaign_id);
    END IF;

    SELECT COUNT(*) INTO v_hostiles FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND m.disposition='hostile' AND m.defeated=FALSE AND m.current_hp>0;
    IF v_hostiles=0 AND EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        v_ended:=TRUE;
        v_end_reason:='All enemies are defeated, have fled, surrendered, or are no longer hostile.';
        PERFORM public.discord_gm_end_combat(p_campaign_id,v_end_reason);
    END IF;

    RETURN jsonb_build_object('display_name',v_row.display_name,'disposition',v_status,'defeated',v_row.defeated,
        'conditions',v_row.conditions,'combat_ended',v_ended,'end_reason',v_end_reason);
END;
$$;

-- Override monster update so defeat also has a disposition and the last hostile ends combat automatically.
DROP FUNCTION IF EXISTS public.discord_gm_update_combat_monster(UUID, TEXT, INTEGER, TEXT, BOOLEAN);
CREATE OR REPLACE FUNCTION public.discord_gm_update_combat_monster(
    p_campaign_id UUID,p_display_name TEXT,p_hp_delta INTEGER,p_conditions TEXT,p_defeated BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_row public.discord_campaign_combat_monsters%ROWTYPE;
    v_new_hp INTEGER;
    v_hostiles INTEGER;
    v_ended BOOLEAN:=FALSE;
    v_end_reason TEXT:='';
BEGIN
    SELECT m.* INTO v_row FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND lower(m.display_name)=lower(TRIM(COALESCE(p_display_name,''))) LIMIT 1 FOR UPDATE;
    IF v_row.combat_monster_id IS NULL THEN RAISE EXCEPTION 'Combat monster not found: %',p_display_name; END IF;
    v_new_hp:=LEAST(v_row.max_hp,GREATEST(0,v_row.current_hp+COALESCE(p_hp_delta,0)));
    UPDATE public.discord_campaign_combat_monsters m SET
        current_hp=v_new_hp,conditions=LEFT(TRIM(COALESCE(p_conditions,'')),240),
        defeated=COALESCE(p_defeated,FALSE) OR v_new_hp=0,
        disposition=CASE WHEN COALESCE(p_defeated,FALSE) OR v_new_hp=0 THEN 'defeated' ELSE m.disposition END,
        updated_at=NOW()
    WHERE m.combat_monster_id=v_row.combat_monster_id RETURNING m.* INTO v_row;

    IF v_row.defeated THEN DELETE FROM public.discord_campaign_combat_tokens WHERE combat_monster_id=v_row.combat_monster_id; END IF;
    SELECT COUNT(*) INTO v_hostiles FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND m.disposition='hostile' AND m.defeated=FALSE AND m.current_hp>0;
    IF v_hostiles=0 AND EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        v_ended:=TRUE;
        v_end_reason:='All enemies are defeated, have fled, surrendered, or are no longer hostile.';
        PERFORM public.discord_gm_end_combat(p_campaign_id,v_end_reason);
    END IF;

    RETURN jsonb_build_object('display_name',v_row.display_name,'monster_name',v_row.monster_name,
        'current_hp',v_row.current_hp,'max_hp',v_row.max_hp,'armor_class',v_row.armor_class,
        'conditions',v_row.conditions,'defeated',v_row.defeated,'disposition',v_row.disposition,
        'combat_ended',v_ended,'end_reason',v_end_reason);
END;
$$;

-- GM combat state now carries disposition for future decisions without changing the outer RPC shape.
DROP FUNCTION IF EXISTS public.discord_gm_get_combat_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_combat_state(p_campaign_id UUID)
RETURNS TABLE(active BOOLEAN,title TEXT,round_number INTEGER,started_at TIMESTAMPTZ,monsters JSONB)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE v_active BOOLEAN:=FALSE; v_title TEXT:=''; v_round INTEGER:=1; v_started TIMESTAMPTZ:=NULL; v_monsters JSONB:='[]'::jsonb;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaigns c WHERE c.campaign_id=p_campaign_id AND c.is_active=TRUE) THEN RAISE EXCEPTION 'Campaign could not be found.'; END IF;
    INSERT INTO public.discord_campaign_combat_state(campaign_id) VALUES(p_campaign_id) ON CONFLICT ON CONSTRAINT discord_campaign_combat_state_pkey DO NOTHING;
    SELECT s.active,s.title,s.round_number,s.started_at INTO v_active,v_title,v_round,v_started FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'combat_monster_id',m.combat_monster_id,'monster_name',m.monster_name,'display_name',m.display_name,
        'current_hp',m.current_hp,'max_hp',m.max_hp,'armor_class',m.armor_class,'conditions',m.conditions,
        'defeated',m.defeated,'disposition',m.disposition,'sort_order',m.sort_order) ORDER BY m.sort_order,m.created_at),'[]'::jsonb)
    INTO v_monsters FROM public.discord_campaign_combat_monsters m WHERE m.campaign_id=p_campaign_id;
    RETURN QUERY SELECT COALESCE(v_active,FALSE),COALESCE(v_title,''),COALESCE(v_round,1),v_started,COALESCE(v_monsters,'[]'::jsonb);
END;
$$;

-- Active tactical tokens contain only living characters and active hostile monsters.
CREATE OR REPLACE FUNCTION public.discord_sync_tactical_tokens(p_campaign_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN RETURN; END IF;
    DELETE FROM public.discord_campaign_combat_tokens t
    WHERE t.campaign_id=p_campaign_id AND t.entity_type='character' AND NOT EXISTS(
        SELECT 1 FROM public.discord_characters c WHERE c.character_id=t.character_id AND c.campaign_id=p_campaign_id AND c.life_state='alive');
    DELETE FROM public.discord_campaign_combat_tokens t
    WHERE t.campaign_id=p_campaign_id AND t.entity_type='monster' AND NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_monsters m WHERE m.combat_monster_id=t.combat_monster_id AND m.campaign_id=p_campaign_id
          AND m.disposition='hostile' AND m.defeated=FALSE AND m.current_hp>0);

    INSERT INTO public.discord_campaign_combat_tokens(campaign_id,entity_type,character_id,grid_x,grid_y,movement_spent_ft)
    SELECT p_campaign_id,'character',ranked.character_id,
        LEAST(18,2+(((ranked.rn-1)%6)*2)::INTEGER),GREATEST(1,17-(((ranked.rn-1)/6)*2)::INTEGER),0
    FROM(SELECT c.character_id,ROW_NUMBER() OVER(ORDER BY c.character_name,c.character_id) rn FROM public.discord_characters c
         WHERE c.campaign_id=p_campaign_id AND c.life_state='alive') ranked ON CONFLICT DO NOTHING;

    INSERT INTO public.discord_campaign_combat_tokens(campaign_id,entity_type,combat_monster_id,grid_x,grid_y,movement_spent_ft)
    SELECT p_campaign_id,'monster',ranked.combat_monster_id,
        GREATEST(1,17-(((ranked.rn-1)%6)*2)::INTEGER),LEAST(18,2+(((ranked.rn-1)/6)*2)::INTEGER),0
    FROM(SELECT m.combat_monster_id,ROW_NUMBER() OVER(ORDER BY m.sort_order,m.created_at,m.combat_monster_id) rn
         FROM public.discord_campaign_combat_monsters m WHERE m.campaign_id=p_campaign_id AND m.disposition='hostile' AND m.defeated=FALSE AND m.current_hp>0) ranked
    ON CONFLICT DO NOTHING;
END;
$$;

-- Initiative candidates exclude only truly dead characters; unconscious characters still take death-save turns.
DROP FUNCTION IF EXISTS public.discord_gm_get_initiative_candidates(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_initiative_candidates(p_campaign_id UUID)
RETURNS TABLE(entity_type TEXT,character_id UUID,combat_monster_id UUID,display_name TEXT,monster_name TEXT,initiative_modifier INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN RAISE EXCEPTION 'No active combat exists for this campaign.'; END IF;
    RETURN QUERY
    SELECT 'character'::text,c.character_id,NULL::uuid,c.character_name,''::text,
           COALESCE(c.initiative,FLOOR((COALESCE(c.dexterity,10)-10)/2.0)::integer)
    FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id AND c.life_state='alive'
    UNION ALL
    SELECT 'monster'::text,NULL::uuid,m.combat_monster_id,m.display_name,m.monster_name,0
    FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND m.defeated=FALSE AND m.disposition='hostile' AND m.current_hp>0;
END;
$$;

-- Party combat stats exclude truly dead characters so enemies do not keep targeting corpses.
-- Keep the exact Build 6.1 return signature for server compatibility.
DROP FUNCTION IF EXISTS public.discord_gm_get_party_combatants(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_party_combatants(p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID, character_name TEXT, class_name TEXT, level INTEGER, current_hp INTEGER, max_hp INTEGER,
    armor_class INTEGER, strength INTEGER, dexterity INTEGER, constitution INTEGER, intelligence INTEGER, wisdom INTEGER,
    charisma INTEGER, proficiency_bonus INTEGER, speed INTEGER)
LANGUAGE sql SECURITY DEFINER SET search_path=public
AS $$
    SELECT c.character_id,c.character_name,c.class_name,c.level,c.current_hp,c.max_hp,c.armor_class,
           c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma,c.proficiency_bonus,c.speed
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.life_state='alive'
    ORDER BY lower(c.character_name),c.character_id;
$$;

-- Recreate initiative readers so dead characters / non-hostile enemies render as inactive entries.
DROP FUNCTION IF EXISTS public.discord_get_combat_initiative(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_combat_initiative(p_player_id UUID,p_campaign_id UUID)
RETURNS TABLE(order_position INTEGER,entity_type TEXT,character_id UUID,combat_monster_id UUID,display_name TEXT,
    initiative_roll INTEGER,initiative_modifier INTEGER,initiative_total INTEGER,is_current BOOLEAN,defeated BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members cm WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;
    RETURN QUERY
    SELECT i.order_position,i.entity_type,i.character_id,i.combat_monster_id,i.display_name,i.initiative_roll,i.initiative_modifier,i.initiative_total,
        CASE WHEN i.entity_type='character' THEN s.current_turn_type='character' AND s.current_turn_character_id=i.character_id
             ELSE s.current_turn_type='monster' AND s.current_turn_monster_id=i.combat_monster_id END,
        CASE WHEN i.entity_type='character' THEN COALESCE(c.life_state,'dead')='dead'
             ELSE COALESCE(m.defeated,TRUE) OR COALESCE(m.disposition,'defeated')<>'hostile' END
    FROM public.discord_campaign_combat_initiative i
    JOIN public.discord_campaign_combat_state s ON s.campaign_id=i.campaign_id
    LEFT JOIN public.discord_characters c ON c.character_id=i.character_id
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
    WHERE i.campaign_id=p_campaign_id ORDER BY i.order_position;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_combat_initiative(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_combat_initiative(p_campaign_id UUID)
RETURNS TABLE(order_position INTEGER,entity_type TEXT,character_id UUID,combat_monster_id UUID,display_name TEXT,
    initiative_roll INTEGER,initiative_modifier INTEGER,initiative_total INTEGER,is_current BOOLEAN,defeated BOOLEAN)
LANGUAGE sql SECURITY DEFINER SET search_path=public
AS $$
    SELECT i.order_position,i.entity_type,i.character_id,i.combat_monster_id,i.display_name,i.initiative_roll,i.initiative_modifier,i.initiative_total,
        CASE WHEN i.entity_type='character' THEN s.current_turn_type='character' AND s.current_turn_character_id=i.character_id
             ELSE s.current_turn_type='monster' AND s.current_turn_monster_id=i.combat_monster_id END,
        CASE WHEN i.entity_type='character' THEN COALESCE(c.life_state,'dead')='dead'
             ELSE COALESCE(m.defeated,TRUE) OR COALESCE(m.disposition,'defeated')<>'hostile' END
    FROM public.discord_campaign_combat_initiative i
    JOIN public.discord_campaign_combat_state s ON s.campaign_id=i.campaign_id
    LEFT JOIN public.discord_characters c ON c.character_id=i.character_id
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
    WHERE i.campaign_id=p_campaign_id ORDER BY i.order_position;
$$;

-- Strict advance skips dead characters and all enemies removed from combat.
DROP FUNCTION IF EXISTS public.discord_advance_combat_turn_internal(UUID,TEXT,BOOLEAN);
CREATE OR REPLACE FUNCTION public.discord_advance_combat_turn_internal(p_campaign_id UUID,p_reason TEXT,p_allow_character BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
    v_state public.discord_campaign_combat_state%ROWTYPE;
    v_current_position INTEGER:=0;
    v_next public.discord_campaign_combat_initiative%ROWTYPE;
    v_wrapped BOOLEAN:=FALSE;
    v_round INTEGER:=1;
BEGIN
    SELECT * INTO v_state FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE FOR UPDATE;
    IF v_state.campaign_id IS NULL THEN RAISE EXCEPTION 'No active combat exists for this campaign.'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=p_campaign_id) THEN RAISE EXCEPTION 'Strict initiative has not been initialized for this combat.'; END IF;
    IF v_state.current_turn_type='character' AND NOT COALESCE(p_allow_character,FALSE) THEN RAISE EXCEPTION 'A player character turn can only advance through that player''s End Turn action.'; END IF;

    SELECT i.order_position INTO v_current_position FROM public.discord_campaign_combat_initiative i
    WHERE i.campaign_id=p_campaign_id AND ((v_state.current_turn_type='character' AND i.entity_type='character' AND i.character_id=v_state.current_turn_character_id)
      OR(v_state.current_turn_type='monster' AND i.entity_type='monster' AND i.combat_monster_id=v_state.current_turn_monster_id)) LIMIT 1;
    v_current_position:=COALESCE(v_current_position,0);

    SELECT i.* INTO v_next FROM public.discord_campaign_combat_initiative i
    LEFT JOIN public.discord_characters c ON c.character_id=i.character_id
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
    WHERE i.campaign_id=p_campaign_id AND i.order_position>v_current_position
      AND ((i.entity_type='character' AND COALESCE(c.life_state,'dead')='alive')
        OR(i.entity_type='monster' AND COALESCE(m.defeated,TRUE)=FALSE AND COALESCE(m.disposition,'defeated')='hostile' AND COALESCE(m.current_hp,0)>0))
    ORDER BY i.order_position LIMIT 1;

    IF v_next.order_position IS NULL THEN
        v_wrapped:=TRUE;
        SELECT i.* INTO v_next FROM public.discord_campaign_combat_initiative i
        LEFT JOIN public.discord_characters c ON c.character_id=i.character_id
        LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
        WHERE i.campaign_id=p_campaign_id
          AND ((i.entity_type='character' AND COALESCE(c.life_state,'dead')='alive')
            OR(i.entity_type='monster' AND COALESCE(m.defeated,TRUE)=FALSE AND COALESCE(m.disposition,'defeated')='hostile' AND COALESCE(m.current_hp,0)>0))
        ORDER BY i.order_position LIMIT 1;
    END IF;
    IF v_next.order_position IS NULL THEN RAISE EXCEPTION 'No remaining combatant can take a turn.'; END IF;

    v_round:=GREATEST(1,COALESCE(v_state.round_number,1)+CASE WHEN v_wrapped AND v_current_position>0 THEN 1 ELSE 0 END);
    UPDATE public.discord_campaign_combat_state s SET round_number=v_round,current_turn_type=v_next.entity_type,
        current_turn_character_id=v_next.character_id,current_turn_monster_id=v_next.combat_monster_id,turn_started_at=NOW(),updated_at=NOW()
    WHERE s.campaign_id=p_campaign_id;
    UPDATE public.discord_campaign_combat_tokens t SET movement_spent_ft=0,updated_at=NOW()
    WHERE t.campaign_id=p_campaign_id AND ((v_next.entity_type='character' AND t.character_id=v_next.character_id)
      OR(v_next.entity_type='monster' AND t.combat_monster_id=v_next.combat_monster_id));
    RETURN jsonb_build_object('round_number',v_round,'wrapped_round',v_wrapped,'current_turn_type',v_next.entity_type,
        'current_turn_character_id',v_next.character_id,'current_turn_monster_id',v_next.combat_monster_id,
        'current_turn_name',v_next.display_name,'order_position',v_next.order_position,'reason',LEFT(TRIM(COALESCE(p_reason,'')),160));
END;
$$;

-- -----------------------------------------------------------------------------
-- Security grants
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.discord_refund_death_donations(UUID) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discord_apply_rag_respawn(UUID) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discord_maybe_apply_rag_respawn(UUID) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discord_advance_combat_turn_internal(UUID,TEXT,BOOLEAN) FROM PUBLIC,anon,authenticated,service_role;

REVOKE ALL ON FUNCTION public.discord_gm_mark_character_dead(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_revive_character(UUID,TEXT,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_adjust_character_hp(UUID,TEXT,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_death_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_choose_respawn(UUID,UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_donate_to_respawn(UUID,UUID,UUID,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_decline_respawn_donation(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_finalize_party_respawn(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_set_enemy_disposition(UUID,TEXT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_update_combat_monster(UUID,TEXT,INTEGER,TEXT,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_combat_state(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_sync_tactical_tokens(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_initiative_candidates(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_party_combatants(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_combat_initiative(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_combat_initiative(UUID) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_gm_mark_character_dead(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_revive_character(UUID,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_adjust_character_hp(UUID,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_death_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_choose_respawn(UUID,UUID,BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_donate_to_respawn(UUID,UUID,UUID,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_decline_respawn_donation(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_finalize_party_respawn(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_enemy_disposition(UUID,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_update_combat_monster(UUID,TEXT,INTEGER,TEXT,BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_combat_state(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_sync_tactical_tokens(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_initiative_candidates(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_party_combatants(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_combat_initiative(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_combat_initiative(UUID) TO service_role;

COMMIT;
