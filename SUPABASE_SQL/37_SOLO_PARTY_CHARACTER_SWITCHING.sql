-- ============================================================
-- RabuShinAIGM Rules Build 6.17
-- Solo Party + Character Switching
-- Migration 37
-- Requires Build 6.16 / migration 36.
-- Safe to run more than once.
-- ============================================================

BEGIN;

ALTER TABLE public.discord_campaigns
    ALTER COLUMN campaign_type SET DEFAULT 'friends';

-- Existing campaigns are Friends campaigns unless explicitly created as Solo.
UPDATE public.discord_campaigns
SET campaign_type = 'friends'
WHERE LOWER(TRIM(COALESCE(campaign_type,''))) <> 'solo'
  AND LOWER(TRIM(COALESCE(campaign_type,''))) <> 'friends';

CREATE TABLE IF NOT EXISTS public.discord_solo_party_characters
(
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    owner_player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    character_id UUID NOT NULL UNIQUE REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    control_player_id UUID NOT NULL UNIQUE REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    slot_no INTEGER NOT NULL CHECK (slot_no BETWEEN 1 AND 5),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campaign_id, owner_player_id, slot_no),
    UNIQUE (campaign_id, owner_player_id, character_id)
);

CREATE TABLE IF NOT EXISTS public.discord_solo_active_character
(
    campaign_id UUID PRIMARY KEY REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    owner_player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    control_player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_discord_solo_party_owner
    ON public.discord_solo_party_characters(campaign_id, owner_player_id, slot_no);
CREATE INDEX IF NOT EXISTS idx_discord_solo_party_control
    ON public.discord_solo_party_characters(campaign_id, control_player_id);

ALTER TABLE public.discord_solo_party_characters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_solo_active_character ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.discord_solo_party_characters FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.discord_solo_active_character FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.discord_solo_party_characters TO service_role;
GRANT ALL ON public.discord_solo_active_character TO service_role;

-- Ensure the campaign owner's original character occupies Solo slot 1.
CREATE OR REPLACE FUNCTION public.discord_solo_ensure_primary(
    p_owner_player_id UUID,
    p_campaign_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_character_id UUID;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id
          AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo'
          AND c.is_active=TRUE
    ) THEN
        RETURN;
    END IF;

    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.player_id=p_owner_player_id
    LIMIT 1;

    IF v_character_id IS NULL THEN RETURN; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.discord_solo_party_characters sp
        WHERE sp.campaign_id=p_campaign_id AND sp.character_id=v_character_id
    ) THEN
        INSERT INTO public.discord_solo_party_characters(
            campaign_id,owner_player_id,character_id,control_player_id,slot_no)
        VALUES(p_campaign_id,p_owner_player_id,v_character_id,p_owner_player_id,1)
        ON CONFLICT DO NOTHING;
    END IF;

    INSERT INTO public.discord_solo_active_character(
        campaign_id,owner_player_id,character_id,control_player_id,updated_at)
    VALUES(p_campaign_id,p_owner_player_id,v_character_id,p_owner_player_id,NOW())
    ON CONFLICT (campaign_id) DO NOTHING;
END;
$$;

-- Convert a real Discord owner's player id to the currently selected Solo character's
-- stable control-player id. Friends campaigns and synthetic control ids pass through unchanged.
CREATE OR REPLACE FUNCTION public.discord_resolve_active_player(
    p_player_id UUID,
    p_campaign_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_control UUID;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id
          AND c.owner_player_id=p_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo'
          AND c.is_active=TRUE
    ) THEN
        RETURN p_player_id;
    END IF;

    PERFORM public.discord_solo_ensure_primary(p_player_id,p_campaign_id);

    SELECT a.control_player_id INTO v_control
    FROM public.discord_solo_active_character a
    WHERE a.campaign_id=p_campaign_id AND a.owner_player_id=p_player_id;

    RETURN COALESCE(v_control,p_player_id);
END;
$$;

-- Friends-mode creation remains the original behavior, but now stores an explicit mode.
CREATE OR REPLACE FUNCTION public.discord_create_campaign(
    p_player_id UUID,
    p_campaign_name TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_campaign_id UUID;
    v_username TEXT;
    v_prefix TEXT;
    v_join_code TEXT;
BEGIN
    IF LENGTH(TRIM(COALESCE(p_campaign_name, ''))) = 0 THEN RAISE EXCEPTION 'Campaign name is required.'; END IF;
    SELECT discord_username INTO v_username FROM public.discord_players WHERE player_id = p_player_id;
    IF v_username IS NULL THEN RAISE EXCEPTION 'Discord player could not be found.'; END IF;
    v_prefix := UPPER(REGEXP_REPLACE(LEFT(v_username, 12), '[^a-zA-Z0-9]', '', 'g'));
    IF LENGTH(v_prefix) = 0 THEN v_prefix := 'PLAYER'; END IF;
    v_join_code := v_prefix || '-' || UPPER(LEFT(REPLACE(gen_random_uuid()::TEXT, '-', ''), 8));
    INSERT INTO public.discord_campaigns(owner_player_id,campaign_name,join_code,campaign_type)
    VALUES(p_player_id,TRIM(p_campaign_name),v_join_code,'friends')
    RETURNING campaign_id INTO v_campaign_id;
    INSERT INTO public.discord_campaign_members(campaign_id,player_id,role)
    VALUES(v_campaign_id,p_player_id,'Owner') ON CONFLICT DO NOTHING;
    RETURN v_campaign_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_create_solo_campaign(
    p_player_id UUID,
    p_campaign_name TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_campaign_id UUID;
    v_join_code TEXT;
BEGIN
    IF LENGTH(TRIM(COALESCE(p_campaign_name,'')))=0 THEN RAISE EXCEPTION 'Campaign name is required.'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.discord_players WHERE player_id=p_player_id) THEN
        RAISE EXCEPTION 'Discord player could not be found.';
    END IF;

    -- Internal uniqueness token only. It is never shown as a join code in Solo Play.
    v_join_code := 'SOLO-' || UPPER(LEFT(REPLACE(gen_random_uuid()::TEXT,'-',''),20));
    INSERT INTO public.discord_campaigns(owner_player_id,campaign_name,join_code,campaign_type)
    VALUES(p_player_id,TRIM(p_campaign_name),v_join_code,'solo')
    RETURNING campaign_id INTO v_campaign_id;
    INSERT INTO public.discord_campaign_members(campaign_id,player_id,role)
    VALUES(v_campaign_id,p_player_id,'Owner') ON CONFLICT DO NOTHING;
    RETURN v_campaign_id;
END;
$$;

-- Solo campaigns cannot be joined by code.
CREATE OR REPLACE FUNCTION public.discord_join_campaign(
    p_player_id UUID,
    p_join_code TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_campaign_id UUID;
    v_mode TEXT;
BEGIN
    SELECT campaign_id,LOWER(TRIM(COALESCE(campaign_type,'friends')))
    INTO v_campaign_id,v_mode
    FROM public.discord_campaigns
    WHERE UPPER(join_code)=UPPER(TRIM(COALESCE(p_join_code,''))) AND is_active=TRUE;

    IF v_campaign_id IS NULL THEN RAISE EXCEPTION 'Campaign code was not found.'; END IF;
    IF v_mode='solo' THEN RAISE EXCEPTION 'Solo Play campaigns cannot be joined.'; END IF;

    INSERT INTO public.discord_campaign_members(campaign_id,player_id,role)
    VALUES(v_campaign_id,p_player_id,'Player') ON CONFLICT DO NOTHING;
    RETURN v_campaign_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_my_campaigns(UUID);
CREATE OR REPLACE FUNCTION public.discord_get_my_campaigns(p_player_id UUID)
RETURNS TABLE(
    campaign_id UUID,
    campaign_name TEXT,
    join_code TEXT,
    current_chapter INTEGER,
    current_location TEXT,
    is_owner BOOLEAN,
    member_count BIGINT,
    campaign_mode TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT c.campaign_id,c.campaign_name,c.join_code,c.current_chapter,c.current_location,
           c.owner_player_id=p_player_id AS is_owner,
           COUNT(DISTINCT all_members.player_id) FILTER (
               WHERE COALESCE(all_players.discord_user_id,'') NOT LIKE 'solo:%'
           ) AS member_count,
           CASE WHEN LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' THEN 'solo' ELSE 'friends' END AS campaign_mode
    FROM public.discord_campaigns c
    INNER JOIN public.discord_campaign_members mine
        ON mine.campaign_id=c.campaign_id AND mine.player_id=p_player_id
    LEFT JOIN public.discord_campaign_members all_members ON all_members.campaign_id=c.campaign_id
    LEFT JOIN public.discord_players all_players ON all_players.player_id=all_members.player_id
    WHERE c.is_active=TRUE
    GROUP BY c.campaign_id,c.campaign_name,c.join_code,c.current_chapter,c.current_location,c.owner_player_id,c.campaign_type
    ORDER BY c.campaign_name;
$$;

-- Allocate a stable synthetic control-player identity for one new Solo party member.
CREATE OR REPLACE FUNCTION public.discord_solo_allocate_control_player(
    p_owner_player_id UUID,
    p_campaign_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count INTEGER;
    v_slot INTEGER;
    v_control UUID;
    v_owner public.discord_players%ROWTYPE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' AND c.is_active=TRUE
    ) THEN RAISE EXCEPTION 'Only the owner of a Solo Play campaign can add party members.'; END IF;

    PERFORM public.discord_solo_ensure_primary(p_owner_player_id,p_campaign_id);
    SELECT COUNT(*) INTO v_count FROM public.discord_solo_party_characters
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_owner_player_id;
    IF v_count>=5 THEN RAISE EXCEPTION 'Solo Play supports a maximum of 5 party characters.'; END IF;

    SELECT * INTO v_owner FROM public.discord_players WHERE player_id=p_owner_player_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Discord player could not be found.'; END IF;

    SELECT COALESCE(MAX(slot_no),0)+1 INTO v_slot
    FROM public.discord_solo_party_characters
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_owner_player_id;
    v_slot := GREATEST(2,LEAST(5,v_slot));

    INSERT INTO public.discord_players(discord_user_id,discord_username,display_name,last_seen_at)
    VALUES(
        'solo:'||p_campaign_id::TEXT||':'||v_slot::TEXT||':'||LEFT(REPLACE(gen_random_uuid()::TEXT,'-',''),12),
        v_owner.discord_username,
        COALESCE(v_owner.display_name,v_owner.discord_username),
        NOW())
    RETURNING player_id INTO v_control;

    INSERT INTO public.discord_campaign_members(campaign_id,player_id,role)
    VALUES(p_campaign_id,v_control,'Solo Companion');

    RETURN v_control;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_solo_register_character(
    p_owner_player_id UUID,
    p_campaign_id UUID,
    p_control_player_id UUID,
    p_character_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_slot INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' AND c.is_active=TRUE
    ) THEN RAISE EXCEPTION 'Solo Play campaign could not be found.'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.discord_players p
        JOIN public.discord_campaign_members m ON m.player_id=p.player_id AND m.campaign_id=p_campaign_id
        WHERE p.player_id=p_control_player_id AND p.discord_user_id LIKE 'solo:%'
    ) THEN RAISE EXCEPTION 'Solo party control slot is invalid.'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.discord_characters c
        WHERE c.character_id=p_character_id AND c.campaign_id=p_campaign_id AND c.player_id=p_control_player_id
    ) THEN RAISE EXCEPTION 'Solo party character could not be found.'; END IF;

    IF (SELECT COUNT(*) FROM public.discord_solo_party_characters
        WHERE campaign_id=p_campaign_id AND owner_player_id=p_owner_player_id)>=5 THEN
        RAISE EXCEPTION 'Solo Play supports a maximum of 5 party characters.';
    END IF;

    SELECT COALESCE(MAX(slot_no),1)+1 INTO v_slot
    FROM public.discord_solo_party_characters
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_owner_player_id;
    v_slot := GREATEST(2,LEAST(5,v_slot));

    INSERT INTO public.discord_solo_party_characters(
        campaign_id,owner_player_id,character_id,control_player_id,slot_no)
    VALUES(p_campaign_id,p_owner_player_id,p_character_id,p_control_player_id,v_slot);
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_solo_cleanup_control_player(
    p_owner_player_id UUID,
    p_campaign_id UUID,
    p_control_player_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo'
    ) THEN RETURN; END IF;

    IF EXISTS(SELECT 1 FROM public.discord_solo_party_characters WHERE control_player_id=p_control_player_id) THEN RETURN; END IF;
    IF EXISTS(SELECT 1 FROM public.discord_characters WHERE campaign_id=p_campaign_id AND player_id=p_control_player_id) THEN
        DELETE FROM public.discord_characters WHERE campaign_id=p_campaign_id AND player_id=p_control_player_id;
    END IF;
    DELETE FROM public.discord_campaign_members WHERE campaign_id=p_campaign_id AND player_id=p_control_player_id;
    DELETE FROM public.discord_players WHERE player_id=p_control_player_id AND discord_user_id LIKE 'solo:%';
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_solo_party_state(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_solo_party_state(
    p_owner_player_id UUID,
    p_campaign_id UUID
) RETURNS TABLE(
    is_solo BOOLEAN,
    character_count INTEGER,
    max_characters INTEGER,
    active_character_id UUID,
    active_character_name TEXT,
    can_add BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_is_solo BOOLEAN;
    v_count INTEGER := 0;
    v_active UUID;
    v_name TEXT := '';
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' AND c.is_active=TRUE
    ) INTO v_is_solo;

    IF NOT v_is_solo THEN
        RETURN QUERY SELECT FALSE,0,5,NULL::UUID,''::TEXT,FALSE;
        RETURN;
    END IF;

    PERFORM public.discord_solo_ensure_primary(p_owner_player_id,p_campaign_id);
    SELECT COUNT(*)::INTEGER INTO v_count FROM public.discord_solo_party_characters
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_owner_player_id;
    SELECT a.character_id,c.character_name INTO v_active,v_name
    FROM public.discord_solo_active_character a
    JOIN public.discord_characters c ON c.character_id=a.character_id
    WHERE a.campaign_id=p_campaign_id AND a.owner_player_id=p_owner_player_id;

    RETURN QUERY SELECT TRUE,v_count,5,v_active,COALESCE(v_name,''),v_count<5;
END;
$$;

CREATE OR REPLACE FUNCTION public.discord_set_solo_active_character(
    p_owner_player_id UUID,
    p_campaign_id UUID,
    p_character_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_control UUID;
    v_current_type TEXT;
    v_current_character UUID;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo' AND c.is_active=TRUE
    ) THEN RAISE EXCEPTION 'Only the owner of a Solo Play campaign can switch characters.'; END IF;

    PERFORM public.discord_solo_ensure_primary(p_owner_player_id,p_campaign_id);
    SELECT sp.control_player_id INTO v_control
    FROM public.discord_solo_party_characters sp
    WHERE sp.campaign_id=p_campaign_id AND sp.owner_player_id=p_owner_player_id AND sp.character_id=p_character_id;
    IF v_control IS NULL THEN RAISE EXCEPTION 'That character is not part of your Solo party.'; END IF;

    IF EXISTS(SELECT 1 FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id AND s.active=TRUE) THEN
        SELECT s.current_turn_type,s.current_turn_character_id
        INTO v_current_type,v_current_character
        FROM public.discord_campaign_combat_state s WHERE s.campaign_id=p_campaign_id;
        IF COALESCE(v_current_type,'')<>'character' OR v_current_character IS DISTINCT FROM p_character_id THEN
            RAISE EXCEPTION 'During combat, Active Character follows initiative.';
        END IF;
    END IF;

    INSERT INTO public.discord_solo_active_character(campaign_id,owner_player_id,character_id,control_player_id,updated_at)
    VALUES(p_campaign_id,p_owner_player_id,p_character_id,v_control,NOW())
    ON CONFLICT (campaign_id) DO UPDATE
    SET owner_player_id=EXCLUDED.owner_player_id,
        character_id=EXCLUDED.character_id,
        control_player_id=EXCLUDED.control_player_id,
        updated_at=NOW();

    RETURN v_control;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_party_character_details(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_party_character_details(
    p_player_id UUID,
    p_campaign_id UUID,
    p_character_id UUID
) RETURNS TABLE(
    character_id UUID,
    level INTEGER,
    experience INTEGER,
    alignment TEXT,
    alignment_deed_balance INTEGER,
    alignment_good_deeds INTEGER,
    alignment_evil_deeds INTEGER,
    active_solo_character BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members m
        WHERE m.campaign_id=p_campaign_id AND m.player_id=p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;

    RETURN QUERY
    SELECT c.character_id,c.level,c.experience,c.alignment,
           COALESCE(c.alignment_deed_balance,0),COALESCE(c.alignment_good_deeds,0),COALESCE(c.alignment_evil_deeds,0),
           EXISTS(SELECT 1 FROM public.discord_solo_active_character a
                  WHERE a.campaign_id=p_campaign_id AND a.character_id=c.character_id)
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id AND c.character_id=p_character_id
    LIMIT 1;
END;
$$;

-- Present every Solo character as belonging to the real Discord owner in the public Party UI.
DROP FUNCTION IF EXISTS public.discord_get_party(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_party(p_player_id UUID,p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID,player_id UUID,display_name TEXT,discord_username TEXT,
    character_name TEXT,species_name TEXT,class_name TEXT,background_name TEXT,alignment TEXT,
    level INTEGER,current_hp INTEGER,max_hp INTEGER,armor_class INTEGER,
    strength INTEGER,dexterity INTEGER,constitution INTEGER,intelligence INTEGER,wisdom INTEGER,charisma INTEGER,
    initiative INTEGER,passive_perception INTEGER,proficiency_bonus INTEGER,speed INTEGER,
    portrait_path TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT c.character_id,c.player_id,
           COALESCE(ownerp.display_name,ownerp.discord_username,p.display_name,p.discord_username),
           COALESCE(ownerp.discord_username,p.discord_username),
           c.character_name,c.species_name,c.class_name,c.background_name,c.alignment,
           c.level,c.current_hp,c.max_hp,c.armor_class,
           c.strength,c.dexterity,c.constitution,c.intelligence,c.wisdom,c.charisma,
           c.initiative,c.passive_perception,c.proficiency_bonus,c.speed,c.portrait_path
    FROM public.discord_characters c
    INNER JOIN public.discord_players p ON p.player_id=c.player_id
    INNER JOIN public.discord_campaign_members viewer
        ON viewer.campaign_id=c.campaign_id AND viewer.player_id=p_player_id
    LEFT JOIN public.discord_solo_party_characters sp
        ON sp.campaign_id=c.campaign_id AND sp.character_id=c.character_id
    LEFT JOIN public.discord_players ownerp ON ownerp.player_id=sp.owner_player_id
    WHERE c.campaign_id=p_campaign_id
    ORDER BY COALESCE(sp.slot_no,99),c.character_name;
$$;

-- Remove synthetic control-player rows when a Solo campaign is deleted.
CREATE OR REPLACE FUNCTION public.discord_solo_cleanup_campaign_players()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF LOWER(TRIM(COALESCE(OLD.campaign_type,'')))='solo' THEN
        DELETE FROM public.discord_players p
        WHERE p.player_id IN (
            SELECT sp.control_player_id
            FROM public.discord_solo_party_characters sp
            WHERE sp.campaign_id=OLD.campaign_id AND sp.control_player_id<>OLD.owner_player_id
        )
        AND p.discord_user_id LIKE 'solo:%';
    END IF;
    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_discord_solo_cleanup_campaign_players ON public.discord_campaigns;
CREATE TRIGGER trg_discord_solo_cleanup_campaign_players
BEFORE DELETE ON public.discord_campaigns
FOR EACH ROW EXECUTE FUNCTION public.discord_solo_cleanup_campaign_players();

-- Mirror the real Solo owner's presence to every stable Solo control player. Existing online-only
-- initiative and Build 6.16 all-sleeping logic therefore see the whole Solo party as active.
CREATE OR REPLACE FUNCTION public.discord_touch_campaign_presence(
    p_player_id UUID,
    p_campaign_id UUID
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_seen TIMESTAMPTZ := NOW();
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=p_campaign_id AND cm.player_id=p_player_id
    ) THEN RAISE EXCEPTION 'You are not a member of this campaign.'; END IF;

    INSERT INTO public.discord_campaign_presence(campaign_id,player_id,last_seen_at)
    VALUES(p_campaign_id,p_player_id,v_seen)
    ON CONFLICT (campaign_id,player_id) DO UPDATE SET last_seen_at=EXCLUDED.last_seen_at;

    IF EXISTS(
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id AND c.owner_player_id=p_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo'
    ) THEN
        PERFORM public.discord_solo_ensure_primary(p_player_id,p_campaign_id);
        INSERT INTO public.discord_campaign_presence(campaign_id,player_id,last_seen_at)
        SELECT p_campaign_id,sp.control_player_id,v_seen
        FROM public.discord_solo_party_characters sp
        WHERE sp.campaign_id=p_campaign_id AND sp.owner_player_id=p_player_id
        ON CONFLICT (campaign_id,player_id) DO UPDATE SET last_seen_at=EXCLUDED.last_seen_at;
    END IF;

    RETURN v_seen;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_solo_ensure_primary(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_resolve_active_player(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_create_solo_campaign(UUID,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_solo_allocate_control_player(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_solo_register_character(UUID,UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_solo_cleanup_control_player(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_solo_party_state(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_set_solo_active_character(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_party_character_details(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_solo_ensure_primary(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_resolve_active_player(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_create_solo_campaign(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_solo_allocate_control_player(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_solo_register_character(UUID,UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_solo_cleanup_control_player(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_solo_party_state(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_set_solo_active_character(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_party_character_details(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_my_campaigns(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_create_campaign(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_join_campaign(UUID,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_party(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_touch_campaign_presence(UUID,UUID) TO service_role;

COMMIT;
