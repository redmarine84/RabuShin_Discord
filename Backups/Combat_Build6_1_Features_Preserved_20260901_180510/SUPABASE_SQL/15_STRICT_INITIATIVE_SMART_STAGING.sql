-- RabuShinAIGM Combat Build 6.1
-- Strict server-authoritative initiative, player End Turn, smart tactical staging support,
-- and GM-authoritative player HP changes during enemy turns.
-- Assumes the Build 5 Tactical Combat, Build 5.1 Terrain/LOS, and Build 6 Live Chat / GM Turn Lock database changes have already been applied.
-- The earlier local migration files themselves do not need to remain in the project folder.

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_campaign_combat_initiative (
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    order_position INTEGER NOT NULL CHECK (order_position > 0),
    entity_type TEXT NOT NULL CHECK (entity_type IN ('character','monster')),
    character_id UUID NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    combat_monster_id UUID NULL REFERENCES public.discord_campaign_combat_monsters(combat_monster_id) ON DELETE CASCADE,
    display_name TEXT NOT NULL,
    initiative_roll INTEGER NOT NULL CHECK (initiative_roll BETWEEN 1 AND 20),
    initiative_modifier INTEGER NOT NULL DEFAULT 0,
    initiative_total INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campaign_id, order_position),
    CONSTRAINT ck_discord_combat_initiative_entity CHECK (
        (entity_type='character' AND character_id IS NOT NULL AND combat_monster_id IS NULL)
        OR
        (entity_type='monster' AND combat_monster_id IS NOT NULL AND character_id IS NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_combat_initiative_character
ON public.discord_campaign_combat_initiative(campaign_id, character_id)
WHERE character_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_combat_initiative_monster
ON public.discord_campaign_combat_initiative(campaign_id, combat_monster_id)
WHERE combat_monster_id IS NOT NULL;

ALTER TABLE public.discord_campaign_combat_initiative ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_campaign_combat_initiative FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_campaign_combat_initiative TO service_role;

-- Compact trusted party combat stats so enemy turns can target any party member accurately.
DROP FUNCTION IF EXISTS public.discord_gm_get_party_combatants(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_party_combatants(p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    class_name TEXT,
    level INTEGER,
    current_hp INTEGER,
    max_hp INTEGER,
    armor_class INTEGER,
    strength INTEGER,
    dexterity INTEGER,
    constitution INTEGER,
    intelligence INTEGER,
    wisdom INTEGER,
    charisma INTEGER,
    proficiency_bonus INTEGER,
    speed INTEGER
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.character_id,c.character_name,c.class_name,c.level,c.current_hp,c.max_hp,c.armor_class,
           c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma,c.proficiency_bonus,c.speed
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
    ORDER BY lower(c.character_name),c.character_id;
$$;

-- Candidates used by the trusted GM server when it rolls initiative.
DROP FUNCTION IF EXISTS public.discord_gm_get_initiative_candidates(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_initiative_candidates(p_campaign_id UUID)
RETURNS TABLE(
    entity_type TEXT,
    character_id UUID,
    combat_monster_id UUID,
    display_name TEXT,
    monster_name TEXT,
    initiative_modifier INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id AND s.active=TRUE
    ) THEN
        RAISE EXCEPTION 'No active combat exists for this campaign.';
    END IF;

    RETURN QUERY
    SELECT 'character'::TEXT, c.character_id, NULL::UUID, c.character_name, ''::TEXT,
           COALESCE(c.initiative, FLOOR((COALESCE(c.dexterity,10)-10)/2.0)::INTEGER)
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
    UNION ALL
    SELECT 'monster'::TEXT, NULL::UUID, m.combat_monster_id, m.display_name, m.monster_name, 0
    FROM public.discord_campaign_combat_monsters m
    WHERE m.campaign_id=p_campaign_id AND COALESCE(m.defeated,FALSE)=FALSE
    ORDER BY 1,4;
END;
$$;

-- Persist the full rolled initiative list in deterministic order, then start the first turn.
DROP FUNCTION IF EXISTS public.discord_gm_set_combat_initiative(UUID, JSONB);
CREATE OR REPLACE FUNCTION public.discord_gm_set_combat_initiative(
    p_campaign_id UUID,
    p_entries JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_expected INTEGER := 0;
    v_received INTEGER := 0;
    v_invalid INTEGER := 0;
    v_first public.discord_campaign_combat_initiative%ROWTYPE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id AND s.active=TRUE
    ) THEN
        RAISE EXCEPTION 'No active combat exists for this campaign.';
    END IF;

    IF p_entries IS NULL OR jsonb_typeof(p_entries)<>'array' OR jsonb_array_length(p_entries)=0 THEN
        RAISE EXCEPTION 'Initiative entries are required.';
    END IF;

    SELECT
        (SELECT COUNT(*) FROM public.discord_characters c WHERE c.campaign_id=p_campaign_id)
        +
        (SELECT COUNT(*) FROM public.discord_campaign_combat_monsters m WHERE m.campaign_id=p_campaign_id AND COALESCE(m.defeated,FALSE)=FALSE)
    INTO v_expected;

    SELECT COUNT(*) INTO v_received FROM jsonb_array_elements(p_entries);
    IF v_received<>v_expected THEN
        RAISE EXCEPTION 'Initiative must include every active combatant. Expected %, received %.',v_expected,v_received;
    END IF;

    WITH parsed AS (
        SELECT *
        FROM jsonb_to_recordset(p_entries) AS x(
            entity_type TEXT,
            character_id UUID,
            combat_monster_id UUID,
            initiative_roll INTEGER,
            initiative_modifier INTEGER,
            initiative_total INTEGER
        )
    )
    SELECT COUNT(*) INTO v_invalid
    FROM parsed p
    WHERE p.entity_type NOT IN ('character','monster')
       OR p.initiative_roll NOT BETWEEN 1 AND 20
       OR p.initiative_total<>p.initiative_roll+COALESCE(p.initiative_modifier,0)
       OR (p.entity_type='character' AND NOT EXISTS (
            SELECT 1 FROM public.discord_characters c
            WHERE c.campaign_id=p_campaign_id AND c.character_id=p.character_id
       ))
       OR (p.entity_type='monster' AND NOT EXISTS (
            SELECT 1 FROM public.discord_campaign_combat_monsters m
            WHERE m.campaign_id=p_campaign_id AND m.combat_monster_id=p.combat_monster_id AND COALESCE(m.defeated,FALSE)=FALSE
       ));

    IF v_invalid>0 THEN
        RAISE EXCEPTION 'One or more initiative entries are invalid or do not belong to this combat.';
    END IF;

    DELETE FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=p_campaign_id;

    WITH parsed AS (
        SELECT *
        FROM jsonb_to_recordset(p_entries) AS x(
            entity_type TEXT,
            character_id UUID,
            combat_monster_id UUID,
            initiative_roll INTEGER,
            initiative_modifier INTEGER,
            initiative_total INTEGER
        )
    ), named AS (
        SELECT p.entity_type,p.character_id,p.combat_monster_id,
               CASE WHEN p.entity_type='character' THEN c.character_name ELSE m.display_name END AS display_name,
               p.initiative_roll,COALESCE(p.initiative_modifier,0) AS initiative_modifier,p.initiative_total
        FROM parsed p
        LEFT JOIN public.discord_characters c
          ON p.entity_type='character' AND c.campaign_id=p_campaign_id AND c.character_id=p.character_id
        LEFT JOIN public.discord_campaign_combat_monsters m
          ON p.entity_type='monster' AND m.campaign_id=p_campaign_id AND m.combat_monster_id=p.combat_monster_id
    ), ranked AS (
        SELECT *, ROW_NUMBER() OVER (
            ORDER BY initiative_total DESC, initiative_modifier DESC, lower(display_name),
                     COALESCE(character_id,combat_monster_id)
        )::INTEGER AS position
        FROM named
    )
    INSERT INTO public.discord_campaign_combat_initiative(
        campaign_id,order_position,entity_type,character_id,combat_monster_id,display_name,
        initiative_roll,initiative_modifier,initiative_total
    )
    SELECT p_campaign_id,position,entity_type,character_id,combat_monster_id,display_name,
           initiative_roll,initiative_modifier,initiative_total
    FROM ranked
    ORDER BY position;

    SELECT * INTO v_first
    FROM public.discord_campaign_combat_initiative i
    WHERE i.campaign_id=p_campaign_id
    ORDER BY i.order_position
    LIMIT 1;

    IF v_first.order_position IS NULL THEN RAISE EXCEPTION 'Unable to establish the first initiative turn.'; END IF;

    PERFORM public.discord_sync_tactical_tokens(p_campaign_id);

    UPDATE public.discord_campaign_combat_state s
    SET round_number=1,
        current_turn_type=v_first.entity_type,
        current_turn_character_id=v_first.character_id,
        current_turn_monster_id=v_first.combat_monster_id,
        turn_started_at=NOW(),updated_at=NOW()
    WHERE s.campaign_id=p_campaign_id;

    UPDATE public.discord_campaign_combat_tokens t
    SET movement_spent_ft=0,updated_at=NOW()
    WHERE t.campaign_id=p_campaign_id
      AND ((v_first.entity_type='character' AND t.character_id=v_first.character_id)
        OR (v_first.entity_type='monster' AND t.combat_monster_id=v_first.combat_monster_id));

    -- Combat initiative supersedes any pre-combat typing lease.
    DELETE FROM public.discord_campaign_gm_turn_lock l WHERE l.campaign_id=p_campaign_id;

    RETURN jsonb_build_object(
        'round_number',1,
        'current_turn_type',v_first.entity_type,
        'current_turn_character_id',v_first.character_id,
        'current_turn_monster_id',v_first.combat_monster_id,
        'current_turn_name',v_first.display_name,
        'initiative',(
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'order_position',i.order_position,
                'entity_type',i.entity_type,
                'character_id',i.character_id,
                'combat_monster_id',i.combat_monster_id,
                'display_name',i.display_name,
                'initiative_roll',i.initiative_roll,
                'initiative_modifier',i.initiative_modifier,
                'initiative_total',i.initiative_total
            ) ORDER BY i.order_position),'[]'::JSONB)
            FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=p_campaign_id
        )
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_combat_initiative(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_get_combat_initiative(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS TABLE(
    order_position INTEGER,
    entity_type TEXT,
    character_id UUID,
    combat_monster_id UUID,
    display_name TEXT,
    initiative_roll INTEGER,
    initiative_modifier INTEGER,
    initiative_total INTEGER,
    is_current BOOLEAN,
    defeated BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;

    RETURN QUERY
    SELECT i.order_position,i.entity_type,i.character_id,i.combat_monster_id,i.display_name,
           i.initiative_roll,i.initiative_modifier,i.initiative_total,
           CASE WHEN i.entity_type='character'
                  THEN s.current_turn_type='character' AND s.current_turn_character_id=i.character_id
                ELSE s.current_turn_type='monster' AND s.current_turn_monster_id=i.combat_monster_id END,
           CASE WHEN i.entity_type='monster' THEN COALESCE(m.defeated,FALSE) ELSE FALSE END
    FROM public.discord_campaign_combat_initiative i
    INNER JOIN public.discord_campaign_combat_state s ON s.campaign_id=i.campaign_id
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
    WHERE i.campaign_id=p_campaign_id
    ORDER BY i.order_position;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_combat_initiative(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_combat_initiative(p_campaign_id UUID)
RETURNS TABLE(
    order_position INTEGER,
    entity_type TEXT,
    character_id UUID,
    combat_monster_id UUID,
    display_name TEXT,
    initiative_roll INTEGER,
    initiative_modifier INTEGER,
    initiative_total INTEGER,
    is_current BOOLEAN,
    defeated BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT i.order_position,i.entity_type,i.character_id,i.combat_monster_id,i.display_name,
           i.initiative_roll,i.initiative_modifier,i.initiative_total,
           CASE WHEN i.entity_type='character'
                  THEN s.current_turn_type='character' AND s.current_turn_character_id=i.character_id
                ELSE s.current_turn_type='monster' AND s.current_turn_monster_id=i.combat_monster_id END,
           CASE WHEN i.entity_type='monster' THEN COALESCE(m.defeated,FALSE) ELSE FALSE END
    FROM public.discord_campaign_combat_initiative i
    INNER JOIN public.discord_campaign_combat_state s ON s.campaign_id=i.campaign_id
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
    WHERE i.campaign_id=p_campaign_id
    ORDER BY i.order_position;
END;
$$;

-- Internal strict advance primitive. Only trusted wrappers call this directly.
DROP FUNCTION IF EXISTS public.discord_advance_combat_turn_internal(UUID, TEXT, BOOLEAN);
CREATE OR REPLACE FUNCTION public.discord_advance_combat_turn_internal(
    p_campaign_id UUID,
    p_reason TEXT,
    p_allow_character BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_state public.discord_campaign_combat_state%ROWTYPE;
    v_current_position INTEGER := 0;
    v_next public.discord_campaign_combat_initiative%ROWTYPE;
    v_wrapped BOOLEAN := FALSE;
    v_round INTEGER := 1;
BEGIN
    SELECT * INTO v_state FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id AND s.active=TRUE FOR UPDATE;
    IF v_state.campaign_id IS NULL THEN RAISE EXCEPTION 'No active combat exists for this campaign.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=p_campaign_id) THEN
        RAISE EXCEPTION 'Strict initiative has not been initialized for this combat.';
    END IF;
    IF v_state.current_turn_type='character' AND NOT COALESCE(p_allow_character,FALSE) THEN
        RAISE EXCEPTION 'A player character turn can only advance through that player''s End Turn action.';
    END IF;

    SELECT i.order_position INTO v_current_position
    FROM public.discord_campaign_combat_initiative i
    WHERE i.campaign_id=p_campaign_id
      AND ((v_state.current_turn_type='character' AND i.entity_type='character' AND i.character_id=v_state.current_turn_character_id)
        OR (v_state.current_turn_type='monster' AND i.entity_type='monster' AND i.combat_monster_id=v_state.current_turn_monster_id))
    LIMIT 1;
    v_current_position:=COALESCE(v_current_position,0);

    SELECT i.* INTO v_next
    FROM public.discord_campaign_combat_initiative i
    LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
    WHERE i.campaign_id=p_campaign_id
      AND i.order_position>v_current_position
      AND (i.entity_type='character' OR COALESCE(m.defeated,FALSE)=FALSE)
    ORDER BY i.order_position LIMIT 1;

    IF v_next.order_position IS NULL THEN
        v_wrapped:=TRUE;
        SELECT i.* INTO v_next
        FROM public.discord_campaign_combat_initiative i
        LEFT JOIN public.discord_campaign_combat_monsters m ON m.combat_monster_id=i.combat_monster_id
        WHERE i.campaign_id=p_campaign_id
          AND (i.entity_type='character' OR COALESCE(m.defeated,FALSE)=FALSE)
        ORDER BY i.order_position LIMIT 1;
    END IF;

    IF v_next.order_position IS NULL THEN RAISE EXCEPTION 'No remaining combatant can take a turn.'; END IF;

    v_round:=GREATEST(1,COALESCE(v_state.round_number,1) + CASE WHEN v_wrapped AND v_current_position>0 THEN 1 ELSE 0 END);

    UPDATE public.discord_campaign_combat_state s
    SET round_number=v_round,
        current_turn_type=v_next.entity_type,
        current_turn_character_id=v_next.character_id,
        current_turn_monster_id=v_next.combat_monster_id,
        turn_started_at=NOW(),updated_at=NOW()
    WHERE s.campaign_id=p_campaign_id;

    UPDATE public.discord_campaign_combat_tokens t
    SET movement_spent_ft=0,updated_at=NOW()
    WHERE t.campaign_id=p_campaign_id
      AND ((v_next.entity_type='character' AND t.character_id=v_next.character_id)
        OR (v_next.entity_type='monster' AND t.combat_monster_id=v_next.combat_monster_id));

    RETURN jsonb_build_object(
        'round_number',v_round,
        'wrapped_round',v_wrapped,
        'current_turn_type',v_next.entity_type,
        'current_turn_character_id',v_next.character_id,
        'current_turn_monster_id',v_next.combat_monster_id,
        'current_turn_name',v_next.display_name,
        'order_position',v_next.order_position,
        'reason',LEFT(TRIM(COALESCE(p_reason,'')),160)
    );
END;
$$;

-- GM/AI advance is legal only after an ENEMY finishes its current turn.
DROP FUNCTION IF EXISTS public.discord_gm_advance_combat_turn(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_advance_combat_turn(
    p_campaign_id UUID,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.discord_advance_combat_turn_internal(p_campaign_id,p_reason,FALSE);
END;
$$;

DROP FUNCTION IF EXISTS public.discord_end_player_combat_turn(UUID, UUID);
CREATE OR REPLACE FUNCTION public.discord_end_player_combat_turn(
    p_player_id UUID,
    p_campaign_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character UUID;
    v_name TEXT;
BEGIN
    SELECT c.character_id,c.character_name INTO v_character,v_name
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_player_id LIMIT 1;
    IF v_character IS NULL THEN RAISE EXCEPTION 'Your campaign character could not be found.'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_combat_state s
        WHERE s.campaign_id=p_campaign_id AND s.active=TRUE
          AND s.current_turn_type='character' AND s.current_turn_character_id=v_character
    ) THEN RAISE EXCEPTION 'It is not your character''s turn.'; END IF;

    RETURN public.discord_advance_combat_turn_internal(p_campaign_id,v_name || ' ended their turn',TRUE);
END;
$$;

-- Override legacy arbitrary turn setting. It remains available before initiative is initialized,
-- but cannot jump past the persisted strict order afterwards.
DROP FUNCTION IF EXISTS public.discord_gm_set_combat_turn(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_set_combat_turn(
    p_campaign_id UUID,
    p_entity_type TEXT,
    p_combatant_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_type TEXT := lower(trim(COALESCE(p_entity_type,'')));
    v_name TEXT := trim(COALESCE(p_combatant_name,''));
    v_state public.discord_campaign_combat_state%ROWTYPE;
    v_character_id UUID := NULL;
    v_monster_id UUID := NULL;
BEGIN
    SELECT * INTO v_state FROM public.discord_campaign_combat_state s
    WHERE s.campaign_id=p_campaign_id AND s.active=TRUE;
    IF v_state.campaign_id IS NULL THEN RAISE EXCEPTION 'No active combat exists for this campaign.'; END IF;
    IF v_type NOT IN ('character','monster') THEN RAISE EXCEPTION 'entityType must be character or monster.'; END IF;
    IF v_name='' THEN RAISE EXCEPTION 'Combatant name is required.'; END IF;

    IF EXISTS (SELECT 1 FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=p_campaign_id) THEN
        IF v_type='character' THEN
            SELECT c.character_id INTO v_character_id FROM public.discord_characters c
            WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(v_name) LIMIT 1;
            IF v_state.current_turn_type<>'character' OR v_state.current_turn_character_id IS DISTINCT FROM v_character_id THEN
                RAISE EXCEPTION 'Strict initiative is active. The GM cannot jump turns; use advance_combat_turn.';
            END IF;
        ELSE
            SELECT m.combat_monster_id INTO v_monster_id FROM public.discord_campaign_combat_monsters m
            WHERE m.campaign_id=p_campaign_id AND lower(m.display_name)=lower(v_name) LIMIT 1;
            IF v_state.current_turn_type<>'monster' OR v_state.current_turn_monster_id IS DISTINCT FROM v_monster_id THEN
                RAISE EXCEPTION 'Strict initiative is active. The GM cannot jump turns; use advance_combat_turn.';
            END IF;
        END IF;
        RETURN jsonb_build_object('entity_type',v_state.current_turn_type,'combatant_name',v_name,
                                  'character_id',v_state.current_turn_character_id,'combat_monster_id',v_state.current_turn_monster_id,
                                  'strict_initiative',TRUE);
    END IF;

    PERFORM public.discord_sync_tactical_tokens(p_campaign_id);
    IF v_type='character' THEN
        SELECT c.character_id INTO v_character_id FROM public.discord_characters c
        WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(v_name) LIMIT 1;
        IF v_character_id IS NULL THEN RAISE EXCEPTION 'Party character not found: %',v_name; END IF;
        UPDATE public.discord_campaign_combat_state SET current_turn_type='character',current_turn_character_id=v_character_id,
            current_turn_monster_id=NULL,turn_started_at=NOW(),updated_at=NOW() WHERE campaign_id=p_campaign_id;
    ELSE
        SELECT m.combat_monster_id INTO v_monster_id FROM public.discord_campaign_combat_monsters m
        WHERE m.campaign_id=p_campaign_id AND lower(m.display_name)=lower(v_name) LIMIT 1;
        IF v_monster_id IS NULL THEN RAISE EXCEPTION 'Combat monster not found: %',v_name; END IF;
        UPDATE public.discord_campaign_combat_state SET current_turn_type='monster',current_turn_character_id=NULL,
            current_turn_monster_id=v_monster_id,turn_started_at=NOW(),updated_at=NOW() WHERE campaign_id=p_campaign_id;
    END IF;

    RETURN jsonb_build_object('entity_type',v_type,'combatant_name',v_name,'character_id',v_character_id,'combat_monster_id',v_monster_id,'strict_initiative',FALSE);
END;
$$;

-- Bulk initial staging. C# validates terrain/LOS; SQL atomically validates campaign token ownership,
-- unique in-grid squares, and resets all movement to zero.
DROP FUNCTION IF EXISTS public.discord_gm_stage_combat_tokens(UUID, JSONB, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_stage_combat_tokens(
    p_campaign_id UUID,
    p_positions JSONB,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_expected INTEGER := 0;
    v_received INTEGER := 0;
    v_distinct INTEGER := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        RAISE EXCEPTION 'No active combat exists for this campaign.';
    END IF;
    PERFORM public.discord_sync_tactical_tokens(p_campaign_id);
    SELECT COUNT(*) INTO v_expected FROM public.discord_campaign_combat_tokens t WHERE t.campaign_id=p_campaign_id;
    IF p_positions IS NULL OR jsonb_typeof(p_positions)<>'array' THEN RAISE EXCEPTION 'Tactical staging positions are required.'; END IF;
    SELECT COUNT(*) INTO v_received FROM jsonb_array_elements(p_positions);
    IF v_received<>v_expected THEN RAISE EXCEPTION 'Initial staging must position every combat token. Expected %, received %.',v_expected,v_received; END IF;

    WITH p AS (
      SELECT * FROM jsonb_to_recordset(p_positions) AS x(token_id UUID,grid_x INTEGER,grid_y INTEGER)
    )
    SELECT COUNT(DISTINCT (grid_x,grid_y)) INTO v_distinct FROM p;
    IF v_distinct<>v_received THEN RAISE EXCEPTION 'Two combatants cannot start in the same tactical square.'; END IF;

    IF EXISTS (
      WITH p AS (SELECT * FROM jsonb_to_recordset(p_positions) AS x(token_id UUID,grid_x INTEGER,grid_y INTEGER))
      SELECT 1 FROM p
      LEFT JOIN public.discord_campaign_combat_tokens t ON t.token_id=p.token_id AND t.campaign_id=p_campaign_id
      WHERE t.token_id IS NULL OR p.grid_x NOT BETWEEN 0 AND 19 OR p.grid_y NOT BETWEEN 0 AND 19
    ) THEN RAISE EXCEPTION 'One or more tactical staging entries are invalid.'; END IF;

    WITH p AS (
      SELECT * FROM jsonb_to_recordset(p_positions) AS x(token_id UUID,grid_x INTEGER,grid_y INTEGER)
    )
    UPDATE public.discord_campaign_combat_tokens t
       SET grid_x=p.grid_x,grid_y=p.grid_y,movement_spent_ft=0,updated_at=NOW()
      FROM p
     WHERE t.campaign_id=p_campaign_id AND t.token_id=p.token_id;

    RETURN jsonb_build_object('positioned',v_received,'reason',LEFT(TRIM(COALESCE(p_reason,'')),160));
END;
$$;

-- Enemy turns must be able to persist damage/healing to player characters.
DROP FUNCTION IF EXISTS public.discord_gm_adjust_character_hp(UUID, TEXT, INTEGER, TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_adjust_character_hp(
    p_campaign_id UUID,
    p_character_name TEXT,
    p_hp_delta INTEGER,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_new_hp INTEGER;
BEGIN
    SELECT c.* INTO v_character FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,''))) LIMIT 1 FOR UPDATE;
    IF v_character.character_id IS NULL THEN RAISE EXCEPTION 'Party character not found: %',p_character_name; END IF;
    v_new_hp:=LEAST(COALESCE(v_character.max_hp,1),GREATEST(0,COALESCE(v_character.current_hp,0)+COALESCE(p_hp_delta,0)));
    UPDATE public.discord_characters c SET current_hp=v_new_hp,updated_at=NOW()
    WHERE c.character_id=v_character.character_id;
    RETURN jsonb_build_object('character_id',v_character.character_id,'character_name',v_character.character_name,
        'current_hp',v_new_hp,'max_hp',v_character.max_hp,'hp_delta',COALESCE(p_hp_delta,0),
        'reason',LEFT(TRIM(COALESCE(p_reason,'')),160));
END;
$$;

-- Clear initiative whenever combat transitions between active/inactive.
CREATE OR REPLACE FUNCTION public.discord_clear_initiative_on_combat_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        DELETE FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=NEW.campaign_id;
    ELSIF NEW.active IS DISTINCT FROM OLD.active OR NEW.started_at IS DISTINCT FROM OLD.started_at THEN
        DELETE FROM public.discord_campaign_combat_initiative i WHERE i.campaign_id=NEW.campaign_id;
    END IF;
    RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_discord_clear_initiative_on_combat_transition ON public.discord_campaign_combat_state;
CREATE TRIGGER trg_discord_clear_initiative_on_combat_transition
AFTER INSERT OR UPDATE OF active, started_at ON public.discord_campaign_combat_state
FOR EACH ROW EXECUTE FUNCTION public.discord_clear_initiative_on_combat_transition();

REVOKE ALL ON FUNCTION public.discord_advance_combat_turn_internal(UUID,TEXT,BOOLEAN) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.discord_gm_get_party_combatants(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_initiative_candidates(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_set_combat_initiative(UUID,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_combat_initiative(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_combat_initiative(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_advance_combat_turn(UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_end_player_combat_turn(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_set_combat_turn(UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_stage_combat_tokens(UUID,JSONB,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_adjust_character_hp(UUID,TEXT,INTEGER,TEXT) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_gm_get_party_combatants(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_initiative_candidates(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_combat_initiative(UUID,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_combat_initiative(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_combat_initiative(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_advance_combat_turn(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_end_player_combat_turn(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_set_combat_turn(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_stage_combat_tokens(UUID,JSONB,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_adjust_character_hp(UUID,TEXT,INTEGER,TEXT) TO service_role;

COMMIT;
