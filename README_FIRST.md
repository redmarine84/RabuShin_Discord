# RabuShinAIGM Discord Completion Package

This package is an **overlay for your existing Discord Activity project** at:

`C:\Users\redhe\source\repos\RabuShinAIGM_Discord\RabuShinDiscord`

It is based on the newest RabuShinAIGM v4.2.1 source supplied for the conversion. It does **not** replace your Windows WinForms application. The Windows application and Discord Activity can remain separate.

---

## What this package completes

The Discord Activity package includes the current playable web conversion:

- Discord OAuth identity — no separate RabuShin login for Discord players.
- Persistent multiplayer campaigns in Supabase.
- Start campaign / join with campaign code.
- One character per Discord player per campaign.
- Random Build using the VB.NET `CharacterGenerationService`.
- Manual Sheet character creation.
- Half-species / hybrid heritage handling.
- Existing VB.NET starting-equipment rules.
- Persistent inventory.
- Class cantrip/spell setup and spell slots.
- Wizard spellbook/prepared-spell distinction.
- Warlock Mystic Arcanum handling.
- Character sheet and party list.
- AI Game Master screen.
- RabuShin campaign canon files available to the AI GM.
- Shared AI-GM campaign history.
- Shared campaign chat.
- Personal campaign journal.
- Dice roller, including d20 Advantage and Disadvantage.
- OpenAI API-key settings.
- OpenAI quota/credit errors are shown in the game instead of crashing RabuShin.
- Responsive Discord Activity UI.

### Important scope note

This package completes the **playable Discord conversion path built in this project**. It is not yet a pixel-for-pixel port of every Windows-only v4.2.1 screen. Windows-specific/image-heavy systems such as the full Codex/monster-image browser, settlement/encounter/world-map UI, merchant UI, structured tactical combat controls, portrait editing, and future voice-chat controls are not represented as full Discord web screens in this package. Your original Windows application remains the source for those interfaces.

---

# Folder map

After installation, the package folders map like this:

| Package item | Goes to |
|---|---|
| `client\` | `RabuShinDiscord\client\` |
| `server\` | `RabuShinDiscord\server\` |
| `RabuShinAIGM.Core\` | `RabuShinDiscord\RabuShinAIGM.Core\` |
| `RabuShinAIGM.Server\` | `RabuShinDiscord\RabuShinAIGM.Server\` |
| `SUPABASE_SQL\` | Copied to `RabuShinDiscord\SUPABASE_SQL\` for you to run manually in Supabase |
| `SETUP\` | Copied to `RabuShinDiscord\SETUP\` |
| `.env.example` | Used only if your root `.env` does not already exist |

The automated installer does this mapping for you.

---

# Before installing

Keep your current RabuShin/Discord command windows closed while copying the package.

You need these command-line tools installed:

1. **Node.js** and npm.
2. **.NET 8 SDK**.
3. **cloudflared**.
4. Your existing Discord Developer application/activity.
5. Your existing Supabase RabuShin project.

You can double-click:

`CHECK_PREREQUISITES.cmd`

to verify `node`, `npm`, `dotnet`, and `cloudflared` are visible from Command Prompt.

---

# INSTALLATION — use this order

## 1. Extract the ZIP

Extract the entire package somewhere convenient, for example:

`C:\Users\redhe\Downloads\RabuShin_Discord_Completion_Package`

Do **not** extract it directly on top of your existing project by hand.

---

## 2. Run the package installer

Double-click:

`INSTALL.cmd`

The installer targets your current project automatically:

`C:\Users\redhe\source\repos\RabuShinAIGM_Discord\RabuShinDiscord`

Before overwriting anything it creates a backup inside the project named similar to:

`_backup_before_completion_20260829_123456`

It then overlays:

- `client`
- `server`
- `RabuShinAIGM.Core`
- `RabuShinAIGM.Server`

### Your `.env` is preserved

If this file already exists:

`RabuShinDiscord\.env`

the installer leaves it alone.

Your working `.env` should contain:

```env
VITE_DISCORD_CLIENT_ID=1542881575820202004
DISCORD_CLIENT_SECRET=YOUR_REAL_DISCORD_CLIENT_SECRET
```

Never put the Discord Client Secret in `client\main.js`, GitHub, or chat messages.

---

# 3. Upgrade Supabase

Open your existing RabuShin Supabase project.

Go to:

**SQL Editor → New Query**

Open this file from your installed project:

`C:\Users\redhe\source\repos\RabuShinAIGM_Discord\RabuShinDiscord\SUPABASE_SQL\01_DISCORD_FULL_SETUP.sql`

Copy the **entire file** into the Supabase SQL Editor and click **Run**.

The script is designed to upgrade the tables created during our earlier steps. It does not intentionally delete your campaign or character tables/data.

It adds/preserves the Discord data needed for:

- campaigns
- members
- characters
- inventory
- spells
- spell slots
- campaign chat
- AI-GM timeline
- journal
- setup state

It also locks the `discord_*` database functions and tables to the trusted server/service role instead of exposing them directly to the Activity browser.

If Supabase says `Success. No rows returned`, that is normal.

---

# 4. Configure ASP.NET server secrets

Double-click:

`SETUP_SERVER_SECRETS.cmd`

The script stores secrets in **.NET User Secrets**, not in JavaScript and not in Supabase tables.

It will configure the Supabase URL automatically:

`https://yrysfedvqtwvqxmlxymg.supabase.co`

Then it asks for your Supabase server secret.

Use your trusted Supabase key beginning with something similar to:

`sb_secret_...`

Do not use the publishable browser key here.

## OpenAI choice

The setup script then asks whether you want one permanent server-side OpenAI API key.

### Choose Y

If you want your RabuShin server to use one OpenAI key for the family/game group. Players will not need to type a key into the Activity.

### Choose N

If each player should use the **Settings** tab inside RabuShin to enter an API key for that server run.

A key entered through the Activity is kept only in ASP.NET server memory and is not stored in Supabase or browser storage.

---

# 5. Build the complete project

Double-click:

`BUILD_ALL.cmd`

It installs the Node packages and compiles the VB.NET Core and ASP.NET server.

You want to finish with:

`BUILD SUCCEEDED`

If this build reports a compiler error, stop there and use the **first error in the output** as the one to troubleshoot; later errors can be cascading errors.

---

# 6. Start RabuShin

Double-click:

`START_RABUSHIN.cmd`

It opens four Command Prompt windows:

1. **Discord OAuth server** — `http://localhost:3001`
2. **RabuShin ASP.NET server** — `http://localhost:3002`
3. **Vite Activity client** — `http://localhost:5173`
4. **Cloudflare Quick Tunnel** — public HTTPS URL for Discord

Leave all four windows open while playing.

---

# 7. Update the Discord Activity URL mapping when necessary

The Cloudflare window prints a URL similar to:

`https://example-name.trycloudflare.com`

Your packaged Vite configuration allows `*.trycloudflare.com`, so you no longer need to edit `vite.config.js` every time the Quick Tunnel hostname changes.

However, if Cloudflare gives you a **different hostname**, update the Discord Developer Portal Activity URL Mapping to the new hostname.

Use the hostname as your Activity mapping target the same way you configured the working Activity earlier.

---

# 8. Launch inside Discord

Open the server/voice channel where you have been testing the Developer Activity and launch RabuShin.

Expected flow:

```text
Discord Authentication
        ↓
My Campaigns
        ↓
Create or Join Campaign
        ↓
Play
        ↓
Create Character (only if needed)
        ↓
Starting Equipment (only if needed)
        ↓
Class Spells (only if needed)
        ↓
RabuShin Main Game Screen
```

Existing campaigns and characters should continue to appear because the installer and SQL upgrade are designed around the Discord tables already created during the step-by-step setup.

---

# Main game tabs

## AI Game Master

Send your character's actions to the AI GM. The server sends current campaign/character context, recent GM history, and the included RabuShin canon to OpenAI.

If the OpenAI account runs out of quota/credits or is rate-limited, RabuShin reports the problem in the UI and remains open.

## Character

Shows your character sheet and the other player characters currently created in the campaign.

## Inventory

Shows the starting inventory saved to Supabase and whether an item started equipped.

## Spellbook

Shows saved cantrips/spells and available spell slots.

## Journal

Personal persistent campaign notes.

## Campaign Chat

Shared text chat for all Discord players in the campaign.

## Dice

Standard RPG dice plus d20 Advantage and Disadvantage.

## Settings

Shows OpenAI status and lets a player temporarily enter/replace an API key when no permanent server key is configured.

---

# Existing Discord data

This upgrade is intended to retain:

- your Discord player mapping
- existing campaign IDs
- campaign names
- campaign codes
- campaign memberships
- existing test characters
- starting inventory already accepted

Existing characters that have never completed the newly added spell stage will automatically be routed through spell selection once.

---

# Important security rules

Never expose any of these in the Activity client or GitHub:

- Discord Client Secret
- Supabase `sb_secret_...` key
- permanent OpenAI API key

The browser should only know the public Discord Client ID and its temporary Discord OAuth access token. The ASP.NET server validates that token with Discord before performing player-specific game operations.

---

# Quick local checks

With all services running, you can test these in a browser on the PC hosting RabuShin:

`http://localhost:3001/api/health`

Expected:

```json
{"success":true,"server":"Discord OAuth"}
```

`http://localhost:3002/game-api/health`

Expected JSON includes:

```json
{
  "success": true,
  "game": "RabuShinAIGM"
}
```

You can also run:

`SETUP\VERIFY_LOCAL.ps1`

from PowerShell after all four services are running.

---

# If the Activity says Discord authentication failed

1. Confirm `server` is running on port 3001.
2. Confirm root `.env` contains the correct Discord Client ID and the current Client Secret.
3. If you reset the Discord Client Secret, update `.env` and restart the Node OAuth server.
4. Completely close/relaunch the Activity to get a fresh OAuth authorization code.

---

# If campaigns fail to load

1. Confirm ASP.NET is running on port 3002.
2. Run the entire Supabase SQL upgrade file.
3. Run `SETUP_SERVER_SECRETS.cmd` and make sure the Supabase Secret Key is correct.
4. Restart ASP.NET after changing .NET User Secrets.

---

# If OpenAI does not answer

Go to **Settings** inside the Activity.

If no permanent server API key was configured, enter a valid OpenAI API key there.

If the key is correct but the account has no credits/quota, RabuShin will display the quota problem without closing the game.

---

# Development ports

| Component | Port |
|---|---:|
| Discord OAuth Node server | 3001 |
| RabuShin ASP.NET game server | 3002 |
| Vite Discord Activity client | 5173 |

---

# Backups / rollback

The installer creates a timestamped backup in your existing project before copying the four main folders.

If you need to roll back, close all RabuShin processes and restore the backed-up folders:

- `client`
- `server`
- `RabuShinAIGM.Core`
- `RabuShinAIGM.Server`

The SQL upgrade adds Discord tables/columns/functions but does not intentionally remove your campaigns or characters.

---

# Recommended first test after installation

Use your existing campaign rather than immediately creating another one:

1. Launch RabuShin in Discord.
2. Confirm **PLAYING AS** shows your Discord user.
3. Confirm **My Campaigns** still lists your campaign and campaign code.
4. Click **Play**.
5. Complete any remaining equipment/spell setup requested for the test character.
6. Enter the main game screen.
7. Open **Settings** and confirm OpenAI is configured.
8. Open **AI Game Master** and send a small action such as `I look around the area.`
9. Test **Campaign Chat**.
10. Test **Dice**.

At that point the packaged Discord gameplay loop is installed and running.
