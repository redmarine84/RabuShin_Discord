-- ============================================================
-- RabuShinAIGM Rules Build 6.20.1
-- Migration 50 - Quest Journal / Objective Tracker
-- Baseline: Build 6.20
--
-- Structured quest state:
--   Active / Completed / Failed / Hidden quests
--   per-quest objectives with the same status set
--   giver, settlement, rewards, notes, timestamps/world dates
--   one live player-visible Quest Tracker row mirrored into the
--   existing Journal tab for every campaign member
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.discord_quests
(
    quest_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    quest_key TEXT NOT NULL,
    title TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','completed','failed','hidden')),
    settlement TEXT NOT NULL DEFAULT '',
    giver TEXT NOT NULL DEFAULT '',
    rewards_text TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    created_world_date TEXT NOT NULL DEFAULT '',
    updated_world_date TEXT NOT NULL DEFAULT '',
    completed_world_date TEXT NOT NULL DEFAULT '',
    failed_world_date TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ NULL,
    failed_at TIMESTAMPTZ NULL,
    UNIQUE(campaign_id,quest_key)
);

CREATE TABLE IF NOT EXISTS public.discord_quest_objectives
(
    objective_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quest_id UUID NOT NULL REFERENCES public.discord_quests(quest_id) ON DELETE CASCADE,
    objective_key TEXT NOT NULL,
    description TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','completed','failed','hidden')),
    optional BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order INTEGER NOT NULL DEFAULT 0,
    notes TEXT NOT NULL DEFAULT '',
    created_world_date TEXT NOT NULL DEFAULT '',
    updated_world_date TEXT NOT NULL DEFAULT '',
    completed_world_date TEXT NOT NULL DEFAULT '',
    failed_world_date TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ NULL,
    failed_at TIMESTAMPTZ NULL,
    UNIQUE(quest_id,objective_key)
);

CREATE INDEX IF NOT EXISTS ix_discord_quests_campaign_status
ON public.discord_quests(campaign_id,status,updated_at DESC);

CREATE INDEX IF NOT EXISTS ix_discord_quest_objectives_quest_order
ON public.discord_quest_objectives(quest_id,sort_order,created_at);

ALTER TABLE public.discord_quests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_quest_objectives ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.discord_quests FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.discord_quest_objectives FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.discord_quests TO service_role;
GRANT ALL ON TABLE public.discord_quest_objectives TO service_role;

-- A nullable FK lets the existing Journal tab render one live tracker row
-- per quest without changing client/main.js.
ALTER TABLE public.discord_journal_entries
    ADD COLUMN IF NOT EXISTS quest_id UUID NULL
    REFERENCES public.discord_quests(quest_id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS ux_discord_journal_quest_mirror
ON public.discord_journal_entries(campaign_id,player_id,quest_id)
WHERE quest_id IS NOT NULL;

DROP FUNCTION IF EXISTS public.discord_sync_quest_journal(UUID);
CREATE OR REPLACE FUNCTION public.discord_sync_quest_journal(p_quest_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    q public.discord_quests%ROWTYPE;
    v_objectives TEXT := '';
    v_body TEXT := '';
    m RECORD;
BEGIN
    SELECT * INTO q FROM public.discord_quests WHERE quest_id=p_quest_id;
    IF q.quest_id IS NULL THEN RETURN; END IF;

    -- Hidden quests are GM-only and must disappear from every player journal.
    IF q.status='hidden' THEN
        DELETE FROM public.discord_journal_entries WHERE quest_id=q.quest_id;
        RETURN;
    END IF;

    SELECT COALESCE(string_agg(
        CASE o.status
            WHEN 'completed' THEN '[Completed] '
            WHEN 'failed' THEN '[Failed] '
            ELSE '[Active] '
        END ||
        CASE WHEN o.optional THEN '(Optional) ' ELSE '' END ||
        o.description ||
        CASE WHEN length(o.notes)>0 THEN E'\n    Notes: '||o.notes ELSE '' END,
        E'\n'
        ORDER BY o.sort_order,o.created_at
    ),'No visible objectives yet.')
    INTO v_objectives
    FROM public.discord_quest_objectives o
    WHERE o.quest_id=q.quest_id AND o.status<>'hidden';

    v_body :=
        'Status: '||initcap(q.status)||E'\n'||
        CASE WHEN length(q.giver)>0 THEN 'Giver: '||q.giver||E'\n' ELSE '' END||
        CASE WHEN length(q.settlement)>0 THEN 'Settlement: '||q.settlement||E'\n' ELSE '' END||
        CASE WHEN length(q.summary)>0 THEN E'\n'||q.summary||E'\n' ELSE '' END||
        E'\nObjectives:\n'||v_objectives||
        CASE WHEN length(q.rewards_text)>0 THEN E'\n\nRewards: '||q.rewards_text ELSE '' END||
        CASE WHEN length(q.notes)>0 THEN E'\nNotes: '||q.notes ELSE '' END||
        CASE WHEN length(q.updated_world_date)>0 THEN E'\nWorld Date: '||q.updated_world_date ELSE '' END;

    FOR m IN
        SELECT cm.player_id
        FROM public.discord_campaign_members cm
        WHERE cm.campaign_id=q.campaign_id
        UNION
        SELECT c.owner_player_id
        FROM public.discord_campaigns c
        WHERE c.campaign_id=q.campaign_id
    LOOP
        INSERT INTO public.discord_journal_entries(
            campaign_id,player_id,category,title,entry_text,quest_id,created_at
        )
        VALUES(
            q.campaign_id,m.player_id,'Quest Tracker',
            '['||upper(q.status)||'] '||q.title,
            v_body,q.quest_id,NOW()
        )
        ON CONFLICT (campaign_id,player_id,quest_id)
        WHERE quest_id IS NOT NULL
        DO UPDATE SET
            category='Quest Tracker',
            title=EXCLUDED.title,
            entry_text=EXCLUDED.entry_text;
    END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_upsert_quest(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_upsert_quest(
    p_campaign_id UUID,
    p_quest_key TEXT,
    p_title TEXT,
    p_summary TEXT,
    p_status TEXT,
    p_settlement TEXT,
    p_giver TEXT,
    p_rewards_text TEXT,
    p_notes TEXT,
    p_world_date TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_key TEXT:=lower(trim(COALESCE(p_quest_key,'')));
    v_status TEXT:=lower(trim(COALESCE(p_status,'active')));
    q public.discord_quests%ROWTYPE;
BEGIN
    IF v_key='' OR trim(COALESCE(p_title,''))='' THEN
        RAISE EXCEPTION 'Quest key and title are required.';
    END IF;
    IF v_status NOT IN ('active','completed','failed','hidden') THEN
        RAISE EXCEPTION 'Quest status must be active, completed, failed, or hidden.';
    END IF;

    INSERT INTO public.discord_quests(
        campaign_id,quest_key,title,summary,status,settlement,giver,rewards_text,notes,
        created_world_date,updated_world_date,completed_world_date,failed_world_date,
        completed_at,failed_at
    )
    VALUES(
        p_campaign_id,v_key,left(trim(p_title),180),left(COALESCE(p_summary,''),4000),v_status,
        left(COALESCE(p_settlement,''),160),left(COALESCE(p_giver,''),160),
        left(COALESCE(p_rewards_text,''),2000),left(COALESCE(p_notes,''),4000),
        left(COALESCE(p_world_date,''),160),left(COALESCE(p_world_date,''),160),
        CASE WHEN v_status='completed' THEN left(COALESCE(p_world_date,''),160) ELSE '' END,
        CASE WHEN v_status='failed' THEN left(COALESCE(p_world_date,''),160) ELSE '' END,
        CASE WHEN v_status='completed' THEN NOW() ELSE NULL END,
        CASE WHEN v_status='failed' THEN NOW() ELSE NULL END
    )
    ON CONFLICT(campaign_id,quest_key) DO UPDATE
    SET title=EXCLUDED.title,
        summary=EXCLUDED.summary,
        status=EXCLUDED.status,
        settlement=EXCLUDED.settlement,
        giver=EXCLUDED.giver,
        rewards_text=EXCLUDED.rewards_text,
        notes=EXCLUDED.notes,
        updated_world_date=EXCLUDED.updated_world_date,
        updated_at=NOW(),
        completed_world_date=CASE
            WHEN EXCLUDED.status='completed' AND public.discord_quests.status<>'completed'
            THEN EXCLUDED.updated_world_date ELSE public.discord_quests.completed_world_date END,
        failed_world_date=CASE
            WHEN EXCLUDED.status='failed' AND public.discord_quests.status<>'failed'
            THEN EXCLUDED.updated_world_date ELSE public.discord_quests.failed_world_date END,
        completed_at=CASE
            WHEN EXCLUDED.status='completed' AND public.discord_quests.status<>'completed'
            THEN NOW() ELSE public.discord_quests.completed_at END,
        failed_at=CASE
            WHEN EXCLUDED.status='failed' AND public.discord_quests.status<>'failed'
            THEN NOW() ELSE public.discord_quests.failed_at END
    RETURNING * INTO q;

    PERFORM public.discord_sync_quest_journal(q.quest_id);

    RETURN jsonb_build_object(
        'authoritative',TRUE,'quest_id',q.quest_id,'quest_key',q.quest_key,
        'title',q.title,'status',q.status,'settlement',q.settlement,'giver',q.giver
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_upsert_quest_objective(UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,INTEGER,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_upsert_quest_objective(
    p_campaign_id UUID,
    p_quest_key TEXT,
    p_objective_key TEXT,
    p_description TEXT,
    p_status TEXT,
    p_optional BOOLEAN,
    p_sort_order INTEGER,
    p_notes TEXT,
    p_world_date TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    q public.discord_quests%ROWTYPE;
    o public.discord_quest_objectives%ROWTYPE;
    v_status TEXT:=lower(trim(COALESCE(p_status,'active')));
    v_key TEXT:=lower(trim(COALESCE(p_objective_key,'')));
BEGIN
    SELECT * INTO q FROM public.discord_quests
    WHERE campaign_id=p_campaign_id AND quest_key=lower(trim(COALESCE(p_quest_key,'')));
    IF q.quest_id IS NULL THEN RAISE EXCEPTION 'Quest was not found.'; END IF;
    IF v_key='' OR trim(COALESCE(p_description,''))='' THEN
        RAISE EXCEPTION 'Objective key and description are required.';
    END IF;
    IF v_status NOT IN ('active','completed','failed','hidden') THEN
        RAISE EXCEPTION 'Objective status must be active, completed, failed, or hidden.';
    END IF;

    INSERT INTO public.discord_quest_objectives(
        quest_id,objective_key,description,status,optional,sort_order,notes,
        created_world_date,updated_world_date,completed_world_date,failed_world_date,
        completed_at,failed_at
    )
    VALUES(
        q.quest_id,v_key,left(trim(p_description),1000),v_status,COALESCE(p_optional,FALSE),
        GREATEST(0,COALESCE(p_sort_order,0)),left(COALESCE(p_notes,''),2000),
        left(COALESCE(p_world_date,''),160),left(COALESCE(p_world_date,''),160),
        CASE WHEN v_status='completed' THEN left(COALESCE(p_world_date,''),160) ELSE '' END,
        CASE WHEN v_status='failed' THEN left(COALESCE(p_world_date,''),160) ELSE '' END,
        CASE WHEN v_status='completed' THEN NOW() ELSE NULL END,
        CASE WHEN v_status='failed' THEN NOW() ELSE NULL END
    )
    ON CONFLICT(quest_id,objective_key) DO UPDATE
    SET description=EXCLUDED.description,status=EXCLUDED.status,optional=EXCLUDED.optional,
        sort_order=EXCLUDED.sort_order,notes=EXCLUDED.notes,
        updated_world_date=EXCLUDED.updated_world_date,updated_at=NOW(),
        completed_world_date=CASE
            WHEN EXCLUDED.status='completed' AND public.discord_quest_objectives.status<>'completed'
            THEN EXCLUDED.updated_world_date ELSE public.discord_quest_objectives.completed_world_date END,
        failed_world_date=CASE
            WHEN EXCLUDED.status='failed' AND public.discord_quest_objectives.status<>'failed'
            THEN EXCLUDED.updated_world_date ELSE public.discord_quest_objectives.failed_world_date END,
        completed_at=CASE
            WHEN EXCLUDED.status='completed' AND public.discord_quest_objectives.status<>'completed'
            THEN NOW() ELSE public.discord_quest_objectives.completed_at END,
        failed_at=CASE
            WHEN EXCLUDED.status='failed' AND public.discord_quest_objectives.status<>'failed'
            THEN NOW() ELSE public.discord_quest_objectives.failed_at END
    RETURNING * INTO o;

    UPDATE public.discord_quests SET updated_at=NOW(),updated_world_date=left(COALESCE(p_world_date,''),160)
    WHERE quest_id=q.quest_id;
    PERFORM public.discord_sync_quest_journal(q.quest_id);

    RETURN jsonb_build_object(
        'authoritative',TRUE,'quest_id',q.quest_id,'quest_key',q.quest_key,
        'objective_id',o.objective_id,'objective_key',o.objective_key,
        'description',o.description,'status',o.status,'optional',o.optional
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_set_quest_status(UUID,TEXT,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.discord_gm_set_quest_status(
    p_campaign_id UUID,
    p_quest_key TEXT,
    p_status TEXT,
    p_notes TEXT,
    p_world_date TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    q public.discord_quests%ROWTYPE;
    v_status TEXT:=lower(trim(COALESCE(p_status,'')));
BEGIN
    IF v_status NOT IN ('active','completed','failed','hidden') THEN
        RAISE EXCEPTION 'Quest status must be active, completed, failed, or hidden.';
    END IF;

    UPDATE public.discord_quests
    SET status=v_status,
        notes=CASE WHEN length(trim(COALESCE(p_notes,'')))>0 THEN left(p_notes,4000) ELSE notes END,
        updated_world_date=left(COALESCE(p_world_date,''),160),updated_at=NOW(),
        completed_world_date=CASE WHEN v_status='completed' AND status<>'completed'
                                  THEN left(COALESCE(p_world_date,''),160) ELSE completed_world_date END,
        failed_world_date=CASE WHEN v_status='failed' AND status<>'failed'
                               THEN left(COALESCE(p_world_date,''),160) ELSE failed_world_date END,
        completed_at=CASE WHEN v_status='completed' AND status<>'completed' THEN NOW() ELSE completed_at END,
        failed_at=CASE WHEN v_status='failed' AND status<>'failed' THEN NOW() ELSE failed_at END
    WHERE campaign_id=p_campaign_id AND quest_key=lower(trim(COALESCE(p_quest_key,'')))
    RETURNING * INTO q;

    IF q.quest_id IS NULL THEN RAISE EXCEPTION 'Quest was not found.'; END IF;
    PERFORM public.discord_sync_quest_journal(q.quest_id);

    RETURN jsonb_build_object(
        'authoritative',TRUE,'quest_id',q.quest_id,'quest_key',q.quest_key,
        'title',q.title,'status',q.status
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_quest_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_quest_state(p_campaign_id UUID)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT jsonb_build_object(
        'quests',
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'quest_id',q.quest_id,
                'quest_key',q.quest_key,
                'title',q.title,
                'summary',q.summary,
                'status',q.status,
                'settlement',q.settlement,
                'giver',q.giver,
                'rewards_text',q.rewards_text,
                'notes',q.notes,
                'created_world_date',q.created_world_date,
                'updated_world_date',q.updated_world_date,
                'completed_world_date',q.completed_world_date,
                'failed_world_date',q.failed_world_date,
                'objectives',COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'objective_key',o.objective_key,
                            'description',o.description,
                            'status',o.status,
                            'optional',o.optional,
                            'sort_order',o.sort_order,
                            'notes',o.notes,
                            'updated_world_date',o.updated_world_date
                        )
                        ORDER BY o.sort_order,o.created_at
                    )
                    FROM public.discord_quest_objectives o
                    WHERE o.quest_id=q.quest_id
                ),'[]'::jsonb)
            )
            ORDER BY
                CASE q.status WHEN 'active' THEN 0 WHEN 'hidden' THEN 1 WHEN 'completed' THEN 2 ELSE 3 END,
                q.updated_at DESC
        ),'[]'::jsonb)
    )
    FROM public.discord_quests q
    WHERE q.campaign_id=p_campaign_id;
$$;

COMMIT;
