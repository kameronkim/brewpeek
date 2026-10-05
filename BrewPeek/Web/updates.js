// Native Homebrew package operations. No package changes are simulated in this bundle.
let updateMode = 'ready',
  updatePlan = null,
  requestedKeys = [],
  previousResult = null;
let activeRequest = null;
let operationKind = 'update';
let cleanupTaskID = null;
let processedPackages = 0;
let popupScroll = null,
  activity = [],
  activitySizes = [],
  activityBytes = 0,
  activityDirty = false,
  progressPackages = [],
  progressStates = {};
let popupReturnFocus = null;
let pendingCancelFocus = null;
let operationScrollPending = false;
const updateBusy = () =>
  ['checking', 'cancelling', 'running', 'verifying', 'confirming', 'recovering'].includes(updateMode);
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
    .querySelectorAll('[data-update], [data-uninstall], [data-retry], #retry-check, #retry-plan, #retry-cleanup, #discard-cleanup')
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
$('notice').addEventListener('close', () => {
  if ($('notice').open) return;
  for (const id of ['notice-title', 'notice-copy', 'notice-command']) $(id).textContent = '';
});
function checkChanges(keys, trigger = document.activeElement, operation = 'update') {
  if (updateBusy() || inventoryRefreshState !== 'idle' || !keys.length) return;
  if (!popupScroll) popupReturnFocus = captureInventoryFocus(trigger);
  operationKind = operation;
  requestedKeys = keys;
  activeRequest = crypto.randomUUID();
  showChecking();
  postUpdate({ action: operationKind === 'uninstall' ? 'prepareUninstall' : 'prepare', keys, requestID: activeRequest });
}
function setConfirmState(mode) {
  delete $('confirm').dataset.issue;
  $('confirm').dataset.operation = operationKind;
  document.querySelector('.confirm-heading .eyebrow').textContent = operationKind.startsWith('cleanup') ? 'DEPENDENCY CLEANUP' : operationKind === 'uninstall' ? 'PACKAGE UNINSTALL' : 'PACKAGE UPDATE';
  $('start').textContent = operationKind === 'uninstall' ? 'Uninstall' : 'Update';
  document.querySelector('.confirm-bottom > p').textContent = operationKind === 'uninstall' ? 'Settings and support files may remain.' : 'Homebrew may also update related packages.';
  document.querySelector('.confirm-scroll').setAttribute('aria-label', operationKind === 'uninstall' ? 'Packages to uninstall' : 'Packages to update');
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
    operationKind.startsWith('cleanup') ? 'Checking remaining dependencies. No cleanup has started.' : operationKind === 'uninstall'
      ? 'Checking the installed package and its dependencies. No uninstallation has started.'
      : 'Checking selected packages and dependencies. No installation has started.';
  setConfirmState('checking');
  $('confirm-title').focus({ preventScroll: true });
}
function showCheckError(message, runningApps = []) {
  updatePlan = null;
  setUpdateMode('check-failed');
  setConfirmState('check-failed');
  if (runningApps.length) {
    $('confirm').dataset.issue = 'running-apps';
    $('confirm-title').textContent = 'Close apps to continue';
    $('confirm-copy').textContent = `Quit the apps below, then retry the ${operationKind === 'uninstall' ? 'uninstall' : 'update'}.`;
    $('confirm-error').innerHTML =
      `<ul class="running-apps" aria-label="Apps to close">${runningApps.map((name) => `<li><strong>${esc(name)}</strong><span>Running</span></li>`).join('')}</ul>`;
  } else {
    $('confirm-title').textContent = operationKind.startsWith('cleanup') ? 'Could not prepare cleanup' : operationKind === 'uninstall' ? 'Could not prepare uninstall' : 'Could not check updates';
    $('confirm-copy').textContent = 'Review the details and try again.';
    $('confirm-error').innerHTML = `<pre>${esc(message)}</pre>`;
  }
  $('retry-plan').focus({ preventScroll: true });
}
$('retry-plan').onclick = () => operationKind.startsWith('cleanup') ? checkCleanup($('retry-plan')) : checkChanges(requestedKeys, $('retry-plan'), operationKind);
function showPlan(plan, changed) {
  updatePlan = plan;
  operationKind = plan.operation || 'update';
  setUpdateMode('confirming');
  setConfirmState('confirming');
  const cleanup = operationKind === 'cleanup';
  document.querySelector('.confirm-table th:nth-child(3)').textContent = cleanup ? 'Status' : 'New';
  if (cleanup) {
    $('confirm-title').textContent = plan.packages.length ? 'Remove remaining dependencies?' : 'No dependencies to remove';
    $('confirm-copy').textContent = (changed ? 'The plan changed. Review it before continuing. ' : '') + `${plan.rootName} is already uninstalled. ${plan.packages.length} unused dependencies are ready to remove.`;
    $('confirm-list').innerHTML = [...plan.packages, ...(plan.kept || [])].map(p => `<tr><td>${esc(p.name)}<small class="dependency-note">${esc(p.message || p.relationship || p.reason)}</small></td><td>${esc(p.version)}</td><td>${esc(p.status)}</td></tr>`).join('');
    $('start').textContent = plan.packages.length ? 'Remove dependencies' : 'Finish review';
    document.querySelector('.confirm-bottom > p').textContent = 'Shared, directly installed, pinned, and changed installations are kept.';
    document.querySelector('.confirm-scroll').scrollTop = 0;
    $('confirm-title').focus({ preventScroll: true });
    return;
  }
  $('confirm-title').textContent =
    operationKind === 'uninstall'
      ? `Uninstall ${plan.packages[0].name}?`
      : plan.selectedCount === 1 ? 'Update package?' : `Update ${plan.selectedCount} packages?`;
  $('confirm-copy').textContent =
    (changed ? 'The plan changed. Review it before continuing. ' : '') +
    (operationKind === 'uninstall' ? `Homebrew will uninstall this ${plan.packages[0].type === 'cask' ? 'Cask' : 'Formula'}${plan.packages.length > 1 ? ` and remove ${plan.packages.length - 1} unused ${plan.packages.length === 2 ? 'dependency' : 'dependencies'}` : ''}. Shared and directly installed dependencies are kept.` : `${plan.selectedCount} selected · ${plan.packages.length - plan.selectedCount} additional changes.`) +
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
$('confirm').addEventListener('close', () => {
  if ($('confirm').open) return;
  $('confirm-list').replaceChildren();
  $('confirm-error').replaceChildren();
});
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
  postUpdate({ action: operationKind === 'cleanup-discard' ? 'discardCleanup' : operationKind === 'cleanup' ? 'startCleanup' : operationKind === 'uninstall' ? 'startUninstall' : 'start', token, recoveryID: cleanupTaskID, requestID: activeRequest });
};
$('packages').addEventListener(
  'click',
  (event) => {
    const button = event.target.closest('[data-update], [data-uninstall]');
    if (!button) return;
    event.stopImmediatePropagation();
    checkChanges([button.dataset.uninstall || button.dataset.update], button, button.hasAttribute('data-uninstall') ? 'uninstall' : 'update');
  },
  true
);
bulk.onclick = () => checkChanges(allPackages.filter((p) => p.availableVersion).map(key), bulk);
const activityByteLimit = 1_000_000;
const activityEncoder = new TextEncoder();
const activityDecoder = new TextDecoder();
function appendActivity(line) {
  let bytes = activityEncoder.encode(line);
  if (bytes.length > activityByteLimit) {
    let start = bytes.length - activityByteLimit;
    while ((bytes[start] & 0xc0) === 0x80) start++;
    bytes = bytes.subarray(start);
    line = activityDecoder.decode(bytes);
  }
  activity.push(line);
  // Count the separator too; the final entry has no trailing newline.
  activitySizes.push(bytes.length + 1);
  activityBytes += bytes.length + 1;
  while (activity.length > 1500 || activityBytes - 1 > activityByteLimit) {
    activityBytes -= activitySizes.shift();
    activity.shift();
  }
  activityDirty = true;
}
function paintActivity() {
  const log = $('activity-log');
  if (!activityDirty || !log || !$('progress-log').open) return;
  const bottom = log.scrollHeight - log.scrollTop - log.clientHeight < 30;
  log.textContent = activity.join('\n');
  activityDirty = false;
  if (bottom) log.scrollTop = log.scrollHeight;
}
function clearProgressData() {
  activity = [];
  activitySizes = [];
  activityBytes = 0;
  activityDirty = false;
  progressPackages = [];
  progressStates = {};
  processedPackages = 0;
}
function beginProgress(plan) {
  previousResult = null;
  operationKind = plan.operation || 'update';
  clearProgressData();
  progressPackages = plan.packages;
  setUpdateMode('running');
  $('operation').innerHTML =
    `<section class="operation" data-operation="${operationKind}"><div class="operation-top"><div><div class="eyebrow" id="operation-phase">${operationKind === 'cleanup' ? 'CLEANUP IN PROGRESS' : operationKind === 'uninstall' ? 'UNINSTALL IN PROGRESS' : 'UPDATE IN PROGRESS'}</div><h3><span class="pulse"></span><span id="operation-title">${operationKind === 'cleanup' ? 'Removing unused dependencies' : operationKind === 'uninstall' ? `Uninstalling ${esc(plan.packages[0].name)}` : 'Updating packages'}</span></h3><p id="operation-copy">${operationKind === 'cleanup' ? 'Homebrew is removing the confirmed remaining dependencies.' : operationKind === 'uninstall' ? 'Homebrew is removing the selected package and any confirmed unused dependencies.' : 'Homebrew controls parallel downloads and installation order.'}</p></div></div><div class="progress-summary"><span>Packages processed · including dependencies</span><span id="processed">0 of ${progressPackages.length}</span></div><div class="progress-track"><div class="progress-fill" id="overall-fill"></div></div><p id="discovered" hidden>Additional related changes detected. The total includes these packages.</p><details id="progress-items"><summary id="progress-count"></summary><div class="bounded-list" id="progress-rows"></div></details><details id="progress-log"><summary>Show activity</summary><pre id="activity-log"></pre></details></section>`;
  $('progress-items').ontoggle = () => paintProgress();
  $('progress-log').ontoggle = paintActivity;
  paintProgress(0);
  scrollOperationIntoView();
}
function setProgressText(element, text) {
  if (element.textContent === text) return false;
  element.textContent = text;
  return true;
}
function paintProgress(processed = processedPackages) {
  processedPackages = processed;
  if (!$('progress-rows')) return;
  const fill = $('overall-fill');
  if (
    setProgressText($('processed'), `${processed} of ${progressPackages.length}`) ||
    !fill.style.width
  )
    fill.style.width = `${progressPackages.length ? (processed / progressPackages.length) * 100 : 0}%`;
  setProgressText($('progress-count'), `Package details · ${progressPackages.length}`);
  const undiscovered = !progressPackages.some((p) => p.reason === 'Detected during execution');
  if ($('discovered').hidden !== undiscovered) $('discovered').hidden = undiscovered;
  // Keep the latest state in memory; collapsed details catch up when opened.
  if (!$('progress-items').open) return;
  const container = $('progress-rows');
  const rows = new Map([...container.children].map((node) => [node.dataset.package, node]));
  for (const p of progressPackages) {
    let row = rows.get(p.id);
    if (!row) {
      row = document.createElement('div');
      row.className = 'download-item';
      row.dataset.package = p.id;
      row.innerHTML = `<span>${esc(p.name)}<small class="dependency-note">${esc(p.relationship || p.reason)}</small></span><div class="progress-track"><div class="progress-fill"></div></div><span class="download-state"></span>`;
      container.append(row);
      rows.set(p.id, row);
    }
    setProgressText(row.querySelector('.dependency-note'), p.relationship || p.reason);
    const text =
      updateMode === 'verifying'
        ? (['uninstall', 'cleanup'].includes(operationKind) ? 'Verifying package registration…' : 'Verifying installed version…')
        : progressStates[p.id] || (['uninstall', 'cleanup'].includes(operationKind) ? 'Uninstalling…' : 'Waiting for Homebrew');
    const fill = row.querySelector('.progress-fill');
    if (setProgressText(row.querySelector('.download-state'), text) || !fill.style.width) {
      row
        .querySelector('.progress-track')
        .classList.toggle(
          'indeterminate',
          !['Waiting for Homebrew', 'Awaiting verification'].includes(text)
        );
      fill.style.width = text === 'Awaiting verification' ? '100%' : '0%';
    }
  }
}
function paintResult(result) {
  const uninstall = result.operation === 'uninstall';
  if (result.recoveryID) cleanupTaskID = result.recoveryID;
  const pending = !!result.pendingCleanup;
  const recoveryTitle = result.recovered ? (pending ? 'Unfinished cleanup' : result.recoveryID ? 'Unfinished uninstall' : 'Cleanup complete') : null;
  const counts = {};
  result.packages.forEach((p) => (counts[p.outcome] = (counts[p.outcome] || 0) + 1));
  const summary = Object.entries(counts)
    .map(([type, count]) => `${count} ${type === 'attention' ? 'need attention' : type}`)
    .join(' · ');
  const issues = result.packages.filter((p) => !['updated', 'installed', 'uninstalled', 'kept'].includes(p.outcome));
  $('operation').innerHTML =
    `<section class="operation"><div class="operation-top"><div><div class="eyebrow">${uninstall ? 'UNINSTALL RESULTS' : 'UPDATE RESULTS'}</div><h3>${esc(recoveryTitle || summary)}</h3><p>${uninstall ? (result.verified ? 'Homebrew package registrations checked.' : 'Package registrations could not be checked.') : (result.verified ? 'Installed versions checked.' : 'Installed versions could not be checked.')}${result.refreshError ? ' Inventory refresh failed; use Refresh to try again.' : ''}</p></div><button class="subtle-btn" id="dismiss">Close results</button></div>${result.recovered ? '<p>Current Homebrew registrations checked. Nothing has resumed automatically.</p>' : ''}${result.recoveryID ? `<div class="dialog-actions recovery-actions">${pending ? '<button class="subtle-btn" id="retry-cleanup">Retry cleanup</button>' : ''}<button class="subtle-btn" id="discard-cleanup">Discard pending cleanup</button></div>${pending ? '<p>Remaining dependencies are checked again before removal. The task stays saved if the app closes.</p>' : ''}` : ''}${issues.length ? `<div class="issues">${issues.map((p) => `<div class="issue-item"><div><strong>${esc(p.name)}</strong><p>${esc(p.message)}</p></div>${!uninstall || (p.id === result.packages[0].id && p.actualVersion !== 'Not installed') ? `<button class="subtle-btn" data-retry="${esc(p.id)}">Retry</button>` : ''}</div>`).join('')}</div>` : ''}<details><summary>All results · ${result.packages.length}</summary><ul class="result-list bounded-list">${result.packages.map((p) => `<li>${esc(p.name)}<span>${esc(p.message)}<small class="dependency-note">${uninstall ? 'Registration' : 'Installed'}: ${esc(p.actualVersion)}</small></span></li>`).join('')}</ul></details><details><summary>Show activity</summary><pre>${esc(result.details || '')}${result.refreshError ? '\n' + esc(result.refreshError) : ''}</pre></details>${issues.length && result.command ? '<div class="dialog-actions"><button class="subtle-btn" id="terminal-help">View Terminal command</button></div>' : ''}</section>`;
  if ($('retry-cleanup')) $('retry-cleanup').onclick = () => checkCleanup($('retry-cleanup'));
  if ($('discard-cleanup')) $('discard-cleanup').onclick = () => confirmDiscardCleanup($('discard-cleanup'));
  $('dismiss').onclick = () => {
    const view = captureInventoryView();
    previousResult = null;
    requestedKeys = [];
    activeRequest = null;
    $('operation').replaceChildren();
    setUpdateMode('ready');
    restoreInventoryView(view);
  };
  document.querySelectorAll('[data-retry]').forEach(
    (button) =>
      (button.onclick = () => {
        const item = allPackages.find((p) => key(p) === button.dataset.retry && (uninstall ? p.id === result.packages[0].id : p.availableVersion));
        checkChanges(item ? [key(item)] : result.retryKeys || requestedKeys, button, uninstall ? 'uninstall' : 'update');
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
    case 'recoveryChecking':
      setUpdateMode('recovering');
      break;
    case 'recoveryEmpty':
      setUpdateMode(previousResult ? 'result' : 'ready');
      break;
    case 'recoveryError':
      setUpdateMode(previousResult ? 'result' : 'ready');
      showNotice('Could not restore cleanup', event.message);
      break;
    case 'cleanupDiscarded':
      $('confirm').close();
      updatePlan = null; activeRequest = null; cleanupTaskID = null;
      if (previousResult) {
        delete previousResult.recoveryID; delete previousResult.pendingCleanup; delete previousResult.recovered;
        paintResult(previousResult);
      }
      setUpdateMode(previousResult ? 'result' : 'ready');
      break;
    case 'checking':
      if (event.operation) operationKind = event.operation;
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
      if (event.states) progressStates = event.states;
      appendActivity(event.line);
      paintActivity();
      if (event.packages || event.states || event.processed !== undefined)
        paintProgress(event.processed);
      break;
    }
    case 'verifying':
      setUpdateMode('verifying');
      $('operation-phase').textContent = 'VERIFYING RESULTS';
      $('operation-title').textContent = ['uninstall', 'cleanup'].includes(operationKind) ? 'Checking package registrations' : 'Checking installed versions';
      $('operation-copy').textContent = ['uninstall', 'cleanup'].includes(operationKind) ? 'Confirming removal before reporting success.' : 'Confirming actual versions before reporting success.';
      paintProgress();
      break;
    case 'result': {
      const view = captureInventoryView();
      // The inventory owns the snapshot; retained results only need display and retry data.
      const { snapshot, ...result } = event;
      updatePlan = null;
      activeRequest = null;
      clearProgressData();
      previousResult = result;
      setUpdateMode('result');
      if (snapshot) window.setInventory(snapshot);
      paintResult(result);
      restoreInventoryView(view);
      syncActionAvailability();
      finishNotice();
      if (!result.recovered) scrollOperationIntoView();
      break;
    }
    case 'error':
      clearProgressData();
      if (['checking', 'confirming', 'check-failed'].includes(updateMode)) {
        showCheckError(event.message, event.runningApps);
        break;
      }
      updatePlan = null;
      activeRequest = null;
      setUpdateMode(previousResult ? 'result' : 'ready');
      if (previousResult) paintResult(previousResult);
      else
        $('operation').innerHTML =
          `<section class="operation"><div class="eyebrow">${operationKind === 'uninstall' ? 'UNINSTALL UNAVAILABLE' : 'UPDATE UNAVAILABLE'}</div><h3>Could not complete the operation</h3><p>Review the details and try again.</p><details open><summary>Details</summary><pre>${esc(event.message)}</pre></details><div class="dialog-actions"><button class="subtle-btn" id="retry-check">Retry check</button></div></section>`;
      if ($('retry-check'))
        $('retry-check').onclick = () => operationKind.startsWith('cleanup') ? checkCleanup($('retry-check')) : checkChanges(requestedKeys, $('retry-check'), operationKind);
      if (previousResult) showNotice(operationKind === 'uninstall' ? 'Could not uninstall package' : 'Could not check updates', event.message);
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

function checkCleanup(trigger = document.activeElement) {
  if (!cleanupTaskID || updateBusy() || inventoryRefreshState !== 'idle') return;
  if (!popupScroll) popupReturnFocus = captureInventoryFocus(trigger);
  operationKind = 'cleanup'; requestedKeys = [];
  activeRequest = crypto.randomUUID();
  showChecking('Checking remaining dependencies…');
  postUpdate({action: 'prepareCleanup', recoveryID: cleanupTaskID, requestID: activeRequest});
}
function confirmDiscardCleanup(trigger) {
  if (!cleanupTaskID || updateBusy()) return;
  if (!popupScroll) popupReturnFocus = captureInventoryFocus(trigger);
  operationKind = 'cleanup-discard';
  updatePlan = {token: cleanupTaskID};
  setUpdateMode('confirming'); setConfirmState('confirming');
  $('confirm-title').textContent = 'Discard pending cleanup?';
  $('confirm-copy').textContent = 'This removes the saved cleanup task. Installed packages stay on this Mac.';
  document.querySelector('.confirm-scroll').hidden = true;
  document.querySelector('.confirm-bottom > p').hidden = true;
  $('start').textContent = 'Discard task';
  $('confirm-title').focus({preventScroll: true});
}
