-- ============================================================
-- RabuShinAIGM Build 6.29 / Migration 63 rollback
--
-- Removes Build 6.29 dynamic-economy state/functions.
-- Completed trades, currency changes, purchased items, claimed commissions,
-- and Masterwork metadata already written to inventory are NOT reversed.
-- Pending commission rows are removed with the Build 6.29 order table.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.discord_economy_set_item_condition(UUID,INTEGER);
DROP FUNCTION IF EXISTS public.discord_economy_claim_order(UUID,UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_economy_blacksmith_service(UUID,UUID,TEXT,UUID,TEXT,TEXT,NUMERIC,UUID);
DROP FUNCTION IF EXISTS public.discord_economy_sell(UUID,UUID,UUID,INTEGER,BOOLEAN,TEXT,TEXT,TEXT,NUMERIC,TEXT,JSONB);
DROP FUNCTION IF EXISTS public.discord_economy_buy(UUID,UUID,UUID,INTEGER);
DROP FUNCTION IF EXISTS public.discord_economy_get_shop(UUID,UUID,UUID,JSONB,JSONB);
DROP FUNCTION IF EXISTS public.discord_economy_seed_shop(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB);
DROP FUNCTION IF EXISTS public.discord_economy_refresh_shop(UUID);
DROP FUNCTION IF EXISTS public.discord_economy_material_demand_multiplier(TEXT,TEXT);
DROP FUNCTION IF EXISTS public.discord_economy_condition_multiplier(INTEGER);
DROP FUNCTION IF EXISTS public.discord_economy_scarcity_multiplier(INTEGER,INTEGER);
DROP FUNCTION IF EXISTS public.discord_economy_sell_reputation_multiplier(INTEGER);
DROP FUNCTION IF EXISTS public.discord_economy_buy_reputation_multiplier(INTEGER);
DROP FUNCTION IF EXISTS public.discord_economy_reputation_label(INTEGER);
DROP FUNCTION IF EXISTS public.discord_economy_reputation_score(UUID,UUID);
DROP FUNCTION IF EXISTS public.discord_economy_wealth_cap(TEXT,NUMERIC);
DROP FUNCTION IF EXISTS public.discord_economy_settlement_multiplier(TEXT);

DROP TABLE IF EXISTS public.discord_blacksmith_orders;
DROP TABLE IF EXISTS public.discord_economy_transactions;
DROP TABLE IF EXISTS public.discord_item_condition;
DROP TABLE IF EXISTS public.discord_economy_stock;
DROP TABLE IF EXISTS public.discord_economy_shops;

NOTIFY pgrst,'reload schema';

COMMIT;
