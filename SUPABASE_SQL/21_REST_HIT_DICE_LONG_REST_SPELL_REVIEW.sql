-- RabuShinAIGM Rules Build 6.4
-- Authoritative Short Rest Hit Dice + complete Long Rest recovery + optional spell review.
-- Requires the existing Build 6.3 XP / level-up schema.

BEGIN;

ALTER TABLE public.discord_characters
ADD COLUMN IF NOT EXISTS hit_dice_spent INTEGER NOT NULL DEFAULT 0;

UPDATE public.discord_characters c
SET hit_dice_spent=GREATEST(0,LEAST(GREATEST(1,COALESCE(c.level,1)),COALESCE(c.hit_dice_spent,0)))
WHERE c.hit_dice_spent IS NULL
   OR c.hit_dice_spent < 0
   OR c.hit_dice_spent > GREATEST(1,COALESCE(c.level,1));

CREATE TABLE IF NOT EXISTS public.discord_character_rest_state (
    character_id UUID PRIMARY KEY REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    rest_type TEXT NOT NULL CHECK (rest_type IN ('short','long')),
    status TEXT NOT NULL CHECK (status IN ('awaiting_hit_dice','spell_review','long_complete')),
    hit_dice_spent_this_rest INTEGER NOT NULL DEFAULT 0 CHECK (hit_dice_spent_this_rest >= 0),
    reason TEXT NOT NULL DEFAULT '',
    roll_log JSONB NOT NULL DEFAULT '[]'::jsonb,
    result_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.discord_character_rest_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_character_rest_state FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_character_rest_state TO service_role;

CREATE OR REPLACE FUNCTION public.discord_hit_die_sides(p_class_name TEXT)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
SELECT CASE lower(trim(COALESCE(p_class_name,'')))
    WHEN 'barbarian' THEN 12
    WHEN 'fighter' THEN 10 WHEN 'paladin' THEN 10 WHEN 'ranger' THEN 10
    WHEN 'bard' THEN 8 WHEN 'cleric' THEN 8 WHEN 'druid' THEN 8 WHEN 'monk' THEN 8
    WHEN 'rogue' THEN 8 WHEN 'warlock' THEN 8
    WHEN 'sorcerer' THEN 6 WHEN 'wizard' THEN 6
    ELSE 8 END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_rest_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_rest_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,
    campaign_id UUID,
    character_name TEXT,
    class_name TEXT,
    level INTEGER,
    current_hp INTEGER,
    max_hp INTEGER,
    constitution INTEGER,
    hit_die_sides INTEGER,
    hit_dice_total INTEGER,
    hit_dice_spent INTEGER,
    hit_dice_available INTEGER,
    rest_type TEXT,
    status TEXT,
    hit_dice_spent_this_rest INTEGER,
    reason TEXT,
    roll_log JSONB,
    result_data JSONB
)
LANGUAGE sql
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT
        c.character_id,
        c.campaign_id,
        c.character_name,
        c.class_name,
        GREATEST(1,COALESCE(c.level,1))::INTEGER,
        COALESCE(c.current_hp,0)::INTEGER,
        GREATEST(1,COALESCE(c.max_hp,1))::INTEGER,
        COALESCE(c.constitution,10)::INTEGER,
        public.discord_hit_die_sides(c.class_name)::INTEGER,
        GREATEST(1,COALESCE(c.level,1))::INTEGER,
        GREATEST(0,LEAST(GREATEST(1,COALESCE(c.level,1)),COALESCE(c.hit_dice_spent,0)))::INTEGER,
        GREATEST(0,GREATEST(1,COALESCE(c.level,1))-GREATEST(0,COALESCE(c.hit_dice_spent,0)))::INTEGER,
        COALESCE(r.rest_type,'')::TEXT,
        COALESCE(r.status,'')::TEXT,
        COALESCE(r.hit_dice_spent_this_rest,0)::INTEGER,
        COALESCE(r.reason,'')::TEXT,
        COALESCE(r.roll_log,'[]'::jsonb),
        COALESCE(r.result_data,'{}'::jsonb)
    FROM public.discord_characters c
    LEFT JOIN public.discord_character_rest_state r ON r.character_id=c.character_id
    WHERE c.player_id=p_player_id
      AND c.campaign_id=p_campaign_id
    LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_complete_short_rest(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_complete_short_rest(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_total INTEGER;
    v_spent INTEGER;
    v_available INTEGER;
    v_sides INTEGER;
    v_reason TEXT:=LEFT(trim(COALESCE(p_reason,'')),240);
BEGIN
    IF EXISTS(
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id AND s.active=TRUE
    ) THEN
        RAISE EXCEPTION 'A Short Rest cannot complete while combat is active.';
    END IF;

    SELECT * INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1 FOR UPDATE;

    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF COALESCE(v_character.life_state,'alive')<>'alive' THEN
        RAISE EXCEPTION '% cannot complete a Short Rest while dead.',v_character.character_name;
    END IF;
    IF COALESCE(v_character.current_hp,0)<1 THEN
        RAISE EXCEPTION '% needs at least 1 HP to complete a Short Rest.',v_character.character_name;
    END IF;

    v_total:=GREATEST(1,COALESCE(v_character.level,1));
    v_spent:=GREATEST(0,LEAST(v_total,COALESCE(v_character.hit_dice_spent,0)));
    v_available:=GREATEST(0,v_total-v_spent);
    v_sides:=public.discord_hit_die_sides(v_character.class_name);

    INSERT INTO public.discord_character_rest_state(
        character_id,campaign_id,rest_type,status,hit_dice_spent_this_rest,
        reason,roll_log,result_data,created_at,updated_at)
    VALUES(
        v_character.character_id,p_campaign_id,'short','awaiting_hit_dice',0,
        v_reason,'[]'::jsonb,
        jsonb_build_object('startingHp',v_character.current_hp,'maxHp',v_character.max_hp,'hitDiceAvailableAtStart',v_available),
        NOW(),NOW())
    ON CONFLICT(character_id) DO UPDATE SET
        campaign_id=EXCLUDED.campaign_id,
        rest_type='short',
        status='awaiting_hit_dice',
        hit_dice_spent_this_rest=0,
        reason=EXCLUDED.reason,
        roll_log='[]'::jsonb,
        result_data=EXCLUDED.result_data,
        created_at=NOW(),
        updated_at=NOW();

    RETURN jsonb_build_object(
        'characterId',v_character.character_id,
        'characterName',v_character.character_name,
        'status','awaiting_hit_dice',
        'currentHp',v_character.current_hp,
        'maxHp',v_character.max_hp,
        'hitDieSides',v_sides,
        'hitDiceTotal',v_total,
        'hitDiceAvailable',v_available,
        'reason',v_reason);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_spend_short_rest_hit_die(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_spend_short_rest_hit_die(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_rest public.discord_character_rest_state%ROWTYPE;
    v_total INTEGER;
    v_spent INTEGER;
    v_available INTEGER;
    v_sides INTEGER;
    v_roll INTEGER;
    v_con_mod INTEGER;
    v_rolled_healing INTEGER;
    v_actual_healing INTEGER;
    v_new_hp INTEGER;
    v_entry JSONB;
BEGIN
    SELECT * INTO v_character
    FROM public.discord_characters c
    WHERE c.player_id=p_player_id AND c.campaign_id=p_campaign_id
    LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT * INTO v_rest
    FROM public.discord_character_rest_state r
    WHERE r.character_id=v_character.character_id
      AND r.campaign_id=p_campaign_id
      AND r.rest_type='short'
      AND r.status='awaiting_hit_dice'
    FOR UPDATE;
    IF v_rest.character_id IS NULL THEN RAISE EXCEPTION 'No completed Short Rest is waiting for Hit Dice.'; END IF;

    IF COALESCE(v_character.current_hp,0)>=COALESCE(v_character.max_hp,1) THEN
        RAISE EXCEPTION '% is already at full HP.',v_character.character_name;
    END IF;

    v_total:=GREATEST(1,COALESCE(v_character.level,1));
    v_spent:=GREATEST(0,LEAST(v_total,COALESCE(v_character.hit_dice_spent,0)));
    v_available:=GREATEST(0,v_total-v_spent);
    IF v_available<1 THEN RAISE EXCEPTION 'No Hit Dice are available. Complete a Long Rest to restore them.'; END IF;
    IF COALESCE(v_rest.hit_dice_spent_this_rest,0)>=v_total THEN
        RAISE EXCEPTION 'The Hit Dice limit for this Short Rest has been reached.';
    END IF;

    v_sides:=public.discord_hit_die_sides(v_character.class_name);
    v_roll:=FLOOR(random()*v_sides)::INTEGER+1;
    v_con_mod:=FLOOR((COALESCE(v_character.constitution,10)-10)::NUMERIC/2)::INTEGER;
    v_rolled_healing:=GREATEST(1,v_roll+v_con_mod);
    v_actual_healing:=LEAST(v_rolled_healing,GREATEST(0,v_character.max_hp-v_character.current_hp));
    v_new_hp:=LEAST(v_character.max_hp,v_character.current_hp+v_actual_healing);

    UPDATE public.discord_characters c
    SET current_hp=v_new_hp,
        hit_dice_spent=v_spent+1,
        character_data=jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{current_hp}',to_jsonb(v_new_hp),TRUE),
        updated_at=NOW()
    WHERE c.character_id=v_character.character_id;

    v_entry:=jsonb_build_object(
        'dieSides',v_sides,
        'roll',v_roll,
        'constitutionModifier',v_con_mod,
        'rolledHealing',v_rolled_healing,
        'healing',v_actual_healing,
        'hpAfter',v_new_hp,
        'rolledAt',NOW());

    UPDATE public.discord_character_rest_state r
    SET hit_dice_spent_this_rest=r.hit_dice_spent_this_rest+1,
        roll_log=COALESCE(r.roll_log,'[]'::jsonb)||jsonb_build_array(v_entry),
        updated_at=NOW()
    WHERE r.character_id=v_character.character_id;

    RETURN jsonb_build_object(
        'characterId',v_character.character_id,
        'characterName',v_character.character_name,
        'dieSides',v_sides,
        'roll',v_roll,
        'constitutionModifier',v_con_mod,
        'rolledHealing',v_rolled_healing,
        'healing',v_actual_healing,
        'currentHp',v_new_hp,
        'maxHp',v_character.max_hp,
        'hitDiceSpent',v_spent+1,
        'hitDiceAvailable',GREATEST(0,v_total-(v_spent+1)),
        'hitDiceSpentThisRest',COALESCE(v_rest.hit_dice_spent_this_rest,0)+1);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_finish_short_rest(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_finish_short_rest(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_rest public.discord_character_rest_state%ROWTYPE;
BEGIN
    SELECT * INTO v_character
    FROM public.discord_characters c
    WHERE c.player_id=p_player_id AND c.campaign_id=p_campaign_id
    LIMIT 1;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT * INTO v_rest
    FROM public.discord_character_rest_state r
    WHERE r.character_id=v_character.character_id
      AND r.rest_type='short'
      AND r.status='awaiting_hit_dice';
    IF v_rest.character_id IS NULL THEN RAISE EXCEPTION 'No Short Rest is waiting to be finished.'; END IF;

    DELETE FROM public.discord_character_rest_state r WHERE r.character_id=v_character.character_id;

    RETURN jsonb_build_object(
        'characterId',v_character.character_id,
        'characterName',v_character.character_name,
        'currentHp',v_character.current_hp,
        'maxHp',v_character.max_hp,
        'hitDiceSpentThisRest',v_rest.hit_dice_spent_this_rest,
        'rollLog',v_rest.roll_log,
        'reason',v_rest.reason);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_finish_long_rest_review(UUID,UUID,BOOLEAN);
CREATE OR REPLACE FUNCTION public.discord_finish_long_rest_review(
    p_player_id UUID,
    p_campaign_id UUID,
    p_review_spells BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_rest public.discord_character_rest_state%ROWTYPE;
BEGIN
    SELECT * INTO v_character
    FROM public.discord_characters c
    WHERE c.player_id=p_player_id AND c.campaign_id=p_campaign_id
    LIMIT 1;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT * INTO v_rest
    FROM public.discord_character_rest_state r
    WHERE r.character_id=v_character.character_id
      AND r.rest_type='long'
      AND r.status IN ('spell_review','long_complete');
    IF v_rest.character_id IS NULL THEN RAISE EXCEPTION 'No completed Long Rest is waiting for review.'; END IF;

    IF COALESCE(p_review_spells,FALSE)=TRUE AND v_rest.status<>'spell_review' THEN
        RAISE EXCEPTION 'This character does not have a Long Rest spell review available.';
    END IF;

    DELETE FROM public.discord_character_rest_state r WHERE r.character_id=v_character.character_id;

    RETURN jsonb_build_object(
        'characterId',v_character.character_id,
        'characterName',v_character.character_name,
        'reviewSpells',COALESCE(p_review_spells,FALSE),
        'reason',v_rest.reason);
END;
$$;

-- Replace Build 6.3 Long Rest with full Rest Build behavior.
DROP FUNCTION IF EXISTS public.discord_gm_complete_long_rest(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_complete_long_rest(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_from INTEGER;
    v_to INTEGER;
    v_hp_gain INTEGER:=0;
    v_gain_per_level INTEGER:=0;
    v_new_max INTEGER;
    v_is_caster BOOLEAN:=FALSE;
    v_hit_dice_restored INTEGER:=0;
    v_reason TEXT:=LEFT(trim(COALESCE(p_reason,'')),240);
    v_result_data JSONB;
BEGIN
    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        RAISE EXCEPTION 'A Long Rest cannot complete while combat is active.';
    END IF;

    SELECT * INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF COALESCE(v_character.life_state,'alive')<>'alive' THEN RAISE EXCEPTION '% cannot complete a Long Rest while dead.',v_character.character_name; END IF;
    IF COALESCE(v_character.current_hp,0)<1 THEN RAISE EXCEPTION '% needs at least 1 HP to complete a Long Rest.',v_character.character_name; END IF;
    IF EXISTS(SELECT 1 FROM public.discord_character_level_up_state s WHERE s.character_id=v_character.character_id AND s.pending=TRUE) THEN
        RAISE EXCEPTION '% still has unfinished choices from the previous level up.',v_character.character_name;
    END IF;

    v_from:=GREATEST(1,LEAST(20,COALESCE(v_character.level,1)));
    v_to:=GREATEST(v_from,public.discord_level_for_xp(v_character.experience));
    v_gain_per_level:=public.discord_fixed_hp_gain(v_character.class_name,v_character.constitution);
    v_hp_gain:=GREATEST(0,v_to-v_from)*v_gain_per_level;
    v_new_max:=GREATEST(1,COALESCE(v_character.max_hp,1)+v_hp_gain);
    v_is_caster:=lower(v_character.class_name) IN ('bard','cleric','druid','paladin','ranger','sorcerer','warlock','wizard');
    v_hit_dice_restored:=GREATEST(0,LEAST(v_from,COALESCE(v_character.hit_dice_spent,0)));

    UPDATE public.discord_characters c
    SET level=v_to,
        proficiency_bonus=public.discord_proficiency_for_level(v_to),
        max_hp=v_new_max,
        current_hp=v_new_max,
        hit_dice_spent=0,
        spells_complete=CASE WHEN v_to>v_from AND v_is_caster THEN FALSE ELSE c.spells_complete END,
        character_data=jsonb_set(
            jsonb_set(
                jsonb_set(
                    jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{level}',to_jsonb(v_to),TRUE),
                    '{current_hp}',to_jsonb(v_new_max),TRUE),
                '{max_hp}',to_jsonb(v_new_max),TRUE),
            '{proficiency_bonus}',to_jsonb(public.discord_proficiency_for_level(v_to)),TRUE),
        updated_at=NOW()
    WHERE c.character_id=v_character.character_id;

    -- All tracked spell slots are fully restored on a completed Long Rest.
    UPDATE public.discord_spell_slots SET used_slots=0 WHERE character_id=v_character.character_id;

    -- Clear any unfinished Short Rest / old Long Rest review state.
    DELETE FROM public.discord_character_rest_state r WHERE r.character_id=v_character.character_id;

    IF v_to>v_from THEN
        INSERT INTO public.discord_character_level_up_state(character_id,campaign_id,from_level,to_level,pending,rest_reason,ability_choices,created_at,completed_at)
        VALUES(v_character.character_id,p_campaign_id,v_from,v_to,TRUE,v_reason,'{}'::jsonb,NOW(),NULL)
        ON CONFLICT(character_id) DO UPDATE SET campaign_id=EXCLUDED.campaign_id,from_level=EXCLUDED.from_level,to_level=EXCLUDED.to_level,
            pending=TRUE,rest_reason=EXCLUDED.rest_reason,ability_choices='{}'::jsonb,created_at=NOW(),completed_at=NULL;
    ELSE
        v_result_data:=jsonb_build_object(
            'hpRestoredTo',v_new_max,
            'hitDiceRestored',v_hit_dice_restored,
            'spellSlotsRestored',v_is_caster,
            'leveledUp',FALSE,
            'fromLevel',v_from,
            'toLevel',v_to);

        INSERT INTO public.discord_character_rest_state(
            character_id,campaign_id,rest_type,status,hit_dice_spent_this_rest,
            reason,roll_log,result_data,created_at,updated_at)
        VALUES(
            v_character.character_id,p_campaign_id,'long',CASE WHEN v_is_caster THEN 'spell_review' ELSE 'long_complete' END,0,
            v_reason,'[]'::jsonb,v_result_data,NOW(),NOW())
        ON CONFLICT(character_id) DO UPDATE SET
            campaign_id=EXCLUDED.campaign_id,
            rest_type='long',
            status=EXCLUDED.status,
            hit_dice_spent_this_rest=0,
            reason=EXCLUDED.reason,
            roll_log='[]'::jsonb,
            result_data=EXCLUDED.result_data,
            created_at=NOW(),
            updated_at=NOW();
    END IF;

    RETURN jsonb_build_object(
        'characterId',v_character.character_id,
        'characterName',v_character.character_name,
        'leveledUp',v_to>v_from,
        'fromLevel',v_from,
        'toLevel',v_to,
        'experience',v_character.experience,
        'hpGain',v_hp_gain,
        'maxHp',v_new_max,
        'proficiencyBonus',public.discord_proficiency_for_level(v_to),
        'spellSelectionRequired',v_to>v_from AND v_is_caster,
        'spellReviewAvailable',v_to=v_from AND v_is_caster,
        'hitDiceRestored',v_hit_dice_restored,
        'reason',v_reason);
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_rest_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_complete_short_rest(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_spend_short_rest_hit_die(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_finish_short_rest(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_finish_long_rest_review(UUID,UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_rest_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_complete_short_rest(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_spend_short_rest_hit_die(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_finish_short_rest(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_finish_long_rest_review(UUID,UUID,BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) TO service_role;

COMMIT;
