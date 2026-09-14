import './multiclassing.css';

// RabuShinAIGM Build 6.30.12 - Multiclassing client integration.
// This module is intentionally side-effect based so the existing main.js API
// remains stable. main.js exposes a very small context object used below.

const MC_CLASSES = [
  'Artificer','Barbarian','Bard','Cleric','Druid','Fighter','Monk',
  'Paladin','Ranger','Rogue','Sorcerer','Warlock','Wizard'
];
const MC_REQUIREMENTS = {
  Artificer:'INT 13 (RabuShin extension)', Barbarian:'STR 13', Bard:'CHA 13', Cleric:'WIS 13', Druid:'WIS 13',
  Fighter:'STR 13 or DEX 13', Monk:'DEX 13 and WIS 13', Paladin:'STR 13 and CHA 13', Ranger:'DEX 13 and WIS 13',
  Rogue:'DEX 13', Sorcerer:'CHA 13', Warlock:'CHA 13', Wizard:'INT 13'
};

let ctx = null;
let observer = null;
let lastOverlay = null;
let levelState = null;
let levelPlan = null;
let levelPreview = null;
let applyBusy = false;
let rules = null;

function getCtx() {
  return window.__rabuMulticlassContext || null;
}
function esc(value) {
  const fn = ctx?.escapeHtml;
  return fn ? fn(value) : String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[ch]));
}
function campaignId() { return ctx?.getCampaignId?.() || null; }
function progression() { return ctx?.getProgression?.() || null; }
function gameData() { return ctx?.getGameData?.() || null; }
function api(path, options={}) {
  if (!ctx?.api) return Promise.reject(new Error('Multiclassing is waiting for the game API context.'));
  return ctx.api(path, options);
}
function notice(message, danger=false) { ctx?.showNotice?.(message, danger); }

function abilityValue(root, names) {
  for (const name of names) {
    const exact = root.querySelector(`#${CSS.escape(name)}`);
    if (exact && Number.isFinite(Number(exact.value))) return Number(exact.value);
  }
  const inputs = [...root.querySelectorAll('input,select')];
  for (const el of inputs) {
    const id = `${el.id} ${el.name} ${el.getAttribute('aria-label')||''}`.toLowerCase();
    if (names.some(n => id.includes(n.toLowerCase())) && Number.isFinite(Number(el.value))) return Number(el.value);
  }
  return null;
}
function localEligible(className, stats) {
  const s = stats.strength, d = stats.dexterity, i = stats.intelligence, w = stats.wisdom, c = stats.charisma;
  switch(className) {
    case 'Artificer': case 'Wizard': return i >= 13;
    case 'Barbarian': return s >= 13;
    case 'Bard': case 'Sorcerer': case 'Warlock': return c >= 13;
    case 'Cleric': case 'Druid': return w >= 13;
    case 'Fighter': return s >= 13 || d >= 13;
    case 'Monk': case 'Ranger': return d >= 13 && w >= 13;
    case 'Paladin': return s >= 13 && c >= 13;
    case 'Rogue': return d >= 13;
    default: return false;
  }
}

async function ensureRules() {
  if (rules) return rules;
  try {
    const data = await api('/game-api/multiclass/rules');
    rules = data.rules || null;
  } catch { rules = null; }
  return rules;
}

function requirementsMarkup(eligibility=null) {
  const list = MC_CLASSES.map(name => {
    const state = eligibility && Object.prototype.hasOwnProperty.call(eligibility,name) ? eligibility[name] : null;
    const badge = state === true ? '<span class="mc-ok">Eligible</span>' : state === false ? '<span class="mc-no">Not eligible</span>' : '';
    return `<div class="mc-requirement-row"><b>${esc(name)}</b><span>${esc(MC_REQUIREMENTS[name])}</span>${badge}</div>`;
  }).join('');
  return `<div class="mc-requirements">${list}</div>`;
}

function mountCreatorGuidance() {
  const random = document.querySelector('#randomCreator');
  const manual = document.querySelector('#manualCreator');
  [random, manual].forEach((root) => {
    if (!root || root.querySelector('.mc-creator-panel')) return;
    const panel = document.createElement('section');
    panel.className = 'mc-creator-panel';
    panel.innerHTML = `<div class="mc-creator-title"><b>Multiclassing / Requirements</b><button type="button" class="button mc-toggle">View</button></div>
      <p class="mc-muted">You begin at level 1 in one class. These requirements show which additional classes can become available when you gain a later character level.</p>
      <div class="mc-creator-body" hidden>${requirementsMarkup()}</div>`;
    root.appendChild(panel);
    const body = panel.querySelector('.mc-creator-body');
    const toggle = panel.querySelector('.mc-toggle');
    const refresh = () => {
      if (root !== manual) return;
      const stats = {
        strength:abilityValue(root,['manualStrength','strength']), dexterity:abilityValue(root,['manualDexterity','dexterity']),
        constitution:abilityValue(root,['manualConstitution','constitution']), intelligence:abilityValue(root,['manualIntelligence','intelligence']),
        wisdom:abilityValue(root,['manualWisdom','wisdom']), charisma:abilityValue(root,['manualCharisma','charisma'])
      };
      if (Object.values(stats).some(v => v === null)) return;
      const e = Object.fromEntries(MC_CLASSES.map(name => [name, localEligible(name,stats)]));
      body.innerHTML = requirementsMarkup(e);
    };
    toggle.onclick = async () => {
      body.hidden = !body.hidden;
      toggle.textContent = body.hidden ? 'View' : 'Hide';
      await ensureRules();
      refresh();
    };
    root.addEventListener('input', refresh);
    root.addEventListener('change', refresh);
  });
}

async function loadLevelState() {
  const id = campaignId();
  if (!id) throw new Error('No campaign is active.');
  const data = await api(`/game-api/campaigns/${id}/multiclass`);
  levelState = data.state;
  return levelState;
}
function optionMap(state) {
  const map = new Map();
  (Array.isArray(state?.options) ? state.options : []).forEach(o => map.set(String(o.className||''), o));
  return map;
}
function currentClassMap(state) {
  const map = new Map();
  (Array.isArray(state?.classes) ? state.classes : []).forEach(o => map.set(String(o.className||''), Number(o.level)||0));
  return map;
}
function defaultPlan(state) {
  const from = Number(state?.fromLevel)||Number(state?.totalLevel)||1;
  const to = Number(state?.toLevel)||from;
  const initial = String(state?.initialClass||'').trim();
  return Array.from({length:Math.max(0,to-from)}, (_,idx)=>({
    totalLevel:from+idx+1, className:initial, proficiencyChoices:{}
  }));
}

function classSelectOptions(state, selected) {
  const options = optionMap(state);
  const existing = currentClassMap(state);
  return MC_CLASSES.map(name => {
    const info = options.get(name) || {};
    const canChoose = existing.has(name) || info.eligible === true;
    const requirement = info.requirement || MC_REQUIREMENTS[name] || '';
    const suffix = canChoose ? `${existing.has(name)?` — current ${existing.get(name)}`:''}` : ` — requires ${requirement}`;
    return `<option value="${esc(name)}" ${name===selected?'selected':''} ${canChoose?'':'disabled'}>${esc(name+suffix)}</option>`;
  }).join('');
}

function proficiencyInputs(className, isNew, choices={}) {
  if (!isNew) return '';
  const skill = esc(choices.skill||'');
  const instrument = esc(choices.instrument||'');
  if (className === 'Bard') return `<div class="mc-proficiency-fields"><label>Granted Bard skill proficiency<input class="input mc-skill" value="${skill}" placeholder="One skill"></label><label>Granted musical instrument proficiency<input class="input mc-instrument" value="${instrument}" placeholder="One instrument"></label></div>`;
  if (className === 'Ranger') return `<div class="mc-proficiency-fields"><label>Granted Ranger skill proficiency<input class="input mc-skill" value="${skill}" placeholder="One Ranger class skill"></label></div>`;
  if (className === 'Rogue') return `<div class="mc-proficiency-fields"><label>Granted Rogue skill proficiency<input class="input mc-skill" value="${skill}" placeholder="One Rogue class skill"></label></div>`;
  return '';
}

function renderPlanner() {
  document.querySelector('#mcPlannerOverlay')?.remove();
  if (!levelState) return;
  if (!levelPlan) levelPlan = defaultPlan(levelState);
  const base = currentClassMap(levelState);
  const simulated = new Map(base);
  const rows = levelPlan.map((item,index) => {
    const prior = simulated.get(item.className)||0;
    const isNew = prior === 0;
    simulated.set(item.className, prior+1);
    return `<div class="mc-plan-row" data-mc-index="${index}">
      <div class="mc-plan-heading"><b>Total Level ${item.totalLevel}</b><small>Choose the class that gains this level.</small></div>
      <select class="input mc-class-select">${classSelectOptions(levelState,item.className)}</select>
      <div class="mc-proficiency-host">${proficiencyInputs(item.className,isNew,item.proficiencyChoices)}</div>
    </div>`;
  }).join('');
  const overlay = document.createElement('div');
  overlay.id = 'mcPlannerOverlay';
  overlay.className = 'mc-overlay';
  overlay.innerHTML = `<section class="mc-card">
    <div class="mc-card-header"><div><p class="eyebrow">D&D 5e Multiclassing</p><h2>Choose Class Levels</h2></div><button type="button" class="button mc-close">Close</button></div>
    <div class="mc-current"><b>Current:</b> ${esc(levelState.summary||'')}</div>
    <p class="mc-muted">A new class is available only when you meet both your initial class prerequisite and the new class prerequisite. Continuing a class you already have is always allowed.</p>
    ${rows || '<p>No character levels are waiting to be assigned.</p>'}
    <div id="mcPlannerError" class="error"></div>
    <div class="mc-actions"><button type="button" class="button" id="mcResetPlan">Continue Current Class</button><button type="button" class="button primary" id="mcPreviewPlan">Use This Plan</button></div>
  </section>`;
  document.body.appendChild(overlay);
  overlay.querySelector('.mc-close').onclick = () => overlay.remove();
  overlay.querySelector('#mcResetPlan').onclick = () => { levelPlan=defaultPlan(levelState); renderPlanner(); };
  overlay.querySelectorAll('.mc-plan-row').forEach(row => {
    const index = Number(row.dataset.mcIndex);
    const select = row.querySelector('.mc-class-select');
    select.onchange = () => {
      levelPlan[index].className = select.value;
      levelPlan[index].proficiencyChoices = {};
      renderPlanner();
    };
    const skill = row.querySelector('.mc-skill'); if(skill) skill.oninput=()=>levelPlan[index].proficiencyChoices.skill=skill.value;
    const instrument = row.querySelector('.mc-instrument'); if(instrument) instrument.oninput=()=>levelPlan[index].proficiencyChoices.instrument=instrument.value;
  });
  overlay.querySelector('#mcPreviewPlan').onclick = () => void previewPlan(overlay);
}

async function previewPlan(overlay) {
  const error = overlay.querySelector('#mcPlannerError');
  error.textContent='';
  try {
    const data = await api(`/game-api/campaigns/${campaignId()}/multiclass/preview`, {method:'POST',body:JSON.stringify({plan:levelPlan})});
    levelPreview = data.preview;
    applyPreviewPrompts(levelPreview);
    updateLevelSummary(levelPreview?.summary || levelState?.summary || '');
    overlay.remove();
    notice(`Level-up plan set: ${levelPreview?.summary || 'class levels selected'}.`);
  } catch (e) { error.textContent=e.message||String(e); }
}

function applyPreviewPrompts(preview) {
  const p = progression();
  const overlay = document.querySelector('#levelUpOverlay');
  if (!p || !overlay) return;
  const prompts = Array.isArray(preview?.prompts) ? preview.prompts.map(x=>({
    key:x.key ?? x.Key, label:x.label ?? x.Label, description:x.description ?? x.Description, optional:x.optional ?? x.Optional ?? false
  })) : [];
  p.prompts = prompts;
  overlay.querySelectorAll('.level-up-choice').forEach(el=>el.remove());
  const error = overlay.querySelector('#levelUpError');
  const host = error?.parentElement;
  if (!host) return;
  const fragment = document.createDocumentFragment();
  prompts.forEach(prompt => {
    const label = document.createElement('label');
    label.className='level-up-choice mc-injected-choice';
    label.innerHTML=`<span><b>${esc(prompt.label)}</b>${prompt.optional?'<em>Optional</em>':''}</span><small>${esc(prompt.description||'')}</small><textarea class="input level-up-choice-input" data-choice-key="${esc(prompt.key)}" rows="2" placeholder="${prompt.optional?'Leave blank if none':'Enter your choice'}"></textarea>`;
    fragment.appendChild(label);
  });
  host.insertBefore(fragment,error);
}
function updateLevelSummary(summary) {
  const host = document.querySelector('#levelUpOverlay .mc-level-summary');
  if (host) host.innerHTML = `<b>Class plan:</b> ${esc(summary)}`;
}

async function mountLevelUp() {
  const overlay = document.querySelector('#levelUpOverlay');
  if (!overlay || overlay.dataset.multiclassMounted==='1') return;
  overlay.dataset.multiclassMounted='1';
  lastOverlay=overlay;
  try {
    const state = await loadLevelState();
    if (!state?.pendingLevelUp) return;
    levelPlan=defaultPlan(state);
    levelPreview=null;
    const finish = overlay.querySelector('#finishLevelUpChoices');
    const error = overlay.querySelector('#levelUpError');
    if (!finish || !error) return;
    const controls=document.createElement('div');
    controls.className='mc-level-controls';
    controls.innerHTML=`<div class="mc-level-summary"><b>Class plan:</b> ${esc(state.summary||'')}</div><button type="button" class="button" id="mcOpenPlanner">Multiclass</button><small>Choose Multiclass to assign this gained level to another eligible class. If you do nothing, your initial class continues.</small>`;
    error.parentElement.insertBefore(controls,error);
    controls.querySelector('#mcOpenPlanner').onclick=()=>renderPlanner();

    const original = finish.onclick;
    finish.onclick = async (event) => {
      if (applyBusy) return;
      applyBusy=true;
      const oldText=finish.textContent;
      finish.disabled=true;
      finish.textContent='Applying Class Level...';
      try {
        const plan = levelPlan || defaultPlan(state);
        const data = await api(`/game-api/campaigns/${campaignId()}/multiclass/apply`,{method:'POST',body:JSON.stringify({plan})});
        const result=data.result||{};
        notice(`Class levels applied: ${result.summary||levelPreview?.summary||state.summary||''}`);
        finish.disabled=false;
        finish.textContent=oldText;
        if (typeof original === 'function') original.call(finish,event);
      } catch(e) {
        finish.disabled=false;finish.textContent=oldText;
        error.textContent=e.message||String(e);
      } finally { applyBusy=false; }
    };
  } catch(e) {
    console.error('Unable to mount multiclass level-up controls:',e);
    const error=overlay.querySelector('#levelUpError');
    if(error)error.textContent=`Multiclassing could not load: ${e.message||e}`;
  }
}

async function mountHitDice() {
  const roll=document.querySelector('#rollRestHitDie');
  if (!roll || roll.dataset.multiclassMounted==='1' || !campaignId()) return;
  try {
    const data=await api(`/game-api/campaigns/${campaignId()}/multiclass`);
    const pools=(data.state?.hitDice||[]).filter(p=>Number(p.availableDice)>0);
    if (!pools.length) return;
    roll.dataset.multiclassMounted='1';
    const box=document.createElement('label');
    box.className='mc-hit-die-picker';
    box.innerHTML=`<span>Hit Die to spend</span><select class="input">${pools.map(p=>`<option value="${Number(p.dieSides)}">${esc(p.className)} — d${Number(p.dieSides)} (${Number(p.availableDice)} available)</option>`).join('')}</select>`;
    roll.parentElement?.insertBefore(box,roll);
    const select=box.querySelector('select');
    roll.textContent=`Roll 1 d${Number(select.value)} Hit Die`;
    select.onchange=()=>roll.textContent=`Roll 1 d${Number(select.value)} Hit Die`;
    roll.onclick=async()=>{
      if(roll.disabled)return;
      roll.disabled=true;
      try {
        const result=await api(`/game-api/campaigns/${campaignId()}/multiclass/hit-die`,{method:'POST',body:JSON.stringify({dieSides:Number(select.value)})});
        const r=result.result||{};
        notice(`${r.className||'Class'} d${r.dieSides||select.value}: rolled ${r.roll||'?'}${Number(r.constitutionModifier)>=0?'+':''}${r.constitutionModifier||0}; healed ${r.healing||0} HP.`);
        // The existing rest poller will refresh the overlay and the remaining pools.
      }catch(e){notice(e.message||String(e),true);roll.disabled=false;}
    };
  } catch(e) { console.error('Unable to mount multiclass Hit Dice selector:',e); }
}

function boot() {
  ctx=getCtx();
  if (!ctx) { setTimeout(boot,100); return; }
  if (observer) return;
  observer=new MutationObserver(()=>{
    mountCreatorGuidance();
    void mountLevelUp();
    void mountHitDice();
  });
  observer.observe(document.documentElement,{childList:true,subtree:true});
  mountCreatorGuidance();
  void mountLevelUp();
  void mountHitDice();
}

boot();
