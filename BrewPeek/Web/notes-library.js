const notesDialog = $('notes-library');
const notesList = $('notes-list');
const notesSearch = $('notes-search');
let confirmNoteID = null;
let deletingNote = false;
let noteDeleteError = '';

function renderNotesLibrary() {
  if (!notesDialog.open) return;
  const focus = document.activeElement;
  const installed = new Map();
  for (const pkg of allPackages) {
    installed.set(key(pkg), pkg);
    for (const formerID of pkg.formerNoteIDs || []) {
      if (!installed.has(formerID)) installed.set(formerID, pkg);
    }
  }
  const query = notesSearch.value.trim().toLowerCase();
  const entries = [...packageNotes].filter(([id, text]) => {
    const pkg = installed.get(id);
    return [id, pkg && key(pkg), pkg?.displayName, text].some(value => value?.toLowerCase().includes(query));
  }).sort(([a], [b]) => a.split(':')[1].localeCompare(b.split(':')[1]) || a.localeCompare(b));

  notesList.innerHTML = entries.map(([id, text]) => {
    const [type, name] = id.split(':');
    const label = type === 'cask' ? 'Cask' : 'Formula';
    const pkg = installed.get(id);
    let status = '';
    if (!pkg) status = 'Not installed';
    else if (key(pkg) !== id) status = 'Now ' + key(pkg).split(':')[1];
    const actionID = 'note-actions-' + encodeURIComponent(id);
    const disabled = deletingNote || noteDrafts.get(id)?.saving ? ' disabled' : '';
    const button = (action, title, aria) =>
      `<button class="subtle-btn" id="${actionID}-${action}" data-action="${action}" aria-label="${esc(aria)}"${disabled}>${title}</button>`;
    const confirming = confirmNoteID === id;
    return `<li data-note-id="${esc(id)}"><div><strong>${esc(name)}</strong><small>${label}</small>${status ? `<small>${esc(status)}</small>` : ''}
      <p class="note-value">${esc(text)}</p></div>
      ${confirming ? `<div class="note-confirm"><span>Delete the note for ${esc(name)}?</span>
        ${button('cancel','Cancel','Cancel deletion')} ${button('delete','Delete note','Confirm deletion of note for ' + label + ' ' + name)}</div>`
        : button('ask','Delete note','Delete note for ' + label + ' ' + name)}</li>`;
  }).join('');
  let status;
  if (notesLoadFailed) status = 'Could not load notes.';
  else if (!notesReady) status = 'Loading notes…';
  else if (!packageNotes.size) status = 'No saved notes.';
  else if (!entries.length) status = 'No matching notes.';
  else status = entries.length + (entries.length === 1 ? ' note' : ' notes');
  $('notes-status').textContent = noteDeleteError || status;
  $('notes-retry').hidden = !notesLoadFailed;
  $('notes-done').disabled = deletingNote;
  notesSearch.readOnly = deletingNote;
  if (focus.id && !focus.isConnected) $(focus.id)?.focus({preventScroll:true});
}

window.showPackageNotes = function () {
  if (document.querySelector('dialog[open]') || updateBusy()) return;
  confirmNoteID = null;
  noteDeleteError = '';
  notesSearch.value = '';
  lockBackground();
  notesDialog.showModal();
  renderNotesLibrary();
  notesList.scrollTop = 0;
  notesSearch.focus({preventScroll:true});
};

notesSearch.oninput = () => {
  confirmNoteID = null;
  noteDeleteError = '';
  renderNotesLibrary();
};
$('notes-done').onclick = () => notesDialog.close();
$('notes-retry').onclick = async () => {
  $('notes-retry').disabled = true;
  await loadPackageNotes();
  $('notes-retry').disabled = false;
};
notesDialog.addEventListener('cancel', event => {
  if (deletingNote) event.preventDefault();
  else if (confirmNoteID) {
    event.preventDefault();
    notesList.querySelector('[data-action="cancel"]')?.click();
  }
});

notesList.onclick = async event => {
  const button = event.target.closest('button[data-action]');
  if (!button || button.disabled || deletingNote) return;
  const id = button.closest('li').dataset.noteId;
  const actionID = 'note-actions-' + encodeURIComponent(id);
  noteDeleteError = '';
  if (button.dataset.action === 'ask' || button.dataset.action === 'cancel') {
    confirmNoteID = button.dataset.action === 'ask' ? id : null;
    renderNotesLibrary();
    $(actionID + (confirmNoteID ? '-cancel' : '-ask')).focus({preventScroll:true});
    return;
  }
  if (confirmNoteID !== id) return;
  deletingNote = true;
  renderNotesLibrary();
  try {
    await savePackageNote(id, '');
    noteDrafts.delete(id);
    confirmNoteID = null;
  } catch {
    noteDeleteError = 'Could not delete the note. Try again.';
  }
  deletingNote = false;
  refreshPackageNotes();
  ($(actionID + '-delete') || notesSearch).focus({preventScroll:true});
};
