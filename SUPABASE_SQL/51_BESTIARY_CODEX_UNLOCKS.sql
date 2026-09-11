-- ============================================================
-- RabuShinAIGM Rules Build 6.20.2
-- Migration 51 - Progressive Bestiary / Codex Unlocks
-- Requires Build 6.20.1 / Migration 50
--
-- Reveal levels:
--   0 hidden      - nothing player-visible
--   1 observed    - unknown label only
--   2 identified  - true name + summary
--   3 studied     - true name + summary + details
--   4 mastered    - full entry; typically defeated/thoroughly researched
-- Categories:
--   creature, monster, settlement, faction, npc, lore, item
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_codex_entries
(
    codex_entry_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    category TEXT NOT NULL
        CHECK (category IN ('creature','monster','settlement','faction','npc','lore','item')),
    entry_key TEXT NOT NULL,
    display_name TEXT NOT NULL,
    unknown_label TEXT NOT NULL DEFAULT 'Unknown',
    reveal_level INTEGER NOT NULL DEFAULT 0 CHECK (reveal_level BETWEEN 0 AND 4),
    summary TEXT NOT NULL DEFAULT '',
    details TEXT NOT NULL DEFAULT '',
    settlement TEXT NOT NULL DEFAULT '',
    source_text TEXT NOT NULL DEFAULT '',
    first_world_date TEXT NOT NULL DEFAULT '',
    updated_world_date TEXT NOT NULL DEFAULT '',
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(campaign_id,category,entry_key)
);

CREATE TABLE IF NOT EXISTS public.discord_codex_events
(
    codex_event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    codex_entry_id UUID NOT NULL REFERENCES public.discord_codex_entries(codex_entry_id) ON DELETE CASCADE,
    reveal_level INTEGER NOT NULL CHECK (reveal_level BETWEEN 0 AND 4),
    reason TEXT NOT NULL DEFAULT '',
    world_date TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_discord_codex_campaign_category
ON public.discord_codex_entries(campaign_id,category,reveal_level,updated_at DESC);

ALTER TABLE public.discord_codex_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_codex_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_codex_entries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.discord_codex_events FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.discord_codex_entries TO service_role;
GRANT ALL ON TABLE public.discord_codex_events TO service_role;

ALTER TABLE public.discord_journal_entries
    ADD COLUMN IF NOT EXISTS codex_entry_id UUID NULL
    REFERENCES public.discord_codex_entries(codex_entry_id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_journal_codex_mirror
ON public.discord_journal_entries(campaign_id,player_id,codex_entry_id)
WHERE codex_entry_id IS NOT NULL;

DROP FUNCTION IF EXISTS public.discord_sync_codex_journal(UUID);
CREATE OR REPLACE FUNCTION public.discord_sync_codex_journal(p_codex_entry_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    c public.discord_codex_entries%ROWTYPE;
    m RECORD;
    v_visible_name TEXT;
    v_body TEXT;
BEGIN
    SELECT * INTO c FROM public.discord_codex_entries WHERE codex_entry_id=p_codex_entry_id;
    IF c.codex_entry_id IS NULL THEN RETURN; END IF;

    IF c.reveal_level=0 THEN
        DELETE FROM public.discord_journal_entries WHERE codex_entry_id=c.codex_entry_id;
        RETURN;
    END IF;

    v_visible_name := CASE WHEN c.reveal_level=1 THEN c.unknown_label ELSE c.display_name END;
    v_body :=
        'Category: '||initcap(c.category)||E'\n'||
        'Discovery: '||
        CASE c.reveal_level
            WHEN 1 THEN 'Observed'
            WHEN 2 THEN 'Identified'
            WHEN 3 THEN 'Studied'
            ELSE 'Mastered'
        END||
        CASE WHEN c.reveal_level>=2 AND length(c.summary)>0 THEN E'\n\n'||c.summary ELSE '' END||
        CASE WHEN c.reveal_level>=3 AND length(c.details)>0 THEN E'\n\nDetails:\n'||c.details ELSE '' END||
        CASE WHEN length(c.settlement)>0 THEN E'\n\nAssociated Settlement: '||c.settlement ELSE '' END||
        CASE WHEN length(c.source_text)>0 THEN E'\nSource: '||c.source_text ELSE '' END||
        CASE WHEN length(c.updated_world_date)>0 THEN E'\nWorld Date: '||c.updated_world_date ELSE '' END;

    FOR m IN
        SELECT cm.player_id
        FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=c.campaign_id
        UNION
        SELECT dc.owner_player_id
        FROM public.discord_campaigns dc
        WHERE dc.campaign_id=c.campaign_id
    LOOP
        INSERT INTO public.discord_journal_entries(
            campaign_id,player_id,category,title,entry_text,codex_entry_id,created_at
        )
        VALUES(
            c.campaign_id,m.player_id,'Codex',
            '['||upper(c.category)||'] '||v_visible_name,
            v_body,c.codex_entry_id,NOW()
        )
        ON CONFLICT (campaign_id,player_id,codex_entry_id)
        WHERE codex_entry_id IS NOT NULL
        DO UPDATE SET
            category='Codex',
            title=EXCLUDED.title,
            entry_text=EXCLUDED.entry_text;
    END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_unlock_codex_entry(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_unlock_codex_entry(
    p_campaign_id UUID,
    p_category TEXT,
    p_entry_key TEXT,
    p_display_name TEXT,
    p_unknown_label TEXT,
    p_reveal_level INTEGER,
    p_summary TEXT,
    p_details TEXT,
    p_settlement TEXT,
    p_source_text TEXT,
    p_world_date TEXT,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_category TEXT:=lower(trim(COALESCE(p_category,'')));
    v_key TEXT:=lower(trim(COALESCE(p_entry_key,'')));
    v_level INTEGER:=LEAST(4,GREATEST(0,COALESCE(p_reveal_level,0)));
    c public.discord_codex_entries%ROWTYPE;
    v_old_level INTEGER:=0;
BEGIN
    IF v_category NOT IN ('creature','monster','settlement','faction','npc','lore','item') THEN
        RAISE EXCEPTION 'Invalid Codex category.';
    END IF;
    IF v_key='' OR trim(COALESCE(p_display_name,''))='' THEN
        RAISE EXCEPTION 'Codex entry key and display name are required.';
    END IF;

    SELECT reveal_level INTO v_old_level
    FROM public.discord_codex_entries
    WHERE campaign_id=p_campaign_id AND category=v_category AND entry_key=v_key;

    INSERT INTO public.discord_codex_entries(
        campaign_id,category,entry_key,display_name,unknown_label,reveal_level,
        summary,details,settlement,source_text,first_world_date,updated_world_date
    )
    VALUES(
        p_campaign_id,v_category,v_key,left(trim(p_display_name),180),
        left(COALESCE(NULLIF(trim(p_unknown_label),''),'Unknown'),180),v_level,
        left(COALESCE(p_summary,''),4000),left(COALESCE(p_details,''),12000),
        left(COALESCE(p_settlement,''),160),left(COALESCE(p_source_text,''),1000),
        left(COALESCE(p_world_date,''),160),left(COALESCE(p_world_date,''),160)
    )
    ON CONFLICT(campaign_id,category,entry_key) DO UPDATE
    SET display_name=EXCLUDED.display_name,
        unknown_label=CASE WHEN length(EXCLUDED.unknown_label)>0 THEN EXCLUDED.unknown_label ELSE public.discord_codex_entries.unknown_label END,
        reveal_level=GREATEST(public.discord_codex_entries.reveal_level,EXCLUDED.reveal_level),
        summary=CASE WHEN length(EXCLUDED.summary)>0 THEN EXCLUDED.summary ELSE public.discord_codex_entries.summary END,
        details=CASE WHEN length(EXCLUDED.details)>0 THEN EXCLUDED.details ELSE public.discord_codex_entries.details END,
        settlement=CASE WHEN length(EXCLUDED.settlement)>0 THEN EXCLUDED.settlement ELSE public.discord_codex_entries.settlement END,
        source_text=CASE WHEN length(EXCLUDED.source_text)>0 THEN EXCLUDED.source_text ELSE public.discord_codex_entries.source_text END,
        updated_world_date=EXCLUDED.updated_world_date,
        updated_at=NOW()
    RETURNING * INTO c;

    -- Keep an audit trail only when the reveal level actually advances, or on first creation.
    IF v_old_level IS NULL OR c.reveal_level>COALESCE(v_old_level,-1) THEN
        INSERT INTO public.discord_codex_events(codex_entry_id,reveal_level,reason,world_date)
        VALUES(c.codex_entry_id,c.reveal_level,left(COALESCE(p_reason,''),2000),left(COALESCE(p_world_date,''),160));
    END IF;

    PERFORM public.discord_sync_codex_journal(c.codex_entry_id);

    RETURN jsonb_build_object(
        'authoritative',TRUE,
        'codex_entry_id',c.codex_entry_id,
        'category',c.category,
        'entry_key',c.entry_key,
        'display_name',c.display_name,
        'visible_name',CASE WHEN c.reveal_level=1 THEN c.unknown_label ELSE c.display_name END,
        'reveal_level',c.reveal_level,
        'advanced',c.reveal_level>COALESCE(v_old_level,-1)
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_codex_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_codex_state(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT jsonb_build_object(
        'entries',
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'category',c.category,
                'entry_key',c.entry_key,
                'display_name',c.display_name,
                'unknown_label',c.unknown_label,
                'reveal_level',c.reveal_level,
                'summary',c.summary,
                'details',c.details,
                'settlement',c.settlement,
                'source_text',c.source_text,
                'first_world_date',c.first_world_date,
                'updated_world_date',c.updated_world_date
            )
            ORDER BY c.category,c.display_name
        ),'[]'::jsonb)
    )
    FROM public.discord_codex_entries c
    WHERE c.campaign_id=p_campaign_id;
$$;

COMMIT;
