-- ============================================================
-- RabuShinAIGM Build 6.30.8
-- Migration 66 - In/Out-of-Combat Spell Casting
--
-- One authoritative cast operation:
--   * validates spellbook/preparation
--   * spends one spell slot for leveled spells
--   * cantrips spend no spell slot
--   * outside combat: no action-economy resource is required
--   * active combat: atomically spends Action/Bonus Action/Reaction
--     based on the spell's stored casting_time
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.discord_gm_cast_spell(UUID,UUID,TEXT,INTEGER,TEXT);

CREATE OR REPLACE FUNCTION public.discord_gm_cast_spell(
    p_campaign_id UUID,
    p_character_id UUID,
    p_spell_name TEXT,
    p_slot_level INTEGER DEFAULT 0,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_character public.discord_characters%ROWTYPE;
    v_spell public.discord_character_spells%ROWTYPE;
    v_base_level INTEGER:=0;
    v_slot_level INTEGER:=0;
    v_max_slots INTEGER:=0;
    v_used_slots INTEGER:=0;
    v_remaining_slots INTEGER:=0;
    v_active_combat BOOLEAN:=FALSE;
    v_casting_time TEXT:='';
    v_resource TEXT:='';
    v_action_state JSONB:='{}'::jsonb;
BEGIN
    IF p_campaign_id IS NULL OR p_character_id IS NULL THEN
        RAISE EXCEPTION 'Campaign and character are required.';
    END IF;

    SELECT c.*
    INTO v_character
    FROM public.discord_characters c
    WHERE c.character_id=p_character_id
      AND c.campaign_id=p_campaign_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'The casting character could not be found in this campaign.';
    END IF;

    SELECT s.*
    INTO v_spell
    FROM public.discord_character_spells s
    WHERE s.character_id=p_character_id
      AND lower(trim(s.spell_name))=lower(trim(COALESCE(p_spell_name,'')))
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION '% does not have % in the current spellbook.',
            v_character.character_name,COALESCE(NULLIF(trim(p_spell_name),''),'that spell');
    END IF;

    v_base_level:=GREATEST(0,COALESCE(v_spell.spell_level,0));

    IF v_base_level>0 AND NOT COALESCE(v_spell.prepared,FALSE) THEN
        RAISE EXCEPTION '% is not currently prepared/available.',v_spell.spell_name;
    END IF;

    v_casting_time:=lower(trim(COALESCE(v_spell.spell_data->>'casting_time','1 Action')));

    SELECT EXISTS(
        SELECT 1
        FROM public.discord_campaign_combat_state cs
        WHERE cs.campaign_id=p_campaign_id
          AND cs.active=TRUE
    )
    INTO v_active_combat;

    -- Validate/lock the slot before touching combat action economy. If the
    -- subsequent combat resource spend fails, PostgreSQL rolls this entire
    -- function call back atomically.
    IF v_base_level=0 THEN
        v_slot_level:=0;
        v_max_slots:=0;
        v_used_slots:=0;
        v_remaining_slots:=0;
    ELSE
        v_slot_level:=CASE
            WHEN COALESCE(p_slot_level,0)<=0 THEN v_base_level
            ELSE p_slot_level
        END;

        IF v_slot_level<v_base_level OR v_slot_level>9 THEN
            RAISE EXCEPTION '% requires a spell slot of level % or higher.',
                v_spell.spell_name,v_base_level;
        END IF;

        SELECT ss.max_slots,ss.used_slots
        INTO v_max_slots,v_used_slots
        FROM public.discord_spell_slots ss
        WHERE ss.character_id=p_character_id
          AND ss.spell_level=v_slot_level
        FOR UPDATE;

        IF NOT FOUND OR COALESCE(v_max_slots,0)<=0 THEN
            RAISE EXCEPTION '% has no level % spell slots.',
                v_character.character_name,v_slot_level;
        END IF;

        IF COALESCE(v_used_slots,0)>=COALESCE(v_max_slots,0) THEN
            RAISE EXCEPTION '% has no level % spell slots remaining.',
                v_character.character_name,v_slot_level;
        END IF;
    END IF;

    IF v_active_combat THEN
        IF v_casting_time LIKE '%bonus action%' THEN
            v_resource:='bonus_action';
        ELSIF v_casting_time LIKE '%reaction%' THEN
            v_resource:='reaction';
        ELSIF v_casting_time LIKE '%action%' OR v_casting_time='' THEN
            v_resource:='action';
        ELSE
            RAISE EXCEPTION '% has a casting time of "%", which cannot be completed as one combat action.',
                v_spell.spell_name,COALESCE(NULLIF(v_spell.spell_data->>'casting_time',''),'unknown');
        END IF;

        v_action_state:=public.discord_action_economy_spend_internal(
            p_campaign_id,
            'character',
            p_character_id,
            v_resource,
            'magic',
            LEFT(trim(COALESCE(p_reason,'Spell cast')),160)
        );
    END IF;

    IF v_base_level>0 THEN
        UPDATE public.discord_spell_slots ss
        SET used_slots=ss.used_slots+1
        WHERE ss.character_id=p_character_id
          AND ss.spell_level=v_slot_level
        RETURNING ss.max_slots,ss.used_slots
        INTO v_max_slots,v_used_slots;

        v_remaining_slots:=GREATEST(0,v_max_slots-v_used_slots);
    END IF;

    RETURN jsonb_build_object(
        'success',TRUE,
        'characterId',p_character_id,
        'characterName',v_character.character_name,
        'spellName',v_spell.spell_name,
        'spellLevel',v_base_level,
        'slotLevel',v_slot_level,
        'slotConsumed',v_base_level>0,
        'maxSlots',v_max_slots,
        'usedSlots',v_used_slots,
        'remainingSlots',v_remaining_slots,
        'activeCombat',v_active_combat,
        'spentActionResource',CASE WHEN v_active_combat THEN v_resource ELSE '' END,
        'castingTime',COALESCE(v_spell.spell_data->>'casting_time',''),
        'actionState',CASE WHEN v_active_combat THEN v_action_state ELSE '{}'::jsonb END,
        'reason',LEFT(trim(COALESCE(p_reason,'')),160)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.discord_gm_cast_spell(UUID,UUID,TEXT,INTEGER,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_gm_cast_spell(UUID,UUID,TEXT,INTEGER,TEXT)
TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
