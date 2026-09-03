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
let gmTurnSubmitting = false;
let gmTurnDraft = '';
let campaignChatDraft = '';
let gmMessageSignature = '';
let chatMessageSignature = '';

// RULES BUILD 6.2 - DEATH / RESPAWN LIVE STATE
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

function primaryRaceName(species) {
  const value=String(species||'').trim();
  return value.startsWith('Half ')?value.substring(5).trim():value;
}

function isTortleRace(species){return primaryRaceName(species).toLowerCase()==='tortle';}

function racialOptionsHtml(prefix,species,data){
  const heritage=primaryRaceName(species);
  const fixed=data?.racialRules?.fixedBonuses?.[heritage]||null;
  const half=String(species||'').startsWith('Half ');
  const halfNote=half?`<p class="racial-note">Ability increases come from your ${escapeHtml(heritage)} half. Your selected second heritage is stored separately for merged racial traits.</p>`:'';
  if(isTortleRace(species)){
    const t=data?.racialRules?.tortle||{};
    const abilityOptions=(data?.racialRules?.abilityNames||['Strength','Dexterity','Constitution','Intelligence','Wisdom','Charisma']).map(a=>`<option value="${escapeHtml(a)}">${escapeHtml(a)}</option>`).join('');
    const skills=(t.natureSkills||['Animal Handling','Medicine','Nature','Perception','Stealth','Survival']).map(a=>`<option value="${escapeHtml(a)}">${escapeHtml(a)}</option>`).join('');
    return `${halfNote}<div class="racial-rule-card"><b>Tortle Racial Choices</b><small>Natural Armor (base AC 17), 1d6 claws, Hold Breath, Nature's Intuition, and Shell Defense are applied automatically.</small>
      <div class="form-grid racial-choice-grid">
        <div><label>Ability Increase Pattern</label><select id="${prefix}TortlePattern" class="input"><option value="21">+2 / +1</option><option value="111">+1 / +1 / +1</option></select></div>
        <div><label>Size</label><select id="${prefix}TortleSize" class="input"><option>Medium</option><option>Small</option></select></div>
        <div><label id="${prefix}AbilityALabel">+2 Ability</label><select id="${prefix}AbilityA" class="input">${abilityOptions}</select></div>
        <div><label>+1 Ability</label><select id="${prefix}AbilityB" class="input">${abilityOptions}</select></div>
        <div id="${prefix}AbilityCBox" hidden><label>+1 Ability</label><select id="${prefix}AbilityC" class="input">${abilityOptions}</select></div>
        <div><label>Nature's Intuition</label><select id="${prefix}TortleSkill" class="input">${skills}</select></div>
        <div><label>Additional Language</label><input id="${prefix}TortleLanguage" class="input" value="${escapeHtml(t.defaultLanguage||'Aquan')}"></div>
      </div></div>`;
  }
  if(fixed){
    const text=Object.entries(fixed).map(([ability,bonus])=>`${ability} +${bonus}`).join(' • ');
    return `${halfNote}<div class="racial-rule-card"><b>Automatic Racial Ability Increase</b><small>${escapeHtml(text)}</small></div>`;
  }
  return `${halfNote}<div class="racial-rule-card"><b>Racial Traits</b><small>No additional ability-score adjustment is defined by this compatibility ruleset for ${escapeHtml(heritage)}. Existing race mechanics remain in effect.</small></div>`;
}

function wireRacialOptions(prefix,species,data){
  const host=document.querySelector(`#${prefix}RacialOptions`); if(!host)return;
  host.innerHTML=racialOptionsHtml(prefix,species,data);
  if(!isTortleRace(species))return;
  const pattern=document.querySelector(`#${prefix}TortlePattern`);
  const updatePattern=()=>{
    const three=pattern.value==='111';
    document.querySelector(`#${prefix}AbilityCBox`).hidden=!three;
    document.querySelector(`#${prefix}AbilityALabel`).textContent=three?'+1 Ability':'+2 Ability';
  };
  pattern.onchange=updatePattern; updatePattern();
  const a=document.querySelector(`#${prefix}AbilityA`),b=document.querySelector(`#${prefix}AbilityB`),c=document.querySelector(`#${prefix}AbilityC`);
  a.value='Strength'; b.value='Wisdom'; c.value='Constitution';
}

function collectRacialOptions(prefix,species){
  if(!isTortleRace(species))return {racialAbilityChoices:null,tortleSize:null,tortleNatureSkill:null,tortleLanguage:null};
  const pattern=document.querySelector(`#${prefix}TortlePattern`).value;
  const a=document.querySelector(`#${prefix}AbilityA`).value,b=document.querySelector(`#${prefix}AbilityB`).value,c=document.querySelector(`#${prefix}AbilityC`).value;
  const selected=pattern==='111'?[a,b,c]:[a,b];
  if(new Set(selected).size!==selected.length)throw new Error('Each Tortle ability increase must use a different ability score.');
  const racialAbilityChoices={};
  if(pattern==='111'){racialAbilityChoices[a]=1;racialAbilityChoices[b]=1;racialAbilityChoices[c]=1;}
  else {racialAbilityChoices[a]=2;racialAbilityChoices[b]=1;}
  return {racialAbilityChoices,tortleSize:document.querySelector(`#${prefix}TortleSize`).value,tortleNatureSkill:document.querySelector(`#${prefix}TortleSkill`).value,tortleLanguage:document.querySelector(`#${prefix}TortleLanguage`).value.trim()};
}

function configureHalfRace(prefix,species,data){
  const box=document.querySelector(`#${prefix}HalfBox`),select=document.querySelector(`#${prefix}Half`);
  if(String(species||'').startsWith('Half ')){
    const primary=primaryRaceName(species);
    const choices=(data.baseSpecies||[]).filter(v=>String(v).toLowerCase()!==primary.toLowerCase());
    select.innerHTML=choices.map(v=>`<option value="${escapeHtml(v)}">${escapeHtml(v)}</option>`).join('');
    box.hidden=false;
  } else {box.hidden=true;select.innerHTML='';}
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
  main.innerHTML=`<div class="creator"><div class="section-title"><div><h2>Starting Equipment</h2><p>${escapeHtml(character.characterName)} • ${escapeHtml(character.className)}</p></div></div><section class="panel"><div id="equipLoading" class="loading">Loading equipment...</div><div id="equipForm" hidden>
    <h3>Class Equipment</h3><select id="classPack" class="input"></select><div id="classChoiceBox" hidden><label>Choose Item</label><select id="classChoice" class="input"></select></div>
    <h3 class="subhead">Background Equipment</h3><select id="bgPack" class="input"></select><div id="bgChoiceBox" hidden><label>Choose Item</label><select id="bgChoice" class="input"></select></div>
    <h3 class="subhead">Starting Inventory Preview</h3><div id="equipPreview" class="item-list"></div><div class="gold-line">Starting Gold: <b id="equipGold">0 GP</b></div>
    <div id="equipError" class="error"></div><button id="saveEquip" class="button primary wide">Accept Starting Equipment</button></div></section></div>`;
  try {
    const data=await api(`/game-api/campaigns/${campaignId}/starting-equipment`);
    const cp=document.querySelector('#classPack'),bp=document.querySelector('#bgPack');
    cp.innerHTML=data.classPackages.map(p=>`<option value="${p.index}">${escapeHtml(p.label)}</option>`).join('');
    bp.innerHTML=data.backgroundPackages.map(p=>`<option value="${p.index}">${escapeHtml(p.label)}</option>`).join('');
    const selected=(arr,el)=>arr.find(p=>p.index===Number(el.value))||arr[0];
    const configure=(pkg,boxId,selectId)=>{const box=document.querySelector(boxId),sel=document.querySelector(selectId);if(pkg?.choiceOptions?.length){sel.innerHTML=pkg.choiceOptions.map(v=>`<option>${escapeHtml(v)}</option>`).join('');box.hidden=false;}else{sel.innerHTML='';box.hidden=true;}};
    const preview=()=>{
      const c=selected(data.classPackages,cp),b=selected(data.backgroundPackages,bp);configure(c,'#classChoiceBox','#classChoice');configure(b,'#bgChoiceBox','#bgChoice');
      const rows=[]; const add=(pkg,choice,source)=>{for(const i of pkg?.items||[])rows.push({source,name:i.choiceKind&&choice?choice:i.itemName,qty:i.quantity});};
      add(c,document.querySelector('#classChoice').value,'Class');add(b,document.querySelector('#bgChoice').value,'Background');
      document.querySelector('#equipPreview').innerHTML=rows.length?rows.map(r=>`<div class="list-row"><span class="muted">${r.source}</span><b>${escapeHtml(r.name)}</b><span>× ${r.qty}</span></div>`).join(''):'<div class="empty small">This selection grants gold only.</div>';
      document.querySelector('#equipGold').textContent=`${Number(c?.gold||0)+Number(b?.gold||0)} GP`;
    };
    cp.onchange=preview;bp.onchange=preview;document.querySelector('#classChoice').onchange=preview;document.querySelector('#bgChoice').onchange=preview;
    document.querySelector('#equipLoading').hidden=true;document.querySelector('#equipForm').hidden=false;preview();
    document.querySelector('#saveEquip').onclick=async()=>{
      const c=selected(data.classPackages,cp),b=selected(data.backgroundPackages,bp),btn=document.querySelector('#saveEquip');btn.disabled=true;btn.textContent='Saving...';
      try{await api(`/game-api/campaigns/${campaignId}/starting-equipment`,{method:'POST',body:JSON.stringify({classPackageIndex:c.index,classChoice:document.querySelector('#classChoice').value||'',backgroundPackageIndex:b.index,backgroundChoice:document.querySelector('#bgChoice').value||''})});showNotice('Starting equipment saved.');const ch=(await api(`/game-api/campaigns/${campaignId}/character`)).character;await continueCharacterSetup(campaignId,ch);}catch(error){document.querySelector('#equipError').textContent=error.message;btn.disabled=false;btn.textContent='Accept Starting Equipment';}
    };
  }catch(error){document.querySelector('#equipLoading').textContent='Unable to load starting equipment.';showNotice(error.message,true);}
}

async function showSpellSelection(campaignId, character, fromLevelUp=false) {
  const main=document.querySelector('#mainContent');
  main.innerHTML=`<div class="creator"><div class="section-title"><div><h2>Spells & Cantrips</h2><p>${escapeHtml(character.characterName)} • Level ${character.level} ${escapeHtml(character.className)}</p></div></div><section class="panel"><div id="spellLoading" class="loading">Loading spell rules...</div><div id="spellForm" hidden></div><div id="spellError" class="error"></div></section></div>`;
  try {
    const data=await api(`/game-api/campaigns/${campaignId}/spell-options`);
    if(!data.required){await api(`/game-api/campaigns/${campaignId}/spell-selection`,{method:'POST',body:JSON.stringify({cantrips:[],spells:[],preparedWizardSpells:[],mysticArcanum:{}})});return enterCampaign(campaignId);}
    const p=data.progression,form=document.querySelector('#spellForm');
    const spellCard=(s,kind)=>`<label class="spell-option"><input type="checkbox" class="${kind}" value="${escapeHtml(s.name)}"><span><b>${escapeHtml(s.name)}</b><small>${s.level===0?'Cantrip':`Level ${s.level}`} • ${escapeHtml(s.school||'')}</small><em>${escapeHtml(s.description||'')}</em></span></label>`;
    const wizard=data.className.toLowerCase()==='wizard';
    form.innerHTML=`
      <div class="selection-summary">Choose <b>${p.cantripsKnown}</b> cantrip(s). ${wizard?`Add <b>${p.wizardSpellbookCount}</b> spells to your spellbook and prepare <b>${p.preparedSpells}</b>.`:`Choose <b>${p.preparedSpells}</b> class spell(s).`} ${data.alwaysPrepared?.length?`Always prepared: ${data.alwaysPrepared.map(escapeHtml).join(', ')}`:''}</div>
      ${p.cantripsKnown>0?`<h3>Cantrips</h3><div class="spell-grid">${data.cantrips.map(s=>spellCard(s,'cantrip-check')).join('')}</div>`:''}
      ${p.preparedSpells>0||p.wizardSpellbookCount>0?`<h3 class="subhead">Spells</h3><div class="spell-grid">${data.spells.map(s=>wizard?`<div class="wizard-spell"><label><input class="spell-check" type="checkbox" value="${escapeHtml(s.name)}"> <b>${escapeHtml(s.name)}</b> <small>L${s.level}</small></label><label class="prepare"><input class="prepare-check" type="checkbox" value="${escapeHtml(s.name)}" disabled> Prepare</label><p>${escapeHtml(s.description||'')}</p></div>`:spellCard(s,'spell-check')).join('')}</div>`:''}
      <div id="arcanumArea"></div><button id="saveSpells" class="button primary wide">Save Spell Selection</button>`;
    document.querySelector('#spellLoading').hidden=true;form.hidden=false;
    if(wizard){document.querySelectorAll('.spell-check').forEach(ch=>ch.onchange=()=>{const prep=[...document.querySelectorAll('.prepare-check')].find(x=>x.value===ch.value);prep.disabled=!ch.checked;if(!ch.checked)prep.checked=false;});}
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

    document.querySelector('#saveSpells').onclick=async()=>{
      const cantrips=[...document.querySelectorAll('.cantrip-check:checked')].map(x=>x.value),spells=[...document.querySelectorAll('.spell-check:checked')].map(x=>x.value),preparedWizardSpells=[...document.querySelectorAll('.prepare-check:checked')].map(x=>x.value),mysticArcanum={};
      document.querySelectorAll('.arcanum').forEach(x=>mysticArcanum[x.dataset.level]=x.value);
      const btn=document.querySelector('#saveSpells');btn.disabled=true;btn.textContent='Saving Spells...';
      try{await api(`/game-api/campaigns/${campaignId}/spell-selection`,{method:'POST',body:JSON.stringify({cantrips,spells,preparedWizardSpells,mysticArcanum})});levelUpSpellRecoveryBusy=false;showNotice(fromLevelUp?'Level-up spell choices saved.':'Spell selection saved.');await enterCampaign(campaignId,fromLevelUp?'character':'gm');}catch(error){document.querySelector('#spellError').textContent=error.message;btn.disabled=false;btn.textContent='Save Spell Selection';}
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
    currentGameData=await api(`/game-api/campaigns/${campaignId}/bootstrap`);
    currentGameData.inventory=mergeInventoryValuations(currentGameData.inventory||[],currentGameData.inventoryValuations||[]);
    renderGameShell();
    renderGameMasterTab();
    startDeathStatePolling();
    startProgressionPolling();
    startRestStatePolling();
    if(initialTab&&initialTab!=='gm'){
      const target=document.querySelector(`.game-tab[data-tab="${initialTab}"]`);
      if(target)switchGameTab(initialTab,target);
    }
  } catch(error){showNotice(error.message,true);}
}

function renderGameShell() {
  const d=currentGameData,c=d.campaign,ch=d.character,main=document.querySelector('#mainContent');
  main.innerHTML=`<div class="game">
    <div class="game-header"><div><button id="backLauncher" class="button small">← Campaigns</button><h2>${escapeHtml(c.campaignName)}</h2><p>Chapter ${c.currentChapter} • <span id="gameCurrentLocation">${escapeHtml(c.currentLocation)}</span> • ${escapeHtml(ch.characterName)}</p></div><div class="quick-vitals"><span>HP <b data-live-self-hp>${ch.currentHp}/${ch.maxHp}</b></span><span>AC <b>${ch.armorClass}</b></span><span>Coins <b data-live-self-currency>${currencyPurseText(ch.gold)}</b></span></div></div>
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

async function refreshDeathState(force=false) {
  if(!currentCampaignId||deathStatePollBusy||deathActionBusy)return;
  deathStatePollBusy=true;
  try {
    const data=await api(`/game-api/campaigns/${currentCampaignId}/death-state`);
    const death=data.death||null;
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
      <p>If you choose Respawn and cannot pay 10 GP yourself, the living party will be asked to donate. If you choose No, this character remains dead and you will create a replacement character for this campaign.</p>
      <div class="death-actions"><button id="deathRespawnYes" class="button primary">Yes — Respawn</button><button id="deathRespawnNo" class="button danger">No — Create New Character</button></div>
      <div id="deathActionError" class="error"></div>
    </div>`;
  } else if(status==='awaiting_donations') {
    const progress=respawnProgressHtml(death);
    const finalize=death.canFinalize?`<button id="deathFinalizeRespawn" class="button primary wide">Revive ${name}</button>`:'';
    if(viewerIsDeadPlayer) {
      body=`<div class="death-card dead-player-card"><div class="death-icon">✦</div><h2>Waiting for Party Revival</h2>${cause}
        <p>${name} did not have enough GP for Respawn. The living party has been asked to contribute toward the 10 GP price.</p>${progress}${finalize}
        <p class="muted">A valid D&amp;D revival spell or revival item can still revive you while this fund is open.</p><div id="deathActionError" class="error"></div></div>`;
    } else if(death.viewerIsEligibleDonor) {
      const decision=String(death.viewerDecision||'').toLowerCase();
      const donatedByViewer=Math.max(0,Number(death.viewerDonatedGp)||0);
      const viewerGold=Math.max(0,Number(death.viewerGold)||0);
      const viewerWholeGp=Math.floor(viewerGold);
      const remaining=Math.max(0,Number(death.remainingGp)||0);
      const maxDonation=Math.max(0,Math.min(viewerWholeGp,remaining));
      let controls='';
      if(decision==='decline') {
        controls='<div class="death-decision-note">You declined this donation request.</div>';
      } else if(decision==='donate'||deathDonationMode) {
        controls=`<div class="donation-controls"><label>Donation amount (purse: ${currencyPurseText(viewerGold)}; donations use whole GP)</label><div class="row gap"><input id="deathDonationAmount" class="input" type="number" min="1" max="${Math.max(1,maxDonation)}" value="${Math.max(1,Math.min(maxDonation||1,remaining||1))}" ${maxDonation<1?'disabled':''}><button id="deathDonateGp" class="button primary" ${maxDonation<1?'disabled':''}>Donate GP</button>${decision?'':'<button id="deathDonationCancel" class="button">Cancel</button>'}</div>${donatedByViewer?`<small>You have already donated ${donatedByViewer} GP.</small>`:''}</div>`;
      } else {
        controls=`<div class="death-actions"><button id="deathDonationYes" class="button primary" ${viewerWholeGp<1?'disabled':''}>Yes — Donate GP</button><button id="deathDonationNo" class="button danger">No</button></div>${viewerWholeGp<1?'<small class="muted">Your purse does not contain a full 1 GP worth of currency available for this whole-GP donation.</small>':''}`;
      }
      body=`<div class="death-card donation-card"><div class="death-icon">⚕</div><h2>Party Member Needs Revival</h2>
        <p><b>${name}</b> has died and does not have enough gold to respawn. Do you want to donate GP to revive them? <b>10 GP needed for revival.</b></p>${progress}${controls}${finalize}<div id="deathActionError" class="error"></div></div>`;
    } else {
      body=`<div class="death-card donation-card"><div class="death-icon">⚕</div><h2>Respawn Fund in Progress</h2><p>The party is raising GP to revive <b>${name}</b>.</p>${progress}${finalize}<div id="deathActionError" class="error"></div></div>`;
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
    if(data.result?.outcome==='self_paid_respawn'||data.result?.outcome==='rag_respawn') {
      lastDeathState=null; document.querySelector('#deathOverlay')?.remove();
      document.body.classList.remove('death-modal-open');
      await reloadCampaignAfterDeathResolution();
    }
  });

  const no=document.querySelector('#deathRespawnNo');
  if(no)no.onclick=()=>runDeathAction(async()=>{
    const data=await api(`/game-api/campaigns/${currentCampaignId}/death/choice`,{method:'POST',body:JSON.stringify({respawn:false})});
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
  if(donateYes)donateYes.onclick=()=>{deathDonationMode=true;renderDeathOverlay(death);};
  const cancel=document.querySelector('#deathDonationCancel');
  if(cancel)cancel.onclick=()=>{deathDonationMode=false;renderDeathOverlay(death);};

  const donate=document.querySelector('#deathDonateGp');
  if(donate)donate.onclick=()=>runDeathAction(async()=>{
    const amount=Math.floor(Number(document.querySelector('#deathDonationAmount')?.value)||0);
    if(amount<1)throw new Error('Enter at least 1 GP to donate.');
    const data=await api(`/game-api/campaigns/${currentCampaignId}/death/${death.deathId}/donate`,{method:'POST',body:JSON.stringify({amountGp:amount})});
    deathDonationMode=false;
    if(currentGameData?.character&&data.result?.remainingGold!==undefined)currentGameData.character.gold=data.result.remainingGold;
    updateLiveGoldDisplay();
    showNotice(data.result?.outcome==='rag_respawn'?'Party Respawn could not be funded.':'Donation added to the Respawn fund.');
  });

  const decline=document.querySelector('#deathDonationNo');
  if(decline)decline.onclick=()=>runDeathAction(async()=>{
    deathDonationMode=false;
    await api(`/game-api/campaigns/${currentCampaignId}/death/${death.deathId}/decline`,{method:'POST'});
  });

  const revive=document.querySelector('#deathFinalizeRespawn');
  if(revive)revive.onclick=()=>runDeathAction(async()=>{
    await api(`/game-api/campaigns/${currentCampaignId}/death/${death.deathId}/revive`,{method:'POST'});
    showNotice(`${death.deadCharacterName} has been revived at half health.`);
  });
}

function timelineDisplayText(value) {
  return String(value ?? '')
    .replace(/^\[WORLD MAP TRAVEL REQUEST\]\s*/i, '')
    .replace(/^\[SETTLEMENT MOVE\]\s*/i, '');
}
function timelineHtml(messages, emptyText='No messages yet.') {
  if(!messages?.length)return `<div class="empty small">${escapeHtml(emptyText)}</div>`;
  return messages.map(m=>`<div class="message ${m.roleName==='assistant'?'assistant':'user'}"><div class="message-name">${escapeHtml(m.senderName||m.roleName)}</div><div>${escapeHtml(timelineDisplayText(m.messageText)).replaceAll('\n','<br>')}</div></div>`).join('');
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
  timeline.innerHTML=timelineHtml(messages,emptyText);
  timeline.scrollTop=timeline.scrollHeight;
  if(signatureName==='gm')gmMessageSignature=signature;
  else chatMessageSignature=signature;
}

function stopConversationLiveSync() {
  if(conversationLiveSyncTimer)clearTimeout(conversationLiveSyncTimer);
  conversationLiveSyncTimer=null;
  conversationLiveSyncBusy=false;
  if(gmTurnCountdownTimer)clearInterval(gmTurnCountdownTimer);
  gmTurnCountdownTimer=null;
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
  gmTurnState=normalizeGmTurnState(state);
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
    return true;
  } catch(error) {
    document.querySelector('#gmError').textContent=error.message;
    return false;
  } finally {
    gmTurnAcquirePending=false;
    updateGmTurnUi();
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
    `<p>Travel to <b>${escapeHtml(location.name)}</b>?</p><p class="muted">The AI Game Master will resolve the journey and any encounter, obstacle, weather, or event that happens before arrival.</p>`,
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

function renderGameMasterTab() {
  const existingInput=document.querySelector('#gmInput');
  if(existingInput)gmTurnDraft=existingInput.value;

  const view=document.querySelector('#gameView');
  view.innerHTML=`<div class="gm-layout"><div><div class="view-heading"><h3>AI Game Master</h3><button id="refreshGm" class="button small">Refresh</button></div><div id="gmTimeline" class="timeline">${timelineHtml(currentGameData.gmMessages,'Your adventure begins when you speak to the Game Master.')}</div><div id="combatInitiativeStatus" class="combat-initiative-status" hidden></div><div id="gmTurnStatus" class="gm-turn-status checking"><span>Checking shared GM turn...</span></div><div class="composer gm-combat-composer"><textarea id="gmInput" class="input" placeholder="What do you do?" disabled></textarea><button id="sendGm" class="button primary" disabled>Send</button><button id="endCombatTurn" class="button end-turn" hidden disabled>End Turn</button><button id="resumeEnemyTurns" class="button resume-enemy-turn" hidden disabled>Resume GM Turn</button></div><div id="gmError" class="error"></div></div><aside class="side-card"><h4>${escapeHtml(currentGameData.character.characterName)}</h4><p>Level ${currentGameData.character.level} ${escapeHtml(currentGameData.character.speciesName)} ${escapeHtml(currentGameData.character.className)}</p><p>HP <b data-live-self-hp>${currentGameData.character.currentHp}/${currentGameData.character.maxHp}</b> • AC ${currentGameData.character.armorClass}</p>${currentGameData.openAiConfigured?'<span class="good">OpenAI Ready</span>':'<span class="warn">OpenAI key needed in Settings</span>'}<p class="muted"><b>GM-Controlled Dice:</b> All checks, attacks, saves, damage, and random rolls are generated by the RabuShin server. Player-supplied roll results are ignored.</p></aside></div>`;

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
    if(input.value.trim()&&(!gmTurnState?.active||(!gmTurnState.isOwner&&currentGmTurnSeconds()<=0)))
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
  if(data.size)extras.push(`Size: ${data.size}`);
  if(data.natureIntuitionSkill)extras.push(`Nature's Intuition: ${data.natureIntuitionSkill}`);
  if(data.extraLanguage)extras.push(`Language: ${data.extraLanguage}`);
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
    <div class="inventory-layout">
      <section class="inventory-list-panel">
        ${items.length?items.map(i=>`
          <button class="inventory-list-item ${i.inventoryItemId===selectedInventoryId?'selected':''}" data-id="${i.inventoryItemId}">
            <span><b>${escapeHtml(i.itemName)}</b><small>${escapeHtml(i.rarity||'Common')} • ${escapeHtml(i.valuationCategory||i.itemType||'Item')}${i.equipped?' • Equipped':''}</small></span>
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
  const drop=document.querySelector('#inventoryDrop');if(drop)drop.onclick=()=>showDropInventoryDialog(selected);
}

function inventoryDetailHtml(item) {
  const meta=[item.rarity||'Common',item.valuationCategory||item.itemType||'Item',item.equipmentSlot?`Slot: ${item.equipmentSlot}`:'',`Quantity: ${item.quantity}`,item.equipped?'Equipped':''].filter(Boolean).join(' • ');
  const valueText=item.priceless?'Priceless':formatShopGp(item.baseValueGp||0);
  const resaleText=item.sellable&&!item.priceless?formatShopGp(item.standardSellValueGp||0):'Not normally sellable';
  return `
    <div class="inventory-detail-heading"><div><h4>${escapeHtml(item.itemName)}</h4><p>${escapeHtml(meta)}</p></div>${item.equipped?'<span class="badge">EQUIPPED</span>':''}</div>
    <div class="inventory-value-card"><div><small>RARITY</small><b>${escapeHtml(item.rarity||'Common')}</b></div><div><small>BASE VALUE</small><b>${valueText}</b></div><div><small>TYPICAL SHOP OFFER</small><b>${resaleText}</b></div></div>
    ${item.priceBand?`<p class="muted inventory-price-band">${escapeHtml(item.priceBand)}</p>`:''}
    <div class="inventory-description">${escapeHtml(item.description||'No description is available for this item.').replaceAll('\n','<br>')}</div>
    ${item.rulesSummary?`<div class="inventory-rules"><b>Equipment Details</b><div>${escapeHtml(item.rulesSummary).replaceAll('\n','<br>')}</div></div>`:''}
    ${item.notes?`<div class="inventory-notes"><b>Notes:</b> ${escapeHtml(item.notes)}</div>`:''}
    <div class="inventory-actions">
      ${item.canEquip?`<button id="inventoryEquip" class="button primary">${item.equipped?'Unequip':'Equip'}</button>`:''}
      ${item.canUse?'<button id="inventoryUse" class="button primary">Use</button>':''}
      <button id="inventoryDrop" class="button danger-button">Drop</button>
    </div>
    ${!item.canEquip&&!item.canUse?'<p class="muted inventory-action-note">This item can be carried or dropped, but it is not wearable/wieldable equipment or a consumable.</p>':''}`;
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
  document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Campaign Chat</h3><button id="refreshChat" class="button small">Refresh</button></div><div id="chatTimeline" class="timeline chat">${timelineHtml(currentGameData.chatMessages,'No campaign chat messages yet.')}</div><div class="composer"><input id="chatInput" class="input" placeholder="Message the party"><button id="sendChat" class="button primary">Send</button></div><div id="chatError" class="error"></div>`;
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
  startChatLiveSync();
}
async function refreshChat(){await refreshChatLive(true);}

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
  document.querySelector('#openOpenAiKeys').onclick=()=>openExternal('https://platform.openai.com/api-keys');
  document.querySelectorAll('[data-settings-link]').forEach(button=>button.onclick=()=>openExternal(legalUrls[button.dataset.settingsLink]));
}

shell('<section class="panel loading"><h2>Loading RabuShin</h2><p>Connecting to Discord...</p></section>');
checkServer();
setupDiscord();
