-- ============================================================
-- RabuShinAIGM Rules Build 6.19.1
-- Migration 46 - Death Saving Throws
--
-- Requires:
--   Build 6.2 death/respawn system
--   Build 6.18.4 Exhaustion
--   Build 6.19 Migration 45
--   Build 6.19.0.1 Exhaustion Source Hotfix
--
-- Rules:
--   10-19 = 1 success
--   2-9   = 1 failure
--   Nat 1 = 2 failures
--   Nat20 = regain 1 HP
--   3 successes = stable
--   3 failures = actual death
--   Damage while already at 0 HP = 1 failure, or 2 if the hit was critical
--   Remaining damage >= effective HP maximum = instant death
--
-- Safe to rerun.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_character_death_saves
(
    character_id UUID PRIMARY KEY
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    successes INTEGER NOT NULL DEFAULT 0
        CHECK (successes BETWEEN 0 AND 3),
    failures INTEGER NOT NULL DEFAULT 0
        CHECK (failures BETWEEN 0 AND 3),
    stable BOOLEAN NOT NULL DEFAULT FALSE,
    last_roll INTEGER NULL
        CHECK (last_roll IS NULL OR last_roll BETWEEN 1 AND 20),
    last_result TEXT NOT NULL DEFAULT '',
    last_resolved_round INTEGER NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.discord_character_death_saves ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_character_death_saves
FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.discord_character_death_saves TO service_role;

CREATE INDEX IF NOT EXISTS ix_discord_character_death_saves_campaign
ON public.discord_character_death_saves(campaign_id);


-- Keep death-save state synchronized with HP transitions.
-- Entering 0 HP while alive starts a fresh death-save track.
-- Regaining HP resets successes/failures/stability.
CREATE OR REPLACE FUNCTION public.discord_sync_character_death_save_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
    IF NEW.life_state='alive' AND COALESCE(NEW.current_hp,0)<=0 THEN
        IF TG_OP='INSERT'
           OR COALESCE(OLD.current_hp,0)>0
           OR COALESCE(OLD.life_state,'alive')<>'alive' THEN
            INSERT INTO public.discord_character_death_saves(
                character_id,campaign_id,successes,failures,stable,
                last_roll,last_result,last_resolved_round,updated_at
            )
            VALUES(
                NEW.character_id,NEW.campaign_id,0,0,FALSE,
                NULL,'',NULL,NOW()
            )
            ON CONFLICT (character_id) DO UPDATE
            SET campaign_id=EXCLUDED.campaign_id,
                successes=0,
                failures=0,
                stable=FALSE,
                last_roll=NULL,
                last_result='',
                last_resolved_round=NULL,
                updated_at=NOW();
        ELSE
            INSERT INTO public.discord_character_death_saves(
                character_id,campaign_id
            )
            VALUES(NEW.character_id,NEW.campaign_id)
            ON CONFLICT (character_id) DO NOTHING;
        END IF;
    ELSIF COALESCE(NEW.current_hp,0)>0 THEN
        INSERT INTO public.discord_character_death_saves(
            character_id,campaign_id,successes,failures,stable,
            last_roll,last_result,last_resolved_round,updated_at
        )
        VALUES(
            NEW.character_id,NEW.campaign_id,0,0,FALSE,
            NULL,'',NULL,NOW()
        )
        ON CONFLICT (character_id) DO UPDATE
        SET campaign_id=EXCLUDED.campaign_id,
            successes=0,
            failures=0,
            stable=FALSE,
            last_resolved_round=NULL,
            updated_at=NOW();
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_character_death_save_state
ON public.discord_characters;

CREATE TRIGGER trg_discord_character_death_save_state
AFTER INSERT OR UPDATE OF current_hp,life_state
ON public.discord_characters
FOR EACH ROW
EXECUTE FUNCTION public.discord_sync_character_death_save_state();


-- Backfill currently-living characters already at 0 HP.
INSERT INTO public.discord_character_death_saves(
    character_id,campaign_id,successes,failures,stable,
    last_roll,last_result,last_resolved_round
)
SELECT
    c.character_id,c.campaign_id,0,0,FALSE,NULL,'',NULL
FROM public.discord_characters c
WHERE c.life_state='alive'
  AND COALESCE(c.current_hp,0)<=0
ON CONFLICT (character_id) DO NOTHING;


DROP FUNCTION IF EXISTS public.discord_get_death_save_state(UUID,UUID);

CREATE OR REPLACE FUNCTION public.discord_get_death_save_state(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    current_hp INTEGER,
    max_hp INTEGER,
    life_state TEXT,
    successes INTEGER,
    failures INTEGER,
    stable BOOLEAN,
    last_roll INTEGER,
    last_result TEXT,
    last_resolved_round INTEGER,
    current_round INTEGER,
    combat_active BOOLEAN,
    is_current_turn BOOLEAN,
    active BOOLEAN,
    requires_save BOOLEAN,
    resolved_this_round BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_round INTEGER;
    v_combat_active BOOLEAN := FALSE;
    v_current_turn BOOLEAN := FALSE;
BEGIN
    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND c.player_id=p_player_id
    LIMIT 1;

    IF v_character.character_id IS NULL THEN
        RETURN;
    END IF;

    IF v_character.life_state='alive'
       AND COALESCE(v_character.current_hp,0)<=0 THEN
        INSERT INTO public.discord_character_death_saves(
            character_id,campaign_id
        )
        VALUES(v_character.character_id,p_campaign_id)
        ON CONFLICT (character_id) DO NOTHING;
    END IF;

    SELECT
        COALESCE(s.active,FALSE),
        CASE
            WHEN COALESCE(s.active,FALSE)
             AND s.current_turn_type='character'
             AND s.current_turn_character_id=v_character.character_id
            THEN TRUE ELSE FALSE
        END,
        CASE WHEN COALESCE(s.active,FALSE)
             THEN GREATEST(1,COALESCE(s.round_number,1))
             ELSE NULL
        END
    INTO v_combat_active,v_current_turn,v_round
    FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id;

    v_combat_active:=COALESCE(v_combat_active,FALSE);
    v_current_turn:=COALESCE(v_current_turn,FALSE);

    RETURN QUERY
    SELECT
        v_character.character_id,
        v_character.character_name,
        COALESCE(v_character.current_hp,0),
        GREATEST(1,COALESCE(v_character.max_hp,1)),
        v_character.life_state,
        COALESCE(ds.successes,0),
        COALESCE(ds.failures,0),
        COALESCE(ds.stable,FALSE),
        ds.last_roll,
        COALESCE(ds.last_result,'')::TEXT,
        ds.last_resolved_round,
        v_round,
        v_combat_active,
        v_current_turn,
        (
            v_character.life_state='alive'
            AND COALESCE(v_character.current_hp,0)<=0
        ),
        (
            v_character.life_state='alive'
            AND COALESCE(v_character.current_hp,0)<=0
            AND NOT COALESCE(ds.stable,FALSE)
            AND (
                NOT v_combat_active
                OR ds.last_resolved_round IS DISTINCT FROM v_round
            )
        ),
        (
            v_combat_active
            AND ds.last_resolved_round IS NOT DISTINCT FROM v_round
        )
    FROM (SELECT 1) q
    LEFT JOIN public.discord_character_death_saves ds
      ON ds.character_id=v_character.character_id;
END;
$$;


DROP FUNCTION IF EXISTS public.discord_resolve_death_save(UUID,UUID,INTEGER);

CREATE OR REPLACE FUNCTION public.discord_resolve_death_save(
    p_player_id UUID,
    p_campaign_id UUID,
    p_roll INTEGER
)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    roll INTEGER,
    outcome TEXT,
    successes INTEGER,
    failures INTEGER,
    stable BOOLEAN,
    current_hp INTEGER,
    max_hp INTEGER,
    dead BOOLEAN,
    combat_active BOOLEAN,
    is_current_turn BOOLEAN,
    message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_state public.discord_character_death_saves%ROWTYPE;
    v_round INTEGER := NULL;
    v_combat_active BOOLEAN := FALSE;
    v_current_turn BOOLEAN := FALSE;
    v_successes INTEGER := 0;
    v_failures INTEGER := 0;
    v_stable BOOLEAN := FALSE;
    v_outcome TEXT := '';
    v_message TEXT := '';
    v_mark JSONB := NULL;
BEGIN
    IF p_roll IS NULL OR p_roll<1 OR p_roll>20 THEN
        RAISE EXCEPTION 'Death saving throw must be a natural d20 result from 1 through 20.';
    END IF;

    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND c.player_id=p_player_id
    LIMIT 1
    FOR UPDATE;

    IF v_character.character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    IF v_character.life_state<>'alive' THEN
        RAISE EXCEPTION '% is already dead.',v_character.character_name;
    END IF;

    IF COALESCE(v_character.current_hp,0)<>0 THEN
        RAISE EXCEPTION '% is not at 0 HP and does not need a death saving throw.',
            v_character.character_name;
    END IF;

    SELECT
        COALESCE(s.active,FALSE),
        CASE
            WHEN COALESCE(s.active,FALSE)
             AND s.current_turn_type='character'
             AND s.current_turn_character_id=v_character.character_id
            THEN TRUE ELSE FALSE
        END,
        CASE WHEN COALESCE(s.active,FALSE)
             THEN GREATEST(1,COALESCE(s.round_number,1))
             ELSE NULL
        END
    INTO v_combat_active,v_current_turn,v_round
    FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id;

    v_combat_active:=COALESCE(v_combat_active,FALSE);
    v_current_turn:=COALESCE(v_current_turn,FALSE);

    IF v_combat_active AND NOT v_current_turn THEN
        RAISE EXCEPTION 'It is not %''s initiative turn.',v_character.character_name;
    END IF;

    INSERT INTO public.discord_character_death_saves(
        character_id,campaign_id
    )
    VALUES(v_character.character_id,p_campaign_id)
    ON CONFLICT (character_id) DO NOTHING;

    SELECT * INTO v_state
    FROM public.discord_character_death_saves ds
    WHERE ds.character_id=v_character.character_id
    FOR UPDATE;

    IF COALESCE(v_state.stable,FALSE) THEN
        RAISE EXCEPTION '% is already stable and does not make death saving throws.',
            v_character.character_name;
    END IF;

    IF v_combat_active
       AND v_state.last_resolved_round IS NOT DISTINCT FROM v_round THEN
        RETURN QUERY
        SELECT
            v_character.character_id,
            v_character.character_name,
            COALESCE(v_state.last_roll,p_roll),
            'already_resolved'::TEXT,
            COALESCE(v_state.successes,0),
            COALESCE(v_state.failures,0),
            COALESCE(v_state.stable,FALSE),
            COALESCE(v_character.current_hp,0),
            GREATEST(1,COALESCE(v_character.max_hp,1)),
            FALSE,
            v_combat_active,
            v_current_turn,
            'This death saving throw was already resolved for the current round.'::TEXT;
        RETURN;
    END IF;

    v_successes:=COALESCE(v_state.successes,0);
    v_failures:=COALESCE(v_state.failures,0);

    IF p_roll=20 THEN
        -- Natural 20: regain 1 HP. The HP trigger clears the 0 HP Unconscious source,
        -- and the death-save trigger resets counters.
        UPDATE public.discord_characters c
        SET current_hp=1,
            character_data=COALESCE(c.character_data,'{}'::jsonb)
                || jsonb_build_object('current_hp',1),
            updated_at=NOW()
        WHERE c.character_id=v_character.character_id;

        UPDATE public.discord_character_death_saves ds
        SET successes=0,
            failures=0,
            stable=FALSE,
            last_roll=20,
            last_result='natural_20',
            last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
            updated_at=NOW()
        WHERE ds.character_id=v_character.character_id;

        v_successes:=0;
        v_failures:=0;
        v_stable:=FALSE;
        v_outcome:='natural_20';
        v_message:=v_character.character_name ||
            ' rolled a natural 20 and regained 1 HP.';
    ELSIF p_roll>=10 THEN
        v_successes:=LEAST(3,v_successes+1);

        IF v_successes>=3 THEN
            -- Becoming stable resets both counters by rule.
            v_successes:=0;
            v_failures:=0;
            v_stable:=TRUE;
            v_outcome:='stabilized';
            v_message:=v_character.character_name ||
                ' reached three successful death saving throws and is stable.';
        ELSE
            v_stable:=FALSE;
            v_outcome:='success';
            v_message:=v_character.character_name ||
                ' succeeded on a death saving throw.';
        END IF;

        UPDATE public.discord_character_death_saves ds
        SET successes=v_successes,
            failures=v_failures,
            stable=v_stable,
            last_roll=p_roll,
            last_result=v_outcome,
            last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
            updated_at=NOW()
        WHERE ds.character_id=v_character.character_id;
    ELSE
        IF p_roll=1 THEN
            v_failures:=LEAST(3,v_failures+2);
            v_outcome:='natural_1_failure';
        ELSE
            v_failures:=LEAST(3,v_failures+1);
            v_outcome:='failure';
        END IF;

        IF v_failures>=3 THEN
            v_failures:=3;
            v_outcome:='dead';
            v_message:=v_character.character_name ||
                ' reached three failed death saving throws and died.';

            UPDATE public.discord_character_death_saves ds
            SET successes=v_successes,
                failures=3,
                stable=FALSE,
                last_roll=p_roll,
                last_result='dead',
                last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
                updated_at=NOW()
            WHERE ds.character_id=v_character.character_id;

            v_mark:=public.discord_gm_mark_character_dead(
                p_campaign_id,
                v_character.character_name,
                'Failed three death saving throws.'
            );
        ELSE
            v_stable:=FALSE;
            v_message:=CASE WHEN p_roll=1
                THEN v_character.character_name ||
                    ' rolled a natural 1 and suffered two death saving throw failures.'
                ELSE v_character.character_name ||
                    ' failed a death saving throw.'
                END;

            UPDATE public.discord_character_death_saves ds
            SET successes=v_successes,
                failures=v_failures,
                stable=FALSE,
                last_roll=p_roll,
                last_result=v_outcome,
                last_resolved_round=CASE WHEN v_combat_active THEN v_round ELSE NULL END,
                updated_at=NOW()
            WHERE ds.character_id=v_character.character_id;
        END IF;
    END IF;

    RETURN QUERY
    SELECT
        v_character.character_id,
        v_character.character_name,
        p_roll,
        v_outcome,
        v_successes,
        v_failures,
        v_stable,
        CASE WHEN v_outcome='natural_20' THEN 1 ELSE 0 END,
        GREATEST(1,COALESCE(v_character.max_hp,1)),
        (v_outcome='dead'),
        v_combat_active,
        v_current_turn,
        v_message;
END;
$$;


-- --------------------------------------------------------------------
-- Damage / healing wrapper for Build 6.19.1
-- Keeps Build 6.18.4 effective-max-HP behavior by delegating normal HP
-- persistence to discord_gm_adjust_character_hp.
-- --------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.discord_gm_adjust_character_hp_with_death_saves(
    UUID,TEXT,INTEGER,BOOLEAN,TEXT
);

CREATE OR REPLACE FUNCTION public.discord_gm_adjust_character_hp_with_death_saves(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_hp_delta INTEGER,
    p_critical_hit BOOLEAN DEFAULT FALSE,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_state public.discord_character_death_saves%ROWTYPE;
    v_hp JSONB;
    v_death JSONB := NULL;
    v_before_hp INTEGER;
    v_damage INTEGER;
    v_remaining INTEGER;
    v_effective_max INTEGER;
    v_failures_added INTEGER := 0;
    v_failures_after INTEGER := 0;
    v_instant_death BOOLEAN := FALSE;
    v_dead BOOLEAN := FALSE;
BEGIN
    SELECT c.* INTO v_character
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    LIMIT 1
    FOR UPDATE;

    IF v_character.character_id IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    IF v_character.life_state='dead' THEN
        IF COALESCE(p_hp_delta,0)>0 THEN
            RAISE EXCEPTION '% is dead. Normal healing cannot revive them; use a valid revival effect or the respawn system.',
                v_character.character_name;
        END IF;

        RETURN jsonb_build_object(
            'character_id',v_character.character_id,
            'character_name',v_character.character_name,
            'current_hp',0,
            'max_hp',GREATEST(1,COALESCE(v_character.max_hp,1)),
            'effective_max_hp',COALESCE(
                public.discord_exhaustion_effective_max_hp(v_character.character_id),
                GREATEST(1,COALESCE(v_character.max_hp,1))
            ),
            'hp_delta',COALESCE(p_hp_delta,0),
            'life_state','dead',
            'reason',LEFT(TRIM(COALESCE(p_reason,'')),160),
            'dead',TRUE,
            'death_save_failures_applied',0,
            'instant_death',FALSE
        );
    END IF;

    v_before_hp:=GREATEST(0,COALESCE(v_character.current_hp,0));
    v_damage:=CASE WHEN COALESCE(p_hp_delta,0)<0
                   THEN ABS(p_hp_delta) ELSE 0 END;
    v_effective_max:=COALESCE(
        public.discord_exhaustion_effective_max_hp(v_character.character_id),
        GREATEST(1,COALESCE(v_character.max_hp,1))
    );

    -- Massive damage is checked using damage remaining after reaching 0.
    IF v_damage>0 AND v_before_hp>0 THEN
        v_remaining:=GREATEST(0,v_damage-v_before_hp);
        IF v_remaining>=v_effective_max THEN
            v_instant_death:=TRUE;
        END IF;
    ELSIF v_damage>0 AND v_before_hp=0 AND v_damage>=v_effective_max THEN
        v_instant_death:=TRUE;
    END IF;

    -- Keep existing authoritative HP clamping / character_data mirroring.
    v_hp:=public.discord_gm_adjust_character_hp(
        p_campaign_id,
        v_character.character_name,
        COALESCE(p_hp_delta,0),
        p_reason
    );

    IF v_instant_death THEN
        v_death:=public.discord_gm_mark_character_dead(
            p_campaign_id,
            v_character.character_name,
            COALESCE(NULLIF(TRIM(p_reason),''),'Massive damage at 0 HP')
        );
        v_dead:=TRUE;

        RETURN v_hp || jsonb_build_object(
            'life_state','dead',
            'current_hp',0,
            'dead',TRUE,
            'death_save_failures_applied',0,
            'death_save_failures',3,
            'stable',FALSE,
            'instant_death',TRUE,
            'death',v_death
        );
    END IF;

    -- Damage taken while ALREADY at 0 HP causes failed death saves.
    -- A critical hit causes two failures.
    IF v_damage>0 AND v_before_hp=0 THEN
        INSERT INTO public.discord_character_death_saves(
            character_id,campaign_id
        )
        VALUES(v_character.character_id,p_campaign_id)
        ON CONFLICT (character_id) DO NOTHING;

        SELECT * INTO v_state
        FROM public.discord_character_death_saves ds
        WHERE ds.character_id=v_character.character_id
        FOR UPDATE;

        v_failures_added:=CASE WHEN COALESCE(p_critical_hit,FALSE) THEN 2 ELSE 1 END;
        v_failures_after:=LEAST(3,COALESCE(v_state.failures,0)+v_failures_added);

        UPDATE public.discord_character_death_saves ds
        SET failures=v_failures_after,
            stable=FALSE,
            last_result=CASE
                WHEN COALESCE(p_critical_hit,FALSE)
                    THEN 'damage_at_zero_critical'
                ELSE 'damage_at_zero'
            END,
            updated_at=NOW()
        WHERE ds.character_id=v_character.character_id;

        IF v_failures_after>=3 THEN
            v_death:=public.discord_gm_mark_character_dead(
                p_campaign_id,
                v_character.character_name,
                CASE WHEN COALESCE(p_critical_hit,FALSE)
                    THEN COALESCE(NULLIF(TRIM(p_reason),''),'Critical damage while at 0 HP')
                    ELSE COALESCE(NULLIF(TRIM(p_reason),''),'Damage while at 0 HP')
                END
            );
            v_dead:=TRUE;
        END IF;
    END IF;

    RETURN v_hp || jsonb_build_object(
        'life_state',CASE WHEN v_dead THEN 'dead' ELSE 'alive' END,
        'current_hp',CASE WHEN v_dead THEN 0
                          ELSE COALESCE((v_hp->>'current_hp')::INTEGER,0) END,
        'dead',v_dead,
        'death_save_failures_applied',v_failures_added,
        'death_save_failures',v_failures_after,
        'stable',CASE
            WHEN v_damage>0 AND v_before_hp=0 THEN FALSE
            ELSE NULL
        END,
        'instant_death',FALSE,
        'death',v_death
    );
END;
$$;


-- Server-only access.
REVOKE ALL ON FUNCTION public.discord_sync_character_death_save_state()
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.discord_get_death_save_state(UUID,UUID)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.discord_resolve_death_save(UUID,UUID,INTEGER)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.discord_gm_adjust_character_hp_with_death_saves(
    UUID,TEXT,INTEGER,BOOLEAN,TEXT
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_death_save_state(UUID,UUID)
TO service_role;

GRANT EXECUTE ON FUNCTION public.discord_resolve_death_save(UUID,UUID,INTEGER)
TO service_role;

GRANT EXECUTE ON FUNCTION public.discord_gm_adjust_character_hp_with_death_saves(
    UUID,TEXT,INTEGER,BOOLEAN,TEXT
)
TO service_role;


-- Validation.
DO $$
BEGIN
    IF to_regclass('public.discord_character_death_saves') IS NULL THEN
        RAISE EXCEPTION
            'Build 6.19.1 validation failed: discord_character_death_saves table is missing.';
    END IF;

    IF to_regprocedure(
        'public.discord_get_death_save_state(uuid,uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Build 6.19.1 validation failed: death-save getter is missing.';
    END IF;

    IF to_regprocedure(
        'public.discord_resolve_death_save(uuid,uuid,integer)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Build 6.19.1 validation failed: death-save resolver is missing.';
    END IF;

    IF to_regprocedure(
        'public.discord_gm_adjust_character_hp_with_death_saves(uuid,text,integer,boolean,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Build 6.19.1 validation failed: death-save-aware HP RPC is missing.';
    END IF;

    IF to_regprocedure(
        'public.discord_gm_mark_character_dead(uuid,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Build 6.19.1 validation failed: Build 6.2 death function is missing.';
    END IF;

    IF to_regprocedure(
        'public.discord_exhaustion_effective_max_hp(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Build 6.19.1 validation failed: Build 6.18.4 effective max HP function is missing.';
    END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
