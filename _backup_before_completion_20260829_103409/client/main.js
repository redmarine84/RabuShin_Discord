import { DiscordSDK } from '@discord/embedded-app-sdk';
import './style.css';

const discordSdk = new DiscordSDK(import.meta.env.VITE_DISCORD_CLIENT_ID);
let discordAuth = null;
let discordAccessToken = null;
let currentDiscordUser = null;
let currentCampaignId = null;
let currentGameData = null;

const app = document.querySelector('#app');

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
  if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
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
  currentCampaignId = null;
  currentGameData = null;
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
    </div>`;

  document.querySelector('#refreshCampaigns').onclick = loadCampaigns;
  document.querySelector('#newCampaign').onclick = showNewCampaignDialog;
  document.querySelector('#joinCampaign').onclick = showJoinCampaignDialog;
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
        <div class="row gap">${c.isOwner ? '<span class="badge">OWNER</span>' : ''}<button class="button play" data-id="${c.campaignId}">Play</button></div>
      </div>`).join('');
    document.querySelectorAll('.play').forEach(b => b.onclick = () => openCampaign(b.dataset.id));
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
    <div class="game-header"><div><button id="backLauncher" class="button small">← Campaigns</button><h2>${escapeHtml(c.campaignName)}</h2><p>Chapter ${c.currentChapter} • ${escapeHtml(c.currentLocation)} • ${escapeHtml(ch.characterName)}</p></div><div class="quick-vitals"><span>HP <b>${ch.currentHp}/${ch.maxHp}</b></span><span>AC <b>${ch.armorClass}</b></span><span>GP <b>${ch.gold}</b></span></div></div>
    <nav class="game-nav">
      <button class="game-tab active" data-tab="gm">AI Game Master</button><button class="game-tab" data-tab="character">Character</button><button class="game-tab" data-tab="inventory">Inventory</button><button class="game-tab" data-tab="spells">Spellbook</button><button class="game-tab" data-tab="journal">Journal</button><button class="game-tab" data-tab="chat">Campaign Chat</button><button class="game-tab" data-tab="dice">Dice</button><button class="game-tab" data-tab="settings">Settings</button>
    </nav><section id="gameView" class="game-view"></section></div>`;
  document.querySelector('#backLauncher').onclick=showCampaignLauncher;
  document.querySelectorAll('.game-tab').forEach(btn=>btn.onclick=()=>switchGameTab(btn.dataset.tab,btn));
}

function switchGameTab(tab,button) {
  document.querySelectorAll('.game-tab').forEach(b=>b.classList.remove('active'));button?.classList.add('active');
  ({gm:renderGameMasterTab,character:renderCharacterTab,inventory:renderInventoryTab,spells:renderSpellbookTab,journal:renderJournalTab,chat:renderChatTab,dice:renderDiceTab,settings:renderSettingsTab}[tab]||renderGameMasterTab)();
}

function timelineHtml(messages, emptyText='No messages yet.') {
  if(!messages?.length)return `<div class="empty small">${escapeHtml(emptyText)}</div>`;
  return messages.map(m=>`<div class="message ${m.roleName==='assistant'?'assistant':'user'}"><div class="message-name">${escapeHtml(m.senderName||m.roleName)}</div><div>${escapeHtml(m.messageText).replaceAll('\n','<br>')}</div></div>`).join('');
}

function renderGameMasterTab() {
  const view=document.querySelector('#gameView');
  view.innerHTML=`<div class="gm-layout"><div><div class="view-heading"><h3>AI Game Master</h3><button id="refreshGm" class="button small">Refresh</button></div><div id="gmTimeline" class="timeline">${timelineHtml(currentGameData.gmMessages,'Your adventure begins when you speak to the Game Master.')}</div><div class="composer"><textarea id="gmInput" class="input" placeholder="What do you do?"></textarea><button id="sendGm" class="button primary">Send</button></div><div id="gmError" class="error"></div></div><aside class="side-card"><h4>${escapeHtml(currentGameData.character.characterName)}</h4><p>Level ${currentGameData.character.level} ${escapeHtml(currentGameData.character.speciesName)} ${escapeHtml(currentGameData.character.className)}</p><p>HP ${currentGameData.character.currentHp}/${currentGameData.character.maxHp} • AC ${currentGameData.character.armorClass}</p>${currentGameData.openAiConfigured?'<span class="good">OpenAI Ready</span>':'<span class="warn">OpenAI key needed in Settings</span>'}</aside></div>`;
  document.querySelector('#refreshGm').onclick=async()=>{const d=await api(`/game-api/campaigns/${currentCampaignId}/gm`);currentGameData.gmMessages=d.messages;renderGameMasterTab();};
  document.querySelector('#sendGm').onclick=async()=>{
    const input=document.querySelector('#gmInput'),message=input.value.trim();if(!message)return;
    const btn=document.querySelector('#sendGm');btn.disabled=true;btn.textContent='GM is thinking...';document.querySelector('#gmError').textContent='';
    try{await api(`/game-api/campaigns/${currentCampaignId}/gm`,{method:'POST',body:JSON.stringify({message})});input.value='';const d=await api(`/game-api/campaigns/${currentCampaignId}/gm`);currentGameData.gmMessages=d.messages;renderGameMasterTab();const tl=document.querySelector('#gmTimeline');tl.scrollTop=tl.scrollHeight;}catch(error){document.querySelector('#gmError').textContent=error.message;if(error.data?.needsApiKey)showNotice('Open Settings and enter your OpenAI API key.',true);btn.disabled=false;btn.textContent='Send';}
  };
}

function statBox(name,score){return `<div class="stat"><span>${name}</span><b>${score}</b><small>${formatSigned(abilityMod(score))}</small></div>`;}
function renderCharacterTab(){const c=currentGameData.character,party=currentGameData.party||[];document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Character Sheet & Party</h3></div><div class="character-grid"><section class="panel"><h2>${escapeHtml(c.characterName)}</h2><p>Level ${c.level} ${escapeHtml(c.speciesName)} ${escapeHtml(c.className)} • ${escapeHtml(c.backgroundName)} • ${escapeHtml(c.alignment)}</p><div class="vitals"><div>HP <b>${c.currentHp}/${c.maxHp}</b></div><div>AC <b>${c.armorClass}</b></div><div>Initiative <b>${formatSigned(c.initiative)}</b></div><div>Speed <b>${c.speed} ft.</b></div><div>Passive Perception <b>${c.passivePerception}</b></div><div>Proficiency <b>${formatSigned(c.proficiencyBonus)}</b></div></div><div class="stats">${statBox('STR',c.strength)}${statBox('DEX',c.dexterity)}${statBox('CON',c.constitution)}${statBox('INT',c.intelligence)}${statBox('WIS',c.wisdom)}${statBox('CHA',c.charisma)}</div></section><section class="panel"><h3>Campaign Party</h3><div class="party-list">${party.length?party.map(p=>`<div class="party-card"><div><b>${escapeHtml(p.characterName)}</b><small>${escapeHtml(p.displayName)} • Level ${p.level} ${escapeHtml(p.speciesName)} ${escapeHtml(p.className)}</small></div><span>HP ${p.currentHp}/${p.maxHp} • AC ${p.armorClass}</span></div>`).join(''):'<div class="empty small">No other characters yet.</div>'}</div></section></div>`;}

function renderInventoryTab(){const items=currentGameData.inventory||[];document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Inventory</h3><span>${currentGameData.character.gold} GP</span></div><div class="table"><div class="table-head"><span>Item</span><span>Qty</span><span>Status</span><span>Source</span></div>${items.length?items.map(i=>`<div class="table-row"><span><b>${escapeHtml(i.itemName)}</b><small>${escapeHtml(i.notes||'')}</small></span><span>${i.quantity}</span><span>${i.equipped?'Equipped':''}${i.attuned?' Attuned':''}</span><span>${escapeHtml(i.sourceName||'')}</span></div>`).join(''):'<div class="empty small">No inventory items.</div>'}</div>`;}

function renderSpellbookTab(){const spells=currentGameData.spells||[],slots=currentGameData.spellSlots||[];document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Spellbook</h3></div>${slots.length?`<div class="slot-row">${slots.map(s=>`<span>Level ${s.spellLevel}: <b>${Math.max(0,s.maxSlots-s.usedSlots)}/${s.maxSlots}</b></span>`).join('')}</div>`:''}<div class="spellbook-list">${spells.length?spells.map(s=>{const d=s.spellData||{};return `<div class="spell-card"><h4>${escapeHtml(s.spellName)} <small>${s.spellLevel===0?'Cantrip':`Level ${s.spellLevel}`}</small></h4><p>${s.prepared?'Prepared • ':''}${escapeHtml(d.casting_time||'')} ${escapeHtml(d.range||'')}</p><div>${escapeHtml(d.description||'')}</div></div>`;}).join(''):'<div class="empty small">This character has no class spells.</div>'}</div>`;}

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

function renderDiceTab(){document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Dice Roller</h3></div><div class="dice-panel"><div class="dice-buttons">${[4,6,8,10,12,20,100].map(s=>`<button class="die button" data-sides="${s}">d${s}</button>`).join('')}</div><div class="row gap"><button id="adv" class="button">d20 Advantage</button><button id="dis" class="button">d20 Disadvantage</button></div><div id="diceResult" class="dice-result">Choose a die.</div></div>`;
  const roll=async(sides,advantage=false,disadvantage=false)=>{try{const d=await api('/game-api/dice/roll',{method:'POST',body:JSON.stringify({count:1,sides,modifier:0,advantage,disadvantage})});document.querySelector('#diceResult').textContent=`${d.mode}: ${d.rolls.join(', ')} → ${d.total}`;}catch(e){document.querySelector('#diceResult').textContent=e.message;}};
  document.querySelectorAll('.die').forEach(b=>b.onclick=()=>roll(Number(b.dataset.sides)));document.querySelector('#adv').onclick=()=>roll(20,true,false);document.querySelector('#dis').onclick=()=>roll(20,false,true);
}

function renderSettingsTab(){document.querySelector('#gameView').innerHTML=`<div class="view-heading"><h3>Settings</h3></div><section class="panel settings"><h4>OpenAI API Key</h4><p>${currentGameData.openAiConfigured?'An API key is configured.':'No API key is configured.'}</p><p class="muted">A key entered here is kept only in the ASP.NET server memory for this run and is never saved to Supabase or the browser. For a permanent server key, use the setup instructions and .NET User Secrets.</p><input id="apiKeyInput" class="input mono" type="password" placeholder="sk-..."><div class="row gap"><button id="saveApiKey" class="button primary">Use This API Key</button><button id="clearApiKey" class="button">Clear Session Key</button></div><div id="settingsError" class="error"></div></section>`;
  document.querySelector('#saveApiKey').onclick=async()=>{const key=document.querySelector('#apiKeyInput').value.trim();if(!key)return;try{await api('/game-api/settings/openai',{method:'POST',body:JSON.stringify({apiKey:key})});document.querySelector('#apiKeyInput').value='';currentGameData.openAiConfigured=true;showNotice('OpenAI API key accepted for this server session.');renderSettingsTab();}catch(e){document.querySelector('#settingsError').textContent=e.message;}};
  document.querySelector('#clearApiKey').onclick=async()=>{try{await api('/game-api/settings/openai',{method:'DELETE'});currentGameData.openAiConfigured=false;showNotice('Session API key cleared.');renderSettingsTab();}catch(e){document.querySelector('#settingsError').textContent=e.message;}};
}

shell('<section class="panel loading"><h2>Loading RabuShin</h2><p>Connecting to Discord...</p></section>');
checkServer();
setupDiscord();
