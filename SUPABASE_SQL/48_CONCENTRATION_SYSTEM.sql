-- ============================================================
-- RabuShinAIGM Rules Build 6.19.3
-- Migration 48 - Concentration System
-- Baseline: 8a1ed6697de09fbf032b12896f5d583ed0e6f703
--
-- Requires:
--   Build 6.19 / Migration 45 - Conditions
--   Build 6.19.1 / Migration 46 - Death saves
--   Build 6.19.2 / Migration 47 - Full Action Economy
--
-- 2024 concentration rules implemented here:
--   * one concentration effect per character
--   * starting another concentration spell replaces the previous spell
--   * damage -> Constitution save, DC max(10, floor(damage/2)), cap 30
--   * Incapacitated / Paralyzed / Petrified / Stunned / Unconscious ends it
--   * 0 HP or death ends it
--   * existing Build 6.18.4 Exhaustion Level 3+ gives save disadvantage
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_character_concentration
(
    character_id UUID PRIMARY KEY
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    spell_name TEXT NOT NULL DEFAULT '',
    spell_level INTEGER NOT NULL DEFAULT 0 CHECK (spell_level >= 0),
    active BOOLEAN NOT NULL DEFAULT FALSE,
    started_at TIMESTAMPTZ NULL,
    ended_at TIMESTAMPTZ NULL,
    end_reason TEXT NOT NULL DEFAULT '',
    last_damage INTEGER NULL CHECK (last_damage IS NULL OR last_damage >= 0),
    last_save_dc INTEGER NULL CHECK (last_save_dc IS NULL OR last_save_dc BETWEEN 1 AND 30),
    last_roll_1 INTEGER NULL CHECK (last_roll_1 IS NULL OR last_roll_1 BETWEEN 1 AND 20),
    last_roll_2 INTEGER NULL CHECK (last_roll_2 IS NULL OR last_roll_2 BETWEEN 1 AND 20),
    last_kept_roll INTEGER NULL CHECK (last_kept_roll IS NULL OR last_kept_roll BETWEEN 1 AND 20),
    last_modifier INTEGER NULL,
    last_total INTEGER NULL,
    last_success BOOLEAN NULL,
    last_check_at TIMESTAMPTZ NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_discord_character_concentration_campaign
ON public.discord_character_concentration(campaign_id);

ALTER TABLE public.discord_character_concentration ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_character_concentration FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.discord_character_concentration TO service_role;

-- Conditions that include Incapacitated in this rules engine end concentration.
CREATE OR REPLACE FUNCTION public.discord_concentration_is_incapacitated(
    p_character_id UUID
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT EXISTS(
        SELECT 1
        FROM public.discord_combat_conditions cc
        WHERE cc.character_id=p_character_id
          AND lower(cc.condition_name) IN (
              'incapacitated','paralyzed','petrified','stunned','unconscious'
          )
          AND public.discord_condition_is_active(
              cc.campaign_id,cc.duration_type,cc.applied_round,cc.rounds_remaining
          )
    );
$$;

-- Base Constitution saving throw modifier used by the trusted damage trigger.
-- Current single-class character model: Artificer, Barbarian, Fighter and
-- Sorcerer have Constitution saving throw proficiency.
CREATE OR REPLACE FUNCTION public.discord_concentration_save_modifier(
    p_character_id UUID
)
RETURNS INTEGER
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT
        FLOOR((COALESCE(c.constitution,10)-10)/2.0)::INTEGER
        +
        CASE
            WHEN lower(trim(COALESCE(c.class_name,''))) IN
                 ('artificer','barbarian','fighter','sorcerer')
            THEN COALESCE(c.proficiency_bonus,0)::INTEGER
            ELSE 0
        END
    FROM public.discord_characters c
    WHERE c.character_id=p_character_id;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_start_concentration(UUID,TEXT,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_start_concentration(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_spell_name TEXT,
    p_spell_level INTEGER,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_previous TEXT := '';
BEGIN
    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    ORDER BY c.character_id
    LIMIT 1;

    IF v_character.character_id IS NULL THEN
        RAISE EXCEPTION 'Concentrating character could not be found.';
    END IF;
    IF COALESCE(v_character.life_state,'alive') <> 'alive' OR COALESCE(v_character.current_hp,0) <= 0 THEN
        RAISE EXCEPTION '% cannot begin concentration while dead or at 0 HP.', v_character.character_name;
    END IF;
    IF public.discord_concentration_is_incapacitated(v_character.character_id) THEN
        RAISE EXCEPTION '% cannot begin concentration while Incapacitated.', v_character.character_name;
    END IF;
    IF length(trim(COALESCE(p_spell_name,'')))=0 THEN
        RAISE EXCEPTION 'A concentration spell name is required.';
    END IF;

    SELECT s.spell_name INTO v_previous
    FROM public.discord_character_concentration s
    WHERE s.character_id=v_character.character_id
      AND s.active=TRUE;

    INSERT INTO public.discord_character_concentration(
        character_id,campaign_id,spell_name,spell_level,active,
        started_at,ended_at,end_reason,
        last_damage,last_save_dc,last_roll_1,last_roll_2,last_kept_roll,
        last_modifier,last_total,last_success,last_check_at,updated_at
    )
    VALUES(
        v_character.character_id,p_campaign_id,trim(p_spell_name),GREATEST(0,COALESCE(p_spell_level,0)),TRUE,
        NOW(),NULL,'',
        NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NOW()
    )
    ON CONFLICT (character_id) DO UPDATE
    SET campaign_id=EXCLUDED.campaign_id,
        spell_name=EXCLUDED.spell_name,
        spell_level=EXCLUDED.spell_level,
        active=TRUE,
        started_at=NOW(),
        ended_at=NULL,
        end_reason='',
        last_damage=NULL,
        last_save_dc=NULL,
        last_roll_1=NULL,
        last_roll_2=NULL,
        last_kept_roll=NULL,
        last_modifier=NULL,
        last_total=NULL,
        last_success=NULL,
        last_check_at=NULL,
        updated_at=NOW();

    RETURN jsonb_build_object(
        'character_id',v_character.character_id,
        'character_name',v_character.character_name,
        'active',TRUE,
        'spell_name',trim(p_spell_name),
        'spell_level',GREATEST(0,COALESCE(p_spell_level,0)),
        'replaced_spell_name',COALESCE(v_previous,''),
        'reason',COALESCE(NULLIF(trim(p_reason),''),'Concentration spell casting began')
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_end_concentration(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_end_concentration(
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
    v_spell TEXT := '';
    v_was_active BOOLEAN := FALSE;
    v_reason TEXT := COALESCE(NULLIF(trim(p_reason),''),'Concentration ended');
BEGIN
    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    ORDER BY c.character_id
    LIMIT 1;

    IF v_character.character_id IS NULL THEN
        RAISE EXCEPTION 'Concentrating character could not be found.';
    END IF;

    SELECT COALESCE(s.spell_name,''),COALESCE(s.active,FALSE)
    INTO v_spell,v_was_active
    FROM public.discord_character_concentration s
    WHERE s.character_id=v_character.character_id;

    IF COALESCE(v_was_active,FALSE) THEN
        UPDATE public.discord_character_concentration
        SET active=FALSE,ended_at=NOW(),end_reason=v_reason,updated_at=NOW()
        WHERE character_id=v_character.character_id;
    END IF;

    RETURN jsonb_build_object(
        'character_id',v_character.character_id,
        'character_name',v_character.character_name,
        'active',FALSE,
        'spell_name',COALESCE(v_spell,''),
        'was_active',COALESCE(v_was_active,FALSE),
        'reason',v_reason
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_concentration_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_concentration_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    active BOOLEAN,
    spell_name TEXT,
    spell_level INTEGER,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    end_reason TEXT,
    last_damage INTEGER,
    last_save_dc INTEGER,
    last_roll_1 INTEGER,
    last_roll_2 INTEGER,
    last_kept_roll INTEGER,
    last_modifier INTEGER,
    last_total INTEGER,
    last_success BOOLEAN,
    last_check_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'Player is not a member of this campaign.';
    END IF;

    RETURN QUERY
    SELECT
        c.character_id,
        c.character_name::TEXT,
        COALESCE(s.active,FALSE),
        COALESCE(s.spell_name,'')::TEXT,
        COALESCE(s.spell_level,0)::INTEGER,
        s.started_at,
        s.ended_at,
        COALESCE(s.end_reason,'')::TEXT,
        s.last_damage,
        s.last_save_dc,
        s.last_roll_1,
        s.last_roll_2,
        s.last_kept_roll,
        s.last_modifier,
        s.last_total,
        s.last_success,
        s.last_check_at
    FROM public.discord_characters c
    LEFT JOIN public.discord_character_concentration s
      ON s.character_id=c.character_id
    WHERE c.campaign_id=p_campaign_id
    ORDER BY lower(c.character_name),c.character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_concentration_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_concentration_state(
    p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    active BOOLEAN,
    spell_name TEXT,
    spell_level INTEGER,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    end_reason TEXT,
    last_damage INTEGER,
    last_save_dc INTEGER,
    last_roll_1 INTEGER,
    last_roll_2 INTEGER,
    last_kept_roll INTEGER,
    last_modifier INTEGER,
    last_total INTEGER,
    last_success BOOLEAN,
    last_check_at TIMESTAMPTZ
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT
        c.character_id,
        c.character_name::TEXT,
        COALESCE(s.active,FALSE),
        COALESCE(s.spell_name,'')::TEXT,
        COALESCE(s.spell_level,0)::INTEGER,
        s.started_at,
        s.ended_at,
        COALESCE(s.end_reason,'')::TEXT,
        s.last_damage,
        s.last_save_dc,
        s.last_roll_1,
        s.last_roll_2,
        s.last_kept_roll,
        s.last_modifier,
        s.last_total,
        s.last_success,
        s.last_check_at
    FROM public.discord_characters c
    LEFT JOIN public.discord_character_concentration s
      ON s.character_id=c.character_id
    WHERE c.campaign_id=p_campaign_id
    ORDER BY lower(c.character_name),c.character_id;
$$;

-- Every HP-loss path that updates discord_characters.current_hp passes here.
-- One DB update is one damage source/check. 0 HP/death ends concentration
-- without a save. Natural 1/20 have no special rule on this saving throw.
CREATE OR REPLACE FUNCTION public.discord_enforce_concentration_on_character_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_damage INTEGER;
    v_dc INTEGER;
    v_roll_1 INTEGER;
    v_roll_2 INTEGER;
    v_kept INTEGER;
    v_modifier INTEGER;
    v_total INTEGER;
    v_success BOOLEAN;
    v_disadvantage BOOLEAN;
BEGIN
    IF NOT EXISTS(
        SELECT 1
        FROM public.discord_character_concentration s
        WHERE s.character_id=NEW.character_id AND s.active=TRUE
    ) THEN
        RETURN NEW;
    END IF;

    IF COALESCE(NEW.life_state,'alive') <> 'alive' THEN
        UPDATE public.discord_character_concentration
        SET active=FALSE,ended_at=NOW(),end_reason='Character died.',
            last_damage=GREATEST(0,COALESCE(OLD.current_hp,0)-COALESCE(NEW.current_hp,0)),
            last_save_dc=NULL,last_roll_1=NULL,last_roll_2=NULL,last_kept_roll=NULL,
            last_modifier=NULL,last_total=NULL,last_success=NULL,last_check_at=NOW(),updated_at=NOW()
        WHERE character_id=NEW.character_id AND active=TRUE;
        RETURN NEW;
    END IF;

    IF COALESCE(NEW.current_hp,0) <= 0 THEN
        UPDATE public.discord_character_concentration
        SET active=FALSE,ended_at=NOW(),end_reason='Character reached 0 HP and became Unconscious.',
            last_damage=GREATEST(0,COALESCE(OLD.current_hp,0)-COALESCE(NEW.current_hp,0)),
            last_save_dc=NULL,last_roll_1=NULL,last_roll_2=NULL,last_kept_roll=NULL,
            last_modifier=NULL,last_total=NULL,last_success=NULL,last_check_at=NOW(),updated_at=NOW()
        WHERE character_id=NEW.character_id AND active=TRUE;
        RETURN NEW;
    END IF;

    v_damage := GREATEST(0,COALESCE(OLD.current_hp,0)-COALESCE(NEW.current_hp,0));
    IF v_damage <= 0 THEN
        RETURN NEW;
    END IF;

    v_dc := LEAST(30,GREATEST(10,FLOOR(v_damage/2.0)::INTEGER));
    v_modifier := COALESCE(public.discord_concentration_save_modifier(NEW.character_id),0);
    v_disadvantage := COALESCE(NEW.exhaustion_level,0) >= 3;

    v_roll_1 := FLOOR(random()*20)::INTEGER + 1;
    IF v_disadvantage THEN
        v_roll_2 := FLOOR(random()*20)::INTEGER + 1;
        v_kept := LEAST(v_roll_1,v_roll_2);
    ELSE
        v_roll_2 := NULL;
        v_kept := v_roll_1;
    END IF;

    v_total := v_kept + v_modifier;
    v_success := v_total >= v_dc;

    UPDATE public.discord_character_concentration
    SET last_damage=v_damage,
        last_save_dc=v_dc,
        last_roll_1=v_roll_1,
        last_roll_2=v_roll_2,
        last_kept_roll=v_kept,
        last_modifier=v_modifier,
        last_total=v_total,
        last_success=v_success,
        last_check_at=NOW(),
        active=v_success,
        ended_at=CASE WHEN v_success THEN NULL ELSE NOW() END,
        end_reason=CASE
            WHEN v_success THEN ''
            ELSE format('Concentration save failed after %s damage (DC %s, total %s).',v_damage,v_dc,v_total)
        END,
        updated_at=NOW()
    WHERE character_id=NEW.character_id AND active=TRUE;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_concentration_character ON public.discord_characters;
CREATE TRIGGER trg_discord_concentration_character
AFTER UPDATE OF current_hp,life_state ON public.discord_characters
FOR EACH ROW
EXECUTE FUNCTION public.discord_enforce_concentration_on_character_update();

CREATE OR REPLACE FUNCTION public.discord_end_concentration_on_condition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NEW.character_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF lower(COALESCE(NEW.condition_name,'')) NOT IN
       ('incapacitated','paralyzed','petrified','stunned','unconscious') THEN
        RETURN NEW;
    END IF;

    IF NOT public.discord_condition_is_active(
        NEW.campaign_id,NEW.duration_type,NEW.applied_round,NEW.rounds_remaining
    ) THEN
        RETURN NEW;
    END IF;

    UPDATE public.discord_character_concentration
    SET active=FALSE,
        ended_at=NOW(),
        end_reason='Concentration ended by ' || initcap(lower(NEW.condition_name)) || '.',
        last_save_dc=NULL,
        last_roll_1=NULL,
        last_roll_2=NULL,
        last_kept_roll=NULL,
        last_modifier=NULL,
        last_total=NULL,
        last_success=NULL,
        last_check_at=NOW(),
        updated_at=NOW()
    WHERE character_id=NEW.character_id
      AND active=TRUE;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_concentration_condition ON public.discord_combat_conditions;
CREATE TRIGGER trg_discord_concentration_condition
AFTER INSERT OR UPDATE
ON public.discord_combat_conditions
FOR EACH ROW
EXECUTE FUNCTION public.discord_end_concentration_on_condition();

REVOKE ALL ON FUNCTION public.discord_concentration_is_incapacitated(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_concentration_save_modifier(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_gm_start_concentration(UUID,TEXT,TEXT,INTEGER,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_gm_end_concentration(UUID,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_get_concentration_state(UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.discord_gm_get_concentration_state(UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.discord_concentration_is_incapacitated(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_concentration_save_modifier(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_start_concentration(UUID,TEXT,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_end_concentration(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_concentration_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_concentration_state(UUID) TO service_role;

COMMIT;
