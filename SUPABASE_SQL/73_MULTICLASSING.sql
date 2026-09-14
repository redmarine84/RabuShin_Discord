-- ============================================================
-- RabuShinAIGM Build 6.30.12
-- Migration 73 - Multiclassing
-- Rules source: https://5thsrd.org/rules/multiclassing/
--
-- Core guarantees:
--   * total character level remains discord_characters.level
--   * per-class levels are stored separately
--   * multiclass ability prerequisites are enforced server-side
--   * no starting equipment or saving-throw proficiencies are granted by multiclassing
--   * reduced multiclass proficiencies are recorded
--   * HP gained by a new class uses that class's post-1st-level hit die average
--   * Hit Dice are tracked by class/die size
--   * normal multiclass spell slots use effective caster level
--   * Warlock Pact Magic remains a separate slot pool and can cross-cast
--   * class summaries are persisted into character_data for the AI GM/client
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_character_classes
(
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    class_name TEXT NOT NULL,
    class_level INTEGER NOT NULL CHECK(class_level BETWEEN 1 AND 20),
    is_initial BOOLEAN NOT NULL DEFAULT FALSE,
    first_total_level INTEGER NOT NULL DEFAULT 1 CHECK(first_total_level BETWEEN 1 AND 20),
    subclass_name TEXT NOT NULL DEFAULT '',
    gained_proficiencies JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(character_id,class_name)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_discord_character_initial_class
ON public.discord_character_classes(character_id)
WHERE is_initial=TRUE;

CREATE TABLE IF NOT EXISTS public.discord_character_hit_dice_pools
(
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    class_name TEXT NOT NULL,
    die_sides INTEGER NOT NULL CHECK(die_sides IN (6,8,10,12)),
    total_dice INTEGER NOT NULL DEFAULT 0 CHECK(total_dice>=0),
    spent_dice INTEGER NOT NULL DEFAULT 0 CHECK(spent_dice>=0 AND spent_dice<=total_dice),
    PRIMARY KEY(character_id,class_name)
);

CREATE TABLE IF NOT EXISTS public.discord_multiclass_level_history
(
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    total_level INTEGER NOT NULL CHECK(total_level BETWEEN 2 AND 20),
    class_name TEXT NOT NULL,
    class_level_after INTEGER NOT NULL CHECK(class_level_after BETWEEN 1 AND 20),
    hp_gain INTEGER NOT NULL,
    proficiency_choices JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(character_id,total_level)
);

CREATE TABLE IF NOT EXISTS public.discord_multiclass_spell_slot_pools
(
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    pool_kind TEXT NOT NULL CHECK(pool_kind IN ('shared','pact')),
    spell_level INTEGER NOT NULL CHECK(spell_level BETWEEN 1 AND 9),
    max_slots INTEGER NOT NULL DEFAULT 0 CHECK(max_slots>=0),
    used_slots INTEGER NOT NULL DEFAULT 0 CHECK(used_slots>=0 AND used_slots<=max_slots),
    PRIMARY KEY(character_id,pool_kind,spell_level)
);

ALTER TABLE public.discord_character_classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_character_hit_dice_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_multiclass_level_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_multiclass_spell_slot_pools ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_character_classes FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.discord_character_hit_dice_pools FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.discord_multiclass_level_history FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.discord_multiclass_spell_slot_pools FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.discord_character_classes TO service_role;
GRANT ALL ON public.discord_character_hit_dice_pools TO service_role;
GRANT ALL ON public.discord_multiclass_level_history TO service_role;
GRANT ALL ON public.discord_multiclass_spell_slot_pools TO service_role;

CREATE OR REPLACE FUNCTION public.discord_multiclass_canonical_class(p_class TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE lower(trim(COALESCE(p_class,'')))
    WHEN 'artificer' THEN 'Artificer'
    WHEN 'barbarian' THEN 'Barbarian'
    WHEN 'bard' THEN 'Bard'
    WHEN 'cleric' THEN 'Cleric'
    WHEN 'druid' THEN 'Druid'
    WHEN 'fighter' THEN 'Fighter'
    WHEN 'monk' THEN 'Monk'
    WHEN 'paladin' THEN 'Paladin'
    WHEN 'ranger' THEN 'Ranger'
    WHEN 'rogue' THEN 'Rogue'
    WHEN 'sorcerer' THEN 'Sorcerer'
    WHEN 'warlock' THEN 'Warlock'
    WHEN 'wizard' THEN 'Wizard'
    ELSE NULL END;
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_requirement_text(p_class TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE lower(trim(COALESCE(p_class,'')))
    WHEN 'artificer' THEN 'INT 13'
    WHEN 'barbarian' THEN 'STR 13'
    WHEN 'bard' THEN 'CHA 13'
    WHEN 'cleric' THEN 'WIS 13'
    WHEN 'druid' THEN 'WIS 13'
    WHEN 'fighter' THEN 'STR 13 or DEX 13'
    WHEN 'monk' THEN 'DEX 13 and WIS 13'
    WHEN 'paladin' THEN 'STR 13 and CHA 13'
    WHEN 'ranger' THEN 'DEX 13 and WIS 13'
    WHEN 'rogue' THEN 'DEX 13'
    WHEN 'sorcerer' THEN 'CHA 13'
    WHEN 'warlock' THEN 'CHA 13'
    WHEN 'wizard' THEN 'INT 13'
    ELSE 'Unknown class' END;
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_requirement_met(
    p_class TEXT,p_strength INTEGER,p_dexterity INTEGER,p_constitution INTEGER,
    p_intelligence INTEGER,p_wisdom INTEGER,p_charisma INTEGER)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE lower(trim(COALESCE(p_class,'')))
    WHEN 'artificer' THEN COALESCE(p_intelligence,0)>=13
    WHEN 'barbarian' THEN COALESCE(p_strength,0)>=13
    WHEN 'bard' THEN COALESCE(p_charisma,0)>=13
    WHEN 'cleric' THEN COALESCE(p_wisdom,0)>=13
    WHEN 'druid' THEN COALESCE(p_wisdom,0)>=13
    WHEN 'fighter' THEN COALESCE(p_strength,0)>=13 OR COALESCE(p_dexterity,0)>=13
    WHEN 'monk' THEN COALESCE(p_dexterity,0)>=13 AND COALESCE(p_wisdom,0)>=13
    WHEN 'paladin' THEN COALESCE(p_strength,0)>=13 AND COALESCE(p_charisma,0)>=13
    WHEN 'ranger' THEN COALESCE(p_dexterity,0)>=13 AND COALESCE(p_wisdom,0)>=13
    WHEN 'rogue' THEN COALESCE(p_dexterity,0)>=13
    WHEN 'sorcerer' THEN COALESCE(p_charisma,0)>=13
    WHEN 'warlock' THEN COALESCE(p_charisma,0)>=13
    WHEN 'wizard' THEN COALESCE(p_intelligence,0)>=13
    ELSE FALSE END;
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_hit_die_sides(p_class TEXT)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE lower(trim(COALESCE(p_class,'')))
    WHEN 'barbarian' THEN 12
    WHEN 'fighter' THEN 10 WHEN 'paladin' THEN 10 WHEN 'ranger' THEN 10
    WHEN 'artificer' THEN 8 WHEN 'bard' THEN 8 WHEN 'cleric' THEN 8 WHEN 'druid' THEN 8
    WHEN 'monk' THEN 8 WHEN 'rogue' THEN 8 WHEN 'warlock' THEN 8
    WHEN 'sorcerer' THEN 6 WHEN 'wizard' THEN 6
    ELSE 8 END;
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_fixed_hp_gain(p_class TEXT,p_constitution INTEGER)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
SELECT GREATEST(1,
    CASE lower(trim(COALESCE(p_class,'')))
        WHEN 'barbarian' THEN 7
        WHEN 'fighter' THEN 6 WHEN 'paladin' THEN 6 WHEN 'ranger' THEN 6
        WHEN 'artificer' THEN 5 WHEN 'bard' THEN 5 WHEN 'cleric' THEN 5 WHEN 'druid' THEN 5
        WHEN 'monk' THEN 5 WHEN 'rogue' THEN 5 WHEN 'warlock' THEN 5
        WHEN 'sorcerer' THEN 4 WHEN 'wizard' THEN 4
        ELSE 5 END
    + FLOOR((COALESCE(p_constitution,10)-10)::NUMERIC/2)::INTEGER);
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_is_spellcaster(p_class TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
SELECT lower(trim(COALESCE(p_class,''))) IN
('artificer','bard','cleric','druid','paladin','ranger','sorcerer','warlock','wizard');
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_proficiency_template(p_class TEXT,p_choices JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_class TEXT:=lower(trim(COALESCE(p_class,'')));
    v_skill TEXT:=trim(COALESCE(p_choices->>'skill',''));
    v_instrument TEXT:=trim(COALESCE(p_choices->>'instrument',''));
BEGIN
    RETURN CASE v_class
        WHEN 'artificer' THEN jsonb_build_object('armor',jsonb_build_array('Light armor','Medium armor','Shields'),'tools',jsonb_build_array('Thieves'' tools','Tinker''s tools'),'note','RabuShin Artificer extension')
        WHEN 'barbarian' THEN jsonb_build_object('armor',jsonb_build_array('Shields'),'weapons',jsonb_build_array('Simple weapons','Martial weapons'))
        WHEN 'bard' THEN jsonb_build_object('armor',jsonb_build_array('Light armor'),'skills',jsonb_build_array(v_skill),'instruments',jsonb_build_array(v_instrument))
        WHEN 'cleric' THEN jsonb_build_object('armor',jsonb_build_array('Light armor','Medium armor','Shields'))
        WHEN 'druid' THEN jsonb_build_object('armor',jsonb_build_array('Light armor','Medium armor','Shields'))
        WHEN 'fighter' THEN jsonb_build_object('armor',jsonb_build_array('Light armor','Medium armor','Shields'),'weapons',jsonb_build_array('Simple weapons','Martial weapons'))
        WHEN 'monk' THEN jsonb_build_object('weapons',jsonb_build_array('Simple weapons','Shortswords'))
        WHEN 'paladin' THEN jsonb_build_object('armor',jsonb_build_array('Light armor','Medium armor','Shields'),'weapons',jsonb_build_array('Simple weapons','Martial weapons'))
        WHEN 'ranger' THEN jsonb_build_object('armor',jsonb_build_array('Light armor','Medium armor','Shields'),'weapons',jsonb_build_array('Simple weapons','Martial weapons'),'skills',jsonb_build_array(v_skill))
        WHEN 'rogue' THEN jsonb_build_object('armor',jsonb_build_array('Light armor'),'skills',jsonb_build_array(v_skill),'tools',jsonb_build_array('Thieves'' tools'))
        WHEN 'sorcerer' THEN '{}'::jsonb
        WHEN 'warlock' THEN jsonb_build_object('armor',jsonb_build_array('Light armor'),'weapons',jsonb_build_array('Simple weapons'))
        WHEN 'wizard' THEN '{}'::jsonb
        ELSE '{}'::jsonb END;
END;
$$;

-- Existing characters begin with all current levels in their stored class.
INSERT INTO public.discord_character_classes(character_id,class_name,class_level,is_initial,first_total_level)
SELECT c.character_id,public.discord_multiclass_canonical_class(c.class_name),GREATEST(1,LEAST(20,c.level)),TRUE,1
FROM public.discord_characters c
WHERE public.discord_multiclass_canonical_class(c.class_name) IS NOT NULL
ON CONFLICT(character_id,class_name) DO NOTHING;

INSERT INTO public.discord_character_hit_dice_pools(character_id,class_name,die_sides,total_dice,spent_dice)
SELECT c.character_id,public.discord_multiclass_canonical_class(c.class_name),
       public.discord_multiclass_hit_die_sides(c.class_name),GREATEST(1,LEAST(20,c.level)),
       GREATEST(0,LEAST(GREATEST(1,LEAST(20,c.level)),COALESCE(c.hit_dice_spent,0)))
FROM public.discord_characters c
WHERE public.discord_multiclass_canonical_class(c.class_name) IS NOT NULL
ON CONFLICT(character_id,class_name) DO UPDATE SET
    total_dice=GREATEST(discord_character_hit_dice_pools.total_dice,EXCLUDED.total_dice),
    spent_dice=LEAST(GREATEST(discord_character_hit_dice_pools.spent_dice,EXCLUDED.spent_dice),GREATEST(discord_character_hit_dice_pools.total_dice,EXCLUDED.total_dice));

CREATE OR REPLACE FUNCTION public.discord_multiclass_summary(p_character_id UUID)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
SELECT string_agg(cc.class_name||' '||cc.class_level,' / ' ORDER BY cc.first_total_level,cc.class_name)
FROM public.discord_character_classes cc
WHERE cc.character_id=p_character_id;
$$;

CREATE OR REPLACE FUNCTION public.discord_sync_multiclass_character_data(p_character_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_classes JSONB;
    v_summary TEXT;
    v_profs JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'className',cc.class_name,'level',cc.class_level,'isInitial',cc.is_initial,
               'subclassName',cc.subclass_name,'firstTotalLevel',cc.first_total_level,
               'gainedProficiencies',cc.gained_proficiencies)
               ORDER BY cc.first_total_level,cc.class_name),'[]'::jsonb),
           COALESCE(public.discord_multiclass_summary(p_character_id),'')
    INTO v_classes,v_summary
    FROM public.discord_character_classes cc
    WHERE cc.character_id=p_character_id;

    SELECT COALESCE(jsonb_object_agg(cc.class_name,cc.gained_proficiencies),'{}'::jsonb)
    INTO v_profs
    FROM public.discord_character_classes cc
    WHERE cc.character_id=p_character_id AND cc.gained_proficiencies<>'{}'::jsonb;

    UPDATE public.discord_characters c
    SET character_data=jsonb_set(
            jsonb_set(
                jsonb_set(COALESCE(c.character_data,'{}'::jsonb),'{multiclassClasses}',v_classes,TRUE),
                '{multiclassSummary}',to_jsonb(v_summary),TRUE),
            '{multiclassProficiencies}',COALESCE(v_profs,'{}'::jsonb),TRUE),
        updated_at=NOW()
    WHERE c.character_id=p_character_id;
END;
$$;

SELECT public.discord_sync_multiclass_character_data(c.character_id)
FROM public.discord_characters c;

-- Extend the existing skill-proficiency helper so server systems such as
-- harvesting/foraging recognize skill proficiencies gained from multiclassing.
CREATE OR REPLACE FUNCTION public.discord_character_has_skill_proficiency(
    p_character_data JSONB,
    p_skill TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_skill TEXT:=LOWER(TRIM(COALESCE(p_skill,'')));
    v_value JSONB;
    v_entry TEXT;
BEGIN
    IF v_skill='' OR p_character_data IS NULL OR jsonb_typeof(p_character_data)<>'object' THEN RETURN FALSE; END IF;

    FOR v_value IN
        SELECT value FROM jsonb_array_elements(
            CASE
                WHEN jsonb_typeof(p_character_data->'skillProficiencies')='array' THEN p_character_data->'skillProficiencies'
                WHEN jsonb_typeof(p_character_data->'skill_proficiencies')='array' THEN p_character_data->'skill_proficiencies'
                WHEN jsonb_typeof(p_character_data->'skills')='array' THEN p_character_data->'skills'
                WHEN jsonb_typeof(p_character_data#>'{proficiencies,skills}')='array' THEN p_character_data#>'{proficiencies,skills}'
                ELSE '[]'::jsonb END)
    LOOP
        v_entry:=LOWER(TRIM(BOTH '"' FROM v_value::TEXT));
        IF v_entry=v_skill THEN RETURN TRUE; END IF;
    END LOOP;

    IF jsonb_typeof(p_character_data->'skills')='object' AND EXISTS (
        SELECT 1 FROM jsonb_each(p_character_data->'skills') s
        WHERE LOWER(s.key)=v_skill AND (s.value='true'::jsonb OR LOWER(TRIM(BOTH '"' FROM s.value::TEXT)) IN ('proficient','true','yes'))
    ) THEN RETURN TRUE; END IF;

    IF jsonb_typeof(p_character_data->'multiclassProficiencies')='object' AND EXISTS (
        SELECT 1
        FROM jsonb_each(p_character_data->'multiclassProficiencies') mc,
             LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(mc.value->'skills')='array' THEN mc.value->'skills' ELSE '[]'::jsonb END) sk
        WHERE LOWER(TRIM(sk.value))=v_skill
    ) THEN RETURN TRUE; END IF;

    RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_seed_multiclass_character()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_class TEXT;
BEGIN
    v_class:=public.discord_multiclass_canonical_class(NEW.class_name);
    IF v_class IS NULL THEN RETURN NEW; END IF;
    INSERT INTO public.discord_character_classes(character_id,class_name,class_level,is_initial,first_total_level)
    VALUES(NEW.character_id,v_class,GREATEST(1,LEAST(20,NEW.level)),TRUE,1)
    ON CONFLICT(character_id,class_name) DO NOTHING;
    INSERT INTO public.discord_character_hit_dice_pools(character_id,class_name,die_sides,total_dice,spent_dice)
    VALUES(NEW.character_id,v_class,public.discord_multiclass_hit_die_sides(v_class),GREATEST(1,LEAST(20,NEW.level)),0)
    ON CONFLICT(character_id,class_name) DO NOTHING;
    PERFORM public.discord_sync_multiclass_character_data(NEW.character_id);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_seed_multiclass_character ON public.discord_characters;
CREATE TRIGGER trg_discord_seed_multiclass_character
AFTER INSERT ON public.discord_characters
FOR EACH ROW EXECUTE FUNCTION public.discord_seed_multiclass_character();

-- Shared spell slot progression, indexed by effective caster level.
CREATE TABLE IF NOT EXISTS public.discord_multiclass_slot_progression
(
    caster_level INTEGER PRIMARY KEY CHECK(caster_level BETWEEN 1 AND 20),
    slots JSONB NOT NULL
);
INSERT INTO public.discord_multiclass_slot_progression(caster_level,slots) VALUES
(1,'{"1":2}'),(2,'{"1":3}'),(3,'{"1":4,"2":2}'),(4,'{"1":4,"2":3}'),
(5,'{"1":4,"2":3,"3":2}'),(6,'{"1":4,"2":3,"3":3}'),(7,'{"1":4,"2":3,"3":3,"4":1}'),
(8,'{"1":4,"2":3,"3":3,"4":2}'),(9,'{"1":4,"2":3,"3":3,"4":3,"5":1}'),
(10,'{"1":4,"2":3,"3":3,"4":3,"5":2}'),(11,'{"1":4,"2":3,"3":3,"4":3,"5":2,"6":1}'),
(12,'{"1":4,"2":3,"3":3,"4":3,"5":2,"6":1}'),(13,'{"1":4,"2":3,"3":3,"4":3,"5":2,"6":1,"7":1}'),
(14,'{"1":4,"2":3,"3":3,"4":3,"5":2,"6":1,"7":1}'),(15,'{"1":4,"2":3,"3":3,"4":3,"5":2,"6":1,"7":1,"8":1}'),
(16,'{"1":4,"2":3,"3":3,"4":3,"5":2,"6":1,"7":1,"8":1}'),
(17,'{"1":4,"2":3,"3":3,"4":3,"5":2,"6":1,"7":1,"8":1,"9":1}'),
(18,'{"1":4,"2":3,"3":3,"4":3,"5":3,"6":1,"7":1,"8":1,"9":1}'),
(19,'{"1":4,"2":3,"3":3,"4":3,"5":3,"6":2,"7":1,"8":1,"9":1}'),
(20,'{"1":4,"2":3,"3":3,"4":3,"5":3,"6":2,"7":2,"8":1,"9":1}')
ON CONFLICT(caster_level) DO UPDATE SET slots=EXCLUDED.slots;

ALTER TABLE public.discord_multiclass_slot_progression ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_multiclass_slot_progression FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.discord_multiclass_slot_progression TO service_role;

CREATE OR REPLACE FUNCTION public.discord_multiclass_sync_spell_slots(p_character_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_effective INTEGER:=0;
    v_warlock INTEGER:=0;
    v_slots JSONB;
    v_level INTEGER;
    v_count INTEGER;
    v_pact_level INTEGER:=0;
    v_pact_count INTEGER:=0;
BEGIN
    SELECT COALESCE(SUM(CASE lower(cc.class_name)
        WHEN 'bard' THEN cc.class_level WHEN 'cleric' THEN cc.class_level WHEN 'druid' THEN cc.class_level
        WHEN 'sorcerer' THEN cc.class_level WHEN 'wizard' THEN cc.class_level
        WHEN 'paladin' THEN FLOOR(cc.class_level/2.0)::INTEGER
        WHEN 'ranger' THEN FLOOR(cc.class_level/2.0)::INTEGER
        WHEN 'artificer' THEN CEIL(cc.class_level/2.0)::INTEGER
        ELSE 0 END),0),
        COALESCE(MAX(CASE WHEN lower(cc.class_name)='warlock' THEN cc.class_level ELSE 0 END),0)
    INTO v_effective,v_warlock
    FROM public.discord_character_classes cc
    WHERE cc.character_id=p_character_id;

    DELETE FROM public.discord_multiclass_spell_slot_pools WHERE character_id=p_character_id;

    IF v_effective>0 THEN
        SELECT sp.slots INTO v_slots
        FROM public.discord_multiclass_slot_progression sp
        WHERE sp.caster_level=LEAST(20,v_effective);
        FOR v_level IN 1..9 LOOP
            v_count:=COALESCE((v_slots->>v_level::TEXT)::INTEGER,0);
            IF v_count>0 THEN
                INSERT INTO public.discord_multiclass_spell_slot_pools(character_id,pool_kind,spell_level,max_slots,used_slots)
                VALUES(p_character_id,'shared',v_level,v_count,0);
            END IF;
        END LOOP;
    END IF;

    IF v_warlock>0 THEN
        v_pact_count:=CASE
            WHEN v_warlock=1 THEN 1
            WHEN v_warlock BETWEEN 2 AND 10 THEN 2
            WHEN v_warlock BETWEEN 11 AND 16 THEN 3
            ELSE 4 END;
        v_pact_level:=CASE
            WHEN v_warlock<=2 THEN 1
            WHEN v_warlock<=4 THEN 2
            WHEN v_warlock<=6 THEN 3
            WHEN v_warlock<=8 THEN 4
            ELSE 5 END;
        INSERT INTO public.discord_multiclass_spell_slot_pools(character_id,pool_kind,spell_level,max_slots,used_slots)
        VALUES(p_character_id,'pact',v_pact_level,v_pact_count,0);
    END IF;

    IF EXISTS(SELECT 1 FROM public.discord_multiclass_spell_slot_pools p WHERE p.character_id=p_character_id) THEN
        DELETE FROM public.discord_spell_slots WHERE character_id=p_character_id;
        INSERT INTO public.discord_spell_slots(character_id,spell_level,max_slots,used_slots)
        SELECT p.character_id,p.spell_level,SUM(p.max_slots)::INTEGER,SUM(p.used_slots)::INTEGER
        FROM public.discord_multiclass_spell_slot_pools p
        WHERE p.character_id=p_character_id
        GROUP BY p.character_id,p.spell_level;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_refresh_aggregate_slots(p_character_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_multiclass_spell_slot_pools p WHERE p.character_id=p_character_id) THEN RETURN; END IF;
    DELETE FROM public.discord_spell_slots WHERE character_id=p_character_id;
    INSERT INTO public.discord_spell_slots(character_id,spell_level,max_slots,used_slots)
    SELECT p.character_id,p.spell_level,SUM(p.max_slots)::INTEGER,SUM(p.used_slots)::INTEGER
    FROM public.discord_multiclass_spell_slot_pools p
    WHERE p.character_id=p_character_id
    GROUP BY p.character_id,p.spell_level;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_get_multiclass_state(p_player_id UUID,p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    c public.discord_characters%ROWTYPE;
    s public.discord_character_level_up_state%ROWTYPE;
    v_classes JSONB;
    v_options JSONB:='[]'::jsonb;
    v_hit_dice JSONB;
    v_initial TEXT;
    v_initial_ok BOOLEAN;
    v_class TEXT;
    v_canonical TEXT;
    v_req TEXT;
    v_ok BOOLEAN;
    v_existing BOOLEAN;
BEGIN
    SELECT * INTO c FROM public.discord_characters
    WHERE player_id=p_player_id AND campaign_id=p_campaign_id LIMIT 1;
    IF c.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT * INTO s FROM public.discord_character_level_up_state
    WHERE character_id=c.character_id AND pending=TRUE LIMIT 1;

    SELECT cc.class_name INTO v_initial
    FROM public.discord_character_classes cc
    WHERE cc.character_id=c.character_id AND cc.is_initial=TRUE LIMIT 1;
    v_initial:=COALESCE(v_initial,public.discord_multiclass_canonical_class(c.class_name));
    v_initial_ok:=public.discord_multiclass_requirement_met(v_initial,c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma);

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'className',cc.class_name,'level',cc.class_level,'isInitial',cc.is_initial,
        'firstTotalLevel',cc.first_total_level,'subclassName',cc.subclass_name,
        'gainedProficiencies',cc.gained_proficiencies)
        ORDER BY cc.first_total_level,cc.class_name),'[]'::jsonb)
    INTO v_classes FROM public.discord_character_classes cc WHERE cc.character_id=c.character_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'className',h.class_name,'dieSides',h.die_sides,'totalDice',h.total_dice,
        'spentDice',h.spent_dice,'availableDice',GREATEST(0,h.total_dice-h.spent_dice))
        ORDER BY h.die_sides DESC,h.class_name),'[]'::jsonb)
    INTO v_hit_dice FROM public.discord_character_hit_dice_pools h WHERE h.character_id=c.character_id;

    FOREACH v_class IN ARRAY ARRAY['Artificer','Barbarian','Bard','Cleric','Druid','Fighter','Monk','Paladin','Ranger','Rogue','Sorcerer','Warlock','Wizard'] LOOP
        v_canonical:=public.discord_multiclass_canonical_class(v_class);
        v_req:=public.discord_multiclass_requirement_text(v_canonical);
        SELECT EXISTS(SELECT 1 FROM public.discord_character_classes cc WHERE cc.character_id=c.character_id AND lower(cc.class_name)=lower(v_canonical)) INTO v_existing;
        v_ok:=CASE WHEN v_existing THEN TRUE ELSE v_initial_ok AND public.discord_multiclass_requirement_met(v_canonical,c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma) END;
        v_options:=v_options||jsonb_build_array(jsonb_build_object(
            'className',v_canonical,'requirement',v_req,'eligible',v_ok,'alreadyClass',v_existing,
            'requiresSkillChoice',lower(v_canonical) IN ('bard','ranger','rogue'),
            'requiresInstrumentChoice',lower(v_canonical)='bard'));
    END LOOP;

    RETURN jsonb_build_object(
        'characterId',c.character_id,'characterName',c.character_name,'totalLevel',c.level,
        'initialClass',v_initial,'summary',COALESCE(public.discord_multiclass_summary(c.character_id),c.class_name||' '||c.level),
        'classes',v_classes,'options',v_options,'hitDice',v_hit_dice,
        'strength',c.strength,'dexterity',c.dexterity,'constitution',c.constitution,
        'intelligence',c.intelligence,'wisdom',c.wisdom,'charisma',c.charisma,
        'pendingLevelUp',s.character_id IS NOT NULL,'fromLevel',COALESCE(s.from_level,c.level),
        'toLevel',COALESCE(s.to_level,c.level));
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_apply_multiclass_level_plan(
    p_player_id UUID,p_campaign_id UUID,p_plan JSONB)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    c public.discord_characters%ROWTYPE;
    s public.discord_character_level_up_state%ROWTYPE;
    v_plan JSONB:=COALESCE(p_plan,'[]'::jsonb);
    v_expected INTEGER;
    v_index INTEGER:=0;
    v_entry JSONB;
    v_total_level INTEGER;
    v_class TEXT;
    v_initial TEXT;
    v_initial_ok BOOLEAN;
    v_existing BOOLEAN;
    v_class_level INTEGER;
    v_default_gain INTEGER;
    v_actual_gain INTEGER;
    v_hp_delta INTEGER:=0;
    v_choices JSONB;
    v_skill TEXT;
    v_instrument TEXT;
    v_saved public.discord_multiclass_level_history%ROWTYPE;
    v_new_max INTEGER;
    v_new_current INTEGER;
    v_spells_changed BOOLEAN:=FALSE;
BEGIN
    SELECT * INTO c FROM public.discord_characters
    WHERE player_id=p_player_id AND campaign_id=p_campaign_id LIMIT 1 FOR UPDATE;
    IF c.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    SELECT * INTO s FROM public.discord_character_level_up_state
    WHERE character_id=c.character_id AND campaign_id=p_campaign_id AND pending=TRUE LIMIT 1 FOR UPDATE;
    IF s.character_id IS NULL THEN RAISE EXCEPTION 'No pending level-up is waiting for a multiclass decision.'; END IF;

    v_expected:=GREATEST(0,s.to_level-s.from_level);
    IF jsonb_typeof(v_plan)<>'array' OR jsonb_array_length(v_plan)<>v_expected THEN
        RAISE EXCEPTION 'Choose exactly one class for each gained level (% choices required).',v_expected;
    END IF;

    SELECT cc.class_name INTO v_initial FROM public.discord_character_classes cc
    WHERE cc.character_id=c.character_id AND cc.is_initial=TRUE LIMIT 1;
    v_initial:=COALESCE(v_initial,public.discord_multiclass_canonical_class(c.class_name));
    v_initial_ok:=public.discord_multiclass_requirement_met(v_initial,c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma);
    v_default_gain:=public.discord_multiclass_fixed_hp_gain(v_initial,c.constitution);

    FOR v_entry IN SELECT value FROM jsonb_array_elements(v_plan) LOOP
        v_index:=v_index+1;
        v_total_level:=COALESCE((v_entry->>'totalLevel')::INTEGER,s.from_level+v_index);
        IF v_total_level<>s.from_level+v_index THEN
            RAISE EXCEPTION 'Level plan is out of order. Expected total level %.',s.from_level+v_index;
        END IF;
        v_class:=public.discord_multiclass_canonical_class(v_entry->>'className');
        IF v_class IS NULL THEN RAISE EXCEPTION 'Unknown multiclass selection: %.',COALESCE(v_entry->>'className',''); END IF;
        v_choices:=COALESCE(v_entry->'proficiencyChoices','{}'::jsonb);

        SELECT * INTO v_saved FROM public.discord_multiclass_level_history h
        WHERE h.character_id=c.character_id AND h.total_level=v_total_level;
        IF v_saved.character_id IS NOT NULL THEN
            IF lower(v_saved.class_name)<>lower(v_class) THEN
                RAISE EXCEPTION 'Total level % was already assigned to %.',v_total_level,v_saved.class_name;
            END IF;
            CONTINUE;
        END IF;

        SELECT EXISTS(SELECT 1 FROM public.discord_character_classes cc WHERE cc.character_id=c.character_id AND lower(cc.class_name)=lower(v_class)) INTO v_existing;
        IF NOT v_existing THEN
            IF NOT v_initial_ok THEN
                RAISE EXCEPTION 'You must meet the % prerequisite (%), as well as the new class prerequisite, before multiclassing.',v_initial,public.discord_multiclass_requirement_text(v_initial);
            END IF;
            IF NOT public.discord_multiclass_requirement_met(v_class,c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma) THEN
                RAISE EXCEPTION 'You do not meet the % multiclass prerequisite (%).',v_class,public.discord_multiclass_requirement_text(v_class);
            END IF;
            v_skill:=trim(COALESCE(v_choices->>'skill',''));
            v_instrument:=trim(COALESCE(v_choices->>'instrument',''));
            IF lower(v_class) IN ('bard','ranger','rogue') AND v_skill='' THEN
                RAISE EXCEPTION '% multiclassing requires the player to record the granted skill proficiency.',v_class;
            END IF;
            IF lower(v_class)='bard' AND v_instrument='' THEN
                RAISE EXCEPTION 'Bard multiclassing requires the player to record the granted musical instrument proficiency.';
            END IF;
            IF lower(v_class)='bard' AND lower(v_skill) NOT IN (
                'acrobatics','animal handling','arcana','athletics','deception','history','insight','intimidation',
                'investigation','medicine','nature','perception','performance','persuasion','religion','sleight of hand','stealth','survival') THEN
                RAISE EXCEPTION 'Choose a valid skill proficiency for the Bard multiclass.';
            END IF;
            IF lower(v_class)='ranger' AND lower(v_skill) NOT IN (
                'animal handling','athletics','insight','investigation','nature','perception','stealth','survival') THEN
                RAISE EXCEPTION 'Choose a skill from the Ranger class skill list.';
            END IF;
            IF lower(v_class)='rogue' AND lower(v_skill) NOT IN (
                'acrobatics','athletics','deception','insight','intimidation','investigation','perception','performance',
                'persuasion','sleight of hand','stealth') THEN
                RAISE EXCEPTION 'Choose a skill from the Rogue class skill list.';
            END IF;

            INSERT INTO public.discord_character_classes(
                character_id,class_name,class_level,is_initial,first_total_level,gained_proficiencies)
            VALUES(c.character_id,v_class,1,FALSE,v_total_level,public.discord_multiclass_proficiency_template(v_class,v_choices));
            v_class_level:=1;
        ELSE
            UPDATE public.discord_character_classes cc
            SET class_level=cc.class_level+1,updated_at=NOW()
            WHERE cc.character_id=c.character_id AND lower(cc.class_name)=lower(v_class)
            RETURNING cc.class_level INTO v_class_level;
        END IF;

        v_actual_gain:=public.discord_multiclass_fixed_hp_gain(v_class,c.constitution);
        v_hp_delta:=v_hp_delta+(v_actual_gain-v_default_gain);
        v_spells_changed:=v_spells_changed OR public.discord_multiclass_is_spellcaster(v_class);

        INSERT INTO public.discord_character_hit_dice_pools(character_id,class_name,die_sides,total_dice,spent_dice)
        VALUES(c.character_id,v_class,public.discord_multiclass_hit_die_sides(v_class),1,0)
        ON CONFLICT(character_id,class_name) DO UPDATE SET total_dice=discord_character_hit_dice_pools.total_dice+1;

        INSERT INTO public.discord_multiclass_level_history(
            character_id,total_level,class_name,class_level_after,hp_gain,proficiency_choices)
        VALUES(c.character_id,v_total_level,v_class,v_class_level,v_actual_gain,v_choices);
    END LOOP;

    -- Long-rest leveling already granted HP as if every gained level belonged to the
    -- initial class. Apply only the difference, so existing advancement stays intact.
    v_new_max:=GREATEST(1,c.max_hp+v_hp_delta);
    v_new_current:=LEAST(v_new_max,GREATEST(1,c.current_hp+v_hp_delta));
    UPDATE public.discord_characters dc
    SET max_hp=v_new_max,current_hp=v_new_current,
        hit_dice_spent=(SELECT COALESCE(SUM(h.spent_dice),0)::INTEGER FROM public.discord_character_hit_dice_pools h WHERE h.character_id=dc.character_id),
        spells_complete=CASE WHEN v_spells_changed THEN FALSE ELSE dc.spells_complete END,
        character_data=jsonb_set(
            jsonb_set(COALESCE(dc.character_data,'{}'::jsonb),'{max_hp}',to_jsonb(v_new_max),TRUE),
            '{current_hp}',to_jsonb(v_new_current),TRUE),
        updated_at=NOW()
    WHERE dc.character_id=c.character_id;

    PERFORM public.discord_sync_multiclass_character_data(c.character_id);
    PERFORM public.discord_multiclass_sync_spell_slots(c.character_id);

    RETURN jsonb_build_object(
        'success',TRUE,'characterId',c.character_id,'fromLevel',s.from_level,'toLevel',s.to_level,
        'summary',public.discord_multiclass_summary(c.character_id),'hpAdjustment',v_hp_delta,
        'maxHp',v_new_max,'currentHp',v_new_current,'needsSpellSelection',v_spells_changed);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_spend_multiclass_hit_die(
    p_player_id UUID,p_campaign_id UUID,p_die_sides INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    c public.discord_characters%ROWTYPE;
    r public.discord_character_rest_state%ROWTYPE;
    h public.discord_character_hit_dice_pools%ROWTYPE;
    v_roll INTEGER;
    v_con_mod INTEGER;
    v_rolled INTEGER;
    v_healing INTEGER;
    v_new_hp INTEGER;
    v_entry JSONB;
BEGIN
    SELECT * INTO c FROM public.discord_characters
    WHERE player_id=p_player_id AND campaign_id=p_campaign_id LIMIT 1 FOR UPDATE;
    IF c.character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    SELECT * INTO r FROM public.discord_character_rest_state
    WHERE character_id=c.character_id AND campaign_id=p_campaign_id AND rest_type='short' AND status='awaiting_hit_dice' FOR UPDATE;
    IF r.character_id IS NULL THEN RAISE EXCEPTION 'No completed Short Rest is waiting for Hit Dice.'; END IF;
    IF c.current_hp>=c.max_hp THEN RAISE EXCEPTION '% is already at full HP.',c.character_name; END IF;

    SELECT * INTO h FROM public.discord_character_hit_dice_pools hp
    WHERE hp.character_id=c.character_id AND hp.spent_dice<hp.total_dice
      AND (p_die_sides IS NULL OR hp.die_sides=p_die_sides)
    ORDER BY CASE WHEN p_die_sides IS NULL THEN hp.die_sides ELSE 0 END DESC,hp.class_name
    LIMIT 1 FOR UPDATE;
    IF h.character_id IS NULL THEN RAISE EXCEPTION 'No matching Hit Dice are available.'; END IF;

    v_roll:=FLOOR(random()*h.die_sides)::INTEGER+1;
    v_con_mod:=FLOOR((COALESCE(c.constitution,10)-10)::NUMERIC/2)::INTEGER;
    v_rolled:=GREATEST(1,v_roll+v_con_mod);
    v_healing:=LEAST(v_rolled,GREATEST(0,c.max_hp-c.current_hp));
    v_new_hp:=LEAST(c.max_hp,c.current_hp+v_healing);

    UPDATE public.discord_character_hit_dice_pools
    SET spent_dice=spent_dice+1
    WHERE character_id=c.character_id AND class_name=h.class_name;

    UPDATE public.discord_characters dc SET current_hp=v_new_hp,
        hit_dice_spent=(SELECT COALESCE(SUM(hp.spent_dice),0)::INTEGER FROM public.discord_character_hit_dice_pools hp WHERE hp.character_id=dc.character_id),
        character_data=jsonb_set(COALESCE(dc.character_data,'{}'::jsonb),'{current_hp}',to_jsonb(v_new_hp),TRUE),updated_at=NOW()
    WHERE dc.character_id=c.character_id;

    v_entry:=jsonb_build_object('className',h.class_name,'dieSides',h.die_sides,'roll',v_roll,
        'constitutionModifier',v_con_mod,'rolledHealing',v_rolled,'healing',v_healing,'hpAfter',v_new_hp,'rolledAt',NOW());
    UPDATE public.discord_character_rest_state SET hit_dice_spent_this_rest=hit_dice_spent_this_rest+1,
        roll_log=COALESCE(roll_log,'[]'::jsonb)||jsonb_build_array(v_entry),updated_at=NOW()
    WHERE character_id=c.character_id;

    RETURN jsonb_build_object('success',TRUE,'characterId',c.character_id,'characterName',c.character_name,
        'className',h.class_name,'dieSides',h.die_sides,'roll',v_roll,'constitutionModifier',v_con_mod,
        'rolledHealing',v_rolled,'healing',v_healing,'currentHp',v_new_hp,'maxHp',c.max_hp,
        'hitDiceSpent',(SELECT COALESCE(SUM(hp.spent_dice),0)::INTEGER FROM public.discord_character_hit_dice_pools hp WHERE hp.character_id=c.character_id),
        'hitDiceAvailable',(SELECT COALESCE(SUM(hp.total_dice-hp.spent_dice),0)::INTEGER FROM public.discord_character_hit_dice_pools hp WHERE hp.character_id=c.character_id),
        'hitDiceSpentThisRest',r.hit_dice_spent_this_rest+1);
END;
$$;

-- Preserve the existing Short Rest endpoint as a safe fallback. It delegates
-- to the multiclass-aware spender and chooses the largest available die when the
-- client does not explicitly select a Hit Die pool.
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
BEGIN
    RETURN public.discord_spend_multiclass_hit_die(p_player_id,p_campaign_id,NULL);
END;
$$;

-- Restore all Pact Magic slots when a Short Rest is finished, then refresh the
-- aggregate slot rows used by the existing UI/cast machinery.
CREATE OR REPLACE FUNCTION public.discord_multiclass_restore_pact_slots(p_character_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    UPDATE public.discord_multiclass_spell_slot_pools
    SET used_slots=0 WHERE character_id=p_character_id AND pool_kind='pact';
    PERFORM public.discord_multiclass_refresh_aggregate_slots(p_character_id);
END;
$$;

-- If existing Long Rest logic resets aggregate slots to zero, mirror that reset
-- into the underlying multiclass pools.
-- Keep per-class Hit Dice pools synchronized with the existing Long Rest
-- implementation. Existing RabuShin behavior resets hit_dice_spent to zero;
-- multiclass pools must reset at the same moment.
CREATE OR REPLACE FUNCTION public.discord_multiclass_hit_dice_reset_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    IF NEW.hit_dice_spent=0 AND COALESCE(OLD.hit_dice_spent,0)<>0 THEN
        UPDATE public.discord_character_hit_dice_pools
        SET spent_dice=0
        WHERE character_id=NEW.character_id;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_discord_multiclass_hit_dice_reset ON public.discord_characters;
CREATE TRIGGER trg_discord_multiclass_hit_dice_reset
AFTER UPDATE OF hit_dice_spent ON public.discord_characters
FOR EACH ROW EXECUTE FUNCTION public.discord_multiclass_hit_dice_reset_trigger();

-- Finish a Short Rest using the existing result shape, but restore Pact Magic
-- first. This is the 5e multiclass interaction that allows Pact Magic slots to
-- return on a Short Rest while shared Spellcasting slots wait for a Long Rest.
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

    PERFORM public.discord_multiclass_restore_pact_slots(v_character.character_id);
    DELETE FROM public.discord_character_rest_state r WHERE r.character_id=v_character.character_id;

    RETURN jsonb_build_object(
        'characterId',v_character.character_id,
        'characterName',v_character.character_name,
        'currentHp',v_character.current_hp,
        'maxHp',v_character.max_hp,
        'hitDiceSpentThisRest',v_rest.hit_dice_spent_this_rest,
        'rollLog',v_rest.roll_log,
        'reason',v_rest.reason,
        'pactMagicRestored',TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_multiclass_slot_reset_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    IF NEW.used_slots=0 AND OLD.used_slots<>0 THEN
        UPDATE public.discord_multiclass_spell_slot_pools
        SET used_slots=0
        WHERE character_id=NEW.character_id AND spell_level=NEW.spell_level;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_discord_multiclass_slot_reset ON public.discord_spell_slots;
CREATE TRIGGER trg_discord_multiclass_slot_reset
AFTER UPDATE OF used_slots ON public.discord_spell_slots
FOR EACH ROW EXECUTE FUNCTION public.discord_multiclass_slot_reset_trigger();

-- Multiclass-aware cast operation. Single-class characters without multiclass
-- pools keep the same behavior as Build 6.30.8. When pools exist, shared and
-- Pact Magic slots are spent separately while the aggregate UI rows stay synced.
DROP FUNCTION IF EXISTS public.discord_gm_cast_spell(UUID,UUID,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_cast_spell(
    p_campaign_id UUID,p_character_id UUID,p_spell_name TEXT,p_slot_level INTEGER DEFAULT 0,p_reason TEXT DEFAULT '')
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    c public.discord_characters%ROWTYPE;
    s public.discord_character_spells%ROWTYPE;
    v_base INTEGER:=0;
    v_slot INTEGER:=0;
    v_active BOOLEAN:=FALSE;
    v_casting TEXT:='';
    v_resource TEXT:='';
    v_action JSONB:='{}'::jsonb;
    v_pool TEXT:='';
    v_max INTEGER:=0;
    v_used INTEGER:=0;
    v_remaining INTEGER:=0;
    v_has_multi_pools BOOLEAN:=FALSE;
BEGIN
    SELECT * INTO c FROM public.discord_characters
    WHERE character_id=p_character_id AND campaign_id=p_campaign_id FOR UPDATE;
    IF c.character_id IS NULL THEN RAISE EXCEPTION 'The casting character could not be found in this campaign.'; END IF;
    SELECT * INTO s FROM public.discord_character_spells
    WHERE character_id=p_character_id AND lower(trim(spell_name))=lower(trim(COALESCE(p_spell_name,''))) LIMIT 1;
    IF s.character_spell_id IS NULL THEN RAISE EXCEPTION '% does not have % in the current spellbook.',c.character_name,COALESCE(NULLIF(trim(p_spell_name),''),'that spell'); END IF;
    v_base:=GREATEST(0,COALESCE(s.spell_level,0));
    IF v_base>0 AND NOT COALESCE(s.prepared,FALSE) THEN RAISE EXCEPTION '% is not currently prepared/available.',s.spell_name; END IF;
    v_casting:=lower(trim(COALESCE(s.spell_data->>'casting_time','1 Action')));
    SELECT EXISTS(SELECT 1 FROM public.discord_campaign_combat_state cs WHERE cs.campaign_id=p_campaign_id AND cs.active=TRUE) INTO v_active;

    IF v_base>0 THEN
        v_slot:=CASE WHEN COALESCE(p_slot_level,0)<=0 THEN v_base ELSE p_slot_level END;
        IF v_slot<v_base OR v_slot>9 THEN RAISE EXCEPTION '% requires a spell slot of level % or higher.',s.spell_name,v_base; END IF;
        SELECT EXISTS(SELECT 1 FROM public.discord_multiclass_spell_slot_pools p WHERE p.character_id=p_character_id) INTO v_has_multi_pools;
        IF v_has_multi_pools THEN
            -- Prefer Pact Magic for Warlock-tagged spells; otherwise prefer shared slots.
            SELECT p.pool_kind,p.max_slots,p.used_slots INTO v_pool,v_max,v_used
            FROM public.discord_multiclass_spell_slot_pools p
            WHERE p.character_id=p_character_id AND p.spell_level=v_slot AND p.used_slots<p.max_slots
            ORDER BY CASE
                WHEN lower(COALESCE(s.source_tag,'')) LIKE '%warlock%' AND p.pool_kind='pact' THEN 0
                WHEN lower(COALESCE(s.source_tag,'')) NOT LIKE '%warlock%' AND p.pool_kind='shared' THEN 0
                WHEN p.pool_kind='pact' THEN 1 ELSE 2 END
            LIMIT 1 FOR UPDATE;
            IF v_pool='' THEN RAISE EXCEPTION '% has no level % spell slots remaining.',c.character_name,v_slot; END IF;
        ELSE
            SELECT ss.max_slots,ss.used_slots INTO v_max,v_used FROM public.discord_spell_slots ss
            WHERE ss.character_id=p_character_id AND ss.spell_level=v_slot FOR UPDATE;
            IF NOT FOUND OR COALESCE(v_max,0)<=0 OR COALESCE(v_used,0)>=COALESCE(v_max,0) THEN
                RAISE EXCEPTION '% has no level % spell slots remaining.',c.character_name,v_slot;
            END IF;
        END IF;
    END IF;

    IF v_active THEN
        IF v_casting LIKE '%bonus action%' THEN v_resource:='bonus_action';
        ELSIF v_casting LIKE '%reaction%' THEN v_resource:='reaction';
        ELSIF v_casting LIKE '%action%' OR v_casting='' THEN v_resource:='action';
        ELSE RAISE EXCEPTION '% has a casting time of "%", which cannot be completed as one combat action.',s.spell_name,COALESCE(NULLIF(s.spell_data->>'casting_time',''),'unknown'); END IF;
        v_action:=public.discord_action_economy_spend_internal(p_campaign_id,'character',p_character_id,v_resource,'magic',LEFT(trim(COALESCE(p_reason,'Spell cast')),160));
    END IF;

    IF v_base>0 THEN
        IF v_has_multi_pools THEN
            UPDATE public.discord_multiclass_spell_slot_pools
            SET used_slots=used_slots+1
            WHERE character_id=p_character_id AND pool_kind=v_pool AND spell_level=v_slot
            RETURNING max_slots,used_slots INTO v_max,v_used;
            PERFORM public.discord_multiclass_refresh_aggregate_slots(p_character_id);
        ELSE
            UPDATE public.discord_spell_slots SET used_slots=used_slots+1
            WHERE character_id=p_character_id AND spell_level=v_slot
            RETURNING max_slots,used_slots INTO v_max,v_used;
        END IF;
        v_remaining:=GREATEST(0,v_max-v_used);
    END IF;

    RETURN jsonb_build_object('success',TRUE,'characterId',p_character_id,'characterName',c.character_name,
        'spellName',s.spell_name,'spellLevel',v_base,'slotLevel',v_slot,'slotConsumed',v_base>0,
        'slotPool',CASE WHEN v_has_multi_pools THEN v_pool ELSE 'standard' END,
        'maxSlots',v_max,'usedSlots',v_used,'remainingSlots',v_remaining,'activeCombat',v_active,
        'spentActionResource',CASE WHEN v_active THEN v_resource ELSE '' END,'castingTime',COALESCE(s.spell_data->>'casting_time',''),
        'actionState',CASE WHEN v_active THEN v_action ELSE '{}'::jsonb END,'reason',LEFT(trim(COALESCE(p_reason,'')),160));
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_multiclass_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_apply_multiclass_level_plan(UUID,UUID,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_spend_multiclass_hit_die(UUID,UUID,INTEGER) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_spend_short_rest_hit_die(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_cast_spell(UUID,UUID,TEXT,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_finish_short_rest(UUID,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_get_multiclass_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_apply_multiclass_level_plan(UUID,UUID,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_spend_multiclass_hit_die(UUID,UUID,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_spend_short_rest_hit_die(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_cast_spell(UUID,UUID,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_finish_short_rest(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_multiclass_restore_pact_slots(UUID) TO service_role;

NOTIFY pgrst,'reload schema';
COMMIT;
