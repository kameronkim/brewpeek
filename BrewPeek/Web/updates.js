// Native Homebrew updates. No package changes are simulated in this bundle.
let updateMode = 'ready',
  updatePlan = null,
  requestedKeys = [],
  previousResult = null;
let activeRequest = null;
let processedPackages = 0;
let popupScroll = null,
  activity = [],
  progressPackages = [],
  progressStates = {};
let popupReturnFocus = null;
let pendingCancelFocus = null;
let operationScrollPending = false;
const updateBusy = () =>
  ['checking', 'cancelling', 'running', 'verifying', 'confirming'].includes(updateMode);
const postUpdate = (message) => window.webkit.messageHandlers.packageUpdate.postMessage(message);
const bulk = document.createElement('button');
bulk.className = 'update-btn bulk';
bulk.textContent = 'Update all';
bulk.id = 'update-all';
bulk.hidden = true;
document.querySelector('.filter-actions').insertBefore(bulk, $('refresh'));
const inventoryRender = render;
render = function () {
  inventoryRender();
  bulk.hidden = !allPackages.some((p) => p.availableVersion);
  syncActionAvailability();
};
function syncActionAvailability() {
  const unavailable = updateBusy() || inventoryRefreshState !== 'idle';
  bulk.disabled = unavailable;
  $('refresh').disabled = updateBusy() || inventoryRefreshState === 'refreshing';
  document
    .querySelectorAll('[data-update], [data-retry], #retry-check, #retry-plan')
    .forEach((b) => (b.disabled = unavailable));
}
function setUpdateMode(mode) {
  updateMode = mode;
  syncActionAvailability();
}
function scrollOperationIntoView() {
  const frame = document.querySelector('#operation .operation');
  if (!frame) return;
  if (popupScroll || document.querySelector('dialog[open]')) {
    operationScrollPending = true;
    return;
  }
  operationScrollPending = false;
  const toolbarHeight = document.querySelector('.toolbar').getBoundingClientRect().height;
  const frameSpacing = parseFloat(getComputedStyle(frame).marginTop);
  const top = scrollY + frame.getBoundingClientRect().top - toolbarHeight - frameSpacing;
  scrollTo(scrollX, Math.max(0, top));
}
function lockBackground() {
  if (popupScroll) return;
  popupReturnFocus ||= captureInventoryFocus();
  popupScroll = { x: scrollX, y: scrollY };
  document.documentElement.classList.add('modal-open');
  document.body.classList.add('modal-open');
}
function unlockBackground() {
  if (!popupScroll || document.querySelector('dialog[open]')) return;
  const saved = popupScroll;
  popupScroll = null;
  document.documentElement.classList.remove('modal-open');
  document.body.classList.remove('modal-open');
  scrollTo(saved.x, saved.y);
  restoreInventoryFocus(popupReturnFocus);
  if (updateMode === 'cancelling' && popupReturnFocus) {
    pendingCancelFocus = { origin: popupReturnFocus, interim: document.activeElement };
  }
  popupReturnFocus = null;
  if (operationScrollPending) scrollOperationIntoView();
}
function restoreCancelledFocus() {
  if (!pendingCancelFocus) return;
  const { origin, interim } = pendingCancelFocus;
  pendingCancelFocus = null;
  // Preparation can finish after the dialog closes. Respect any new user focus.
  if (!document.querySelector('dialog[open]') && document.activeElement === interim)
    restoreInventoryFocus(origin);
}
for (const dialog of document.querySelectorAll('dialog')) {
  dialog.addEventListener('close', unlockBackground);
  dialog.addEventListener('keydown', (event) => {
    if (event.key !== 'Tab' || event.altKey || event.ctrlKey || event.metaKey) return;
    const buttons = [...dialog.querySelectorAll('button:not(:disabled)')].filter(
      (button) => button.getClientRects().length
    );
    if (!buttons.length) return;
    const index = buttons.indexOf(document.activeElement);
    // WKWebView otherwise includes the web view itself when wrapping a dialog.
    if (index < 0 || (event.shiftKey ? index === 0 : index === buttons.length - 1)) {
      event.preventDefault();
      buttons[event.shiftKey ? buttons.length - 1 : 0].focus({ preventScroll: true });
    }
  });
}
function showNotice(title, copy, command = '', kind = 'info') {
  // Native close prevention can arrive while the confirmation is open.
  $('notice').dataset.kind = kind;
  $('notice-title').textContent = title;
  $('notice-copy').textContent = copy;
  $('notice-command').textContent = command;
  $('notice-command').hidden = !command;
  lockBackground();
  if (!$('notice').open) $('notice').showModal();
}
$('notice-ok').onclick = () => $('notice').close();
function checkChanges(keys, trigger = document.activeElement) {
  if (updateBusy() || inventoryRefreshState !== 'idle' || !keys.length) return;
  if (!popupScroll) popupReturnFocus = captureInventoryFocus(trigger);
  requestedKeys = keys;
  activeRequest = crypto.randomUUID();
  showChecking();
  postUpdate({ action: 'prepare', keys, requestID: activeRequest });
}
function setConfirmState(mode) {
  $('confirm').dataset.state = mode;
  document.querySelector('.confirm-scroll').hidden = mode !== 'confirming';
  document.querySelector('.confirm-bottom > p').hidden = mode !== 'confirming';
  $('confirm-error').hidden = mode !== 'check-failed';
  $('start').hidden = mode !== 'confirming';
  $('retry-plan').hidden = mode !== 'check-failed';
  $('cancel').textContent = mode === 'check-failed' ? 'Close' : 'Cancel';
  lockBackground();
  if (!$('confirm').open) $('confirm').showModal();
}
function showChecking(message) {
  setUpdateMode('checking');
  $('confirm-title').textContent = message || 'Checking changes…';
  $('confirm-copy').textContent =
    'Checking selected packages and dependencies. No installation has started.';
  setConfirmState('checking');
  $('confirm-title').focus({ preventScroll: true });
}
function showCheckError(message) {
  updatePlan = null;
  setUpdateMode('check-failed');
  $('confirm-title').textContent = 'Could not check updates';
  $('confirm-copy').textContent = 'Review the details and try again.';
  $('confirm-error').innerHTML = `<pre>${esc(message)}</pre>`;
  setConfirmState('check-failed');
  $('retry-plan').focus({ preventScroll: true });
}
$('retry-plan').onclick = () => checkChanges(requestedKeys);
function showPlan(plan, changed) {
  updatePlan = plan;
  setUpdateMode('confirming');
  setConfirmState('confirming');
  $('confirm-title').textContent =
    plan.selectedCount === 1 ? 'Update package?' : `Update ${plan.selectedCount} packages?`;
  $('confirm-copy').textContent =
    (changed ? 'The plan changed. Review it before continuing. ' : '') +
    `${plan.selectedCount} selected · ${plan.packages.length - plan.selectedCount} additional changes.` +
    (plan.excluded?.length ? ` Homebrew excluded: ${plan.excluded.join(', ')}.` : '');
  $('confirm-list').innerHTML = plan.packages
    .map(
      (p) =>
        `<tr><td>${esc(p.name)}<small class="dependency-note">${esc(p.relationship || p.reason)}</small></td><td>${p.action === 'install' ? 'Not installed' : esc(p.version)}</td><td>${esc(p.availableVersion)}</td></tr>`
    )
    .join('');
  document.querySelector('.confirm-scroll').scrollTop = 0;
}
function cancelUpdate() {
  const pending = updateMode === 'checking';
  updatePlan = null;
  setUpdateMode(pending ? 'cancelling' : previousResult ? 'result' : 'ready');
  postUpdate({ action: 'cancel' });
  if (!pending) activeRequest = null;
}
$('cancel').onclick = () => {
  cancelUpdate();
  $('confirm').close();
};
$('confirm').addEventListener('cancel', cancelUpdate);
$('confirm').addEventListener('keydown', (event) => {
  if (updateMode !== 'confirming' || event.altKey || event.ctrlKey || event.metaKey) return;
  const list = document.querySelector('.confirm-scroll');
  const positions = {
    ArrowDown: list.scrollTop + 40,
    ArrowUp: list.scrollTop - 40,
    PageDown: list.scrollTop + list.clientHeight,
    PageUp: list.scrollTop - list.clientHeight,
    Home: 0,
    End: list.scrollHeight
  };
  if (!(event.key in positions)) return;
  event.preventDefault();
  list.scrollTop = positions[event.key];
});
$('start').onclick = () => {
  const token = updatePlan?.token;
  if (!token) return;
  activeRequest = crypto.randomUUID();
  showChecking('Rechecking the confirmed plan…');
  postUpdate({ action: 'start', token, requestID: activeRequest });
};
$('packages').addEventListener(
  'click',
  (event) => {
    const button = event.target.closest('[data-update]');
    if (!button) return;
    event.stopImmediatePropagation();
    checkChanges([button.dataset.update], button);
  },
  true
);
bulk.onclick = () => checkChanges(allPackages.filter((p) => p.availableVersion).map(key), bulk);
function beginProgress(plan) {
  previousResult = null;
  activity = [];
  progressStates = {};
  progressPackages = plan.packages;
  setUpdateMode('running');
  $('operation').innerHTML =
    `<section class="operation"><div class="operation-top"><div><div class="eyebrow" id="operation-phase">UPDATE IN PROGRESS</div><h3><span class="pulse"></span><span id="operation-title">Updating packages</span></h3><p id="operation-copy">Homebrew controls parallel downloads and installation order.</p></div></div><div class="progress-summary"><span>Packages processed · including dependencies</span><span id="processed">0 of ${progressPackages.length}</span></div><div class="progress-track"><div class="progress-fill" id="overall-fill"></div></div><p id="discovered" hidden>Additional related changes detected. The total includes these packages.</p><details id="progress-items"><summary id="progress-count"></summary><div class="bounded-list" id="progress-rows"></div></details><details id="progress-log"><summary>Show activity</summary><pre id="activity-log"></pre></details></section>`;
  paintProgress(0);
  scrollOperationIntoView();
}
function paintProgress(processed = processedPackages) {
  processedPackages = processed;
  if (!$('progress-rows')) return;
  $('processed').textContent = `${processed} of ${progressPackages.length}`;
  $('overall-fill').style.width =
    `${progressPackages.length ? (processed / progressPackages.length) * 100 : 0}%`;
  $('progress-count').textContent = `Package details · ${progressPackages.length}`;
  $('discovered').hidden = !progressPackages.some((p) => p.reason === 'Detected during execution');
  const container = $('progress-rows');
  for (const p of progressPackages) {
    let row = [...container.children].find((node) => node.dataset.package === p.id);
    if (!row) {
      row = document.createElement('div');
      row.className = 'download-item';
      row.dataset.package = p.id;
      row.innerHTML = `<span>${esc(p.name)}<small class="dependency-note">${esc(p.relationship || p.reason)}</small></span><div class="progress-track"><div class="progress-fill"></div></div><span class="download-state"></span>`;
      container.append(row);
    }
    row.querySelector('.dependency-note').textContent = p.relationship || p.reason;
    const text =
      updateMode === 'verifying'
        ? 'Verifying installed version…'
        : progressStates[p.id] || 'Waiting for Homebrew';
    row.querySelector('.download-state').textContent = text;
    row
      .querySelector('.progress-track')
      .classList.toggle(
        'indeterminate',
        !['Waiting for Homebrew', 'Awaiting verification'].includes(text)
      );
    row.querySelector('.progress-fill').style.width =
      text === 'Awaiting verification' ? '100%' : '0%';
  }
}
function paintResult(result) {
  const counts = {};
  result.packages.forEach((p) => (counts[p.outcome] = (counts[p.outcome] || 0) + 1));
  const summary = Object.entries(counts)
    .map(([type, count]) => `${count} ${type === 'attention' ? 'need attention' : type}`)
    .join(' · ');
  const issues = result.packages.filter((p) => !['updated', 'installed'].includes(p.outcome));
  $('operation').innerHTML =
    `<section class="operation"><div class="operation-top"><div><div class="eyebrow">UPDATE RESULTS</div><h3>${esc(summary)}</h3><p>${result.verified ? 'Installed versions checked.' : 'Installed versions could not be checked.'}${result.refreshError ? ' Inventory refresh failed; use Refresh to try again.' : ''}</p></div><button class="subtle-btn" id="dismiss">Close results</button></div>${issues.length ? `<div class="issues">${issues.map((p) => `<div class="issue-item"><div><strong>${esc(p.name)}</strong><p>${esc(p.message)}</p></div><button class="subtle-btn" data-retry="${esc(p.id)}">Retry</button></div>`).join('')}</div>` : ''}<details><summary>All results · ${result.packages.length}</summary><ul class="result-list bounded-list">${result.packages.map((p) => `<li>${esc(p.name)}<span>${esc(p.message)}<small class="dependency-note">Installed: ${esc(p.actualVersion)}</small></span></li>`).join('')}</ul></details><details><summary>Show activity</summary><pre>${esc(result.details || '')}${result.refreshError ? '\n' + esc(result.refreshError) : ''}</pre></details>${issues.length && result.command ? '<div class="dialog-actions"><button class="subtle-btn" id="terminal-help">View Terminal command</button></div>' : ''}</section>`;
  $('dismiss').onclick = () => {
    const view = captureInventoryView();
    previousResult = null;
    $('operation').replaceChildren();
    restoreInventoryView(view);
  };
  document.querySelectorAll('[data-retry]').forEach(
    (button) =>
      (button.onclick = () => {
        const item = allPackages.find((p) => key(p) === button.dataset.retry && p.availableVersion);
        checkChanges(item ? [key(item)] : result.retryKeys || requestedKeys, button);
      })
  );
  if ($('terminal-help'))
    $('terminal-help').onclick = () =>
      showNotice(
        'Continue in Terminal',
        'Review the activity above. If administrator permission is required, run this command in Terminal, then return and refresh.',
        result.command
      );
}
window.receiveUpdate = function (event) {
  if (event.requestID && event.requestID !== activeRequest) return;
  if (updateMode === 'cancelling' && ['checking', 'plan', 'error'].includes(event.kind)) return;
  switch (event.kind) {
    case 'checking':
      showChecking(event.message);
      break;
    case 'plan':
      showPlan(event.plan, event.changed);
      break;
    case 'cancelled':
      activeRequest = null;
      setUpdateMode(previousResult ? 'result' : 'ready');
      restoreCancelledFocus();
      break;
    case 'started':
      $('confirm').close();
      updatePlan = null;
      beginProgress(event.plan);
      break;
    case 'progress':
      progressPackages = event.packages;
      progressStates = event.states;
      paintProgress(event.processed);
      break;
    case 'activity': {
      if (event.packages) progressPackages = event.packages;
      progressStates = event.states;
      activity.push(event.line);
      if (activity.length > 1500) activity.splice(0, activity.length - 1500);
      const log = $('activity-log');
      if (log) {
        const bottom = log.scrollHeight - log.scrollTop - log.clientHeight < 30;
        log.textContent = activity.join('\n');
        if (bottom) log.scrollTop = log.scrollHeight;
      }
      paintProgress(event.processed);
      break;
    }
    case 'verifying':
      setUpdateMode('verifying');
      $('operation-phase').textContent = 'VERIFYING RESULTS';
      $('operation-title').textContent = 'Checking installed versions';
      $('operation-copy').textContent = 'Confirming actual versions before reporting success.';
      paintProgress();
      break;
    case 'result': {
      const view = captureInventoryView();
      updatePlan = null;
      previousResult = event;
      setUpdateMode('result');
      if (event.snapshot) window.setInventory(event.snapshot);
      paintResult(event);
      restoreInventoryView(view);
      syncActionAvailability();
      finishNotice();
      scrollOperationIntoView();
      break;
    }
    case 'error':
      if (['checking', 'confirming', 'check-failed'].includes(updateMode)) {
        showCheckError(event.message);
        break;
      }
      updatePlan = null;
      setUpdateMode(previousResult ? 'result' : 'ready');
      if (previousResult) paintResult(previousResult);
      else
        $('operation').innerHTML =
          `<section class="operation"><div class="eyebrow">UPDATE UNAVAILABLE</div><h3>Could not complete the operation</h3><p>Review the details and try again.</p><details open><summary>Details</summary><pre>${esc(event.message)}</pre></details><div class="dialog-actions"><button class="subtle-btn" id="retry-check">Retry check</button></div></section>`;
      if ($('retry-check'))
        $('retry-check').onclick = () => checkChanges(requestedKeys, $('retry-check'));
      if (previousResult) showNotice('Could not check updates', event.message);
      finishNotice();
      break;
    case 'closeBlocked':
      showNotice('Operation in progress', event.message, '', 'exit');
      break;
  }
};
function finishNotice() {
  if ($('notice').open && $('notice').dataset.kind === 'exit') {
    $('notice-title').textContent = 'Operation finished';
    $('notice-copy').textContent =
      'Homebrew is no longer running. You can close BrewPeek or review the results.';
  }
}
