BEGIN;
DROP FUNCTION IF EXISTS public.discord_craft_recipe(UUID,UUID,TEXT);
DROP FUNCTION IF EXISTS public.discord_get_crafting_state(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_crafting_material_family(TEXT,JSONB);
DROP TABLE IF EXISTS public.discord_crafting_events;
DROP TABLE IF EXISTS public.discord_crafting_recipes;
COMMIT;
