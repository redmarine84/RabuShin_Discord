-- RabuShinAIGM Rules Build 6.3
-- XP progression, CR-based monster XP, quest XP, long-rest-gated level ups,
-- and persistent post-rest class choice state.
-- Requires the existing Discord/Supabase character schema and Builds 6.1-6.2.2.

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_experience_awards (
    award_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    award_key TEXT NOT NULL,
    award_type TEXT NOT NULL CHECK (award_type IN ('monster','quest','other')),
    source_name TEXT NOT NULL DEFAULT '',
    xp_amount INTEGER NOT NULL CHECK (xp_amount > 0),
    award_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    awarded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(character_id, award_key)
);

CREATE INDEX IF NOT EXISTS ix_discord_experience_awards_campaign
ON public.discord_experience_awards(campaign_id, awarded_at DESC);

CREATE TABLE IF NOT EXISTS public.discord_character_level_up_state (
    character_id UUID PRIMARY KEY REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    from_level INTEGER NOT NULL CHECK (from_level BETWEEN 1 AND 20),
    to_level INTEGER NOT NULL CHECK (to_level BETWEEN 1 AND 20),
    pending BOOLEAN NOT NULL DEFAULT TRUE,
    rest_reason TEXT NOT NULL DEFAULT '',
    ability_choices JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ NULL
);

ALTER TABLE public.discord_experience_awards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_character_level_up_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_experience_awards, public.discord_character_level_up_state FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_experience_awards, public.discord_character_level_up_state TO service_role;

CREATE OR REPLACE FUNCTION public.discord_level_threshold(p_level INTEGER)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
SELECT CASE GREATEST(1,LEAST(20,COALESCE(p_level,1)))
    WHEN 1 THEN 0 WHEN 2 THEN 300 WHEN 3 THEN 900 WHEN 4 THEN 2700 WHEN 5 THEN 6500
    WHEN 6 THEN 14000 WHEN 7 THEN 23000 WHEN 8 THEN 34000 WHEN 9 THEN 48000 WHEN 10 THEN 64000
    WHEN 11 THEN 85000 WHEN 12 THEN 100000 WHEN 13 THEN 120000 WHEN 14 THEN 140000 WHEN 15 THEN 165000
    WHEN 16 THEN 195000 WHEN 17 THEN 225000 WHEN 18 THEN 265000 WHEN 19 THEN 305000 ELSE 355000 END;
$$;

CREATE OR REPLACE FUNCTION public.discord_level_for_xp(p_xp INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_xp INTEGER := GREATEST(0,COALESCE(p_xp,0));
    v_level INTEGER := 1;
BEGIN
    FOR i IN 2..20 LOOP
        EXIT WHEN v_xp < public.discord_level_threshold(i);
        v_level := i;
    END LOOP;
    RETURN v_level;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_proficiency_for_level(p_level INTEGER)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
SELECT CASE
    WHEN GREATEST(1,LEAST(20,COALESCE(p_level,1))) <= 4 THEN 2
    WHEN GREATEST(1,LEAST(20,COALESCE(p_level,1))) <= 8 THEN 3
    WHEN GREATEST(1,LEAST(20,COALESCE(p_level,1))) <= 12 THEN 4
    WHEN GREATEST(1,LEAST(20,COALESCE(p_level,1))) <= 16 THEN 5
    ELSE 6 END;
$$;

CREATE OR REPLACE FUNCTION public.discord_fixed_hp_gain(p_class_name TEXT,p_constitution INTEGER)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
SELECT GREATEST(1,
    CASE lower(trim(COALESCE(p_class_name,'')))
        WHEN 'barbarian' THEN 7
        WHEN 'fighter' THEN 6 WHEN 'paladin' THEN 6 WHEN 'ranger' THEN 6
        WHEN 'bard' THEN 5 WHEN 'cleric' THEN 5 WHEN 'druid' THEN 5 WHEN 'monk' THEN 5
        WHEN 'rogue' THEN 5 WHEN 'warlock' THEN 5
        WHEN 'sorcerer' THEN 4 WHEN 'wizard' THEN 4
        ELSE 5 END
    + FLOOR((COALESCE(p_constitution,10)-10)::NUMERIC/2)::INTEGER
);
$$;

-- Existing manually-created higher-level characters should start at least at the XP floor for their stored level.
UPDATE public.discord_characters c
SET experience=GREATEST(COALESCE(c.experience,0),public.discord_level_threshold(c.level)),
    character_data=jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{experience}',to_jsonb(GREATEST(COALESCE(c.experience,0),public.discord_level_threshold(c.level))),TRUE),
    updated_at=NOW()
WHERE COALESCE(c.experience,0) < public.discord_level_threshold(c.level);

DROP FUNCTION IF EXISTS public.discord_get_level_up_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_level_up_state(p_player_id UUID,p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID,campaign_id UUID,pending BOOLEAN,from_level INTEGER,to_level INTEGER,
    rest_reason TEXT,ability_choices JSONB,created_at TIMESTAMPTZ,completed_at TIMESTAMPTZ)
LANGUAGE sql
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT s.character_id,s.campaign_id,s.pending,s.from_level,s.to_level,s.rest_reason,
           s.ability_choices,s.created_at,s.completed_at
    FROM public.discord_character_level_up_state s
    JOIN public.discord_characters c ON c.character_id=s.character_id
    WHERE c.player_id=p_player_id AND c.campaign_id=p_campaign_id AND s.campaign_id=p_campaign_id
    LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.discord_save_level_up_choices(UUID,UUID,JSONB);
CREATE OR REPLACE FUNCTION public.discord_save_level_up_choices(
    p_player_id UUID,p_campaign_id UUID,p_choices JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_state public.discord_character_level_up_state%ROWTYPE;
    v_choices JSONB := COALESCE(p_choices,'{}'::jsonb);
BEGIN
    SELECT * INTO v_character FROM public.discord_characters c
    WHERE c.player_id=p_player_id AND c.campaign_id=p_campaign_id LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT * INTO v_state FROM public.discord_character_level_up_state s
    WHERE s.character_id=v_character.character_id AND s.pending=TRUE FOR UPDATE;
    IF v_state.character_id IS NULL THEN RAISE EXCEPTION 'No post-rest level-up choices are waiting for this character.'; END IF;

    UPDATE public.discord_character_level_up_state
    SET ability_choices=v_choices,pending=FALSE,completed_at=NOW()
    WHERE character_id=v_character.character_id;

    UPDATE public.discord_characters c
    SET character_data=jsonb_set(
            COALESCE(c.character_data,'{}'::jsonb),
            '{lastLevelUp}',
            jsonb_build_object('fromLevel',v_state.from_level,'toLevel',v_state.to_level,'choices',v_choices,'completedAt',NOW()),
            TRUE),
        updated_at=NOW()
    WHERE c.character_id=v_character.character_id;

    RETURN jsonb_build_object('character_id',v_character.character_id,'from_level',v_state.from_level,
        'to_level',v_state.to_level,'choices',v_choices);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_award_monster_xp(UUID,TEXT,TEXT,INTEGER);
CREATE OR REPLACE FUNCTION public.discord_gm_award_monster_xp(
    p_campaign_id UUID,p_display_name TEXT,p_challenge_rating TEXT,p_total_xp INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_monster public.discord_campaign_combat_monsters%ROWTYPE;
    v_count INTEGER:=0;
    v_base INTEGER:=0;
    v_remainder INTEGER:=0;
    v_index INTEGER:=0;
    v_share INTEGER:=0;
    v_inserted INTEGER:=0;
    v_recipients JSONB:='[]'::jsonb;
    r RECORD;
BEGIN
    IF COALESCE(p_total_xp,0)<=0 THEN RAISE EXCEPTION 'Monster XP must be greater than zero.'; END IF;
    SELECT * INTO v_monster FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND lower(m.display_name)=lower(trim(COALESCE(p_display_name,'')))
    ORDER BY m.created_at DESC LIMIT 1;
    IF v_monster.combat_monster_id IS NULL THEN RAISE EXCEPTION 'Combat monster could not be found.'; END IF;
    IF COALESCE(v_monster.defeated,FALSE)=FALSE AND COALESCE(v_monster.current_hp,0)>0 THEN
        RAISE EXCEPTION '% has not been defeated.',v_monster.display_name;
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.discord_campaign_combat_initiative i
    WHERE i.campaign_id=p_campaign_id AND i.entity_type='character' AND i.character_id IS NOT NULL;

    IF v_count=0 THEN
        SELECT COUNT(*) INTO v_count FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id AND COALESCE(c.life_state,'alive')='alive'
          AND EXISTS(SELECT 1 FROM public.discord_campaign_presence pr
              WHERE pr.campaign_id=p_campaign_id AND pr.player_id=c.player_id
                AND pr.last_seen_at>=NOW()-INTERVAL '15 seconds');
    END IF;
    IF v_count=0 THEN RETURN jsonb_build_object('awarded',FALSE,'reason','No participating characters were available.'); END IF;

    v_base:=p_total_xp/v_count;
    v_remainder:=p_total_xp%v_count;

    FOR r IN
        SELECT c.character_id,c.character_name
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND (
            EXISTS(SELECT 1 FROM public.discord_campaign_combat_initiative i
                WHERE i.campaign_id=p_campaign_id AND i.entity_type='character' AND i.character_id=c.character_id)
            OR (
                NOT EXISTS(SELECT 1 FROM public.discord_campaign_combat_initiative i2 WHERE i2.campaign_id=p_campaign_id AND i2.entity_type='character')
                AND COALESCE(c.life_state,'alive')='alive'
                AND EXISTS(SELECT 1 FROM public.discord_campaign_presence pr
                    WHERE pr.campaign_id=p_campaign_id AND pr.player_id=c.player_id
                      AND pr.last_seen_at>=NOW()-INTERVAL '15 seconds')
            )
          )
        ORDER BY lower(c.character_name),c.character_id
    LOOP
        v_index:=v_index+1;
        v_share:=v_base+CASE WHEN v_index<=v_remainder THEN 1 ELSE 0 END;
        IF v_share<=0 THEN CONTINUE; END IF;

        INSERT INTO public.discord_experience_awards(campaign_id,character_id,award_key,award_type,source_name,xp_amount,award_data)
        VALUES(p_campaign_id,r.character_id,'monster:'||v_monster.combat_monster_id,'monster',v_monster.display_name,v_share,
            jsonb_build_object('monsterName',v_monster.monster_name,'challengeRating',COALESCE(p_challenge_rating,''),'totalMonsterXp',p_total_xp))
        ON CONFLICT(character_id,award_key) DO NOTHING;

        IF FOUND THEN
            UPDATE public.discord_characters c
            SET experience=COALESCE(c.experience,0)+v_share,
                character_data=jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{experience}',to_jsonb(COALESCE(c.experience,0)+v_share),TRUE),
                updated_at=NOW()
            WHERE c.character_id=r.character_id;
            v_inserted:=v_inserted+1;
        END IF;
        v_recipients:=v_recipients||jsonb_build_array(jsonb_build_object('characterName',r.character_name,'xp',v_share));
    END LOOP;

    RETURN jsonb_build_object('awarded',v_inserted>0,'monsterName',v_monster.monster_name,'displayName',v_monster.display_name,
        'challengeRating',COALESCE(p_challenge_rating,''),'totalXp',p_total_xp,'participantCount',v_count,'recipients',v_recipients);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_award_quest_xp(UUID,TEXT,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_award_quest_xp(
    p_campaign_id UUID,p_quest_key TEXT,p_quest_name TEXT,p_xp_per_character INTEGER,p_difficulty TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_key TEXT:=lower(trim(COALESCE(p_quest_key,'')));
    v_inserted INTEGER:=0;
    v_recipients JSONB:='[]'::jsonb;
    r RECORD;
BEGIN
    IF v_key='' THEN RAISE EXCEPTION 'Quest key is required.'; END IF;
    IF COALESCE(p_xp_per_character,0)<=0 THEN RAISE EXCEPTION 'Quest XP must be greater than zero.'; END IF;

    FOR r IN SELECT c.character_id,c.character_name FROM public.discord_characters c
             WHERE c.campaign_id=p_campaign_id ORDER BY lower(c.character_name),c.character_id
    LOOP
        INSERT INTO public.discord_experience_awards(campaign_id,character_id,award_key,award_type,source_name,xp_amount,award_data)
        VALUES(p_campaign_id,r.character_id,'quest:'||v_key,'quest',trim(COALESCE(p_quest_name,'')),p_xp_per_character,
            jsonb_build_object('difficulty',lower(trim(COALESCE(p_difficulty,'side')))))
        ON CONFLICT(character_id,award_key) DO NOTHING;
        IF FOUND THEN
            UPDATE public.discord_characters c
            SET experience=COALESCE(c.experience,0)+p_xp_per_character,
                character_data=jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{experience}',to_jsonb(COALESCE(c.experience,0)+p_xp_per_character),TRUE),
                updated_at=NOW()
            WHERE c.character_id=r.character_id;
            v_inserted:=v_inserted+1;
        END IF;
        v_recipients:=v_recipients||jsonb_build_array(jsonb_build_object('characterName',r.character_name,'xp',p_xp_per_character));
    END LOOP;

    RETURN jsonb_build_object('awarded',v_inserted>0,'questName',trim(COALESCE(p_quest_name,'')),
        'difficulty',lower(trim(COALESCE(p_difficulty,'side'))),'xpPerCharacter',p_xp_per_character,
        'recipientCount',v_inserted,'recipients',v_recipients);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_complete_long_rest(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_complete_long_rest(
    p_campaign_id UUID,p_character_name TEXT,p_reason TEXT)
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
BEGIN
    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        RAISE EXCEPTION 'A Long Rest cannot complete while combat is active.';
    END IF;

    SELECT * INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF COALESCE(v_character.life_state,'alive')<>'alive' THEN RAISE EXCEPTION '% cannot complete a Long Rest while dead.',v_character.character_name; END IF;
    IF EXISTS(SELECT 1 FROM public.discord_character_level_up_state s WHERE s.character_id=v_character.character_id AND s.pending=TRUE) THEN
        RAISE EXCEPTION '% still has unfinished choices from the previous level up.',v_character.character_name;
    END IF;

    v_from:=GREATEST(1,LEAST(20,COALESCE(v_character.level,1)));
    v_to:=GREATEST(v_from,public.discord_level_for_xp(v_character.experience));
    v_gain_per_level:=public.discord_fixed_hp_gain(v_character.class_name,v_character.constitution);
    v_hp_gain:=GREATEST(0,v_to-v_from)*v_gain_per_level;
    v_new_max:=GREATEST(1,COALESCE(v_character.max_hp,1)+v_hp_gain);
    v_is_caster:=lower(v_character.class_name) IN ('bard','cleric','druid','paladin','ranger','sorcerer','warlock','wizard');

    UPDATE public.discord_characters c
    SET level=v_to,
        proficiency_bonus=public.discord_proficiency_for_level(v_to),
        max_hp=v_new_max,
        current_hp=v_new_max,
        spells_complete=CASE WHEN v_to>v_from AND v_is_caster THEN FALSE ELSE c.spells_complete END,
        character_data=jsonb_set(
            jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{level}',to_jsonb(v_to),TRUE),
            '{current_hp}',to_jsonb(v_new_max),TRUE),
        updated_at=NOW()
    WHERE c.character_id=v_character.character_id;

    UPDATE public.discord_spell_slots SET used_slots=0 WHERE character_id=v_character.character_id;

    IF v_to>v_from THEN
        INSERT INTO public.discord_character_level_up_state(character_id,campaign_id,from_level,to_level,pending,rest_reason,ability_choices,created_at,completed_at)
        VALUES(v_character.character_id,p_campaign_id,v_from,v_to,TRUE,LEFT(trim(COALESCE(p_reason,'')),240),'{}'::jsonb,NOW(),NULL)
        ON CONFLICT(character_id) DO UPDATE SET campaign_id=EXCLUDED.campaign_id,from_level=EXCLUDED.from_level,to_level=EXCLUDED.to_level,
            pending=TRUE,rest_reason=EXCLUDED.rest_reason,ability_choices='{}'::jsonb,created_at=NOW(),completed_at=NULL;
    END IF;

    RETURN jsonb_build_object(
        'characterId',v_character.character_id,'characterName',v_character.character_name,
        'leveledUp',v_to>v_from,'fromLevel',v_from,'toLevel',v_to,'experience',v_character.experience,
        'hpGain',v_hp_gain,'maxHp',v_new_max,'proficiencyBonus',public.discord_proficiency_for_level(v_to),
        'spellSelectionRequired',v_to>v_from AND v_is_caster,'reason',LEFT(trim(COALESCE(p_reason,'')),240));
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_level_up_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_save_level_up_choices(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_award_monster_xp(UUID,TEXT,TEXT,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_award_quest_xp(UUID,TEXT,TEXT,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_level_up_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_save_level_up_choices(UUID,UUID,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_award_monster_xp(UUID,TEXT,TEXT,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_award_quest_xp(UUID,TEXT,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) TO service_role;

COMMIT;
