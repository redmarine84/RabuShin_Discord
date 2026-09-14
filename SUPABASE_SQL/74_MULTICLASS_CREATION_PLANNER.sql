-- ============================================================
-- RabuShinAIGM Build 6.30.12.1
-- Migration 74 - Multiclass Character Creation Level Distribution
-- Requires Migration 73.
--
-- Adds creation-time multiclass distribution for manually-created
-- characters at total level 2-20. Level 1 always belongs to the
-- initial class. Levels 2..N may be divided among eligible classes.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_apply_creation_multiclass_plan(
    p_player_id UUID,
    p_character_id UUID,
    p_plan JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    c public.discord_characters%ROWTYPE;
    v_plan JSONB:=COALESCE(p_plan,'[]'::jsonb);
    v_initial TEXT;
    v_initial_ok BOOLEAN;
    v_has_secondary BOOLEAN:=FALSE;
    v_entry JSONB;
    v_index INTEGER:=0;
    v_expected_total INTEGER;
    v_class TEXT;
    v_existing BOOLEAN;
    v_class_level INTEGER;
    v_choices JSONB;
    v_skill TEXT;
    v_instrument TEXT;
    v_default_gain INTEGER;
    v_actual_gain INTEGER;
    v_hp_delta INTEGER:=0;
    v_new_max INTEGER;
    v_new_current INTEGER;
    v_any_caster BOOLEAN:=FALSE;
    v_summary TEXT;
    v_classes JSONB;
    v_stored_plan JSONB;
    v_data JSONB;
BEGIN
    SELECT *
    INTO c
    FROM public.discord_characters dc
    WHERE dc.character_id=p_character_id
      AND (
          dc.player_id=p_player_id
          OR EXISTS (
              SELECT 1
              FROM public.discord_solo_party_characters sp
              WHERE sp.character_id=dc.character_id
                AND sp.owner_player_id=p_player_id
          )
      )
    LIMIT 1
    FOR UPDATE;

    IF c.character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found or is not owned by this player.';
    END IF;

    IF COALESCE(c.level,1)<2 THEN
        RAISE EXCEPTION 'Creation-time multiclassing requires character level 2 or higher.';
    END IF;

    -- This operation belongs to the character creator. Once starting equipment
    -- is accepted, class distribution is finalized and normal level-up rules apply.
    IF COALESCE(c.equipment_complete,FALSE) THEN
        RAISE EXCEPTION 'Creation-time multiclass distribution is already finalized for this character.';
    END IF;

    IF jsonb_typeof(v_plan)<>'array' THEN
        RAISE EXCEPTION 'Creation multiclass plan must be an array.';
    END IF;
    IF jsonb_array_length(v_plan)<>GREATEST(0,c.level-1) THEN
        RAISE EXCEPTION 'Assign exactly one class for each character level after level 1 (% assignments required).',
            GREATEST(0,c.level-1);
    END IF;

    -- Network retries after a committed request are idempotent.
    IF COALESCE((c.character_data->>'creationMulticlassApplied')::BOOLEAN,FALSE) THEN
        v_stored_plan:=COALESCE(c.character_data->'creationMulticlassPlan','[]'::jsonb);
        IF v_stored_plan=v_plan THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'className',cc.class_name,'level',cc.class_level,'isInitial',cc.is_initial,
                       'firstTotalLevel',cc.first_total_level,'gainedProficiencies',cc.gained_proficiencies)
                       ORDER BY cc.first_total_level,cc.class_name),'[]'::jsonb)
            INTO v_classes
            FROM public.discord_character_classes cc
            WHERE cc.character_id=c.character_id;

            RETURN jsonb_build_object(
                'success',TRUE,
                'characterId',c.character_id,
                'summary',COALESCE(public.discord_multiclass_summary(c.character_id),c.class_name||' '||c.level),
                'classes',v_classes,
                'needsSpellSelection',EXISTS(
                    SELECT 1 FROM public.discord_character_classes cc
                    WHERE cc.character_id=c.character_id
                      AND public.discord_multiclass_is_spellcaster(cc.class_name)),
                'idempotent',TRUE);
        END IF;
        RAISE EXCEPTION 'This character''s creation-time multiclass distribution has already been finalized.';
    END IF;

    v_initial:=public.discord_multiclass_canonical_class(c.class_name);
    IF v_initial IS NULL THEN
        RAISE EXCEPTION 'Initial class % is not supported by multiclassing.',c.class_name;
    END IF;

    -- Determine whether the plan actually enters another class.
    FOR v_entry IN SELECT value FROM jsonb_array_elements(v_plan)
    LOOP
        v_class:=public.discord_multiclass_canonical_class(v_entry->>'className');
        IF v_class IS NULL THEN
            RAISE EXCEPTION 'Unknown multiclass selection: %.',COALESCE(v_entry->>'className','');
        END IF;
        IF lower(v_class)<>lower(v_initial) THEN v_has_secondary:=TRUE; END IF;
    END LOOP;

    v_initial_ok:=public.discord_multiclass_requirement_met(
        v_initial,c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma);

    IF v_has_secondary AND NOT v_initial_ok THEN
        RAISE EXCEPTION 'You must meet the % multiclass prerequisite (%) before taking another class.',
            v_initial,public.discord_multiclass_requirement_text(v_initial);
    END IF;

    -- The base manual creator built HP and Hit Dice as if every level were in
    -- the initial class. Rebuild the class ledgers and apply only the HP
    -- difference for levels 2..N, preserving racial HP bonuses.
    DELETE FROM public.discord_multiclass_level_history
    WHERE character_id=c.character_id;

    DELETE FROM public.discord_character_hit_dice_pools
    WHERE character_id=c.character_id;

    DELETE FROM public.discord_character_classes
    WHERE character_id=c.character_id;

    INSERT INTO public.discord_character_classes(
        character_id,class_name,class_level,is_initial,first_total_level,gained_proficiencies)
    VALUES(c.character_id,v_initial,1,TRUE,1,'{}'::jsonb);

    INSERT INTO public.discord_character_hit_dice_pools(
        character_id,class_name,die_sides,total_dice,spent_dice)
    VALUES(c.character_id,v_initial,public.discord_multiclass_hit_die_sides(v_initial),1,0);

    v_default_gain:=public.discord_multiclass_fixed_hp_gain(v_initial,c.constitution);

    FOR v_entry IN SELECT value FROM jsonb_array_elements(v_plan)
    LOOP
        v_index:=v_index+1;
        v_expected_total:=v_index+1;

        IF COALESCE((v_entry->>'totalLevel')::INTEGER,v_expected_total)<>v_expected_total THEN
            RAISE EXCEPTION 'Creation level plan is out of order. Expected total level %.',v_expected_total;
        END IF;

        v_class:=public.discord_multiclass_canonical_class(v_entry->>'className');
        IF v_class IS NULL THEN
            RAISE EXCEPTION 'Unknown multiclass selection: %.',COALESCE(v_entry->>'className','');
        END IF;

        v_choices:=CASE
            WHEN jsonb_typeof(v_entry->'proficiencyChoices')='object'
                THEN v_entry->'proficiencyChoices'
            ELSE '{}'::jsonb
        END;

        SELECT EXISTS(
            SELECT 1 FROM public.discord_character_classes cc
            WHERE cc.character_id=c.character_id
              AND lower(cc.class_name)=lower(v_class))
        INTO v_existing;

        IF NOT v_existing THEN
            IF NOT public.discord_multiclass_requirement_met(
                v_class,c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma) THEN
                RAISE EXCEPTION 'You do not meet the % multiclass prerequisite (%).',
                    v_class,public.discord_multiclass_requirement_text(v_class);
            END IF;

            v_skill:=trim(COALESCE(v_choices->>'skill',''));
            v_instrument:=trim(COALESCE(v_choices->>'instrument',''));

            IF lower(v_class) IN ('bard','ranger','rogue') AND v_skill='' THEN
                RAISE EXCEPTION '% multiclassing requires the granted skill proficiency.',v_class;
            END IF;
            IF lower(v_class)='bard' AND v_instrument='' THEN
                RAISE EXCEPTION 'Bard multiclassing requires a musical instrument proficiency.';
            END IF;

            IF lower(v_class)='bard' AND lower(v_skill) NOT IN (
                'acrobatics','animal handling','arcana','athletics','deception','history','insight','intimidation',
                'investigation','medicine','nature','perception','performance','persuasion','religion',
                'sleight of hand','stealth','survival') THEN
                RAISE EXCEPTION 'Choose a valid skill proficiency for the Bard multiclass.';
            END IF;
            IF lower(v_class)='ranger' AND lower(v_skill) NOT IN (
                'animal handling','athletics','insight','investigation','nature','perception','stealth','survival') THEN
                RAISE EXCEPTION 'Choose a skill from the Ranger class skill list.';
            END IF;
            IF lower(v_class)='rogue' AND lower(v_skill) NOT IN (
                'acrobatics','athletics','deception','insight','intimidation','investigation','perception',
                'performance','persuasion','sleight of hand','stealth') THEN
                RAISE EXCEPTION 'Choose a skill from the Rogue class skill list.';
            END IF;

            INSERT INTO public.discord_character_classes(
                character_id,class_name,class_level,is_initial,first_total_level,gained_proficiencies)
            VALUES(
                c.character_id,v_class,1,FALSE,v_expected_total,
                public.discord_multiclass_proficiency_template(v_class,v_choices));
            v_class_level:=1;
        ELSE
            UPDATE public.discord_character_classes cc
            SET class_level=cc.class_level+1,updated_at=NOW()
            WHERE cc.character_id=c.character_id
              AND lower(cc.class_name)=lower(v_class)
            RETURNING cc.class_level INTO v_class_level;
        END IF;

        v_actual_gain:=public.discord_multiclass_fixed_hp_gain(v_class,c.constitution);
        v_hp_delta:=v_hp_delta+(v_actual_gain-v_default_gain);

        INSERT INTO public.discord_character_hit_dice_pools(
            character_id,class_name,die_sides,total_dice,spent_dice)
        VALUES(
            c.character_id,v_class,public.discord_multiclass_hit_die_sides(v_class),1,0)
        ON CONFLICT(character_id,class_name) DO UPDATE
        SET total_dice=public.discord_character_hit_dice_pools.total_dice+1,
            spent_dice=0;

        INSERT INTO public.discord_multiclass_level_history(
            character_id,total_level,class_name,class_level_after,hp_gain,proficiency_choices)
        VALUES(
            c.character_id,v_expected_total,v_class,v_class_level,v_actual_gain,v_choices);
    END LOOP;

    SELECT EXISTS(
        SELECT 1 FROM public.discord_character_classes cc
        WHERE cc.character_id=c.character_id
          AND public.discord_multiclass_is_spellcaster(cc.class_name))
    INTO v_any_caster;

    v_new_max:=GREATEST(1,c.max_hp+v_hp_delta);
    v_new_current:=LEAST(v_new_max,GREATEST(1,c.current_hp+v_hp_delta));

    v_data:=COALESCE(c.character_data,'{}'::jsonb);
    v_data:=jsonb_set(v_data,'{max_hp}',to_jsonb(v_new_max),TRUE);
    v_data:=jsonb_set(v_data,'{current_hp}',to_jsonb(v_new_current),TRUE);
    v_data:=jsonb_set(v_data,'{creationMulticlassApplied}','true'::jsonb,TRUE);
    v_data:=jsonb_set(v_data,'{creationMulticlassPlan}',v_plan,TRUE);

    UPDATE public.discord_characters dc
    SET max_hp=v_new_max,
        current_hp=v_new_current,
        hit_dice_spent=0,
        spells_complete=CASE WHEN v_any_caster THEN FALSE ELSE dc.spells_complete END,
        character_data=v_data,
        updated_at=NOW()
    WHERE dc.character_id=c.character_id;

    PERFORM public.discord_sync_multiclass_character_data(c.character_id);
    PERFORM public.discord_multiclass_sync_spell_slots(c.character_id);

    v_summary:=COALESCE(public.discord_multiclass_summary(c.character_id),v_initial||' '||c.level);

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'className',cc.class_name,'level',cc.class_level,'isInitial',cc.is_initial,
               'firstTotalLevel',cc.first_total_level,'gainedProficiencies',cc.gained_proficiencies)
               ORDER BY cc.first_total_level,cc.class_name),'[]'::jsonb)
    INTO v_classes
    FROM public.discord_character_classes cc
    WHERE cc.character_id=c.character_id;

    RETURN jsonb_build_object(
        'success',TRUE,
        'characterId',c.character_id,
        'totalLevel',c.level,
        'initialClass',v_initial,
        'summary',v_summary,
        'classes',v_classes,
        'hpAdjustment',v_hp_delta,
        'maxHp',v_new_max,
        'currentHp',v_new_current,
        'needsSpellSelection',v_any_caster,
        'idempotent',FALSE);
END;
$$;

-- Cleanup is called only if the C# creation flow receives an error after the
-- base character row was inserted. It will never delete a character whose
-- creation multiclass plan successfully committed.
CREATE OR REPLACE FUNCTION public.discord_delete_failed_creation_multiclass_character(
    p_player_id UUID,
    p_character_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    c public.discord_characters%ROWTYPE;
    v_control_player_id UUID;
    v_campaign_id UUID;
BEGIN
    SELECT *
    INTO c
    FROM public.discord_characters dc
    WHERE dc.character_id=p_character_id
      AND (
          dc.player_id=p_player_id
          OR EXISTS (
              SELECT 1
              FROM public.discord_solo_party_characters sp
              WHERE sp.character_id=dc.character_id
                AND sp.owner_player_id=p_player_id
          )
      )
    LIMIT 1
    FOR UPDATE;

    IF c.character_id IS NULL THEN RETURN FALSE; END IF;
    IF COALESCE((c.character_data->>'creationMulticlassApplied')::BOOLEAN,FALSE) THEN
        RETURN FALSE;
    END IF;
    IF COALESCE(c.equipment_complete,FALSE) THEN
        RETURN FALSE;
    END IF;

    SELECT sp.control_player_id,sp.campaign_id
    INTO v_control_player_id,v_campaign_id
    FROM public.discord_solo_party_characters sp
    WHERE sp.character_id=c.character_id
      AND sp.owner_player_id=p_player_id
    LIMIT 1;

    DELETE FROM public.discord_characters
    WHERE character_id=c.character_id;

    -- A failed additional Solo companion was created under a synthetic control
    -- player. Remove that now-unused synthetic identity as part of rollback.
    IF v_control_player_id IS NOT NULL AND v_control_player_id<>p_player_id THEN
        DELETE FROM public.discord_campaign_members
        WHERE campaign_id=v_campaign_id AND player_id=v_control_player_id;
        DELETE FROM public.discord_players p
        WHERE p.player_id=v_control_player_id
          AND p.discord_user_id LIKE 'solo:%'
          AND NOT EXISTS (
              SELECT 1 FROM public.discord_characters dc
              WHERE dc.player_id=v_control_player_id);
    END IF;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_apply_creation_multiclass_plan(UUID,UUID,JSONB)
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_delete_failed_creation_multiclass_character(UUID,UUID)
FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_apply_creation_multiclass_plan(UUID,UUID,JSONB)
TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_delete_failed_creation_multiclass_character(UUID,UUID)
TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
