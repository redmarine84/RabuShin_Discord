import { DiscordSDK } from '@discord/embedded-app-sdk';
import './style.css';

const discordSdk = new DiscordSDK(import.meta.env.VITE_DISCORD_CLIENT_ID);
let discordAuth = null;
let discordAccessToken = null;
let currentDiscordUser = null;
let currentCampaignId = null;
let currentGameData = null;
let selectedInventoryId = null;
const portraitObjectUrls = new Map();
let currentWorldMapData = null; // VISUALS BUILD 2 - WORLD MAP CLIENT
let currentLocalMapData = null; // VISUALS BUILD 3 - LOCAL MAP CLIENT
let currentCombatData = null; // VISUALS BUILD 4 - MONSTER COMBAT CLIENT
let currentTacticalCombatData = null; // VISUALS BUILD 5 - TACTICAL COMBAT CLIENT
let currentTacticalMapData = null;
let tacticalCombatRefreshTimer = null;
let tacticalSelectedTokenId = null;
let tacticalZoom = 1;
let tacticalLastSignature = '';
let tacticalShowTerrainDebug = false; // VISUALS BUILD 5.1 - TERRAIN CLIENT

// MULTIPLAYER LIVE CHAT + AI GM TURN LEASE
let activeGameTab = 'gm';
let conversationLiveSyncTimer = null;
let conversationLiveSyncBusy = false;
let gmTurnCountdownTimer = null;
let gmTurnState = null;
let gmCombatTurnState = null; // COMBAT BUILD 6.1 - strict initiative state shown in GM composer
let gmTurnToken = null;
let gmTurnAcquirePending = false;
let gmTurnInputHeartbeatPending = false;
let gmTurnInputHeartbeatQueued = false;
let gmTurnSubmitting = false;
let gmTurnDraft = '';
let campaignChatDraft = '';
let gmMessageSignature = '';
let chatMessageSignature = '';

// RULES BUILD 6.2 - DEATH / RESPAWN LIVE STATE
// RULES BUILD 6.14.2 - ACTIVE PLAYER 1 GP RESPAWN DONATIONS
let deathStatePollTimer = null;
let deathStatePollBusy = false;
let deathActionBusy = false;
let lastDeathState = null;
let deathDonationMode = false;

// RULES BUILD 6.3 - EXPERIENCE / REST-GATED LEVELING
let progressionPollTimer = null;
let progressionPollBusy = false;
let currentProgression = null;
let levelUpActionBusy = false;
let levelUpOverlaySignature = '';
let levelUpSpellRecoveryBusy = false;

// RULES BUILD 6.4 - SHORT / LONG REST RESOLUTION
let restStatePollTimer = null;
let restStatePollBusy = false;
let restActionBusy = false;
let lastRestState = null;
let restOverlaySignature = '';

// RULES BUILD 6.8 - SURVIVAL / ENCUMBRANCE
let survivalPollTimer = null;
let survivalPollBusy = false;

// RULES BUILD 6.16 - WORLD TIME / SLEEPING LONG REST
let worldTimePollTimer = null;
let worldTimePollBusy = false;
let sleepStatePollTimer = null;
let sleepStatePollBusy = false;
let sleepWakeBusy = false;
let lastSleepState = null;
let sleepOverlaySignature = '';


// RULES BUILD 6.12 - AI GAME MASTER VOICE
// Voice preferences are intentionally local to each Discord player/device.
// No speech audio is generated or stored by the RabuShin server.
let gmVoicePreferences = null;
let gmVoicePreferencesOwnerId = '';
let gmVoiceAvailableVoices = [];
let gmVoiceBaselineInitialized = false;
let gmVoiceLastSeenMessageKey = '';
let gmVoiceCurrentMessageKey = '';
let gmVoiceVoicesChangedBound = false;

const app = document.querySelector('#app');
const publicSiteBase = (import.meta.env.VITE_PUBLIC_SITE_BASE_URL || 'https://redmarine84.github.io/Quests-of-Rabu-Shin/').replace(/\/$/, '');
const legalUrls = {
  terms: `${publicSiteBase}/terms.html`,
  privacy: `${publicSiteBase}/privacy.html`,
  support: `${publicSiteBase}/support.html`,
  deletion: `${publicSiteBase}/data-deletion.html`,
  licenses: `${publicSiteBase}/licenses.html`,
};

async function openExternal(url) {
  try {
    await discordSdk.commands.openExternalLink({ url });
  } catch (error) {
    console.error('Unable to open external link through Discord:', error);
    showNotice('Discord could not open the external link.', true);
  }
}


function shell(content = '') {
  app.innerHTML = `
    <div class="app-shell">
      <header class="topbar">
        <div>
          <h1>RabuShin AI Game Master</h1>
          <div class="subtitle">The Quests of Rabu Shin: Tales of the Krasis</div>
        </div>
        <div class="topbar-right">
          <div id="discordUser" class="identity">Connecting to Discord...</div>
          <div id="serverStatus" class="status">Checking Server...</div>
        </div>
      </header>
      <main id="mainContent" class="content">${content}</main>
    </div>`;
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function formatSigned(value) {
  const n = Number(value || 0);
  return n >= 0 ? `+${n}` : `${n}`;
}

function abilityMod(score) {
  return Math.floor((Number(score) - 10) / 2);
}

async function readResponse(response) {
  const text = await response.text();
  if (!text) {
    if (response.ok) return {};
    throw new Error(`HTTP ${response.status}: server returned an empty response.`);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`HTTP ${response.status}: server returned invalid JSON: ${text.slice(0, 300)}`);
  }
}

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (discordAccessToken) headers.set('Authorization', `Bearer ${discordAccessToken}`);
  const isFormData = typeof FormData !== 'undefined' && options.body instanceof FormData;
  if (options.body && !isFormData && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  const response = await fetch(path, { ...options, headers });
  const data = await readResponse(response);
  if (!response.ok || data.success === false) {
    const error = new Error(data.error || `Request failed: HTTP ${response.status}`);
    error.status = response.status;
    error.data = data;
    throw error;
  }
  return data;
}

function showNotice(message, danger = false) {
  document.querySelector('#notice')?.remove();
  const el = document.createElement('div');
  el.id = 'notice';
  el.className = `notice${danger ? ' danger' : ''}`;
  el.textContent = message;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 4500);
}

async function checkServer() {
  try {
    const response = await fetch('/game-api/health');
    const data = await readResponse(response);
    const el = document.querySelector('#serverStatus');
    if (el) {
      el.textContent = data.success ? 'RabuShin Server Online' : 'RabuShin Server Offline';
      el.classList.toggle('online', !!data.success);
      el.classList.toggle('offline', !data.success);
    }
  } catch {
    const el = document.querySelector('#serverStatus');
    if (el) {
      el.textContent = 'RabuShin Server Offline';
      el.classList.add('offline');
    }
  }
}

async function setupDiscord() {
  const userBox = document.querySelector('#discordUser');
  try {
    if (!import.meta.env.VITE_DISCORD_CLIENT_ID) throw new Error('VITE_DISCORD_CLIENT_ID is missing from .env.');
    userBox.textContent = 'Connecting to Discord...';
    await discordSdk.ready();

    const { code } = await discordSdk.commands.authorize({
      client_id: import.meta.env.VITE_DISCORD_CLIENT_ID,
      response_type: 'code',
      state: '',
      prompt: 'none',
      scope: ['identify'],
    });

    const tokenResponse = await fetch('/api/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code }),
    });
    const tokenData = await readResponse(tokenResponse);
    if (!tokenResponse.ok || !tokenData.access_token) throw new Error(tokenData.error_description || tokenData.error || 'Discord token exchange failed.');

    discordAccessToken = tokenData.access_token;
    discordAuth = await discordSdk.commands.authenticate({ access_token: discordAccessToken });
    if (!discordAuth?.user) throw new Error('Discord returned no authenticated user.');
    currentDiscordUser = discordAuth.user;

    const displayName = currentDiscordUser.global_name || currentDiscordUser.username;
    userBox.innerHTML = `<span>PLAYING AS</span><strong>${escapeHtml(displayName)}</strong><small>@${escapeHtml(currentDiscordUser.username)}</small>`;
    await showCampaignLauncher();
  } catch (error) {
    console.error(error);
    userBox.innerHTML = `<span>DISCORD ERROR</span><strong>${escapeHtml(error.message)}</strong>`;
    document.querySelector('#mainContent').innerHTML = `<section class="panel"><h2>Unable to Start RabuShin</h2><p>${escapeHtml(error.message)}</p></section>`;
  }
}

async function showCampaignLauncher() {
  stopGmVoicePlayback();
  gmVoiceBaselineInitialized=false;
  gmVoiceLastSeenMessageKey='';
  clearPortraitCache();
  currentCampaignId = null;
  currentGameData = null;
  currentTacticalCombatData = null;
  currentTacticalMapData = null;
  tacticalSelectedTokenId = null;
  tacticalLastSignature = '';
  stopTacticalCombatPolling();
  stopConversationLiveSync();
  stopDeathStatePolling();
  stopProgressionPolling();
  stopRestStatePolling();
  stopSurvivalPolling();
  stopWorldTimePolling();
  stopSleepStatePolling();
  document.querySelector('#deathOverlay')?.remove();
  document.body.classList.remove('death-modal-open');
  document.querySelector('#levelUpOverlay')?.remove();
  document.querySelector('#restOverlay')?.remove();
  currentProgression=null;
  levelUpOverlaySignature='';
  levelUpSpellRecoveryBusy=false;
  lastDeathState=null;
  lastRestState=null;
  restOverlaySignature='';
  lastSleepState=null;
  sleepOverlaySignature='';
  document.querySelector('#sleepOverlay')?.remove();
  activeGameTab = 'gm';
  gmTurnState = null;
  gmTurnToken = null;
  gmTurnDraft = '';
  campaignChatDraft = '';
  currentCombatData = null;
  currentLocalMapData = null;
  currentWorldMapData = null;
  const main = document.querySelector('#mainContent');
  const name = currentDiscordUser?.global_name || currentDiscordUser?.username || 'Player';
  main.innerHTML = `
    <div class="launcher">
      <section class="welcome">
        <h2>Welcome, ${escapeHtml(name)}</h2>
        <p>Continue a campaign, create a new adventure, or join with a campaign code.</p>
      </section>
      <section class="panel">
        <div class="panel-header"><div><h3>My Campaigns</h3><p>Campaigns you own or have joined.</p></div><button id="refreshCampaigns" class="button small">Refresh</button></div>
        <div id="campaignList" class="campaign-list"><div class="loading">Loading campaigns...</div></div>
      </section>
      <div class="launcher-actions">
        <button id="newCampaign" class="action primary"><b>＋ Start New Campaign</b><span>Create a new multiplayer adventure</span></button>
        <button id="joinCampaign" class="action"><b># Join With Campaign Code</b><span>Enter a code from another player</span></button>
      </div>
      <div class="public-legal-note">By using RabuShinAIGM, you agree to the <button class="link-button" data-legal="terms">Terms of Service</button> and acknowledge the <button class="link-button" data-legal="privacy">Privacy Policy</button>. <button class="link-button" data-legal="support">Support</button></div>
    </div>`;

  document.querySelector('#refreshCampaigns').onclick = loadCampaigns;
  document.querySelector('#newCampaign').onclick = showNewCampaignDialog;
  document.querySelector('#joinCampaign').onclick = showJoinCampaignDialog;
  document.querySelectorAll('[data-legal]').forEach(button => button.onclick = () => openExternal(legalUrls[button.dataset.legal]));
  await loadCampaigns();
}

async function loadCampaigns() {
  const list = document.querySelector('#campaignList');
  if (!list) return;
  list.innerHTML = '<div class="loading">Loading campaigns...</div>';
  try {
    const data = await api('/game-api/campaigns');
    if (!data.campaigns?.length) {
      list.innerHTML = '<div class="empty"><div class="empty-icon">⚔</div><b>No campaigns yet</b><span>Start a new campaign or join one with a campaign code.</span></div>';
      return;
    }
    list.innerHTML = data.campaigns.map(c => `
      <div class="campaign-card">
        <div>
          <h4>${escapeHtml(c.campaignName)}</h4>
          <p>Chapter ${c.currentChapter} • ${escapeHtml(c.currentLocation)} • ${c.memberCount} Player${c.memberCount === 1 ? '' : 's'}</p>
          <small>Campaign Code: <strong>${escapeHtml(c.joinCode)}</strong></small>
        </div>
        <div class="row gap campaign-actions">
          ${c.isOwner ? '<span class="badge">OWNER</span>' : ''}
          <button class="button play" data-id="${c.campaignId}">Play</button>
          ${c.isOwner
            ? `<button class="button danger delete-campaign" data-id="${c.campaignId}" data-name="${escapeHtml(c.campaignName)}">Delete Campaign</button>`
            : `<button class="button danger leave-campaign" data-id="${c.campaignId}" data-name="${escapeHtml(c.campaignName)}">Leave Campaign</button>`}
        </div>
      </div>`).join('');
    document.querySelectorAll('.play').forEach(b => b.onclick = () => openCampaign(b.dataset.id));
    document.querySelectorAll('.delete-campaign').forEach(b => b.onclick = () => showDeleteCampaignDialog(b.dataset.id, b.dataset.name));
    document.querySelectorAll('.leave-campaign').forEach(b => b.onclick = () => showLeaveCampaignDialog(b.dataset.id, b.dataset.name));
  } catch (error) {
    list.innerHTML = `<div class="empty danger-text">${escapeHtml(error.message)}</div>`;
  }
}

function showModal(title, body, confirmText, onConfirm) {
  document.querySelector('#modalOverlay')?.remove();
  const overlay = document.createElement('div');
  overlay.id = 'modalOverlay';
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `<div class="modal"><h3>${escapeHtml(title)}</h3>${body}<div class="modal-actions"><button id="modalCancel" class="button">Cancel</button><button id="modalConfirm" class="button primary">${escapeHtml(confirmText)}</button></div><div id="modalError" class="error"></div></div>`;
  document.body.appendChild(overlay);
  document.querySelector('#modalCancel').onclick = () => overlay.remove();
  document.querySelector('#modalConfirm').onclick = async () => {
    try { await onConfirm(); } catch (error) { document.querySelector('#modalError').textContent = error.message; }
  };
}

function showDeleteCampaignDialog(campaignId, campaignName) {
  showModal(
    'Delete Campaign',
    `<div class="destructive-warning">
      <p><strong>This permanently deletes ${escapeHtml(campaignName)} for every player.</strong></p>
      <p>The campaign, characters, inventories, spellbooks, journal entries, chat/GM history, party membership, and campaign progress will be removed. This cannot be undone.</p>
    </div>
    <label>Type the campaign name exactly to confirm</label>
    <input id="deleteCampaignConfirm" class="input" autocomplete="off" placeholder="${escapeHtml(campaignName)}">`,
    'Delete Campaign',
    async () => {
      const typed = document.querySelector('#deleteCampaignConfirm')?.value?.trim() || '';
      if (typed !== campaignName) throw new Error('Enter the campaign name exactly to confirm deletion.');
      await api(`/game-api/campaigns/${campaignId}`, { method: 'DELETE' });
      document.querySelector('#modalOverlay')?.remove();
      showNotice(`Campaign "${campaignName}" was deleted.`);
      await loadCampaigns();
    }
  );
  const confirm = document.querySelector('#modalConfirm');
  if (confirm) confirm.className = 'button danger';
}

function showLeaveCampaignDialog(campaignId, campaignName) {
  showModal(
    'Leave Campaign',
    `<div class="destructive-warning">
      <p><strong>Leave ${escapeHtml(campaignName)}?</strong></p>
      <p>Your character and personal journal entries for this campaign will be deleted. The campaign and other players remain unchanged. Shared campaign/chat history remains with the campaign.</p>
    </div>`,
    'Leave Campaign',
    async () => {
      await api(`/game-api/campaigns/${campaignId}/leave`, { method: 'POST' });
      document.querySelector('#modalOverlay')?.remove();
      showNotice(`You left "${campaignName}".`);
      await loadCampaigns();
    }
  );
  const confirm = document.querySelector('#modalConfirm');
  if (confirm) confirm.className = 'button danger';
}

function showNewCampaignDialog() {
  showModal('Start New Campaign', `<label>Campaign Name</label><input id="campaignName" class="input" maxlength="80" placeholder="My Rabu Shin Campaign">`, 'Create Campaign', async () => {
    const name = document.querySelector('#campaignName').value.trim();
    if (!name) throw new Error('Campaign name is required.');
    await api('/game-api/campaigns', { method: 'POST', body: JSON.stringify({ campaignName: name }) });
    document.querySelector('#modalOverlay').remove();
    showNotice('Campaign created.');
    await loadCampaigns();
  });
}

function showJoinCampaignDialog() {
  showModal('Join Campaign', `<label>Campaign Code</label><input id="campaignCode" class="input mono" maxlength="64" placeholder="REDMARINEUSMC-XXXXXXXX">`, 'Join Campaign', async () => {
    const code = document.querySelector('#campaignCode').value.trim();
    if (!code) throw new Error('Campaign code is required.');
    await api('/game-api/campaigns/join', { method: 'POST', body: JSON.stringify({ joinCode: code }) });
    document.querySelector('#modalOverlay').remove();
    showNotice('Campaign joined.');
    await loadCampaigns();
  });
}

async function openCampaign(campaignId) {
  try {
    currentCampaignId = campaignId;
    const data = await api(`/game-api/campaigns/${campaignId}/character`);
    if (!data.hasCharacter) return showCharacterCreator(campaignId);
    await continueCharacterSetup(campaignId, data.character);
  } catch (error) { showNotice(error.message, true); }
}

async function continueCharacterSetup(campaignId, character) {
  try {
    const state = await api(`/game-api/campaigns/${campaignId}/character/setup`);
    if (!state.equipmentComplete) return showStartingEquipment(campaignId, character);
    if (!state.spellsComplete) return showSpellSelection(campaignId, character);
    await enterCampaign(campaignId);
  } catch (error) { showNotice(error.message, true); }
}

function manualAbilityInput(label, id) {
  return `<div class="ability-input"><label>${label}</label><input id="${id}" type="number" min="1" max="20" value="10"></div>`;
}

function populateSelect(selector, values) {
  const select = document.querySelector(selector);
  select.innerHTML = (values || []).map(v => `<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`).join('');
}

// RULES BUILD 6.13.1 - FULL HYBRID HERITAGE INHERITANCE
function primaryRaceName(species) {
  const value=String(species||'').trim();
  return value.startsWith('Half ')?value.substring(5).trim():value;
}

function isTortleRace(species){return primaryRaceName(species).toLowerCase()==='tortle';}

function subraceRulesForHeritage(heritage,data){
  const rules=data?.racialRules?.subraces?.[String(heritage||'').trim()];
  return Array.isArray(rules)?rules:[];
}

function subraceRulesFor(species,data){return subraceRulesForHeritage(primaryRaceName(species),data);}

function selectedSubraceRule(species,name,data){
  return subraceRulesFor(species,data).find(r=>String(r?.name||'').toLowerCase()===String(name||'').toLowerCase())||null;
}

function subraceDetailHtml(prefix,species,name,data){
  const rule=selectedSubraceRule(species,name,data);
  if(!rule)return '';
  const bonuses=rule.abilityBonuses&&typeof rule.abilityBonuses==='object'
    ?Object.entries(rule.abilityBonuses).map(([ability,bonus])=>`${ability} +${bonus}`).join(' • '):'';
  const traits=Array.isArray(rule.traits)?rule.traits:[];
  const highElf=String(rule.name||'').toLowerCase()==='high elf';
  const cantrips=(data?.racialRules?.highElfWizardCantrips||[]).map(v=>`<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`).join('');
  return `<div class="subrace-summary">
    <b>${escapeHtml(rule.name)}</b>
    ${bonuses?`<small>Additional Ability Increase: ${escapeHtml(bonuses)}</small>`:''}
    ${Number(rule.speedOverride)>0?`<small>Walking Speed: ${Number(rule.speedOverride)} ft.</small>`:''}
    ${Number(rule.hitPointBonusPerLevel)>0?`<small>Maximum HP: +${Number(rule.hitPointBonusPerLevel)} per character level</small>`:''}
    ${traits.length?`<div class="subrace-traits">${traits.map(t=>`<span>${escapeHtml(t)}</span>`).join('')}</div>`:''}
    ${highElf?`<div class="form-grid racial-choice-grid subrace-extra-choices">
      <div><label>High Elf Wizard Cantrip</label><select id="${prefix}HighElfCantrip" class="input">${cantrips}</select></div>
      <div><label>High Elf Extra Language</label><input id="${prefix}HighElfLanguage" class="input" placeholder="Example: Draconic"></div>
    </div>`:''}
  </div>`;
}

function dragonbornAncestryDetailHtml(ancestry){
  if(!ancestry)return '';
  return `<div class="subrace-summary ancestry-summary">
    <b>${escapeHtml(ancestry.name)} Dragon Ancestry</b>
    <small>Breath Weapon: ${escapeHtml(ancestry.damageType)} • ${escapeHtml(ancestry.area)} • ${escapeHtml(ancestry.savingThrow)} save</small>
    <small>Damage Resistance: ${escapeHtml(ancestry.resistance)}</small>
    <small>Breath damage: 2d6 at level 1, 3d6 at 6th, 4d6 at 11th, 5d6 at 16th. Save DC = 8 + CON modifier + proficiency bonus. One use per short or long rest.</small>
  </div>`;
}

function tortleChoiceFieldsHtml(optionPrefix,data,labelPrefix=''){
  const t=data?.racialRules?.tortle||{};
  const abilityOptions=(data?.racialRules?.abilityNames||['Strength','Dexterity','Constitution','Intelligence','Wisdom','Charisma']).map(a=>`<option value="${escapeHtml(a)}">${escapeHtml(a)}</option>`).join('');
  const skills=(t.natureSkills||['Animal Handling','Medicine','Nature','Perception','Stealth','Survival']).map(a=>`<option value="${escapeHtml(a)}">${escapeHtml(a)}</option>`).join('');
  return `<div class="racial-choice-section tortle-choice-section">
    <small>${escapeHtml(labelPrefix)}Natural Armor (base AC 17), 1d6 claws, Hold Breath, Nature's Intuition, and Shell Defense are inherited.</small>
    <div class="form-grid racial-choice-grid">
      <div><label>Ability Increase Pattern</label><select id="${optionPrefix}TortlePattern" class="input"><option value="21">+2 / +1</option><option value="111">+1 / +1 / +1</option></select></div>
      <div><label>Tortle Size Choice</label><select id="${optionPrefix}TortleSize" class="input"><option>Medium</option><option>Small</option></select></div>
      <div><label id="${optionPrefix}AbilityALabel">+2 Ability</label><select id="${optionPrefix}AbilityA" class="input">${abilityOptions}</select></div>
      <div><label>+1 Ability</label><select id="${optionPrefix}AbilityB" class="input">${abilityOptions}</select></div>
      <div id="${optionPrefix}AbilityCBox" hidden><label>+1 Ability</label><select id="${optionPrefix}AbilityC" class="input">${abilityOptions}</select></div>
      <div><label>Nature's Intuition</label><select id="${optionPrefix}TortleSkill" class="input">${skills}</select></div>
      <div><label>Additional Language</label><input id="${optionPrefix}TortleLanguage" class="input" value="${escapeHtml(t.defaultLanguage||'Aquan')}"></div>
    </div>
  </div>`;
}

function wireTortleChoiceFields(optionPrefix,saved={}){
  const pattern=document.querySelector(`#${optionPrefix}TortlePattern`);
  if(!pattern)return;
  const updatePattern=()=>{
    const three=pattern.value==='111';
    const cBox=document.querySelector(`#${optionPrefix}AbilityCBox`);
    const aLabel=document.querySelector(`#${optionPrefix}AbilityALabel`);
    if(cBox)cBox.hidden=!three;
    if(aLabel)aLabel.textContent=three?'+1 Ability':'+2 Ability';
  };
  if(saved.tortlePattern)pattern.value=saved.tortlePattern;
  pattern.onchange=updatePattern; updatePattern();
  const a=document.querySelector(`#${optionPrefix}AbilityA`),b=document.querySelector(`#${optionPrefix}AbilityB`),c=document.querySelector(`#${optionPrefix}AbilityC`);
  if(a)a.value=saved.abilityA||'Strength';
  if(b)b.value=saved.abilityB||'Wisdom';
  if(c)c.value=saved.abilityC||'Constitution';
  const size=document.querySelector(`#${optionPrefix}TortleSize`),skill=document.querySelector(`#${optionPrefix}TortleSkill`),language=document.querySelector(`#${optionPrefix}TortleLanguage`);
  if(size&&saved.tortleSize)size.value=saved.tortleSize;
  if(skill&&saved.tortleSkill)skill.value=saved.tortleSkill;
  if(language&&saved.tortleLanguage)language.value=saved.tortleLanguage;
}

function collectTortleChoiceFields(optionPrefix,label){
  const pattern=document.querySelector(`#${optionPrefix}TortlePattern`)?.value;
  if(!pattern)return null;
  const a=document.querySelector(`#${optionPrefix}AbilityA`)?.value;
  const b=document.querySelector(`#${optionPrefix}AbilityB`)?.value;
  const c=document.querySelector(`#${optionPrefix}AbilityC`)?.value;
  const selected=pattern==='111'?[a,b,c]:[a,b];
  if(selected.some(v=>!v))throw new Error(`Choose all ${label} Tortle ability increases.`);
  if(new Set(selected).size!==selected.length)throw new Error(`Each ${label} Tortle ability increase must use a different ability score.`);
  const abilityChoices={};
  if(pattern==='111'){abilityChoices[a]=1;abilityChoices[b]=1;abilityChoices[c]=1;}
  else {abilityChoices[a]=2;abilityChoices[b]=1;}
  return {
    abilityChoices,
    size:document.querySelector(`#${optionPrefix}TortleSize`)?.value||'Medium',
    skill:document.querySelector(`#${optionPrefix}TortleSkill`)?.value||'Survival',
    language:document.querySelector(`#${optionPrefix}TortleLanguage`)?.value?.trim()||'Aquan'
  };
}

function racialOptionsHtml(prefix,species,data){
  const heritage=primaryRaceName(species);
  const fixed=data?.racialRules?.fixedBonuses?.[heritage]||null;
  const half=String(species||'').startsWith('Half ');
  const halfNote=half?`<p class="racial-note">Hybrid Heritage: both racial halves now contribute their base racial traits and ability-score increases. If either half has a subrace or Draconic Ancestry, that half receives its own choice below.</p>`:'';
  if(isTortleRace(species)){
    return `${halfNote}<div class="racial-rule-card"><b>${half?'Primary Half':'Racial Heritage'}: Tortle</b>${tortleChoiceFieldsHtml(prefix,data,'')}</div>`;
  }

  const parts=[halfNote,`<div class="racial-rule-card"><b>${half?'Primary Half':'Racial Heritage'}: ${escapeHtml(heritage)}</b>`];
  if(fixed){
    const text=Object.entries(fixed).map(([ability,bonus])=>`${ability} +${bonus}`).join(' • ');
    parts.push(`<small>Base ${escapeHtml(heritage)} Ability Increase: ${escapeHtml(text)}</small>`);
  } else {
    parts.push(`<small>Base ${escapeHtml(heritage)} racial traits remain in effect.</small>`);
  }

  const subraces=subraceRulesFor(species,data);
  if(subraces.length){
    parts.push(`<div class="racial-choice-section"><label>${half?'Primary ':''}Subrace</label><select id="${prefix}Subrace" class="input">${subraces.map(r=>`<option value="${escapeHtml(r.name)}">${escapeHtml(r.name)}</option>`).join('')}</select><div id="${prefix}SubraceDetails"></div></div>`);
  }

  if(heritage.toLowerCase()==='dragonborn'){
    const ancestries=data?.racialRules?.dragonbornAncestries||[];
    parts.push(`<div class="racial-choice-section"><label>${half?'Primary ':''}Draconic Ancestry</label><select id="${prefix}DragonbornAncestry" class="input">${ancestries.map(a=>`<option value="${escapeHtml(a.name)}">${escapeHtml(a.name)} — ${escapeHtml(a.damageType)}</option>`).join('')}</select><div id="${prefix}DragonbornAncestryDetails"></div></div>`);
  }

  if(heritage.toLowerCase()==='dwarf'){
    const tools=data?.racialRules?.dwarfTools||["Smith's Tools","Brewer's Supplies","Mason's Tools"];
    parts.push(`<div class="racial-choice-section"><label>Dwarven Tool Proficiency</label><select id="${prefix}DwarfTool" class="input">${tools.map(v=>`<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`).join('')}</select></div>`);
  }

  parts.push('</div>');
  return parts.join('');
}

function secondaryHeritageOptionsHtml(prefix,species,data){
  if(!String(species||'').startsWith('Half '))return '';
  const secondary=document.querySelector(`#${prefix}Half`)?.value||'';
  if(!secondary)return '';
  const fixed=data?.racialRules?.fixedBonuses?.[secondary]||null;
  const baseTraits=Array.isArray(data?.racialRules?.traitSummaries?.[secondary])?data.racialRules.traitSummaries[secondary]:[];
  const parts=[`<div class="racial-rule-card secondary-heritage-card"><b>Other Half: ${escapeHtml(secondary)}</b>`];
  if(fixed){
    const text=Object.entries(fixed).map(([ability,bonus])=>`${ability} +${bonus}`).join(' • ');
    parts.push(`<small>Base ${escapeHtml(secondary)} Ability Increase: ${escapeHtml(text)} — compounds with the primary half.</small>`);
  } else {
    parts.push(`<small>The ${escapeHtml(secondary)} half's base racial traits are inherited.</small>`);
  }
  if(baseTraits.length)parts.push(`<div class="subrace-traits">${baseTraits.map(t=>`<span>${escapeHtml(t)}</span>`).join('')}</div>`);

  if(secondary.toLowerCase()==='tortle'){
    parts.push(tortleChoiceFieldsHtml(`${prefix}Secondary`,data,'Secondary Tortle: '));
  }

  const subraces=subraceRulesForHeritage(secondary,data);
  if(subraces.length){
    parts.push(`<div class="racial-choice-section"><label>${escapeHtml(secondary)} Subrace</label><select id="${prefix}SecondarySubrace" class="input">${subraces.map(r=>`<option value="${escapeHtml(r.name)}">${escapeHtml(r.name)}</option>`).join('')}</select><div id="${prefix}SecondarySubraceDetails"></div></div>`);
  }
  if(secondary.toLowerCase()==='dragonborn'){
    const ancestries=data?.racialRules?.dragonbornAncestries||[];
    parts.push(`<div class="racial-choice-section"><label>Secondary Draconic Ancestry</label><select id="${prefix}SecondaryDragonbornAncestry" class="input">${ancestries.map(a=>`<option value="${escapeHtml(a.name)}">${escapeHtml(a.name)} — ${escapeHtml(a.damageType)}</option>`).join('')}</select><div id="${prefix}SecondaryDragonbornAncestryDetails"></div></div>`);
  }
  if(secondary.toLowerCase()==='dwarf'){
    const tools=data?.racialRules?.dwarfTools||["Smith's Tools","Brewer's Supplies","Mason's Tools"];
    parts.push(`<div class="racial-choice-section"><label>Secondary Dwarf Tool Proficiency</label><select id="${prefix}SecondaryDwarfTool" class="input">${tools.map(v=>`<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`).join('')}</select></div>`);
  }
  parts.push('</div>');
  return parts.join('');
}

function wireRacialOptions(prefix,species,data){
  const host=document.querySelector(`#${prefix}RacialOptions`); if(!host)return;
  // Preserve the primary half's current choices when the player changes only the Other Half selector.
  const savedPrimary={
    subrace:document.querySelector(`#${prefix}Subrace`)?.value||'',
    ancestry:document.querySelector(`#${prefix}DragonbornAncestry`)?.value||'',
    dwarfTool:document.querySelector(`#${prefix}DwarfTool`)?.value||'',
    highElfCantrip:document.querySelector(`#${prefix}HighElfCantrip`)?.value||'',
    highElfLanguage:document.querySelector(`#${prefix}HighElfLanguage`)?.value||'',
    tortlePattern:document.querySelector(`#${prefix}TortlePattern`)?.value||'',
    abilityA:document.querySelector(`#${prefix}AbilityA`)?.value||'',
    abilityB:document.querySelector(`#${prefix}AbilityB`)?.value||'',
    abilityC:document.querySelector(`#${prefix}AbilityC`)?.value||'',
    tortleSize:document.querySelector(`#${prefix}TortleSize`)?.value||'',
    tortleSkill:document.querySelector(`#${prefix}TortleSkill`)?.value||'',
    tortleLanguage:document.querySelector(`#${prefix}TortleLanguage`)?.value||''
  };
  host.innerHTML=racialOptionsHtml(prefix,species,data)+secondaryHeritageOptionsHtml(prefix,species,data);

  if(isTortleRace(species))wireTortleChoiceFields(prefix,savedPrimary);

  const subrace=document.querySelector(`#${prefix}Subrace`);
  if(subrace){
    if(savedPrimary.subrace&&Array.from(subrace.options).some(o=>o.value===savedPrimary.subrace))subrace.value=savedPrimary.subrace;
    const updateSubrace=()=>{
      const detail=document.querySelector(`#${prefix}SubraceDetails`);
      if(detail)detail.innerHTML=subraceDetailHtml(prefix,species,subrace.value,data);
    };
    subrace.onchange=updateSubrace; updateSubrace();
    const cantrip=document.querySelector(`#${prefix}HighElfCantrip`),language=document.querySelector(`#${prefix}HighElfLanguage`);
    if(cantrip&&savedPrimary.highElfCantrip&&Array.from(cantrip.options).some(o=>o.value===savedPrimary.highElfCantrip))cantrip.value=savedPrimary.highElfCantrip;
    if(language&&savedPrimary.highElfLanguage)language.value=savedPrimary.highElfLanguage;
  }

  const ancestry=document.querySelector(`#${prefix}DragonbornAncestry`);
  if(ancestry){
    if(savedPrimary.ancestry&&Array.from(ancestry.options).some(o=>o.value===savedPrimary.ancestry))ancestry.value=savedPrimary.ancestry;
    const updateAncestry=()=>{
      const details=document.querySelector(`#${prefix}DragonbornAncestryDetails`);
      const rule=(data?.racialRules?.dragonbornAncestries||[]).find(a=>String(a?.name||'').toLowerCase()===String(ancestry.value||'').toLowerCase());
      if(details)details.innerHTML=dragonbornAncestryDetailHtml(rule);
    };
    ancestry.onchange=updateAncestry; updateAncestry();
  }

  const primaryDwarfTool=document.querySelector(`#${prefix}DwarfTool`);
  if(primaryDwarfTool&&savedPrimary.dwarfTool&&Array.from(primaryDwarfTool.options).some(o=>o.value===savedPrimary.dwarfTool))primaryDwarfTool.value=savedPrimary.dwarfTool;

  const secondary=document.querySelector(`#${prefix}Half`)?.value||'';
  if(secondary.toLowerCase()==='tortle')wireTortleChoiceFields(`${prefix}Secondary`);
  const secondarySubrace=document.querySelector(`#${prefix}SecondarySubrace`);
  if(secondarySubrace){
    const updateSecondarySubrace=()=>{
      const detail=document.querySelector(`#${prefix}SecondarySubraceDetails`);
      if(detail)detail.innerHTML=subraceDetailHtml(`${prefix}Secondary`,secondary,secondarySubrace.value,data);
    };
    secondarySubrace.onchange=updateSecondarySubrace; updateSecondarySubrace();
  }

  const secondaryAncestry=document.querySelector(`#${prefix}SecondaryDragonbornAncestry`);
  if(secondaryAncestry){
    const updateSecondaryAncestry=()=>{
      const details=document.querySelector(`#${prefix}SecondaryDragonbornAncestryDetails`);
      const rule=(data?.racialRules?.dragonbornAncestries||[]).find(a=>String(a?.name||'').toLowerCase()===String(secondaryAncestry.value||'').toLowerCase());
      if(details)details.innerHTML=dragonbornAncestryDetailHtml(rule);
    };
    secondaryAncestry.onchange=updateSecondaryAncestry; updateSecondaryAncestry();
  }
}

function collectRacialOptions(prefix,species){
  const heritage=primaryRaceName(species);
  const half=String(species||'').startsWith('Half ');
  const secondary=half?(document.querySelector(`#${prefix}Half`)?.value||''):'';
  const result={
    racialAbilityChoices:null,
    secondaryRacialAbilityChoices:null,
    subrace:document.querySelector(`#${prefix}Subrace`)?.value||null,
    secondarySubrace:document.querySelector(`#${prefix}SecondarySubrace`)?.value||null,
    dragonbornAncestry:document.querySelector(`#${prefix}DragonbornAncestry`)?.value||null,
    secondaryDragonbornAncestry:document.querySelector(`#${prefix}SecondaryDragonbornAncestry`)?.value||null,
    highElfCantrip:document.querySelector(`#${prefix}HighElfCantrip`)?.value||null,
    highElfLanguage:document.querySelector(`#${prefix}HighElfLanguage`)?.value?.trim()||null,
    secondaryHighElfCantrip:document.querySelector(`#${prefix}SecondaryHighElfCantrip`)?.value||null,
    secondaryHighElfLanguage:document.querySelector(`#${prefix}SecondaryHighElfLanguage`)?.value?.trim()||null,
    dwarfTool:document.querySelector(`#${prefix}DwarfTool`)?.value||null,
    secondaryDwarfTool:document.querySelector(`#${prefix}SecondaryDwarfTool`)?.value||null,
    tortleSize:null,tortleNatureSkill:null,tortleLanguage:null,
    secondaryTortleSize:null,secondaryTortleNatureSkill:null,secondaryTortleLanguage:null
  };

  if(isTortleRace(species)){
    const tortle=collectTortleChoiceFields(prefix,'primary');
    result.racialAbilityChoices=tortle.abilityChoices;
    result.tortleSize=tortle.size;
    result.tortleNatureSkill=tortle.skill;
    result.tortleLanguage=tortle.language;
  }
  if(secondary.toLowerCase()==='tortle'){
    const tortle=collectTortleChoiceFields(`${prefix}Secondary`,'secondary');
    result.secondaryRacialAbilityChoices=tortle.abilityChoices;
    result.secondaryTortleSize=tortle.size;
    result.secondaryTortleNatureSkill=tortle.skill;
    result.secondaryTortleLanguage=tortle.language;
  }

  if(heritage.toLowerCase()==='elf'&&String(result.subrace||'').toLowerCase()==='high elf'&&!result.highElfLanguage)
    throw new Error('Choose the High Elf extra language.');
  if(secondary.toLowerCase()==='elf'&&String(result.secondarySubrace||'').toLowerCase()==='high elf'&&!result.secondaryHighElfLanguage)
    throw new Error('Choose the High Elf extra language for the Elf half.');
  return result;
}

function configureHalfRace(prefix,species,data){
  const box=document.querySelector(`#${prefix}HalfBox`),select=document.querySelector(`#${prefix}Half`);
  if(String(species||'').startsWith('Half ')){
    const primary=primaryRaceName(species);
    const prior=select.value;
    const choices=(data.baseSpecies||[]).filter(v=>String(v).toLowerCase()!==primary.toLowerCase());
    select.innerHTML=choices.map(v=>`<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`).join('');
    if(choices.includes(prior))select.value=prior;
    box.hidden=false;
    select.onchange=()=>wireRacialOptions(prefix,document.querySelector(`#${prefix}Species`)?.value||species,data);
  } else {
    box.hidden=true;select.innerHTML='';select.onchange=null;
  }
}

async function showCharacterCreator(campaignId) {
  const main = document.querySelector('#mainContent');
  main.innerHTML = `
    <div class="creator">
      <div class="section-title"><div><h2>Create Your Character</h2><p>One character per player in this campaign. Racial bonuses are applied after the base ability scores you enter.</p></div><button id="creatorBack" class="button">Back</button></div>
      <div class="tabs"><button id="randomTab" class="tab active">Random Build</button><button id="manualTab" class="tab">Manual Sheet</button></div>
      <section class="panel creator-panel">
        <div id="creatorLoading" class="loading">Loading character options...</div>
        <div id="randomCreator" hidden>
          <h3>Random Build</h3><p>Choose species and class. RabuShin generates the base character, then applies any selected racial options.</p>
          <label>Character Name</label><input id="randomName" class="input" placeholder="Leave blank for a generated name">
          <div class="form-grid">
            <div><label>Species / Race</label><select id="randomSpecies" class="input"></select></div>
            <div id="randomHalfBox" hidden><label>Other Half</label><select id="randomHalf" class="input"></select></div>
            <div><label>Class</label><select id="randomClass" class="input"></select></div>
          </div>
          <div id="randomRacialOptions" class="racial-options"></div>
          <button id="randomCreate" class="button primary wide">Generate Character</button>
        </div>
        <div id="manualCreator" hidden>
          <h3>Manual Sheet</h3>
          <div class="form-grid">
            <div><label>Name</label><input id="manualName" class="input"></div>
            <div><label>Level</label><input id="manualLevel" class="input" type="number" min="1" max="20" value="1"></div>
            <div><label>Species / Race</label><select id="manualSpecies" class="input"></select></div>
            <div id="manualHalfBox" hidden><label>Other Half</label><select id="manualHalf" class="input"></select></div>
            <div><label>Class</label><select id="manualClass" class="input"></select></div>
            <div><label>Background</label><select id="manualBackground" class="input"></select></div>
            <div><label>Alignment</label><select id="manualAlignment" class="input"></select></div>
          </div>
          <div id="manualRacialOptions" class="racial-options"></div>
          <h4 class="subhead">Base Ability Scores</h4>
          <p class="muted racial-score-hint">Enter scores before racial increases. Fixed racial bonuses are automatic; flexible bonuses are chosen above.</p>
          <div class="ability-entry-grid">${manualAbilityInput('STR','mStr')}${manualAbilityInput('DEX','mDex')}${manualAbilityInput('CON','mCon')}${manualAbilityInput('INT','mInt')}${manualAbilityInput('WIS','mWis')}${manualAbilityInput('CHA','mCha')}</div>
          <h4 class="subhead">Character Details</h4>
          <label>Appearance</label><textarea id="mAppearance" class="input textarea"></textarea>
          <label>Personality</label><textarea id="mPersonality" class="input textarea"></textarea>
          <label>Backstory</label><textarea id="mBackstory" class="input textarea"></textarea>
          <label>Notes</label><textarea id="mNotes" class="input textarea"></textarea>
          <button id="manualCreate" class="button primary wide">Create Character</button>
        </div>
        <div id="creatorError" class="error"></div>
      </section>
    </div>`;

  document.querySelector('#creatorBack').onclick = showCampaignLauncher;
  try {
    const data = await api('/game-api/character-options');
    populateSelect('#randomSpecies', data.species); populateSelect('#randomClass', data.classes);
    populateSelect('#manualSpecies', data.species); populateSelect('#manualClass', data.classes);
    populateSelect('#manualBackground', data.backgrounds); populateSelect('#manualAlignment', data.alignments);
    document.querySelector('#randomSpecies').value = data.species.includes('Human')?'Human':data.species[0]; document.querySelector('#randomClass').value = data.classes.includes('Fighter')?'Fighter':data.classes[0];
    document.querySelector('#manualSpecies').value = data.species.includes('Human')?'Human':data.species[0]; document.querySelector('#manualClass').value = data.classes.includes('Fighter')?'Fighter':data.classes[0];
    if (data.backgrounds.includes('Soldier')) document.querySelector('#manualBackground').value = 'Soldier';
    if (data.alignments.includes('True Neutral')) document.querySelector('#manualAlignment').value = 'True Neutral';
    document.querySelector('#creatorLoading').hidden = true; document.querySelector('#randomCreator').hidden = false;

    const randomTab = document.querySelector('#randomTab'), manualTab = document.querySelector('#manualTab');
    randomTab.onclick = () => { randomTab.classList.add('active'); manualTab.classList.remove('active'); document.querySelector('#randomCreator').hidden=false; document.querySelector('#manualCreator').hidden=true; };
    manualTab.onclick = () => { manualTab.classList.add('active'); randomTab.classList.remove('active'); document.querySelector('#manualCreator').hidden=false; document.querySelector('#randomCreator').hidden=true; };

    const refreshRaceUi=(prefix)=>{
      const species=document.querySelector(`#${prefix}Species`).value;
      configureHalfRace(prefix,species,data);
      wireRacialOptions(prefix,species,data);
    };
    document.querySelector('#manualSpecies').onchange=()=>refreshRaceUi('manual');
    document.querySelector('#randomSpecies').onchange=()=>refreshRaceUi('random');
    refreshRaceUi('manual');refreshRaceUi('random');

    document.querySelector('#randomCreate').onclick = async () => {
      const btn=document.querySelector('#randomCreate'); btn.disabled=true; btn.textContent='Generating...';
      try {
        const species=document.querySelector('#randomSpecies').value;
        const racial=collectRacialOptions('random',species);
        const result=await api(`/game-api/campaigns/${campaignId}/characters/random`,{method:'POST',body:JSON.stringify({
          characterName:document.querySelector('#randomName').value.trim(),species,
          secondaryHeritage:species.startsWith('Half ')?document.querySelector('#randomHalf').value:'',
          className:document.querySelector('#randomClass').value,...racial})});
        await showStartingEquipment(campaignId,result.character);
      } catch(error){ document.querySelector('#creatorError').textContent=error.message; btn.disabled=false; btn.textContent='Generate Character'; }
    };

    document.querySelector('#manualCreate').onclick = async () => {
      const score = id => Math.max(1,Math.min(20,Number(document.querySelector(id).value)||10));
      const name=document.querySelector('#manualName').value.trim(); if(!name){document.querySelector('#creatorError').textContent='Character name is required.';return;}
      const btn=document.querySelector('#manualCreate');btn.disabled=true;btn.textContent='Creating...';
      try {
        const species=document.querySelector('#manualSpecies').value;
        const racial=collectRacialOptions('manual',species);
        const result=await api(`/game-api/campaigns/${campaignId}/characters/manual`,{method:'POST',body:JSON.stringify({
          characterName:name,species,secondaryHeritage:species.startsWith('Half ')?document.querySelector('#manualHalf').value:'',className:document.querySelector('#manualClass').value,
          background:document.querySelector('#manualBackground').value,alignment:document.querySelector('#manualAlignment').value,level:Number(document.querySelector('#manualLevel').value)||1,
          strength:score('#mStr'),dexterity:score('#mDex'),constitution:score('#mCon'),intelligence:score('#mInt'),wisdom:score('#mWis'),charisma:score('#mCha'),
          appearance:document.querySelector('#mAppearance').value.trim(),personality:document.querySelector('#mPersonality').value.trim(),backstory:document.querySelector('#mBackstory').value.trim(),notes:document.querySelector('#mNotes').value.trim(),...racial
        })});
        await showStartingEquipment(campaignId,result.character);
      } catch(error){document.querySelector('#creatorError').textContent=error.message;btn.disabled=false;btn.textContent='Create Character';}
    };
  } catch(error){ document.querySelector('#creatorLoading').textContent='Unable to load character creator.'; document.querySelector('#creatorError').textContent=error.message; }
}

async function showStartingEquipment(campaignId, character) {
  const main=document.querySelector('#mainContent');
  main.innerHTML=`<div class="creator"><div class="section-title"><div><h2>Starting Equipment</h2><p>${escapeHtml(character.characterName)} • ${escapeHtml(character.className)}</p></div></div><section class="panel"><div id="equipLoading" class="loading">Loading 2014 starting equipment...</div><div id="equipForm" hidden>
    <div class="selection-summary"><b>2014 Starting Equipment</b><br>Choose each class equipment group below. Background equipment is added separately, and equipment packs are expanded into the actual items placed in your inventory.</div>
    <div id="equipCompatibility"></div>
    <div id="classEquipmentArea"></div>
    <div id="backgroundEquipmentArea"></div>
    <h3 class="subhead">Starting Inventory Preview</h3><div id="equipPreview" class="item-list"></div><div class="gold-line">Starting Gold: <b id="equipGold">0 GP</b></div>
    <div id="equipError" class="error"></div><button id="saveEquip" class="button primary wide">Accept Starting Equipment</button></div></section></div>`;

  try {
    const data=await api(`/game-api/campaigns/${campaignId}/starting-equipment`);
    const classPlan=data.classEquipment||{},backgroundPlan=data.backgroundEquipment||{};
    const choiceState={classChoices:{},backgroundChoices:{}};

    if(data.compatibilityMapped){
      document.querySelector('#equipCompatibility').innerHTML=`<div class="equipment-compatibility"><b>${escapeHtml(data.backgroundName)}</b> uses the 2014 <b>${escapeHtml(data.backgroundRulesName)}</b> starting-equipment package for compatibility.</div>`;
    }

    const itemText=item=>`${escapeHtml(item.itemName)}${Number(item.quantity||1)>1?` × ${Number(item.quantity)}`:''}`;
    const fixedList=items=>items?.length
      ? `<div class="equipment-fixed-list">${items.map(item=>`<div class="equipment-fixed-item"><b>${itemText(item)}</b>${item.origin?`<small>${escapeHtml(item.origin)}</small>`:''}</div>`).join('')}</div>`
      : '<div class="empty small">No automatic items in this section.</div>';

    const renderSlots=(plan,prefix,group,option)=>{
      const host=document.querySelector(`#${prefix}-slots-${group.key}`);if(!host)return;
      const slots=option?.slots||[];
      if(!slots.length){host.innerHTML='';return;}
      host.innerHTML=slots.map(slot=>`<label class="equipment-slot-label">${escapeHtml(slot.label)}<select class="input equipment-slot-select" data-prefix="${prefix}" data-group="${escapeHtml(group.key)}" data-slot="${escapeHtml(slot.key)}">${(slot.options||[]).map(o=>`<option value="${escapeHtml(o.key)}">${escapeHtml(o.label)}</option>`).join('')}</select></label>`).join('');
      host.querySelectorAll('.equipment-slot-select').forEach(select=>{select.onchange=()=>{syncState(plan,prefix);renderPreview();};});
    };

    const selectedOption=(group,select)=>group?.options?.find(o=>o.key===select?.value)||group?.options?.[0]||null;

    const syncState=(plan,prefix)=>{
      const target=choiceState[prefix==='class'?'classChoices':'backgroundChoices'];
      for(const group of plan.choiceGroups||[]){
        const select=document.querySelector(`#${prefix}-choice-${group.key}`);
        const option=selectedOption(group,select);
        if(!option)continue;
        const slots={};
        for(const slot of option.slots||[]){
          const slotSelect=document.querySelector(`.equipment-slot-select[data-prefix="${prefix}"][data-group="${group.key}"][data-slot="${slot.key}"]`);
          slots[slot.key]=slotSelect?.value||slot.options?.[0]?.key||'';
        }
        target[group.key]={optionKey:option.key,slots};
      }
    };

    const renderPlan=(plan,prefix,title)=>{
      const host=document.querySelector(`#${prefix}EquipmentArea`);
      host.innerHTML=`<div class="equipment-plan"><div class="equipment-plan-heading"><div><h3>${escapeHtml(title)}</h3><p>${escapeHtml(plan.rulesName||'')}</p></div>${Number(plan.gold||0)>0?`<span class="equipment-gold-badge">+${Number(plan.gold)} GP</span>`:''}</div>
        <h4>Automatically Received</h4>${fixedList(plan.fixedItems||[])}
        ${(plan.choiceGroups||[]).length?`<h4 class="equipment-choice-heading">Choose Equipment</h4><div class="equipment-choice-list">${(plan.choiceGroups||[]).map(group=>`<div class="equipment-choice-group"><label>${escapeHtml(group.label)}<select id="${prefix}-choice-${escapeHtml(group.key)}" class="input equipment-choice-select">${(group.options||[]).map(option=>`<option value="${escapeHtml(option.key)}">${escapeHtml(option.label)}</option>`).join('')}</select></label><div id="${prefix}-slots-${escapeHtml(group.key)}" class="equipment-slot-area"></div></div>`).join('')}</div>`:''}</div>`;

      for(const group of plan.choiceGroups||[]){
        const select=document.querySelector(`#${prefix}-choice-${group.key}`);
        const update=()=>{const option=selectedOption(group,select);renderSlots(plan,prefix,group,option);syncState(plan,prefix);renderPreview();};
        select.onchange=update;update();
      }
      syncState(plan,prefix);
    };

    const itemsForPlan=(plan,prefix)=>{
      const result=[...(plan.fixedItems||[])];
      const state=choiceState[prefix==='class'?'classChoices':'backgroundChoices'];
      for(const group of plan.choiceGroups||[]){
        const chosen=state[group.key];if(!chosen)continue;
        const option=(group.options||[]).find(o=>o.key===chosen.optionKey);if(!option)continue;
        result.push(...(option.items||[]));
        for(const slot of option.slots||[]){
          const key=chosen.slots?.[slot.key];
          const selected=(slot.options||[]).find(o=>o.key===key);
          if(selected)result.push(...(selected.items||[]));
        }
      }
      return result;
    };

    const renderPreview=()=>{
      syncState(classPlan,'class');syncState(backgroundPlan,'background');
      const rows=[];
      for(const item of itemsForPlan(classPlan,'class'))rows.push({source:'Class',...item});
      for(const item of itemsForPlan(backgroundPlan,'background'))rows.push({source:'Background',...item});
      const merged=new Map();
      for(const row of rows){
        const key=`${row.source}\u001f${String(row.origin||'')}\u001f${String(row.itemName||'')}`.toLowerCase();
        const current=merged.get(key);if(current)current.quantity+=Number(row.quantity||1);else merged.set(key,{...row,quantity:Number(row.quantity||1)});
      }
      const display=[...merged.values()];
      document.querySelector('#equipPreview').innerHTML=display.length?display.map(r=>`<div class="list-row equipment-preview-row"><span class="muted">${escapeHtml(r.source)}${r.origin?`<small>${escapeHtml(r.origin)}</small>`:''}</span><b>${escapeHtml(r.itemName)}</b><span>× ${Number(r.quantity||1)}</span></div>`).join(''):'<div class="empty small">This selection grants gold only.</div>';
      document.querySelector('#equipGold').textContent=`${Number(classPlan.gold||0)+Number(backgroundPlan.gold||0)} GP`;
    };

    renderPlan(classPlan,'class','Class Equipment');
    renderPlan(backgroundPlan,'background','Background Equipment');
    renderPreview();
    document.querySelector('#equipLoading').hidden=true;document.querySelector('#equipForm').hidden=false;

    document.querySelector('#saveEquip').onclick=async()=>{
      const btn=document.querySelector('#saveEquip');btn.disabled=true;btn.textContent='Saving...';document.querySelector('#equipError').textContent='';
      try{
        syncState(classPlan,'class');syncState(backgroundPlan,'background');
        await api(`/game-api/campaigns/${campaignId}/starting-equipment`,{method:'POST',body:JSON.stringify(choiceState)});
        showNotice('2014 starting equipment saved.');
        const ch=(await api(`/game-api/campaigns/${campaignId}/character`)).character;
        await continueCharacterSetup(campaignId,ch);
      }catch(error){document.querySelector('#equipError').textContent=error.message;btn.disabled=false;btn.textContent='Accept Starting Equipment';}
    };
  }catch(error){document.querySelector('#equipLoading').textContent='Unable to load starting equipment.';showNotice(error.message,true);}
}

// RULES BUILD 6.14 - SPELL & CANTRIP SELECTION COUNTERS
async function showSpellSelection(campaignId, character, fromLevelUp=false) {
  const main=document.querySelector('#mainContent');
  main.innerHTML=`<div class="creator"><div class="section-title"><div><h2>Spells & Cantrips</h2><p>${escapeHtml(character.characterName)} • Level ${character.level} ${escapeHtml(character.className)}</p></div></div><section class="panel"><div id="spellLoading" class="loading">Loading spell rules...</div><div id="spellForm" hidden></div><div id="spellError" class="error"></div></section></div>`;
  try {
    const data=await api(`/game-api/campaigns/${campaignId}/spell-options`);
    if(!data.required){await api(`/game-api/campaigns/${campaignId}/spell-selection`,{method:'POST',body:JSON.stringify({cantrips:[],spells:[],preparedWizardSpells:[],mysticArcanum:{}})});return enterCampaign(campaignId);}
    const p=data.progression,form=document.querySelector('#spellForm');
    const spellCard=(s,kind)=>`<label class="spell-option"><input type="checkbox" class="${kind}" value="${escapeHtml(s.name)}"><span><b>${escapeHtml(s.name)}</b><small>${s.level===0?'Cantrip':`Level ${s.level}`} • ${escapeHtml(s.school||'')}</small><em>${escapeHtml(s.description||'')}</em></span></label>`;
    const wizard=data.className.toLowerCase()==='wizard';
    const cantripLimit=Math.max(0,Number(p.cantripsKnown)||0);
    const spellLimit=Math.max(0,Number(wizard?p.wizardSpellbookCount:p.preparedSpells)||0);
    const preparedLimit=Math.max(0,Number(wizard?p.preparedSpells:0)||0);
    form.innerHTML=`
      <div class="selection-summary">Choose <b>${p.cantripsKnown}</b> cantrip(s). ${wizard?`Add <b>${p.wizardSpellbookCount}</b> spells to your spellbook and prepare <b>${p.preparedSpells}</b>.`:`Choose <b>${p.preparedSpells}</b> class spell(s).`} ${data.alwaysPrepared?.length?`Always prepared: ${data.alwaysPrepared.map(escapeHtml).join(', ')}`:''}</div>
      <div id="spellSelectionCounters" class="selection-summary">
        ${cantripLimit>0?`<span><b id="cantripRemaining">${cantripLimit}</b> cantrip(s) remaining</span>`:''}
        ${spellLimit>0?`<span>${cantripLimit>0?' • ':''}<b id="spellRemaining">${spellLimit}</b> ${wizard?'spellbook spell(s)':'spell(s)'} remaining</span>`:''}
        ${wizard&&preparedLimit>0?`<span> • <b id="preparedRemaining">${preparedLimit}</b> prepared spell(s) remaining</span>`:''}
      </div>
      ${p.cantripsKnown>0?`<h3>Cantrips</h3><div class="spell-grid">${data.cantrips.map(s=>spellCard(s,'cantrip-check')).join('')}</div>`:''}
      ${p.preparedSpells>0||p.wizardSpellbookCount>0?`<h3 class="subhead">Spells</h3><div class="spell-grid">${data.spells.map(s=>wizard?`<div class="wizard-spell"><label><input class="spell-check" type="checkbox" value="${escapeHtml(s.name)}"> <b>${escapeHtml(s.name)}</b> <small>L${s.level}</small></label><label class="prepare"><input class="prepare-check" type="checkbox" value="${escapeHtml(s.name)}" disabled> Prepare</label><p>${escapeHtml(s.description||'')}</p></div>`:spellCard(s,'spell-check')).join('')}</div>`:''}
      <div id="arcanumArea"></div><button id="saveSpells" class="button primary wide">Save Spell Selection</button>`;
    document.querySelector('#spellLoading').hidden=true;form.hidden=false;
    if(p.warlockArcanumLevels?.length){const ar=document.querySelector('#arcanumArea');ar.innerHTML='<h3 class="subhead">Mystic Arcanum</h3>'+p.warlockArcanumLevels.map(level=>`<label>Level ${level}<select class="input arcanum" data-level="${level}">${data.spells.filter(s=>s.level===level).map(s=>`<option>${escapeHtml(s.name)}</option>`).join('')}</select></label>`).join('');}

    // During a post-rest level up, keep the character's existing spell choices checked
    // so the player only needs to add/replace whatever the new level grants.
    const existingSpells=Array.isArray(data.existingSpells)?data.existingSpells:[];
    existingSpells.forEach(existing=>{
      const name=String(existing.name||'');
      if(Number(existing.level)===0){
        const box=[...document.querySelectorAll('.cantrip-check')].find(x=>x.value===name);if(box)box.checked=true;
        return;
      }
      if(String(existing.sourceTag||'').toLowerCase()==='mysticarcanum'){
        const select=document.querySelector(`.arcanum[data-level="${Number(existing.level)}"]`);
        if(select&&[...select.options].some(o=>o.value===name))select.value=name;
        return;
      }
      const box=[...document.querySelectorAll('.spell-check')].find(x=>x.value===name);
      if(box){
        box.checked=true;
        if(wizard){
          const prep=[...document.querySelectorAll('.prepare-check')].find(x=>x.value===name);
          if(prep){prep.disabled=false;prep.checked=Boolean(existing.prepared);}
        }
      }
    });

    const setCounter=(id,limit,selected,label)=>{
      const el=document.querySelector(`#${id}`);if(!el)return selected===limit;
      const remaining=limit-selected;
      if(remaining<0){el.textContent=`Over by ${Math.abs(remaining)}`;el.parentElement?.classList.add('error');return false;}
      el.textContent=String(remaining);
      el.parentElement?.classList.remove('error');
      return remaining===0;
    };

    const updateSpellSelectionCounters=()=>{
      const cantripBoxes=[...document.querySelectorAll('.cantrip-check')];
      const spellBoxes=[...document.querySelectorAll('.spell-check')];
      const prepBoxes=[...document.querySelectorAll('.prepare-check')];
      const cantripSelected=cantripBoxes.filter(x=>x.checked).length;
      const spellSelected=spellBoxes.filter(x=>x.checked).length;

      cantripBoxes.forEach(box=>{box.disabled=!box.checked&&cantripSelected>=cantripLimit;});
      spellBoxes.forEach(box=>{box.disabled=!box.checked&&spellSelected>=spellLimit;});

      let preparedSelected=0;
      if(wizard){
        prepBoxes.forEach(prep=>{
          const spell=spellBoxes.find(x=>x.value===prep.value);
          if(!spell?.checked)prep.checked=false;
        });
        preparedSelected=prepBoxes.filter(x=>x.checked).length;
        prepBoxes.forEach(prep=>{
          const spell=spellBoxes.find(x=>x.value===prep.value);
          prep.disabled=!spell?.checked||(!prep.checked&&preparedSelected>=preparedLimit);
        });
      }

      const cantripsComplete=cantripLimit===0||setCounter('cantripRemaining',cantripLimit,cantripSelected,'cantrip');
      const spellsComplete=spellLimit===0||setCounter('spellRemaining',spellLimit,spellSelected,'spell');
      const preparedComplete=!wizard||preparedLimit===0||setCounter('preparedRemaining',preparedLimit,preparedSelected,'prepared spell');
      const complete=cantripsComplete&&spellsComplete&&preparedComplete;
      const save=document.querySelector('#saveSpells');
      if(save&&!String(save.textContent||'').startsWith('Saving')){
        save.disabled=!complete;
        if(complete)save.textContent='Save Spell Selection';
        else {
          const remaining=[];
          if(cantripLimit>cantripSelected)remaining.push(`${cantripLimit-cantripSelected} cantrip`);
          if(spellLimit>spellSelected)remaining.push(`${spellLimit-spellSelected} ${wizard?'spellbook spell':'spell'}`);
          if(wizard&&preparedLimit>preparedSelected)remaining.push(`${preparedLimit-preparedSelected} prepared spell`);
          save.textContent=remaining.length?`Select ${remaining.join(', ')} more`:'Complete Required Selections';
        }
      }
      return complete;
    };

    document.querySelectorAll('.cantrip-check').forEach(ch=>ch.addEventListener('change',updateSpellSelectionCounters));
    document.querySelectorAll('.spell-check').forEach(ch=>ch.addEventListener('change',()=>{
      if(wizard&&!ch.checked){const prep=[...document.querySelectorAll('.prepare-check')].find(x=>x.value===ch.value);if(prep)prep.checked=false;}
      updateSpellSelectionCounters();
    }));
    document.querySelectorAll('.prepare-check').forEach(ch=>ch.addEventListener('change',updateSpellSelectionCounters));
    updateSpellSelectionCounters();

    document.querySelector('#saveSpells').onclick=async()=>{
      if(!updateSpellSelectionCounters()){document.querySelector('#spellError').textContent='Complete all required cantrip and spell selections before saving.';return;}
      const cantrips=[...document.querySelectorAll('.cantrip-check:checked')].map(x=>x.value),spells=[...document.querySelectorAll('.spell-check:checked')].map(x=>x.value),preparedWizardSpells=[...document.querySelectorAll('.prepare-check:checked')].map(x=>x.value),mysticArcanum={};
      document.querySelectorAll('.arcanum').forEach(x=>mysticArcanum[x.dataset.level]=x.value);
      const btn=document.querySelector('#saveSpells');btn.disabled=true;btn.textContent='Saving Spells...';document.querySelector('#spellError').textContent='';
      try{await api(`/game-api/campaigns/${campaignId}/spell-selection`,{method:'POST',body:JSON.stringify({cantrips,spells,preparedWizardSpells,mysticArcanum})});levelUpSpellRecoveryBusy=false;showNotice(fromLevelUp?'Level-up spell choices saved.':'Spell selection saved.');await enterCampaign(campaignId,fromLevelUp?'character':'gm');}catch(error){document.querySelector('#spellError').textContent=error.message;btn.textContent='Save Spell Selection';updateSpellSelectionCounters();}
    };
  }catch(error){document.querySelector('#spellLoading').textContent='Unable to load spell selection.';document.querySelector('#spellError').textContent=error.message;}
}

async function enterCampaign(campaignId, initialTab='gm') {
  try {
    currentCampaignId=campaignId;
    activeGameTab='gm';
    gmTurnState=null;
    gmTurnToken=null;
    gmTurnDraft='';
    campaignChatDraft='';
    stopGmVoicePlayback();
    gmVoiceBaselineInitialized=false;
    gmVoiceLastSeenMessageKey='';
    currentGameData=await api(`/game-api/campaigns/${campaignId}/bootstrap`);
    currentGameData.inventory=mergeInventoryValuations(currentGameData.inventory||[],currentGameData.inventoryValuations||[]);
    renderGameShell();
    renderGameMasterTab();
    startDeathStatePolling();
    startProgressionPolling();
    startRestStatePolling();
    startSurvivalPolling();
    startWorldTimePolling();
    startSleepStatePolling();
    if(initialTab&&initialTab!=='gm'){
      const target=document.querySelector(`.game-tab[data-tab="${initialTab}"]`);
      if(target)switchGameTab(initialTab,target);
    }
  } catch(error){showNotice(error.message,true);}
}

function renderGameShell() {
  const d=currentGameData,c=d.campaign,ch=d.character,main=document.querySelector('#mainContent');
  main.innerHTML=`<div class="game">
    <div class="game-header"><div><button id="backLauncher" class="button small">← Campaigns</button><h2>${escapeHtml(c.campaignName)}</h2><p>Chapter ${c.currentChapter} • <span id="gameCurrentLocation">${escapeHtml(c.currentLocation)}</span> • ${escapeHtml(ch.characterName)}</p></div><div class="game-header-vitals"><div id="worldClockHost">${worldClockHtml(d.worldTime)}</div><div class="quick-vitals"><span>HP <b data-live-self-hp>${ch.currentHp}/${ch.maxHp}</b></span><span>AC <b>${ch.armorClass}</b></span><span>Coins <b data-live-self-currency>${currencyPurseText(ch.gold)}</b></span></div><div id="survivalMetersHost">${survivalMetersHtml(d.survival)}</div></div></div>
    <nav class="game-nav">
      <button class="game-tab active" data-tab="gm">AI Game Master</button><button class="game-tab" data-tab="character">Character</button><button class="game-tab" data-tab="inventory">Inventory</button><button class="game-tab" data-tab="spells">Spellbook</button><button class="game-tab" data-tab="journal">Journal</button><button class="game-tab" data-tab="chat">Campaign Chat</button><button class="game-tab" data-tab="settings">Settings</button>
    </nav><section id="gameView" class="game-view"></section></div>`;
  document.querySelector('#backLauncher').onclick=showCampaignLauncher;
  document.querySelectorAll('.game-tab').forEach(btn=>btn.onclick=()=>switchGameTab(btn.dataset.tab,btn));
  const settingsGameTab=document.querySelector('.game-tab[data-tab="settings"]');
  if(settingsGameTab&&!document.querySelector('.game-tab[data-tab="combat"]')) {
    const combatTab=document.createElement('button'); combatTab.className='game-tab'; combatTab.dataset.tab='combat'; combatTab.textContent='\u2694 Combat';
    settingsGameTab.parentElement.insertBefore(combatTab,settingsGameTab);
    combatTab.onclick=()=>switchGameTab('combat',combatTab);
  }
}

function switchGameTab(tab,button) {
  document.querySelectorAll('.game-tab').forEach(b=>b.classList.remove('active'));
  button?.classList.add('active');
  stopConversationLiveSync();
  activeGameTab=tab;
  if(tab!=='combat')stopTacticalCombatPolling();
  if(tab==='combat'){renderCombatTab();return;}
  ({gm:renderGameMasterTab,character:renderCharacterTab,inventory:renderInventoryTab,spells:renderSpellbookTab,journal:renderJournalTab,chat:renderChatTab,settings:renderSettingsTab}[tab]||renderGameMasterTab)();
}

function survivalMetersHtml(state) {
  if(!state?.enabled)return '';
  // Build 6.8 originally returned the Supabase DTO directly, so its
  // JsonPropertyName attributes emitted snake_case even though the UI expected
  // camelCase. Accept both shapes during rolling deployments while the server
  // now returns the canonical camelCase contract.
  const value=(camel,snake)=>state[camel]??state[snake];
  const hunger=Math.max(0,Math.min(100,Number(value('hungerPercent','hunger_percent'))||0));
  const thirst=Math.max(0,Math.min(100,Number(value('thirstPercent','thirst_percent'))||0));
  const food=Math.max(0,Number(value('foodCreditLb','food_credit_lb'))||0);
  const foodReq=Math.max(0.01,Number(value('foodRequirementLb','food_requirement_lb'))||1);
  const water=Math.max(0,Number(value('waterCreditGal','water_credit_gal'))||0);
  const waterReq=Math.max(0.01,Number(value('waterRequirementGal','water_requirement_gal'))||1);
  const exhaustion=Math.max(0,Number(value('exhaustionLevel','exhaustion_level'))||0);
  const hotWeather=Boolean(value('hotWeather','hot_weather'));
  return `<div class="survival-meters">
    <div class="survival-meter hunger-meter"><div class="survival-meter-label"><span>Hunger</span><b>${hunger.toFixed(0)}%</b><small>${food.toFixed(2)} / ${foodReq.toFixed(0)} lb</small></div><div class="survival-track"><i style="width:${hunger}%"></i></div></div>
    <div class="survival-meter thirst-meter"><div class="survival-meter-label"><span>Thirst${hotWeather?' (Hot)':''}</span><b>${thirst.toFixed(0)}%</b><small>${water.toFixed(2)} / ${waterReq.toFixed(0)} gal</small></div><div class="survival-track"><i style="width:${thirst}%"></i></div></div>
    ${exhaustion>0?`<div class="survival-exhaustion">Exhaustion ${exhaustion}</div>`:''}
  </div>`;
}

function updateSurvivalHeader() {
  const host=document.querySelector('#survivalMetersHost');
  if(host)host.innerHTML=survivalMetersHtml(currentGameData?.survival);
}

function stopSurvivalPolling() {
  if(survivalPollTimer)clearInterval(survivalPollTimer);
  survivalPollTimer=null;
  survivalPollBusy=false;
}

function startSurvivalPolling() {
  stopSurvivalPolling();
  if(!currentCampaignId)return;
  void refreshSurvivalState();
  survivalPollTimer=setInterval(()=>void refreshSurvivalState(),3000);
}

async function refreshSurvivalState() {
  if(!currentCampaignId||!currentGameData||survivalPollBusy)return;
  survivalPollBusy=true;
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/survival`);
    if(data.survival)currentGameData.survival=data.survival;
    if(data.encumbrance)currentGameData.encumbrance=data.encumbrance;
    updateSurvivalHeader();
    updateEncumbranceUi();
  } catch(error) {
    console.warn('Survival state refresh failed:',error);
  } finally {
    survivalPollBusy=false;
  }
}

function resolvedEncumbrance() {
  if(currentGameData?.encumbrance)return currentGameData.encumbrance;
  const strength=Math.max(0,Number(currentGameData?.character?.strength)||0);
  const capacity=strength*15;
  const carried=(currentGameData?.inventory||[]).reduce((sum,item)=>sum+(Math.max(0,Number(item.quantity)||0)*Math.max(0,Number(item.weightLb)||0)),0);
  return {carriedWeightLb:carried,capacityLb:capacity,remainingCapacityLb:Math.max(0,capacity-carried),percent:capacity>0?Math.min(100,(carried/capacity)*100):0,overCapacity:carried>capacity};
}

function encumbranceHtml() {
  const e=resolvedEncumbrance();
  const carried=Math.max(0,Number(e.carriedWeightLb)||0);
  const capacity=Math.max(0,Number(e.capacityLb)||0);
  const percent=capacity>0?Math.min(100,(carried/capacity)*100):0;
  const remaining=Math.max(0,capacity-carried);
  return `<div class="encumbrance-card ${e.overCapacity?'over':''}">
    <div class="encumbrance-line"><span>Weight Capacity</span><b>${carried.toFixed(1)} / ${capacity.toFixed(0)} lb</b><small>${e.overCapacity?`${(carried-capacity).toFixed(1)} lb over capacity`:`${remaining.toFixed(1)} lb remaining`}</small></div>
    <div class="encumbrance-track"><i style="width:${percent}%"></i></div>
  </div>`;
}

function updateEncumbranceUi() {
  const host=document.querySelector('#encumbranceHost');
  if(host)host.innerHTML=encumbranceHtml();
}

function stopProgressionPolling() {
  if(progressionPollTimer)clearInterval(progressionPollTimer);
  progressionPollTimer=null;
  progressionPollBusy=false;
}

function startProgressionPolling() {
  stopProgressionPolling();
  if(!currentCampaignId)return;
  void refreshCharacterProgression(true);
  progressionPollTimer=setInterval(()=>void refreshCharacterProgression(false),3000);
}

function experienceProgressHtml(progression) {
  if(!progression)return '<div class="loading mini">Loading experience...</div>';
  const xp=Math.max(0,Number(progression.experience)||0);
  const level=Math.max(1,Number(progression.currentLevel)||1);
  const earned=Math.max(level,Number(progression.earnedLevel)||level);
  const maxLevel=level>=20;
  const start=Math.max(0,Number(progression.currentLevelXp)||0);
  const next=Math.max(start,Number(progression.nextLevelXp)||start);
  const into=Math.max(0,Number(progression.xpIntoLevel)||0);
  const span=Math.max(1,Number(progression.xpNeededThisLevel)||1);
  const percent=maxLevel?100:Math.max(0,Math.min(100,(into/span)*100));
  let status=maxLevel?'Maximum Level Reached':`${xp.toLocaleString()} / ${next.toLocaleString()} XP`;
  let badge='';
  if(progression.pendingLevelUp){badge='<span class="xp-ready-badge wake">LEVEL UP — CHOICES WAITING</span>';status=`Level ${progression.fromLevel} → ${progression.toLevel} after Long Rest`;}
  else if(progression.readyForLevelUp){badge='<span class="xp-ready-badge">LEVEL UP READY</span>';status=`${xp.toLocaleString()} XP • Rest to reach Level ${earned}`;}
  return `<div class="experience-card ${progression.readyForLevelUp||progression.pendingLevelUp?'ready':''}">
    <div class="experience-heading"><div><span>Experience</span><b>Level ${level}</b></div>${badge}</div>
    <div class="experience-track" role="progressbar" aria-valuemin="${start}" aria-valuemax="${maxLevel?xp:next}" aria-valuenow="${xp}"><i style="width:${percent}%"></i></div>
    <div class="experience-meta"><strong>${escapeHtml(status)}</strong><small>${maxLevel?'355,000 XP threshold reached':`${Math.max(0,next-xp).toLocaleString()} XP until the next threshold`}</small></div>
    ${progression.readyForLevelUp&&!progression.pendingLevelUp?'<p class="experience-rest-note">Enough XP has been earned. Your level will not change until your character successfully completes an in-game <b>Long Rest</b>.</p>':''}
  </div>`;
}

async function refreshCharacterProgression(force=false) {
  if(!currentCampaignId||!currentGameData||progressionPollBusy||levelUpActionBusy)return;
  progressionPollBusy=true;
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/progression`);
    const progression=data.progression||null;
    currentProgression=progression;
    const host=document.querySelector('#experienceProgressHost');
    if(host)host.innerHTML=experienceProgressHtml(progression);

    if(progression&&currentGameData?.character&&Number(currentGameData.character.level)!==Number(progression.currentLevel)){
      const fresh=await api(`/game-api/campaigns/${currentCampaignId}/character`);
      if(fresh.hasCharacter&&fresh.character)currentGameData.character=fresh.character;
    }

    if(progression?.pendingLevelUp){
      const sig=`${progression.fromLevel}:${progression.toLevel}:${(progression.prompts||[]).map(p=>p.key).join('|')}`;
      if(force||!document.querySelector('#levelUpOverlay')||sig!==levelUpOverlaySignature)renderLevelUpOverlay(progression,sig);
    } else {
      document.querySelector('#levelUpOverlay')?.remove();
      levelUpOverlaySignature='';
      if(progression?.spellSelectionPending&&!levelUpSpellRecoveryBusy){
        levelUpSpellRecoveryBusy=true;
        stopConversationLiveSync();
        stopProgressionPolling();
        const fresh=await api(`/game-api/campaigns/${currentCampaignId}/character`);
        if(fresh.hasCharacter&&fresh.character)currentGameData.character=fresh.character;
        await showSpellSelection(currentCampaignId,currentGameData.character,true);
        return;
      }
    }
  } catch(error) {
    console.warn('Experience / level-up refresh failed:',error);
  } finally {
    progressionPollBusy=false;
  }
}

function renderLevelUpOverlay(progression,signature='') {
  document.querySelector('#levelUpOverlay')?.remove();
  levelUpOverlaySignature=signature;
  const prompts=Array.isArray(progression.prompts)?progression.prompts:[];
  const overlay=document.createElement('div');
  overlay.id='levelUpOverlay';
  overlay.className='level-up-overlay';
  const promptHtml=prompts.map(prompt=>`<label class="level-up-choice"><span><b>${escapeHtml(prompt.label)}</b>${prompt.optional?'<em>Optional</em>':''}</span><small>${escapeHtml(prompt.description||'')}</small><textarea class="input level-up-choice-input" data-choice-key="${escapeHtml(prompt.key)}" rows="2" placeholder="${prompt.optional?'Leave blank if none':'Enter your choice'}"></textarea></label>`).join('');
  overlay.innerHTML=`<section class="level-up-card">
    <div class="level-up-sun">✦</div>
    <p class="eyebrow">You wake from your Long Rest</p>
    <h2>Level Up!</h2>
    <div class="level-up-levels"><b>Level ${Number(progression.fromLevel)||1}</b><span>→</span><b>Level ${Number(progression.toLevel)||1}</b></div>
    <p>Your XP qualified you to advance, but the level increase waited until this completed Long Rest. Your new level and proficiency are now recognized by the Game Master.</p>
    ${progression.restReason?`<p class="level-up-rest-reason">${escapeHtml(progression.restReason)}</p>`:''}
    <div class="level-up-choices">${promptHtml||'<p>No additional class-feature choices are required for this level.</p>'}</div>
    <p class="level-up-spell-note">After these class choices, spellcasting classes will be shown their spell selection when needed so existing spells can be kept and new choices added.</p>
    <div id="levelUpError" class="error"></div>
    <button id="finishLevelUpChoices" class="button primary wide">Continue Level Up</button>
  </section>`;
  document.body.appendChild(overlay);
  overlay.querySelector('#finishLevelUpChoices').onclick=()=>void saveLevelUpChoices(progression);
}

async function saveLevelUpChoices(progression) {
  if(levelUpActionBusy||!currentCampaignId)return;
  const overlay=document.querySelector('#levelUpOverlay');
  if(!overlay)return;
  const choices={};
  let missing='';
  (progression.prompts||[]).forEach(prompt=>{
    const input=overlay.querySelector(`[data-choice-key="${CSS.escape(prompt.key)}"]`);
    const value=String(input?.value||'').trim();
    choices[prompt.key]=value;
    if(!prompt.optional&&!value&&!missing)missing=prompt.label;
  });
  if(missing){overlay.querySelector('#levelUpError').textContent=`Choose or record your ${missing} before continuing.`;return;}
  levelUpActionBusy=true;
  const btn=overlay.querySelector('#finishLevelUpChoices');
  btn.disabled=true;btn.textContent='Saving Level Up...';
  try {
    const result=await api(`/game-api/campaigns/${currentCampaignId}/level-up/choices`,{method:'POST',body:JSON.stringify({choices})});
    overlay.remove();levelUpOverlaySignature='';currentProgression=null;
    const fresh=await api(`/game-api/campaigns/${currentCampaignId}/character`);
    if(fresh.hasCharacter&&fresh.character)currentGameData.character=fresh.character;
    showNotice(`Level ${result.toLevel} choices saved.`);
    if(result.needsSpellSelection){
      stopConversationLiveSync();
      stopProgressionPolling();
      await showSpellSelection(currentCampaignId,currentGameData.character,true);
    } else {
      currentGameData=await api(`/game-api/campaigns/${currentCampaignId}/bootstrap`);
    currentGameData.inventory=mergeInventoryValuations(currentGameData.inventory||[],currentGameData.inventoryValuations||[]);
      renderGameShell();
      const tab=document.querySelector('.game-tab[data-tab="character"]');
      switchGameTab('character',tab);
      await refreshCharacterProgression(true);
    }
  } catch(error) {
    overlay.querySelector('#levelUpError').textContent=error.message;
    btn.disabled=false;btn.textContent='Continue Level Up';
  } finally {
    levelUpActionBusy=false;
  }
}


// RULES BUILD 6.16 - WORLD TIME / SLEEPING LONG REST
function worldClockHtml(world) {
  if(!world)return '<div class="world-clock-chip"><span>WORLD TIME</span><b>Loading...</b></div>';
  const day=Math.max(1,Number(world.dayNumber)||1);
  const time=String(world.displayTime||'--:--');
  const weather=String(world.weatherLabel||'Clear');
  const part=String(world.dayPart||'');
  return `<div class="world-clock-chip"><span>DAY ${day}${part?` • ${escapeHtml(part)}`:''}</span><b>${escapeHtml(time)}</b><small>${escapeHtml(weather)}</small></div>`;
}

function updateWorldClockUi(world) {
  if(currentGameData)currentGameData.worldTime=world||currentGameData.worldTime;
  const host=document.querySelector('#worldClockHost');
  if(host)host.innerHTML=worldClockHtml(world||currentGameData?.worldTime);
}

function stopWorldTimePolling() {
  if(worldTimePollTimer)clearInterval(worldTimePollTimer);
  worldTimePollTimer=null;
  worldTimePollBusy=false;
}

function startWorldTimePolling() {
  stopWorldTimePolling();
  if(!currentCampaignId)return;
  void refreshWorldTime(true);
  worldTimePollTimer=setInterval(()=>void refreshWorldTime(false),5000);
}

async function refreshWorldTime(force=false) {
  if(!currentCampaignId||!currentGameData||worldTimePollBusy)return;
  worldTimePollBusy=true;
  try{
    const data=await api(`/game-api/campaigns/${currentCampaignId}/world-time`);
    const world=data.world||null;
    if(world)updateWorldClockUi(world);
  }catch(error){
    if(force)console.warn('World time refresh failed:',error);
  }finally{worldTimePollBusy=false;}
}

function stopSleepStatePolling() {
  if(sleepStatePollTimer)clearInterval(sleepStatePollTimer);
  sleepStatePollTimer=null;
  sleepStatePollBusy=false;
}

function startSleepStatePolling() {
  stopSleepStatePolling();
  if(!currentCampaignId)return;
  void refreshSleepState(true);
  sleepStatePollTimer=setInterval(()=>void refreshSleepState(false),1000);
}

function sleepDurationText(minutes) {
  const value=Math.max(0,Math.trunc(Number(minutes)||0));
  const hours=Math.floor(value/60),mins=value%60;
  return `${hours}h ${String(mins).padStart(2,'0')}m`;
}

async function refreshSleepState(force=false) {
  if(!currentCampaignId||!currentGameData||sleepStatePollBusy||sleepWakeBusy)return;
  sleepStatePollBusy=true;
  try{
    const data=await api(`/game-api/campaigns/${currentCampaignId}/sleep-state`);
    const sleep=data.sleep||null;
    lastSleepState=sleep;
    if(sleep?.world)updateWorldClockUi(sleep.world);

    if(!sleep?.sleeping){
      document.querySelector('#sleepOverlay')?.remove();
      sleepOverlaySignature='';
      return;
    }

    syncAuthoritativeCharacterHp(sleep.currentHp,sleep.maxHp);
    const signature=[
      sleep.sleepSessionId,sleep.currentHp,sleep.elapsedMinutes,
      sleep.remainingMinutes,sleep.world?.worldMinute,sleep.safeLocation,sleep.paidLodging
    ].join(':');
    if(force||signature!==sleepOverlaySignature||!document.querySelector('#sleepOverlay')){
      sleepOverlaySignature=signature;
      renderSleepingLongRestOverlay(sleep);
    }
  }catch(error){
    if(force)console.warn('Sleep state refresh failed:',error);
  }finally{sleepStatePollBusy=false;}
}

function renderSleepingLongRestOverlay(sleep) {
  let overlay=document.querySelector('#sleepOverlay');
  if(!overlay){
    overlay=document.createElement('div');
    overlay.id='sleepOverlay';
    overlay.className='sleep-overlay';
    document.body.appendChild(overlay);
  }

  const current=Math.max(0,Number(sleep.currentHp)||0);
  const max=Math.max(1,Number(sleep.maxHp)||1);
  const elapsed=Math.max(0,Number(sleep.elapsedMinutes)||0);
  const remaining=Math.max(0,Number(sleep.remainingMinutes)||0);
  const exact=Math.max(0,Number(sleep.hpRecoveryExact)||0);
  const perHour=Math.max(0,Number(sleep.hpPerHour)||0);
  const progress=Math.min(100,Math.max(0,elapsed/480*100));
  const world=sleep.world||{};
  const lodging=sleep.paidLodging
    ? `<span class="sleep-safe good">Paid ${escapeHtml(sleep.lifestyle||'')} room • ${escapeHtml(sleep.innName||'Inn')}</span>`
    : sleep.safeLocation
      ? '<span class="sleep-safe good">Safe Long Rest location</span>'
      : '<span class="sleep-safe warn">Unsecured rest location</span>';

  overlay.innerHTML=`<section class="sleep-card">
    <div class="sleep-moon">☾</div>
    <p class="eyebrow">LONG REST IN PROGRESS</p>
    <h2>${escapeHtml(sleep.characterName||'Your character')} is sleeping</h2>
    <div class="sleep-world-clock">
      <span>World Time</span>
      <b>Day ${Math.max(1,Number(world.dayNumber)||1)} • ${escapeHtml(world.displayTime||'--:--')}</b>
      <small>${escapeHtml(world.dayPart||'')} • ${escapeHtml(world.weatherLabel||'Clear')}</small>
    </div>
    <div class="sleep-hp-block">
      <div><span>HP</span><b>${current}/${max}</b></div>
      <div><span>Recovery Rate</span><b>${perHour.toFixed(2)} HP/hour</b></div>
      <div><span>Recovered</span><b>${exact.toFixed(2)} HP progress</b></div>
    </div>
    <div class="sleep-progress"><i style="width:${progress.toFixed(2)}%"></i></div>
    <div class="sleep-time-grid">
      <div><span>Time Rested</span><b>${sleepDurationText(elapsed)}</b></div>
      <div><span>Remaining</span><b>${sleepDurationText(remaining)}</b></div>
      <div><span>Required</span><b>8h 00m</b></div>
    </div>
    ${lodging}
    <p class="sleep-note">World time continues for everyone. Your HP recovers gradually as time passes. Waking before 8 hours keeps recovered HP but does not grant full Long Rest recovery.</p>
    <button id="wakeFromLongRest" class="button danger-button">Wake</button>
    <div id="sleepWakeError" class="error"></div>
  </section>`;

  const wake=overlay.querySelector('#wakeFromLongRest');
  if(wake)wake.onclick=async()=>{
    if(sleepWakeBusy)return;
    sleepWakeBusy=true;
    wake.disabled=true;wake.textContent='Waking...';
    const error=overlay.querySelector('#sleepWakeError');if(error)error.textContent='';
    try{
      const data=await api(`/game-api/campaigns/${currentCampaignId}/rest/long/wake`,{method:'POST'});
      const result=data.result||{};
      if(result.world)updateWorldClockUi(result.world);
      if(result.currentHp!==undefined)syncAuthoritativeCharacterHp(result.currentHp,result.maxHp);
      overlay.remove();sleepOverlaySignature='';lastSleepState=null;
      showNotice(result.message||'You wake before completing the Long Rest.');
      await refreshRestState(true);
    }catch(ex){
      const target=document.querySelector('#sleepWakeError');if(target)target.textContent=ex.message;
      showNotice(ex.message,true);
    }finally{
      sleepWakeBusy=false;
      void refreshSleepState(true);
    }
  };
}

function stopRestStatePolling() {
  if(restStatePollTimer)clearInterval(restStatePollTimer);
  restStatePollTimer=null;
  restStatePollBusy=false;
}

function startRestStatePolling() {
  stopRestStatePolling();
  if(!currentCampaignId)return;
  void refreshRestState(true);
  restStatePollTimer=setInterval(()=>void refreshRestState(false),1000);
}

function restResourceHtml(rest) {
  if(!rest)return '<div class="rest-resource-card"><span>Hit Dice</span><b>Loading...</b></div>';
  const total=Math.max(1,Number(rest.hitDiceTotal)||Number(rest.level)||1);
  const available=Math.max(0,Number(rest.hitDiceAvailable)||0);
  const sides=Math.max(4,Number(rest.hitDieSides)||8);
  return `<div class="rest-resource-card"><span>Hit Dice</span><b>${available}/${total} d${sides}</b><small>${Math.max(0,total-available)} spent • Long Rest restores all</small></div>`;
}

function updateRestResourceUi(rest) {
  const host=document.querySelector('#restResourceHost');
  if(host)host.innerHTML=restResourceHtml(rest);
}

function syncAuthoritativeCharacterHp(hpValue,maxHpValue) {
  if(!currentGameData?.character)return;
  const hp=Number(hpValue),maxHp=Number(maxHpValue);
  if(Number.isFinite(hp))currentGameData.character.currentHp=Math.max(0,Math.trunc(hp));
  if(Number.isFinite(maxHp)&&maxHp>0)currentGameData.character.maxHp=Math.max(1,Math.trunc(maxHp));

  const self=Array.isArray(currentGameData.party)
    ? currentGameData.party.find(p=>p.characterId===currentGameData.character.characterId)
    : null;
  if(self){self.currentHp=currentGameData.character.currentHp;self.maxHp=currentGameData.character.maxHp;}

  const text=`${currentGameData.character.currentHp}/${currentGameData.character.maxHp}`;
  document.querySelectorAll('[data-live-self-hp]').forEach(node=>{node.textContent=text;});
}

async function refreshRestState(force=false) {
  if(!currentCampaignId||!currentGameData||restStatePollBusy||restActionBusy)return;
  restStatePollBusy=true;
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/rest-state`);
    const rest=data.rest||null;
    const previous=lastRestState;
    lastRestState=rest;
    updateRestResourceUi(rest);

    if(rest&&currentGameData?.character)syncAuthoritativeCharacterHp(rest.currentHp,rest.maxHp);

    const status=String(rest?.status||'');
    if(!status){
      document.querySelector('#restOverlay')?.remove();
      restOverlaySignature='';
      return;
    }

    // A level-up overlay owns the screen first. The long-rest spell workflow follows it.
    if(document.querySelector('#levelUpOverlay'))return;

    const rolls=Array.isArray(rest?.rollLog)?rest.rollLog:[];
    const signature=`${rest.characterId}:${status}:${rest.currentHp}:${rest.hitDiceAvailable}:${rest.hitDiceSpentThisRest}:${rolls.length}`;
    if(force||signature!==restOverlaySignature||!document.querySelector('#restOverlay')){
      restOverlaySignature=signature;
      if(status==='awaiting_hit_dice')renderShortRestOverlay(rest);
      else if(status==='spell_review'||status==='long_complete')renderLongRestOverlay(rest);
    }

  } catch(error) {
    console.warn('Rest state refresh failed:',error);
  } finally {
    restStatePollBusy=false;
  }
}

function restRollLogHtml(rest) {
  const rolls=Array.isArray(rest?.rollLog)?rest.rollLog:[];
  if(!rolls.length)return '<div class="rest-roll-empty">No Hit Dice spent yet.</div>';
  return `<div class="rest-roll-log">${rolls.map((r,index)=>`<div><span>Die ${index+1}: d${Number(r.dieSides)||Number(rest.hitDieSides)||8}</span><b>${Number(r.roll)||0} ${formatSigned(Number(r.constitutionModifier)||0)} = ${Number(r.healing)||0} HP</b><small>HP ${Number(r.hpAfter)||0}/${Number(rest.maxHp)||0}</small></div>`).join('')}</div>`;
}

function renderShortRestOverlay(rest) {
  let overlay=document.querySelector('#restOverlay');
  if(!overlay){overlay=document.createElement('div');overlay.id='restOverlay';overlay.className='rest-overlay';document.body.appendChild(overlay);}
  const hp=Math.max(0,Number(rest.currentHp)||0),maxHp=Math.max(1,Number(rest.maxHp)||1);
  const total=Math.max(1,Number(rest.hitDiceTotal)||Number(rest.level)||1),available=Math.max(0,Number(rest.hitDiceAvailable)||0);
  const sides=Math.max(4,Number(rest.hitDieSides)||8),spentThis=Math.max(0,Number(rest.hitDiceSpentThisRest)||0);
  const canRoll=hp<maxHp&&available>0&&spentThis<total;
  overlay.innerHTML=`<section class="rest-card short-rest-card">
    <div class="rest-icon">☕</div><p class="eyebrow">Short Rest Complete</p><h2>${escapeHtml(rest.characterName||'Character')}</h2>
    <p>The rest was completed successfully. You may now spend any of your available Hit Dice, one at a time.</p>
    <div class="rest-vitals"><div><span>HP</span><b>${hp}/${maxHp}</b></div><div><span>Hit Dice Available</span><b>${available}/${total} d${sides}</b></div><div><span>Spent This Rest</span><b>${spentThis}/${total}</b></div></div>
    <p class="rest-rule-note">Each d${sides} roll adds your Constitution modifier. Healing from each die is at least 1 HP. You may stop after any roll.</p>
    ${restRollLogHtml(rest)}
    <div class="rest-actions"><button id="rollRestHitDie" class="button primary" ${canRoll?'':'disabled'}>Roll 1 d${sides} Hit Die</button><button id="finishShortRest" class="button">Finish Short Rest</button></div>
    ${hp>=maxHp?'<small class="rest-hint">You are already at full HP; you do not need to spend a Hit Die.</small>':available<1?'<small class="rest-hint">No Hit Dice remain. Complete a Long Rest to restore them.</small>':''}
    <div id="restActionError" class="error"></div>
  </section>`;
  const roll=overlay.querySelector('#rollRestHitDie');if(roll)roll.onclick=()=>runRestAction(async()=>{
    const data=await api(`/game-api/campaigns/${currentCampaignId}/rest/short/hit-die`,{method:'POST'});
    const r=data.result||{};showNotice(`Hit Die: ${Number(r.roll)||0} ${formatSigned(Number(r.constitutionModifier)||0)} = ${Number(r.healing)||0} HP recovered.`);
  });
  overlay.querySelector('#finishShortRest').onclick=()=>runRestAction(async()=>{
    await api(`/game-api/campaigns/${currentCampaignId}/rest/short/finish`,{method:'POST'});
    document.querySelector('#restOverlay')?.remove();restOverlaySignature='';showNotice('Short Rest finished.');
  });
}

function renderLongRestOverlay(rest) {
  let overlay=document.querySelector('#restOverlay');
  if(!overlay){overlay=document.createElement('div');overlay.id='restOverlay';overlay.className='rest-overlay';document.body.appendChild(overlay);}
  const canReview=String(rest.status||'')==='spell_review';
  overlay.innerHTML=`<section class="rest-card long-rest-card">
    <div class="rest-icon">✦</div><p class="eyebrow">You Wake from a Long Rest</p><h2>Long Rest Complete</h2>
    <p>${escapeHtml(rest.characterName||'Your character')} is fully rested.</p>
    <div class="rest-summary-list"><span>HP restored to <b>${Number(rest.currentHp)||0}/${Number(rest.maxHp)||0}</b></span><span>All spent Hit Dice restored: <b>${Number(rest.hitDiceAvailable)||0}/${Number(rest.hitDiceTotal)||0}</b></span><span>Tracked spell slots/resources restored to full.</span></div>
    ${canReview?'<p class="rest-spell-review">Your class uses spells. Would you like to review or change your spell choices before continuing?</p>':''}
    <div class="rest-actions">${canReview?'<button id="reviewRestSpells" class="button primary">Review / Change Spells</button><button id="keepRestSpells" class="button">Keep Current Spells</button>':'<button id="finishLongRest" class="button primary">Continue</button>'}</div>
    <div id="restActionError" class="error"></div>
  </section>`;
  const review=overlay.querySelector('#reviewRestSpells');if(review)review.onclick=()=>runRestAction(async()=>{
    await api(`/game-api/campaigns/${currentCampaignId}/rest/long/review`,{method:'POST',body:JSON.stringify({reviewSpells:true})});
    document.querySelector('#restOverlay')?.remove();restOverlaySignature='';
    const fresh=await api(`/game-api/campaigns/${currentCampaignId}/character`);if(fresh.hasCharacter&&fresh.character)currentGameData.character=fresh.character;
    stopConversationLiveSync();stopRestStatePolling();await showSpellSelection(currentCampaignId,currentGameData.character,false);
  });
  const keep=overlay.querySelector('#keepRestSpells');if(keep)keep.onclick=()=>runRestAction(async()=>{
    await api(`/game-api/campaigns/${currentCampaignId}/rest/long/review`,{method:'POST',body:JSON.stringify({reviewSpells:false})});
    document.querySelector('#restOverlay')?.remove();restOverlaySignature='';showNotice('Long Rest complete. Current spells kept.');
    currentGameData=await api(`/game-api/campaigns/${currentCampaignId}/bootstrap`);
    currentGameData.inventory=mergeInventoryValuations(currentGameData.inventory||[],currentGameData.inventoryValuations||[]);
    renderGameShell();renderGameMasterTab();
  });
  const finish=overlay.querySelector('#finishLongRest');if(finish)finish.onclick=()=>runRestAction(async()=>{
    await api(`/game-api/campaigns/${currentCampaignId}/rest/long/review`,{method:'POST',body:JSON.stringify({reviewSpells:false})});
    document.querySelector('#restOverlay')?.remove();restOverlaySignature='';showNotice('Long Rest complete.');
    currentGameData=await api(`/game-api/campaigns/${currentCampaignId}/bootstrap`);
    currentGameData.inventory=mergeInventoryValuations(currentGameData.inventory||[],currentGameData.inventoryValuations||[]);
    renderGameShell();renderGameMasterTab();
  });
}

async function runRestAction(action) {
  if(restActionBusy)return;
  restActionBusy=true;
  document.querySelectorAll('#restOverlay button').forEach(b=>b.disabled=true);
  const error=document.querySelector('#restActionError');if(error)error.textContent='';
  try{await action();}
  catch(ex){const e=document.querySelector('#restActionError');if(e)e.textContent=ex.message;showNotice(ex.message,true);}
  finally{restActionBusy=false;if(currentCampaignId)await refreshRestState(true);}
}

function stopDeathStatePolling() {
  if(deathStatePollTimer)clearInterval(deathStatePollTimer);
  deathStatePollTimer=null;
  deathStatePollBusy=false;
}

function startDeathStatePolling() {
  stopDeathStatePolling();
  if(!currentCampaignId)return;
  void refreshDeathState(true);
  deathStatePollTimer=setInterval(()=>void refreshDeathState(false),1000);
}

async function reloadCampaignAfterDeathResolution() {
  if(!currentCampaignId)return;
  currentGameData=await api(`/game-api/campaigns/${currentCampaignId}/bootstrap`);
    currentGameData.inventory=mergeInventoryValuations(currentGameData.inventory||[],currentGameData.inventoryValuations||[]);
  activeGameTab='gm';
  gmTurnState=null;
  gmTurnToken=null;
  gmTurnDraft='';
  renderGameShell();
  renderGameMasterTab();
}

// RULES BUILD 6.14.2 v5 - Normalize Supabase/ASP.NET respawn DTO field names.
// DeathStateRow and DeathActionResult carry JsonPropertyName(snake_case) for Supabase,
// while older client code reads camelCase. Accept both so Discord and browser clients
// render the same authoritative respawn state.
function normalizeRespawnPayload(value) {
  if(!value||typeof value!=='object')return value;
  const pick=(camel,snake,fallback)=>{
    const camelValue=value[camel];
    if(camelValue!==undefined&&camelValue!==null)return camelValue;
    const snakeValue=value[snake];
    if(snakeValue!==undefined&&snakeValue!==null)return snakeValue;
    return fallback;
  };
  return {
    ...value,
    deathId:pick('deathId','death_id',null),
    deadPlayerId:pick('deadPlayerId','dead_player_id',null),
    deadCharacterName:pick('deadCharacterName','dead_character_name',''),
    requiredGp:pick('requiredGp','required_gp',10),
    donatedGp:pick('donatedGp','donated_gp',0),
    remainingGp:pick('remainingGp','remaining_gp',10),
    viewerIsDeadPlayer:pick('viewerIsDeadPlayer','viewer_is_dead_player',false),
    viewerIsEligibleDonor:pick('viewerIsEligibleDonor','viewer_is_eligible_donor',false),
    viewerDecision:pick('viewerDecision','viewer_decision',''),
    viewerDonatedGp:pick('viewerDonatedGp','viewer_donated_gp',0),
    viewerGold:pick('viewerGold','viewer_gold',0),
    deadCharacterGold:pick('deadCharacterGold','dead_character_gold',0),
    eligibleDonorCount:pick('eligibleDonorCount','eligible_donor_count',0),
    answeredDonorCount:pick('answeredDonorCount','answered_donor_count',0),
    canFinalize:pick('canFinalize','can_finalize',false),
    characterName:pick('characterName','character_name',''),
    requiresNewCharacter:pick('requiresNewCharacter','requires_new_character',false),
    paidGp:pick('paidGp','paid_gp',0),
    currentHp:pick('currentHp','current_hp',0),
    maxHp:pick('maxHp','max_hp',0),
    remainingGold:pick('remainingGold','remaining_gold',undefined),
    donorCharacterName:pick('donorCharacterName','donor_character_name',''),
    donatedNow:pick('donatedNow','donated_now',0),
    refundedGp:pick('refundedGp','refunded_gp',0)
  };
}

async function refreshDeathState(force=false) {
  if(!currentCampaignId||deathStatePollBusy||deathActionBusy)return;
  deathStatePollBusy=true;
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/death-state`);
    const death=normalizeRespawnPayload(data.death||null);
    const previous=lastDeathState;
    if(!death) {
      document.querySelector('#deathOverlay')?.remove();
      document.body.classList.remove('death-modal-open');
      lastDeathState=null;
      deathDonationMode=false;
      if(previous&&currentGameData&&(previous.viewerIsDeadPlayer||Number(previous.viewerDonatedGp)>0)) {
        await reloadCampaignAfterDeathResolution();
        if(previous.viewerIsDeadPlayer)showNotice(`${previous.deadCharacterName||'Your character'} has returned to play.`);
      }
      return;
    }
    if(previous?.deathId&&previous.deathId!==death.deathId)deathDonationMode=false;
    const signature=`${death.deathId}:${death.status}:${death.donatedGp}:${death.viewerDecision}:${death.canFinalize}:${death.viewerGold}`;
    const oldSignature=previous?`${previous.deathId}:${previous.status}:${previous.donatedGp}:${previous.viewerDecision}:${previous.canFinalize}:${previous.viewerGold}`:'';
    lastDeathState=death;
    if(force||signature!==oldSignature||!document.querySelector('#deathOverlay'))renderDeathOverlay(death);
  } catch(error) {
    console.warn('Death / Respawn live state refresh failed:',error);
  } finally {
    deathStatePollBusy=false;
  }
}

function respawnProgressHtml(death) {
  const required=Math.max(1,Number(death.requiredGp)||10);
  const donated=Math.max(0,Number(death.donatedGp)||0);
  const percent=Math.max(0,Math.min(100,(donated/required)*100));
  return `<div class="respawn-fund">
    <div class="respawn-fund-heading"><span>Party Respawn Fund</span><b>${donated} / ${required} GP</b></div>
    <div class="respawn-progress"><i style="width:${percent}%"></i></div>
    <small>${Math.max(0,required-donated)} GP still needed</small>
  </div>`;
}

function renderDeathOverlay(death) {
  let overlay=document.querySelector('#deathOverlay');
  if(!overlay) {
    overlay=document.createElement('div');
    overlay.id='deathOverlay';
    overlay.className='death-overlay';
    document.body.appendChild(overlay);
  }
  document.body.classList.add('death-modal-open');

  const name=escapeHtml(death.deadCharacterName||'Character');
  const cause=death.cause?`<p class="death-cause"><b>Cause:</b> ${escapeHtml(death.cause)}</p>`:'';
  const status=String(death.status||'').trim().toLowerCase().replace(/[\s-]+/g,'_');
  // discord_get_death_state only returns awaiting_choice to the player who died.
  // Treat that status itself as authoritative so a missing/mis-serialized viewer flag
  // can never leave the player staring at an empty dark overlay.
  const viewerIsDeadPlayer=death.viewerIsDeadPlayer===true||status==='awaiting_choice';
  let body='';

  if(viewerIsDeadPlayer&&status==='awaiting_choice') {
    const gold=Math.max(0,Number(death.deadCharacterGold)||0);
    body=`<div class="death-card dead-player-card">
      <div class="death-icon">☠</div><h2>${name} Has Died</h2>${cause}
      <p>Normal D&amp;D revival magic or a valid revival item can still return this character. You may also use the campaign Respawn system.</p>
      <div class="death-price"><span>Respawn Price</span><b>10 GP</b><small>You currently have ${currencyPurseText(gold)}.</small></div>
      <p>If you choose Respawn and cannot pay 10 GP yourself, the other active players will be asked to donate. If you choose No, this character remains dead and you will create a replacement character for this campaign.</p>
      <div class="death-actions"><button id="deathRespawnYes" class="button primary">Yes — Respawn</button><button id="deathRespawnNo" class="button danger">No — Create New Character</button></div>
      <div id="deathActionError" class="error"></div>
    </div>`;
  } else if(status==='awaiting_donations') {
    const progress=respawnProgressHtml(death);
    const finalize=death.canFinalize?`<button id="deathFinalizeRespawn" class="button primary wide">Respawn ${name}</button>`:'';
    if(viewerIsDeadPlayer) {
      body=`<div class="death-card dead-player-card"><div class="death-icon">✦</div><h2>Waiting for Party Revival</h2>${cause}
        <p>${name} did not have enough GP for Respawn. The other active players have been asked to contribute toward the 10 GP price.</p>${progress}${finalize}
        <p class="muted">A valid D&amp;D revival spell or revival item can still revive you while this fund is open.</p><div id="deathActionError" class="error"></div></div>`;
    } else if(death.viewerIsEligibleDonor) {
      const decision=String(death.viewerDecision||'').toLowerCase();
      const donatedByViewer=Math.max(0,Number(death.viewerDonatedGp)||0);
      const viewerGold=Math.max(0,Number(death.viewerGold)||0);
      const viewerWholeGp=Math.floor(viewerGold);
      const remaining=Math.max(0,Number(death.remainingGp)||0);
      const canDonateOne=viewerWholeGp>=1&&remaining>0;
      let controls='';
      if(death.canFinalize) {
        controls='<div class="death-decision-note">The full 10 GP has been collected. Respawn is ready.</div>';
      } else if(decision==='decline') {
        controls='<div class="death-decision-note">You declined this donation request. Other active players may still contribute.</div>';
      } else if(decision==='donate'||deathDonationMode) {
        controls=`<div class="donation-controls"><label>Donate 1 GP at a time (purse: ${currencyPurseText(viewerGold)})</label><div class="row gap"><button id="deathDonateGp" class="button primary" ${canDonateOne?'':'disabled'}>Donate 1 GP</button>${decision?'':'<button id="deathDonationCancel" class="button">Cancel</button>'}</div><small>Each click contributes exactly 1 GP. ${Math.max(0,remaining)} GP remains before ${name} can Respawn.</small>${donatedByViewer?`<small>You have donated ${donatedByViewer} GP to this Respawn fund.</small>`:''}${!canDonateOne&&remaining>0?'<small class="muted">You do not currently have 1 full GP available to donate.</small>':''}</div>`;
      } else {
        controls=`<div class="death-actions"><button id="deathDonationYes" class="button primary" ${viewerWholeGp<1?'disabled':''}>Yes — Donate</button><button id="deathDonationNo" class="button danger">No</button></div>${viewerWholeGp<1?'<small class="muted">You do not currently have 1 full GP available to donate.</small>':''}`;
      }
      body=`<div class="death-card donation-card"><div class="death-icon">⚕</div><h2>Party Member Needs Revival</h2>
        <p><b>${name}</b> has died and does not have enough gold to respawn. Do you want to donate GP to Respawn them? <b>10 GP is required.</b></p>${progress}${controls}${finalize}<div id="deathActionError" class="error"></div></div>`;
    } else {
      body=`<div class="death-card donation-card"><div class="death-icon">⚕</div><h2>Respawn Fund in Progress</h2><p>The party is raising GP to Respawn <b>${name}</b>.</p>${progress}${finalize}<div id="deathActionError" class="error"></div></div>`;
    }
  }

  if(!body) {
    const safeStatus=escapeHtml(status||'unknown');
    body=`<div class="death-card dead-player-card">
      <div class="death-icon">☠</div><h2>${name} Has Died</h2>${cause}
      <p>The Respawn state is active, but this client received an unexpected state (<b>${safeStatus}</b>).</p>
      <p>Please refresh the Activity. Your character and Respawn record are still stored safely on the server.</p>
      <div id="deathActionError" class="error"></div>
    </div>`;
  }

  overlay.innerHTML=body;
  wireDeathOverlayActions(death);
}

function setDeathActionError(message='') {
  const el=document.querySelector('#deathActionError');
  if(el)el.textContent=message;
}

async function runDeathAction(action) {
  if(deathActionBusy)return;
  deathActionBusy=true;
  document.querySelectorAll('#deathOverlay button').forEach(b=>b.disabled=true);
  setDeathActionError('');
  try { await action(); }
  catch(error) { setDeathActionError(error.message); showNotice(error.message,true); }
  finally {
    deathActionBusy=false;
    await refreshDeathState(true);
  }
}

function wireDeathOverlayActions(death) {
  const yes=document.querySelector('#deathRespawnYes');
  if(yes)yes.onclick=()=>runDeathAction(async()=>{
    const data=await api(`/game-api/campaigns/${currentCampaignId}/death/choice`,{method:'POST',body:JSON.stringify({respawn:true})});
    data.result=normalizeRespawnPayload(data.result);
    if(data.result?.outcome==='self_paid_respawn'||data.result?.outcome==='rag_respawn') {
      lastDeathState=null; document.querySelector('#deathOverlay')?.remove();
      document.body.classList.remove('death-modal-open');
      await reloadCampaignAfterDeathResolution();
    }
  });

  const no=document.querySelector('#deathRespawnNo');
  if(no)no.onclick=()=>runDeathAction(async()=>{
    const data=await api(`/game-api/campaigns/${currentCampaignId}/death/choice`,{method:'POST',body:JSON.stringify({respawn:false})});
    data.result=normalizeRespawnPayload(data.result);
    if(data.result?.requiresNewCharacter||data.result?.outcome==='new_character') {
      stopDeathStatePolling();
      lastDeathState=null;
      document.querySelector('#deathOverlay')?.remove();
      document.body.classList.remove('death-modal-open');
      currentGameData=null;
      await showCharacterCreator(currentCampaignId);
    }
  });

  const donateYes=document.querySelector('#deathDonationYes');
  if(donateYes)donateYes.onclick=()=>runDeathAction(async()=>{
    await api(`/game-api/campaigns/${currentCampaignId}/death/${death.deathId}/accept-donation`,{method:'POST'});
    deathDonationMode=false;
  });
  const cancel=document.querySelector('#deathDonationCancel');
  if(cancel)cancel.onclick=()=>{deathDonationMode=false;renderDeathOverlay(death);};

  const donate=document.querySelector('#deathDonateGp');
  if(donate)donate.onclick=()=>runDeathAction(async()=>{
    const data=await api(`/game-api/campaigns/${currentCampaignId}/death/${death.deathId}/donate`,{method:'POST',body:JSON.stringify({amountGp:1})});
    data.result=normalizeRespawnPayload(data.result);
    deathDonationMode=false;
    if(currentGameData?.character&&data.result?.remainingGold!==undefined)currentGameData.character.gold=data.result.remainingGold;
    updateLiveGoldDisplay();
    if(data.result?.outcome==='rag_respawn')showNotice('Party Respawn could not be funded.');
    else if(data.result?.canFinalize)showNotice(`The Respawn fund has reached 10 GP. ${death.deadCharacterName||'The fallen player'} can now be Respawned.`);
    else showNotice(`1 GP donated. ${Math.max(0,Number(data.result?.remainingGp)||0)} GP still needed.`);
  });

  const decline=document.querySelector('#deathDonationNo');
  if(decline)decline.onclick=()=>runDeathAction(async()=>{
    deathDonationMode=false;
    await api(`/game-api/campaigns/${currentCampaignId}/death/${death.deathId}/decline`,{method:'POST'});
  });

  const revive=document.querySelector('#deathFinalizeRespawn');
  if(revive)revive.onclick=()=>runDeathAction(async()=>{
    await api(`/game-api/campaigns/${currentCampaignId}/death/${death.deathId}/revive`,{method:'POST'});
    showNotice(`${death.deadCharacterName} has been Respawned at half health.`);
  });
}

function timelineDisplayText(value) {
  return String(value ?? '')
    .replace(/^\[WORLD MAP TRAVEL REQUEST\]\s*/i, '')
    .replace(/^\[SETTLEMENT MOVE\]\s*/i, '');
}

const GM_VOICE_DEFAULTS=Object.freeze({enabled:false,voiceURI:'',rate:1,pitch:1,volume:1});

function gmVoiceSupported() {
  return typeof window!=='undefined' &&
    'speechSynthesis' in window &&
    typeof window.SpeechSynthesisUtterance==='function';
}

function gmVoiceStorageKey() {
  const owner=String(currentDiscordUser?.id||'local');
  return `rabushin.gmVoice.${owner}.v1`;
}

function normalizeGmVoicePreferences(value={}) {
  const number=(input,fallback,min,max)=>{
    const n=Number(input);
    return Number.isFinite(n)?Math.max(min,Math.min(max,n)):fallback;
  };
  return {
    enabled:Boolean(value.enabled),
    voiceURI:String(value.voiceURI||''),
    rate:number(value.rate,GM_VOICE_DEFAULTS.rate,.5,2),
    pitch:number(value.pitch,GM_VOICE_DEFAULTS.pitch,0,2),
    volume:number(value.volume,GM_VOICE_DEFAULTS.volume,0,1)
  };
}

function getGmVoicePreferences() {
  const owner=String(currentDiscordUser?.id||'local');
  if(gmVoicePreferences&&gmVoicePreferencesOwnerId===owner)return gmVoicePreferences;
  gmVoicePreferencesOwnerId=owner;
  let stored=null;
  try { stored=JSON.parse(localStorage.getItem(gmVoiceStorageKey())||'null'); }
  catch(error) { console.warn('Unable to read GM voice preferences:',error); }
  gmVoicePreferences=normalizeGmVoicePreferences(stored||GM_VOICE_DEFAULTS);
  return gmVoicePreferences;
}

function saveGmVoicePreferences(patch={}) {
  gmVoicePreferences=normalizeGmVoicePreferences({...getGmVoicePreferences(),...patch});
  try { localStorage.setItem(gmVoiceStorageKey(),JSON.stringify(gmVoicePreferences)); }
  catch(error) { console.warn('Unable to save GM voice preferences:',error); }
  return gmVoicePreferences;
}

function refreshGmVoiceList() {
  if(!gmVoiceSupported()) {
    gmVoiceAvailableVoices=[];
    return gmVoiceAvailableVoices;
  }
  try {
    gmVoiceAvailableVoices=[...(window.speechSynthesis.getVoices?.()||[])];
  } catch(error) {
    console.warn('Unable to load speech synthesis voices:',error);
    gmVoiceAvailableVoices=[];
  }
  return gmVoiceAvailableVoices;
}

function bindGmVoiceEventsOnce() {
  if(!gmVoiceSupported()||gmVoiceVoicesChangedBound)return;
  gmVoiceVoicesChangedBound=true;
  refreshGmVoiceList();
  const refresh=()=>{
    refreshGmVoiceList();
    if(activeGameTab==='settings'&&document.querySelector('#gmVoiceSelect'))populateGmVoiceSelect();
  };
  if(typeof window.speechSynthesis.addEventListener==='function')window.speechSynthesis.addEventListener('voiceschanged',refresh);
  else window.speechSynthesis.onvoiceschanged=refresh;
}

function selectedGmVoice() {
  if(!gmVoiceSupported())return null;
  if(!gmVoiceAvailableVoices.length)refreshGmVoiceList();
  const prefs=getGmVoicePreferences();
  if(prefs.voiceURI) {
    const exact=gmVoiceAvailableVoices.find(v=>String(v.voiceURI||v.name)===prefs.voiceURI);
    if(exact)return exact;
  }
  return gmVoiceAvailableVoices.find(v=>String(v.lang||'').toLowerCase()==='en-us')||
    gmVoiceAvailableVoices.find(v=>String(v.lang||'').toLowerCase().startsWith('en'))||
    gmVoiceAvailableVoices.find(v=>v.default)||null;
}

function gmVoiceMessageKey(message,index=0) {
  return String(message?.messageId||message?.id||message?.createdAt||`index:${index}`);
}

function newestAssistantMessage(messages) {
  const list=messages||[];
  for(let i=list.length-1;i>=0;i--) {
    if(String(list[i]?.roleName||'').toLowerCase()==='assistant')return {message:list[i],index:i,key:gmVoiceMessageKey(list[i],i)};
  }
  return null;
}

function initializeGmVoiceBaseline(messages) {
  const latest=newestAssistantMessage(messages);
  gmVoiceBaselineInitialized=true;
  gmVoiceLastSeenMessageKey=latest?.key||'';
}

function gmVoiceSpeakableText(value) {
  let text=timelineDisplayText(value).replace(/\r/g,'');
  // Skip fenced code/stat blocks and standalone mechanical roll lines. Narration
  // and dialogue remain visible in the chat and are what the narrator speaks.
  text=text.replace(/```[\s\S]*?```/g,' ');
  const spokenLines=text.split('\n').filter(line=>{
    const trimmed=line.trim();
    if(!trimmed)return true;
    if(/^\|.*\|$/.test(trimmed))return false;
    if(/^[-:|\s]{3,}$/.test(trimmed))return false;
    if(/^(attack roll|damage|initiative|armor class|hit points|hp|ac|dc|saving throw|dice roll|roll result)\s*:/i.test(trimmed))return false;
    if(/^\[(system|tool|debug|combat state|inventory state)\]/i.test(trimmed))return false;
    return true;
  });
  text=spokenLines.join('\n')
    .replace(/!\[([^\]]*)\]\([^)]*\)/g,'$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g,'$1')
    .replace(/https?:\/\/\S+/gi,' ')
    .replace(/^\s{0,3}#{1,6}\s*/gm,'')
    .replace(/^\s*>\s?/gm,'')
    .replace(/^\s*[-+]\s+/gm,'')
    .replace(/^\s*\d+\.\s+/gm,'')
    .replace(/[*_~`]/g,'')
    .replace(/\b(\d+)d(\d+)(?:\s*([+-])\s*(\d+))?\b/gi,(_,count,sides,sign,bonus)=>`${count} d ${sides}${sign&&bonus?` ${sign==='+'?'plus':'minus'} ${bonus}`:''}`)
    .replace(/\s+/g,' ')
    .trim();
  return text;
}

function splitGmVoiceText(text,maxLength=520) {
  const clean=String(text||'').trim();
  if(!clean)return [];
  const sentences=clean.match(/[^.!?]+[.!?]+(?:[\"'’”]+)?|[^.!?]+$/g)||[clean];
  const chunks=[];
  let current='';
  const pushWords=(sentence)=>{
    const words=sentence.trim().split(/\s+/);
    let part='';
    for(const word of words) {
      if(part&&`${part} ${word}`.length>maxLength) { chunks.push(part); part=word; }
      else part=part?`${part} ${word}`:word;
    }
    if(part)chunks.push(part);
  };
  for(const raw of sentences) {
    const sentence=raw.trim();
    if(!sentence)continue;
    if(sentence.length>maxLength) {
      if(current){chunks.push(current);current='';}
      pushWords(sentence);
      continue;
    }
    const next=current?`${current} ${sentence}`:sentence;
    if(next.length>maxLength){if(current)chunks.push(current);current=sentence;}
    else current=next;
  }
  if(current)chunks.push(current);
  return chunks;
}

function stopGmVoicePlayback() {
  if(gmVoiceSupported()) {
    try { window.speechSynthesis.cancel(); }
    catch(error) { console.warn('Unable to stop GM voice playback:',error); }
  }
  gmVoiceCurrentMessageKey='';
  document.querySelectorAll('.gm-voice-speaking').forEach(el=>el.classList.remove('gm-voice-speaking'));
}

function speakGmVoiceText(rawText,{messageKey='',manual=false}={}) {
  if(!gmVoiceSupported()) {
    if(manual)showNotice('This browser does not provide a speech-synthesis voice.',true);
    return false;
  }
  bindGmVoiceEventsOnce();
  const text=gmVoiceSpeakableText(rawText);
  if(!text) {
    if(manual)showNotice('This GM response contains no narration or dialogue to speak.',true);
    return false;
  }
  const chunks=splitGmVoiceText(text);
  if(!chunks.length)return false;
  const prefs=getGmVoicePreferences();
  const voice=selectedGmVoice();
  stopGmVoicePlayback();
  gmVoiceCurrentMessageKey=messageKey;
  const messageElement=messageKey?document.querySelector(`[data-gm-message-key="${CSS.escape(messageKey)}"]`):null;
  messageElement?.classList.add('gm-voice-speaking');
  chunks.forEach((chunk,index)=>{
    const utterance=new window.SpeechSynthesisUtterance(chunk);
    if(voice)utterance.voice=voice;
    utterance.rate=prefs.rate;
    utterance.pitch=prefs.pitch;
    utterance.volume=prefs.volume;
    if(index===chunks.length-1)utterance.onend=()=>{
      if(gmVoiceCurrentMessageKey===messageKey)gmVoiceCurrentMessageKey='';
      messageElement?.classList.remove('gm-voice-speaking');
    };
    utterance.onerror=(event)=>{
      if(event?.error==='interrupted'||event?.error==='canceled')return;
      console.warn('GM voice playback error:',event?.error||event);
      if(manual)showNotice(`GM voice could not play${event?.error?`: ${event.error}`:'.'}`,true);
    };
    window.speechSynthesis.speak(utterance);
  });
  return true;
}

function considerAutomaticGmVoice(messages) {
  const latest=newestAssistantMessage(messages);
  if(!gmVoiceBaselineInitialized) {
    initializeGmVoiceBaseline(messages);
    return;
  }
  if(!latest)return;
  if(latest.key===gmVoiceLastSeenMessageKey)return;
  gmVoiceLastSeenMessageKey=latest.key;
  if(!getGmVoicePreferences().enabled)return;
  speakGmVoiceText(latest.message.messageText,{messageKey:latest.key,manual:false});
}

function gmVoiceControlsHtml(message,index) {
  if(!gmVoiceSupported()||String(message?.roleName||'').toLowerCase()!=='assistant')return '';
  const key=escapeHtml(gmVoiceMessageKey(message,index));
  return `<div class="gm-voice-message-actions"><button class="gm-voice-mini-button" type="button" data-gm-voice-speak="${key}" title="Speak this Game Master response again">🔊 Speak Again</button><button class="gm-voice-mini-button" type="button" data-gm-voice-stop title="Stop Game Master voice">⏹ Stop</button></div>`;
}

function timelineHtml(messages, emptyText='No messages yet.', includeGmVoiceControls=false) {
  if(!messages?.length)return `<div class="empty small">${escapeHtml(emptyText)}</div>`;
  return messages.map((m,index)=>{
    const assistant=String(m.roleName||'').toLowerCase()==='assistant';
    const key=assistant?escapeHtml(gmVoiceMessageKey(m,index)):'';
    return `<div class="message ${assistant?'assistant':'user'}${assistant&&gmVoiceCurrentMessageKey===gmVoiceMessageKey(m,index)?' gm-voice-speaking':''}"${assistant&&includeGmVoiceControls?` data-gm-message-key="${key}"`:''}><div class="message-name">${escapeHtml(m.senderName||m.roleName)}</div><div>${escapeHtml(timelineDisplayText(m.messageText)).replaceAll('\n','<br>')}</div>${includeGmVoiceControls?gmVoiceControlsHtml(m,index):''}</div>`;
  }).join('');
}

function bindGmVoiceTimelineControls() {
  const timeline=document.querySelector('#gmTimeline');
  if(!timeline||timeline.dataset.gmVoiceBound==='true')return;
  timeline.dataset.gmVoiceBound='true';
  timeline.addEventListener('click',event=>{
    const speakButton=event.target.closest('[data-gm-voice-speak]');
    if(speakButton) {
      const key=String(speakButton.dataset.gmVoiceSpeak||'');
      const list=currentGameData?.gmMessages||[];
      const match=list.find((m,index)=>gmVoiceMessageKey(m,index)===key);
      if(match)speakGmVoiceText(match.messageText,{messageKey:key,manual:true});
      return;
    }
    if(event.target.closest('[data-gm-voice-stop]'))stopGmVoicePlayback();
  });
}

function messageListSignature(messages) {
  const list=messages||[];
  if(!list.length)return '0';
  const last=list[list.length-1];
  return `${list.length}:${last.messageId||0}:${last.createdAt||''}`;
}

function updateLiveTimeline(elementId,messages,emptyText,signatureName,force=false) {
  const timeline=document.querySelector(`#${elementId}`);
  if(!timeline)return;
  const signature=messageListSignature(messages);
  const previous=signatureName==='gm'?gmMessageSignature:chatMessageSignature;
  if(!force&&signature===previous)return;
  timeline.innerHTML=timelineHtml(messages,emptyText,signatureName==='gm');
  timeline.scrollTop=timeline.scrollHeight;
  if(signatureName==='gm'){
    gmMessageSignature=signature;
    bindGmVoiceTimelineControls();
    considerAutomaticGmVoice(messages);
  }
  else chatMessageSignature=signature;
}

function stopConversationLiveSync() {
  if(conversationLiveSyncTimer)clearTimeout(conversationLiveSyncTimer);
  conversationLiveSyncTimer=null;
  conversationLiveSyncBusy=false;
  if(gmTurnCountdownTimer)clearInterval(gmTurnCountdownTimer);
  gmTurnCountdownTimer=null;
  gmTurnInputHeartbeatQueued=false;
}

function normalizeGmTurnState(state) {
  const normalized={
    active:!!state?.active,
    processing:!!state?.processing,
    isOwner:!!state?.isOwner,
    ownerPlayerId:state?.ownerPlayerId||null,
    ownerName:String(state?.ownerName||''),
    lockToken:state?.lockToken||null,
    remainingSeconds:Math.max(0,Number(state?.remainingSeconds)||0),
    expiresAt:state?.expiresAt||null,
    _deadlineMs:null
  };
  if(normalized.active&&!normalized.processing&&normalized.remainingSeconds>0)
    normalized._deadlineMs=Date.now()+normalized.remainingSeconds*1000;
  return normalized;
}

function currentGmTurnSeconds() {
  if(!gmTurnState?.active||gmTurnState.processing)return 0;
  if(gmTurnState._deadlineMs)
    return Math.max(0,Math.ceil((gmTurnState._deadlineMs-Date.now())/1000));
  return Math.max(0,Number(gmTurnState.remainingSeconds)||0);
}

function setGmTurnState(state) {
  const previous=gmTurnState;
  const next=normalizeGmTurnState(state);
  // Live polls and hidden input heartbeats report the same absolute expiry.
  // Preserve the local deadline so repeated input can never restart the
  // visible 30-second countdown through response-rounding.
  if(previous?.active&&next.active&&!next.processing&&previous._deadlineMs&&
     previous.expiresAt&&previous.expiresAt===next.expiresAt)
    next._deadlineMs=previous._deadlineMs;
  gmTurnState=next;
  gmTurnToken=gmTurnState.isOwner?gmTurnState.lockToken:null;
  updateGmTurnUi();
}

function updateCombatInitiativeUi() {
  const host=document.querySelector('#combatInitiativeStatus');
  if(!host)return;
  const combat=gmCombatTurnState;
  if(!combat?.active) {
    host.hidden=true;
    host.innerHTML='';
    return;
  }
  host.hidden=false;
  const order=(combat.initiative||[]).filter(i=>!i.defeated);
  const orderHtml=order.length
    ? order.map(i=>`<span class="initiative-chip${i.isCurrent?' current':''}">${escapeHtml(i.displayName)} <b>${Number(i.initiativeTotal)||0}</b></span>`).join('<span class="initiative-arrow">→</span>')
    : '<span class="muted">Initiative is being established...</span>';
  host.innerHTML=`<div class="combat-turn-heading"><b>Round ${Math.max(1,Number(combat.roundNumber)||1)}</b><span>Current: <strong>${escapeHtml(combat.currentTurnName||'Waiting for GM')}</strong></span></div><div class="initiative-order">${orderHtml}</div>`;
}

function updateGmTurnUi() {
  const status=document.querySelector('#gmTurnStatus');
  const input=document.querySelector('#gmInput');
  const send=document.querySelector('#sendGm');
  const endTurn=document.querySelector('#endCombatTurn');
  const resumeEnemy=document.querySelector('#resumeEnemyTurns');
  if(!status||!input||!send)return;

  updateCombatInitiativeUi();
  const message=input.value.trim();
  const state=gmTurnState;
  const combat=gmCombatTurnState;
  const combatActive=!!combat?.active;
  // RULES BUILD 6.7.1 - INTERRUPTED COMBAT SETUP RECOVERY
  // Active combat with no current turn and no initiative is SETUP, not another player's turn.
  const liveInitiative=(combat?.initiative||[]).filter(i=>!i.defeated);
  const combatSetupPending=combatActive &&
    !String(combat?.currentTurnType||'').trim() &&
    !combat?.currentTurnCharacterId &&
    !combat?.currentTurnMonsterId &&
    liveInitiative.length===0;
  const combatCanAct=!combatActive||combatSetupPending||!!combat?.canAct;
  if(endTurn) {
    endTurn.hidden=!combatActive||combatSetupPending;
    endTurn.disabled=!combatActive||combatSetupPending||!combatCanAct||gmTurnSubmitting||!!state?.processing;
  }
  if(resumeEnemy) {
    const enemyTurn=combatActive&&String(combat?.currentTurnType||'').toLowerCase()==='monster';
    resumeEnemy.hidden=!enemyTurn||!!state?.active||!!state?.processing;
    resumeEnemy.disabled=!enemyTurn||gmTurnSubmitting||!!state?.active||!!state?.processing;
  }
  status.className='gm-turn-status';

  if(!state) {
    status.classList.add('checking');
    status.innerHTML='<span>Checking shared GM turn...</span>';
    input.disabled=true;
    send.disabled=true;
    if(endTurn)endTurn.disabled=true;
    if(resumeEnemy)resumeEnemy.disabled=true;
    return;
  }

  if(state.active&&state.processing) {
    const who=state.ownerName||'the active combat turn';
    status.classList.add('processing');
    status.innerHTML=combatActive
      ? `<span>RabuShin is resolving <b>${escapeHtml(combat.currentTurnName||'combat')}</b>...</span>`
      : `<span>RabuShin is responding to <b>${escapeHtml(who)}</b>...</span>`;
    input.disabled=true;
    send.disabled=true;
    if(endTurn)endTurn.disabled=true;
    if(resumeEnemy)resumeEnemy.disabled=true;
    return;
  }

  if(combatActive&&!combatCanAct) {
    status.classList.add('locked');
    const who=combat.currentTurnName||'another combatant';
    const enemy=String(combat.currentTurnType||'').toLowerCase()==='monster';
    status.innerHTML=enemy
      ? `<span>Enemy initiative: <b>${escapeHtml(who)}</b>. RabuShin resolves this turn automatically.${state.active?'':' If an earlier GM request was interrupted, use Resume GM Turn.'}</span>`
      : `<span><b>${escapeHtml(who)}</b>'s initiative turn — waiting for that player.</span>`;
    input.disabled=true;
    send.disabled=true;
    if(endTurn)endTurn.disabled=true;
    return;
  }

  const seconds=currentGmTurnSeconds();
  if(state.active&&seconds<=0) {
    gmTurnState={active:false,processing:false,isOwner:false,ownerName:'',lockToken:null,remainingSeconds:0,_deadlineMs:null};
    gmTurnToken=null;
    status.classList.add('expired');
    status.innerHTML=combatActive
      ? '<span>Your combat turn — typing lease expired. Continue typing to claim another 30 seconds.</span>'
      : '<span>Turn expired — continue typing to claim a new 30-second turn.</span>';
    input.disabled=false;
    send.disabled=!message||gmTurnSubmitting;
    return;
  }

  if(state.active&&state.isOwner) {
    status.classList.add('own');
    status.innerHTML=`<span>${combatActive?'Your combat turn':'Your turn'} — send before time expires</span><b class="gm-turn-countdown">00:${String(seconds).padStart(2,'0')}</b>`;
    input.disabled=gmTurnSubmitting;
    send.disabled=!message||gmTurnSubmitting;
    return;
  }

  if(state.active) {
    const who=state.ownerName||'Another player';
    status.classList.add('locked');
    status.innerHTML=`<span><b>${escapeHtml(who)}</b> is typing</span><b class="gm-turn-countdown">00:${String(seconds).padStart(2,'0')}</b>`;
    input.disabled=true;
    send.disabled=true;
    return;
  }

  if(combatSetupPending) {
    status.classList.add('checking');
    status.innerHTML='<span>Combat setup is incomplete. Continue with the AI Game Master to add/stage enemies and establish initiative.</span>';
    input.disabled=gmTurnSubmitting;
    send.disabled=!message||gmTurnSubmitting;
    return;
  }

  status.classList.add(combatActive?'own':'idle');
  status.innerHTML=combatActive
    ? '<span>Your initiative turn — describe your actions, then click <b>End Turn</b> when finished.</span>'
    : '<span>AI Game Master input available — begin typing to claim 30 seconds.</span>';
  input.disabled=false;
  send.disabled=!message||gmTurnSubmitting;
}

async function acquireGmTurnForDraft() {
  const input=document.querySelector('#gmInput');
  if(!input||!currentCampaignId||!input.value.trim())return false;
  if(gmTurnSubmitting)return false;
  if(gmTurnState?.active&&gmTurnState.isOwner&&gmTurnToken&&currentGmTurnSeconds()>0)return true;
  if(gmTurnAcquirePending)return false;

  gmTurnAcquirePending=true;
  try {
    const result=await api(`/game-api/campaigns/${currentCampaignId}/gm/turn/acquire`,{method:'POST'});
    setGmTurnState(result.turnState);
    if(!result.turnState?.isOwner) {
      const who=result.turnState?.ownerName||'Another player';
      document.querySelector('#gmError').textContent=`${who} currently has the AI Game Master turn.`;
      return false;
    }
    document.querySelector('#gmError').textContent='';
    // Acquiring is itself an input event. Touch once more after the response so
    // input typed while the acquire request was in flight is also recognized.
    void touchGmTurnInput();
    return true;
  } catch(error) {
    document.querySelector('#gmError').textContent=error.message;
    return false;
  } finally {
    gmTurnAcquirePending=false;
    updateGmTurnUi();
  }
}

// RULES BUILD 6.8 - HIDDEN FIVE-SECOND GM INPUT-IDLE LEASE
// Input heartbeats are serialized and coalesced so rapid typing cannot create
// overlapping requests. Supabase tracks the hidden idle deadline; this does not
// alter the visible, absolute 30-second countdown.
async function touchGmTurnInput() {
  if(gmTurnInputHeartbeatPending) {
    gmTurnInputHeartbeatQueued=true;
    return;
  }
  if(gmTurnSubmitting||!currentCampaignId||!gmTurnState?.active||
     gmTurnState.processing||!gmTurnState.isOwner||!gmTurnToken)return;

  const campaignId=currentCampaignId;
  const token=gmTurnToken;
  gmTurnInputHeartbeatPending=true;
  try {
    const result=await api(`/game-api/campaigns/${campaignId}/gm/turn/input`,{
      method:'POST',
      headers:{'X-RabuShin-GM-Turn-Token':token}
    });
    if(currentCampaignId===campaignId&&gmTurnToken===token&&!gmTurnSubmitting)
      setGmTurnState(result.turnState);
  } catch(error) {
    if(currentCampaignId===campaignId&&gmTurnToken===token&&error.data?.turnExpired) {
      gmTurnToken=null;
      gmTurnState={active:false,processing:false,isOwner:false,ownerName:'',lockToken:null,remainingSeconds:0,_deadlineMs:null};
      updateGmTurnUi();
      const input=document.querySelector('#gmInput');
      if(input?.value.trim())void acquireGmTurnForDraft();
    }
  } finally {
    gmTurnInputHeartbeatPending=false;
    if(gmTurnInputHeartbeatQueued) {
      gmTurnInputHeartbeatQueued=false;
      void touchGmTurnInput();
    }
  }
}

async function refreshGmLive(force=false) {
  if(activeGameTab!=='gm'||!currentCampaignId||conversationLiveSyncBusy)return;
  conversationLiveSyncBusy=true;
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/gm`);
    currentGameData.gmMessages=data.messages||[];
    gmCombatTurnState=data.combatTurn||null;
    updateLiveTimeline('gmTimeline',currentGameData.gmMessages,'Your adventure begins when you speak to the Game Master.','gm',force);
    setGmTurnState(data.turnState);
    updateCombatInitiativeUi();
  } catch(error) {
    const errorBox=document.querySelector('#gmError');
    if(errorBox&&!gmTurnSubmitting)errorBox.textContent=`Live sync: ${error.message}`;
  } finally {
    conversationLiveSyncBusy=false;
  }
}

function scheduleGmLiveSync() {
  if(activeGameTab!=='gm')return;
  if(conversationLiveSyncTimer)clearTimeout(conversationLiveSyncTimer);
  conversationLiveSyncTimer=setTimeout(async()=>{
    await refreshGmLive(false);
    if(activeGameTab==='gm')scheduleGmLiveSync();
  },1000);
}

function startGmLiveSync() {
  stopConversationLiveSync();
  bindGmVoiceEventsOnce();
  initializeGmVoiceBaseline(currentGameData?.gmMessages||[]);
  gmMessageSignature=messageListSignature(currentGameData?.gmMessages||[]);
  gmTurnCountdownTimer=setInterval(updateGmTurnUi,250);
  void refreshGmLive(true);
  scheduleGmLiveSync();
}

async function refreshChatLive(force=false) {
  if(activeGameTab!=='chat'||!currentCampaignId||conversationLiveSyncBusy)return;
  conversationLiveSyncBusy=true;
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/chat`);
    currentGameData.chatMessages=data.messages||[];
    updateLiveTimeline('chatTimeline',currentGameData.chatMessages,'No campaign chat messages yet.','chat',force);
  } catch(error) {
    const errorBox=document.querySelector('#chatError');
    if(errorBox)errorBox.textContent=`Live sync: ${error.message}`;
  } finally {
    conversationLiveSyncBusy=false;
  }
}

function scheduleChatLiveSync() {
  if(activeGameTab!=='chat')return;
  if(conversationLiveSyncTimer)clearTimeout(conversationLiveSyncTimer);
  conversationLiveSyncTimer=setTimeout(async()=>{
    await refreshChatLive(false);
    if(activeGameTab==='chat')scheduleChatLiveSync();
  },1000);
}

function startChatLiveSync() {
  stopConversationLiveSync();
  chatMessageSignature=messageListSignature(currentGameData?.chatMessages||[]);
  void refreshChatLive(true);
  scheduleChatLiveSync();
}

function worldMapPercent(value,total) {
  return `${((Number(value)||0)/(Number(total)||1)*100).toFixed(4)}%`;
}

async function openWorldMap() {
  document.querySelector('#worldMapOverlay')?.remove();
  const overlay=document.createElement('div');
  overlay.id='worldMapOverlay';
  overlay.className='modal-overlay world-map-overlay';
  overlay.innerHTML=`<div class="world-map-modal">
    <div class="world-map-header"><div><h2>Vael Turog World Map</h2><p class="muted">Loading discovered destinations...</p></div><button id="closeWorldMap" class="modal-close" aria-label="Close">×</button></div>
    <div class="loading">Loading World Map...</div>
  </div>`;
  document.body.appendChild(overlay);
  document.querySelector('#closeWorldMap').onclick=()=>overlay.remove();
  overlay.addEventListener('click',event=>{if(event.target===overlay)overlay.remove();});

  try {
    currentWorldMapData=await api(`/game-api/campaigns/${currentCampaignId}/world-map`);
    renderWorldMapOverlay();
  } catch(error) {
    const modal=overlay.querySelector('.world-map-modal');
    modal.innerHTML=`<div class="world-map-header"><div><h2>Vael Turog World Map</h2><p class="muted">Unable to load map state.</p></div><button id="closeWorldMap" class="modal-close" aria-label="Close">×</button></div><div class="error">${escapeHtml(error.message)}</div>`;
    document.querySelector('#closeWorldMap').onclick=()=>overlay.remove();
  }
}

function renderWorldMapOverlay() {
  const data=currentWorldMapData;
  const overlay=document.querySelector('#worldMapOverlay');
  if(!data||!overlay)return;

  const locations=(data.locations||[]);
  const hotspots=locations.map((location,index)=>{
    const style=`left:${worldMapPercent(location.x,data.imageWidth)};top:${worldMapPercent(location.y,data.imageHeight)};width:${worldMapPercent(location.width,data.imageWidth)};height:${worldMapPercent(location.height,data.imageHeight)};`;
    if(!location.discovered) {
      return `<div class="world-map-hotspot hidden-location" style="${style}" title="Undiscovered location"><span>?</span></div>`;
    }
    return `<button class="world-map-hotspot discovered-location${location.current?' current-location':''}" style="${style}" data-world-map-index="${index}" title="${location.current?'Current location':`Travel to ${escapeHtml(location.name)}`}">
      <span>${escapeHtml(location.name)}</span>${location.current?'<small>CURRENT</small>':''}
    </button>`;
  }).join('');

  overlay.querySelector('.world-map-modal').innerHTML=`
    <div class="world-map-header">
      <div><h2>Vael Turog World Map</h2><p>Current location: <b>${escapeHtml(data.currentLocation||'Unknown')}</b></p></div>
      <div class="row gap"><button id="refreshWorldMap" class="button small">Refresh</button><button id="closeWorldMap" class="modal-close" aria-label="Close">×</button></div>
    </div>
    <div class="world-map-stage">
      <img src="${escapeHtml(data.imageUrl)}" width="${data.imageWidth}" height="${data.imageHeight}" alt="Map of Vael Turog">
      ${hotspots}
    </div>
    <div class="world-map-legend">
      <span><i class="legend-current"></i> Current Location</span>
      <span><i class="legend-known"></i> Discovered / Fast Travel</span>
      <span><i class="legend-hidden"></i> Undiscovered</span>
    </div>
    <p class="muted world-map-hint">Undiscovered settlement nameplates remain concealed. Locations become available through campaign progress, quests, NPC information, clues, or direct discovery.</p>`;

  document.querySelector('#closeWorldMap').onclick=()=>overlay.remove();
  document.querySelector('#refreshWorldMap').onclick=async()=>{
    try {
      currentWorldMapData=await api(`/game-api/campaigns/${currentCampaignId}/world-map`);
      renderWorldMapOverlay();
    } catch(error) { showNotice(error.message,true); }
  };

  overlay.querySelectorAll('[data-world-map-index]').forEach(button=>{
    button.onclick=()=>requestWorldMapTravel(Number(button.dataset.worldMapIndex));
  });
}

function requestWorldMapTravel(index) {
  const location=currentWorldMapData?.locations?.[index];
  if(!location||!location.discovered)return;
  if(location.current) {
    showNotice(`You are already in ${location.name}.`);
    return;
  }
  if(!currentGameData?.openAiConfigured) {
    showNotice('Add your OpenAI API key in Settings before starting World Map travel.',true);
    return;
  }

  showModal(
    `Travel to ${location.name}`,
    `<p>Travel to <b>${escapeHtml(location.name)}</b>?</p><p class="muted">The AI Game Master will resolve travel time, weather, and any encounter, obstacle, or event before arrival. The shared world clock advances during the journey.</p>`,
    'Begin Travel',
    async()=>{
      document.querySelector('#modalOverlay')?.remove();
      document.querySelector('#worldMapOverlay')?.remove();
      renderGameMasterTab();
      const input=document.querySelector('#gmInput');
      const send=document.querySelector('#sendGm');
      if(!input||!send)throw new Error('AI Game Master controls could not be opened.');
      input.value=`[WORLD MAP TRAVEL REQUEST] I travel to ${location.name}.`;
      await send.onclick();
      await refreshWorldMapCampaignLocation();
    }
  );
}

async function refreshWorldMapCampaignLocation() {
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/world-map`);
    currentWorldMapData=data;
    if(currentGameData?.campaign&&data.currentLocation)currentGameData.campaign.currentLocation=data.currentLocation;
    const location=document.querySelector('#gameCurrentLocation');
    if(location&&data.currentLocation)location.textContent=data.currentLocation;
  } catch(error) {
    console.warn('World Map state refresh failed:',error);
  }
}
async function loadLocalMapState() {
  currentLocalMapData=await api(`/game-api/campaigns/${currentCampaignId}/local-maps`);
  return currentLocalMapData;
}

async function refreshLocalMapButtons() {
  const settlementButton=document.querySelector('#openSettlementMap');
  const encounterButton=document.querySelector('#openEncounterMap');
  if(!settlementButton&&!encounterButton)return;
  try {
    const data=await loadLocalMapState();
    if(settlementButton) {
      settlementButton.disabled=!data?.settlementMap?.available;
      settlementButton.title=data?.settlementMap?.available ? `View ${data.currentLocation} settlement map` : 'No settlement map is available here.';
    }
    if(encounterButton) {
      encounterButton.disabled=!data?.encounterMap?.available;
      encounterButton.title=data?.encounterMap?.available ? `View active ${data.currentLocation} encounter map` : 'No tactical Encounter Map is currently active.';
    }
  } catch(error) {
    if(settlementButton)settlementButton.disabled=true;
    if(encounterButton)encounterButton.disabled=true;
    console.warn('Local map state refresh failed:',error);
  }
}

async function openCampaignLocalMap(kind) {
  try {
    const data=await loadLocalMapState();
    const map=kind==='encounter' ? data?.encounterMap : data?.settlementMap;
    if(!map?.available) {
      showNotice(kind==='encounter' ? 'No Encounter Map is currently active.' : 'No Settlement Map is available for the current location.',true);
      await refreshLocalMapButtons();
      return;
    }
    renderCampaignLocalMap(map,kind,data.currentLocation);
  } catch(error) {
    showNotice(error.message,true);
  }
}

function renderCampaignLocalMap(map,kind,currentLocation) {
  document.querySelector('#localMapOverlay')?.remove();
  const overlay=document.createElement('div');
  overlay.id='localMapOverlay';
  overlay.className='modal-overlay local-map-overlay';
  const reason=kind==='encounter'&&map.reason ? `<p class="muted">${escapeHtml(map.reason)}</p>` : '';
  const interactive=kind==='settlement'&&map.interactive&&Array.isArray(map.pois)&&map.pois.length>0;
  const viewerLocation=map.viewerPoiName ? `<p class="settlement-personal-location">Your location: <b>${escapeHtml(map.viewerPoiName)}</b></p>` : '<p class="settlement-personal-location muted">Your character has not selected a location in this settlement yet.</p>';
  const hotspots=interactive ? map.pois.flatMap(poi=>(poi.hotspots||[]).map((hotspot,index)=>`<button type="button" class="settlement-poi-hotspot ${poi.isShop?'shop':''} ${map.viewerPoiKey===poi.poiKey?'current':''}" data-poi-key="${escapeHtml(poi.poiKey)}" data-hotspot-index="${index}" style="left:${Number(hotspot.x)||0}%;top:${Number(hotspot.y)||0}%;width:${Number(hotspot.width)||1}%;height:${Number(hotspot.height)||1}%;" title="${escapeHtml(poi.name)}${poi.isShop?' — Shop':''}" aria-label="Go to ${escapeHtml(poi.name)}">${map.viewerPoiKey===poi.poiKey?'<span class="settlement-current-pin">●</span>':''}</button>`)).join('') : '';
  const instruction=interactive ? '<p class="settlement-map-instruction">Click any highlighted map location to move <b>your character only</b>. Merchant locations are marked with a shop symbol and open the Shop screen.</p>' : '';
  overlay.innerHTML=`<div class="local-map-modal">
    <div class="local-map-header">
      <div><h2>${escapeHtml(map.name)}</h2><p>Settlement: <b>${escapeHtml(currentLocation||'Unknown')}</b></p>${kind==='settlement'?viewerLocation:''}${reason}</div>
      <button id="closeLocalMap" class="modal-close" aria-label="Close">×</button>
    </div>
    ${instruction}
    <div class="local-map-toolbar">
      <button id="localMapZoomOut" class="button small">−</button>
      <span id="localMapZoomLabel">100%</span>
      <button id="localMapZoomIn" class="button small">+</button>
      <button id="localMapFit" class="button small">Fit to Screen</button>
    </div>
    <div id="localMapViewport" class="local-map-viewport">
      <div id="localMapStage" class="local-map-stage">
        <img id="localMapImage" class="local-map-image" src="${escapeHtml(map.imageUrl)}" width="${Number(map.imageWidth)||''}" height="${Number(map.imageHeight)||''}" alt="${escapeHtml(map.name)}">
        ${hotspots}
      </div>
    </div>
  </div>`;
  document.body.appendChild(overlay);
  const stage=overlay.querySelector('#localMapStage');
  const label=overlay.querySelector('#localMapZoomLabel');
  let zoom=1;
  const applyZoom=()=>{
    stage.style.width=`${Math.round(zoom*100)}%`;
    label.textContent=`${Math.round(zoom*100)}%`;
  };
  overlay.querySelector('#localMapZoomOut').onclick=()=>{zoom=Math.max(.5,Math.round((zoom-.25)*100)/100);applyZoom();};
  overlay.querySelector('#localMapZoomIn').onclick=()=>{zoom=Math.min(3,Math.round((zoom+.25)*100)/100);applyZoom();};
  overlay.querySelector('#localMapFit').onclick=()=>{zoom=1;applyZoom();overlay.querySelector('#localMapViewport').scrollTo(0,0);};
  overlay.querySelector('#closeLocalMap').onclick=()=>overlay.remove();
  overlay.addEventListener('click',event=>{if(event.target===overlay)overlay.remove();});
  overlay.querySelectorAll('.settlement-poi-hotspot').forEach(button=>button.onclick=async event=>{
    event.stopPropagation();
    await moveToSettlementPoi(button.dataset.poiKey,map,currentLocation,button);
  });
  applyZoom();
}

// RULES BUILD 6.6.1 - Multi-currency PP/GP/SP/CP wallet
function mergeInventoryValuations(items,valuations) {
  const values=new Map((valuations||[]).map(v=>[String(v.inventoryItemId||''),v]));
  return (items||[]).map(item=>Object.assign({},item,values.get(String(item.inventoryItemId||''))||{}));
}

function applyInventoryPayload(payload) {
  if(!currentGameData)return;
  currentGameData.inventory=mergeInventoryValuations(payload?.inventory||[],payload?.inventoryValuations||[]);
  if(payload?.gold!==undefined&&currentGameData.character)currentGameData.character.gold=payload.gold;
  if(payload?.encumbrance)currentGameData.encumbrance=payload.encumbrance;
  updateEncumbranceUi();
}

function currencyParts(goldValue) {
  const totalCp=Math.max(0,Math.round((Number(goldValue)||0)*100));
  const pp=Math.floor(totalCp/1000);
  let remaining=totalCp-(pp*1000);
  const gp=Math.floor(remaining/100);
  remaining-=gp*100;
  const sp=Math.floor(remaining/10);
  const cp=remaining-(sp*10);
  return {pp,gp,sp,cp,totalCp};
}

function currencyPurseText(goldValue) {
  const c=currencyParts(goldValue);
  return `${c.pp} PP • ${c.gp} GP • ${c.sp} SP • ${c.cp} CP`;
}

function formatCoinPrice(goldValue) {
  const totalCp=Math.max(0,Math.round((Number(goldValue)||0)*100));
  const gp=Math.floor(totalCp/100);
  const sp=Math.floor((totalCp-(gp*100))/10);
  const cp=totalCp-(gp*100)-(sp*10);
  const parts=[];
  if(gp)parts.push(`${gp} GP`);
  if(sp)parts.push(`${sp} SP`);
  if(cp)parts.push(`${cp} CP`);
  return parts.length?parts.join(' '):'0 CP';
}

function updateLiveGoldDisplay() {
  if(!currentGameData?.character)return;
  const purse=currencyPurseText(currentGameData.character.gold);
  document.querySelectorAll('[data-live-self-currency],[data-shop-gold]').forEach(node=>node.textContent=purse);
}

async function moveToSettlementPoi(poiKey,map,currentLocation,button) {
  if(!poiKey||button?.disabled)return;
  const poi=(map.pois||[]).find(entry=>entry.poiKey===poiKey);
  if(!poi)return;
  if(button)button.disabled=true;
  try {
    const result=await api(`/game-api/campaigns/${currentCampaignId}/settlement/move`,{
      method:'POST',
      body:JSON.stringify({poiKey})
    });
    if(currentLocalMapData?.settlementMap) {
      currentLocalMapData.settlementMap.viewerPoiKey=result.poiKey;
      currentLocalMapData.settlementMap.viewerPoiName=result.poiName;
    }
    document.querySelector('#localMapOverlay')?.remove();
    if(result.isShop) {
      await openSettlementShop();
      return;
    }
    showNotice(`${currentGameData?.character?.characterName||'Your character'} moved to ${result.poiName}.`);
    await continueSettlementNarrative(result.poiName,currentLocation);
  } catch(error) {
    showNotice(error.message,true);
    if(button)button.disabled=false;
  }
}

async function continueSettlementNarrative(poiName,settlementName) {
  const gmButton=document.querySelector('.game-tab[data-tab="gm"]');
  switchGameTab('gm',gmButton);
  const message=`[SETTLEMENT MOVE] I travel to ${poiName} in ${settlementName||currentGameData?.campaign?.currentLocation||'the settlement'} on my own. Only my character moves there. Continue the narrative for me at this location.`;
  gmTurnDraft=message;
  const input=document.querySelector('#gmInput');
  if(!input)return;
  input.value=message;
  input.dispatchEvent(new Event('input',{bubbles:true}));
  try {
    const acquired=await acquireGmTurnForDraft();
    if(acquired) {
      updateGmTurnUi();
      const send=document.querySelector('#sendGm');
      if(send&&!send.disabled)send.click();
      else showNotice(`You arrived at ${poiName}. Your travel action is ready in the AI Game Master box.`);
    } else {
      showNotice(`You arrived at ${poiName}. Your travel action is ready in the AI Game Master box.`);
    }
  } catch(error) {
    console.warn('Automatic settlement narrative handoff failed:',error);
    showNotice(`You arrived at ${poiName}. Continue from the AI Game Master tab.`);
  }
}

async function openSettlementShop() {
  try {
    const shop=await api(`/game-api/campaigns/${currentCampaignId}/settlement/shop`);
    renderSettlementShop(shop);
  } catch(error) {
    showNotice(error.message,true);
  }
}

function formatShopGp(value) {
  return formatCoinPrice(value);
}

function renderSettlementShop(shop,initialMode='buy') {
  document.querySelector('#settlementShopOverlay')?.remove();
  document.querySelector('#localMapOverlay')?.remove();
  const overlay=document.createElement('div');
  overlay.id='settlementShopOverlay';
  overlay.className='modal-overlay settlement-shop-overlay';
  // RULES BUILD 6.15 - HOSPITALITY UI
  const hospitality=['inn','tavern','inn-tavern'].includes(String(shop.shopKind||'').toLowerCase());

  const groups=new Map();
  (shop.items||[]).forEach(item=>{
    const category=item.category||'Goods';
    if(!groups.has(category))groups.set(category,[]);
    groups.get(category).push(item);
  });
  const buyCatalog=[...groups.entries()].map(([category,items])=>`<section class="shop-category"><h3>${escapeHtml(category)}</h3><div class="shop-item-grid">${items.map(item=>`<article class="shop-item-card" data-shop-item="${escapeHtml(item.itemKey)}"><div class="shop-item-copy"><div class="item-value-line"><span class="item-rarity rarity-${String(item.rarity||'common').toLowerCase().replaceAll(' ','-')}">${escapeHtml(item.rarity||'Common')}</span><span>${escapeHtml(item.valueClass||category)}</span></div><h4>${escapeHtml(item.itemName)}</h4><p>${escapeHtml(item.description||'')}</p></div><div class="shop-item-buy"><b>${formatShopGp(item.priceGp)}</b><label>Qty <input class="input shop-quantity" type="number" min="1" max="20" value="1" aria-label="Quantity of ${escapeHtml(item.itemName)}"></label><button class="button primary shop-buy-button" data-item-key="${escapeHtml(item.itemKey)}">Buy</button></div></article>`).join('')}</div></section>`).join('');

  const sellItems=shop.sellItems||[];
  const sellCatalog=sellItems.length?sellItems.map(item=>{
    const status=[item.equipped?'Equipped':'',item.attuned?'Attuned':''].filter(Boolean).join(' • ');
    const sellControls=item.canSell
      ? `<div class="shop-item-buy shop-item-sell"><b>${formatShopGp(item.unitPriceGp)} each</b><label>Qty <input class="input shop-sell-quantity" type="number" min="1" max="${Math.max(1,Number(item.quantity)||1)}" value="1" aria-label="Quantity of ${escapeHtml(item.itemName)} to sell"></label><button class="button primary shop-sell-button" data-inventory-item-id="${escapeHtml(item.inventoryItemId)}">Sell</button></div>`
      : `<div class="shop-sell-unavailable">${escapeHtml(item.reason||'This merchant will not buy this item.')}</div>`;
    return `<article class="shop-item-card shop-sell-card ${item.canSell?'':'disabled'}"><div class="shop-item-copy"><div class="item-value-line"><span class="item-rarity rarity-${String(item.rarity||'common').toLowerCase().replaceAll(' ','-')}">${escapeHtml(item.rarity||'Common')}</span><span>Base ${item.baseValueGp>0?formatShopGp(item.baseValueGp):'Priceless'}</span></div><h4>${escapeHtml(item.itemName)}</h4><p>${escapeHtml(item.category||'Inventory Item')} • Carried: ${Number(item.quantity)||0}${status?` • ${escapeHtml(status)}`:''}</p>${item.priceBand?`<small class="muted">${escapeHtml(item.priceBand)}</small>`:''}</div>${sellControls}</article>`;
  }).join(''):'<div class="empty">You have no inventory items to sell.</div>';

  overlay.innerHTML=`<div class="settlement-shop-modal">
    <div class="settlement-shop-header"><div><p class="eyebrow">SHOP</p><h2>${escapeHtml(shop.shopName||'Settlement Shop')}</h2><p>${escapeHtml(shop.settlementName||'')} • Your Purse: <b data-shop-gold>${currencyPurseText(shop.gold??currentGameData?.character?.gold??0)}</b></p></div><button id="closeSettlementShop" class="modal-close" aria-label="Close">×</button></div>
    <div class="settlement-shop-actions"><button id="shopBackToMap" class="button">← Settlement Map</button><button id="shopOpenInventory" class="button">Inventory</button><span class="muted">Buying and selling update this character's authoritative inventory and GP.</span></div>
    <div class="shop-mode-tabs" role="tablist"><button class="button shop-mode-button" data-shop-mode="buy" role="tab">Buy</button><button class="button shop-mode-button" data-shop-mode="sell" role="tab">Sell</button><span class="muted shop-resale-note">Merchants normally pay 50% of the item's authoritative base value. Rarity and item category determine that value; Artifact items are priceless and protected.</span></div>
    <div id="shopError" class="error"></div>
    <div id="shopBuyPane" class="settlement-shop-catalog shop-mode-pane">${buyCatalog||'<div class="empty">This merchant has nothing for sale right now.</div>'}</div>
    <div id="shopSellPane" class="settlement-shop-catalog shop-mode-pane" hidden>${sellCatalog}</div>
  </div>`;
  document.body.appendChild(overlay);
  if(hospitality) {
    const eyebrow=overlay.querySelector('.settlement-shop-header .eyebrow');
    if(eyebrow) eyebrow.textContent=String(shop.shopKind||'').toLowerCase()==='tavern'?'TAVERN':'INN';
    overlay.querySelector('.shop-mode-tabs')?.remove();
    const note=overlay.querySelector('.settlement-shop-actions .muted');
    if(note) note.textContent=String(shop.shopKind||'').toLowerCase()==='tavern'
      ? 'Drinks are served immediately and do not enter inventory.'
      : 'Meals are served immediately; room quantity is the number of lodging days.';
  }
  if(currentGameData?.character&&shop.gold!==undefined) {
    currentGameData.character.gold=shop.gold;
    updateLiveGoldDisplay();
  }

  const setMode=mode=>{
    const normalized=mode==='sell'?'sell':'buy';
    overlay.querySelector('#shopBuyPane').hidden=normalized!=='buy';
    overlay.querySelector('#shopSellPane').hidden=normalized!=='sell';
    overlay.querySelectorAll('.shop-mode-button').forEach(button=>{
      button.classList.toggle('primary',button.dataset.shopMode===normalized);
      button.setAttribute('aria-selected',button.dataset.shopMode===normalized?'true':'false');
    });
  };
  overlay.querySelectorAll('.shop-mode-button').forEach(button=>button.onclick=()=>setMode(button.dataset.shopMode));
  setMode(initialMode);

  overlay.querySelector('#closeSettlementShop').onclick=()=>overlay.remove();
  overlay.querySelector('#shopBackToMap').onclick=async()=>{overlay.remove();await openCampaignLocalMap('settlement');};
  overlay.querySelector('#shopOpenInventory').onclick=()=>{
    overlay.remove();
    const tab=document.querySelector('.game-tab[data-tab="inventory"]');
    switchGameTab('inventory',tab);
  };
  overlay.addEventListener('click',event=>{if(event.target===overlay)overlay.remove();});
  overlay.querySelectorAll('.shop-buy-button').forEach(button=>button.onclick=()=>buySettlementShopItem(button,shop));
  overlay.querySelectorAll('.shop-sell-button').forEach(button=>button.onclick=()=>sellSettlementShopItem(button,shop));
}

async function buySettlementShopItem(button,shop) {
  if(!button||button.disabled)return;
  const card=button.closest('.shop-item-card');
  const quantity=Math.max(1,Math.min(20,Number(card?.querySelector('.shop-quantity')?.value)||1));
  const errorBox=document.querySelector('#shopError');
  if(errorBox)errorBox.textContent='';
  button.disabled=true;
  try {
    const result=await api(`/game-api/campaigns/${currentCampaignId}/settlement/shop/buy`,{
      method:'POST',
      body:JSON.stringify({itemKey:button.dataset.itemKey,quantity})
    });
    if(currentGameData?.character&&result.remainingGold!==undefined) {
      currentGameData.character.gold=result.remainingGold;
      updateLiveGoldDisplay();
    }
    try {
      const inv=await api(`/game-api/campaigns/${currentCampaignId}/inventory`);
      applyInventoryPayload(inv);
      updateLiveGoldDisplay();
    } catch(refreshError) {
      console.warn('Inventory refresh after shop purchase failed:',refreshError);
    }
    try {
      const freshShop=await api(`/game-api/campaigns/${currentCampaignId}/settlement/shop`);
      renderSettlementShop(freshShop,'buy');
    } catch(shopRefreshError) {
      console.warn('Shop refresh after purchase failed:',shopRefreshError);
    }
    showNotice(`Purchased ${result.quantityPurchased} × ${result.itemName} for ${formatShopGp(result.totalPriceGp)}.`);
  } catch(error) {
    if(errorBox)errorBox.textContent=error.message;
  } finally {
    button.disabled=false;
  }
}

async function sellSettlementShopItem(button,shop) {
  if(!button||button.disabled)return;
  const card=button.closest('.shop-sell-card');
  const maxQuantity=Math.max(1,Number(card?.querySelector('.shop-sell-quantity')?.max)||1);
  const quantity=Math.max(1,Math.min(maxQuantity,Number(card?.querySelector('.shop-sell-quantity')?.value)||1));
  const errorBox=document.querySelector('#shopError');
  if(errorBox)errorBox.textContent='';
  button.disabled=true;
  try {
    const result=await api(`/game-api/campaigns/${currentCampaignId}/settlement/shop/sell`,{
      method:'POST',
      body:JSON.stringify({inventoryItemId:button.dataset.inventoryItemId,quantity})
    });
    if(currentGameData?.character&&result.remainingGold!==undefined) {
      currentGameData.character.gold=result.remainingGold;
      updateLiveGoldDisplay();
    }
    try {
      const inv=await api(`/game-api/campaigns/${currentCampaignId}/inventory`);
      applyInventoryPayload(inv);
      updateLiveGoldDisplay();
    } catch(refreshError) {
      console.warn('Inventory refresh after shop sale failed:',refreshError);
    }
    try {
      const freshShop=await api(`/game-api/campaigns/${currentCampaignId}/settlement/shop`);
      renderSettlementShop(freshShop,'sell');
    } catch(shopRefreshError) {
      console.warn('Shop refresh after sale failed:',shopRefreshError);
    }
    showNotice(`Sold ${result.quantitySold} × ${result.itemName} for ${formatShopGp(result.totalPriceGp)}.`);
  } catch(error) {
    if(errorBox)errorBox.textContent=error.message;
  } finally {
    button.disabled=false;
  }
}

async function loadCombatState() {
  currentCombatData=await api(`/game-api/campaigns/${currentCampaignId}/combat`);
  return currentCombatData;
}

function monsterImageHtml(monster,cssClass='combat-monster-image') {
  if(!monster?.imageUrl)return `<div class="${cssClass} monster-image-fallback">${escapeHtml((monster?.monsterName||'?').slice(0,1).toUpperCase())}</div>`;
  return `<div class="monster-image-shell"><img class="${cssClass}" src="${escapeHtml(monster.imageUrl)}" alt="${escapeHtml(monster.monsterName||'Monster')}"><div class="${cssClass} monster-image-fallback" hidden>${escapeHtml((monster.monsterName||'?').slice(0,1).toUpperCase())}</div></div>`;
}

async function renderCombatTab() {
  const view=document.querySelector('#gameView');
  view.innerHTML='<div class="panel loading"><h3>Combat</h3><p>Loading authoritative combat state...</p></div>';
  try {
    const data=await loadCombatState();
    if(!data.active) {
        view.innerHTML =`<div class="view-heading"><h3>\u2694 Combat</h3><button id="refreshCombat" class="button small">Refresh</button></div><section class="panel combat-empty"><h3>No Active Combat</h3><p>When the AI Game Master begins a tactical encounter, enemy portraits and combat statistics will appear here automatically.</p></section>`;
      document.querySelector('#refreshCombat').onclick=renderCombatTab;
      return;
    }
    const party=currentGameData.party||[];
    const monsters=data.monsters||[];
      view.innerHTML =`<div class="view-heading"><div><h3>\u2694 ${escapeHtml(data.title||'Combat')}</h3><small>Round ${Number(data.roundNumber)||1}</small></div><div class="row gap"><button id="combatEncounterMap" class="button small">Encounter Map</button><button id="refreshCombat" class="button small">Refresh</button></div></div>
      <section class="combat-party-strip"><h4>Party</h4><div class="combat-party-list">${party.map(p=>`<div class="combat-party-vital"><b>${escapeHtml(p.characterName)}</b><span>HP ${p.currentHp}/${p.maxHp}</span><span>AC ${p.armorClass}</span></div>`).join('')}</div></section>
      <section class="panel"><h3>Enemies</h3><div class="combat-monster-grid">${monsters.length?monsters.map(m=>`<button class="combat-monster-card ${m.defeated?'defeated':''}" data-monster-id="${escapeHtml(m.combatMonsterId)}">
        ${monsterImageHtml(m)}
        <div class="combat-monster-card-body"><h4>${escapeHtml(m.displayName)}</h4>${m.displayName!==m.monsterName?`<small>${escapeHtml(m.monsterName)}</small>`:''}<div class="combat-monster-vitals"><span>HP <b>${m.currentHp}/${m.maxHp}</b></span><span>AC <b>${m.armorClass}</b></span></div><p>${escapeHtml(m.defeated?'Defeated':m.conditions||'No conditions')}</p><span class="view-stat-block">View Image & Stat Block’</span></div>
      </button>`).join(''):'<div class="empty small">Combat is active, but no enemies have been added yet.</div>'}</div></section>`;
    document.querySelector('#refreshCombat').onclick=renderCombatTab;
    const tacticalHost=document.createElement('section');
    tacticalHost.id='tacticalCombatHost';
    tacticalHost.className='panel tactical-combat-panel';
    const partyStrip=view.querySelector('.combat-party-strip');
    if(partyStrip)partyStrip.before(tacticalHost); else view.appendChild(tacticalHost);
    void renderTacticalCombatBoard(tacticalHost,data,party);
    const encounter=document.querySelector('#combatEncounterMap'); if(encounter)encounter.onclick=()=>openCampaignLocalMap('encounter');
    document.querySelectorAll('.combat-monster-image').forEach(img=>{if(img.tagName!=='IMG')return;img.onerror=()=>{img.hidden=true;const fb=img.parentElement?.querySelector('.monster-image-fallback');if(fb)fb.hidden=false;};});
    document.querySelectorAll('.combat-monster-card').forEach(card=>card.onclick=()=>{const monster=monsters.find(m=>String(m.combatMonsterId)===card.dataset.monsterId);if(monster)showMonsterStatViewer(monster);});
  } catch(error) {
      view.innerHTML =`<div class="view-heading"><h3>\u2694 Combat</h3></div><div class="error">Unable to load Combat: ${escapeHtml(error.message)}</div>`;
  }
}

async function loadTacticalCombatState() {
  currentTacticalCombatData=await api(`/game-api/campaigns/${currentCampaignId}/combat/tactical`);
  return currentTacticalCombatData;
}

function stopTacticalCombatPolling() {
  if(tacticalCombatRefreshTimer)clearTimeout(tacticalCombatRefreshTimer);
  tacticalCombatRefreshTimer=null;
}

function tacticalStateSignature(tactical,combat) {
  const tokens=(tactical?.tokens||[]).map(t=>[t.tokenId,t.gridX,t.gridY,t.movementSpentFt,t.currentHp,t.defeated]);
  const monsters=(combat?.monsters||[]).map(m=>[m.combatMonsterId,m.currentHp,m.conditions,m.defeated]);
  return JSON.stringify([tactical?.active,tactical?.roundNumber,tactical?.currentTurnType,tactical?.currentTurnCharacterId,tactical?.currentTurnMonsterId,tactical?.viewerMovementRemaining,tokens,monsters]);
}

function tacticalTokenPositionStyle(token) {
  const x=Math.max(0,Math.min(19,Number(token.gridX)||0));
  const y=Math.max(0,Math.min(19,Number(token.gridY)||0));
  return `left:${((x+.5)/20*100).toFixed(3)}%;top:${((y+.5)/20*100).toFixed(3)}%;`;
}

function tacticalCharacterArtHtml(token) {
  const hasPortrait=!!token.hasPortrait;
  return `<span class="tactical-token-art" data-portrait-frame="${escapeHtml(token.characterId||'')}" data-has-portrait="${hasPortrait?'true':'false'}">
    <span class="portrait-placeholder">${escapeHtml(portraitInitials(token.displayName))}</span>
    <img alt="${escapeHtml(token.displayName)} portrait" hidden>
  </span>`;
}

function tacticalMonsterArtHtml(token,combatData) {
  const monster=(combatData?.monsters||[]).find(m=>String(m.combatMonsterId)===String(token.combatMonsterId));
  if(monster?.imageUrl)return `<span class="tactical-token-art"><img src="${escapeHtml(monster.imageUrl)}" alt="${escapeHtml(token.displayName)}"></span>`;
  return `<span class="tactical-token-art"><span class="portrait-placeholder">${escapeHtml((token.monsterName||token.displayName||'?').slice(0,1).toUpperCase())}</span></span>`;
}

const tacticalBarrierDebugMaps={
  greymoor:'/maps/barriers/Encounter_Greymoor_Hollow_Barriers.png',
  stonewake:'/maps/barriers/Encounter_Stonewake_Port_Barriers.png',
  emberfall:'/maps/barriers/Encounter_Emberfall_Barriers.png',
  lunareth:'/maps/barriers/Encounter_Lunareth_Barriers.png',
  high_bastion:'/maps/barriers/Encounter_High_Bastion_Barriers.png',
  marrowfen:'/maps/barriers/Encounter_Marrowfen_Barriers.png',
  silverreach:'/maps/barriers/Encounter_Silverreach_Barriers.png',
  duskmire:'/maps/barriers/Encounter_Duskmire_Crossing_Barriers.png',
  frostharbor:'/maps/barriers/Encounter_Frostharbor_Barriers.png',
  sunspire:'/maps/barriers/Encounter_Sunspire_Barriers.png',
  blackroot:'/maps/barriers/Encounter_Blackroot_Enclave_Barriers.png',
  aetherfall:'/maps/barriers/Encounter_Aetherfall_Barriers.png'
};
function tacticalBarrierDebugUrl(map) {
  return tacticalBarrierDebugMaps[String(map?.locationKey||'').toLowerCase()]||'';
}
function tacticalTurnLabel(tactical) {
  if(!tactical?.currentTurnName)return 'Current turn: waiting for the AI Game Master';
  return `Current turn: ${tactical.currentTurnName}`;
}

function renderTacticalCombatBoardView(host,tactical,mapData,combatData,party) {
  if(!host)return;
  if(!tactical?.active) {
    host.innerHTML='<h3>Tactical Encounter Map</h3><p class="muted">Tactical combat is not active.</p>';
    return;
  }

  const map=mapData?.encounterMap;
  if(!map?.available||!map?.imageUrl) {
    host.innerHTML='<h3>Tactical Encounter Map</h3><p class="muted">Combat is active, but the Encounter Map is not currently available.</p>';
    return;
  }

  const tokens=tactical.tokens||[];
  const viewerId=String(tactical.viewerCharacterId||'');
  const canMove=!!tactical.canMove;
  const currentTurnCharacterId=String(tactical.currentTurnCharacterId||'');
  const currentTurnMonsterId=String(tactical.currentTurnMonsterId||'');
  const selected=tokens.find(t=>String(t.tokenId)===String(tacticalSelectedTokenId));
  if(!selected||selected.entityType!=='character'||String(selected.characterId)!==viewerId||!canMove)tacticalSelectedTokenId=null;

  const tokenHtml=tokens.map(token=>{
    const isCharacter=token.entityType==='character';
    const isOwn=isCharacter&&String(token.characterId)===viewerId;
    const isTurn=(isCharacter&&String(token.characterId)===currentTurnCharacterId)||(!isCharacter&&String(token.combatMonsterId)===currentTurnMonsterId);
    const isSelected=String(token.tokenId)===String(tacticalSelectedTokenId);
    const classes=['tactical-token',isCharacter?'character-token':'monster-token'];
    if(isOwn)classes.push('own-token');
    if(isTurn)classes.push('current-turn-token');
    if(isSelected)classes.push('selected-token');
    if(token.defeated)classes.push('defeated-token');
    const art=isCharacter?tacticalCharacterArtHtml(token):tacticalMonsterArtHtml(token,combatData);
    const hp=`${Number(token.currentHp)||0}/${Math.max(1,Number(token.maxHp)||1)}`;
    return `<button class="${classes.join(' ')}" data-tactical-token-id="${escapeHtml(token.tokenId)}" data-entity-type="${escapeHtml(token.entityType)}" style="${tacticalTokenPositionStyle(token)}" title="${escapeHtml(token.displayName)} - HP ${hp} - AC ${Number(token.armorClass)||0}">
      ${art}<span class="tactical-token-name">${escapeHtml(token.displayName)}</span><span class="tactical-token-hp">${escapeHtml(hp)}</span>
    </button>`;
  }).join('');

  const movementText=canMove
    ? `Your movement: ${Math.max(0,Number(tactical.viewerMovementRemaining)||0)} / ${Math.max(0,Number(tactical.viewerSpeed)||0)} ft. remaining`
    : (tactical.currentTurnName ? `Waiting for ${escapeHtml(tactical.currentTurnName)}` : 'Waiting for the AI Game Master to set the active turn');

  host.innerHTML=`<div class="tactical-combat-heading">
      <div><h3>Tactical Encounter Map</h3><p class="muted">20 x 20 logical grid - 5 ft. per square - ${escapeHtml(tacticalTurnLabel(tactical))}</p></div>
      <div class="tactical-movement-status ${canMove?'your-turn':''}">${movementText}</div>
    </div>
    <div class="tactical-toolbar">
      <button id="tacticalZoomOut" class="button small">-</button>
      <span id="tacticalZoomLabel">${Math.round(tacticalZoom*100)}%</span>
      <button id="tacticalZoomIn" class="button small">+</button>
      <button id="tacticalFit" class="button small">Fit</button>
      <button id="tacticalTerrainDebug" class="button small">Terrain Debug</button>
      <span id="tacticalMoveHint" class="muted">${canMove?'Select your token, then click a destination square. Terrain and obstacles are validated by the server.':''}</span>
      <div id="tacticalTerrainLegend" class="tactical-terrain-legend" ${tacticalShowTerrainDebug?'':'hidden'}>Purple/Indigo: blocked wall/building | Green: closed door | Lime: open door | Gold/Light Yellow/Gray: partial cover | Gray/Turquoise: difficult terrain | Lavender: bridge/stairs | Orange: cliff/ledge</div>
    </div>
    <div id="tacticalViewport" class="tactical-viewport">
      <div id="tacticalStage" class="tactical-stage" style="width:${Math.round(tacticalZoom*100)}%">
        <img id="tacticalMapImage" class="tactical-map-image" src="${escapeHtml(map.imageUrl)}" alt="${escapeHtml(map.name||'Encounter Map')}">
        <div class="tactical-token-layer">${tokenHtml}</div>
      </div>
    </div>`;

  hydratePortraits(host);

  const stage=host.querySelector('#tacticalStage');
  const image=host.querySelector('#tacticalMapImage');
  const viewport=host.querySelector('#tacticalViewport');
  const zoomLabel=host.querySelector('#tacticalZoomLabel');
  const moveHint=host.querySelector('#tacticalMoveHint');
  const terrainDebug=host.querySelector('#tacticalTerrainDebug');
  const terrainLegend=host.querySelector('#tacticalTerrainLegend');

  const applyZoom=()=>{
    tacticalZoom=Math.max(.5,Math.min(3,tacticalZoom));
    if(stage)stage.style.width=`${Math.round(tacticalZoom*100)}%`;
    if(zoomLabel)zoomLabel.textContent=`${Math.round(tacticalZoom*100)}%`;
  };

  host.querySelector('#tacticalZoomOut').onclick=()=>{tacticalZoom=Math.round(Math.max(.5,tacticalZoom-.25)*100)/100;applyZoom();};
  host.querySelector('#tacticalZoomIn').onclick=()=>{tacticalZoom=Math.round(Math.min(3,tacticalZoom+.25)*100)/100;applyZoom();};
  host.querySelector('#tacticalFit').onclick=()=>{tacticalZoom=1;applyZoom();viewport?.scrollTo(0,0);};
  if(terrainDebug&&image)terrainDebug.onclick=()=>{
    const debugUrl=tacticalBarrierDebugUrl(map);
    if(!debugUrl){showNotice('No barrier debug map is available for this encounter.',true);return;}
    tacticalShowTerrainDebug=!tacticalShowTerrainDebug;
    image.src=tacticalShowTerrainDebug?debugUrl:map.imageUrl;
    if(terrainLegend)terrainLegend.hidden=!tacticalShowTerrainDebug;
    terrainDebug.textContent=tacticalShowTerrainDebug?'Clean Map':'Terrain Debug';
  };

  host.querySelectorAll('[data-tactical-token-id]').forEach(button=>{
    button.onclick=event=>{
      event.stopPropagation();
      const token=tokens.find(t=>String(t.tokenId)===String(button.dataset.tacticalTokenId));
      if(!token)return;
      if(token.entityType==='character') {
        const isOwn=String(token.characterId)===viewerId;
        if(isOwn&&canMove&&!token.defeated) {
          tacticalSelectedTokenId=token.tokenId;
          host.querySelectorAll('.tactical-token').forEach(t=>t.classList.toggle('selected-token',t===button));
          if(moveHint)moveHint.textContent=`${token.displayName} selected. Click a destination square.`;
          return;
        }
        const member=(party||[]).find(p=>String(p.characterId)===String(token.characterId));
        if(member)showPartyMemberDetails(member);
        return;
      }
      const monster=(combatData?.monsters||[]).find(m=>String(m.combatMonsterId)===String(token.combatMonsterId));
      if(monster)showMonsterStatViewer({...monster,currentHp:token.currentHp,maxHp:token.maxHp,armorClass:token.armorClass,defeated:token.defeated});
    };
  });

  if(stage&&image) {
    stage.onclick=async event=>{
      if(!tacticalSelectedTokenId||!canMove)return;
      const token=tokens.find(t=>String(t.tokenId)===String(tacticalSelectedTokenId));
      if(!token)return;
      const rect=image.getBoundingClientRect();
      if(event.clientX<rect.left||event.clientX>rect.right||event.clientY<rect.top||event.clientY>rect.bottom)return;
      const gridX=Math.max(0,Math.min(19,Math.floor((event.clientX-rect.left)/rect.width*20)));
      const gridY=Math.max(0,Math.min(19,Math.floor((event.clientY-rect.top)/rect.height*20)));
      // Build 5.1: the server calculates the legal path and terrain-aware movement cost.

      try {
        if(moveHint)moveHint.textContent='Moving token...';
        const response=await api(`/game-api/campaigns/${currentCampaignId}/combat/tactical/move51`,{
          method:'POST',
          body:JSON.stringify({gridX,gridY})
        });
        const move=response.move||{};
        showNotice(`Moved ${Number(move.moveCostFt)||0} ft. - ${Number(move.movementRemainingFt)||0} ft. remaining.` + (response.usesDifficultTerrain?' Difficult terrain applied.':''));
        tacticalSelectedTokenId=null;
        await refreshTacticalCombatBoard(host,mapData,party,true);
      } catch(error) {
        showNotice(error.message,true);
        if(moveHint)moveHint.textContent='Select your token, then click a destination square.';
      }
    };

    stage.onmousemove=event=>{
      if(!tacticalSelectedTokenId||!canMove||!moveHint)return;
      const token=tokens.find(t=>String(t.tokenId)===String(tacticalSelectedTokenId));
      if(!token)return;
      const rect=image.getBoundingClientRect();
      const gridX=Math.max(0,Math.min(19,Math.floor((event.clientX-rect.left)/rect.width*20)));
      const gridY=Math.max(0,Math.min(19,Math.floor((event.clientY-rect.top)/rect.height*20)));
      moveHint.textContent=`Destination (${gridX+1},${gridY+1}) - server will calculate the legal terrain-aware path.`;
    };
  }

  applyZoom();
}

async function refreshTacticalCombatBoard(host,mapData,party,force=false) {
  if(!host?.isConnected)return;
  try {
    const [tactical,combat]=await Promise.all([loadTacticalCombatState(),loadCombatState()]);
    const signature=tacticalStateSignature(tactical,combat);
    if(force||signature!==tacticalLastSignature) {
      tacticalLastSignature=signature;
      renderTacticalCombatBoardView(host,tactical,mapData,combat,party);
    }
  } catch(error) {
    if(force)host.innerHTML=`<h3>Tactical Encounter Map</h3><div class="error">Unable to load Tactical Combat: ${escapeHtml(error.message)}</div>`;
  }
}

function scheduleTacticalCombatPolling(host,mapData,party) {
  stopTacticalCombatPolling();
  tacticalCombatRefreshTimer=setTimeout(async()=>{
    if(!host?.isConnected)return;
    await refreshTacticalCombatBoard(host,mapData,party,false);
    if(host.isConnected)scheduleTacticalCombatPolling(host,mapData,party);
  },3000);
}

async function renderTacticalCombatBoard(host,combatData,party) {
  stopTacticalCombatPolling();
  tacticalLastSignature='';
  host.innerHTML='<h3>Tactical Encounter Map</h3><p class="muted">Loading synchronized token positions...</p>';
  try {
    const [tactical,mapData]=await Promise.all([loadTacticalCombatState(),loadLocalMapState()]);
    currentTacticalMapData=mapData;
    currentCombatData=combatData||currentCombatData;
    tacticalLastSignature=tacticalStateSignature(tactical,currentCombatData);
    renderTacticalCombatBoardView(host,tactical,mapData,currentCombatData,party);
    scheduleTacticalCombatPolling(host,mapData,party);
  } catch(error) {
    host.innerHTML=`<h3>Tactical Encounter Map</h3><div class="error">Unable to load Tactical Combat: ${escapeHtml(error.message)}</div>`;
  }
}
function showMonsterStatViewer(monster) {
  document.querySelector('#monsterStatOverlay')?.remove();
  const overlay=document.createElement('div'); overlay.id='monsterStatOverlay'; overlay.className='modal-overlay monster-stat-overlay';
    overlay.innerHTML = `<div class="monster-stat-modal"><div class="monster-stat-header"><div><h2>${escapeHtml(monster.displayName)}</h2><p>${escapeHtml(monster.subtitle || monster.monsterName)}</p></div><button id="closeMonsterStats" class="modal-close" aria-label="Close">&times;</button></div>
    <div class="monster-stat-layout"><div class="monster-stat-art">${monsterImageHtml(monster,'monster-stat-image')}<div class="monster-live-vitals"><span>Current HP <b>${monster.currentHp}/${monster.maxHp}</b></span><span>AC <b>${monster.armorClass}</b></span><span>${escapeHtml(monster.defeated?'Defeated':monster.conditions||'No conditions')}</span></div></div>
    <div class="monster-stat-text"><div class="monster-stat-source">${escapeHtml(monster.source||'')}</div><pre>${escapeHtml(monster.statBlock||'No stat block available.')}</pre></div></div></div>`;
  document.body.appendChild(overlay);
  overlay.querySelectorAll('.monster-stat-image').forEach(img=>{if(img.tagName!=='IMG')return;img.onerror=()=>{img.hidden=true;const fb=img.parentElement?.querySelector('.monster-image-fallback');if(fb)fb.hidden=false;};});
  overlay.querySelector('#closeMonsterStats').onclick=()=>overlay.remove(); overlay.addEventListener('click',e=>{if(e.target===overlay)overlay.remove();});
}
function scrollGmToBottom() {
    requestAnimationFrame(() => {
        const timeline = document.querySelector('#gmTimeline');
        if (!timeline) return;

        timeline.scrollTop = timeline.scrollHeight;
    });
}

// RULES BUILD 6.8.1 - ENTER TO SEND
// Enter submits chat text. Shift+Enter retains the textarea's normal newline
// behavior. Composition and held-key repeats are ignored to avoid accidental
// submissions for IME users or a key held down too long.
function bindChatEnterToSend(input,sendButton) {
  if(!input||!sendButton)return;
  input.addEventListener('keydown',event=>{
    if(event.key!=='Enter'||event.shiftKey||event.isComposing||event.repeat)return;
    event.preventDefault();
    if(!input.value.trim()||sendButton.disabled)return;
    sendButton.click();
  });
}

function renderGameMasterTab() {
  const existingInput=document.querySelector('#gmInput');
  if(existingInput)gmTurnDraft=existingInput.value;

  const view=document.querySelector('#gameView');
  view.innerHTML=`<div class="gm-layout"><div><div class="view-heading"><h3>AI Game Master</h3><button id="refreshGm" class="button small">Refresh</button></div><div id="gmTimeline" class="timeline">${timelineHtml(currentGameData.gmMessages,'Your adventure begins when you speak to the Game Master.',true)}</div><div id="combatInitiativeStatus" class="combat-initiative-status" hidden></div><div id="gmTurnStatus" class="gm-turn-status checking"><span>Checking shared GM turn...</span></div><div class="composer gm-combat-composer"><textarea id="gmInput" class="input" placeholder="What do you do?" disabled></textarea><button id="sendGm" class="button primary" disabled>Send</button><button id="endCombatTurn" class="button end-turn" hidden disabled>End Turn</button><button id="resumeEnemyTurns" class="button resume-enemy-turn" hidden disabled>Resume GM Turn</button></div><div id="gmError" class="error"></div></div><aside class="side-card"><h4>${escapeHtml(currentGameData.character.characterName)}</h4><p>Level ${currentGameData.character.level} ${escapeHtml(currentGameData.character.speciesName)} ${escapeHtml(currentGameData.character.className)}</p><p>HP <b data-live-self-hp>${currentGameData.character.currentHp}/${currentGameData.character.maxHp}</b> • AC ${currentGameData.character.armorClass}</p>${currentGameData.openAiConfigured?'<span class="good">OpenAI Ready</span>':'<span class="warn">OpenAI key needed in Settings</span>'}<p class="muted"><b>GM-Controlled Dice:</b> All checks, attacks, saves, damage, and random rolls are generated by the RabuShin server. Player-supplied roll results are ignored.</p></aside></div>`;

  const input=document.querySelector('#gmInput');
  input.value=gmTurnDraft;

  const gmRefreshButton=document.querySelector('#refreshGm');
  if(gmRefreshButton&&!document.querySelector('#openWorldMap')) {
    const mapButton=document.createElement('button');
    mapButton.id='openWorldMap';
    mapButton.className='button small';
    mapButton.textContent='🗺 World Map';
    gmRefreshButton.parentElement?.insertBefore(mapButton,gmRefreshButton);
  }
  const openWorldMapButton=document.querySelector('#openWorldMap');
  if(openWorldMapButton)openWorldMapButton.onclick=openWorldMap;

  const localMapRefreshButton=document.querySelector('#refreshGm');
  const localMapButtonHost=localMapRefreshButton?.parentElement;
  if(localMapButtonHost&&!document.querySelector('#openSettlementMap')) {
    const settlementMapButton=document.createElement('button');
    settlementMapButton.id='openSettlementMap';
    settlementMapButton.className='button small';
    settlementMapButton.textContent='🏘 Settlement Map';
    localMapButtonHost.insertBefore(settlementMapButton,localMapRefreshButton);
  }
  if(localMapButtonHost&&!document.querySelector('#openEncounterMap')) {
    const encounterMapButton=document.createElement('button');
    encounterMapButton.id='openEncounterMap';
    encounterMapButton.className='button small';
    encounterMapButton.textContent='⚔ Encounter Map';
    encounterMapButton.disabled=true;
    localMapButtonHost.insertBefore(encounterMapButton,localMapRefreshButton);
  }
  const settlementMapButton=document.querySelector('#openSettlementMap');
  const encounterMapButton=document.querySelector('#openEncounterMap');
  if(settlementMapButton)settlementMapButton.onclick=()=>openCampaignLocalMap('settlement');
  if(encounterMapButton)encounterMapButton.onclick=()=>openCampaignLocalMap('encounter');
  void refreshLocalMapButtons();

  document.querySelector('#refreshGm').onclick=()=>refreshGmLive(true);

  input.addEventListener('input',()=>{
    gmTurnDraft=input.value;
    updateGmTurnUi();
    if(gmTurnState?.active&&gmTurnState.isOwner&&!gmTurnState.processing)
      void touchGmTurnInput();
    else if(input.value.trim()&&(!gmTurnState?.active||(!gmTurnState.isOwner&&currentGmTurnSeconds()<=0)))
      void acquireGmTurnForDraft();
  });
  input.addEventListener('focus',()=>{
    if(input.value.trim()&&!gmTurnState?.active)void acquireGmTurnForDraft();
  });

  document.querySelector('#sendGm').onclick=async()=>{
    const message=input.value.trim();
    if(!message||gmTurnSubmitting)return;

    if(!gmTurnState?.isOwner||!gmTurnToken||currentGmTurnSeconds()<=0) {
      const acquired=await acquireGmTurnForDraft();
      if(!acquired)return;
    }

    const token=gmTurnToken;
    gmTurnSubmitting=true;
    gmTurnState={...(gmTurnState||{}),active:true,processing:true,isOwner:true,ownerName:(currentDiscordUser?.global_name||currentDiscordUser?.username||'You'),lockToken:token};
    updateGmTurnUi();
    document.querySelector('#gmError').textContent='';

    try {
      await api(`/game-api/campaigns/${currentCampaignId}/gm`,{
        method:'POST',
        headers:{'X-RabuShin-GM-Turn-Token':token},
        body:JSON.stringify({message})
      });
      gmTurnDraft='';
      input.value='';

      try {
        const inv=await api(`/game-api/campaigns/${currentCampaignId}/inventory`);
        applyInventoryPayload(inv);
      } catch(refreshError) {
        console.warn('Inventory refresh after GM turn failed:',refreshError);
      }

      await refreshWorldMapCampaignLocation();
    } catch(error) {
      document.querySelector('#gmError').textContent=error.message;
      if(error.data?.needsApiKey)showNotice('Open Settings and enter your OpenAI API key.',true);
      if(error.data?.turnExpired)gmTurnToken=null;
    } finally {
      gmTurnSubmitting=false;
      await refreshRestState(true);
      await refreshGmLive(true);
      updateGmTurnUi();
    }
  };
  bindChatEnterToSend(input,document.querySelector('#sendGm'));

  const endTurnButton=document.querySelector('#endCombatTurn');
  if(endTurnButton)endTurnButton.onclick=async()=>{
    if(gmTurnSubmitting||!gmCombatTurnState?.active||!gmCombatTurnState?.canAct)return;
    gmTurnSubmitting=true;
    document.querySelector('#gmError').textContent='';
    gmTurnDraft='';
    input.value='';
    gmTurnState={...(gmTurnState||{}),active:true,processing:true,isOwner:true,ownerName:(currentDiscordUser?.global_name||currentDiscordUser?.username||'You')};
    updateGmTurnUi();
    try {
      await api(`/game-api/campaigns/${currentCampaignId}/combat/end-turn`,{method:'POST'});
      try {
        const inv=await api(`/game-api/campaigns/${currentCampaignId}/inventory`);
        applyInventoryPayload(inv);
      } catch(refreshError) {
        console.warn('Inventory refresh after enemy turns failed:',refreshError);
      }
    } catch(error) {
      document.querySelector('#gmError').textContent=error.message;
      if(error.data?.needsApiKey)showNotice('Open Settings and enter your OpenAI API key before ending the combat turn.',true);
    } finally {
      gmTurnSubmitting=false;
      await refreshGmLive(true);
      try {
        currentTacticalCombatData=await loadTacticalCombatState();
      } catch(error) {
        console.warn('Tactical refresh after End Turn failed:',error);
      }
      updateGmTurnUi();
    }
  };

  const resumeEnemyButton=document.querySelector('#resumeEnemyTurns');
  if(resumeEnemyButton)resumeEnemyButton.onclick=async()=>{
    if(gmTurnSubmitting||!gmCombatTurnState?.active||String(gmCombatTurnState.currentTurnType||'').toLowerCase()!=='monster')return;
    gmTurnSubmitting=true;
    document.querySelector('#gmError').textContent='';
    gmTurnState={...(gmTurnState||{}),active:true,processing:true,isOwner:true,ownerName:(currentDiscordUser?.global_name||currentDiscordUser?.username||'You')};
    updateGmTurnUi();
    try {
      await api(`/game-api/campaigns/${currentCampaignId}/combat/resume-enemy-turns`,{method:'POST'});
      try {
        const inv=await api(`/game-api/campaigns/${currentCampaignId}/inventory`);
        applyInventoryPayload(inv);
      } catch(refreshError) {
        console.warn('Inventory refresh after resumed enemy turns failed:',refreshError);
      }
    } catch(error) {
      document.querySelector('#gmError').textContent=error.message;
      if(error.data?.needsApiKey)showNotice('Open Settings and enter your OpenAI API key before resuming the GM turn.',true);
    } finally {
      gmTurnSubmitting=false;
      await refreshGmLive(true);
      try { currentTacticalCombatData=await loadTacticalCombatState(); }
      catch(error) { console.warn('Tactical refresh after Resume GM Turn failed:',error); }
      updateGmTurnUi();
    }
  };

  bindGmVoiceTimelineControls();
  scrollGmToBottom();
  startGmLiveSync();
}

function clearPortraitCache(characterId = null) {
  if(characterId) {
    const url=portraitObjectUrls.get(characterId);
    if(url) URL.revokeObjectURL(url);
    portraitObjectUrls.delete(characterId);
    return;
  }
  for(const url of portraitObjectUrls.values()) URL.revokeObjectURL(url);
  portraitObjectUrls.clear();
}

function portraitInitials(name) {
  return String(name||'?').trim().split(/\s+/).slice(0,2).map(part=>part[0]?.toUpperCase()||'').join('')||'?';
}

function portraitFrameHtml(characterId, characterName, hasPortrait, extraClass='') {
  return `<div class="portrait-frame ${extraClass}" data-portrait-frame="${characterId}" data-has-portrait="${hasPortrait?'true':'false'}">
    <div class="portrait-placeholder">${escapeHtml(portraitInitials(characterName))}</div>
    <img alt="${escapeHtml(characterName)} portrait" hidden>
  </div>`;
}

async function loadPortraitObjectUrl(characterId, force=false) {
  if(!force && portraitObjectUrls.has(characterId)) return portraitObjectUrls.get(characterId);
  if(force) clearPortraitCache(characterId);
  const headers=new Headers();
  if(discordAccessToken) headers.set('Authorization',`Bearer ${discordAccessToken}`);
  const response=await fetch(`/game-api/campaigns/${currentCampaignId}/characters/${characterId}/portrait`,{headers});
  if(response.status===404)return null;
  if(!response.ok) {
    const text=await response.text();
    throw new Error(text||`Unable to load portrait (HTTP ${response.status}).`);
  }
  const blob=await response.blob();
  const url=URL.createObjectURL(blob);
  portraitObjectUrls.set(characterId,url);
  return url;
}

async function hydratePortraits(scope=document) {
  const frames=[...scope.querySelectorAll('[data-portrait-frame][data-has-portrait="true"]')];
  await Promise.all(frames.map(async frame=>{
    try {
      const url=await loadPortraitObjectUrl(frame.dataset.portraitFrame);
      if(!url)return;
      const img=frame.querySelector('img');
      const placeholder=frame.querySelector('.portrait-placeholder');
      img.src=url;img.hidden=false;if(placeholder)placeholder.hidden=true;
    } catch(error) { console.warn('Unable to load character portrait:',error); }
  }));
}

async function uploadCharacterPortrait(file) {
  if(!file)return;
  const allowed=['image/png','image/jpeg','image/webp'];
  if(!allowed.includes(file.type))return showNotice('Portraits must be PNG, JPEG, or WebP.',true);
  if(file.size>5*1024*1024)return showNotice('Portraits must be 5 MB or smaller.',true);
  const button=document.querySelector('#uploadPortrait');
  if(button){button.disabled=true;button.textContent='Uploading...';}
  try {
    const form=new FormData();form.append('portrait',file);
    await api(`/game-api/campaigns/${currentCampaignId}/character/portrait`,{method:'POST',body:form});
    clearPortraitCache(currentGameData.character.characterId);
    currentGameData.character.hasPortrait=true;
    const self=currentGameData.party?.find(p=>p.characterId===currentGameData.character.characterId);
    if(self)self.hasPortrait=true;
    showNotice('Character portrait saved.');
    renderCharacterTab();
  } catch(error) { showNotice(error.message,true); if(button){button.disabled=false;button.textContent='Upload / Replace Portrait';} }
}

async function removeCharacterPortrait() {
  if(!confirm('Remove your character portrait?'))return;
  try {
    await api(`/game-api/campaigns/${currentCampaignId}/character/portrait`,{method:'DELETE'});
    clearPortraitCache(currentGameData.character.characterId);
    currentGameData.character.hasPortrait=false;
    const self=currentGameData.party?.find(p=>p.characterId===currentGameData.character.characterId);
    if(self)self.hasPortrait=false;
    showNotice('Character portrait removed.');
    renderCharacterTab();
  } catch(error) { showNotice(error.message,true); }
}

function showPartyMemberDetails(member) {
  document.querySelector('#partyMemberOverlay')?.remove();
  const overlay=document.createElement('div');
  overlay.id='partyMemberOverlay';overlay.className='modal-overlay';
  overlay.innerHTML=`<div class="modal party-member-modal">
    <button id="closePartyMember" class="modal-close" aria-label="Close">×</button>
    <div class="party-member-detail">
      ${portraitFrameHtml(member.characterId,member.characterName,member.hasPortrait,'party-detail-portrait')}
      <div class="party-member-sheet">
        <h2>${escapeHtml(member.characterName)}</h2>
        <p>${escapeHtml(member.displayName)} • @${escapeHtml(member.discordUsername)}</p>
        <p>Level ${member.level} ${escapeHtml(member.speciesName)} ${escapeHtml(member.className)} • ${escapeHtml(member.backgroundName||'')} ${member.alignment?`• ${escapeHtml(member.alignment)}`:''}</p>
        <div class="vitals party-detail-vitals"><div>HP <b ${member.characterId===currentGameData?.character?.characterId?'data-live-self-hp':''}>${member.currentHp}/${member.maxHp}</b></div><div>AC <b>${member.armorClass}</b></div><div>Initiative <b>${formatSigned(member.initiative)}</b></div><div>Speed <b>${member.speed} ft.</b></div><div>Passive Perception <b>${member.passivePerception}</b></div><div>Proficiency <b>${formatSigned(member.proficiencyBonus)}</b></div></div>
        <div class="stats">${statBox('STR',member.strength)}${statBox('DEX',member.dexterity)}${statBox('CON',member.constitution)}${statBox('INT',member.intelligence)}${statBox('WIS',member.wisdom)}${statBox('CHA',member.charisma)}</div>
      </div>
    </div>
  </div>`;
  document.body.appendChild(overlay);
  document.querySelector('#closePartyMember').onclick=()=>overlay.remove();
  overlay.onclick=e=>{if(e.target===overlay)overlay.remove();};
  hydratePortraits(overlay);
}

function statBox(name,score){return `<div class="stat"><span>${name}</span><b>${score}</b><small>${formatSigned(abilityMod(score))}</small></div>`;}

const alignmentLadder=['Lawful Good','Neutral Good','Chaotic Good','Lawful Neutral','True Neutral','Chaotic Neutral','Lawful Evil','Neutral Evil','Chaotic Evil'];
function normalizedAlignment(value){return String(value||'').trim().toLowerCase()==='neutral'?'True Neutral':String(value||'True Neutral');}
function alignmentGaugeMarkup(state){
  const alignment=normalizedAlignment(state?.alignment);
  const balance=Math.max(-8,Math.min(8,Number(state?.alignmentDeedBalance)||0));
  const direction=balance<0?'Good':balance>0?'Evil':'Balanced';
  const progress=Math.abs(balance);
  const marker=((balance+9)/18)*100;
  const stageIndex=Math.max(0,alignmentLadder.findIndex(a=>a.toLowerCase()===alignment.toLowerCase()));
  return `<div class="alignment-gauge-card">
    <div class="alignment-gauge-heading"><div><span>Alignment Gauge</span><b>${escapeHtml(alignment)}</b></div><small>${progress}/9 ${direction==='Balanced'?'toward either side':`toward ${direction}`}</small></div>
    <div class="alignment-stage-row">${alignmentLadder.map((a,i)=>`<span class="${i===stageIndex?'current':''}" title="${escapeHtml(a)}">${escapeHtml(a.split(' ').map(w=>w[0]).join(''))}</span>`).join('')}</div>
    <div class="alignment-meter"><span class="alignment-good-label">GOOD</span><div class="alignment-meter-track"><i style="left:${marker}%"></i></div><span class="alignment-evil-label">EVIL</span></div>
    <div class="alignment-counts"><span>Good deeds: <b>${Number(state?.goodDeeds)||0}</b></span><span>Evil deeds: <b>${Number(state?.evilDeeds)||0}</b></span><span>9 net deeds = 1 stage</span></div>
  </div>`;
}

function racialTraitsMarkup(featureState){
  const data=featureState?.racialTraits||{};
  const traits=Array.isArray(data.racialTraits)?data.racialTraits:[];
  const bonuses=data.racialAbilityBonuses&&typeof data.racialAbilityBonuses==='object'
    ?Object.entries(data.racialAbilityBonuses).map(([k,v])=>`${k} +${v}`):[];
  const extras=[];
  if(featureState?.secondaryHeritage)extras.push(`Other half: ${featureState.secondaryHeritage}`);
  if(data.subrace)extras.push(`Subrace: ${data.subrace}`);
  if(data.secondarySubrace)extras.push(`Other-half Subrace: ${data.secondarySubrace}`);
  if(data.dragonbornAncestry)extras.push(`Draconic Ancestry: ${data.dragonbornAncestry}`);
  if(data.secondaryDragonbornAncestry)extras.push(`Other-half Draconic Ancestry: ${data.secondaryDragonbornAncestry}`);
  if(data.highElfCantrip)extras.push(`High Elf Cantrip: ${data.highElfCantrip}`);
  if(data.secondaryHighElfCantrip)extras.push(`Other-half High Elf Cantrip: ${data.secondaryHighElfCantrip}`);
  if(data.dwarfToolProficiency)extras.push(`Dwarven Tool: ${data.dwarfToolProficiency}`);
  if(data.secondaryDwarfToolProficiency)extras.push(`Other-half Dwarven Tool: ${data.secondaryDwarfToolProficiency}`);
  if(data.damageResistance)extras.push(`Damage Resistance: ${data.damageResistance}`);
  if(data.speedOverride)extras.push(`Racial Speed: ${data.speedOverride} ft.`);
  if(data.hitPointBonusPerLevel)extras.push(`Racial HP: +${data.hitPointBonusPerLevel} per level`);
  if(data.size)extras.push(`Size: ${data.size}`);
  if(data.secondarySize)extras.push(`Other-half Tortle Size Choice: ${data.secondarySize}`);
  if(data.natureIntuitionSkill)extras.push(`Nature's Intuition: ${data.natureIntuitionSkill}`);
  if(data.secondaryNatureIntuitionSkill)extras.push(`Other-half Nature's Intuition: ${data.secondaryNatureIntuitionSkill}`);
  if(data.extraLanguage)extras.push(`Language: ${data.extraLanguage}`);
  if(data.secondaryExtraLanguage)extras.push(`Other-half Additional Language: ${data.secondaryExtraLanguage}`);
  if(bonuses.length)extras.push(`Ability increases: ${bonuses.join(', ')}`);
  if(!traits.length&&!extras.length)return '<p class="muted">No stored racial trait metadata for this character yet.</p>';
  return `<div class="racial-detail-list">${extras.map(t=>`<span>${escapeHtml(t)}</span>`).join('')}${traits.map(t=>`<span>${escapeHtml(t)}</span>`).join('')}</div>`;
}

async function loadCharacterFeatureSummary(){
  const host=document.querySelector('#alignmentGaugeHost'); if(!host||!currentCampaignId)return;
  try{
    const state=await api(`/game-api/campaigns/${currentCampaignId}/character/features`);
    if(currentGameData?.character){currentGameData.character.alignment=state.alignment;currentGameData.character.backgroundName=state.background;}
    if(host.isConnected)host.innerHTML=alignmentGaugeMarkup(state);
  }catch(error){if(host.isConnected)host.innerHTML=`<div class="error">${escapeHtml(error.message)}</div>`;}
}

async function showCharacterDetails(){
  try{
    const state=await api(`/game-api/campaigns/${currentCampaignId}/character/features`);
    const overlay=document.createElement('div');overlay.className='modal-overlay';
    const render=(editing=false)=>{
      overlay.innerHTML=`<div class="modal character-details-modal"><button class="modal-close" id="closeCharacterDetails" aria-label="Close">×</button>
        <h3>Character Details</h3>${alignmentGaugeMarkup(state)}
        ${editing?`<div class="character-details-form">
          <label>Background</label><input id="detailBackground" class="input" value="${escapeHtml(state.background||'')}">
          <label>Appearance</label><textarea id="detailAppearance" class="input textarea">${escapeHtml(state.appearance||'')}</textarea>
          <label>Personality</label><textarea id="detailPersonality" class="input textarea">${escapeHtml(state.personality||'')}</textarea>
          <label>Backstory</label><textarea id="detailBackstory" class="input textarea detail-long">${escapeHtml(state.backstory||'')}</textarea>
          <label>Notes</label><textarea id="detailNotes" class="input textarea detail-long">${escapeHtml(state.notes||'')}</textarea>
          <div id="characterDetailError" class="error"></div><div class="modal-actions"><button id="cancelCharacterEdit" class="button">Cancel</button><button id="saveCharacterDetails" class="button primary">Save Changes</button></div>
        </div>`:`<div class="character-detail-sections">
          <section><h4>Background</h4><p>${escapeHtml(state.background||'Not entered.')}</p></section>
          <section><h4>Appearance</h4><p>${escapeHtml(state.appearance||'Not entered.').replaceAll('\n','<br>')}</p></section>
          <section><h4>Personality</h4><p>${escapeHtml(state.personality||'Not entered.').replaceAll('\n','<br>')}</p></section>
          <section><h4>Backstory</h4><p>${escapeHtml(state.backstory||'Not entered.').replaceAll('\n','<br>')}</p></section>
          <section><h4>Notes</h4><p>${escapeHtml(state.notes||'Not entered.').replaceAll('\n','<br>')}</p></section>
          <section><h4>Racial Traits</h4>${racialTraitsMarkup(state)}</section>
          <div class="modal-actions"><button id="editCharacterDetails" class="button primary">Edit</button></div>
        </div>`}</div>`;
      overlay.querySelector('#closeCharacterDetails').onclick=()=>overlay.remove();
      if(editing){
        overlay.querySelector('#cancelCharacterEdit').onclick=()=>render(false);
        overlay.querySelector('#saveCharacterDetails').onclick=async()=>{
          const btn=overlay.querySelector('#saveCharacterDetails');btn.disabled=true;btn.textContent='Saving...';
          try{
            const payload={background:overlay.querySelector('#detailBackground').value.trim(),appearance:overlay.querySelector('#detailAppearance').value.trim(),personality:overlay.querySelector('#detailPersonality').value.trim(),backstory:overlay.querySelector('#detailBackstory').value.trim(),notes:overlay.querySelector('#detailNotes').value.trim()};
            await api(`/game-api/campaigns/${currentCampaignId}/character/details`,{method:'PUT',body:JSON.stringify(payload)});
            Object.assign(state,payload);if(currentGameData?.character)currentGameData.character.backgroundName=payload.background;
            showNotice('Character details saved.');render(false);loadCharacterFeatureSummary();
          }catch(error){overlay.querySelector('#characterDetailError').textContent=error.message;btn.disabled=false;btn.textContent='Save Changes';}
        };
      }else overlay.querySelector('#editCharacterDetails').onclick=()=>render(true);
    };
    render(false);document.body.appendChild(overlay);overlay.onclick=e=>{if(e.target===overlay)overlay.remove();};
  }catch(error){showNotice(error.message,true);}
}

function renderCharacterTab(){
  const c=currentGameData.character,party=currentGameData.party||[],view=document.querySelector('#gameView');
  const self=party.find(p=>p.characterId===c.characterId);
  const hasPortrait=Boolean(c.hasPortrait||self?.hasPortrait);
  view.innerHTML=`<div class="view-heading"><div><h3>Character Sheet & Party</h3><p class="muted">Add your portrait, view your alignment gauge and details, or click any party member to view their character card.</p></div><div class="row gap"><button id="characterDetails" class="button small">Background & Details</button><button id="refreshParty" class="button small">Refresh Party</button></div></div>
    <div class="character-grid visual-character-grid">
      <section class="panel character-sheet-panel">
        <div class="character-sheet-layout">
          <div class="own-portrait-column">
            ${portraitFrameHtml(c.characterId,c.characterName,hasPortrait,'own-character-portrait')}
            <input id="portraitFile" type="file" accept="image/png,image/jpeg,image/webp" hidden>
            <button id="uploadPortrait" class="button primary wide">${hasPortrait?'Replace Portrait':'Upload Portrait'}</button>
            ${hasPortrait?'<button id="removePortrait" class="button danger-button wide">Remove Portrait</button>':''}
            <small class="portrait-help">PNG, JPEG, or WebP • 5 MB max</small>
          </div>
          <div class="character-sheet-details">
            <h2>${escapeHtml(c.characterName)}</h2>
            <p>Level ${c.level} ${escapeHtml(c.speciesName)} ${escapeHtml(c.className)} • ${escapeHtml(c.backgroundName)} • ${escapeHtml(c.alignment)}</p>
            <div class="vitals"><div>HP <b data-live-self-hp>${c.currentHp}/${c.maxHp}</b></div><div>AC <b>${c.armorClass}</b></div><div>Initiative <b>${formatSigned(c.initiative)}</b></div><div>Speed <b>${c.speed} ft.</b></div><div>Passive Perception <b>${c.passivePerception}</b></div><div>Proficiency <b>${formatSigned(c.proficiencyBonus)}</b></div></div>
            <div class="currency-purse-card"><span>Currency Purse</span><b data-live-self-currency>${currencyPurseText(c.gold)}</b><small>10 CP = 1 SP • 10 SP = 1 GP • 10 GP = 1 PP</small></div>
            <div id="experienceProgressHost" class="experience-progress-host">${experienceProgressHtml(currentProgression)}</div>
            <div id="restResourceHost" class="rest-resource-host">${restResourceHtml(lastRestState)}</div>
            <div class="stats">${statBox('STR',c.strength)}${statBox('DEX',c.dexterity)}${statBox('CON',c.constitution)}${statBox('INT',c.intelligence)}${statBox('WIS',c.wisdom)}${statBox('CHA',c.charisma)}</div>
            <div id="alignmentGaugeHost" class="alignment-gauge-host"><div class="loading mini">Loading alignment...</div></div>
          </div>
        </div>
      </section>
      <section class="panel party-panel"><h3>Campaign Party</h3><p class="muted">Select a character to view their portrait and current public combat stats.</p>
        <div class="party-list visual-party-list">${party.length?party.map((p,index)=>`<button class="party-card visual-party-card" data-party-index="${index}">
          ${portraitFrameHtml(p.characterId,p.characterName,p.hasPortrait,'party-thumbnail')}
          <div class="party-card-copy"><b>${escapeHtml(p.characterName)}</b><small>${escapeHtml(p.displayName)} • Level ${p.level} ${escapeHtml(p.speciesName)} ${escapeHtml(p.className)}</small><span>HP <b ${p.characterId===c.characterId?'data-live-self-hp':''}>${p.currentHp}/${p.maxHp}</b> • AC ${p.armorClass}</span></div><span class="party-view-hint">View →</span>
        </button>`).join(''):'<div class="empty small">No characters are in this campaign yet.</div>'}</div>
      </section>
    </div>`;
  document.querySelector('#refreshParty').onclick=refreshPartyData;
  document.querySelector('#characterDetails').onclick=showCharacterDetails;
  document.querySelector('#uploadPortrait').onclick=()=>document.querySelector('#portraitFile').click();
  document.querySelector('#portraitFile').onchange=e=>uploadCharacterPortrait(e.target.files?.[0]);
  const remove=document.querySelector('#removePortrait');if(remove)remove.onclick=removeCharacterPortrait;
  document.querySelectorAll('[data-party-index]').forEach(button=>button.onclick=()=>showPartyMemberDetails(party[Number(button.dataset.partyIndex)]));
  hydratePortraits(view);
  void loadCharacterFeatureSummary();
  void refreshCharacterProgression(true);
  void refreshRestState(true);
}

async function refreshPartyData() {
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/party`);
    currentGameData.party=data.party||[];
    const self=currentGameData.party.find(p=>p.characterId===currentGameData.character.characterId);
    currentGameData.character.hasPortrait=Boolean(self?.hasPortrait);
    clearPortraitCache();
    renderCharacterTab();
  } catch(error) { showNotice(error.message,true); }
}

function renderInventoryTab() {
  const items=currentGameData.inventory||[],view=document.querySelector('#gameView');
  if(items.length && !items.some(i=>i.inventoryItemId===selectedInventoryId)) selectedInventoryId=items[0].inventoryItemId;
  if(!items.length) selectedInventoryId=null;
  const selected=items.find(i=>i.inventoryItemId===selectedInventoryId)||null;

  view.innerHTML=`
    <div class="view-heading"><div><h3>Inventory</h3><p class="muted">Select an item to inspect it and see the actions it supports.</p></div><span class="inventory-currency" data-live-self-currency>${currencyPurseText(currentGameData.character.gold)}</span></div>
    <div id="encumbranceHost">${encumbranceHtml()}</div>
    <div class="inventory-layout">
      <section class="inventory-list-panel">
        ${items.length?items.map(i=>`
          <button class="inventory-list-item ${i.inventoryItemId===selectedInventoryId?'selected':''}" data-id="${i.inventoryItemId}">
            <span><b>${escapeHtml(i.itemName)}</b><small>${escapeHtml(i.rarity||'Common')} • ${escapeHtml(i.valuationCategory||i.itemType||'Item')}${i.ration?` • ${Math.max(0,Number(i.ration.portionsRemaining)||0)}/${Math.max(1,Number(i.ration.maximumPortions)||3)} Portions`:''}${i.waterskin?` • ${Math.max(0,Number(i.waterskin.drinksRemaining)||0)}/${Math.max(1,Number(i.waterskin.maximumDrinks)||30)} Drinks • ${escapeHtml(i.waterskin.waterQuality||'empty')}`:''}${i.equipped?' • Equipped':''}</small></span>
            <strong>×${i.quantity}</strong>
          </button>`).join(''):'<div class="empty small">No inventory items.</div>'}
      </section>
      <section class="inventory-detail-panel">
        ${selected?inventoryDetailHtml(selected):`<div class="empty"><b>Select an inventory item</b><span>Its description and available actions will appear here.</span></div>`}
      </section>
    </div>`;

  document.querySelectorAll('.inventory-list-item').forEach(button=>button.onclick=()=>{
    selectedInventoryId=button.dataset.id;
    renderInventoryTab();
  });
  if(!selected)return;
  const equip=document.querySelector('#inventoryEquip');if(equip)equip.onclick=()=>toggleInventoryEquip(selected);
  const use=document.querySelector('#inventoryUse');if(use)use.onclick=()=>confirmUseInventoryItem(selected);
  const eatRation=document.querySelector('#inventoryEatRation');if(eatRation)eatRation.onclick=()=>eatRationPortion(selected,eatRation);
  const drink=document.querySelector('#inventoryDrink');if(drink)drink.onclick=()=>drinkFromWaterskin(selected,drink);
  const fill=document.querySelector('#inventoryFillWaterskin');if(fill)fill.onclick=()=>prepareFillWaterskinAction(selected);
  const boil=document.querySelector('#inventoryBoilWaterskin');if(boil)boil.onclick=()=>prepareBoilWaterskinAction(selected);
  const drop=document.querySelector('#inventoryDrop');if(drop)drop.onclick=()=>showDropInventoryDialog(selected);
}

function inventoryDetailHtml(item) {
  const meta=[item.rarity||'Common',item.valuationCategory||item.itemType||'Item',item.equipmentSlot?`Slot: ${item.equipmentSlot}`:'',`Quantity: ${item.quantity}`,item.equipped?'Equipped':''].filter(Boolean).join(' • ');
  const valueText=item.priceless?'Priceless':formatShopGp(item.baseValueGp||0);
  const resaleText=item.sellable&&!item.priceless?formatShopGp(item.standardSellValueGp||0):'Not normally sellable';
  return `
    <div class="inventory-detail-heading"><div><h4>${escapeHtml(item.itemName)}</h4><p>${escapeHtml(meta)}</p></div>${item.equipped?'<span class="badge">EQUIPPED</span>':''}</div>
    <div class="inventory-value-card"><div><small>RARITY</small><b>${escapeHtml(item.rarity||'Common')}</b></div><div><small>BASE VALUE</small><b>${valueText}</b></div><div><small>TYPICAL SHOP OFFER</small><b>${resaleText}</b></div></div>
    <div class="inventory-physical-card"><span><small>WEIGHT</small><b>${Math.max(0,Number(item.weightLb)||0).toFixed(2)} lb each</b></span>${Number(item.foodLb)>0?`<span><small>FOOD</small><b>${Number(item.foodLb).toFixed(2)} lb</b></span>`:''}${Number(item.waterGallons)>0?`<span><small>WATER</small><b>${Number(item.waterGallons).toFixed(2)} gal</b></span>`:''}</div>
    ${item.priceBand?`<p class="muted inventory-price-band">${escapeHtml(item.priceBand)}</p>`:''}
    ${rationDetailHtml(item)}
    ${waterskinDetailHtml(item)}
    <div class="inventory-description">${escapeHtml(item.description||'No description is available for this item.').replaceAll('\n','<br>')}</div>
    ${item.rulesSummary?`<div class="inventory-rules"><b>Equipment Details</b><div>${escapeHtml(item.rulesSummary).replaceAll('\n','<br>')}</div></div>`:''}
    ${item.notes?`<div class="inventory-notes"><b>Notes:</b> ${escapeHtml(item.notes)}</div>`:''}
    <div class="inventory-actions">
      ${item.canEquip?`<button id="inventoryEquip" class="button primary">${item.equipped?'Unequip':'Equip'}</button>`:''}
      ${item.canUse?'<button id="inventoryUse" class="button primary">Use</button>':''}
      ${item.ration?`<button id="inventoryEatRation" class="button primary" ${item.ration.canEat?'':'disabled'}>Eat Portion</button>`:''}
      ${item.waterskin?`<button id="inventoryDrink" class="button primary" ${item.waterskin.canDrink?'':'disabled'}>Drink</button>`:''}
      ${item.waterskin?.canFill?'<button id="inventoryFillWaterskin" class="button">Fill at Water Source</button>':''}
      ${item.waterskin?.canBoil?'<button id="inventoryBoilWaterskin" class="button">Boil Water</button>':''}
      <button id="inventoryDrop" class="button danger-button">Drop</button>
    </div>
    ${!item.canEquip&&!item.canUse&&!item.ration&&!item.waterskin?'<p class="muted inventory-action-note">This item can be carried or dropped, but it is not wearable/wieldable equipment or a consumable.</p>':''}`;
}

function rationDetailHtml(item) {
  const ration=item.ration;if(!ration)return '';
  const max=Math.max(1,Number(ration.maximumPortions)||Math.max(1,(Number(ration.dayCount)||1)*3));
  const portions=Math.max(0,Math.min(max,Number(ration.portionsRemaining)||0));
  const days=Math.max(1,Number(ration.dayCount)||Math.ceil(max/3));
  const restore=Math.max(0,Number(ration.hungerPercentPerPortion)||33);
  return `<div class="ration-card">
    <div class="ration-card-heading"><span><small>RATION PORTIONS</small><b>${portions} / ${max} Remaining</b></span><span class="ration-days">${days} ${days===1?'day':'days'}</span></div>
    <div class="ration-meter" role="progressbar" aria-label="Ration portions remaining" aria-valuemin="0" aria-valuemax="${max}" aria-valuenow="${portions}"><i style="width:${Math.round(portions/max*100)}%"></i></div>
    <div class="ration-meta"><span><small>PORTIONS PER DAY</small><b>3</b></span><span><small>HUNGER PER PORTION</small><b>+${restore}%</b></span></div>
  </div>`;
}

function waterskinDetailHtml(item) {
  const skin=item.waterskin;if(!skin)return '';
  const drinks=Math.max(0,Math.min(Number(skin.maximumDrinks)||30,Number(skin.drinksRemaining)||0));
  const max=Math.max(1,Number(skin.maximumDrinks)||30);
  const quality=String(skin.waterQuality||'empty').toLowerCase();
  const label=quality==='tainted'?'Tainted':quality==='clean'?'Clean':'Empty';
  const source=skin.sourceName?`<span><small>SOURCE</small><b>${escapeHtml(skin.sourceName)}</b></span>`:'';
  return `<div class="waterskin-card ${quality==='tainted'?'tainted':''}">
    <div class="waterskin-card-heading"><span><small>WATERSKIN CONTENTS</small><b>${drinks} / ${max} Drinks</b></span><span class="waterskin-quality ${quality}">${label}</span></div>
    <div class="waterskin-meter" role="progressbar" aria-label="Waterskin drinks remaining" aria-valuemin="0" aria-valuemax="${max}" aria-valuenow="${drinks}"><i style="width:${Math.round(drinks/max*100)}%"></i></div>
    <div class="waterskin-meta"><span><small>CAPACITY</small><b>3 days</b></span>${source}</div>
    ${skin.taintedWarning?`<p class="waterskin-warning">${escapeHtml(skin.taintedWarning)}</p>`:''}
    ${skin.magicNote?`<p class="waterskin-magic-note">${escapeHtml(skin.magicNote)}</p>`:''}
  </div>`;
}

async function refreshInventoryData() {
  const data=await api(`/game-api/campaigns/${currentCampaignId}/inventory`);
  applyInventoryPayload(data);
  renderInventoryTab();
}

async function toggleInventoryEquip(item) {
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/inventory/${item.inventoryItemId}/equip`,{method:'POST'});
    showNotice(data.message||`${item.itemName} updated.`);
    await refreshInventoryData();
  } catch(error){showNotice(error.message,true);}
}

async function eatRationPortion(item,button) {
  if(!item.ration?.canEat)return;
  const original=button.textContent;
  button.disabled=true;button.textContent='Eating…';
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/inventory/${item.inventoryItemId}/eat-ration`,{method:'POST'});
    showNotice(data.message||`Ate one portion of ${item.itemName}.`);
    await refreshInventoryData();
    await refreshSurvivalState();
  } catch(error) {
    showNotice(error.message,true);
    button.disabled=false;button.textContent=original;
  }
}

async function drinkFromWaterskin(item,button) {
  if(!item.waterskin?.canDrink)return;
  const original=button.textContent;
  button.disabled=true;button.textContent='Drinking…';
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/inventory/${item.inventoryItemId}/drink`,{method:'POST'});
    showNotice(data.message||`Drank from ${item.itemName}.`);
    await refreshInventoryData();
    await refreshSurvivalState();
  } catch(error) {
    showNotice(error.message,true);
    button.disabled=false;button.textContent=original;
  }
}

function prepareFillWaterskinAction(item) {
  prefillGameMasterMessage(`I fill my selected ${item.itemName} (inventory item ${item.inventoryItemId}) from this water source.`);
}

function prepareBoilWaterskinAction(item) {
  prefillGameMasterMessage(`I boil the tainted water in my selected waterskin (inventory item ${item.inventoryItemId}) and pour it back into the waterskin.`);
}

function showDropInventoryDialog(item) {
  const quantityField=item.quantity>1
    ?`<label>Quantity to Drop</label><input id="dropQuantity" class="input" type="number" min="1" max="${item.quantity}" value="1"><p class="muted">You currently carry ${item.quantity}.</p>`
    :`<p>Drop <b>${escapeHtml(item.itemName)}</b>?</p><p class="muted">Dropping it permanently removes it from this character's inventory.</p>`;
  showModal('Drop Inventory Item',quantityField,'Drop',async()=>{
    const quantity=item.quantity>1?Number(document.querySelector('#dropQuantity').value):1;
    if(!Number.isInteger(quantity)||quantity<1||quantity>item.quantity)throw new Error(`Choose a quantity from 1 to ${item.quantity}.`);
    const data=await api(`/game-api/campaigns/${currentCampaignId}/inventory/${item.inventoryItemId}/drop`,{method:'POST',body:JSON.stringify({quantity})});
    document.querySelector('#modalOverlay')?.remove();
    showNotice(data.message||'Item dropped.');
    await refreshInventoryData();
  });
}

function confirmUseInventoryItem(item) {
  showModal('Use Inventory Item',`
    <p>Use <b>${escapeHtml(item.itemName)}</b>?</p>
    <p class="muted">RabuShin will prepare an "I use ${escapeHtml(item.itemName)}" action for the AI Game Master. The item is not consumed until the GM successfully resolves the use.</p>`,
    'Prepare Action',async()=>{
      document.querySelector('#modalOverlay')?.remove();
      prefillGameMasterMessage(`I use ${item.itemName}`);
    });
}

function prefillGameMasterMessage(message) {
  const gmButton=document.querySelector('.game-tab[data-tab="gm"]');
  switchGameTab('gm',gmButton);
  const input=document.querySelector('#gmInput');
  if(!input)return;
  input.value=message;
  gmTurnDraft=message;
  input.focus();
  const end=input.value.length;
  input.setSelectionRange?.(end,end);
  updateGmTurnUi();
  void acquireGmTurnForDraft();
}

function renderSpellbookTab() {
  const spells=currentGameData.spells||[],slots=currentGameData.spellSlots||[];
  document.querySelector('#gameView').innerHTML=`
    <div class="view-heading"><div><h3>Spellbook</h3><p class="muted">Click a spell to prepare "I cast {Spell}" in the AI Game Master. Add a target or other details, then press Send.</p></div></div>
    ${slots.length?`<div class="slot-row">${slots.map(s=>`<span>Level ${s.spellLevel}: <b>${Math.max(0,s.maxSlots-s.usedSlots)}/${s.maxSlots}</b></span>`).join('')}</div>`:''}
    <div class="spellbook-list">${spells.length?spells.map((s,index)=>{const d=s.spellData||{};return `
      <button class="spell-card spell-cast-card" data-spell-index="${index}">
        <div class="spell-card-heading"><h4>${escapeHtml(s.spellName)} <small>${s.spellLevel===0?'Cantrip':`Level ${s.spellLevel}`}</small></h4><span class="cast-hint">Cast →</span></div>
        <p>${s.prepared?'Prepared • ':'Not Prepared • '}${escapeHtml(d.casting_time||'')} ${escapeHtml(d.range||'')}</p>
        <div>${escapeHtml(d.description||'')}</div>
      </button>`;}).join(''):'<div class="empty small">This character has no class spells.</div>'}</div>`;

  document.querySelectorAll('.spell-cast-card').forEach(card=>card.onclick=()=>{
    const spell=spells[Number(card.dataset.spellIndex)];
    if(!spell)return;
    prefillGameMasterMessage(`I cast ${spell.spellName}`);
    if(spell.spellLevel>0&&!spell.prepared)showNotice(`${spell.spellName} is not currently prepared. The GM will enforce preparation rules.`,true);
  });
}

function renderJournalTab(){const entries=currentGameData.journal||[];document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Journal</h3><button id="refreshJournal" class="button small">Refresh</button></div><div class="two-col"><div><div class="journal-list">${entries.length?entries.map(j=>`<article><small>${escapeHtml(j.category)}</small><h4>${escapeHtml(j.title||'Journal Entry')}</h4><p>${escapeHtml(j.entryText).replaceAll('\n','<br>')}</p></article>`).join(''):'<div class="empty small">No journal entries.</div>'}</div></div><div class="panel"><h4>Add Entry</h4><input id="journalTitle" class="input" placeholder="Title"><select id="journalCategory" class="input"><option>Note</option><option>Quest</option><option>NPC</option><option>Location</option><option>Loot</option></select><textarea id="journalText" class="input textarea" placeholder="Journal entry"></textarea><button id="saveJournal" class="button primary wide">Save Entry</button><div id="journalError" class="error"></div></div></div>`;
  document.querySelector('#refreshJournal').onclick=refreshJournal;
  document.querySelector('#saveJournal').onclick=async()=>{const text=document.querySelector('#journalText').value.trim();if(!text)return;try{await api(`/game-api/campaigns/${currentCampaignId}/journal`,{method:'POST',body:JSON.stringify({category:document.querySelector('#journalCategory').value,title:document.querySelector('#journalTitle').value.trim(),entryText:text})});await refreshJournal();}catch(e){document.querySelector('#journalError').textContent=e.message;}};
}
async function refreshJournal(){const d=await api(`/game-api/campaigns/${currentCampaignId}/journal`);currentGameData.journal=d.entries;renderJournalTab();}

function renderChatTab(){
  const existingInput=document.querySelector('#chatInput');
  if(existingInput)campaignChatDraft=existingInput.value;
  document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Campaign Chat</h3><button id="refreshChat" class="button small">Refresh</button></div><div id="chatTimeline" class="timeline chat">${timelineHtml(currentGameData.chatMessages,'No campaign chat messages yet.')}</div><div class="composer"><textarea id="chatInput" class="input" placeholder="Message the party"></textarea><button id="sendChat" class="button primary">Send</button></div><div id="chatError" class="error"></div>`;
  const input=document.querySelector('#chatInput');
  input.value=campaignChatDraft;
  input.addEventListener('input',()=>campaignChatDraft=input.value);
  document.querySelector('#refreshChat').onclick=()=>refreshChatLive(true);
  document.querySelector('#sendChat').onclick=async()=>{
    const message=input.value.trim();
    if(!message)return;
    const send=document.querySelector('#sendChat');
    send.disabled=true;
    try {
      await api(`/game-api/campaigns/${currentCampaignId}/chat`,{method:'POST',body:JSON.stringify({message})});
      campaignChatDraft='';
      input.value='';
      await refreshChatLive(true);
    } catch(e) {
      document.querySelector('#chatError').textContent=e.message;
    } finally {
      send.disabled=false;
    }
  };
  bindChatEnterToSend(input,document.querySelector('#sendChat'));
  startChatLiveSync();
}
async function refreshChat(){await refreshChatLive(true);}

function populateGmVoiceSelect() {
  const select=document.querySelector('#gmVoiceSelect');
  if(!select)return;
  refreshGmVoiceList();
  const prefs=getGmVoicePreferences();
  const options=['<option value="">System / Browser Default</option>'];
  for(const voice of gmVoiceAvailableVoices) {
    const value=escapeHtml(String(voice.voiceURI||voice.name||''));
    const label=`${voice.name||'Unnamed Voice'}${voice.lang?` (${voice.lang})`:''}${voice.default?' — Default':''}`;
    options.push(`<option value="${value}">${escapeHtml(label)}</option>`);
  }
  select.innerHTML=options.join('');
  select.value=[...select.options].some(o=>o.value===prefs.voiceURI)?prefs.voiceURI:'';
}

function syncGmVoiceSettingLabels() {
  const prefs=getGmVoicePreferences();
  const rate=document.querySelector('#gmVoiceRateValue');
  const pitch=document.querySelector('#gmVoicePitchValue');
  const volume=document.querySelector('#gmVoiceVolumeValue');
  if(rate)rate.textContent=`${prefs.rate.toFixed(2)}×`;
  if(pitch)pitch.textContent=prefs.pitch.toFixed(2);
  if(volume)volume.textContent=`${Math.round(prefs.volume*100)}%`;
}

function bindGmVoiceSettings() {
  const supported=gmVoiceSupported();
  const prefs=getGmVoicePreferences();
  const enabled=document.querySelector('#gmVoiceEnabled');
  if(!enabled)return;
  bindGmVoiceEventsOnce();
  populateGmVoiceSelect();
  enabled.checked=supported&&prefs.enabled;
  enabled.disabled=!supported;
  const voice=document.querySelector('#gmVoiceSelect');
  const rate=document.querySelector('#gmVoiceRate');
  const pitch=document.querySelector('#gmVoicePitch');
  const volume=document.querySelector('#gmVoiceVolume');
  const test=document.querySelector('#testGmVoice');
  const stop=document.querySelector('#stopGmVoice');
  if(voice)voice.disabled=!supported;
  if(rate){rate.value=String(prefs.rate);rate.disabled=!supported;}
  if(pitch){pitch.value=String(prefs.pitch);pitch.disabled=!supported;}
  if(volume){volume.value=String(prefs.volume);volume.disabled=!supported;}
  if(test)test.disabled=!supported;
  if(stop)stop.disabled=!supported;
  syncGmVoiceSettingLabels();

  enabled.onchange=()=>{
    const next=saveGmVoicePreferences({enabled:enabled.checked});
    if(!next.enabled)stopGmVoicePlayback();
    showNotice(`AI Game Master Voice ${next.enabled?'enabled':'disabled'} on this device.`);
  };
  if(voice)voice.onchange=()=>saveGmVoicePreferences({voiceURI:voice.value});
  const bindRange=(input,key)=>{if(!input)return;input.oninput=()=>{saveGmVoicePreferences({[key]:Number(input.value)});syncGmVoiceSettingLabels();};};
  bindRange(rate,'rate');
  bindRange(pitch,'pitch');
  bindRange(volume,'volume');
  if(test)test.onclick=()=>speakGmVoiceText('RabuShin AI Game Master voice is ready.',{messageKey:'gm-voice-test',manual:true});
  if(stop)stop.onclick=stopGmVoicePlayback;
}

function renderSettingsTab(){
  document.querySelector('#gameView').innerHTML=`
    <div class="view-heading"><h3>Settings</h3></div>
    <section class="panel settings">
      <h4>OpenAI API Key</h4>
      <p>${currentGameData.openAiConfigured?'<span class="good">A personal OpenAI API key is securely stored for your Discord account.</span>':'<span class="warn">No personal OpenAI API key is saved.</span>'}</p>
      <p class="muted">Public RabuShin uses each player’s own OpenAI API key. When you choose <b>Test & Save API Key</b>, the server validates the key, encrypts it, and stores only the encrypted value in Supabase. The key is never displayed again or shared with other players. You are responsible for charges and limits on your own OpenAI account.</p>
      <input id="apiKeyInput" class="input mono" type="password" autocomplete="off" placeholder="Paste your OpenAI API key">
      <div class="row gap settings-actions"><button id="saveApiKey" class="button primary">Test & Save API Key</button><button id="clearApiKey" class="button danger-button">Remove Saved Key</button><button id="openOpenAiKeys" class="button">Open OpenAI API Keys</button></div>
      <div id="settingsError" class="error"></div>
    </section>
    <section class="panel settings survival-settings">
      <h4>Hunger & Thirst Survival Rules</h4>
      <p>${currentGameData?.survival?.enabled?'<span class="good">Hunger and Thirst are ON for this campaign.</span>':'<span class="muted">Hunger and Thirst are OFF for this campaign.</span>'}</p>
      <p class="muted">When enabled, characters need 1 lb of food and 1 gallon of water per in-game day. Hot weather raises water to 2 gallons. Missing requirements can add Exhaustion. Weight Capacity remains active even when Hunger and Thirst are off.</p>
      <button id="toggleSurvivalRules" class="button ${currentGameData?.survival?.enabled?'danger-button':'primary'}" ${currentGameData?.campaign?.isOwner?'':'disabled'}>${currentGameData?.survival?.enabled?'Turn Hunger & Thirst OFF':'Turn Hunger & Thirst ON'}</button>
      ${currentGameData?.campaign?.isOwner?'':'<small class="muted settings-owner-note">Only the campaign owner can change this setting.</small>'}
      <div id="survivalSettingsError" class="error"></div>
    </section>
    <section class="panel settings gm-voice-settings">
      <h4>AI Game Master Voice</h4>
      ${gmVoiceSupported()?'':'<p class="warn">This browser does not expose a speech-synthesis voice. Text responses will continue to work normally.</p>'}
      <label class="gm-voice-toggle"><input id="gmVoiceEnabled" type="checkbox"> <span>Speak new AI Game Master responses automatically</span></label>
      <p class="muted">Free, device-local narration using your browser or operating system voices. This preference belongs only to your Discord account on this device and does not add OpenAI/TTS API charges. Markdown, URLs, code blocks, tables, and standalone dice-result lines are cleaned from speech while narration and dialogue remain.</p>
      <div class="gm-voice-grid">
        <label>Voice<select id="gmVoiceSelect" class="input"><option value="">System / Browser Default</option></select></label>
        <label>Speed <b id="gmVoiceRateValue">1.00×</b><input id="gmVoiceRate" type="range" min="0.5" max="2" step="0.05" value="1"></label>
        <label>Pitch <b id="gmVoicePitchValue">1.00</b><input id="gmVoicePitch" type="range" min="0" max="2" step="0.05" value="1"></label>
        <label>Volume <b id="gmVoiceVolumeValue">100%</b><input id="gmVoiceVolume" type="range" min="0" max="1" step="0.05" value="1"></label>
      </div>
      <div class="row gap settings-actions"><button id="testGmVoice" class="button primary">🔊 Test Voice</button><button id="stopGmVoice" class="button">⏹ Stop Voice</button></div>
      <small class="muted">Automatic narration starts only for responses that arrive after the campaign view is opened; existing chat history is never read aloud automatically. Use Speak Again beneath any GM response for manual replay.</small>
    </section>
    <section class="panel settings legal-settings">
      <h4>Legal & Support</h4>
      <p class="muted">These links open outside the Discord Activity using Discord's approved external-link flow.</p>
      <div class="legal-link-grid">
        <button class="button" data-settings-link="terms">Terms of Service</button>
        <button class="button" data-settings-link="privacy">Privacy Policy</button>
        <button class="button" data-settings-link="support">Support</button>
        <button class="button" data-settings-link="deletion">Data Deletion</button>
        <button class="button" data-settings-link="licenses">Licenses & Attribution</button>
      </div>
    </section>`;

  document.querySelector('#saveApiKey').onclick=async()=>{
    const input=document.querySelector('#apiKeyInput');
    const key=input.value.trim();
    if(!key){document.querySelector('#settingsError').textContent='Paste an OpenAI API key first.';return;}
    const button=document.querySelector('#saveApiKey');
    button.disabled=true;button.textContent='Testing...';document.querySelector('#settingsError').textContent='';
    try{
      const result=await api('/game-api/settings/openai',{method:'POST',body:JSON.stringify({apiKey:key})});
      input.value='';currentGameData.openAiConfigured=true;showNotice(result.message||'API key tested and saved securely.');renderSettingsTab();
    }catch(e){document.querySelector('#settingsError').textContent=e.message;button.disabled=false;button.textContent='Test & Save API Key';}
  };
  document.querySelector('#clearApiKey').onclick=async()=>{
    if(!confirm('Remove the OpenAI API key saved for your Discord account?'))return;
    try{await api('/game-api/settings/openai',{method:'DELETE'});currentGameData.openAiConfigured=false;showNotice('Saved OpenAI API key removed.');renderSettingsTab();}catch(e){document.querySelector('#settingsError').textContent=e.message;}
  };
  const survivalToggle=document.querySelector('#toggleSurvivalRules');
  if(survivalToggle&&currentGameData?.campaign?.isOwner)survivalToggle.onclick=async()=>{
    survivalToggle.disabled=true;
    const enabled=!Boolean(currentGameData?.survival?.enabled);
    try{
      const result=await api(`/game-api/campaigns/${currentCampaignId}/settings/survival`,{method:'POST',body:JSON.stringify({enabled})});
      if(result.survival)currentGameData.survival=result.survival;
      updateSurvivalHeader();
      showNotice(result.message||`Hunger and Thirst ${enabled?'enabled':'disabled'}.`);
      renderSettingsTab();
    }catch(e){
      const error=document.querySelector('#survivalSettingsError');if(error)error.textContent=e.message;
      survivalToggle.disabled=false;
    }
  };
  bindGmVoiceSettings();
  document.querySelector('#openOpenAiKeys').onclick=()=>openExternal('https://platform.openai.com/api-keys');
  document.querySelectorAll('[data-settings-link]').forEach(button=>button.onclick=()=>openExternal(legalUrls[button.dataset.settingsLink]));
}

shell('<section class="panel loading"><h2>Loading RabuShin</h2><p>Connecting to Discord...</p></section>');
checkServer();
setupDiscord();
