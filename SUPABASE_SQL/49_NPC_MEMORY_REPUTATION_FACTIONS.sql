-- ============================================================
-- RabuShinAIGM Rules Build 6.20
-- Migration 49 - NPC Memory, Reputation, and Factions
-- Baseline: 0c98dba3413c29ed3fd246951c1f598e4b4e2163
--
-- Persistent GM-only social state:
--   * important NPC identity / role / faction
--   * per-party or per-character NPC opinion (-100..100)
--   * durable, deduplicated NPC memories
--   * per-party or per-character faction reputation (-100..100)
--   * durable, deduplicated faction reputation events
--
-- Visible tiers:
--   Hostile    -100 .. -61
--   Unfriendly  -60 .. -21
--   Neutral     -20 ..  20
--   Friendly     21 ..  60
--   Allied       61 .. 100
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_social_key(p_value TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT trim(both '-' from regexp_replace(
        lower(trim(COALESCE(p_value,''))),
        '[^a-z0-9]+',
        '-',
        'g'
    ));
$$;

CREATE OR REPLACE FUNCTION public.discord_social_tier(p_score INTEGER)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
SECURITY DEFINER
SET search_path=public
AS $$
    SELECT CASE
        WHEN LEAST(100,GREATEST(-100,COALESCE(p_score,0))) <= -61 THEN 'Hostile'
        WHEN LEAST(100,GREATEST(-100,COALESCE(p_score,0))) <= -21 THEN 'Unfriendly'
        WHEN LEAST(100,GREATEST(-100,COALESCE(p_score,0))) <=  20 THEN 'Neutral'
        WHEN LEAST(100,GREATEST(-100,COALESCE(p_score,0))) <=  60 THEN 'Friendly'
        ELSE 'Allied'
    END;
$$;

CREATE TABLE IF NOT EXISTS public.discord_campaign_factions
(
    faction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    faction_key TEXT NOT NULL,
    display_name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(campaign_id,faction_key)
);

CREATE TABLE IF NOT EXISTS public.discord_campaign_npcs
(
    npc_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    npc_key TEXT NOT NULL,
    display_name TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT '',
    faction_id UUID NULL
        REFERENCES public.discord_campaign_factions(faction_id) ON DELETE SET NULL,
    home_location TEXT NOT NULL DEFAULT '',
    important BOOLEAN NOT NULL DEFAULT TRUE,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(campaign_id,npc_key)
);

CREATE TABLE IF NOT EXISTS public.discord_npc_opinions
(
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    npc_id UUID NOT NULL
        REFERENCES public.discord_campaign_npcs(npc_id) ON DELETE CASCADE,
    subject_type TEXT NOT NULL CHECK (subject_type IN ('party','character')),
    subject_key TEXT NOT NULL,
    character_id UUID NULL
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    score INTEGER NOT NULL DEFAULT 0 CHECK (score BETWEEN -100 AND 100),
    last_reason TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(npc_id,subject_key),
    CHECK (
        (subject_type='party' AND subject_key='party' AND character_id IS NULL)
        OR
        (subject_type='character' AND character_id IS NOT NULL AND subject_key=character_id::TEXT)
    )
);

CREATE TABLE IF NOT EXISTS public.discord_npc_memories
(
    memory_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    npc_id UUID NOT NULL
        REFERENCES public.discord_campaign_npcs(npc_id) ON DELETE CASCADE,
    subject_type TEXT NOT NULL CHECK (subject_type IN ('party','character')),
    subject_key TEXT NOT NULL,
    character_id UUID NULL
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    memory_text TEXT NOT NULL,
    opinion_delta INTEGER NOT NULL DEFAULT 0 CHECK (opinion_delta BETWEEN -25 AND 25),
    importance INTEGER NOT NULL DEFAULT 3 CHECK (importance BETWEEN 1 AND 5),
    memory_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (subject_type='party' AND subject_key='party' AND character_id IS NULL)
        OR
        (subject_type='character' AND character_id IS NOT NULL AND subject_key=character_id::TEXT)
    ),
    UNIQUE(npc_id,subject_key,memory_hash)
);

CREATE TABLE IF NOT EXISTS public.discord_faction_reputation
(
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    faction_id UUID NOT NULL
        REFERENCES public.discord_campaign_factions(faction_id) ON DELETE CASCADE,
    subject_type TEXT NOT NULL CHECK (subject_type IN ('party','character')),
    subject_key TEXT NOT NULL,
    character_id UUID NULL
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    score INTEGER NOT NULL DEFAULT 0 CHECK (score BETWEEN -100 AND 100),
    last_reason TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(faction_id,subject_key),
    CHECK (
        (subject_type='party' AND subject_key='party' AND character_id IS NULL)
        OR
        (subject_type='character' AND character_id IS NOT NULL AND subject_key=character_id::TEXT)
    )
);

CREATE TABLE IF NOT EXISTS public.discord_faction_reputation_events
(
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID NOT NULL
        REFERENCES public.discord_campaigns(campaign_id) ON DELETE CASCADE,
    faction_id UUID NOT NULL
        REFERENCES public.discord_campaign_factions(faction_id) ON DELETE CASCADE,
    subject_type TEXT NOT NULL CHECK (subject_type IN ('party','character')),
    subject_key TEXT NOT NULL,
    character_id UUID NULL
        REFERENCES public.discord_characters(character_id) ON DELETE CASCADE,
    delta INTEGER NOT NULL CHECK (delta BETWEEN -25 AND 25 AND delta <> 0),
    reason TEXT NOT NULL,
    event_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (subject_type='party' AND subject_key='party' AND character_id IS NULL)
        OR
        (subject_type='character' AND character_id IS NOT NULL AND subject_key=character_id::TEXT)
    ),
    UNIQUE(faction_id,subject_key,event_hash)
);

CREATE INDEX IF NOT EXISTS ix_discord_campaign_npcs_campaign
ON public.discord_campaign_npcs(campaign_id,updated_at DESC);

CREATE INDEX IF NOT EXISTS ix_discord_npc_memories_campaign_npc
ON public.discord_npc_memories(campaign_id,npc_id,created_at DESC);

CREATE INDEX IF NOT EXISTS ix_discord_factions_campaign
ON public.discord_campaign_factions(campaign_id,updated_at DESC);

CREATE INDEX IF NOT EXISTS ix_discord_faction_events_campaign
ON public.discord_faction_reputation_events(campaign_id,faction_id,created_at DESC);

ALTER TABLE public.discord_campaign_factions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_campaign_npcs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_npc_opinions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_npc_memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_faction_reputation ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discord_faction_reputation_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.discord_campaign_factions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.discord_campaign_npcs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.discord_npc_opinions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.discord_npc_memories FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.discord_faction_reputation FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.discord_faction_reputation_events FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.discord_campaign_factions TO service_role;
GRANT ALL ON TABLE public.discord_campaign_npcs TO service_role;
GRANT ALL ON TABLE public.discord_npc_opinions TO service_role;
GRANT ALL ON TABLE public.discord_npc_memories TO service_role;
GRANT ALL ON TABLE public.discord_faction_reputation TO service_role;
GRANT ALL ON TABLE public.discord_faction_reputation_events TO service_role;

CREATE OR REPLACE FUNCTION public.discord_social_resolve_character(
    p_campaign_id UUID,
    p_subject_type TEXT,
    p_character_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_subject_type TEXT := lower(trim(COALESCE(p_subject_type,'')));
    v_character_id UUID;
BEGIN
    IF v_subject_type='party' THEN
        RETURN NULL;
    END IF;

    IF v_subject_type <> 'character' THEN
        RAISE EXCEPTION 'Social subjectType must be party or character.';
    END IF;

    SELECT c.character_id INTO v_character_id
    FROM public.discord_characters c
    WHERE c.campaign_id=p_campaign_id
      AND lower(c.character_name)=lower(trim(COALESCE(p_character_name,'')))
    ORDER BY c.character_id
    LIMIT 1;

    IF v_character_id IS NULL THEN
        RAISE EXCEPTION 'Social target character could not be found.';
    END IF;

    RETURN v_character_id;
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_remember_npc_interaction(
    UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER
);
CREATE OR REPLACE FUNCTION public.discord_gm_remember_npc_interaction(
    p_campaign_id UUID,
    p_npc_name TEXT,
    p_npc_role TEXT,
    p_faction_name TEXT,
    p_home_location TEXT,
    p_subject_type TEXT,
    p_character_name TEXT,
    p_memory TEXT,
    p_opinion_delta INTEGER,
    p_importance INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_npc_name TEXT := left(trim(COALESCE(p_npc_name,'')),120);
    v_npc_key TEXT;
    v_faction_name TEXT := left(trim(COALESCE(p_faction_name,'')),120);
    v_faction_key TEXT;
    v_faction_id UUID;
    v_npc_id UUID;
    v_subject_type TEXT := lower(trim(COALESCE(p_subject_type,'')));
    v_character_id UUID;
    v_subject_key TEXT;
    v_memory TEXT := left(regexp_replace(trim(COALESCE(p_memory,'')),'[[:space:]]+',' ','g'),600);
    v_memory_hash TEXT;
    v_memory_id UUID;
    v_score INTEGER := 0;
    v_delta INTEGER := COALESCE(p_opinion_delta,0);
    v_importance INTEGER := COALESCE(p_importance,3);
BEGIN
    IF v_npc_name='' THEN
        RAISE EXCEPTION 'NPC name is required.';
    END IF;
    v_npc_key := public.discord_social_key(v_npc_name);
    IF v_npc_key='' THEN
        RAISE EXCEPTION 'NPC name could not produce a stable key.';
    END IF;
    IF v_memory='' THEN
        RAISE EXCEPTION 'NPC memory text is required.';
    END IF;
    IF v_delta < -25 OR v_delta > 25 THEN
        RAISE EXCEPTION 'NPC opinion delta must be between -25 and 25.';
    END IF;
    IF v_importance < 1 OR v_importance > 5 THEN
        RAISE EXCEPTION 'NPC memory importance must be between 1 and 5.';
    END IF;

    v_character_id := public.discord_social_resolve_character(
        p_campaign_id,v_subject_type,p_character_name
    );
    v_subject_key := CASE
        WHEN v_subject_type='party' THEN 'party'
        ELSE v_character_id::TEXT
    END;

    IF v_faction_name<>'' THEN
        v_faction_key := public.discord_social_key(v_faction_name);
        IF v_faction_key='' THEN
            RAISE EXCEPTION 'Faction name could not produce a stable key.';
        END IF;
        INSERT INTO public.discord_campaign_factions(
            campaign_id,faction_key,display_name,description,updated_at
        )
        VALUES(p_campaign_id,v_faction_key,v_faction_name,'',NOW())
        ON CONFLICT(campaign_id,faction_key) DO UPDATE
        SET display_name=EXCLUDED.display_name,
            updated_at=NOW()
        RETURNING faction_id INTO v_faction_id;
    END IF;

    INSERT INTO public.discord_campaign_npcs(
        campaign_id,npc_key,display_name,role,faction_id,home_location,
        important,first_seen_at,last_seen_at,updated_at
    )
    VALUES(
        p_campaign_id,v_npc_key,v_npc_name,
        left(trim(COALESCE(p_npc_role,'')),120),
        v_faction_id,
        left(trim(COALESCE(p_home_location,'')),120),
        TRUE,NOW(),NOW(),NOW()
    )
    ON CONFLICT(campaign_id,npc_key) DO UPDATE
    SET display_name=EXCLUDED.display_name,
        role=CASE WHEN EXCLUDED.role<>'' THEN EXCLUDED.role ELSE discord_campaign_npcs.role END,
        faction_id=COALESCE(EXCLUDED.faction_id,discord_campaign_npcs.faction_id),
        home_location=CASE
            WHEN EXCLUDED.home_location<>'' THEN EXCLUDED.home_location
            ELSE discord_campaign_npcs.home_location
        END,
        important=TRUE,
        last_seen_at=NOW(),
        updated_at=NOW()
    RETURNING npc_id INTO v_npc_id;

    v_memory_hash := md5(
        v_npc_key || '|' || v_subject_key || '|' || lower(v_memory)
    );

    INSERT INTO public.discord_npc_memories(
        campaign_id,npc_id,subject_type,subject_key,character_id,
        memory_text,opinion_delta,importance,memory_hash,created_at
    )
    VALUES(
        p_campaign_id,v_npc_id,v_subject_type,v_subject_key,v_character_id,
        v_memory,v_delta,v_importance,v_memory_hash,NOW()
    )
    ON CONFLICT(npc_id,subject_key,memory_hash) DO NOTHING
    RETURNING memory_id INTO v_memory_id;

    IF v_memory_id IS NOT NULL THEN
        INSERT INTO public.discord_npc_opinions(
            campaign_id,npc_id,subject_type,subject_key,character_id,
            score,last_reason,updated_at
        )
        VALUES(
            p_campaign_id,v_npc_id,v_subject_type,v_subject_key,v_character_id,
            v_delta,v_memory,NOW()
        )
        ON CONFLICT(npc_id,subject_key) DO UPDATE
        SET score=LEAST(100,GREATEST(-100,discord_npc_opinions.score+EXCLUDED.score)),
            subject_type=EXCLUDED.subject_type,
            character_id=EXCLUDED.character_id,
            last_reason=EXCLUDED.last_reason,
            updated_at=NOW();
    END IF;

    SELECT COALESCE(o.score,0) INTO v_score
    FROM public.discord_npc_opinions o
    WHERE o.npc_id=v_npc_id AND o.subject_key=v_subject_key;

    RETURN jsonb_build_object(
        'authoritative',TRUE,
        'action','remember_npc_interaction',
        'recorded',v_memory_id IS NOT NULL,
        'npc_id',v_npc_id,
        'npc_name',v_npc_name,
        'subject_type',v_subject_type,
        'character_name',CASE WHEN v_subject_type='character' THEN trim(COALESCE(p_character_name,'')) ELSE '' END,
        'memory',v_memory,
        'opinion_delta',CASE WHEN v_memory_id IS NOT NULL THEN v_delta ELSE 0 END,
        'opinion_score',COALESCE(v_score,0),
        'opinion_tier',public.discord_social_tier(COALESCE(v_score,0)),
        'deduplicated',v_memory_id IS NULL
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_adjust_faction_reputation(
    UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT
);
CREATE OR REPLACE FUNCTION public.discord_gm_adjust_faction_reputation(
    p_campaign_id UUID,
    p_faction_name TEXT,
    p_faction_description TEXT,
    p_subject_type TEXT,
    p_character_name TEXT,
    p_delta INTEGER,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_faction_name TEXT := left(trim(COALESCE(p_faction_name,'')),120);
    v_faction_key TEXT;
    v_faction_id UUID;
    v_subject_type TEXT := lower(trim(COALESCE(p_subject_type,'')));
    v_character_id UUID;
    v_subject_key TEXT;
    v_delta INTEGER := COALESCE(p_delta,0);
    v_reason TEXT := left(regexp_replace(trim(COALESCE(p_reason,'')),'[[:space:]]+',' ','g'),600);
    v_event_hash TEXT;
    v_event_id UUID;
    v_score INTEGER := 0;
BEGIN
    IF v_faction_name='' THEN
        RAISE EXCEPTION 'Faction name is required.';
    END IF;
    IF v_delta=0 OR v_delta < -25 OR v_delta > 25 THEN
        RAISE EXCEPTION 'Faction reputation delta must be non-zero and between -25 and 25.';
    END IF;
    IF v_reason='' THEN
        RAISE EXCEPTION 'Faction reputation reason is required.';
    END IF;

    v_faction_key := public.discord_social_key(v_faction_name);
    IF v_faction_key='' THEN
        RAISE EXCEPTION 'Faction name could not produce a stable key.';
    END IF;

    v_character_id := public.discord_social_resolve_character(
        p_campaign_id,v_subject_type,p_character_name
    );
    v_subject_key := CASE
        WHEN v_subject_type='party' THEN 'party'
        ELSE v_character_id::TEXT
    END;

    INSERT INTO public.discord_campaign_factions(
        campaign_id,faction_key,display_name,description,updated_at
    )
    VALUES(
        p_campaign_id,v_faction_key,v_faction_name,
        left(trim(COALESCE(p_faction_description,'')),300),
        NOW()
    )
    ON CONFLICT(campaign_id,faction_key) DO UPDATE
    SET display_name=EXCLUDED.display_name,
        description=CASE
            WHEN EXCLUDED.description<>'' THEN EXCLUDED.description
            ELSE discord_campaign_factions.description
        END,
        updated_at=NOW()
    RETURNING faction_id INTO v_faction_id;

    v_event_hash := md5(
        v_faction_key || '|' || v_subject_key || '|' ||
        v_delta::TEXT || '|' || lower(v_reason)
    );

    INSERT INTO public.discord_faction_reputation_events(
        campaign_id,faction_id,subject_type,subject_key,character_id,
        delta,reason,event_hash,created_at
    )
    VALUES(
        p_campaign_id,v_faction_id,v_subject_type,v_subject_key,v_character_id,
        v_delta,v_reason,v_event_hash,NOW()
    )
    ON CONFLICT(faction_id,subject_key,event_hash) DO NOTHING
    RETURNING event_id INTO v_event_id;

    IF v_event_id IS NOT NULL THEN
        INSERT INTO public.discord_faction_reputation(
            campaign_id,faction_id,subject_type,subject_key,character_id,
            score,last_reason,updated_at
        )
        VALUES(
            p_campaign_id,v_faction_id,v_subject_type,v_subject_key,v_character_id,
            v_delta,v_reason,NOW()
        )
        ON CONFLICT(faction_id,subject_key) DO UPDATE
        SET score=LEAST(100,GREATEST(-100,discord_faction_reputation.score+EXCLUDED.score)),
            subject_type=EXCLUDED.subject_type,
            character_id=EXCLUDED.character_id,
            last_reason=EXCLUDED.last_reason,
            updated_at=NOW();
    END IF;

    SELECT COALESCE(r.score,0) INTO v_score
    FROM public.discord_faction_reputation r
    WHERE r.faction_id=v_faction_id AND r.subject_key=v_subject_key;

    RETURN jsonb_build_object(
        'authoritative',TRUE,
        'action','adjust_faction_reputation',
        'recorded',v_event_id IS NOT NULL,
        'faction_id',v_faction_id,
        'faction_name',v_faction_name,
        'subject_type',v_subject_type,
        'character_name',CASE WHEN v_subject_type='character' THEN trim(COALESCE(p_character_name,'')) ELSE '' END,
        'delta',CASE WHEN v_event_id IS NOT NULL THEN v_delta ELSE 0 END,
        'reason',v_reason,
        'reputation_score',COALESCE(v_score,0),
        'reputation_tier',public.discord_social_tier(COALESCE(v_score,0)),
        'deduplicated',v_event_id IS NULL
    );
END;
$$;

DROP FUNCTION IF EXISTS public.discord_gm_get_social_state(UUID);
CREATE OR REPLACE FUNCTION public.discord_gm_get_social_state(
    p_campaign_id UUID
)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
SELECT jsonb_build_object(
    'npcs',
    COALESCE((
        SELECT jsonb_agg(npc_json ORDER BY npc_updated DESC)
        FROM (
            SELECT
                n.updated_at AS npc_updated,
                jsonb_build_object(
                    'npc_id',n.npc_id,
                    'npc_name',n.display_name,
                    'role',n.role,
                    'faction_name',COALESCE(f.display_name,''),
                    'home_location',n.home_location,
                    'opinions',COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'subject_type',o.subject_type,
                                'character_name',COALESCE(c.character_name,''),
                                'score',o.score,
                                'tier',public.discord_social_tier(o.score),
                                'last_reason',o.last_reason
                            )
                            ORDER BY o.updated_at DESC
                        )
                        FROM public.discord_npc_opinions o
                        LEFT JOIN public.discord_characters c
                          ON c.character_id=o.character_id
                        WHERE o.npc_id=n.npc_id
                    ),'[]'::jsonb),
                    'memories',COALESCE((
                        SELECT jsonb_agg(mq.memory_json ORDER BY mq.importance DESC,mq.created_at DESC)
                        FROM (
                            SELECT
                                m.importance,
                                m.created_at,
                                jsonb_build_object(
                                    'subject_type',m.subject_type,
                                    'character_name',COALESCE(mc.character_name,''),
                                    'memory_text',m.memory_text,
                                    'opinion_delta',m.opinion_delta,
                                    'importance',m.importance,
                                    'created_at',m.created_at
                                ) AS memory_json
                            FROM public.discord_npc_memories m
                            LEFT JOIN public.discord_characters mc
                              ON mc.character_id=m.character_id
                            WHERE m.npc_id=n.npc_id
                            ORDER BY m.importance DESC,m.created_at DESC
                            LIMIT 8
                        ) mq
                    ),'[]'::jsonb)
                ) AS npc_json
            FROM public.discord_campaign_npcs n
            LEFT JOIN public.discord_campaign_factions f
              ON f.faction_id=n.faction_id
            WHERE n.campaign_id=p_campaign_id
              AND n.important=TRUE
            ORDER BY n.updated_at DESC
            LIMIT 80
        ) nq
    ),'[]'::jsonb),
    'factions',
    COALESCE((
        SELECT jsonb_agg(faction_json ORDER BY faction_updated DESC)
        FROM (
            SELECT
                f.updated_at AS faction_updated,
                jsonb_build_object(
                    'faction_id',f.faction_id,
                    'faction_name',f.display_name,
                    'description',f.description,
                    'reputations',COALESCE((
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'subject_type',r.subject_type,
                                'character_name',COALESCE(c.character_name,''),
                                'score',r.score,
                                'tier',public.discord_social_tier(r.score),
                                'last_reason',r.last_reason
                            )
                            ORDER BY r.updated_at DESC
                        )
                        FROM public.discord_faction_reputation r
                        LEFT JOIN public.discord_characters c
                          ON c.character_id=r.character_id
                        WHERE r.faction_id=f.faction_id
                    ),'[]'::jsonb),
                    'recent_events',COALESCE((
                        SELECT jsonb_agg(eq.event_json ORDER BY eq.created_at DESC)
                        FROM (
                            SELECT
                                e.created_at,
                                jsonb_build_object(
                                    'subject_type',e.subject_type,
                                    'character_name',COALESCE(ec.character_name,''),
                                    'delta',e.delta,
                                    'reason',e.reason,
                                    'created_at',e.created_at
                                ) AS event_json
                            FROM public.discord_faction_reputation_events e
                            LEFT JOIN public.discord_characters ec
                              ON ec.character_id=e.character_id
                            WHERE e.faction_id=f.faction_id
                            ORDER BY e.created_at DESC
                            LIMIT 8
                        ) eq
                    ),'[]'::jsonb)
                ) AS faction_json
            FROM public.discord_campaign_factions f
            WHERE f.campaign_id=p_campaign_id
            ORDER BY f.updated_at DESC
            LIMIT 80
        ) fq
    ),'[]'::jsonb)
);
$$;

REVOKE ALL ON FUNCTION public.discord_social_key(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_social_tier(INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_social_resolve_character(UUID,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_remember_npc_interaction(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_adjust_faction_reputation(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.discord_gm_get_social_state(UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.discord_social_key(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_social_tier(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_social_resolve_character(UUID,TEXT,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_remember_npc_interaction(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER,INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_adjust_faction_reputation(UUID,TEXT,TEXT,TEXT,TEXT,INTEGER,TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.discord_gm_get_social_state(UUID) TO service_role;

COMMIT;
