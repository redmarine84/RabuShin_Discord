-- ============================================================
-- RabuShinAIGM Build 6.30.11
-- Migration 70 - Condition Saving Throws / Lifecycle / Cures
--
-- Adds:
--   * Repeatable save-ending condition resolution in and out of combat
--   * Start/end-of-turn save timing metadata
--   * World-time expiration for magical effects
--   * Source-death and source-LOS ending rules
--   * True condition suppression/restoration (Calm Emotions style)
--   * Temporary condition immunities (Heroism style)
--   * Atomic curative potion/item use
--   * Dispel-Magic-compatible tracked magical condition removal
--
-- Run AFTER the Build 6.30.11 source installer succeeds and before deployment.
-- Safe to rerun.
-- ============================================================

BEGIN;

ALTER TABLE public.discord_combat_conditions
    ADD COLUMN IF NOT EXISTS repeat_save_timing TEXT NOT NULL DEFAULT 'none',
    ADD COLUMN IF NOT EXISTS magic_effect BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS spell_name TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS expires_world_minute BIGINT NULL,
    ADD COLUMN IF NOT EXISTS ends_on_combat_end BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS ends_on_source_death BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS ends_on_source_lost_los BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS source_entity_type TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS source_character_id UUID NULL,
    ADD COLUMN IF NOT EXISTS source_monster_id UUID NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname='ck_discord_condition_repeat_save_timing'
    ) THEN
        ALTER TABLE public.discord_combat_conditions
        ADD CONSTRAINT ck_discord_condition_repeat_save_timing
        CHECK (repeat_save_timing IN ('none','start','end'));
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.discord_condition_suppressions
(
    suppression_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    condition_id UUID NOT NULL,
    entity_type TEXT NOT NULL,
    character_id UUID NULL,
    combat_monster_id UUID NULL,
    condition_name TEXT NOT NULL,
    source_name TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    duration_type TEXT NOT NULL DEFAULT 'persistent',
    rounds_remaining INTEGER NULL,
    save_ability TEXT NULL,
    save_dc INTEGER NULL,
    applied_round INTEGER NULL,
    repeat_save_timing TEXT NOT NULL DEFAULT 'none',
    magic_effect BOOLEAN NOT NULL DEFAULT FALSE,
    spell_name TEXT NOT NULL DEFAULT '',
    expires_world_minute BIGINT NULL,
    ends_on_combat_end BOOLEAN NOT NULL DEFAULT FALSE,
    ends_on_source_death BOOLEAN NOT NULL DEFAULT FALSE,
    ends_on_source_lost_los BOOLEAN NOT NULL DEFAULT FALSE,
    source_entity_type TEXT NOT NULL DEFAULT '',
    source_character_id UUID NULL,
    source_monster_id UUID NULL,
    suppressing_effect TEXT NOT NULL DEFAULT '',
    restore_world_minute BIGINT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(campaign_id, condition_id)
);

CREATE TABLE IF NOT EXISTS public.discord_condition_immunities
(
    immunity_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL,
    character_id UUID NULL,
    combat_monster_id UUID NULL,
    condition_name TEXT NOT NULL,
    source_name TEXT NOT NULL DEFAULT '',
    expires_world_minute BIGINT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_discord_condition_immunity_entity
        CHECK (
            (entity_type='character' AND character_id IS NOT NULL AND combat_monster_id IS NULL)
            OR
            (entity_type='monster' AND combat_monster_id IS NOT NULL AND character_id IS NULL)
        )
);

CREATE INDEX IF NOT EXISTS ix_discord_condition_suppressions_campaign
    ON public.discord_condition_suppressions(campaign_id);
CREATE INDEX IF NOT EXISTS ix_discord_condition_immunities_campaign
    ON public.discord_condition_immunities(campaign_id);

ALTER TABLE public.discord_condition_suppressions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_condition_immunities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_condition_suppressions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.discord_condition_immunities FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.discord_condition_world_minute(p_campaign_id UUID)
RETURNS BIGINT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT COALESCE(
        (SELECT w.world_minute
         FROM public.discord_campaign_world_time w
         WHERE w.campaign_id=p_campaign_id),
        0
    )::BIGINT;
$$;

CREATE OR REPLACE FUNCTION public.discord_condition_find_target(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    OUT character_id UUID,
    OUT combat_monster_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_type TEXT:=lower(trim(COALESCE(p_target_type,'')));
    v_name TEXT:=trim(COALESCE(p_target_name,''));
BEGIN
    character_id:=NULL;
    combat_monster_id:=NULL;

    IF v_type='character' THEN
        SELECT c.character_id INTO character_id
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND lower(c.character_name)=lower(v_name)
        ORDER BY c.character_id
        LIMIT 1;
        IF character_id IS NULL THEN
            RAISE EXCEPTION 'Party character not found: %', v_name;
        END IF;
    ELSIF v_type='monster' THEN
        SELECT m.combat_monster_id INTO combat_monster_id
        FROM public.discord_campaign_combat_monsters m
        WHERE m.campaign_id=p_campaign_id
          AND lower(m.display_name)=lower(v_name)
        ORDER BY m.combat_monster_id
        LIMIT 1;
        IF combat_monster_id IS NULL THEN
            RAISE EXCEPTION 'Active combat monster not found: %', v_name;
        END IF;
    ELSE
        RAISE EXCEPTION 'targetType must be character or monster.';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_set_condition_lifecycle(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT,
    p_source_name TEXT,
    p_repeat_save_timing TEXT,
    p_magic_effect BOOLEAN,
    p_spell_name TEXT,
    p_duration_minutes INTEGER,
    p_ends_on_combat_end BOOLEAN,
    p_ends_on_source_death BOOLEAN,
    p_ends_on_source_lost_los BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_timing TEXT:=lower(trim(COALESCE(NULLIF(p_repeat_save_timing,''),'none')));
    v_character_id UUID;
    v_monster_id UUID;
    v_source_character UUID;
    v_source_monster UUID;
    v_source_type TEXT:='';
    v_updated INTEGER:=0;
    v_expires BIGINT:=NULL;
BEGIN
    IF v_timing NOT IN ('none','start','end') THEN
        RAISE EXCEPTION 'repeatSaveTiming must be none, start, or end.';
    END IF;

    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    IF COALESCE(p_duration_minutes,0)>0 THEN
        v_expires:=public.discord_condition_world_minute(p_campaign_id)+p_duration_minutes;
    END IF;

    IF trim(COALESCE(p_source_name,''))<>'' THEN
        SELECT c.character_id INTO v_source_character
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND lower(c.character_name)=lower(trim(p_source_name))
        LIMIT 1;

        IF v_source_character IS NOT NULL THEN
            v_source_type:='character';
        ELSE
            SELECT m.combat_monster_id INTO v_source_monster
            FROM public.discord_campaign_combat_monsters m
            WHERE m.campaign_id=p_campaign_id
              AND lower(m.display_name)=lower(trim(p_source_name))
            LIMIT 1;
            IF v_source_monster IS NOT NULL THEN v_source_type:='monster'; END IF;
        END IF;
    END IF;

    UPDATE public.discord_combat_conditions cc
    SET repeat_save_timing=v_timing,
        magic_effect=COALESCE(p_magic_effect,FALSE),
        spell_name=trim(COALESCE(p_spell_name,'')),
        expires_world_minute=v_expires,
        ends_on_combat_end=COALESCE(p_ends_on_combat_end,FALSE),
        ends_on_source_death=COALESCE(p_ends_on_source_death,FALSE),
        ends_on_source_lost_los=COALESCE(p_ends_on_source_lost_los,FALSE),
        source_entity_type=v_source_type,
        source_character_id=v_source_character,
        source_monster_id=v_source_monster,
        updated_at=NOW()
    WHERE cc.campaign_id=p_campaign_id
      AND cc.condition_name=v_condition
      AND (trim(COALESCE(p_source_name,''))='' OR lower(cc.source_name)=lower(trim(p_source_name)))
      AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id));

    GET DIAGNOSTICS v_updated=ROW_COUNT;
    IF v_updated=0 THEN
        RAISE EXCEPTION 'Condition instance was not found for lifecycle metadata.';
    END IF;

    RETURN jsonb_build_object(
        'success',TRUE,'updated',v_updated,'condition',v_condition,
        'repeatSaveTiming',v_timing,'expiresWorldMinute',v_expires,
        'magicEffect',COALESCE(p_magic_effect,FALSE),
        'endsOnSourceDeath',COALESCE(p_ends_on_source_death,FALSE),
        'endsOnSourceLostLos',COALESCE(p_ends_on_source_lost_los,FALSE)
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_resolve_condition_save(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_resolve_condition_save(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT,
    p_source_name TEXT,
    p_d20_roll INTEGER,
    p_ability_modifier INTEGER,
    p_timing TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_character_id UUID;
    v_monster_id UUID;
    v_row public.discord_combat_conditions%ROWTYPE;
    v_roll INTEGER:=COALESCE(p_d20_roll,0);
    v_total INTEGER;
    v_success BOOLEAN;
    v_modifier INTEGER:=COALESCE(p_ability_modifier,0);
    v_timing TEXT:=lower(trim(COALESCE(NULLIF(p_timing,''),'end')));
    v_class TEXT:='';
    v_proficiency INTEGER:=0;
    v_is_proficient BOOLEAN:=FALSE;
BEGIN
    IF v_roll<1 OR v_roll>20 THEN
        RAISE EXCEPTION 'Trusted condition save d20 roll must be between 1 and 20.';
    END IF;
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    SELECT cc.* INTO v_row
    FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND cc.condition_name=v_condition
      AND cc.duration_type='save_ends'
      AND (trim(COALESCE(p_source_name,''))='' OR lower(cc.source_name)=lower(trim(p_source_name)))
      AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id))
    ORDER BY cc.created_at
    LIMIT 1;

    IF v_row.condition_id IS NULL THEN
        RAISE EXCEPTION 'No active save-ending % condition was found on %.', v_condition,p_target_name;
    END IF;

    IF v_row.repeat_save_timing<>'none' AND v_row.repeat_save_timing<>v_timing THEN
        RAISE EXCEPTION 'This condition repeats its save at the % of the turn, not %.',v_row.repeat_save_timing,v_timing;
    END IF;

    IF v_character_id IS NOT NULL THEN
        SELECT
            CASE lower(COALESCE(v_row.save_ability,''))
                WHEN 'strength' THEN FLOOR((c.strength-10)/2.0)::INTEGER
                WHEN 'dexterity' THEN FLOOR((c.dexterity-10)/2.0)::INTEGER
                WHEN 'constitution' THEN FLOOR((c.constitution-10)/2.0)::INTEGER
                WHEN 'intelligence' THEN FLOOR((c.intelligence-10)/2.0)::INTEGER
                WHEN 'wisdom' THEN FLOOR((c.wisdom-10)/2.0)::INTEGER
                WHEN 'charisma' THEN FLOOR((c.charisma-10)/2.0)::INTEGER
                ELSE 0 END,
            lower(trim(COALESCE(c.class_name,''))),
            COALESCE(c.proficiency_bonus,0)
        INTO v_modifier,v_class,v_proficiency
        FROM public.discord_characters c
        WHERE c.character_id=v_character_id;

        -- Standard class saving-throw proficiencies. Multiclass save proficiencies
        -- are intentionally not invented here; the character's stored class is authoritative.
        v_is_proficient:=CASE v_class
            WHEN 'barbarian' THEN lower(v_row.save_ability) IN ('strength','constitution')
            WHEN 'bard' THEN lower(v_row.save_ability) IN ('dexterity','charisma')
            WHEN 'cleric' THEN lower(v_row.save_ability) IN ('wisdom','charisma')
            WHEN 'druid' THEN lower(v_row.save_ability) IN ('intelligence','wisdom')
            WHEN 'fighter' THEN lower(v_row.save_ability) IN ('strength','constitution')
            WHEN 'monk' THEN lower(v_row.save_ability) IN ('strength','dexterity')
            WHEN 'paladin' THEN lower(v_row.save_ability) IN ('wisdom','charisma')
            WHEN 'ranger' THEN lower(v_row.save_ability) IN ('strength','dexterity')
            WHEN 'rogue' THEN lower(v_row.save_ability) IN ('dexterity','intelligence')
            WHEN 'sorcerer' THEN lower(v_row.save_ability) IN ('constitution','charisma')
            WHEN 'warlock' THEN lower(v_row.save_ability) IN ('wisdom','charisma')
            WHEN 'wizard' THEN lower(v_row.save_ability) IN ('intelligence','wisdom')
            WHEN 'artificer' THEN lower(v_row.save_ability) IN ('constitution','intelligence')
            ELSE FALSE END;
        IF v_is_proficient THEN v_modifier:=v_modifier+v_proficiency; END IF;
    END IF;

    v_total:=v_roll+v_modifier;
    v_success:=v_total>=COALESCE(v_row.save_dc,9999);

    IF v_success THEN
        DELETE FROM public.discord_combat_conditions WHERE condition_id=v_row.condition_id;
        IF v_row.combat_monster_id IS NOT NULL THEN
            PERFORM public.discord_sync_legacy_monster_conditions(p_campaign_id,v_row.combat_monster_id);
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success',TRUE,
        'condition',v_condition,
        'source',v_row.source_name,
        'ability',COALESCE(v_row.save_ability,''),
        'dc',v_row.save_dc,
        'roll',v_roll,
        'modifier',v_modifier,
        'total',v_total,
        'saveSucceeded',v_success,
        'conditionRemoved',v_success
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_suppress_condition(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT,
    p_suppressing_effect TEXT,
    p_duration_minutes INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_character_id UUID;
    v_monster_id UUID;
    v_restore BIGINT:=NULL;
    v_count INTEGER:=0;
BEGIN
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    IF COALESCE(p_duration_minutes,0)>0 THEN
        v_restore:=public.discord_condition_world_minute(p_campaign_id)+p_duration_minutes;
    END IF;

    INSERT INTO public.discord_condition_suppressions(
        campaign_id,condition_id,entity_type,character_id,combat_monster_id,
        condition_name,source_name,notes,duration_type,rounds_remaining,save_ability,save_dc,applied_round,
        repeat_save_timing,magic_effect,spell_name,expires_world_minute,ends_on_combat_end,
        ends_on_source_death,ends_on_source_lost_los,source_entity_type,source_character_id,source_monster_id,
        suppressing_effect,restore_world_minute
    )
    SELECT
        cc.campaign_id,cc.condition_id,cc.entity_type,cc.character_id,cc.combat_monster_id,
        cc.condition_name,cc.source_name,cc.notes,cc.duration_type,cc.rounds_remaining,cc.save_ability,cc.save_dc,cc.applied_round,
        cc.repeat_save_timing,cc.magic_effect,cc.spell_name,cc.expires_world_minute,cc.ends_on_combat_end,
        cc.ends_on_source_death,cc.ends_on_source_lost_los,cc.source_entity_type,cc.source_character_id,cc.source_monster_id,
        trim(COALESCE(p_suppressing_effect,'')),v_restore
    FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND cc.condition_name=v_condition
      AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id))
    ON CONFLICT(campaign_id,condition_id)
    DO UPDATE SET
        suppressing_effect=EXCLUDED.suppressing_effect,
        restore_world_minute=EXCLUDED.restore_world_minute,
        updated_at=NOW();

    GET DIAGNOSTICS v_count=ROW_COUNT;

    DELETE FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND cc.condition_name=v_condition
      AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id));

    IF v_monster_id IS NOT NULL THEN
        PERFORM public.discord_sync_legacy_monster_conditions(p_campaign_id,v_monster_id);
    END IF;

    RETURN jsonb_build_object('success',TRUE,'suppressed',v_count,'condition',v_condition,'restoreWorldMinute',v_restore);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_restore_suppressed_conditions(
    p_campaign_id UUID,
    p_suppression_id UUID DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_row RECORD;
    v_count INTEGER:=0;
BEGIN
    -- Expired underlying effects are discarded rather than restored.
    DELETE FROM public.discord_condition_suppressions s
    WHERE s.campaign_id=p_campaign_id
      AND (p_suppression_id IS NULL OR s.suppression_id=p_suppression_id)
      AND s.expires_world_minute IS NOT NULL
      AND s.expires_world_minute<=public.discord_condition_world_minute(p_campaign_id);

    FOR v_row IN
        SELECT s.*
        FROM public.discord_condition_suppressions s
        WHERE s.campaign_id=p_campaign_id
          AND (p_suppression_id IS NULL OR s.suppression_id=p_suppression_id)
    LOOP
        -- Do not restore while another active immunity to the same condition remains.
        IF EXISTS(
            SELECT 1
            FROM public.discord_condition_immunities i
            WHERE i.campaign_id=v_row.campaign_id
              AND i.condition_name=v_row.condition_name
              AND (i.expires_world_minute IS NULL
                   OR i.expires_world_minute>public.discord_condition_world_minute(v_row.campaign_id))
              AND ((v_row.character_id IS NOT NULL AND i.character_id=v_row.character_id)
                OR (v_row.combat_monster_id IS NOT NULL AND i.combat_monster_id=v_row.combat_monster_id))
        ) THEN
            CONTINUE;
        END IF;

        INSERT INTO public.discord_combat_conditions(
            condition_id,campaign_id,entity_type,character_id,combat_monster_id,
            condition_name,source_name,notes,duration_type,rounds_remaining,save_ability,save_dc,applied_round,
            repeat_save_timing,magic_effect,spell_name,expires_world_minute,ends_on_combat_end,
            ends_on_source_death,ends_on_source_lost_los,source_entity_type,source_character_id,source_monster_id
        )
        VALUES(
            v_row.condition_id,v_row.campaign_id,v_row.entity_type,v_row.character_id,v_row.combat_monster_id,
            v_row.condition_name,v_row.source_name,v_row.notes,v_row.duration_type,v_row.rounds_remaining,v_row.save_ability,v_row.save_dc,v_row.applied_round,
            v_row.repeat_save_timing,v_row.magic_effect,v_row.spell_name,v_row.expires_world_minute,v_row.ends_on_combat_end,
            v_row.ends_on_source_death,v_row.ends_on_source_lost_los,v_row.source_entity_type,v_row.source_character_id,v_row.source_monster_id
        )
        ON CONFLICT DO NOTHING;
        v_count:=v_count+1;
        DELETE FROM public.discord_condition_suppressions WHERE suppression_id=v_row.suppression_id;
        IF v_row.combat_monster_id IS NOT NULL THEN
            PERFORM public.discord_sync_legacy_monster_conditions(p_campaign_id,v_row.combat_monster_id);
        END IF;
    END LOOP;
    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_restore_suppressed_condition(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_character_id UUID;
    v_monster_id UUID;
    v_id UUID;
    v_restored INTEGER:=0;
BEGIN
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    FOR v_id IN
        SELECT s.suppression_id
        FROM public.discord_condition_suppressions s
        WHERE s.campaign_id=p_campaign_id
          AND s.condition_name=v_condition
          AND ((v_character_id IS NOT NULL AND s.character_id=v_character_id)
            OR (v_monster_id IS NOT NULL AND s.combat_monster_id=v_monster_id))
    LOOP
        v_restored:=v_restored+public.discord_restore_suppressed_conditions(p_campaign_id,v_id);
    END LOOP;

    RETURN jsonb_build_object('success',TRUE,'restored',v_restored,'condition',v_condition);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_set_condition_immunity(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT,
    p_source_name TEXT,
    p_duration_minutes INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_character_id UUID;
    v_monster_id UUID;
    v_expires BIGINT:=NULL;
BEGIN
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    IF COALESCE(p_duration_minutes,0)>0 THEN
        v_expires:=public.discord_condition_world_minute(p_campaign_id)+p_duration_minutes;
    END IF;

    DELETE FROM public.discord_condition_immunities i
    WHERE i.campaign_id=p_campaign_id
      AND i.condition_name=v_condition
      AND lower(i.source_name)=lower(trim(COALESCE(p_source_name,'')))
      AND ((v_character_id IS NOT NULL AND i.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND i.combat_monster_id=v_monster_id));

    INSERT INTO public.discord_condition_immunities(
        campaign_id,entity_type,character_id,combat_monster_id,condition_name,source_name,expires_world_minute
    ) VALUES(
        p_campaign_id,lower(trim(p_target_type)),v_character_id,v_monster_id,v_condition,
        trim(COALESCE(p_source_name,'')),v_expires
    );

    -- Immunity is suppression, not a cure. Preserve any currently active instance
    -- so it can return if its original source/duration still exists after immunity ends.
    IF EXISTS(
        SELECT 1 FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=p_campaign_id
          AND cc.condition_name=v_condition
          AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
            OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id))
    ) THEN
        PERFORM public.discord_gm_suppress_condition(
            p_campaign_id,p_target_type,p_target_name,v_condition,
            'Condition Immunity: '||trim(COALESCE(p_source_name,'')),
            GREATEST(0,COALESCE(p_duration_minutes,0))
        );
    END IF;

    RETURN jsonb_build_object('success',TRUE,'condition',v_condition,'expiresWorldMinute',v_expires);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_remove_condition_immunity(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT,
    p_source_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_character_id UUID;
    v_monster_id UUID;
    v_removed INTEGER:=0;
    v_id UUID;
BEGIN
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    DELETE FROM public.discord_condition_immunities i
    WHERE i.campaign_id=p_campaign_id
      AND i.condition_name=v_condition
      AND (trim(COALESCE(p_source_name,''))='' OR lower(i.source_name)=lower(trim(p_source_name)))
      AND ((v_character_id IS NOT NULL AND i.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND i.combat_monster_id=v_monster_id));
    GET DIAGNOSTICS v_removed=ROW_COUNT;

    -- Ending immunity early restores only conditions that THIS immunity suppressed;
    -- unrelated suppressors such as Calm Emotions remain intact.
    FOR v_id IN
        SELECT s.suppression_id
        FROM public.discord_condition_suppressions s
        WHERE s.campaign_id=p_campaign_id
          AND s.condition_name=v_condition
          AND lower(s.suppressing_effect) LIKE lower('Condition Immunity:%')
          AND (
              trim(COALESCE(p_source_name,''))=''
              OR lower(s.suppressing_effect)=lower('Condition Immunity: '||trim(p_source_name))
          )
          AND ((v_character_id IS NOT NULL AND s.character_id=v_character_id)
            OR (v_monster_id IS NOT NULL AND s.combat_monster_id=v_monster_id))
    LOOP
        PERFORM public.discord_restore_suppressed_conditions(p_campaign_id,v_id);
    END LOOP;

    RETURN jsonb_build_object('success',TRUE,'removed',v_removed,'condition',v_condition);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_apply_condition_extended(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT,
    p_source_name TEXT,
    p_duration_type TEXT,
    p_rounds_remaining INTEGER,
    p_save_ability TEXT,
    p_save_dc INTEGER,
    p_notes TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_character_id UUID;
    v_monster_id UUID;
    v_world BIGINT:=public.discord_condition_world_minute(p_campaign_id);
    v_result JSONB;
BEGIN
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    IF EXISTS(
        SELECT 1
        FROM public.discord_condition_immunities i
        WHERE i.campaign_id=p_campaign_id
          AND i.condition_name=v_condition
          AND (i.expires_world_minute IS NULL OR i.expires_world_minute>v_world)
          AND ((v_character_id IS NOT NULL AND i.character_id=v_character_id)
            OR (v_monster_id IS NOT NULL AND i.combat_monster_id=v_monster_id))
    ) THEN
        RETURN jsonb_build_object(
            'applied',FALSE,'immune',TRUE,'target',p_target_name,'condition',v_condition,
            'message',format('%s is currently immune to %s.',p_target_name,initcap(v_condition))
        );
    END IF;

    SELECT public.discord_gm_apply_condition(
        p_campaign_id,p_target_type,p_target_name,p_condition_name,p_source_name,
        p_duration_type,p_rounds_remaining,p_save_ability,p_save_dc,p_notes
    ) INTO v_result;

    RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_condition_builtin_cures(p_item_name TEXT)
RETURNS TEXT[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE v TEXT:=lower(trim(COALESCE(p_item_name,'')));
BEGIN
    IF v LIKE '%potion of lesser restoration%' OR v LIKE '%lesser restoration potion%' THEN
        RETURN ARRAY['blinded','deafened','paralyzed','poisoned']::TEXT[];
    ELSIF v LIKE '%potion of greater restoration%' OR v LIKE '%greater restoration potion%' THEN
        RETURN ARRAY['charmed','petrified']::TEXT[];
    ELSIF v LIKE '%potion of cure poison%' OR v LIKE '%potion of neutralize poison%' OR v LIKE '%antidote potion%' THEN
        RETURN ARRAY['poisoned']::TEXT[];
    ELSIF v LIKE '%potion of cure blindness%' OR v LIKE '%potion of sight restoration%' THEN
        RETURN ARRAY['blinded']::TEXT[];
    ELSIF v LIKE '%potion of cure paralysis%' OR v LIKE '%potion of mobility restoration%' THEN
        RETURN ARRAY['paralyzed']::TEXT[];
    END IF;
    RETURN ARRAY[]::TEXT[];
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_consume_condition_cure_item(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_inventory_item_id UUID,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character_id UUID;
    v_item RECORD;
    v_cures TEXT[]:=ARRAY[]::TEXT[];
    v_custom JSONB;
    v_removed INTEGER:=0;
    v_removed_suppressed INTEGER:=0;
    v_remaining INTEGER:=0;
BEGIN
    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Character not found: %', p_character_name;
    END IF;

    SELECT i.* INTO v_item
    FROM public.discord_inventory_items i
    WHERE i.inventory_item_id=p_inventory_item_id
      AND i.character_id=v_character_id
    FOR UPDATE;

    IF v_item.inventory_item_id IS NULL OR COALESCE(v_item.quantity,0)<=0 THEN
        RAISE EXCEPTION 'The selected curative item is not carried by this character.';
    END IF;

    v_cures:=public.discord_condition_builtin_cures(v_item.item_name);

    IF COALESCE(v_item.item_data,'{}'::jsonb) ? 'cures_conditions' THEN
        v_custom:=COALESCE(v_item.item_data,'{}'::jsonb)->'cures_conditions';
        IF jsonb_typeof(v_custom)='array' THEN
            SELECT ARRAY(
                SELECT DISTINCT public.discord_condition_normalize(value)
                FROM jsonb_array_elements_text(v_custom)
            ) INTO v_cures;
        END IF;
    END IF;

    IF COALESCE(array_length(v_cures,1),0)=0 THEN
        RAISE EXCEPTION '% has no recognized condition-curing rule.',v_item.item_name;
    END IF;

    DELETE FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND cc.character_id=v_character_id
      AND cc.condition_name=ANY(v_cures);
    GET DIAGNOSTICS v_removed=ROW_COUNT;

    -- A real cure also removes an underlying condition while it is temporarily
    -- suppressed. This prevents the condition from returning after the suppressor ends.
    DELETE FROM public.discord_condition_suppressions s
    WHERE s.campaign_id=p_campaign_id
      AND s.character_id=v_character_id
      AND s.condition_name=ANY(v_cures);
    GET DIAGNOSTICS v_removed_suppressed=ROW_COUNT;

    IF v_removed+v_removed_suppressed=0 THEN
        RAISE EXCEPTION '% does not currently have a condition this item can cure. The item was not consumed.',p_character_name;
    END IF;

    IF v_item.quantity<=1 THEN
        DELETE FROM public.discord_inventory_items WHERE inventory_item_id=v_item.inventory_item_id;
        v_remaining:=0;
    ELSE
        UPDATE public.discord_inventory_items
        SET quantity=quantity-1,updated_at=NOW()
        WHERE inventory_item_id=v_item.inventory_item_id
        RETURNING quantity INTO v_remaining;
    END IF;

    RETURN jsonb_build_object(
        'success',TRUE,
        'itemName',v_item.item_name,
        'remaining',v_remaining,
        'removedConditions',v_removed+v_removed_suppressed,
        'cures',to_jsonb(v_cures),
        'reason',trim(COALESCE(p_reason,''))
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_dispel_condition_effect(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_condition_name TEXT,
    p_source_name TEXT,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_condition TEXT:=public.discord_condition_normalize(p_condition_name);
    v_character_id UUID;
    v_monster_id UUID;
    v_removed INTEGER:=0;
BEGIN
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    DELETE FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND cc.condition_name=v_condition
      AND cc.magic_effect=TRUE
      AND (trim(COALESCE(p_source_name,''))='' OR lower(cc.source_name)=lower(trim(p_source_name)))
      AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id));
    GET DIAGNOSTICS v_removed=ROW_COUNT;

    WITH deleted_suppressed AS (
        DELETE FROM public.discord_condition_suppressions s
        WHERE s.campaign_id=p_campaign_id
          AND s.condition_name=v_condition
          AND s.magic_effect=TRUE
          AND (trim(COALESCE(p_source_name,''))='' OR lower(s.source_name)=lower(trim(p_source_name)))
          AND ((v_character_id IS NOT NULL AND s.character_id=v_character_id)
            OR (v_monster_id IS NOT NULL AND s.combat_monster_id=v_monster_id))
        RETURNING 1
    )
    SELECT v_removed+COUNT(*)::INTEGER INTO v_removed FROM deleted_suppressed;

    IF v_monster_id IS NOT NULL THEN
        PERFORM public.discord_sync_legacy_monster_conditions(p_campaign_id,v_monster_id);
    END IF;

    RETURN jsonb_build_object('success',TRUE,'removed',v_removed,'condition',v_condition,'reason',trim(COALESCE(p_reason,'')));
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_resolve_condition_source_los(
    p_campaign_id UUID,
    p_target_type TEXT,
    p_target_name TEXT,
    p_source_name TEXT,
    p_has_line_of_sight BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character_id UUID;
    v_monster_id UUID;
    v_removed INTEGER:=0;
BEGIN
    SELECT t.character_id,t.combat_monster_id
    INTO v_character_id,v_monster_id
    FROM public.discord_condition_find_target(p_campaign_id,p_target_type,p_target_name) t;

    IF COALESCE(p_has_line_of_sight,FALSE) THEN
        RETURN jsonb_build_object('success',TRUE,'removed',0,'lineOfSight',TRUE);
    END IF;

    DELETE FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND cc.ends_on_source_lost_los=TRUE
      AND lower(cc.source_name)=lower(trim(COALESCE(p_source_name,'')))
      AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id));
    GET DIAGNOSTICS v_removed=ROW_COUNT;

    WITH deleted_suppressed AS (
        DELETE FROM public.discord_condition_suppressions s
        WHERE s.campaign_id=p_campaign_id
          AND s.ends_on_source_lost_los=TRUE
          AND lower(s.source_name)=lower(trim(COALESCE(p_source_name,'')))
          AND ((v_character_id IS NOT NULL AND s.character_id=v_character_id)
            OR (v_monster_id IS NOT NULL AND s.combat_monster_id=v_monster_id))
        RETURNING 1
    )
    SELECT v_removed+COUNT(*)::INTEGER INTO v_removed FROM deleted_suppressed;

    IF v_monster_id IS NOT NULL THEN
        PERFORM public.discord_sync_legacy_monster_conditions(p_campaign_id,v_monster_id);
    END IF;

    RETURN jsonb_build_object('success',TRUE,'removed',v_removed,'lineOfSight',FALSE);
END;
$$;


CREATE OR REPLACE FUNCTION public.discord_condition_sync_legacy_after_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF OLD.combat_monster_id IS NOT NULL THEN
        PERFORM public.discord_sync_legacy_monster_conditions(OLD.campaign_id,OLD.combat_monster_id);
    END IF;
    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_condition_sync_legacy_after_delete ON public.discord_combat_conditions;
CREATE TRIGGER trg_discord_condition_sync_legacy_after_delete
AFTER DELETE ON public.discord_combat_conditions
FOR EACH ROW
EXECUTE FUNCTION public.discord_condition_sync_legacy_after_delete();

CREATE OR REPLACE FUNCTION public.discord_condition_world_time_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE v_id UUID;
BEGIN
    DELETE FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=NEW.campaign_id
      AND cc.expires_world_minute IS NOT NULL
      AND cc.expires_world_minute<=NEW.world_minute;

    DELETE FROM public.discord_condition_immunities i
    WHERE i.campaign_id=NEW.campaign_id
      AND i.expires_world_minute IS NOT NULL
      AND i.expires_world_minute<=NEW.world_minute;

    FOR v_id IN
        SELECT s.suppression_id
        FROM public.discord_condition_suppressions s
        WHERE s.campaign_id=NEW.campaign_id
          AND s.restore_world_minute IS NOT NULL
          AND s.restore_world_minute<=NEW.world_minute
    LOOP
        PERFORM public.discord_restore_suppressed_conditions(NEW.campaign_id,v_id);
    END LOOP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_condition_world_time_lifecycle ON public.discord_campaign_world_time;
CREATE TRIGGER trg_discord_condition_world_time_lifecycle
AFTER UPDATE OF world_minute ON public.discord_campaign_world_time
FOR EACH ROW
EXECUTE FUNCTION public.discord_condition_world_time_lifecycle();

CREATE OR REPLACE FUNCTION public.discord_condition_source_death_cleanup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF COALESCE(NEW.defeated,FALSE)=TRUE AND COALESCE(OLD.defeated,FALSE)=FALSE THEN
        DELETE FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=NEW.campaign_id
          AND cc.ends_on_source_death=TRUE
          AND (
              cc.source_monster_id=NEW.combat_monster_id
              OR (cc.source_monster_id IS NULL AND lower(cc.source_name)=lower(NEW.display_name))
          );

        DELETE FROM public.discord_condition_suppressions s
        WHERE s.campaign_id=NEW.campaign_id
          AND s.ends_on_source_death=TRUE
          AND (
              s.source_monster_id=NEW.combat_monster_id
              OR (s.source_monster_id IS NULL AND lower(s.source_name)=lower(NEW.display_name))
          );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_condition_source_death_cleanup ON public.discord_campaign_combat_monsters;
CREATE TRIGGER trg_discord_condition_source_death_cleanup
AFTER UPDATE OF defeated ON public.discord_campaign_combat_monsters
FOR EACH ROW
EXECUTE FUNCTION public.discord_condition_source_death_cleanup();

-- Combat-ending effects that explicitly say they end with combat are cleaned up.
CREATE OR REPLACE FUNCTION public.discord_condition_combat_end_cleanup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF COALESCE(OLD.active,FALSE)=TRUE AND COALESCE(NEW.active,FALSE)=FALSE THEN
        DELETE FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=NEW.campaign_id
          AND cc.ends_on_combat_end=TRUE;

        -- Save-ending conditions deliberately remain. They can continue making
        -- saves through the GM outside combat until they succeed or are cured.
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_condition_combat_end_cleanup ON public.discord_campaign_combat_state;
CREATE TRIGGER trg_discord_condition_combat_end_cleanup
AFTER UPDATE OF active ON public.discord_campaign_combat_state
FOR EACH ROW
EXECUTE FUNCTION public.discord_condition_combat_end_cleanup();

GRANT EXECUTE ON FUNCTION public.discord_condition_world_minute(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_condition_find_target(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_condition_lifecycle(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,TEXT,INTEGER,BOOLEAN,BOOLEAN,BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_resolve_condition_save(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_suppress_condition(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_restore_suppressed_conditions(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_restore_suppressed_condition(UUID,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_condition_immunity(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_remove_condition_immunity(UUID,TEXT,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_apply_condition_extended(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_consume_condition_cure_item(UUID,TEXT,UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_dispel_condition_effect(UUID,TEXT,TEXT,TEXT,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_resolve_condition_source_los(UUID,TEXT,TEXT,TEXT,BOOLEAN) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
