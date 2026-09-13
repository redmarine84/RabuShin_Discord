-- ============================================================
-- RabuShinAIGM Build 6.30.9 Hotfix
-- Migration 68 - Character Library / Death Save Lifecycle
--
-- Purpose:
--   Build 6.30.9 allows discord_characters.campaign_id to be NULL while a
--   character is stored in My Characters. The existing death-save trigger
--   still attempted to create discord_character_death_saves rows on every
--   character INSERT, even for healthy unassigned Library characters.
--
-- Fix:
--   * Do not create death-save state for unassigned characters.
--   * Remove campaign-specific death-save state when a character is detached.
--   * Reinitialize death-save state when a character is assigned to a campaign.
--   * Keep discord_character_death_saves.campaign_id NOT NULL because death
--     saves are campaign/combat state, not Character Library state.
--
-- Safe to rerun.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.discord_sync_character_death_save_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
    v_new_zero_track BOOLEAN:=FALSE;
BEGIN
    -- Character Library characters are allowed to exist without a campaign.
    -- Death-saving throws are campaign/combat state, so no death-save row
    -- should exist while the character is unassigned.
    IF NEW.campaign_id IS NULL THEN
        DELETE FROM public.discord_character_death_saves
        WHERE character_id=NEW.character_id;
        RETURN NEW;
    END IF;

    IF NEW.life_state='alive' AND COALESCE(NEW.current_hp,0)<=0 THEN
        IF TG_OP='INSERT' THEN
            v_new_zero_track:=TRUE;
        ELSE
            v_new_zero_track:=COALESCE(OLD.current_hp,0)>0
                OR COALESCE(OLD.life_state,'alive')<>'alive'
                OR OLD.campaign_id IS DISTINCT FROM NEW.campaign_id;
        END IF;

        IF v_new_zero_track THEN
            INSERT INTO public.discord_character_death_saves(
                character_id,campaign_id,successes,failures,stable,last_roll,last_result,
                last_resolved_round,track_started_at,last_resolved_at,updated_at
            )
            VALUES(NEW.character_id,NEW.campaign_id,0,0,FALSE,NULL,'',NULL,NOW(),NULL,NOW())
            ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO UPDATE
            SET campaign_id=EXCLUDED.campaign_id,
                successes=0,
                failures=0,
                stable=FALSE,
                last_roll=NULL,
                last_result='',
                last_resolved_round=NULL,
                track_started_at=NOW(),
                last_resolved_at=NULL,
                updated_at=NOW();
        ELSE
            INSERT INTO public.discord_character_death_saves(
                character_id,campaign_id,track_started_at
            )
            VALUES(NEW.character_id,NEW.campaign_id,NOW())
            ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO NOTHING;
        END IF;
    ELSIF COALESCE(NEW.current_hp,0)>0 THEN
        INSERT INTO public.discord_character_death_saves(
            character_id,campaign_id,successes,failures,stable,last_roll,last_result,
            last_resolved_round,track_started_at,last_resolved_at,updated_at
        )
        VALUES(NEW.character_id,NEW.campaign_id,0,0,FALSE,NULL,'',NULL,NOW(),NULL,NOW())
        ON CONFLICT ON CONSTRAINT discord_character_death_saves_pkey DO UPDATE
        SET campaign_id=EXCLUDED.campaign_id,
            successes=0,
            failures=0,
            stable=FALSE,
            last_roll=NULL,
            last_result='',
            last_resolved_round=NULL,
            track_started_at=NOW(),
            last_resolved_at=NULL,
            updated_at=NOW();
    END IF;

    RETURN NEW;
END;
$$;

-- campaign_id must be part of the trigger so detaching/assigning a stored
-- character performs the death-save lifecycle cleanup/reinitialization.
DROP TRIGGER IF EXISTS trg_discord_character_death_save_state
ON public.discord_characters;

CREATE TRIGGER trg_discord_character_death_save_state
AFTER INSERT OR UPDATE OF current_hp,life_state,campaign_id
ON public.discord_characters
FOR EACH ROW
EXECUTE FUNCTION public.discord_sync_character_death_save_state();

-- Clean up any stale campaign-specific rows belonging to characters that are
-- currently sitting unassigned in My Characters.
DELETE FROM public.discord_character_death_saves ds
USING public.discord_characters c
WHERE ds.character_id=c.character_id
  AND c.campaign_id IS NULL;

-- If a character was moved between campaigns before this hotfix was applied,
-- make sure its death-save row points at its current campaign and starts clean.
UPDATE public.discord_character_death_saves ds
SET campaign_id=c.campaign_id,
    successes=0,
    failures=0,
    stable=FALSE,
    last_roll=NULL,
    last_result='',
    last_resolved_round=NULL,
    track_started_at=NOW(),
    last_resolved_at=NULL,
    updated_at=NOW()
FROM public.discord_characters c
WHERE ds.character_id=c.character_id
  AND c.campaign_id IS NOT NULL
  AND ds.campaign_id IS DISTINCT FROM c.campaign_id;

NOTIFY pgrst,'reload schema';

COMMIT;
