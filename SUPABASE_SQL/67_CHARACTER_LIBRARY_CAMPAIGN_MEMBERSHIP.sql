-- ============================================================
-- RabuShinAIGM Build 6.30.9
-- Migration 67 - Character Library + Campaign Membership
--
-- Adds:
--   * 10-slot account Character Library
--   * reusable characters that survive campaigns
--   * Friends Leave Campaign character retention
--   * Friends owner Kick Player
--   * pending Store/Delete decisions for campaign-created characters
--   * Solo Remove Character support
--
-- Safe to run more than once.
-- Requires Build 6.30.8 / Migration 66.
-- ============================================================

BEGIN;

ALTER TABLE public.discord_characters
    ADD COLUMN IF NOT EXISTS owner_player_id UUID REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS library_slot INTEGER NULL,
    ADD COLUMN IF NOT EXISTS character_origin TEXT NOT NULL DEFAULT 'campaign',
    ADD COLUMN IF NOT EXISTS character_status TEXT NOT NULL DEFAULT 'assigned',
    ADD COLUMN IF NOT EXISTS pending_reason TEXT NOT NULL DEFAULT '';

ALTER TABLE public.discord_characters
    ALTER COLUMN campaign_id DROP NOT NULL;

-- The original character->campaign FK was ON DELETE CASCADE. A reusable
-- character must survive a campaign delete, so it becomes ON DELETE SET NULL.
ALTER TABLE public.discord_characters
    DROP CONSTRAINT IF EXISTS discord_characters_campaign_id_fkey;
ALTER TABLE public.discord_characters
    ADD CONSTRAINT discord_characters_campaign_id_fkey
    FOREIGN KEY (campaign_id)
    REFERENCES public.discord_campaigns(campaign_id)
    ON DELETE SET NULL;

-- Existing Solo companions are controlled by synthetic player rows. Their real
-- owner is recorded in the Solo party table.
UPDATE public.discord_characters c
SET owner_player_id=sp.owner_player_id
FROM public.discord_solo_party_characters sp
WHERE c.owner_player_id IS NULL
  AND sp.character_id=c.character_id;

UPDATE public.discord_characters
SET owner_player_id=player_id
WHERE owner_player_id IS NULL;

ALTER TABLE public.discord_characters
    ALTER COLUMN owner_player_id SET NOT NULL;

ALTER TABLE public.discord_characters
    DROP CONSTRAINT IF EXISTS ck_discord_character_library_slot;
ALTER TABLE public.discord_characters
    ADD CONSTRAINT ck_discord_character_library_slot
    CHECK (library_slot IS NULL OR library_slot BETWEEN 1 AND 10);

ALTER TABLE public.discord_characters
    DROP CONSTRAINT IF EXISTS ck_discord_character_origin;
ALTER TABLE public.discord_characters
    ADD CONSTRAINT ck_discord_character_origin
    CHECK (character_origin IN ('library','campaign'));

ALTER TABLE public.discord_characters
    DROP CONSTRAINT IF EXISTS ck_discord_character_status;
ALTER TABLE public.discord_characters
    ADD CONSTRAINT ck_discord_character_status
    CHECK (character_status IN ('available','assigned','pending_storage'));

CREATE INDEX IF NOT EXISTS idx_discord_characters_owner
    ON public.discord_characters(owner_player_id);
CREATE INDEX IF NOT EXISTS idx_discord_characters_owner_status
    ON public.discord_characters(owner_player_id,character_status);
CREATE UNIQUE INDEX IF NOT EXISTS uq_discord_character_library_slot
    ON public.discord_characters(owner_player_id,library_slot)
    WHERE library_slot IS NOT NULL;

-- ============================================================
-- INTERNAL DETACH HELPER
-- ============================================================
CREATE OR REPLACE FUNCTION public.discord_detach_character(
    p_character_id UUID,
    p_reason TEXT DEFAULT ''
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_owner UUID;
    v_slot INTEGER;
    v_status TEXT;
BEGIN
    SELECT owner_player_id,library_slot
    INTO v_owner,v_slot
    FROM public.discord_characters
    WHERE character_id=p_character_id
    FOR UPDATE;

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'Character could not be found.';
    END IF;

    v_status:=CASE WHEN v_slot IS NOT NULL THEN 'available' ELSE 'pending_storage' END;

    UPDATE public.discord_characters
    SET campaign_id=NULL,
        player_id=v_owner,
        character_status=v_status,
        pending_reason=CASE WHEN v_status='pending_storage' THEN COALESCE(p_reason,'') ELSE '' END,
        updated_at=NOW()
    WHERE character_id=p_character_id;

    RETURN v_status;
END;
$$;

REVOKE ALL ON FUNCTION public.discord_detach_character(UUID,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.discord_detach_character(UUID,TEXT) TO service_role;

-- ============================================================
-- FUTURE CAMPAIGN CHARACTER CREATION
-- ============================================================
-- Preserve the existing signature used by the server, but stamp the new durable
-- ownership metadata on every campaign-created character.
CREATE OR REPLACE FUNCTION public.discord_create_character(
    p_player_id UUID,
    p_campaign_id UUID,
    p_character_data JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_character_id UUID;
    v_name TEXT;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members
        WHERE campaign_id=p_campaign_id AND player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    IF EXISTS(
        SELECT 1 FROM public.discord_characters
        WHERE campaign_id=p_campaign_id AND player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You already have a character in this campaign.';
    END IF;

    v_name:=TRIM(COALESCE(p_character_data->>'character_name',''));
    IF LENGTH(v_name)=0 THEN
        RAISE EXCEPTION 'Character name is required.';
    END IF;

    INSERT INTO public.discord_characters(
        campaign_id,player_id,owner_player_id,character_name,species_name,class_name,
        background_name,alignment,level,experience,current_hp,max_hp,armor_class,
        strength,dexterity,constitution,intelligence,wisdom,charisma,initiative,
        passive_perception,proficiency_bonus,speed,size_name,gold,character_data,
        character_origin,character_status,pending_reason
    ) VALUES(
        p_campaign_id,p_player_id,p_player_id,v_name,
        COALESCE(p_character_data->>'species_name',''),
        COALESCE(p_character_data->>'class_name',''),
        COALESCE(p_character_data->>'background_name',''),
        COALESCE(p_character_data->>'alignment',''),
        COALESCE(NULLIF(p_character_data->>'level','')::INTEGER,1),
        COALESCE(NULLIF(p_character_data->>'experience','')::INTEGER,0),
        COALESCE(NULLIF(p_character_data->>'current_hp','')::INTEGER,1),
        COALESCE(NULLIF(p_character_data->>'max_hp','')::INTEGER,1),
        COALESCE(NULLIF(p_character_data->>'armor_class','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'strength','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'dexterity','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'constitution','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'intelligence','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'wisdom','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'charisma','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'initiative','')::INTEGER,0),
        COALESCE(NULLIF(p_character_data->>'passive_perception','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'proficiency_bonus','')::INTEGER,2),
        COALESCE(NULLIF(p_character_data->>'speed','')::INTEGER,30),
        COALESCE(p_character_data->>'size_name','Medium'),
        COALESCE(NULLIF(p_character_data->>'gold','')::NUMERIC,0),
        COALESCE(p_character_data,'{}'::JSONB),
        'campaign','assigned',''
    )
    RETURNING character_id INTO v_character_id;

    RETURN v_character_id;
END;
$$;

-- ============================================================
-- CHARACTER LIBRARY
-- ============================================================
DROP FUNCTION IF EXISTS public.discord_get_character_library(UUID);
CREATE OR REPLACE FUNCTION public.discord_get_character_library(p_player_id UUID)
RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    species_name TEXT,
    class_name TEXT,
    background_name TEXT,
    alignment TEXT,
    gender TEXT,
    level INTEGER,
    experience INTEGER,
    current_hp INTEGER,
    max_hp INTEGER,
    armor_class INTEGER,
    library_slot INTEGER,
    character_origin TEXT,
    character_status TEXT,
    pending_reason TEXT,
    campaign_id UUID,
    campaign_name TEXT,
    equipment_complete BOOLEAN,
    spells_complete BOOLEAN,
    portrait_path TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path=public AS $$
    SELECT c.character_id,c.character_name,c.species_name,c.class_name,
           c.background_name,c.alignment,c.gender,c.level,c.experience,
           c.current_hp,c.max_hp,c.armor_class,c.library_slot,
           c.character_origin,c.character_status,c.pending_reason,
           c.campaign_id,cp.campaign_name,c.equipment_complete,c.spells_complete,
           c.portrait_path
    FROM public.discord_characters c
    LEFT JOIN public.discord_campaigns cp ON cp.campaign_id=c.campaign_id
    WHERE c.owner_player_id=p_player_id
      AND (c.library_slot IS NOT NULL OR c.character_status='pending_storage')
    ORDER BY CASE WHEN c.character_status='pending_storage' THEN 0 ELSE 1 END,
             c.library_slot NULLS LAST,
             LOWER(c.character_name);
$$;

DROP FUNCTION IF EXISTS public.discord_create_library_character(UUID,JSONB,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TEXT);
CREATE OR REPLACE FUNCTION public.discord_create_library_character(
    p_player_id UUID,
    p_character_data JSONB,
    p_secondary_heritage TEXT,
    p_appearance TEXT,
    p_personality TEXT,
    p_backstory TEXT,
    p_notes TEXT,
    p_racial_traits JSONB,
    p_gender TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_character_id UUID;
    v_name TEXT;
    v_slot INTEGER;
BEGIN
    -- Serialize slot allocation per real account.
    PERFORM 1 FROM public.discord_players WHERE player_id=p_player_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Discord player could not be found.';
    END IF;

    SELECT gs INTO v_slot
    FROM generate_series(1,10) gs
    WHERE NOT EXISTS(
        SELECT 1 FROM public.discord_characters c
        WHERE c.owner_player_id=p_player_id AND c.library_slot=gs
    )
    ORDER BY gs
    LIMIT 1;

    IF v_slot IS NULL THEN
        RAISE EXCEPTION 'CHARACTER_LIBRARY_FULL: Your Character Library already has 10 characters.';
    END IF;

    v_name:=TRIM(COALESCE(p_character_data->>'character_name',''));
    IF LENGTH(v_name)=0 THEN
        RAISE EXCEPTION 'Character name is required.';
    END IF;

    INSERT INTO public.discord_characters(
        campaign_id,player_id,owner_player_id,character_name,species_name,class_name,
        background_name,alignment,gender,level,experience,current_hp,max_hp,armor_class,
        strength,dexterity,constitution,intelligence,wisdom,charisma,initiative,
        passive_perception,proficiency_bonus,speed,size_name,gold,character_data,
        secondary_heritage,appearance,personality,backstory,notes,racial_traits,
        library_slot,character_origin,character_status,pending_reason
    ) VALUES(
        NULL,p_player_id,p_player_id,v_name,
        COALESCE(p_character_data->>'species_name',''),
        COALESCE(p_character_data->>'class_name',''),
        COALESCE(p_character_data->>'background_name',''),
        COALESCE(p_character_data->>'alignment',''),
        NULLIF(TRIM(COALESCE(p_gender,'')),''),
        COALESCE(NULLIF(p_character_data->>'level','')::INTEGER,1),
        COALESCE(NULLIF(p_character_data->>'experience','')::INTEGER,0),
        COALESCE(NULLIF(p_character_data->>'current_hp','')::INTEGER,1),
        COALESCE(NULLIF(p_character_data->>'max_hp','')::INTEGER,1),
        COALESCE(NULLIF(p_character_data->>'armor_class','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'strength','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'dexterity','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'constitution','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'intelligence','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'wisdom','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'charisma','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'initiative','')::INTEGER,0),
        COALESCE(NULLIF(p_character_data->>'passive_perception','')::INTEGER,10),
        COALESCE(NULLIF(p_character_data->>'proficiency_bonus','')::INTEGER,2),
        COALESCE(NULLIF(p_character_data->>'speed','')::INTEGER,30),
        COALESCE(p_character_data->>'size_name','Medium'),
        COALESCE(NULLIF(p_character_data->>'gold','')::NUMERIC,0),
        COALESCE(p_character_data,'{}'::JSONB),
        COALESCE(TRIM(p_secondary_heritage),''),
        COALESCE(p_appearance,''),COALESCE(p_personality,''),
        COALESCE(p_backstory,''),COALESCE(p_notes,''),
        COALESCE(p_racial_traits,'{}'::JSONB),
        v_slot,'library','available',''
    )
    RETURNING character_id INTO v_character_id;

    RETURN v_character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_assign_library_character(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_assign_library_character(
    p_player_id UUID,
    p_campaign_id UUID,
    p_character_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_mode TEXT;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members
        WHERE campaign_id=p_campaign_id AND player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    SELECT LOWER(TRIM(COALESCE(campaign_type,'friends')))
    INTO v_mode
    FROM public.discord_campaigns
    WHERE campaign_id=p_campaign_id AND is_active=TRUE;

    IF v_mode IS NULL THEN
        RAISE EXCEPTION 'Campaign could not be found.';
    END IF;

    IF EXISTS(
        SELECT 1 FROM public.discord_characters
        WHERE campaign_id=p_campaign_id AND owner_player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You already have a character in this campaign.';
    END IF;

    PERFORM 1
    FROM public.discord_characters
    WHERE character_id=p_character_id
      AND owner_player_id=p_player_id
      AND library_slot IS NOT NULL
      AND campaign_id IS NULL
      AND character_status='available'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'That character is not available.';
    END IF;

    UPDATE public.discord_characters
    SET campaign_id=p_campaign_id,
        player_id=p_player_id,
        character_status='assigned',
        pending_reason='',
        updated_at=NOW()
    WHERE character_id=p_character_id;

    IF v_mode='solo' THEN
        PERFORM public.discord_solo_ensure_primary(p_player_id,p_campaign_id);
    END IF;

    RETURN p_character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_delete_library_character(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_delete_library_character(
    p_player_id UUID,
    p_character_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    DELETE FROM public.discord_characters
    WHERE character_id=p_character_id
      AND owner_player_id=p_player_id
      AND library_slot IS NOT NULL
      AND campaign_id IS NULL
      AND character_status='available';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Only an available Character Library character can be deleted.';
    END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_resolve_pending_character(UUID,UUID,TEXT,UUID);
CREATE OR REPLACE FUNCTION public.discord_resolve_pending_character(
    p_player_id UUID,
    p_character_id UUID,
    p_action TEXT,
    p_replace_character_id UUID DEFAULT NULL
) RETURNS TABLE(
    character_id UUID,
    character_status TEXT,
    library_slot INTEGER,
    was_deleted BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_action TEXT:=LOWER(TRIM(COALESCE(p_action,'')));
    v_slot INTEGER;
BEGIN
    PERFORM 1 FROM public.discord_players WHERE player_id=p_player_id FOR UPDATE;

    PERFORM 1
    FROM public.discord_characters
    WHERE character_id=p_character_id
      AND owner_player_id=p_player_id
      AND campaign_id IS NULL
      AND character_status='pending_storage'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'This character is not waiting for a Store/Delete decision.';
    END IF;

    IF v_action='delete' THEN
        DELETE FROM public.discord_characters WHERE character_id=p_character_id;
        RETURN QUERY SELECT p_character_id,'deleted'::TEXT,NULL::INTEGER,TRUE;
        RETURN;
    END IF;

    IF v_action<>'store' THEN
        RAISE EXCEPTION 'Choose Store Character or Delete Character.';
    END IF;

    SELECT gs INTO v_slot
    FROM generate_series(1,10) gs
    WHERE NOT EXISTS(
        SELECT 1 FROM public.discord_characters c
        WHERE c.owner_player_id=p_player_id AND c.library_slot=gs
    )
    ORDER BY gs
    LIMIT 1;

    IF v_slot IS NULL AND p_replace_character_id IS NOT NULL THEN
        SELECT library_slot INTO v_slot
        FROM public.discord_characters
        WHERE character_id=p_replace_character_id
          AND owner_player_id=p_player_id
          AND library_slot IS NOT NULL
          AND campaign_id IS NULL
          AND character_status='available'
        FOR UPDATE;

        IF v_slot IS NULL THEN
            RAISE EXCEPTION 'The replacement character must be an available Character Library character.';
        END IF;

        DELETE FROM public.discord_characters
        WHERE character_id=p_replace_character_id
          AND owner_player_id=p_player_id
          AND campaign_id IS NULL
          AND character_status='available';
    END IF;

    IF v_slot IS NULL THEN
        RAISE EXCEPTION 'CHARACTER_LIBRARY_FULL: Delete an available stored character or delete the character you are trying to store.';
    END IF;

    UPDATE public.discord_characters
    SET library_slot=v_slot,
        character_status='available',
        pending_reason='',
        updated_at=NOW()
    WHERE character_id=p_character_id;

    RETURN QUERY SELECT p_character_id,'available'::TEXT,v_slot,FALSE;
END;
$$;

-- ============================================================
-- DEPARTURE PREVIEW / MEMBER MANAGEMENT
-- ============================================================
DROP FUNCTION IF EXISTS public.discord_get_character_departure_preview(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_character_departure_preview(
    p_player_id UUID,
    p_campaign_id UUID,
    p_character_id UUID DEFAULT NULL
) RETURNS TABLE(
    character_id UUID,
    character_name TEXT,
    is_library_character BOOLEAN,
    requires_store_delete_choice BOOLEAN,
    library_slot INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members
        WHERE campaign_id=p_campaign_id AND player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    RETURN QUERY
    SELECT c.character_id,c.character_name,(c.library_slot IS NOT NULL),
           (c.library_slot IS NULL),c.library_slot
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND c.owner_player_id=p_player_id
      AND (p_character_id IS NULL OR c.character_id=p_character_id)
    ORDER BY c.character_id
    LIMIT 1;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_get_campaign_members(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_get_campaign_members(
    p_requester_player_id UUID,
    p_campaign_id UUID
) RETURNS TABLE(
    player_id UUID,
    display_name TEXT,
    discord_username TEXT,
    role TEXT,
    is_owner BOOLEAN,
    character_name TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id
          AND c.owner_player_id=p_requester_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'friends')))='friends'
          AND c.is_active=TRUE
    ) THEN
        RAISE EXCEPTION 'Only the owner of a Play with Friends campaign can manage players.';
    END IF;

    RETURN QUERY
    SELECT m.player_id,COALESCE(p.display_name,p.discord_username),p.discord_username,
           m.role,(m.player_id=p_requester_player_id),ch.character_name
    FROM public.discord_campaign_members m
    JOIN public.discord_players p ON p.player_id=m.player_id
    LEFT JOIN public.discord_characters ch
      ON ch.campaign_id=m.campaign_id AND ch.owner_player_id=m.player_id
    WHERE m.campaign_id=p_campaign_id
      AND COALESCE(p.discord_user_id,'') NOT LIKE 'solo:%'
    ORDER BY CASE WHEN m.player_id=p_requester_player_id THEN 0 ELSE 1 END,
             LOWER(COALESCE(p.display_name,p.discord_username));
END;
$$;

-- ============================================================
-- FRIENDS LEAVE / KICK
-- ============================================================
DROP FUNCTION IF EXISTS public.discord_leave_campaign(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_leave_campaign(
    p_player_id UUID,
    p_campaign_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_owner UUID;
    v_mode TEXT;
    v_character UUID;
BEGIN
    SELECT owner_player_id,LOWER(TRIM(COALESCE(campaign_type,'friends')))
    INTO v_owner,v_mode
    FROM public.discord_campaigns
    WHERE campaign_id=p_campaign_id AND is_active=TRUE;

    IF v_owner IS NULL THEN RAISE EXCEPTION 'Campaign could not be found.'; END IF;
    IF v_mode<>'friends' THEN RAISE EXCEPTION 'Solo Play campaigns cannot be left.'; END IF;
    IF v_owner=p_player_id THEN RAISE EXCEPTION 'Campaign owners cannot leave their own campaign. Use Delete Campaign instead.'; END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members
        WHERE campaign_id=p_campaign_id AND player_id=p_player_id
    ) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;

    SELECT character_id INTO v_character
    FROM public.discord_characters
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_player_id
    LIMIT 1;

    IF v_character IS NOT NULL THEN
        PERFORM public.discord_detach_character(v_character,'left_campaign');
    END IF;

    DELETE FROM public.discord_journal_entries
    WHERE campaign_id=p_campaign_id AND player_id=p_player_id;

    DELETE FROM public.discord_campaign_members
    WHERE campaign_id=p_campaign_id AND player_id=p_player_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_kick_campaign_player(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_kick_campaign_player(
    p_owner_player_id UUID,
    p_campaign_id UUID,
    p_target_player_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_owner UUID;
    v_mode TEXT;
    v_character UUID;
BEGIN
    SELECT owner_player_id,LOWER(TRIM(COALESCE(campaign_type,'friends')))
    INTO v_owner,v_mode
    FROM public.discord_campaigns
    WHERE campaign_id=p_campaign_id AND is_active=TRUE;

    IF v_owner IS NULL THEN RAISE EXCEPTION 'Campaign could not be found.'; END IF;
    IF v_owner<>p_owner_player_id THEN RAISE EXCEPTION 'Only the campaign owner can kick players.'; END IF;
    IF v_mode<>'friends' THEN RAISE EXCEPTION 'Kick Player is available only in Play with Friends campaigns.'; END IF;
    IF p_target_player_id=v_owner THEN RAISE EXCEPTION 'The campaign owner cannot be kicked.'; END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaign_members
        WHERE campaign_id=p_campaign_id AND player_id=p_target_player_id
    ) THEN
        RAISE EXCEPTION 'That player is not a member of this campaign.';
    END IF;

    SELECT character_id INTO v_character
    FROM public.discord_characters
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_target_player_id
    LIMIT 1;

    IF v_character IS NOT NULL THEN
        PERFORM public.discord_detach_character(v_character,'kicked_from_campaign');
    END IF;

    DELETE FROM public.discord_journal_entries
    WHERE campaign_id=p_campaign_id AND player_id=p_target_player_id;

    DELETE FROM public.discord_campaign_members
    WHERE campaign_id=p_campaign_id AND player_id=p_target_player_id;
END;
$$;

-- ============================================================
-- CAMPAIGN DELETE - PRESERVE PLAYER CHARACTERS
-- ============================================================
DROP FUNCTION IF EXISTS public.discord_delete_campaign(UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_delete_campaign(
    p_player_id UUID,
    p_campaign_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_owner UUID;
    v_synthetic_players UUID[];
BEGIN
    SELECT owner_player_id INTO v_owner
    FROM public.discord_campaigns
    WHERE campaign_id=p_campaign_id;

    IF v_owner IS NULL THEN RAISE EXCEPTION 'Campaign could not be found.'; END IF;
    IF v_owner<>p_player_id THEN RAISE EXCEPTION 'Only the campaign owner can permanently delete this campaign.'; END IF;

    SELECT ARRAY_AGG(m.player_id)
    INTO v_synthetic_players
    FROM public.discord_campaign_members m
    JOIN public.discord_players p ON p.player_id=m.player_id
    WHERE m.campaign_id=p_campaign_id
      AND p.discord_user_id LIKE 'solo:%';

    UPDATE public.discord_characters
    SET campaign_id=NULL,
        player_id=owner_player_id,
        character_status=CASE WHEN library_slot IS NOT NULL THEN 'available' ELSE 'pending_storage' END,
        pending_reason=CASE WHEN library_slot IS NOT NULL THEN '' ELSE 'campaign_deleted' END,
        updated_at=NOW()
    WHERE campaign_id=p_campaign_id;

    DELETE FROM public.discord_campaigns
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_player_id;

    IF v_synthetic_players IS NOT NULL THEN
        DELETE FROM public.discord_players
        WHERE player_id=ANY(v_synthetic_players)
          AND discord_user_id LIKE 'solo:%';
    END IF;
END;
$$;

-- ============================================================
-- SOLO REMOVE CHARACTER
-- ============================================================
DROP FUNCTION IF EXISTS public.discord_remove_solo_character(UUID,UUID,UUID);
CREATE OR REPLACE FUNCTION public.discord_remove_solo_character(
    p_owner_player_id UUID,
    p_campaign_id UUID,
    p_character_id UUID
) RETURNS TABLE(
    character_id UUID,
    character_status TEXT,
    library_slot INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_control UUID;
    v_status TEXT;
    v_slot INTEGER;
    v_next_character UUID;
    v_next_control UUID;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id
          AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'friends')))='solo'
          AND c.is_active=TRUE
    ) THEN
        RAISE EXCEPTION 'Only the owner of a Solo Play campaign can remove party characters.';
    END IF;

    SELECT sp.control_player_id INTO v_control
    FROM public.discord_solo_party_characters sp
    WHERE sp.campaign_id=p_campaign_id
      AND sp.owner_player_id=p_owner_player_id
      AND sp.character_id=p_character_id
    FOR UPDATE;

    IF v_control IS NULL THEN
        RAISE EXCEPTION 'That character is not part of your Solo party.';
    END IF;

    DELETE FROM public.discord_solo_active_character
    WHERE campaign_id=p_campaign_id AND character_id=p_character_id;

    DELETE FROM public.discord_solo_party_characters
    WHERE campaign_id=p_campaign_id AND character_id=p_character_id;

    v_status:=public.discord_detach_character(p_character_id,'removed_from_solo');

    IF v_control<>p_owner_player_id THEN
        DELETE FROM public.discord_campaign_members
        WHERE campaign_id=p_campaign_id AND player_id=v_control;
        DELETE FROM public.discord_players
        WHERE player_id=v_control AND discord_user_id LIKE 'solo:%';
    END IF;

    SELECT sp.character_id,sp.control_player_id
    INTO v_next_character,v_next_control
    FROM public.discord_solo_party_characters sp
    WHERE sp.campaign_id=p_campaign_id
      AND sp.owner_player_id=p_owner_player_id
    ORDER BY sp.slot_no
    LIMIT 1;

    IF v_next_character IS NOT NULL THEN
        INSERT INTO public.discord_solo_active_character(
            campaign_id,owner_player_id,character_id,control_player_id,updated_at
        )
        VALUES(p_campaign_id,p_owner_player_id,v_next_character,v_next_control,NOW())
        ON CONFLICT(campaign_id) DO UPDATE
        SET owner_player_id=EXCLUDED.owner_player_id,
            character_id=EXCLUDED.character_id,
            control_player_id=EXCLUDED.control_player_id,
            updated_at=NOW();
    END IF;

    SELECT c.library_slot INTO v_slot
    FROM public.discord_characters c
    WHERE c.character_id=p_character_id;

    RETURN QUERY SELECT p_character_id,v_status,v_slot;
END;
$$;

-- Solo companions are initially created using a synthetic control player. Stamp
-- their real account owner when they are registered into the Solo party.
CREATE OR REPLACE FUNCTION public.discord_solo_register_character(
    p_owner_player_id UUID,
    p_campaign_id UUID,
    p_control_player_id UUID,
    p_character_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
    v_slot INTEGER;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.discord_campaigns c
        WHERE c.campaign_id=p_campaign_id
          AND c.owner_player_id=p_owner_player_id
          AND LOWER(TRIM(COALESCE(c.campaign_type,'')))='solo'
          AND c.is_active=TRUE
    ) THEN
        RAISE EXCEPTION 'Solo Play campaign could not be found.';
    END IF;

    IF NOT EXISTS(
        SELECT 1
        FROM public.discord_players p
        JOIN public.discord_campaign_members m
          ON m.player_id=p.player_id AND m.campaign_id=p_campaign_id
        WHERE p.player_id=p_control_player_id
          AND p.discord_user_id LIKE 'solo:%'
    ) THEN
        RAISE EXCEPTION 'Solo party control slot is invalid.';
    END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.discord_characters c
        WHERE c.character_id=p_character_id
          AND c.campaign_id=p_campaign_id
          AND c.player_id=p_control_player_id
    ) THEN
        RAISE EXCEPTION 'Solo party character could not be found.';
    END IF;

    IF (
        SELECT COUNT(*)
        FROM public.discord_solo_party_characters
        WHERE campaign_id=p_campaign_id AND owner_player_id=p_owner_player_id
    )>=5 THEN
        RAISE EXCEPTION 'Solo Play supports a maximum of 5 party characters.';
    END IF;

    SELECT COALESCE(MAX(slot_no),1)+1 INTO v_slot
    FROM public.discord_solo_party_characters
    WHERE campaign_id=p_campaign_id AND owner_player_id=p_owner_player_id;
    v_slot:=GREATEST(2,LEAST(5,v_slot));

    UPDATE public.discord_characters
    SET owner_player_id=p_owner_player_id,
        character_origin='campaign',
        character_status='assigned',
        pending_reason=''
    WHERE character_id=p_character_id;

    INSERT INTO public.discord_solo_party_characters(
        campaign_id,owner_player_id,character_id,control_player_id,slot_no
    )
    VALUES(p_campaign_id,p_owner_player_id,p_character_id,p_control_player_id,v_slot);
END;
$$;

-- ============================================================
-- SECURITY
-- ============================================================
REVOKE ALL ON FUNCTION public.discord_get_character_library(UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_create_library_character(UUID,JSONB,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TEXT) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_assign_library_character(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_delete_library_character(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_resolve_pending_character(UUID,UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_character_departure_preview(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_get_campaign_members(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_leave_campaign(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_kick_campaign_player(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_delete_campaign(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.discord_remove_solo_character(UUID,UUID,UUID) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.discord_get_character_library(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_create_library_character(UUID,JSONB,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_assign_library_character(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_delete_library_character(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_resolve_pending_character(UUID,UUID,TEXT,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_character_departure_preview(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_get_campaign_members(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_leave_campaign(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_kick_campaign_player(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_delete_campaign(UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_remove_solo_character(UUID,UUID,UUID) TO service_role;

NOTIFY pgrst,'reload schema';

COMMIT;
