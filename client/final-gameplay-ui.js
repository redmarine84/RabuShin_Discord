import './final-gameplay.css';

const stateCache = new Map();
const equipmentSlots = [
  'armor','shield','main_hand','off_hand','ranged','ammunition','head','neck','hands','feet','ring_left','ring_right','accessory_1','accessory_2'
];

export async function mountFinalGameplayInventoryPanels(context) {
  const host = document.querySelector('#gameView');
  if (!host || !context?.campaignId) return;
  host.querySelector('#rsFinalGameplay')?.remove();
  const shell = document.createElement('div');
  shell.id = 'rsFinalGameplay';
  shell.className = 'rs-final-systems';
  shell.innerHTML = '<section class="rs-system-panel"><div class="rs-system-loading">Loading equipment, crafting, and tactical presets…</div></section>';
  host.prepend(shell);

  try {
    const requests = [
      context.api(`/game-api/campaigns/${context.campaignId}/equipment`),
      context.api(`/game-api/campaigns/${context.campaignId}/crafting`),
      context.api(`/game-api/campaigns/${context.campaignId}/harvesting`)
    ];
    if (context.isSolo) requests.push(context.api(`/game-api/campaigns/${context.campaignId}/formation`));
    const responses = await Promise.all(requests);
    const state = {
      equipment: responses[0]?.equipment || null,
      crafting: responses[1]?.crafting || null,
      harvesting: responses[2]?.harvesting || null,
      formation: context.isSolo ? (responses[3]?.formation || null) : null
    };
    stateCache.set(String(context.campaignId), state);
    if (state.equipment && context.syncArmorClass) context.syncArmorClass(state.equipment.armorClass);
    if (!shell.isConnected) return;
    renderFinalSystems(shell, context, state);
  } catch (error) {
    if (shell.isConnected) shell.innerHTML = `<section class="rs-system-panel rs-system-error"><h3>Final Gameplay Systems</h3><p>${context.escapeHtml(error.message)}</p></section>`;
  }
}

export async function handleFinalEquipmentToggle(context, item) {
  if (!context?.campaignId || !item?.inventoryItemId) return false;
  try {
    let state = stateCache.get(String(context.campaignId));
    if (!state?.equipment) {
      const loaded = await context.api(`/game-api/campaigns/${context.campaignId}/equipment`);
      state = { ...(state || {}), equipment: loaded.equipment };
      stateCache.set(String(context.campaignId), state);
    }

    const occupied = (state.equipment?.slots || []).find(s => String(s.inventoryItemId || '') === String(item.inventoryItemId));
    if (occupied) {
      const result = await context.api(`/game-api/campaigns/${context.campaignId}/equipment/unequip`, {
        method: 'POST', body: JSON.stringify({ slotKey: occupied.slotKey })
      });
      await afterEquipmentMutation(context, result, `${item.itemName} unequipped.`);
      return true;
    }

    const eligible = eligibleSlotsForItem(item);
    if (!eligible.length) return false;
    const currentSlots = state.equipment?.slots || [];
    const preferred = choosePreferredSlot(eligible, currentSlots);
    const slotKey = eligible.length === 1 ? eligible[0] : await chooseEquipmentSlot(context, item, eligible, preferred);
    if (!slotKey) return true;
    const result = await context.api(`/game-api/campaigns/${context.campaignId}/equipment/equip`, {
      method: 'POST', body: JSON.stringify({ inventoryItemId: item.inventoryItemId, slotKey })
    });
    await afterEquipmentMutation(context, result, `${item.itemName} equipped.`);
    return true;
  } catch (error) {
    context.showNotice(error.message, true);
    return true;
  }
}

async function afterEquipmentMutation(context, result, fallbackMessage) {
  const cached = stateCache.get(String(context.campaignId)) || {};
  if (result?.equipment) cached.equipment = result.equipment;
  stateCache.set(String(context.campaignId), cached);
  if (result?.equipment && context.syncArmorClass) context.syncArmorClass(result.equipment.armorClass);
  if (context.refreshInventory) await context.refreshInventory();
  context.showNotice(result?.message || fallbackMessage);
  context.rerender?.();
}

function renderFinalSystems(shell, context, state) {
  shell.innerHTML = [
    renderEquipmentPanel(context, state.equipment),
    renderCraftingPanel(context, state.crafting),
    renderHarvestingPanel(context, state.harvesting),
    context.isSolo ? renderFormationPanel(context, state.formation) : ''
  ].join('');
  bindEquipmentPanel(shell, context, state);
  bindCraftingPanel(shell, context, state);
  bindHarvestingPanel(shell, context, state);
  if (context.isSolo) bindFormationPanel(shell, context, state);
  hydrateEquipmentPortrait(shell, context);
}

function renderEquipmentPanel(context, equipment) {
  if (!equipment) return '<section class="rs-system-panel"><h3>Equipment Loadout</h3><p class="muted">Equipment state is unavailable.</p></section>';
  const slots = equipment.slots || [];
  const leftKeys = ['ranged','ammunition','armor','shield','ring_left','feet','accessory_1'];
  const rightKeys = ['head','neck','hands','main_hand','off_hand','ring_right','accessory_2'];
  const byKey = new Map(slots.map(s => [s.slotKey, s]));
  const column = keys => keys.map(key => equipmentSlotCard(context, byKey.get(key) || { slotKey:key,label:key,itemName:'' })).join('');
  const attacks = equipment.attacks || [];
  return `<section class="rs-system-panel rs-equipment-panel">
    <div class="rs-system-heading"><div><span class="rs-eyebrow">BUILD 6.22.1</span><h3>Equipment Loadout</h3><p>Equipped gear directly drives Armor Class and available weapon attacks.</p></div><div class="rs-ac-medallion"><span>ARMOR CLASS</span><b>${Number(equipment.armorClass)||10}</b></div></div>
    <div class="rs-loadout-stage">
      <div class="rs-slot-column">${column(leftKeys)}</div>
      <div class="rs-loadout-core" aria-label="Character equipment crest"><div class="rs-crest-ring" data-rs-equipment-portrait><div class="rs-crest-mark">RS</div><img class="rs-equipment-portrait" alt="${context.escapeHtml(equipment.characterName || context.gameData?.character?.characterName || 'Character')} portrait" hidden></div><strong>${context.escapeHtml(equipment.characterName || context.gameData?.character?.characterName || 'Adventurer')}</strong><small>${context.escapeHtml(equipment.defenseSummary || '')}</small></div>
      <div class="rs-slot-column">${column(rightKeys)}</div>
    </div>
    <div class="rs-attack-strip"><h4>Equipped Attacks</h4>${attacks.length?`<div class="rs-attack-grid">${attacks.map(a=>`<article class="${a.ammunitionReady===false?'unavailable':''}"><b>${context.escapeHtml(a.itemName)}</b><span>Attack ${signed(a.attackBonus)}</span><span>${context.escapeHtml(a.damage)} ${context.escapeHtml(a.damageType||'damage')}</span><small>${context.escapeHtml(a.range||'Melee')}${a.isOffHand?' • Off Hand':''}${a.ammunitionReady===false?` • ${context.escapeHtml(a.availabilityNote||'No ammunition equipped')}`:''}</small></article>`).join('')}</div>`:'<p class="muted">Equip a weapon in Main Hand, Off Hand, or Ranged to make its attack available.</p>'}</div>
  </section>`;
}

function equipmentSlotCard(context, slot) {
  const filled = !!slot.inventoryItemId;
  return `<button class="rs-slot-card ${filled?'filled':'empty'}" data-rs-slot="${context.escapeHtml(slot.slotKey)}" data-item-id="${context.escapeHtml(slot.inventoryItemId||'')}" type="button">
    <span class="rs-slot-icon">${context.escapeHtml(slot.icon||slotIcon(slot.slotKey))}</span>
    <span class="rs-slot-copy"><small>${context.escapeHtml(slot.label||humanSlot(slot.slotKey))}</small><b>${context.escapeHtml(slot.itemName||'Empty')}</b></span>
    ${filled?'<span class="rs-slot-remove" title="Unequip">×</span>':''}
  </button>`;
}

async function hydrateEquipmentPortrait(shell, context) {
  const ring = shell.querySelector('[data-rs-equipment-portrait]');
  const image = ring?.querySelector('.rs-equipment-portrait');
  const character = context.gameData?.character;
  const characterId = String(character?.characterId || '');

  if (!ring || !image || !characterId || typeof context.loadPortraitObjectUrl !== 'function') return;
  if (character?.hasPortrait === false) return;

  try {
    const objectUrl = await context.loadPortraitObjectUrl(characterId);
    if (!objectUrl || !ring.isConnected || !image.isConnected) return;
    image.src = objectUrl;
    image.hidden = false;
    ring.classList.add('has-portrait');
  } catch {
    // Missing/unavailable portrait intentionally leaves the RS crest visible.
  }
}

function bindEquipmentPanel(shell, context, state) {
  shell.querySelectorAll('[data-rs-slot]').forEach(button => button.onclick = async event => {
    event.preventDefault();
    const slotKey = button.dataset.rsSlot;
    const itemId = button.dataset.itemId;
    if (itemId) {
      try {
        const result = await context.api(`/game-api/campaigns/${context.campaignId}/equipment/unequip`, {
          method:'POST', body:JSON.stringify({slotKey})
        });
        await afterEquipmentMutation(context, result, `${humanSlot(slotKey)} cleared.`);
      } catch (error) { context.showNotice(error.message,true); }
      return;
    }
    const selected = (context.gameData?.inventory||[]).find(i => String(i.inventoryItemId) === String(context.selectedInventoryId||''));
    if (!selected) { context.showNotice(`Select an inventory item first, then choose ${humanSlot(slotKey)}.`, true); return; }
    if (!eligibleSlotsForItem(selected).includes(slotKey)) { context.showNotice(`${selected.itemName} cannot be equipped in ${humanSlot(slotKey)}.`, true); return; }
    try {
      const result = await context.api(`/game-api/campaigns/${context.campaignId}/equipment/equip`, {
        method:'POST', body:JSON.stringify({inventoryItemId:selected.inventoryItemId,slotKey})
      });
      await afterEquipmentMutation(context,result,`${selected.itemName} equipped.`);
    } catch (error) { context.showNotice(error.message,true); }
  });
}

function renderCraftingPanel(context, crafting) {
  if (!crafting) return '<section class="rs-system-panel"><h3>Crafting & Harvesting</h3><p class="muted">Crafting state is unavailable.</p></section>';
  const materials = crafting.materials || [];
  const recipes = crafting.recipes || [];
  return `<section class="rs-system-panel rs-crafting-panel">
    <div class="rs-system-heading"><div><span class="rs-eyebrow">BUILD 6.22</span><h3>Crafting & Harvesting</h3><p>Monster remains and gathered materials now have a purpose beyond selling.</p></div></div>
    <div class="rs-material-shelf"><h4>Harvested Materials</h4>${materials.length?`<div class="rs-material-chips">${materials.map(m=>`<span><b>${Number(m.quantity)||0}×</b> ${context.escapeHtml(m.itemName)}<small>${context.escapeHtml(m.familyLabel||'Material')}</small></span>`).join('')}</div>`:'<p class="muted">Harvest pelts, scales, meat, herbs, venom, bones, or chitin to begin crafting.</p>'}</div>
    <div class="rs-recipe-grid">${recipes.map(r=>recipeCard(context,r)).join('')||'<p class="muted">No recipes are available.</p>'}</div>
  </section>`;
}

function recipeCard(context, recipe) {
  const requirements = recipe.requirements || [];
  return `<article class="rs-recipe-card ${recipe.canCraft?'ready':''}"><div><small>${context.escapeHtml(recipe.category||'Crafting')}</small><h4>${context.escapeHtml(recipe.recipeName||recipe.recipeKey)}</h4><p>${context.escapeHtml(recipe.description||'')}</p></div><div class="rs-recipe-reqs">${requirements.map(r=>`<span class="${Number(r.available)>=Number(r.needed)?'met':'missing'}">${context.escapeHtml(r.label||r.family)} ${Number(r.available)||0}/${Number(r.needed)||0}</span>`).join('')}</div><div class="rs-recipe-output">Creates <b>${Number(recipe.outputQuantity)||1}× ${context.escapeHtml(recipe.outputItemName||'Item')}</b></div><button class="button ${recipe.canCraft?'primary':''} rs-craft-button" data-recipe-key="${context.escapeHtml(recipe.recipeKey)}" ${recipe.canCraft?'':'disabled'}>Craft</button></article>`;
}

function bindCraftingPanel(shell, context) {
  shell.querySelectorAll('.rs-craft-button').forEach(button => button.onclick = async () => {
    if (button.disabled) return;
    button.disabled = true;
    try {
      const result = await context.api(`/game-api/campaigns/${context.campaignId}/crafting/craft`, {
        method:'POST', body:JSON.stringify({recipeKey:button.dataset.recipeKey})
      });
      if (context.refreshInventory) await context.refreshInventory();
      context.showNotice(result.message || 'Crafting complete.');
      context.rerender?.();
    } catch (error) { context.showNotice(error.message,true); button.disabled=false; }
  });
}

function renderHarvestingPanel(context, harvesting) {
  if (!harvesting) return '<section class="rs-system-panel"><h3>Monster Harvesting</h3><p class="muted">Harvesting state is unavailable.</p></section>';
  const sources = harvesting.sources || [];
  return `<section class="rs-system-panel rs-harvesting-panel">
    <div class="rs-system-heading"><div><span class="rs-eyebrow">BUILD 6.26</span><h3>Monster Harvesting</h3><p>Defeated creatures now have finite, skill-based harvests instead of automatic anatomy drops.</p></div></div>
    ${sources.length ? `<div class="rs-harvest-source-grid">${sources.map(source=>harvestSourceCard(context,source)).join('')}</div>` :
      '<div class="rs-material-shelf"><p class="muted">No defeated monsters currently have recoverable harvesting materials.</p></div>'}
    <div class="rs-harvest-rules"><small>Checks are rolled by the server. Suitable tools or known skill proficiency can add proficiency; missing recommended tools raise the DC. Fresh materials can spoil.</small></div>
  </section>`;
}

function harvestSourceCard(context, source) {
  const entries = source.entries || [];
  return `<article class="rs-harvest-source">
    <header><div><small>DEFEATED CREATURE</small><h4>${context.escapeHtml(source.displayName||source.monsterName||'Monster')}</h4></div><span>${entries.length} material${entries.length===1?'':'s'}</span></header>
    <div class="rs-harvest-entry-grid">${entries.map(entry=>harvestEntryCard(context,entry)).join('')}</div>
  </article>`;
}

function harvestEntryCard(context, entry) {
  const rarity=String(entry.rarity||'common').replaceAll('_',' ');
  const spoiled=entry.spoiled===true;
  const missingContainer=entry.containerAvailable===false;
  const disabled=spoiled||missingContainer||Number(entry.remainingQuantity)<=0;
  const skill=`${entry.skillName||'Survival'} (${String(entry.abilityName||'wisdom').slice(0,3).toUpperCase()})`;
  const toolState=entry.toolAvailable?'Tool ready':entry.toolRequired?'Tool required':'No recommended tool';
  const containerNote=entry.requiredContainerFamily
    ? (entry.containerAvailable?`${entry.requiredContainerFamily} ready`:`Needs ${entry.requiredContainerFamily}`)
    : '';
  return `<div class="rs-harvest-entry rarity-${context.escapeHtml(String(entry.rarity||'common'))}">
    <div class="rs-harvest-title"><div><small>${context.escapeHtml(rarity.toUpperCase())}</small><b>${context.escapeHtml(entry.itemName)}</b></div><span>${Number(entry.remainingQuantity)||0}/${Number(entry.maximumQuantity)||0}</span></div>
    <p>${context.escapeHtml(entry.description||'')}</p>
    <div class="rs-harvest-meta"><span>${context.escapeHtml(skill)}</span><span>DC ${Number(entry.dc)||10}</span><span>${context.escapeHtml(entry.freshnessLabel||'Durable')}</span></div>
    <div class="rs-harvest-tool ${entry.toolAvailable?'ready':entry.toolRequired?'missing':''}"><span>${context.escapeHtml(entry.toolLabel||'Suitable harvesting tool')}</span><small>${context.escapeHtml([toolState,containerNote].filter(Boolean).join(' • '))}</small></div>
    <button class="button ${disabled?'':'primary'} rs-harvest-button" data-harvest-entry="${context.escapeHtml(entry.harvestEntryId||'')}" ${disabled?'disabled':''}>${spoiled?'Spoiled':missingContainer?'Missing Container':'Harvest'}</button>
  </div>`;
}

function bindHarvestingPanel(shell, context, state) {
  shell.querySelectorAll('.rs-harvest-button').forEach(button=>button.onclick=async()=>{
    if(button.disabled)return;
    button.disabled=true;
    const oldText=button.textContent;
    button.textContent='Harvesting...';
    try{
      const result=await context.api(`/game-api/campaigns/${context.campaignId}/harvesting/attempt`,{
        method:'POST',body:JSON.stringify({harvestEntryId:button.dataset.harvestEntry})
      });
      if(result?.harvesting)state.harvesting=result.harvesting;
      if(context.refreshInventory)await context.refreshInventory();
      context.showNotice(result.message||'Harvesting attempt resolved.',result?.harvestResult?.success===false);
      context.rerender?.();
    }catch(error){
      context.showNotice(error.message,true);
      button.disabled=false;
      button.textContent=oldText;
    }
  });
}

function renderFormationPanel(context, formation) {
  if (!formation?.isSolo) return '';
  const presets = [
    ['front_line','Front Line','A broad forward rank with trailing support.'],
    ['defensive','Defensive','A tight protective diamond around the center.'],
    ['traveling','Traveling','A staggered marching order for uncertain roads.'],
    ['custom','Custom','Set exact relative starting positions for your Solo party.']
  ];
  const members = formation.members || [];
  return `<section class="rs-system-panel rs-formation-panel">
    <div class="rs-system-heading"><div><span class="rs-eyebrow">BUILD 6.23 • SOLO</span><h3>Party Formation</h3><p>The selected preset is applied when terrain-aware combat staging begins.</p></div><span class="rs-active-preset">Active: <b>${context.escapeHtml(formation.presetLabel||humanPreset(formation.presetKey))}</b></span></div>
    <div class="rs-preset-grid">${presets.map(([key,label,desc])=>`<button class="rs-preset-card ${formation.presetKey===key?'active':''}" data-preset-key="${key}"><b>${label}</b><small>${desc}</small></button>`).join('')}</div>
    <div class="rs-formation-preview">${formationGrid(context,members)}</div>
    <div class="rs-custom-formation" ${formation.presetKey==='custom'?'':'hidden'}><h4>Custom Relative Positions</h4><p class="muted">Offsets are measured in 5-foot tactical squares from the party anchor. The terrain engine moves an invalid square to the nearest safe square.</p>${members.map(m=>customOffsetRow(context,m)).join('')}<button id="rsSaveCustomFormation" class="button primary">Save Custom Formation</button></div>
  </section>`;
}

function formationGrid(context, members) {
  const cells=[];
  for(let y=-3;y<=3;y++) for(let x=-3;x<=3;x++) {
    const member=members.find(m=>Number(m.offsetX)===x&&Number(m.offsetY)===y);
    cells.push(`<div class="rs-formation-cell ${x===0&&y===0?'anchor':''} ${member?'occupied':''}" title="${member?context.escapeHtml(member.characterName):`${x},${y}`}">${member?context.escapeHtml(initials(member.characterName)):(x===0&&y===0?'◆':'')}</div>`);
  }
  return `<div class="rs-formation-board">${cells.join('')}</div><div class="rs-formation-legend">${members.map(m=>`<span><b>${context.escapeHtml(initials(m.characterName))}</b>${context.escapeHtml(m.characterName)}</span>`).join('')}</div>`;
}

function customOffsetRow(context, member) {
  const values=[-3,-2,-1,0,1,2,3];
  const options=(selected)=>values.map(v=>`<option value="${v}" ${Number(selected)===v?'selected':''}>${v>0?'+':''}${v}</option>`).join('');
  return `<div class="rs-offset-row" data-character-id="${context.escapeHtml(member.characterId)}"><b>${context.escapeHtml(member.characterName)}</b><label>X <select class="input rs-offset-x">${options(member.offsetX)}</select></label><label>Y <select class="input rs-offset-y">${options(member.offsetY)}</select></label></div>`;
}

function bindFormationPanel(shell, context) {
  shell.querySelectorAll('[data-preset-key]').forEach(button=>button.onclick=async()=>{
    const key=button.dataset.presetKey;
    if(key==='custom') {
      const custom=shell.querySelector('.rs-custom-formation');
      if(custom)custom.hidden=false;
      shell.querySelectorAll('[data-preset-key]').forEach(x=>x.classList.toggle('active',x===button));
      return;
    }
    await saveFormation(context,key,[]);
  });
  const save=shell.querySelector('#rsSaveCustomFormation');
  if(save)save.onclick=async()=>{
    const offsets=[...shell.querySelectorAll('.rs-offset-row')].map(row=>({
      characterId:row.dataset.characterId,
      offsetX:Number(row.querySelector('.rs-offset-x')?.value)||0,
      offsetY:Number(row.querySelector('.rs-offset-y')?.value)||0
    }));
    const unique=new Set(offsets.map(x=>`${x.offsetX},${x.offsetY}`));
    if(unique.size!==offsets.length){context.showNotice('Each party member needs a unique Custom formation square.',true);return;}
    await saveFormation(context,'custom',offsets);
  };
}

async function saveFormation(context,presetKey,customOffsets){
  try{
    const result=await context.api(`/game-api/campaigns/${context.campaignId}/formation`,{
      method:'POST',body:JSON.stringify({presetKey,customOffsets})
    });
    const cached=stateCache.get(String(context.campaignId))||{};
    cached.formation=result.formation;
    stateCache.set(String(context.campaignId),cached);
    context.showNotice(result.message||`${humanPreset(presetKey)} formation saved.`);
    context.rerender?.();
  }catch(error){context.showNotice(error.message,true);}
}

function eligibleSlotsForItem(item) {
  const type=String(item.itemType||'').toLowerCase();
  const name=String(item.itemName||'').toLowerCase();
  const equipmentSlot=String(item.equipmentSlot||'').toLowerCase();
  const properties=String(item.weaponProperties||item.itemData?.weapon_properties||'').toLowerCase();
  const accessorySlots=['accessory_1','accessory_2'];
  const slots=[];

  const javelin=name.includes('javelin');
  const spear=name.includes('spear');
  const thrownHandRanged=javelin||spear;
  const bowCrossbowHandRanged=
    name.includes('shortbow')||
    name.includes('longbow')||
    (name.includes('crossbow')&&(name.includes('light')||name.includes('heavy')));
  const handRanged=thrownHandRanged||bowCrossbowHandRanged;

  const dedicatedRanged=
    name.includes('bow')||
    name.includes('crossbow')||
    name.includes('sling')||
    name.includes('blowgun')||
    equipmentSlot.includes('ranged')||
    properties.includes('ammunition')||
    properties.includes('ranged');

  const ammunition=
    type==='ammunition'||
    name.includes('arrow')||
    name.includes('bolt')||
    name.includes('bullet')||
    name.includes('needle')||
    name.includes('ammunition');

  const shield=type==='shield'||name.includes('shield');
  const weapon=
    type==='weapon'||
    name.includes('sword')||
    name.includes('dagger')||
    name.includes('axe')||
    name.includes('mace')||
    name.includes('hammer')||
    name.includes('spear')||
    name.includes('javelin')||
    name.includes('staff')||
    name.includes('club')||
    name.includes('flail')||
    name.includes('rapier')||
    name.includes('scimitar')||
    name.includes('trident')||
    name.includes('whip')||
    name.includes('bow')||
    name.includes('crossbow')||
    name.includes('sling')||
    name.includes('blowgun');

  if(ammunition)slots.push('ammunition');
  else if(shield)slots.push('shield','off_hand');
  else if(weapon) {
    // Weapon routing must happen before wearable hand-slot inference.
    // Otherwise equipmentSlot "Hand / Ranged" contains "hand" and was
    // incorrectly classified as the Hands armor/accessory slot.
    if(thrownHandRanged)slots.push('main_hand','off_hand','ranged');
    else if(bowCrossbowHandRanged)slots.push('main_hand','ranged');
    else if(dedicatedRanged)slots.push('ranged');
    else slots.push('main_hand','off_hand');
  }
  else if(name.includes('helmet')||name.includes('helm')||name.includes('circlet')||equipmentSlot.includes('head'))slots.push('head');
  else if(name.includes('glove')||name.includes('gauntlet')||name.includes('bracer')||equipmentSlot.includes('hand')||equipmentSlot.includes('arm'))slots.push('hands');
  else if(name.includes('boot')||name.includes('greave')||equipmentSlot.includes('feet'))slots.push('feet');
  else if(name.includes('ring'))slots.push('ring_left','ring_right');
  else if(name.includes('necklace')||name.includes('amulet')||name.includes('pendant')||name.includes('brooch'))slots.push('neck');
  else if(type==='armor')slots.push('armor');

  return [...new Set([...slots,...accessorySlots])];
}

function choosePreferredSlot(eligible,currentSlots){
  return eligible.find(key=>!currentSlots.some(s=>s.slotKey===key&&s.inventoryItemId))||eligible[0];
}

function chooseEquipmentSlot(context,item,eligible,preferred){
  return new Promise(resolve=>{
    document.querySelector('#rsEquipmentSlotOverlay')?.remove();
    const overlay=document.createElement('div');
    overlay.id='rsEquipmentSlotOverlay';
    overlay.className='rs-slot-overlay';
    overlay.innerHTML=`<div class="rs-slot-modal"><h3>Equip ${context.escapeHtml(item.itemName)}</h3><p>Choose an equipment slot.</p><div class="rs-slot-choice-grid">${eligible.map(key=>`<button class="button ${key===preferred?'primary':''}" data-choice="${key}">${humanSlot(key)}</button>`).join('')}</div><button class="button rs-cancel-slot">Cancel</button></div>`;
    document.body.appendChild(overlay);
    const finish=value=>{overlay.remove();resolve(value);};
    overlay.querySelectorAll('[data-choice]').forEach(b=>b.onclick=()=>finish(b.dataset.choice));
    overlay.querySelector('.rs-cancel-slot').onclick=()=>finish(null);
    overlay.onclick=e=>{if(e.target===overlay)finish(null);};
  });
}

function humanSlot(key){
  const labels={shield:'Shield / Off Hand',accessory_1:'Accessory 1',accessory_2:'Accessory 2'};
  return labels[key]||String(key||'').replaceAll('_',' ').replace(/\b\w/g,m=>m.toUpperCase());
}
function humanPreset(key){return String(key||'traveling').replaceAll('_',' ').replace(/\b\w/g,m=>m.toUpperCase());}
function slotIcon(key){return ({armor:'🛡',shield:'◈',main_hand:'⚔',off_hand:'†',ranged:'➶',ammunition:'⌁',head:'⛨',neck:'◇',hands:'✦',feet:'⌂',ring_left:'○',ring_right:'○',accessory_1:'✧',accessory_2:'✧'})[key]||'•';}
function signed(value){const n=Number(value)||0;return n>=0?`+${n}`:`${n}`;}
function initials(name){return String(name||'?').split(/\s+/).filter(Boolean).slice(0,2).map(x=>x[0]).join('').toUpperCase();}
