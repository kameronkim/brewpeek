const packageNotes = new Map();
const noteDrafts = new Map();
const notesBridge = window.webkit?.messageHandlers?.packageNotes;
let notesReady = false;
let notesLoadFailed = false;

// Used by shows short names when unique and Homebrew full names for collisions.
function indexUsedByFormulae(formulae) {
  const ids = new Map();
  for (const p of formulae) ids.set(p.name, ids.has(p.name) ? null : key(p));
  for (const p of formulae) {
    const id = key(p);
    ids.set(id.slice('formula:'.length), id);
  }
  return ids;
}

function usedByWithNotes(names) {
  if (!names?.length) return '—';
  const entries = names.map(name => {
    const note = packageNotes.get(usedByFormulaIDs.get(name));
    const annotation = note
      ? `<span class="used-by-note"><span class="sr-only">My note: </span>${esc(note)}</span>`
      : '';
    return `<li>${esc(name)}${annotation}</li>`;
  });
  return `<ul class="used-by-list">${entries.join('')}</ul>`;
}

function packageNoteFields(p) {
  const id = key(p), note = packageNotes.get(id), draft = noteDrafts.get(id);
  const former = formerNotes(p);
  let content;
  if (draft) {
    content = `<textarea class="note-editor" data-note-action="input" aria-label="My note for ${esc(p.name)}" maxlength="300"${draft.saving ? ' readonly' : ''}>${esc(draft.text)}</textarea>
      <button class="subtle-btn" data-note-action="save" aria-disabled="${draft.saving}">Save</button>
      <button class="subtle-btn" data-note-action="cancel" aria-disabled="${draft.saving}">Cancel</button>
      ${draft.error ? `<p role="alert">${esc(draft.error)}</p>` : ''}`;
  } else if (notesLoadFailed) {
    content = 'Could not load notes. <button class="subtle-btn" data-note-action="retry">Retry</button>';
  } else if (notesReady) {
    content = (note ? `<p class="note-value">${esc(note)}</p>` : '') +
      `<button class="subtle-btn" data-note-action="edit">${note ? 'Edit note' : 'Add note'}</button>`;
  } else {
    return '';
  }
  const history = former.map(([oldID, text]) =>
    `<div><small>Saved as ${esc(oldID.slice(oldID.indexOf(':') + 1))}</small><p class="note-value">${esc(text)}</p></div>`
  ).join('');
  return field('MY NOTE', content + history, 'full') +
    (note || draft || former.length ? field('DESCRIPTION', esc(packageDescription(p)), true) : '');
}

function formerNotes(p) {
  return (p.formerNoteIDs || []).filter(id => packageNotes.has(id)).map(id => [id, packageNotes.get(id)]);
}

function listNote(p) {
  if (packageNotes.has(key(p))) return packageNotes.get(key(p));
  const former = formerNotes(p);
  return former.length === 1 ? former[0][1] : '';
}

function removalNote(id) {
  const note = packageNotes.get(id);
  return `<small class="dependency-note removal-note" data-removal-note="${esc(id)}"${note ? '' : ' hidden'}>${esc(note || '')}</small>`;
}

function refreshPackageNotes() {
  if (!brewData) return;
  const view = captureInventoryView();
  render();
  restoreInventoryView(view);
  for (const element of document.querySelectorAll('[data-removal-note]')) {
    const note = packageNotes.get(element.dataset.removalNote);
    element.textContent = note || '';
    element.hidden = !note;
  }
}

async function loadPackageNotes() {
  if (!notesBridge) return;
  try {
    const notes = await notesBridge.postMessage({action: 'load'});
    for (const [id, text] of Object.entries(notes)) packageNotes.set(id, text);
    notesReady = true;
    notesLoadFailed = false;
  } catch {
    notesLoadFailed = true;
  }
  refreshPackageNotes();
}

function refreshNoteEditor(id) {
  const cell = document.getElementById('detail-' + encodeURIComponent(id));
  const pkg = allPackages.find(p => key(p) === id);
  if (!cell || cell.hidden || !pkg) return;
  const focus = captureInventoryFocus();
  cell.firstElementChild.innerHTML = detail(pkg);
  syncActionAvailability();
  restoreInventoryFocus(focus);
}

function selectNoteControl(id, action) {
  const cell = document.getElementById('detail-' + encodeURIComponent(id));
  cell?.querySelector(`[data-note-action="${action}"]`)?.focus({preventScroll: true});
}

$('packages').addEventListener('input', event => {
  if (event.target.dataset.noteAction !== 'input') return;
  const id = event.target.closest('.detail-row').previousElementSibling.dataset.key;
  noteDrafts.get(id).text = event.target.value;
});

$('packages').addEventListener('click', async event => {
  const button = event.target.closest('button[data-note-action]');
  if (!button) return;
  const id = button.closest('.detail-row').previousElementSibling.dataset.key;
  const action = button.dataset.noteAction;
  const draft = noteDrafts.get(id);
  if (action === 'retry') {
    await loadPackageNotes();
    return;
  }
  if (draft?.saving) return;
  if (action === 'edit') {
    noteDrafts.set(id, {text: packageNotes.get(id) || '', saving: false});
    refreshNoteEditor(id);
    selectNoteControl(id, 'input');
    return;
  }
  if (!draft) return;
  if (action === 'cancel') {
    noteDrafts.delete(id);
    refreshNoteEditor(id);
    selectNoteControl(id, 'edit');
    return;
  }
  draft.saving = true;
  draft.error = '';
  refreshNoteEditor(id);
  try {
    const saved = await notesBridge.postMessage({action: 'save', id, text: draft.text});
    if (saved) packageNotes.set(id, saved);
    else packageNotes.delete(id);
    noteDrafts.delete(id);
  } catch (error) {
    draft.error = 'Could not save the note. ' + String(error.message || error);
    draft.saving = false;
  }
  const wasSavingHere = document.activeElement?.dataset.noteAction === 'save' &&
    document.activeElement.closest('.detail-row')?.previousElementSibling.dataset.key === id;
  refreshPackageNotes();
  if (wasSavingHere) selectNoteControl(id, draft.error ? 'input' : 'edit');
});

loadPackageNotes();
