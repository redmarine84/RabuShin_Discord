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

async function showCharacterCreator(campaignId) {
  const main = document.querySelector('#mainContent');
  main.innerHTML = `
    <div class="creator">
      <div class="section-title"><div><h2>Create Your Character</h2><p>One character per player in this campaign.</p></div><button id="creatorBack" class="button">Back</button></div>
      <div class="tabs"><button id="randomTab" class="tab active">Random Build</button><button id="manualTab" class="tab">Manual Sheet</button></div>
      <section class="panel creator-panel">
        <div id="creatorLoading" class="loading">Loading character options...</div>
        <div id="randomCreator" hidden>
          <h3>Random Build</h3><p>Choose species and class. RabuShin generates the rest using the VB.NET game rules.</p>
          <label>Character Name</label><input id="randomName" class="input" placeholder="Leave blank for a generated name">
          <div class="form-grid"><div><label>Species / Race</label><select id="randomSpecies" class="input"></select></div><div><label>Class</label><select id="randomClass" class="input"></select></div></div>
          <button id="randomCreate" class="button primary wide">Generate Character</button>
        </div>
        <div id="manualCreator" hidden>
          <h3>Manual Sheet</h3>
          <div class="form-grid">
            <div><label>Name</label><input id="manualName" class="input"></div>
            <div><label>Level</label><input id="manualLevel" class="input" type="number" min="1" max="20" value="1"></div>
            <div><label>Species / Race</label><select id="manualSpecies" class="input"></select></div>
            <div id="halfBox" hidden><label>Other Half</label><select id="manualHalf" class="input"></select></div>
            <div><label>Class</label><select id="manualClass" class="input"></select></div>
            <div><label>Background</label><select id="manualBackground" class="input"></select></div>
            <div><label>Alignment</label><select id="manualAlignment" class="input"></select></div>
          </div>
          <h4 class="subhead">Ability Scores</h4>
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
    document.querySelector('#randomSpecies').value = 'Human'; document.querySelector('#randomClass').value = 'Fighter';
    document.querySelector('#manualSpecies').value = 'Human'; document.querySelector('#manualClass').value = 'Fighter';
    if (data.backgrounds.includes('Soldier')) document.querySelector('#manualBackground').value = 'Soldier';
    if (data.alignments.includes('Neutral')) document.querySelector('#manualAlignment').value = 'Neutral';
    document.querySelector('#creatorLoading').hidden = true; document.querySelector('#randomCreator').hidden = false;

    const randomTab = document.querySelector('#randomTab'), manualTab = document.querySelector('#manualTab');
    randomTab.onclick = () => { randomTab.classList.add('active'); manualTab.classList.remove('active'); document.querySelector('#randomCreator').hidden=false; document.querySelector('#manualCreator').hidden=true; };
    manualTab.onclick = () => { manualTab.classList.add('active'); randomTab.classList.remove('active'); document.querySelector('#manualCreator').hidden=false; document.querySelector('#randomCreator').hidden=true; };

    const manualSpecies = document.querySelector('#manualSpecies');
    const updateHalf = () => {
      const halfBox = document.querySelector('#halfBox');
      if (manualSpecies.value.startsWith('Half ')) {
        const primary = manualSpecies.value.substring(5);
        const choices = data.baseSpecies.filter(v => v.toLowerCase() !== primary.toLowerCase());
        document.querySelector('#manualHalf').innerHTML = choices.map(v=>`<option>${escapeHtml(v)}</option>`).join('');
        halfBox.hidden=false;
      } else { halfBox.hidden=true; document.querySelector('#manualHalf').innerHTML=''; }
    };
    manualSpecies.onchange = updateHalf; updateHalf();

    document.querySelector('#randomCreate').onclick = async () => {
      const btn=document.querySelector('#randomCreate'); btn.disabled=true; btn.textContent='Generating...';
      try {
        const result=await api(`/game-api/campaigns/${campaignId}/characters/random`,{method:'POST',body:JSON.stringify({characterName:document.querySelector('#randomName').value.trim(),species:document.querySelector('#randomSpecies').value,className:document.querySelector('#randomClass').value})});
        await showStartingEquipment(campaignId,result.character);
      } catch(error){ document.querySelector('#creatorError').textContent=error.message; btn.disabled=false; btn.textContent='Generate Character'; }
    };

    document.querySelector('#manualCreate').onclick = async () => {
      const score = id => Math.max(1,Math.min(20,Number(document.querySelector(id).value)||10));
      const name=document.querySelector('#manualName').value.trim(); if(!name){document.querySelector('#creatorError').textContent='Character name is required.';return;}
      const btn=document.querySelector('#manualCreate');btn.disabled=true;btn.textContent='Creating...';
      try {
        const species=manualSpecies.value;
        const result=await api(`/game-api/campaigns/${campaignId}/characters/manual`,{method:'POST',body:JSON.stringify({
          characterName:name,species,secondaryHeritage:species.startsWith('Half ')?document.querySelector('#manualHalf').value:'',className:document.querySelector('#manualClass').value,
          background:document.querySelector('#manualBackground').value,alignment:document.querySelector('#manualAlignment').value,level:Number(document.querySelector('#manualLevel').value)||1,
          strength:score('#mStr'),dexterity:score('#mDex'),constitution:score('#mCon'),intelligence:score('#mInt'),wisdom:score('#mWis'),charisma:score('#mCha'),
          appearance:document.querySelector('#mAppearance').value.trim(),personality:document.querySelector('#mPersonality').value.trim(),backstory:document.querySelector('#mBackstory').value.trim(),notes:document.querySelector('#mNotes').value.trim()
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

async function showSpellSelection(campaignId, character) {
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
    document.querySelector('#saveSpells').onclick=async()=>{
      const cantrips=[...document.querySelectorAll('.cantrip-check:checked')].map(x=>x.value),spells=[...document.querySelectorAll('.spell-check:checked')].map(x=>x.value),preparedWizardSpells=[...document.querySelectorAll('.prepare-check:checked')].map(x=>x.value),mysticArcanum={};
      document.querySelectorAll('.arcanum').forEach(x=>mysticArcanum[x.dataset.level]=x.value);
      const btn=document.querySelector('#saveSpells');btn.disabled=true;btn.textContent='Saving Spells...';
      try{await api(`/game-api/campaigns/${campaignId}/spell-selection`,{method:'POST',body:JSON.stringify({cantrips,spells,preparedWizardSpells,mysticArcanum})});showNotice('Spell selection saved.');await enterCampaign(campaignId);}catch(error){document.querySelector('#spellError').textContent=error.message;btn.disabled=false;btn.textContent='Save Spell Selection';}
    };
  }catch(error){document.querySelector('#spellLoading').textContent='Unable to load spell selection.';document.querySelector('#spellError').textContent=error.message;}
}

async function enterCampaign(campaignId) {
  try {
    currentCampaignId=campaignId;
    currentGameData=await api(`/game-api/campaigns/${campaignId}/bootstrap`);
    renderGameShell();
    renderGameMasterTab();
  } catch(error){showNotice(error.message,true);}
}

function renderGameShell() {
  const d=currentGameData,c=d.campaign,ch=d.character,main=document.querySelector('#mainContent');
  main.innerHTML=`<div class="game">
    <div class="game-header"><div><button id="backLauncher" class="button small">← Campaigns</button><h2>${escapeHtml(c.campaignName)}</h2><p>Chapter ${c.currentChapter} • <span id="gameCurrentLocation">${escapeHtml(c.currentLocation)}</span> • ${escapeHtml(ch.characterName)}</p></div><div class="quick-vitals"><span>HP <b>${ch.currentHp}/${ch.maxHp}</b></span><span>AC <b>${ch.armorClass}</b></span><span>GP <b>${ch.gold}</b></span></div></div>
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
  document.querySelectorAll('.game-tab').forEach(b=>b.classList.remove('active'));button?.classList.add('active');
  if(tab==='combat'){renderCombatTab();return;}
  ({gm:renderGameMasterTab,character:renderCharacterTab,inventory:renderInventoryTab,spells:renderSpellbookTab,journal:renderJournalTab,chat:renderChatTab,settings:renderSettingsTab}[tab]||renderGameMasterTab)();
}

function timelineDisplayText(value) {
  return String(value ?? '').replace(/^\[WORLD MAP TRAVEL REQUEST\]\s*/i, '');
}
function timelineHtml(messages, emptyText='No messages yet.') {
  if(!messages?.length)return `<div class="empty small">${escapeHtml(emptyText)}</div>`;
  return messages.map(m=>`<div class="message ${m.roleName==='assistant'?'assistant':'user'}"><div class="message-name">${escapeHtml(m.senderName||m.roleName)}</div><div>${escapeHtml(timelineDisplayText(m.messageText)).replaceAll('\n','<br>')}</div></div>`).join('');
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
  overlay.innerHTML=`<div class="local-map-modal">
    <div class="local-map-header">
      <div><h2>${escapeHtml(map.name)}</h2><p>Current location: <b>${escapeHtml(currentLocation||'Unknown')}</b></p>${reason}</div>
      <button id="closeLocalMap" class="modal-close" aria-label="Close">×</button>
    </div>
    <div class="local-map-toolbar">
      <button id="localMapZoomOut" class="button small">−</button>
      <span id="localMapZoomLabel">100%</span>
      <button id="localMapZoomIn" class="button small">+</button>
      <button id="localMapFit" class="button small">Fit to Screen</button>
    </div>
    <div id="localMapViewport" class="local-map-viewport">
      <img id="localMapImage" class="local-map-image" src="${escapeHtml(map.imageUrl)}" width="${Number(map.imageWidth)||''}" height="${Number(map.imageHeight)||''}" alt="${escapeHtml(map.name)}">
    </div>
  </div>`;
  document.body.appendChild(overlay);
  const image=overlay.querySelector('#localMapImage');
  const label=overlay.querySelector('#localMapZoomLabel');
  let zoom=1;
  const applyZoom=()=>{
    image.style.width=`${Math.round(zoom*100)}%`;
    image.style.height='auto';
    label.textContent=`${Math.round(zoom*100)}%`;
  };
  overlay.querySelector('#localMapZoomOut').onclick=()=>{zoom=Math.max(.5,Math.round((zoom-.25)*100)/100);applyZoom();};
  overlay.querySelector('#localMapZoomIn').onclick=()=>{zoom=Math.min(3,Math.round((zoom+.25)*100)/100);applyZoom();};
  overlay.querySelector('#localMapFit').onclick=()=>{zoom=1;applyZoom();overlay.querySelector('#localMapViewport').scrollTo(0,0);};
  overlay.querySelector('#closeLocalMap').onclick=()=>overlay.remove();
  overlay.addEventListener('click',event=>{if(event.target===overlay)overlay.remove();});
  applyZoom();
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
    const encounter=document.querySelector('#combatEncounterMap'); if(encounter)encounter.onclick=()=>openCampaignLocalMap('encounter');
    document.querySelectorAll('.combat-monster-image').forEach(img=>{if(img.tagName!=='IMG')return;img.onerror=()=>{img.hidden=true;const fb=img.parentElement?.querySelector('.monster-image-fallback');if(fb)fb.hidden=false;};});
    document.querySelectorAll('.combat-monster-card').forEach(card=>card.onclick=()=>{const monster=monsters.find(m=>String(m.combatMonsterId)===card.dataset.monsterId);if(monster)showMonsterStatViewer(monster);});
  } catch(error) {
      view.innerHTML =`<div class="view-heading"><h3>\u2694 Combat</h3></div><div class="error">Unable to load Combat: ${escapeHtml(error.message)}</div>`;
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
  const view=document.querySelector('#gameView');
  view.innerHTML=`<div class="gm-layout"><div><div class="view-heading"><h3>AI Game Master</h3><button id="refreshGm" class="button small">Refresh</button></div><div id="gmTimeline" class="timeline">${timelineHtml(currentGameData.gmMessages,'Your adventure begins when you speak to the Game Master.')}</div><div class="composer"><textarea id="gmInput" class="input" placeholder="What do you do?"></textarea><button id="sendGm" class="button primary">Send</button></div><div id="gmError" class="error"></div></div><aside class="side-card"><h4>${escapeHtml(currentGameData.character.characterName)}</h4><p>Level ${currentGameData.character.level} ${escapeHtml(currentGameData.character.speciesName)} ${escapeHtml(currentGameData.character.className)}</p><p>HP ${currentGameData.character.currentHp}/${currentGameData.character.maxHp} • AC ${currentGameData.character.armorClass}</p>${currentGameData.openAiConfigured?'<span class="good">OpenAI Ready</span>':'<span class="warn">OpenAI key needed in Settings</span>'}<p class="muted"><b>GM-Controlled Dice:</b> All checks, attacks, saves, damage, and random rolls are generated by the RabuShin server. Player-supplied roll results are ignored.</p></aside></div>`;
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
  document.querySelector('#refreshGm').onclick=async()=>{const d=await api(`/game-api/campaigns/${currentCampaignId}/gm`);currentGameData.gmMessages=d.messages;renderGameMasterTab();};
  document.querySelector('#sendGm').onclick=async()=>{
    const input=document.querySelector('#gmInput'),message=input.value.trim();if(!message)return;
    const btn=document.querySelector('#sendGm');btn.disabled=true;btn.textContent='GM is thinking...';document.querySelector('#gmError').textContent='';
      try { await api(`/game-api/campaigns/${currentCampaignId}/gm`, { method: 'POST', body: JSON.stringify({ message }) }); input.value = ''; const d = await api(`/game-api/campaigns/${currentCampaignId}/gm`); currentGameData.gmMessages = d.messages; try { const inv = await api(`/game-api/campaigns/${currentCampaignId}/inventory`); currentGameData.inventory = inv.inventory || []; if (inv.gold !== undefined) currentGameData.character.gold = inv.gold; } catch (refreshError) { console.warn('Inventory refresh after GM turn failed:', refreshError); } await refreshWorldMapCampaignLocation(); renderGameMasterTab(); } catch (error) { document.querySelector('#gmError').textContent = error.message; if (error.data?.needsApiKey) showNotice('Open Settings and enter your OpenAI API key.', true); btn.disabled = false; btn.textContent = 'Send'; }
  };
 scrollGmToBottom();
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
        <div class="vitals party-detail-vitals"><div>HP <b>${member.currentHp}/${member.maxHp}</b></div><div>AC <b>${member.armorClass}</b></div><div>Initiative <b>${formatSigned(member.initiative)}</b></div><div>Speed <b>${member.speed} ft.</b></div><div>Passive Perception <b>${member.passivePerception}</b></div><div>Proficiency <b>${formatSigned(member.proficiencyBonus)}</b></div></div>
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
function renderCharacterTab(){
  const c=currentGameData.character,party=currentGameData.party||[],view=document.querySelector('#gameView');
  const self=party.find(p=>p.characterId===c.characterId);
  const hasPortrait=Boolean(c.hasPortrait||self?.hasPortrait);
  view.innerHTML=`<div class="view-heading"><div><h3>Character Sheet & Party</h3><p class="muted">Add your portrait, then click any party member to view their character card.</p></div><button id="refreshParty" class="button small">Refresh Party</button></div>
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
            <div class="vitals"><div>HP <b>${c.currentHp}/${c.maxHp}</b></div><div>AC <b>${c.armorClass}</b></div><div>Initiative <b>${formatSigned(c.initiative)}</b></div><div>Speed <b>${c.speed} ft.</b></div><div>Passive Perception <b>${c.passivePerception}</b></div><div>Proficiency <b>${formatSigned(c.proficiencyBonus)}</b></div></div>
            <div class="stats">${statBox('STR',c.strength)}${statBox('DEX',c.dexterity)}${statBox('CON',c.constitution)}${statBox('INT',c.intelligence)}${statBox('WIS',c.wisdom)}${statBox('CHA',c.charisma)}</div>
          </div>
        </div>
      </section>
      <section class="panel party-panel"><h3>Campaign Party</h3><p class="muted">Select a character to view their portrait and current public combat stats.</p>
        <div class="party-list visual-party-list">${party.length?party.map((p,index)=>`<button class="party-card visual-party-card" data-party-index="${index}">
          ${portraitFrameHtml(p.characterId,p.characterName,p.hasPortrait,'party-thumbnail')}
          <div class="party-card-copy"><b>${escapeHtml(p.characterName)}</b><small>${escapeHtml(p.displayName)} • Level ${p.level} ${escapeHtml(p.speciesName)} ${escapeHtml(p.className)}</small><span>HP ${p.currentHp}/${p.maxHp} • AC ${p.armorClass}</span></div><span class="party-view-hint">View →</span>
        </button>`).join(''):'<div class="empty small">No characters are in this campaign yet.</div>'}</div>
      </section>
    </div>`;
  document.querySelector('#refreshParty').onclick=refreshPartyData;
  document.querySelector('#uploadPortrait').onclick=()=>document.querySelector('#portraitFile').click();
  document.querySelector('#portraitFile').onchange=e=>uploadCharacterPortrait(e.target.files?.[0]);
  const remove=document.querySelector('#removePortrait');if(remove)remove.onclick=removeCharacterPortrait;
  document.querySelectorAll('[data-party-index]').forEach(button=>button.onclick=()=>showPartyMemberDetails(party[Number(button.dataset.partyIndex)]));
  hydratePortraits(view);
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
    <div class="view-heading"><div><h3>Inventory</h3><p class="muted">Select an item to inspect it and see the actions it supports.</p></div><span>${currentGameData.character.gold} GP</span></div>
    <div class="inventory-layout">
      <section class="inventory-list-panel">
        ${items.length?items.map(i=>`
          <button class="inventory-list-item ${i.inventoryItemId===selectedInventoryId?'selected':''}" data-id="${i.inventoryItemId}">
            <span><b>${escapeHtml(i.itemName)}</b><small>${escapeHtml(i.itemType||'Item')}${i.equipped?' • Equipped':''}</small></span>
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
  const meta=[item.itemType||'Item',item.equipmentSlot?`Slot: ${item.equipmentSlot}`:'',`Quantity: ${item.quantity}`,item.equipped?'Equipped':''].filter(Boolean).join(' • ');
  return `
    <div class="inventory-detail-heading"><div><h4>${escapeHtml(item.itemName)}</h4><p>${escapeHtml(meta)}</p></div>${item.equipped?'<span class="badge">EQUIPPED</span>':''}</div>
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
  currentGameData.inventory=data.inventory||[];
  if(data.gold!==undefined)currentGameData.character.gold=data.gold;
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
  input.focus();
  const end=input.value.length;
  input.setSelectionRange?.(end,end);
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

function renderChatTab(){document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Campaign Chat</h3><button id="refreshChat" class="button small">Refresh</button></div><div id="chatTimeline" class="timeline chat">${timelineHtml(currentGameData.chatMessages,'No campaign chat messages yet.')}</div><div class="composer"><input id="chatInput" class="input" placeholder="Message the party"><button id="sendChat" class="button primary">Send</button></div><div id="chatError" class="error"></div>`;
  document.querySelector('#refreshChat').onclick=refreshChat;
  document.querySelector('#sendChat').onclick=async()=>{const input=document.querySelector('#chatInput'),message=input.value.trim();if(!message)return;try{await api(`/game-api/campaigns/${currentCampaignId}/chat`,{method:'POST',body:JSON.stringify({message})});input.value='';await refreshChat();}catch(e){document.querySelector('#chatError').textContent=e.message;}};
}
async function refreshChat(){const d=await api(`/game-api/campaigns/${currentCampaignId}/chat`);currentGameData.chatMessages=d.messages;renderChatTab();}

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
