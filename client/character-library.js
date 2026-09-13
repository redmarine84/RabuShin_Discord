// RabuShinAIGM Build 6.30.9
// Character Library + campaign membership UI.
// This module intentionally receives the existing main.js helpers so the new
// feature preserves the Activity's established modal, auth and creator flows.

let ctx = null;
let activeCampaignId = null;
let campaignHookObserver = null;
let campaignModes = new Map();

export function configureCharacterLibraryUI(deps) {
  ctx = deps;
}

function needCtx() {
  if (!ctx) throw new Error('Character Library UI has not been configured.');
  return ctx;
}

function pendingReasonText(reason) {
  switch (String(reason || '').toLowerCase()) {
    case 'left_campaign': return 'You left the campaign.';
    case 'kicked_from_campaign': return 'You were removed from the campaign.';
    case 'campaign_deleted': return 'The campaign was deleted.';
    case 'removed_from_solo': return 'You removed this character from Solo Play.';
    default: return 'This character is no longer assigned to a campaign.';
  }
}

function statusLabel(c) {
  if (c.characterStatus === 'pending_storage') return 'Needs Store/Delete Decision';
  if (c.campaignId) return `In Campaign: ${c.campaignName || 'Campaign'}`;
  return 'Available';
}

function libraryCard(c) {
  const { escapeHtml } = needCtx();
  const assigned = !!c.campaignId;
  const pending = c.characterStatus === 'pending_storage';
  const classes = ['character-library-card'];
  if (assigned) classes.push('assigned');
  if (pending) classes.push('pending');

  return `<div class="${classes.join(' ')}" data-library-character="${escapeHtml(c.characterId)}">
    <div class="character-library-card-main">
      <div class="character-library-slot">${c.librarySlot ? `#${Number(c.librarySlot)}` : '!'}</div>
      <div>
        <h4>${escapeHtml(c.characterName)}</h4>
        <p>${escapeHtml(c.speciesName)} ${escapeHtml(c.className)} • Level ${Number(c.level || 1)}</p>
        <small>${escapeHtml(statusLabel(c))}</small>
        ${pending ? `<em>${escapeHtml(pendingReasonText(c.pendingReason))}</em>` : ''}
      </div>
    </div>
    <div class="character-library-actions">
      ${pending ? `
        <button class="button primary small pending-store" data-id="${escapeHtml(c.characterId)}">Store Character</button>
        <button class="button danger small pending-delete" data-id="${escapeHtml(c.characterId)}" data-name="${escapeHtml(c.characterName)}">Delete Character</button>`
      : assigned ? `<span class="character-library-in-use">IN USE</span>`
      : `<button class="button danger small library-delete" data-id="${escapeHtml(c.characterId)}" data-name="${escapeHtml(c.characterName)}">Delete</button>`}
    </div>
  </div>`;
}

export async function loadCharacterLibraryPanel() {
  const { api, escapeHtml, showNotice } = needCtx();
  const list = document.querySelector('#characterLibraryList');
  const count = document.querySelector('#characterLibraryCount');
  if (!list) return null;

  list.innerHTML = '<div class="loading">Loading characters...</div>';
  try {
    const data = await api('/game-api/characters/library');
    const characters = Array.isArray(data.characters) ? data.characters : [];
    if (count) count.textContent = `${Number(data.slotCount || 0)}/${Number(data.maxCharacters || 10)}`;

    if (!characters.length) {
      list.innerHTML = `<div class="empty"><div class="empty-icon">♙</div><b>No stored characters yet</b><span>Create up to 10 characters outside a campaign, then reuse them when starting or joining adventures.</span></div>`;
    } else {
      list.innerHTML = characters.map(libraryCard).join('');
    }

    list.querySelectorAll('.library-delete').forEach(btn => {
      btn.onclick = () => confirmDeleteLibraryCharacter(btn.dataset.id, btn.dataset.name);
    });
    list.querySelectorAll('.pending-store').forEach(btn => {
      btn.onclick = () => resolvePendingCharacter(btn.dataset.id, 'store');
    });
    list.querySelectorAll('.pending-delete').forEach(btn => {
      btn.onclick = () => confirmDeletePendingCharacter(btn.dataset.id, btn.dataset.name);
    });
    return data;
  } catch (error) {
    list.innerHTML = `<div class="empty danger-text">${escapeHtml(error.message)}</div>`;
    showNotice(error.message, true);
    return null;
  }
}

async function confirmDeleteLibraryCharacter(characterId, name) {
  const { showModal, api, showNotice } = needCtx();
  showModal(
    'Delete Stored Character',
    `<div class="destructive-warning"><p><strong>Permanently delete ${needCtx().escapeHtml(name)}?</strong></p><p>This character is currently available and is not assigned to a campaign. This cannot be undone.</p></div>`,
    'Delete Character',
    async () => {
      await api(`/game-api/characters/library/${characterId}`, { method: 'DELETE' });
      document.querySelector('#modalOverlay')?.remove();
      showNotice(`${name} was deleted.`);
      await loadCharacterLibraryPanel();
    }
  );
  const confirm = document.querySelector('#modalConfirm');
  if (confirm) confirm.className = 'button danger';
}

async function confirmDeletePendingCharacter(characterId, name) {
  const { showModal, showNotice } = needCtx();
  showModal(
    'Delete Character',
    `<div class="destructive-warning"><p><strong>Permanently delete ${needCtx().escapeHtml(name)}?</strong></p><p>This character was created for a campaign and is waiting for you to either store or delete it.</p></div>`,
    'Delete Character',
    async () => {
      await resolvePendingCharacter(characterId, 'delete', null, false);
      document.querySelector('#modalOverlay')?.remove();
      showNotice(`${name} was deleted.`);
      await loadCharacterLibraryPanel();
    }
  );
  const confirm = document.querySelector('#modalConfirm');
  if (confirm) confirm.className = 'button danger';
}

async function resolvePendingCharacter(characterId, action, replaceCharacterId = null, refresh = true) {
  const { api, showNotice } = needCtx();
  try {
    const result = await api(`/game-api/characters/pending/${characterId}/resolve`, {
      method: 'POST',
      body: JSON.stringify({ action, replaceCharacterId })
    });
    if (refresh) {
      showNotice(action === 'store' ? 'Character stored in My Characters.' : 'Character deleted.');
      await loadCharacterLibraryPanel();
    }
    return result;
  } catch (error) {
    if (action === 'store' && String(error.message || '').includes('CHARACTER_LIBRARY_FULL')) {
      await showReplacementChoice(characterId);
      return null;
    }
    throw error;
  }
}

async function showReplacementChoice(pendingCharacterId, afterResolve = null) {
  const { api, showModal, escapeHtml, showNotice } = needCtx();
  const data = await api('/game-api/characters/library');
  const available = (data.characters || []).filter(c =>
    c.librarySlot && !c.campaignId && c.characterStatus === 'available' && c.characterId !== pendingCharacterId);

  const body = available.length
    ? `<div class="destructive-warning"><p><strong>Your Character Library is full (10/10).</strong></p><p>Choose an available stored character to permanently delete and replace.</p></div>
       <div class="replacement-character-list">${available.map((c, i) => `
         <label class="replacement-character-option">
           <input type="radio" name="replacementCharacter" value="${escapeHtml(c.characterId)}" ${i === 0 ? 'checked' : ''}>
           <span><b>${escapeHtml(c.characterName)}</b><small>${escapeHtml(c.speciesName)} ${escapeHtml(c.className)} • Level ${Number(c.level || 1)}</small></span>
         </label>`).join('')}</div>`
    : `<div class="destructive-warning"><p><strong>Your Character Library is full and every stored character is currently in a campaign.</strong></p><p>No assigned character can be replaced. You can delete the character you were trying to store, or leave it pending until a slot becomes available.</p></div>`;

  showModal(
    'Character Library Full',
    body,
    available.length ? 'Replace & Store' : 'Keep Pending',
    async () => {
      if (!available.length) {
        document.querySelector('#modalOverlay')?.remove();
        if (afterResolve) await afterResolve();
        return;
      }
      const replacement = document.querySelector('input[name="replacementCharacter"]:checked')?.value;
      if (!replacement) throw new Error('Choose a character to replace.');
      await resolvePendingCharacter(pendingCharacterId, 'store', replacement, false);
      document.querySelector('#modalOverlay')?.remove();
      showNotice('Character stored. The selected stored character was deleted.');
      await loadCharacterLibraryPanel();
      if (afterResolve) await afterResolve();
    }
  );

  const actions = document.querySelector('#modalOverlay .modal-actions');
  if (actions) {
    const del = document.createElement('button');
    del.className = 'button danger';
    del.textContent = 'Delete New Character Instead';
    del.onclick = async () => {
      try {
        await resolvePendingCharacter(pendingCharacterId, 'delete', null, false);
        document.querySelector('#modalOverlay')?.remove();
        showNotice('Character deleted.');
        await loadCharacterLibraryPanel();
        if (afterResolve) await afterResolve();
      } catch (error) {
        const box = document.querySelector('#modalError');
        if (box) box.textContent = error.message;
      }
    };
    actions.insertBefore(del, document.querySelector('#modalConfirm'));
  }
}

async function showCharacterChoice(campaignId) {
  const { api, showModal, escapeHtml, showCharacterCreator, openCampaign, showNotice } = needCtx();
  activeCampaignId = campaignId;

  const existing = await api(`/game-api/campaigns/${campaignId}/character`);
  if (existing.hasCharacter) {
    return openCampaign(campaignId);
  }

  const library = await api('/game-api/characters/library');
  const characters = Array.isArray(library.characters) ? library.characters : [];
  const available = characters.filter(c => c.librarySlot && !c.campaignId && c.characterStatus === 'available');

  const body = `<p>Choose an available character from <strong>My Characters</strong>, or create a new character specifically for this campaign.</p>
    <div class="campaign-character-choice-list">
      ${characters.filter(c => c.librarySlot).length
        ? characters.filter(c => c.librarySlot).map(c => {
            const disabled = !!c.campaignId || c.characterStatus !== 'available';
            return `<button class="campaign-character-choice ${disabled ? 'disabled' : ''}" data-character-id="${escapeHtml(c.characterId)}" ${disabled ? 'disabled' : ''}>
              <span><b>${escapeHtml(c.characterName)}</b><small>${escapeHtml(c.speciesName)} ${escapeHtml(c.className)} • Level ${Number(c.level || 1)}</small></span>
              <em>${escapeHtml(disabled ? statusLabel(c) : 'Select Character')}</em>
            </button>`;
          }).join('')
        : '<div class="empty small">You do not have any stored characters yet.</div>'}
    </div>`;

  showModal('Choose Your Character', body, 'Create New Character', async () => {
    document.querySelector('#modalOverlay')?.remove();
    await showCharacterCreator(campaignId);
  });

  document.querySelectorAll('.campaign-character-choice:not(.disabled)').forEach(btn => {
    btn.onclick = async () => {
      try {
        btn.disabled = true;
        await api(`/game-api/campaigns/${campaignId}/character-library/${btn.dataset.characterId}/assign`, {
          method: 'POST'
        });
        document.querySelector('#modalOverlay')?.remove();
        showNotice('Character assigned to campaign.');
        await showCharacterChoice(campaignId);
      } catch (error) {
        btn.disabled = false;
        const box = document.querySelector('#modalError');
        if (box) box.textContent = error.message;
      }
    };
  });
}

async function showNewCampaignDialogV2() {
  const { showModal, api, showNotice } = needCtx();
  showModal(
    'Start New Campaign',
    `<label>Campaign Name</label><input id="campaignName" class="input" maxlength="80" placeholder="My Rabu Shin Campaign">
     <div class="campaign-mode-picker">
       <label class="campaign-mode-option"><input type="radio" name="campaignMode" value="solo" checked><span><b>Play Solo</b><small>Control your hero plus up to 4 additional party characters.</small></span></label>
       <label class="campaign-mode-option"><input type="radio" name="campaignMode" value="friends"><span><b>Play with Friends</b><small>Create a Discord multiplayer campaign with a join code.</small></span></label>
     </div>`,
    'Create Campaign',
    async () => {
      const name = document.querySelector('#campaignName')?.value?.trim() || '';
      if (!name) throw new Error('Campaign name is required.');
      const mode = document.querySelector('input[name="campaignMode"]:checked')?.value || 'solo';
      const result = await api(mode === 'solo' ? '/game-api/campaigns/solo' : '/game-api/campaigns', {
        method: 'POST',
        body: JSON.stringify({ campaignName: name })
      });
      document.querySelector('#modalOverlay')?.remove();
      showNotice(mode === 'solo' ? 'Solo Play campaign created.' : 'Friends campaign created.');
      if (result.campaignId) await showCharacterChoice(result.campaignId);
    }
  );
}

async function showJoinCampaignDialogV2() {
  const { showModal, api, showNotice } = needCtx();
  showModal(
    'Join Campaign',
    `<label>Campaign Code</label><input id="campaignCode" class="input mono" maxlength="64" placeholder="REDMARINEUSMC-XXXXXXXX">`,
    'Join Campaign',
    async () => {
      const code = document.querySelector('#campaignCode')?.value?.trim() || '';
      if (!code) throw new Error('Campaign code is required.');
      const result = await api('/game-api/campaigns/join', {
        method: 'POST',
        body: JSON.stringify({ joinCode: code })
      });
      document.querySelector('#modalOverlay')?.remove();
      showNotice('Campaign joined.');
      if (result.campaignId) await showCharacterChoice(result.campaignId);
    }
  );
}

async function leaveCampaign(campaignId, campaignName) {
  const { api, showModal, showNotice, showCampaignLauncher, escapeHtml } = needCtx();
  const data = await api(`/game-api/campaigns/${campaignId}/character-departure-preview`);
  const p = data.preview;

  const finish = async action => {
    await api(`/game-api/campaigns/${campaignId}/leave`, { method: 'POST' });
    if (p?.requiresStoreDeleteChoice && p.characterId && action) {
      try {
        await resolvePendingCharacter(p.characterId, action, null, false);
      } catch (error) {
        if (action === 'store' && String(error.message || '').includes('CHARACTER_LIBRARY_FULL')) {
          document.querySelector('#modalOverlay')?.remove();
          await showCampaignLauncher();
          await showReplacementChoice(p.characterId);
          return;
        }
        throw error;
      }
    }
    document.querySelector('#modalOverlay')?.remove();
    showNotice(`You left "${campaignName}".`);
    await showCampaignLauncher();
  };

  if (!p || p.isLibraryCharacter) {
    showModal(
      'Leave Campaign',
      `<div class="destructive-warning"><p><strong>Leave ${escapeHtml(campaignName)}?</strong></p><p>${p ? `${escapeHtml(p.characterName)} will automatically return to My Characters and become available again.` : 'You do not currently have a character in this campaign.'}</p></div>`,
      'Leave Campaign',
      () => finish(null)
    );
    const confirm = document.querySelector('#modalConfirm');
    if (confirm) confirm.className = 'button danger';
    return;
  }

  showModal(
    'Leave Campaign',
    `<div class="destructive-warning"><p><strong>Leave ${escapeHtml(campaignName)}?</strong></p><p>${escapeHtml(p.characterName)} was created inside this campaign. Choose whether to store the character in My Characters or permanently delete it.</p></div>`,
    'Store Character & Leave',
    () => finish('store')
  );
  const actions = document.querySelector('#modalOverlay .modal-actions');
  if (actions) {
    const del = document.createElement('button');
    del.className = 'button danger';
    del.textContent = 'Delete Character & Leave';
    del.onclick = async () => {
      try { await finish('delete'); }
      catch (error) {
        const box = document.querySelector('#modalError');
        if (box) box.textContent = error.message;
      }
    };
    actions.insertBefore(del, document.querySelector('#modalConfirm'));
  }
}

async function managePlayers(campaignId, campaignName) {
  const { api, showModal, escapeHtml, showNotice } = needCtx();
  const data = await api(`/game-api/campaigns/${campaignId}/members/manage`);
  const members = Array.isArray(data.members) ? data.members : [];

  showModal(
    `Players — ${campaignName}`,
    `<p>Campaign owners can remove non-owner players. Library characters automatically return to their owner; campaign-created characters wait for that player to choose Store or Delete.</p>
     <div class="campaign-member-list">
       ${members.map(m => `<div class="campaign-member-row">
         <div><b>${escapeHtml(m.displayName || m.discordUsername)}</b><small>@${escapeHtml(m.discordUsername)}${m.characterName ? ` • ${escapeHtml(m.characterName)}` : ' • No character yet'}</small></div>
         ${m.isOwner ? '<span class="badge">OWNER</span>' : `<button class="button danger small kick-player" data-player="${escapeHtml(m.playerId)}" data-name="${escapeHtml(m.displayName || m.discordUsername)}">Kick Player</button>`}
       </div>`).join('')}
     </div>`,
    'Close',
    async () => document.querySelector('#modalOverlay')?.remove()
  );

  document.querySelectorAll('.kick-player').forEach(btn => {
    btn.onclick = () => {
      const targetId = btn.dataset.player;
      const targetName = btn.dataset.name;
      showModal(
        'Kick Player',
        `<div class="destructive-warning"><p><strong>Remove ${escapeHtml(targetName)} from ${escapeHtml(campaignName)}?</strong></p><p>They immediately lose campaign access. Their library character will return automatically; a campaign-created character will wait for them to choose Store or Delete.</p></div>`,
        'Kick Player',
        async () => {
          await api(`/game-api/campaigns/${campaignId}/members/${targetId}/kick`, { method: 'POST' });
          document.querySelector('#modalOverlay')?.remove();
          showNotice(`${targetName} was removed from the campaign.`);
          await managePlayers(campaignId, campaignName);
        }
      );
      const confirm = document.querySelector('#modalConfirm');
      if (confirm) confirm.className = 'button danger';
    };
  });
}

async function deleteCampaignV2(campaignId, campaignName) {
  const { showModal, api, showNotice, showCampaignLauncher, escapeHtml } = needCtx();
  showModal(
    'Delete Campaign',
    `<div class="destructive-warning">
       <p><strong>Delete ${escapeHtml(campaignName)} for every player?</strong></p>
       <p>The campaign, campaign chat, encounters, maps and campaign-only progress will be removed. Stored characters return to My Characters. Campaign-created characters are preserved and each owner will be asked to Store or Delete them.</p>
     </div>
     <label>Type the campaign name exactly to confirm</label>
     <input id="deleteCampaignConfirm" class="input" autocomplete="off" placeholder="${escapeHtml(campaignName)}">`,
    'Delete Campaign',
    async () => {
      const typed = document.querySelector('#deleteCampaignConfirm')?.value?.trim() || '';
      if (typed !== campaignName) throw new Error('Enter the campaign name exactly to confirm deletion.');
      await api(`/game-api/campaigns/${campaignId}`, { method: 'DELETE' });
      document.querySelector('#modalOverlay')?.remove();
      showNotice(`Campaign "${campaignName}" was deleted. Player characters were preserved.`);
      await showCampaignLauncher();
    }
  );
  const confirm = document.querySelector('#modalConfirm');
  if (confirm) confirm.className = 'button danger';
}

async function removeSoloCharacter(campaignId, characterId, characterName) {
  const { api, showModal, escapeHtml, showNotice } = needCtx();
  const data = await api(`/game-api/campaigns/${campaignId}/character-departure-preview?characterId=${encodeURIComponent(characterId)}`);
  const p = data.preview;
  if (!p) throw new Error('Character could not be found in this Solo campaign.');

  const finish = async action => {
    try {
      await api(`/game-api/campaigns/${campaignId}/solo-party/characters/${characterId}/remove`, {
        method: 'POST',
        body: JSON.stringify({ action })
      });
      document.querySelector('#modalOverlay')?.remove();
      showNotice(p.isLibraryCharacter
        ? `${characterName} returned to My Characters.`
        : action === 'store'
          ? `${characterName} was stored in My Characters.`
          : `${characterName} was deleted.`);
      await showCharacterChoice(campaignId);
    } catch (error) {
      if (action === 'store' && String(error.message || '').includes('CHARACTER_LIBRARY_FULL')) {
        document.querySelector('#modalOverlay')?.remove();
        await showReplacementChoice(characterId, () => showCharacterChoice(campaignId));
        return;
      }
      throw error;
    }
  };

  if (p.isLibraryCharacter) {
    showModal(
      'Remove Character from Solo Campaign',
      `<p><strong>Remove ${escapeHtml(characterName)} from this Solo campaign?</strong></p><p>The character will not be deleted. It will return to My Characters and become available for another campaign.</p>`,
      'Remove Character',
      () => finish(null)
    );
    return;
  }

  showModal(
    'Remove Character from Solo Campaign',
    `<p><strong>Remove ${escapeHtml(characterName)} from this Solo campaign?</strong></p><p>This character was created inside the campaign. Choose whether to store it in My Characters or permanently delete it.</p>`,
    'Store Character',
    () => finish('store')
  );
  const actions = document.querySelector('#modalOverlay .modal-actions');
  if (actions) {
    const del = document.createElement('button');
    del.className = 'button danger';
    del.textContent = 'Delete Character';
    del.onclick = async () => {
      try { await finish('delete'); }
      catch (error) {
        const box = document.querySelector('#modalError');
        if (box) box.textContent = error.message;
      }
    };
    actions.insertBefore(del, document.querySelector('#modalConfirm'));
  }
}

async function refreshCampaignModes() {
  try {
    const data = await needCtx().api('/game-api/campaigns');
    campaignModes = new Map((data.campaigns || []).map(c => [String(c.campaignId), c]));
  } catch {
    // loadCampaigns already surfaces campaign retrieval errors.
  }
}

function hookCampaignCards() {
  const { openCampaign } = needCtx();

  document.querySelectorAll('.campaign-card').forEach(card => {
    const play = card.querySelector('.play');
    if (!play) return;
    const campaignId = play.dataset.id;
    const info = campaignModes.get(String(campaignId));
    const campaignName = card.querySelector('h4')?.textContent || 'Campaign';

    play.onclick = async () => {
      activeCampaignId = campaignId;
      try { await showCharacterChoice(campaignId); }
      catch (error) { needCtx().showNotice(error.message, true); }
    };

    const leave = card.querySelector('.leave-campaign');
    if (leave) {
      leave.onclick = async () => {
        try { await leaveCampaign(campaignId, campaignName); }
        catch (error) { needCtx().showNotice(error.message, true); }
      };
    }

    const del = card.querySelector('.delete-campaign');
    if (del) {
      del.onclick = () => deleteCampaignV2(campaignId, campaignName);
    }

    if (info?.isOwner && String(info.campaignMode || 'friends').toLowerCase() === 'friends') {
      const actions = card.querySelector('.campaign-actions');
      if (actions && !actions.querySelector('.manage-campaign-players')) {
        const button = document.createElement('button');
        button.className = 'button manage-campaign-players';
        button.textContent = 'Players';
        button.onclick = () => managePlayers(campaignId, campaignName);
        actions.insertBefore(button, del || null);
      }
    }
  });
}


function hookInCampaignMembershipControls() {
  if (!activeCampaignId) return;
  const info = campaignModes.get(String(activeCampaignId));
  if (!info) return;
  const gameView = document.querySelector('#gameView');
  if (!gameView) return;

  const isSettings = Array.from(gameView.querySelectorAll('h2,h3'))
    .some(h => String(h.textContent || '').trim().toLowerCase() === 'settings');
  if (!isSettings || gameView.querySelector('#characterLibraryCampaignMembership')) return;

  const mode = String(info.campaignMode || 'friends').toLowerCase();
  if (mode !== 'friends') return;

  const section = document.createElement('section');
  section.id = 'characterLibraryCampaignMembership';
  section.className = 'panel settings character-library-membership-settings';

  if (info.isOwner) {
    section.innerHTML = `<h4>Play with Friends — Player Management</h4>
      <p>Remove players from this campaign without destroying their characters.</p>
      <button class="button danger" id="managePlayersInCampaign">Manage Players / Kick Player</button>`;
    section.querySelector('#managePlayersInCampaign').onclick = () =>
      managePlayers(activeCampaignId, info.campaignName || 'Campaign');
  } else {
    section.innerHTML = `<h4>Play with Friends — Campaign Membership</h4>
      <p>Leave this campaign. Your stored character returns automatically; a campaign-created character can be stored or deleted.</p>
      <button class="button danger" id="leaveCampaignInGame">Leave Campaign</button>`;
    section.querySelector('#leaveCampaignInGame').onclick = () =>
      leaveCampaign(activeCampaignId, info.campaignName || 'Campaign');
  }

  gameView.appendChild(section);
}

function hookSoloRemovalControls() {
  if (!activeCampaignId) return;
  document.querySelectorAll('[data-solo-character-switch]').forEach(select => {
    const host = select.closest('.solo-active-character') || select.parentElement;
    if (!host || host.querySelector('.solo-remove-character')) return;

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'button danger small solo-remove-character';
    button.textContent = 'Delete Character';
    button.title = 'Remove this character from the Solo campaign';
    button.onclick = async event => {
      event.preventDefault();
      event.stopPropagation();
      const characterId = select.value;
      const characterName = select.selectedOptions?.[0]?.textContent || 'Character';
      try { await removeSoloCharacter(activeCampaignId, characterId, characterName); }
      catch (error) { needCtx().showNotice(error.message, true); }
    };
    host.appendChild(button);
  });
}

function ensureObserver() {
  if (campaignHookObserver) return;
  const main = document.querySelector('#mainContent');
  if (!main) return;

  campaignHookObserver = new MutationObserver(() => {
    refreshCampaignModes().finally(() => {
      hookCampaignCards();
      hookSoloRemovalControls();
      hookInCampaignMembershipControls();
    });
  });
  campaignHookObserver.observe(main, { childList: true, subtree: true });
}

export async function mountCharacterLibraryLauncher() {
  const { showCharacterCreator } = needCtx();
  const launcher = document.querySelector('.launcher');
  if (!launcher) return;

  activeCampaignId = null;
  await refreshCampaignModes();

  let panel = document.querySelector('#characterLibraryPanel');
  if (!panel) {
    panel = document.createElement('section');
    panel.id = 'characterLibraryPanel';
    panel.className = 'panel character-library-panel';
    panel.innerHTML = `
      <div class="panel-header">
        <div><h3>My Characters <span id="characterLibraryCount" class="character-library-count">0/10</span></h3><p>Create reusable characters outside a campaign. Characters currently in a campaign stay visible but are unavailable.</p></div>
        <button id="newLibraryCharacter" class="button small primary">＋ Create Character</button>
      </div>
      <div id="characterLibraryList" class="character-library-list"><div class="loading">Loading characters...</div></div>`;
    const actions = launcher.querySelector('.launcher-actions');
    launcher.insertBefore(panel, actions || null);
  }

  document.querySelector('#newLibraryCharacter').onclick = async () => {
    const data = await needCtx().api('/game-api/characters/library');
    if (Number(data.slotCount || 0) >= Number(data.maxCharacters || 10)) {
      needCtx().showNotice('Your Character Library is full (10/10). Delete an available stored character first.', true);
      return;
    }
    await showCharacterCreator(null, { libraryMode: true });
  };

  const newCampaign = document.querySelector('#newCampaign');
  if (newCampaign) newCampaign.onclick = showNewCampaignDialogV2;
  const joinCampaign = document.querySelector('#joinCampaign');
  if (joinCampaign) joinCampaign.onclick = showJoinCampaignDialogV2;

  await loadCharacterLibraryPanel();
  hookCampaignCards();
  hookSoloRemovalControls();
  hookInCampaignMembershipControls();
  ensureObserver();
}

export function setCharacterLibraryActiveCampaign(campaignId) {
  activeCampaignId = campaignId ? String(campaignId) : null;
}
