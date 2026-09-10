-- ============================================================
-- RabuShinAIGM Rules Build 6.19
-- Migration 45 - Combat Conditions + Status Effects
-- Run AFTER Migration 44 and Build 6.18.4 Migration 41.
-- Safe to rerun.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_combat_conditions
(
    condition_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL,
    character_id UUID NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    combat_monster_id UUID NULL REFERENCES public.discord_campaign_combat_monsters(combat_monster_id) ON DELETE CASCADE,
    condition_name TEXT NOT NULL,
    source_name TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    duration_type TEXT NOT NULL DEFAULT 'persistent',
    rounds_remaining INTEGER NULL,
    save_ability TEXT NULL,
    save_dc INTEGER NULL,
    applied_round INTEGER NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_discord_condition_entity_type
        CHECK (entity_type IN ('character','monster')),
    CONSTRAINT ck_discord_condition_identity
        CHECK (
            (entity_type='character' AND character_id IS NOT NULL AND combat_monster_id IS NULL)
            OR
            (entity_type='monster' AND combat_monster_id IS NOT NULL AND character_id IS NULL)
        ),
    CONSTRAINT ck_discord_condition_duration
        CHECK (duration_type IN ('persistent','until_removed','rounds','save_ends')),
    CONSTRAINT ck_discord_condition_rounds
        CHECK (rounds_remaining IS NULL OR rounds_remaining > 0),
    CONSTRAINT ck_discord_condition_save_dc
        CHECK (save_dc IS NULL OR save_dc > 0)
);

ALTER TABLE public.discord_combat_conditions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_combat_conditions FROM anon, authenticated;

CREATE INDEX IF NOT EXISTS ix_discord_combat_conditions_campaign
    ON public.discord_combat_conditions(campaign_id);

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_combat_conditions_character_source
    ON public.discord_combat_conditions(campaign_id, character_id, condition_name, lower(source_name))
    WHERE character_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_combat_conditions_monster_source
    ON public.discord_combat_conditions(campaign_id, combat_monster_id, condition_name, lower(source_name))
    WHERE combat_monster_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.discord_condition_normalize(p_condition TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v TEXT := lower(trim(COALESCE(p_condition,'')));
BEGIN
    IF v NOT IN (
        'blinded','charmed','deafened','frightened','grappled',
        'incapacitated','invisible','paralyzed','petrified','poisoned',
        'prone','restrained','stunned','unconscious'
    ) THEN
        RAISE EXCEPTION 'Unsupported condition: %', p_condition;
    END IF;
    RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_condition_current_round(p_campaign_id UUID)
RETURNS INTEGER
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT GREATEST(1, COALESCE(
        (SELECT s.round_number
         FROM public.discord_campaign_combat_state s
         WHERE s.campaign_id=p_campaign_id),
        1
    ));
$$;

CREATE OR REPLACE FUNCTION public.discord_condition_is_active(
    p_campaign_id UUID,
    p_duration_type TEXT,
    p_applied_round INTEGER,
    p_rounds_remaining INTEGER
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT
        COALESCE(p_duration_type,'persistent') <> 'rounds'
        OR p_applied_round IS NULL
        OR p_rounds_remaining IS NULL
        OR public.discord_condition_current_round(p_campaign_id)
             < p_applied_round + p_rounds_remaining;
$$;

CREATE OR REPLACE FUNCTION public.discord_sync_legacy_monster_conditions(
    p_campaign_id UUID,
    p_combat_monster_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_conditions TEXT;
BEGIN
    SELECT string_agg(initcap(cc.condition_name), ', ' ORDER BY cc.condition_name)
    INTO v_conditions
    FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND cc.combat_monster_id=p_combat_monster_id
      AND public.discord_condition_is_active(
            cc.campaign_id,cc.duration_type,cc.applied_round,cc.rounds_remaining);

    UPDATE public.discord_campaign_combat_monsters
    SET conditions=COALESCE(v_conditions,'')
    WHERE campaign_id=p_campaign_id
      AND combat_monster_id=p_combat_monster_id;
END;
$$;

-- 0 HP automatically supplies an Unconscious source. Healing above 0 removes
-- only the 0 HP source, preserving magical/sleep/etc. Unconscious sources.
CREATE OR REPLACE FUNCTION public.discord_sync_zero_hp_unconscious()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF COALESCE(NEW.current_hp,0) <= 0 THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.discord_combat_conditions cc
            WHERE cc.campaign_id=NEW.campaign_id
              AND cc.character_id=NEW.character_id
              AND cc.condition_name='unconscious'
              AND lower(cc.source_name)=lower('0 HP')
        ) THEN
            INSERT INTO public.discord_combat_conditions(
                campaign_id,entity_type,character_id,condition_name,source_name,
                notes,duration_type,applied_round
            )
            VALUES(
                NEW.campaign_id,'character',NEW.character_id,'unconscious','0 HP',
                'Automatically applied because current HP reached 0.','persistent',
                public.discord_condition_current_round(NEW.campaign_id)
            );
        END IF;
    ELSE
        DELETE FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=NEW.campaign_id
          AND cc.character_id=NEW.character_id
          AND cc.condition_name='unconscious'
          AND lower(cc.source_name)=lower('0 HP');
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_zero_hp_unconscious ON public.discord_characters;
CREATE TRIGGER trg_discord_zero_hp_unconscious
AFTER INSERT OR UPDATE OF current_hp ON public.discord_characters
FOR EACH ROW
EXECUTE FUNCTION public.discord_sync_zero_hp_unconscious();

-- Backfill any character already at 0 HP when this migration is installed.
INSERT INTO public.discord_combat_conditions(
    campaign_id,entity_type,character_id,condition_name,source_name,
    notes,duration_type,applied_round
)
SELECT
    c.campaign_id,'character',c.character_id,'unconscious','0 HP',
    'Automatically applied because current HP is 0.','persistent',
    public.discord_condition_current_round(c.campaign_id)
FROM public.discord_characters c
WHERE COALESCE(c.current_hp,0) <= 0
  AND NOT EXISTS (
      SELECT 1 FROM public.discord_combat_conditions cc
      WHERE cc.campaign_id=c.campaign_id
        AND cc.character_id=c.character_id
        AND cc.condition_name='unconscious'
        AND lower(cc.source_name)=lower('0 HP')
  );

DROP FUNCTION IF EXISTS public.discord_get_combat_conditions(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_combat_conditions(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    condition_id UUID,
    entity_type TEXT,
    character_id UUID,
    combat_monster_id UUID,
    display_name TEXT,
    condition_name TEXT,
    source_name TEXT,
    notes TEXT,
    duration_type TEXT,
    rounds_remaining INTEGER,
    save_ability TEXT,
    save_dc INTEGER,
    applied_round INTEGER,
    exhaustion_level INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id
          AND cm.player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'Player is not a member of this campaign.';
    END IF;

    RETURN QUERY
    SELECT
        cc.condition_id,
        cc.entity_type,
        cc.character_id,
        cc.combat_monster_id,
        COALESCE(c.character_name,m.display_name,'Unknown')::TEXT,
        cc.condition_name,
        cc.source_name,
        cc.notes,
        cc.duration_type,
        CASE
            WHEN cc.duration_type='rounds'
             AND cc.applied_round IS NOT NULL
             AND cc.rounds_remaining IS NOT NULL
            THEN GREATEST(
                0,
                (cc.applied_round + cc.rounds_remaining)
                - public.discord_condition_current_round(cc.campaign_id)
            )
            ELSE cc.rounds_remaining
        END::INTEGER,
        COALESCE(cc.save_ability,'')::TEXT,
        cc.save_dc,
        cc.applied_round,
        0::INTEGER
    FROM public.discord_combat_conditions cc
    LEFT JOIN public.discord_characters c ON c.character_id=cc.character_id
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=cc.combat_monster_id
    WHERE cc.campaign_id=p_campaign_id
      AND public.discord_condition_is_active(
            cc.campaign_id,cc.duration_type,cc.applied_round,cc.rounds_remaining)

    UNION ALL

    SELECT
        NULL::UUID,
        'character'::TEXT,
        c.character_id,
        NULL::UUID,
        c.character_name::TEXT,
        'exhaustion'::TEXT,
        'Survival / rules'::TEXT,
        ('Level '||COALESCE(c.exhaustion_level,0)::TEXT)::TEXT,
        'persistent'::TEXT,
        NULL::INTEGER,
        ''::TEXT,
        NULL::INTEGER,
        NULL::INTEGER,
        COALESCE(c.exhaustion_level,0)::INTEGER
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND COALESCE(c.exhaustion_level,0)>0;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_combat_conditions(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_combat_conditions(
    p_campaign_id UUID
)
RETURNS TABLE(
    condition_id UUID,
    entity_type TEXT,
    character_id UUID,
    combat_monster_id UUID,
    display_name TEXT,
    condition_name TEXT,
    source_name TEXT,
    notes TEXT,
    duration_type TEXT,
    rounds_remaining INTEGER,
    save_ability TEXT,
    save_dc INTEGER,
    applied_round INTEGER,
    exhaustion_level INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        cc.condition_id,
        cc.entity_type,
        cc.character_id,
        cc.combat_monster_id,
        COALESCE(c.character_name,m.display_name,'Unknown')::TEXT,
        cc.condition_name,
        cc.source_name,
        cc.notes,
        cc.duration_type,
        CASE
            WHEN cc.duration_type='rounds'
             AND cc.applied_round IS NOT NULL
             AND cc.rounds_remaining IS NOT NULL
            THEN GREATEST(
                0,
                (cc.applied_round + cc.rounds_remaining)
                - public.discord_condition_current_round(cc.campaign_id)
            )
            ELSE cc.rounds_remaining
        END::INTEGER,
        COALESCE(cc.save_ability,'')::TEXT,
        cc.save_dc,
        cc.applied_round,
        0::INTEGER
    FROM public.discord_combat_conditions cc
    LEFT JOIN public.discord_characters c ON c.character_id=cc.character_id
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=cc.combat_monster_id
    WHERE cc.campaign_id=p_campaign_id
      AND public.discord_condition_is_active(
            cc.campaign_id,cc.duration_type,cc.applied_round,cc.rounds_remaining)

    UNION ALL

    SELECT
        NULL::UUID,
        'character'::TEXT,
        c.character_id,
        NULL::UUID,
        c.character_name::TEXT,
        'exhaustion'::TEXT,
        'Survival / rules'::TEXT,
        ('Level '||COALESCE(c.exhaustion_level,0)::TEXT)::TEXT,
        'persistent'::TEXT,
        NULL::INTEGER,
        ''::TEXT,
        NULL::INTEGER,
        NULL::INTEGER,
        COALESCE(c.exhaustion_level,0)::INTEGER
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND COALESCE(c.exhaustion_level,0)>0;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_apply_condition(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,INTEGER,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_apply_condition(
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
    v_type TEXT := lower(trim(COALESCE(p_target_type,'')));
    v_name TEXT := trim(COALESCE(p_target_name,''));
    v_condition TEXT := public.discord_condition_normalize(p_condition_name);
    v_source TEXT := trim(COALESCE(p_source_name,''));
    v_duration TEXT := lower(trim(COALESCE(NULLIF(p_duration_type,''),'persistent')));
    v_save TEXT := lower(trim(COALESCE(p_save_ability,'')));
    v_character_id UUID;
    v_monster_id UUID;
    v_condition_id UUID;
    v_round INTEGER := public.discord_condition_current_round(p_campaign_id);
BEGIN
    IF v_type NOT IN ('character','monster') THEN
        RAISE EXCEPTION 'Condition targetType must be character or monster.';
    END IF;
    IF v_name='' THEN
        RAISE EXCEPTION 'Condition targetName is required.';
    END IF;
    IF v_duration NOT IN ('persistent','until_removed','rounds','save_ends') THEN
        RAISE EXCEPTION 'Invalid condition duration type: %', p_duration_type;
    END IF;
    IF v_duration='rounds' AND COALESCE(p_rounds_remaining,0)<=0 THEN
        RAISE EXCEPTION 'Round-based conditions require a positive roundsRemaining value.';
    END IF;
    IF v_duration='save_ends' THEN
        IF v_save NOT IN ('strength','dexterity','constitution','intelligence','wisdom','charisma')
           OR COALESCE(p_save_dc,0)<=0 THEN
            RAISE EXCEPTION 'save_ends requires saveAbility and a positive saveDc.';
        END IF;
    ELSE
        v_save := '';
    END IF;

    IF v_type='character' THEN
        SELECT c.character_id INTO v_character_id
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND lower(c.character_name)=lower(v_name)
        ORDER BY c.character_id
        LIMIT 1;
        IF v_character_id IS NULL THEN
            RAISE EXCEPTION 'Party character not found: %', v_name;
        END IF;
    ELSE
        SELECT m.combat_monster_id INTO v_monster_id
        FROM public.discord_campaign_combat_monsters m
        WHERE m.campaign_id=p_campaign_id
          AND lower(m.display_name)=lower(v_name)
        ORDER BY m.combat_monster_id
        LIMIT 1;
        IF v_monster_id IS NULL THEN
            RAISE EXCEPTION 'Active combat monster not found: %', v_name;
        END IF;
    END IF;

    -- Petrified creatures are immune to new poison. Existing poison remains stored
    -- and is mechanically suspended while Petrified.
    IF v_condition='poisoned' AND EXISTS (
        SELECT 1
        FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=p_campaign_id
          AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
            OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id))
          AND cc.condition_name='petrified'
          AND public.discord_condition_is_active(
                cc.campaign_id,cc.duration_type,cc.applied_round,cc.rounds_remaining)
    ) THEN
        RETURN jsonb_build_object(
            'applied',false,'immune',true,'target',v_name,'condition',v_condition,
            'reason','Petrified creatures are immune to poison.'
        );
    END IF;

    SELECT cc.condition_id INTO v_condition_id
    FROM public.discord_combat_conditions cc
    WHERE cc.campaign_id=p_campaign_id
      AND ((v_character_id IS NOT NULL AND cc.character_id=v_character_id)
        OR (v_monster_id IS NOT NULL AND cc.combat_monster_id=v_monster_id))
      AND cc.condition_name=v_condition
      AND lower(cc.source_name)=lower(v_source)
    LIMIT 1
    FOR UPDATE;

    IF v_condition_id IS NULL THEN
        INSERT INTO public.discord_combat_conditions(
            campaign_id,entity_type,character_id,combat_monster_id,
            condition_name,source_name,notes,duration_type,rounds_remaining,
            save_ability,save_dc,applied_round
        )
        VALUES(
            p_campaign_id,v_type,v_character_id,v_monster_id,
            v_condition,v_source,trim(COALESCE(p_notes,'')),v_duration,
            CASE WHEN v_duration='rounds' THEN p_rounds_remaining ELSE NULL END,
            CASE WHEN v_duration='save_ends' THEN v_save ELSE NULL END,
            CASE WHEN v_duration='save_ends' THEN p_save_dc ELSE NULL END,
            v_round
        )
        RETURNING condition_id INTO v_condition_id;
    ELSE
        UPDATE public.discord_combat_conditions
        SET notes=trim(COALESCE(p_notes,'')),
            duration_type=v_duration,
            rounds_remaining=CASE WHEN v_duration='rounds' THEN p_rounds_remaining ELSE NULL END,
            save_ability=CASE WHEN v_duration='save_ends' THEN v_save ELSE NULL END,
            save_dc=CASE WHEN v_duration='save_ends' THEN p_save_dc ELSE NULL END,
            applied_round=v_round,
            updated_at=NOW()
        WHERE condition_id=v_condition_id;
    END IF;

    IF v_monster_id IS NOT NULL THEN
        PERFORM public.discord_sync_legacy_monster_conditions(p_campaign_id,v_monster_id);
    END IF;

    RETURN jsonb_build_object(
        'applied',true,
        'conditionId',v_condition_id,
        'targetType',v_type,
        'target',v_name,
        'condition',v_condition,
        'source',v_source,
        'durationType',v_duration,
        'roundsRemaining',CASE WHEN v_duration='rounds' THEN p_rounds_remaining ELSE NULL END,
        'saveAbility',CASE WHEN v_duration='save_ends' THEN v_save ELSE NULL END,
        'saveDc',CASE WHEN v_duration='save_ends' THEN p_save_dc ELSE NULL END,
        'appliedRound',v_round
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_remove_condition(UUID,TEXT,TEXT,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_remove_condition(
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
    v_type TEXT := lower(trim(COALESCE(p_target_type,'')));
    v_name TEXT := trim(COALESCE(p_target_name,''));
    v_condition TEXT := public.discord_condition_normalize(p_condition_name);
    v_source TEXT := trim(COALESCE(p_source_name,''));
    v_character_id UUID;
    v_monster_id UUID;
    v_removed INTEGER := 0;
BEGIN
    IF v_type='character' THEN
        SELECT c.character_id INTO v_character_id
        FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id
          AND lower(c.character_name)=lower(v_name)
        ORDER BY c.character_id
        LIMIT 1;
        IF v_character_id IS NULL THEN RAISE EXCEPTION 'Party character not found: %', v_name; END IF;

        DELETE FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=p_campaign_id
          AND cc.character_id=v_character_id
          AND cc.condition_name=v_condition
          AND (v_source='' OR lower(cc.source_name)=lower(v_source));
        GET DIAGNOSTICS v_removed = ROW_COUNT;
    ELSIF v_type='monster' THEN
        SELECT m.combat_monster_id INTO v_monster_id
        FROM public.discord_campaign_combat_monsters m
        WHERE m.campaign_id=p_campaign_id
          AND lower(m.display_name)=lower(v_name)
        ORDER BY m.combat_monster_id
        LIMIT 1;
        IF v_monster_id IS NULL THEN RAISE EXCEPTION 'Active combat monster not found: %', v_name; END IF;

        DELETE FROM public.discord_combat_conditions cc
        WHERE cc.campaign_id=p_campaign_id
          AND cc.combat_monster_id=v_monster_id
          AND cc.condition_name=v_condition
          AND (v_source='' OR lower(cc.source_name)=lower(v_source));
        GET DIAGNOSTICS v_removed = ROW_COUNT;
        PERFORM public.discord_sync_legacy_monster_conditions(p_campaign_id,v_monster_id);
    ELSE
        RAISE EXCEPTION 'Condition targetType must be character or monster.';
    END IF;

    RETURN jsonb_build_object(
        'removed',v_removed>0,
        'removedCount',v_removed,
        'targetType',v_type,
        'target',v_name,
        'condition',v_condition,
        'source',v_source,
        'reason',trim(COALESCE(p_reason,''))
    );
END;
$$;

-- Build 6.19 security follows the existing RabuShin service-role RPC pattern.
REVOKE ALL ON TABLE public.discord_combat_conditions FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.discord_condition_normalize(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_condition_current_round(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_condition_is_active(UUID,TEXT,INTEGER,INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_sync_legacy_monster_conditions(UUID,UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_sync_zero_hp_unconscious() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.discord_get_combat_conditions(UUID,UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_combat_conditions(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_apply_condition(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,INTEGER,TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_remove_condition(UUID,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_combat_conditions(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_combat_conditions(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_apply_condition(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_remove_condition(UUID,TEXT,TEXT,TEXT,TEXT,TEXT) TO service_role;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
    IF to_regclass('public.discord_combat_conditions') IS NULL THEN
        RAISE EXCEPTION 'Build 6.19 validation failed: discord_combat_conditions table missing.';
    END IF;
    IF to_regprocedure('public.discord_get_combat_conditions(uuid,uuid)') IS NULL THEN
        RAISE EXCEPTION 'Build 6.19 validation failed: member condition getter missing.';
    END IF;
    IF to_regprocedure('public.discord_gm_apply_condition(uuid,text,text,text,text,text,integer,text,integer,text)') IS NULL THEN
        RAISE EXCEPTION 'Build 6.19 validation failed: GM apply condition RPC missing.';
    END IF;
    IF to_regprocedure('public.discord_gm_remove_condition(uuid,text,text,text,text,text)') IS NULL THEN
        RAISE EXCEPTION 'Build 6.19 validation failed: GM remove condition RPC missing.';
    END IF;
END
$$;

COMMIT;
