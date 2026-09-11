-- ============================================================
-- RabuShinAIGM Rules Build 6.23
-- Solo Party Formations / Tactical Presets
-- Migration 58
-- Requires Build 6.17 Solo party tables.
-- ============================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_solo_formation_settings
(
    campaign_id UUID PRIMARY KEY REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    owner_player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    preset_key TEXT NOT NULL DEFAULT 'traveling' CHECK(preset_key IN('front_line','defensive','traveling','custom')),
    custom_offsets JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.discord_solo_formation_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_solo_formation_settings FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.discord_solo_formation_settings TO service_role;

CREATE OR REPLACE FUNCTION public.discord_formation_builtin_offset(p_preset TEXT,p_slot_no INTEGER)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_preset TEXT:=LOWER(TRIM(COALESCE(p_preset,'traveling'))); v_slot INTEGER:=GREATEST(1,LEAST(5,COALESCE(p_slot_no,1)));
BEGIN
    IF v_preset='front_line' THEN
        RETURN CASE v_slot
          WHEN 1 THEN '{"offsetX":0,"offsetY":0}'::jsonb
          WHEN 2 THEN '{"offsetX":-1,"offsetY":0}'::jsonb
          WHEN 3 THEN '{"offsetX":1,"offsetY":0}'::jsonb
          WHEN 4 THEN '{"offsetX":-1,"offsetY":1}'::jsonb
          ELSE '{"offsetX":1,"offsetY":1}'::jsonb END;
    ELSIF v_preset='defensive' THEN
        RETURN CASE v_slot
          WHEN 1 THEN '{"offsetX":0,"offsetY":0}'::jsonb
          WHEN 2 THEN '{"offsetX":0,"offsetY":-1}'::jsonb
          WHEN 3 THEN '{"offsetX":-1,"offsetY":0}'::jsonb
          WHEN 4 THEN '{"offsetX":1,"offsetY":0}'::jsonb
          ELSE '{"offsetX":0,"offsetY":1}'::jsonb END;
    ELSE
        RETURN CASE v_slot
          WHEN 1 THEN '{"offsetX":0,"offsetY":0}'::jsonb
          WHEN 2 THEN '{"offsetX":0,"offsetY":1}'::jsonb
          WHEN 3 THEN '{"offsetX":-1,"offsetY":2}'::jsonb
          WHEN 4 THEN '{"offsetX":1,"offsetY":2}'::jsonb
          ELSE '{"offsetX":0,"offsetY":3}'::jsonb END;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_get_solo_formation(p_owner_player_id UUID,p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_is_solo BOOLEAN;
    v_preset TEXT:='traveling';
    v_custom JSONB:='[]'::jsonb;
    v_members JSONB:='[]'::jsonb;
    v_member RECORD;
    v_offset JSONB;
BEGIN
    SELECT EXISTS(SELECT 1 FROM public.discord_campaigns c
      WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_owner_player_id
        AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' AND c.is_active=TRUE) INTO v_is_solo;
    IF NOT v_is_solo THEN RETURN jsonb_build_object('isSolo',FALSE); END IF;
    PERFORM public.discord_solo_ensure_primary(p_owner_player_id,p_campaign_id);
    INSERT INTO public.discord_solo_formation_settings(campaign_id,owner_player_id)
    VALUES(p_campaign_id,p_owner_player_id) ON CONFLICT(campaign_id) DO NOTHING;
    SELECT s.preset_key,s.custom_offsets INTO v_preset,v_custom FROM public.discord_solo_formation_settings s WHERE s.campaign_id=p_campaign_id;

    FOR v_member IN
      SELECT sp.character_id,sp.slot_no,c.character_name
      FROM public.discord_solo_party_characters sp JOIN public.discord_characters c ON c.character_id=sp.character_id
      WHERE sp.campaign_id=p_campaign_id AND sp.owner_player_id=p_owner_player_id ORDER BY sp.slot_no
    LOOP
      IF v_preset='custom' THEN
        SELECT value INTO v_offset FROM jsonb_array_elements(COALESCE(v_custom,'[]'::jsonb)) value
        WHERE LOWER(value->>'characterId')=LOWER(v_member.character_id::TEXT) LIMIT 1;
      ELSE v_offset:=NULL; END IF;
      IF v_offset IS NULL THEN v_offset:=public.discord_formation_builtin_offset(CASE WHEN v_preset='custom' THEN 'traveling' ELSE v_preset END,v_member.slot_no); END IF;
      v_members:=v_members||jsonb_build_array(jsonb_build_object(
        'characterId',v_member.character_id,'characterName',v_member.character_name,'slotNo',v_member.slot_no,
        'offsetX',COALESCE((v_offset->>'offsetX')::INTEGER,0),'offsetY',COALESCE((v_offset->>'offsetY')::INTEGER,0)));
    END LOOP;
    RETURN jsonb_build_object('isSolo',TRUE,'presetKey',v_preset,
      'presetLabel',CASE v_preset WHEN 'front_line' THEN 'Front Line' WHEN 'defensive' THEN 'Defensive' WHEN 'custom' THEN 'Custom' ELSE 'Traveling' END,
      'members',v_members,'updatedAt',(SELECT updated_at FROM public.discord_solo_formation_settings WHERE campaign_id=p_campaign_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_set_solo_formation(
 p_owner_player_id UUID,p_campaign_id UUID,p_preset_key TEXT,p_custom_offsets JSONB DEFAULT '[]'::jsonb)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_preset TEXT:=LOWER(REPLACE(TRIM(COALESCE(p_preset_key,'traveling')),' ','_'));
    v_count INTEGER;
    v_entry JSONB;
    v_character UUID;
    v_x INTEGER;
    v_y INTEGER;
    v_seen TEXT[]:=ARRAY[]::TEXT[];
    v_key TEXT;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaigns c WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_owner_player_id
      AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' AND c.is_active=TRUE) THEN
      RAISE EXCEPTION 'Party formations are available only to the owner of a Solo Play campaign.';
    END IF;
    IF v_preset NOT IN('front_line','defensive','traveling','custom') THEN RAISE EXCEPTION 'Unknown formation preset.'; END IF;
    PERFORM public.discord_solo_ensure_primary(p_owner_player_id,p_campaign_id);

    IF v_preset='custom' THEN
      SELECT COUNT(*)::INTEGER INTO v_count FROM public.discord_solo_party_characters sp
      WHERE sp.campaign_id=p_campaign_id AND sp.owner_player_id=p_owner_player_id;
      IF jsonb_typeof(COALESCE(p_custom_offsets,'[]'::jsonb))<>'array' OR jsonb_array_length(COALESCE(p_custom_offsets,'[]'::jsonb))<>v_count THEN
        RAISE EXCEPTION 'Custom formation must provide one position for every Solo party character.';
      END IF;
      FOR v_entry IN SELECT value FROM jsonb_array_elements(p_custom_offsets) LOOP
        BEGIN v_character:=(v_entry->>'characterId')::UUID; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Custom formation contains an invalid character id.'; END;
        IF NOT EXISTS(SELECT 1 FROM public.discord_solo_party_characters sp WHERE sp.campaign_id=p_campaign_id AND sp.owner_player_id=p_owner_player_id AND sp.character_id=v_character) THEN
          RAISE EXCEPTION 'Custom formation contains a character outside this Solo party.';
        END IF;
        v_x:=COALESCE((v_entry->>'offsetX')::INTEGER,0); v_y:=COALESCE((v_entry->>'offsetY')::INTEGER,0);
        IF v_x NOT BETWEEN -3 AND 3 OR v_y NOT BETWEEN -3 AND 3 THEN RAISE EXCEPTION 'Custom formation offsets must be between -3 and +3 squares.'; END IF;
        v_key:=v_x::TEXT||','||v_y::TEXT;
        IF v_key=ANY(v_seen) THEN RAISE EXCEPTION 'Two party members cannot occupy the same Custom formation square.'; END IF;
        v_seen:=array_append(v_seen,v_key);
      END LOOP;
    ELSE p_custom_offsets:='[]'::jsonb; END IF;

    INSERT INTO public.discord_solo_formation_settings(campaign_id,owner_player_id,preset_key,custom_offsets,updated_at)
    VALUES(p_campaign_id,p_owner_player_id,v_preset,COALESCE(p_custom_offsets,'[]'::jsonb),NOW())
    ON CONFLICT(campaign_id) DO UPDATE SET owner_player_id=EXCLUDED.owner_player_id,preset_key=EXCLUDED.preset_key,
      custom_offsets=EXCLUDED.custom_offsets,updated_at=NOW();
    RETURN public.discord_get_solo_formation(p_owner_player_id,p_campaign_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_gm_get_solo_formation(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_owner UUID;
BEGIN
    SELECT c.owner_player_id INTO v_owner FROM public.discord_campaigns c
    WHERE c.campaign_id=p_campaign_id AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' AND c.is_active=TRUE;
    IF v_owner IS NULL THEN RETURN jsonb_build_object('isSolo',FALSE); END IF;
    RETURN public.discord_get_solo_formation(v_owner,p_campaign_id);
END;
$$;

REVOKE ALL ON FUNCTION public.discord_get_solo_formation(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_set_solo_formation(UUID,UUID,TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_solo_formation(UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_get_solo_formation(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_solo_formation(UUID,UUID,TEXT,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_solo_formation(UUID) TO service_role;

COMMIT;
