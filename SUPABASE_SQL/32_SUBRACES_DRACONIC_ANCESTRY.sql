-- RabuShinAIGM Rules Build 6.13
-- 2014 Subraces + Draconic Ancestry
-- Keeps Hill Dwarf Dwarven Toughness (+1 maximum HP per level) active during long-rest leveling.
-- Safe to rerun after Build 6.4 / later migrations.

BEGIN;

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
    v_subrace_hp_bonus INTEGER:=0;
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
    -- Build 6.13: subrace HP modifiers compound with the normal class/Constitution level gain.
    -- Hill Dwarf stores hitPointBonusPerLevel=1 in character_data.features.
    BEGIN
        v_subrace_hp_bonus:=GREATEST(0,COALESCE(NULLIF(v_character.character_data #>> '{features,hitPointBonusPerLevel}','')::INTEGER,0));
    EXCEPTION WHEN OTHERS THEN
        v_subrace_hp_bonus:=0;
    END;
    v_gain_per_level:=public.discord_fixed_hp_gain(v_character.class_name,v_character.constitution)+v_subrace_hp_bonus;
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


REVOKE ALL ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_gm_complete_long_rest(UUID,TEXT,TEXT) TO service_role;

COMMIT;
