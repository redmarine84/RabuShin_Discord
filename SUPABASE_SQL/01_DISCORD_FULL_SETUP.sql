-- ============================================================
-- RABUSHIN DISCORD COMPLETE DATABASE SETUP
-- Safe to run more than once.
-- Run in Supabase SQL Editor.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.discord_players
(
    player_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    discord_user_id TEXT NOT NULL UNIQUE,
    discord_username TEXT NOT NULL,
    display_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.discord_campaigns
(
    campaign_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    campaign_name TEXT NOT NULL,
    join_code TEXT NOT NULL UNIQUE,
    campaign_type TEXT NOT NULL DEFAULT 'multiplayer',
    current_chapter INTEGER NOT NULL DEFAULT 1,
    current_location TEXT NOT NULL DEFAULT 'Greymoor Hollow',
    game_state JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS public.discord_campaign_members
(
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'Player',
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campaign_id, player_id)
);

CREATE TABLE IF NOT EXISTS public.discord_characters
(
    character_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    character_name TEXT NOT NULL,
    species_name TEXT NOT NULL,
    class_name TEXT NOT NULL,
    background_name TEXT NOT NULL DEFAULT '',
    alignment TEXT NOT NULL DEFAULT '',
    level INTEGER NOT NULL DEFAULT 1,
    experience INTEGER NOT NULL DEFAULT 0,
    current_hp INTEGER NOT NULL DEFAULT 1,
    max_hp INTEGER NOT NULL DEFAULT 1,
    armor_class INTEGER NOT NULL DEFAULT 10,
    strength INTEGER NOT NULL DEFAULT 10,
    dexterity INTEGER NOT NULL DEFAULT 10,
    constitution INTEGER NOT NULL DEFAULT 10,
    intelligence INTEGER NOT NULL DEFAULT 10,
    wisdom INTEGER NOT NULL DEFAULT 10,
    charisma INTEGER NOT NULL DEFAULT 10,
    initiative INTEGER NOT NULL DEFAULT 0,
    passive_perception INTEGER NOT NULL DEFAULT 10,
    proficiency_bonus INTEGER NOT NULL DEFAULT 2,
    speed INTEGER NOT NULL DEFAULT 30,
    size_name TEXT NOT NULL DEFAULT 'Medium',
    gold NUMERIC NOT NULL DEFAULT 0,
    equipment_complete BOOLEAN NOT NULL DEFAULT FALSE,
    spells_complete BOOLEAN NOT NULL DEFAULT FALSE,
    character_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_discord_character_per_campaign UNIQUE (campaign_id, player_id)
);

-- Upgrade tables created during the earlier step-by-step setup.
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS alignment TEXT NOT NULL DEFAULT '';
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS equipment_complete BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.discord_characters ADD COLUMN IF NOT EXISTS spells_complete BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.discord_campaigns ADD COLUMN IF NOT EXISTS game_state JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Preserve alignment for characters created during the earlier Discord setup.
UPDATE public.discord_characters
SET alignment = COALESCE(
    NULLIF(alignment, ''),
    NULLIF(character_data->>'alignment', ''),
    NULLIF(character_data #>> '{snapshot,Alignment}', ''),
    ''
)
WHERE alignment = '';

CREATE TABLE IF NOT EXISTS public.discord_inventory_items
(
    inventory_item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    item_name TEXT NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    equipped BOOLEAN NOT NULL DEFAULT FALSE,
    attuned BOOLEAN NOT NULL DEFAULT FALSE,
    source_name TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    item_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.discord_character_spells
(
    character_spell_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    spell_name TEXT NOT NULL,
    spell_level INTEGER NOT NULL DEFAULT 0,
    prepared BOOLEAN NOT NULL DEFAULT FALSE,
    source_tag TEXT NOT NULL DEFAULT 'Class',
    spell_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(character_id, spell_name)
);

CREATE TABLE IF NOT EXISTS public.discord_spell_slots
(
    character_id UUID NOT NULL REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    spell_level INTEGER NOT NULL,
    max_slots INTEGER NOT NULL DEFAULT 0,
    used_slots INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(character_id, spell_level)
);

CREATE TABLE IF NOT EXISTS public.discord_campaign_messages
(
    message_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    sender_player_id UUID REFERENCES public.discord_players(player_id) ON DELETE SET NULL,
    channel_name TEXT NOT NULL DEFAULT 'chat',
    role_name TEXT NOT NULL DEFAULT 'user',
    sender_name TEXT NOT NULL DEFAULT '',
    message_text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.discord_journal_entries
(
    journal_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES public.discord_players(player_id) ON DELETE CASCADE,
    category TEXT NOT NULL DEFAULT 'Note',
    title TEXT NOT NULL DEFAULT '',
    entry_text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_discord_campaign_members_player ON public.discord_campaign_members(player_id);
CREATE INDEX IF NOT EXISTS idx_discord_campaigns_owner ON public.discord_campaigns(owner_player_id);
CREATE INDEX IF NOT EXISTS idx_discord_characters_player ON public.discord_characters(player_id);
CREATE INDEX IF NOT EXISTS idx_discord_characters_campaign ON public.discord_characters(campaign_id);
CREATE INDEX IF NOT EXISTS idx_discord_inventory_character ON public.discord_inventory_items(character_id);
CREATE INDEX IF NOT EXISTS idx_discord_spells_character ON public.discord_character_spells(character_id);
CREATE INDEX IF NOT EXISTS idx_discord_messages_campaign_channel ON public.discord_campaign_messages(campaign_id, channel_name, message_id);
CREATE INDEX IF NOT EXISTS idx_discord_journal_campaign_player ON public.discord_journal_entries(campaign_id, player_id, journal_id);

ALTER TABLE public.discord_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_campaign_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_characters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_character_spells ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_spell_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_campaign_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_journal_entries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.discord_players FROM anon, authenticated;
REVOKE ALL ON public.discord_campaigns FROM anon, authenticated;
REVOKE ALL ON public.discord_campaign_members FROM anon, authenticated;
REVOKE ALL ON public.discord_characters FROM anon, authenticated;
REVOKE ALL ON public.discord_inventory_items FROM anon, authenticated;
REVOKE ALL ON public.discord_character_spells FROM anon, authenticated;
REVOKE ALL ON public.discord_spell_slots FROM anon, authenticated;
REVOKE ALL ON public.discord_campaign_messages FROM anon, authenticated;
REVOKE ALL ON public.discord_journal_entries FROM anon, authenticated;

GRANT ALL ON public.discord_players TO service_role;
GRANT ALL ON public.discord_campaigns TO service_role;
GRANT ALL ON public.discord_campaign_members TO service_role;
GRANT ALL ON public.discord_characters TO service_role;
GRANT ALL ON public.discord_inventory_items TO service_role;
GRANT ALL ON public.discord_character_spells TO service_role;
GRANT ALL ON public.discord_spell_slots TO service_role;
GRANT ALL ON public.discord_campaign_messages TO service_role;
GRANT ALL ON public.discord_journal_entries TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- ============================================================
-- PLAYER
-- ============================================================
CREATE OR REPLACE FUNCTION public.discord_upsert_player(
    p_discord_user_id TEXT,
    p_discord_username TEXT,
    p_display_name TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_player_id UUID;
BEGIN
    INSERT INTO public.discord_players(discord_user_id, discord_username, display_name, last_seen_at)
    VALUES(p_discord_user_id, p_discord_username, p_display_name, NOW())
    ON CONFLICT(discord_user_id) DO UPDATE SET
        discord_username = EXCLUDED.discord_username,
        display_name = EXCLUDED.display_name,
        last_seen_at = NOW()
    RETURNING player_id INTO v_player_id;
    RETURN v_player_id;
END; $$;

-- ============================================================
-- CAMPAIGNS
-- ============================================================
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
    INSERT INTO public.discord_campaigns(owner_player_id, campaign_name, join_code)
    VALUES(p_player_id, TRIM(p_campaign_name), v_join_code)
    RETURNING campaign_id INTO v_campaign_id;
    INSERT INTO public.discord_campaign_members(campaign_id, player_id, role)
    VALUES(v_campaign_id, p_player_id, 'Owner') ON CONFLICT DO NOTHING;
    RETURN v_campaign_id;
END; $$;

CREATE OR REPLACE FUNCTION public.discord_join_campaign(
    p_player_id UUID,
    p_join_code TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_campaign_id UUID;
BEGIN
    SELECT campaign_id INTO v_campaign_id
    FROM public.discord_campaigns
    WHERE UPPER(join_code) = UPPER(TRIM(COALESCE(p_join_code, ''))) AND is_active = TRUE;
    IF v_campaign_id IS NULL THEN RAISE EXCEPTION 'Campaign code was not found.'; END IF;
    INSERT INTO public.discord_campaign_members(campaign_id, player_id, role)
    VALUES(v_campaign_id, p_player_id, 'Player') ON CONFLICT DO NOTHING;
    RETURN v_campaign_id;
END; $$;

CREATE OR REPLACE FUNCTION public.discord_get_my_campaigns(p_player_id UUID)
RETURNS TABLE(
    campaign_id UUID,
    campaign_name TEXT,
    join_code TEXT,
    current_chapter INTEGER,
    current_location TEXT,
    is_owner BOOLEAN,
    member_count BIGINT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT c.campaign_id, c.campaign_name, c.join_code, c.current_chapter, c.current_location,
           c.owner_player_id = p_player_id AS is_owner,
           COUNT(all_members.player_id) AS member_count
    FROM public.discord_campaigns c
    INNER JOIN public.discord_campaign_members mine
        ON mine.campaign_id = c.campaign_id AND mine.player_id = p_player_id
    LEFT JOIN public.discord_campaign_members all_members ON all_members.campaign_id = c.campaign_id
    WHERE c.is_active = TRUE
    GROUP BY c.campaign_id, c.campaign_name, c.join_code, c.current_chapter, c.current_location, c.owner_player_id
    ORDER BY c.campaign_name;
$$;

-- ============================================================
-- CHARACTER
-- ============================================================
-- Earlier step-by-step builds used smaller RETURNS TABLE signatures.
-- PostgreSQL requires these functions to be dropped before expanding their return columns.
DROP FUNCTION IF EXISTS public.discord_get_character(UUID, UUID);
DROP FUNCTION IF EXISTS public.discord_get_character_setup_state(UUID, UUID);

CREATE OR REPLACE FUNCTION public.discord_get_character(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID, campaign_id UUID, character_name TEXT, species_name TEXT, class_name TEXT,
    background_name TEXT, alignment TEXT, level INTEGER, experience INTEGER, current_hp INTEGER,
    max_hp INTEGER, armor_class INTEGER, strength INTEGER, dexterity INTEGER, constitution INTEGER,
    intelligence INTEGER, wisdom INTEGER, charisma INTEGER, initiative INTEGER, passive_perception INTEGER,
    proficiency_bonus INTEGER, speed INTEGER, size_name TEXT, gold NUMERIC, equipment_complete BOOLEAN,
    spells_complete BOOLEAN, character_data JSONB
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT c.character_id, c.campaign_id, c.character_name, c.species_name, c.class_name,
           c.background_name, c.alignment, c.level, c.experience, c.current_hp, c.max_hp,
           c.armor_class, c.strength, c.dexterity, c.constitution, c.intelligence, c.wisdom,
           c.charisma, c.initiative, c.passive_perception, c.proficiency_bonus, c.speed,
           c.size_name, c.gold, c.equipment_complete, c.spells_complete, c.character_data
    FROM public.discord_characters c
    INNER JOIN public.discord_campaign_members m ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.discord_create_character(
    p_player_id UUID,
    p_campaign_id UUID,
    p_character_data JSONB
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_character_id UUID; v_name TEXT;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members WHERE campaign_id = p_campaign_id AND player_id = p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;
    IF EXISTS(SELECT 1 FROM public.discord_characters WHERE campaign_id = p_campaign_id AND player_id = p_player_id) THEN
        RAISE EXCEPTION 'You already have a character in this campaign.';
    END IF;
    v_name := TRIM(COALESCE(p_character_data->>'character_name', ''));
    IF LENGTH(v_name) = 0 THEN RAISE EXCEPTION 'Character name is required.'; END IF;

    INSERT INTO public.discord_characters(
        campaign_id, player_id, character_name, species_name, class_name, background_name, alignment,
        level, experience, current_hp, max_hp, armor_class, strength, dexterity, constitution,
        intelligence, wisdom, charisma, initiative, passive_perception, proficiency_bonus,
        speed, size_name, gold, character_data
    ) VALUES(
        p_campaign_id, p_player_id, v_name,
        COALESCE(p_character_data->>'species_name',''), COALESCE(p_character_data->>'class_name',''),
        COALESCE(p_character_data->>'background_name',''), COALESCE(p_character_data->>'alignment',''),
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
        COALESCE(NULLIF(p_character_data->>'gold','')::NUMERIC,0), p_character_data
    ) RETURNING character_id INTO v_character_id;
    RETURN v_character_id;
END; $$;

CREATE OR REPLACE FUNCTION public.discord_get_character_setup_state(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(character_id UUID, equipment_complete BOOLEAN, spells_complete BOOLEAN)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT c.character_id, c.equipment_complete, c.spells_complete
    FROM public.discord_characters c
    INNER JOIN public.discord_campaign_members m ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id LIMIT 1;
$$;

-- ============================================================
-- PARTY
-- ============================================================
CREATE OR REPLACE FUNCTION public.discord_get_party(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(
    character_id UUID, player_id UUID, display_name TEXT, discord_username TEXT,
    character_name TEXT, species_name TEXT, class_name TEXT, level INTEGER,
    current_hp INTEGER, max_hp INTEGER, armor_class INTEGER
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT c.character_id, c.player_id, COALESCE(p.display_name,p.discord_username), p.discord_username,
           c.character_name,c.species_name,c.class_name,c.level,c.current_hp,c.max_hp,c.armor_class
    FROM public.discord_characters c
    INNER JOIN public.discord_players p ON p.player_id=c.player_id
    INNER JOIN public.discord_campaign_members viewer ON viewer.campaign_id=c.campaign_id AND viewer.player_id=p_player_id
    WHERE c.campaign_id=p_campaign_id
    ORDER BY c.character_name;
$$;

-- ============================================================
-- EQUIPMENT / INVENTORY
-- ============================================================
CREATE OR REPLACE FUNCTION public.discord_set_starting_equipment(
    p_player_id UUID, p_campaign_id UUID, p_gold NUMERIC, p_items JSONB
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_character_id UUID; v_done BOOLEAN;
BEGIN
    SELECT c.character_id, c.equipment_complete INTO v_character_id, v_done
    FROM public.discord_characters c
    INNER JOIN public.discord_campaign_members m ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;
    IF v_done THEN RAISE EXCEPTION 'Starting equipment has already been selected.'; END IF;

    DELETE FROM public.discord_inventory_items WHERE character_id = v_character_id;
    INSERT INTO public.discord_inventory_items(character_id,item_name,quantity,equipped,attuned,source_name,notes,item_data)
    SELECT v_character_id,
           item->>'item_name',
           GREATEST(1, COALESCE(NULLIF(item->>'quantity','')::INTEGER,1)),
           COALESCE((item->>'equipped')::BOOLEAN,FALSE), FALSE,
           COALESCE(item->>'source_name',''), COALESCE(item->>'notes',''), item
    FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) AS item
    WHERE LENGTH(TRIM(COALESCE(item->>'item_name',''))) > 0;

    UPDATE public.discord_characters SET gold = GREATEST(0,COALESCE(p_gold,0)), equipment_complete = TRUE, updated_at = NOW()
    WHERE character_id = v_character_id;
END; $$;

CREATE OR REPLACE FUNCTION public.discord_get_inventory(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(inventory_item_id UUID, item_name TEXT, quantity INTEGER, equipped BOOLEAN, attuned BOOLEAN, source_name TEXT, notes TEXT, item_data JSONB)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT i.inventory_item_id, i.item_name, i.quantity, i.equipped, i.attuned, i.source_name, i.notes, i.item_data
    FROM public.discord_inventory_items i
    INNER JOIN public.discord_characters c ON c.character_id = i.character_id
    INNER JOIN public.discord_campaign_members m ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id
    ORDER BY i.item_name;
$$;

-- ============================================================
-- SPELLS
-- ============================================================
CREATE OR REPLACE FUNCTION public.discord_set_spells(
    p_player_id UUID, p_campaign_id UUID, p_spells JSONB, p_slots JSONB
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_character_id UUID;
BEGIN
    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    INNER JOIN public.discord_campaign_members m ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id LIMIT 1;
    IF v_character_id IS NULL THEN RAISE EXCEPTION 'Character could not be found.'; END IF;

    DELETE FROM public.discord_character_spells WHERE character_id = v_character_id;
    DELETE FROM public.discord_spell_slots WHERE character_id = v_character_id;

    INSERT INTO public.discord_character_spells(character_id,spell_name,spell_level,prepared,source_tag,spell_data)
    SELECT v_character_id, spell->>'spell_name',
           COALESCE(NULLIF(spell->>'spell_level','')::INTEGER,0),
           COALESCE((spell->>'prepared')::BOOLEAN,FALSE),
           COALESCE(spell->>'source_tag','Class'), spell
    FROM jsonb_array_elements(COALESCE(p_spells,'[]'::jsonb)) AS spell
    WHERE LENGTH(TRIM(COALESCE(spell->>'spell_name',''))) > 0;

    INSERT INTO public.discord_spell_slots(character_id,spell_level,max_slots,used_slots)
    SELECT v_character_id,
           COALESCE(NULLIF(slot->>'spell_level','')::INTEGER,1),
           GREATEST(0,COALESCE(NULLIF(slot->>'max_slots','')::INTEGER,0)), 0
    FROM jsonb_array_elements(COALESCE(p_slots,'[]'::jsonb)) AS slot
    WHERE COALESCE(NULLIF(slot->>'max_slots','')::INTEGER,0) > 0;

    UPDATE public.discord_characters SET spells_complete = TRUE, updated_at = NOW() WHERE character_id = v_character_id;
END; $$;

CREATE OR REPLACE FUNCTION public.discord_get_spells(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(character_spell_id UUID, spell_name TEXT, spell_level INTEGER, prepared BOOLEAN, source_tag TEXT, spell_data JSONB)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT s.character_spell_id, s.spell_name, s.spell_level, s.prepared, s.source_tag, s.spell_data
    FROM public.discord_character_spells s
    INNER JOIN public.discord_characters c ON c.character_id = s.character_id
    INNER JOIN public.discord_campaign_members m ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id
    ORDER BY s.spell_level, s.spell_name;
$$;

CREATE OR REPLACE FUNCTION public.discord_get_spell_slots(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(spell_level INTEGER, max_slots INTEGER, used_slots INTEGER)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT s.spell_level, s.max_slots, s.used_slots
    FROM public.discord_spell_slots s
    INNER JOIN public.discord_characters c ON c.character_id = s.character_id
    INNER JOIN public.discord_campaign_members m ON m.campaign_id = c.campaign_id AND m.player_id = p_player_id
    WHERE c.player_id = p_player_id AND c.campaign_id = p_campaign_id
    ORDER BY s.spell_level;
$$;

-- ============================================================
-- CHAT / GM TIMELINE
-- ============================================================
CREATE OR REPLACE FUNCTION public.discord_add_message(
    p_player_id UUID, p_campaign_id UUID, p_channel_name TEXT, p_role_name TEXT, p_sender_name TEXT, p_message_text TEXT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id BIGINT;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members WHERE campaign_id=p_campaign_id AND player_id=p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;
    IF LENGTH(TRIM(COALESCE(p_message_text,''))) = 0 THEN RAISE EXCEPTION 'Message is required.'; END IF;
    INSERT INTO public.discord_campaign_messages(campaign_id,sender_player_id,channel_name,role_name,sender_name,message_text)
    VALUES(p_campaign_id,p_player_id,COALESCE(NULLIF(TRIM(p_channel_name),''),'chat'),COALESCE(NULLIF(TRIM(p_role_name),''),'user'),COALESCE(p_sender_name,''),TRIM(p_message_text))
    RETURNING message_id INTO v_id;
    RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.discord_get_messages(
    p_player_id UUID, p_campaign_id UUID, p_channel_name TEXT, p_limit INTEGER DEFAULT 100
) RETURNS TABLE(message_id BIGINT, role_name TEXT, sender_name TEXT, message_text TEXT, created_at TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT q.message_id, q.role_name, q.sender_name, q.message_text, q.created_at
    FROM (
        SELECT m.message_id, m.role_name, m.sender_name, m.message_text, m.created_at
        FROM public.discord_campaign_messages m
        INNER JOIN public.discord_campaign_members cm ON cm.campaign_id=m.campaign_id AND cm.player_id=p_player_id
        WHERE m.campaign_id=p_campaign_id AND m.channel_name=COALESCE(NULLIF(TRIM(p_channel_name),''),'chat')
        ORDER BY m.message_id DESC
        LIMIT LEAST(GREATEST(COALESCE(p_limit,100),1),500)
    ) q ORDER BY q.message_id;
$$;

-- ============================================================
-- JOURNAL
-- ============================================================
CREATE OR REPLACE FUNCTION public.discord_add_journal(
    p_player_id UUID, p_campaign_id UUID, p_category TEXT, p_title TEXT, p_entry_text TEXT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id BIGINT;
BEGIN
    IF NOT EXISTS(SELECT 1 FROM public.discord_campaign_members WHERE campaign_id=p_campaign_id AND player_id=p_player_id) THEN
        RAISE EXCEPTION 'You are not a member of this campaign.';
    END IF;
    IF LENGTH(TRIM(COALESCE(p_entry_text,'')))=0 THEN RAISE EXCEPTION 'Journal entry is required.'; END IF;
    INSERT INTO public.discord_journal_entries(campaign_id,player_id,category,title,entry_text)
    VALUES(p_campaign_id,p_player_id,COALESCE(NULLIF(TRIM(p_category),''),'Note'),COALESCE(p_title,''),TRIM(p_entry_text))
    RETURNING journal_id INTO v_id;
    RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.discord_get_journal(p_player_id UUID, p_campaign_id UUID)
RETURNS TABLE(journal_id BIGINT, category TEXT, title TEXT, entry_text TEXT, created_at TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT j.journal_id,j.category,j.title,j.entry_text,j.created_at
    FROM public.discord_journal_entries j
    INNER JOIN public.discord_campaign_members m ON m.campaign_id=j.campaign_id AND m.player_id=p_player_id
    WHERE j.campaign_id=p_campaign_id AND j.player_id=p_player_id
    ORDER BY j.journal_id DESC;
$$;

-- ============================================================
-- PERMISSIONS: service-role only RPCs
-- ============================================================
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname LIKE 'discord_%'
    LOOP
        EXECUTE 'REVOKE ALL ON FUNCTION ' || r.sig || ' FROM PUBLIC';
        EXECUTE 'GRANT EXECUTE ON FUNCTION ' || r.sig || ' TO service_role';
    END LOOP;
END $$;
