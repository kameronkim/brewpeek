const toolbar = document.querySelector('.toolbar');
new ResizeObserver(() =>
  document.documentElement.style.setProperty(
    '--toolbar-height',
    `${toolbar.getBoundingClientRect().height}px`
  )
).observe(toolbar);
let brewData;
const state = {
  query: '',
  filter: 'all',
  category: 'all',
  sort: 'name',
  direction: 'asc',
  expanded: new Set()
};
let allPackages = [];
let securityFindings = new Map();
let packageSearch = new Map();
let sortedPackages = null;
const $ = (id) => document.getElementById(id);
const esc = (value) =>
  String(value ?? '—').replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]
  );
const size = (bytes) =>
  bytes == null
    ? '—'
    : bytes < 1048576
      ? (bytes / 1024).toFixed(1) + ' KiB'
      : bytes >= 1073741824
        ? (bytes / 1073741824).toFixed(2) + ' GiB'
        : (bytes / 1048576).toFixed(1) + ' MiB';
const list = (items) => (Array.isArray(items) && items.length ? items.map(esc).join('<br>') : '—');
const key = (p) => p.id || p.type + ':' + p.name;
const status = (p) => (p.type === 'cask' ? '—' : p.leaf ? 'Leaf' : 'Dependency');
const safeLink = (url) => {
  try {
    const u = new URL(url);
    return ['https:', 'http:'].includes(u.protocol)
      ? `<a href="${esc(u.href)}" target="_blank" rel="noopener noreferrer">${esc(u.href)}</a>`
      : '—';
  } catch {
    return '—';
  }
};
function highlighted(value) {
  const text = String(value ?? '—'),
    query = state.query.trim();
  if (!query) return esc(text);
  let result = '',
    offset = 0;
  const lower = text.toLowerCase(),
    q = query.toLowerCase();
  let index;
  while ((index = lower.indexOf(q, offset)) >= 0) {
    result +=
      esc(text.slice(offset, index)) +
      '<mark>' +
      esc(text.slice(index, index + query.length)) +
      '</mark>';
    offset = index + query.length;
  }
  return result + esc(text.slice(offset));
}
function matches(p, query) {
  return (
    (!query || packageSearch.get(p).includes(query)) &&
    (state.category === 'all' || p.category === state.category) &&
    (state.filter === 'all' ||
      (state.filter === 'updates' && Boolean(p.availableVersion)) ||
      state.filter === p.type ||
      (state.filter === 'leaf' && p.type === 'formula' && p.leaf) ||
      (state.filter === 'dependency' && p.type === 'formula' && !p.leaf) ||
      (state.filter === 'direct' && p.type === 'formula' && p.direct))
  );
}
function compare(a, b) {
  const get = (p) => (state.sort === 'status' ? status(p) : (p[state.sort] ?? ''));
  const v = String(get(a)).localeCompare(String(get(b)), undefined, {
    numeric: true,
    sensitivity: 'base'
  });
  return (state.direction === 'asc' ? v : -v) || a.name.localeCompare(b.name);
}
function field(label, content, wide = false) {
  return `<div class="detail-field${wide === 'full' ? ' full' : wide ? ' wide' : ''}"><dt>${label}</dt><dd>${content}</dd></div>`;
}
// Security findings come only from Homebrew's Formula scanner, independently of update availability.
const formulaIdentity = name => name.replace(/^homebrew\/core\//, '');
function securityFor(p) {
  return p.type === 'formula' ? securityFindings.get(formulaIdentity(key(p).slice(8))) : null;
}
function securityDetail(p) {
  if (p.type !== 'formula') return '';
  const check = brewData.securityCheck;
  if (!check) return '';
  const report = check.report;
  const finding = securityFor(p);
  const id = formulaIdentity(key(p).slice(8));
  const includes = names => (names || []).some(name => formulaIdentity(name) === id);
  let notes = [];
  if (check.status === 'checking') notes.push('Checking Formula security information…');
  if (check.status === 'unsupported') notes.push('This Homebrew does not support vulnerability scan coverage JSON.');
  if (check.status === 'failed') notes.push('Security check failed. Any retained findings are unconfirmed.');
  else if (check.complete === false) notes.push('Scan incomplete. Findings do not cover every installed Formula.');
  if (includes(report?.skipped_formulae)) notes.push('Not scanned: no supported source URL.');
  if (includes(report?.outdated_without_sbom)) notes.push('Installed source unknown: no SBOM for this old version. Findings may reflect the current Formula recipe.');
  const reason = Object.entries(report?.unscanned_formulae || {}).find(([name]) => formulaIdentity(name) === id)?.[1];
  if (reason) notes.push(`Not scanned: ${reason}.`);
  if (finding) {
    notes.push(`Reported version: ${finding.version}`);
    for (const [label, items] of [['Open finding', finding.vulnerabilities], ['Resolved by Formula patch', finding.patched]]) {
      for (const item of items || []) {
        notes.push(`${label}: ${item.id} · ${item.severity}${item.summary ? ' · ' + item.summary : ''}${item.fixed_versions?.length ? ' · Reported fixes: ' + item.fixed_versions.join(', ') : ''}`);
      }
    }
  } else if (report) notes.push('No finding reported for this Formula. This is not a safety guarantee.');
  return notes.length ? field('SECURITY · HOMEBREW', notes.map(esc).join('<br>'), true) : '';
}
function renderSecurityNote() {
  const check = brewData.securityCheck;
  const note = $('security-note');
  note.hidden = !check;
  if (!check) return;
  const report = check.report;
  const findings = report?.findings || [];
  const open = findings.filter(f => f.vulnerabilities?.length).length;
  const patched = findings.filter(f => f.patched?.length).length;
  let text = `Security · ${open} Formulae with open findings · ${patched} with findings resolved by Formula patches`;
  if (check.status === 'checking') text = 'Checking Formula security information…';
  else if (check.status === 'unsupported') text = 'Security check unavailable in this Homebrew version';
  else if (check.status === 'failed') text = report ? text + ' · Check failed; retained findings are unconfirmed' : 'Security check failed';
  else if (!check.complete) text += ' · Scan incomplete';
  else text += ' · Homebrew reports complete coverage';
  note.textContent = text + ' · Formulae only; Casks are not scanned. No safety guarantee.';
  note.title = [check.error, check.diagnostic].filter(Boolean).join('\n');
}
function detail(p) {
  let fields =
    field('CATEGORY', esc(p.category)) +
    field(
      'INSTALL ORIGIN',
      p.type === 'cask'
        ? 'Cask record'
        : p.direct
          ? 'Explicitly requested'
          : 'Not marked as explicitly requested'
    ) +
    field('HOMEPAGE', safeLink(p.homepage), true) +
    field('SOURCE TAP', esc(p.tap)) +
    field('DEPENDENCIES', list(p.dependencies)) +
    field('USED BY · INSTALLED FORMULAE', list(p.usedBy)) +
    field('DISK USAGE', size(p.size)) +
    field('INSTALLED PATH', list(p.paths), true) + securityDetail(p);
  if (p.type === 'cask') {
    fields += field(
      'ACTUAL APP',
      p.apps.length
        ? p.apps
            .map(
              (a) =>
                `${esc(a.version)}<br>${esc(a.path)}<br>${size(a.kib == null ? null : a.kib * 1024)}`
            )
            .join('<br>')
        : p.appExpected
          ? 'App bundle not found at the registered location'
          : 'No app bundle expected',
      'full'
    );
  }
  const actions = p.type === 'cask' || p.direct === true
    ? `<button class="subtle-btn uninstall-btn" data-uninstall="${esc(key(p))}">Uninstall</button>`
    : '';
  const versions = p.type === 'formula' && p.installedVersions?.length > 1
    ? `<button class="subtle-btn" data-version-cleanup="${esc(key(p))}">Manage versions</button>` : '';
  return `<div class="details-grid"><dl style="display:contents">${fields}</dl>${versions || actions ? `<div class="detail-actions">${versions}${actions}</div>` : ''}</div>`;
}
function row(p) {
  const id = 'detail-' + encodeURIComponent(key(p)),
    open = state.expanded.has(key(p));
  return `<tr class="package-row" data-key="${esc(key(p))}"><td><button class="package-button" aria-expanded="${open}" aria-controls="${esc(id)}"><span class="chevron" aria-hidden="true">${open ? '−' : '+'}</span><span class="package-name">${highlighted(p.name)}</span>${p.deprecated === true ? '<span class="deprecated-label">DEPRECATED</span>' : ''}${securityFor(p)?.vulnerabilities?.length ? '<span class="security-label">SECURITY REVIEW</span>' : ''}<span class="sr-only"> details</span></button><p class="description">${highlighted(p.type === 'cask' ? [p.displayName, p.description].filter(Boolean).join(' · ') : p.description)}</p></td><td class="version"><div class="version-content"><span class="installed-value" title="${esc(p.version)}">${esc(p.version)}</span>${p.availableVersion ? `<span class="available-version"><span class="available-value" title="${esc(p.availableVersion)}">Available: ${esc(p.availableVersion)}</span></span><button class="update-btn row-update" data-update="${esc(key(p))}">Update</button>` : ''}</div></td>${p.type === 'formula' ? `<td><span class="status ${p.leaf ? 'leaf' : ''}">${status(p)}</span>${p.direct ? '<span class="direct-label">DIRECT</span>' : ''}</td>` : ''}</tr><tr class="detail-row" id="${esc(id)}" ${open ? '' : 'hidden'}><td colspan="${p.type === 'formula' ? 3 : 2}">${open ? detail(p) : ''}</td></tr>`;
}
function countLabel(count, total) {
  return count === total ? `${count} total` : `${count} of ${total}`;
}
function section(type, items) {
  const title = type === 'formula' ? 'Formulae' : 'Casks',
    total = type === 'formula' ? brewData.formulae.length : brewData.casks.length;
  return `<section class="section" id="${type}"><table class="package-table ${type}" aria-label="${title}"><colgroup>${(type === 'formula' ? [54, 26, 20] : [54, 46]).map((width) => `<col style="width:${width}%">`).join('')}</colgroup><thead><tr class="section-heading-row"><th colspan="${type === 'formula' ? 3 : 2}"><div class="section-title"><h2>${title}</h2><span class="count">${countLabel(items.length, total)}</span></div></th></tr><tr class="sort-heading-row">${(type === 'formula' ? ['name', 'version', 'status'] : ['name', 'version']).map((col) => `<th scope="col" aria-sort="${state.sort === col ? (state.direction === 'asc' ? 'ascending' : 'descending') : 'none'}"><button data-sort="${col}">${col.toUpperCase()} ${state.sort === col ? (state.direction === 'asc' ? '↑' : '↓') : '↕'}</button></th>`).join('')}</tr></thead><tbody>${items.map(row).join('')}</tbody></table>${items.length ? '' : '<p class="empty">No matching packages.</p>'}</section>`;
}
function render() {
  if (
    !sortedPackages ||
    sortedPackages.sort !== state.sort ||
    sortedPackages.direction !== state.direction
  ) {
    sortedPackages = {
      sort: state.sort,
      direction: state.direction,
      items: [...allPackages].sort(compare)
    };
  }
  const query = state.query.trim().toLowerCase();
  const filtered = sortedPackages.items.filter((p) => matches(p, query));
  const visibleTypes =
    state.filter === 'cask'
      ? ['cask']
      : ['formula', 'leaf', 'dependency', 'direct'].includes(state.filter)
        ? ['formula']
        : ['formula', 'cask'];
  $('packages').innerHTML = visibleTypes
    .map((t) =>
      section(
        t,
        filtered.filter((p) => p.type === t)
      )
    )
    .join('');
  $('results').textContent =
    filtered.length === 0 ? 'No results' : countLabel(filtered.length, allPackages.length);
  document
    .querySelectorAll('[data-filter]')
    .forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.filter === state.filter)));
}
function sortBy(col, trigger) {
  const focus = captureInventoryFocus(trigger);
  state.direction = state.sort === col && state.direction === 'asc' ? 'desc' : 'asc';
  state.sort = col;
  render();
  restoreInventoryFocus(focus);
}
function renderOverview() {
  renderSecurityNote();
  const env = brewData.environment;
  $('footer-updated').textContent = 'Last updated · ' + env.updated;
  const leafCount = brewData.formulae.filter((p) => p.leaf).length;
  const directCount = brewData.formulae.filter((p) => p.direct).length;
  $('overview').innerHTML =
    `<div class="metric metric-main"><span class="metric-label">INSTALLED</span><strong>${allPackages.length}</strong><small>PACKAGES<br>ON THIS MAC</small></div><div class="metric formula-metric"><span class="metric-label">FORMULAE</span><strong>${brewData.formulae.length}</strong></div><div class="metric metric-leaf"><span class="metric-label">LEAVES</span><strong>${leafCount}</strong></div><div class="metric metric-inline"><span class="metric-label">CASKS</span><strong>${brewData.casks.length}</strong></div><div class="metric metric-inline"><span class="metric-label">TAPS</span><strong>${brewData.taps.length}</strong></div>`;
  $('overview-note').textContent =
    `${directCount} directly installed formulae · Formula disk usage ${size(env.cellarSize)}`;
  if (brewData.updateCheck?.status === 'failed')
    $('overview-note').textContent += ' · Update check unavailable';
  for (const cat of [...new Set(allPackages.map((p) => p.category))].sort()) {
    const option = document.createElement('option');
    option.value = cat;
    option.textContent = cat;
    $('category').append(option);
  }
  $('tap-count').textContent = String(brewData.taps.length);
  $('taps-list').innerHTML = brewData.taps.length
    ? brewData.taps.map((t) => `<p>${esc(t)}</p>`).join('')
    : '<p>No additional taps</p>';
  $('env').innerHTML = [
    ['Homebrew Prefix', env.prefix],
    ['Homebrew Version', env.brewVersion],
    ['Architecture', env.architecture],
    ['macOS', env.macOS + ' (' + env.build + ')'],
    ['Cellar size', size(env.cellarSize)],
    ['Caskroom size', size(env.caskSize)]
  ]
    .map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`)
    .join('');
}
$('refresh').addEventListener('click', () => {
  if (!updateBusy()) window.webkit.messageHandlers.refreshInventory.postMessage(null);
});
$('search').addEventListener('input', (event) => {
  state.query = event.target.value;
  render();
});
$('category').addEventListener('change', (event) => {
  state.category = event.target.value;
  render();
});
document.querySelector('.segments').addEventListener('click', (event) => {
  const b = event.target.closest('[data-filter]');
  if (b) {
    state.filter = b.dataset.filter;
    render();
  }
});
$('packages').addEventListener('click', (event) => {
  const sorting = event.target.closest('[data-sort]');
  if (sorting) {
    sortBy(sorting.dataset.sort, sorting);
    return;
  }
  const tr = event.target.closest('.package-row');
  if (!tr) return;
  const k = tr.dataset.key,
    p = allPackages.find((p) => key(p) === k);
  if (!p) return;
  const open = !state.expanded.has(k);
  if (open) state.expanded.add(k);
  else state.expanded.delete(k);
  tr.querySelector('button').setAttribute('aria-expanded', String(open));
  tr.querySelector('.chevron').textContent = open ? '−' : '+';
  const target = tr.nextElementSibling;
  target.hidden = !open;
  if (open) {
    target.firstElementChild.innerHTML = detail(p);
    syncActionAvailability();
  }
});
window.setInventory = function (data) {
  brewData = data;
  securityFindings = new Map((data.securityCheck?.report?.findings || []).map(f => [formulaIdentity(f.formula), f]));
  allPackages = [...data.formulae, ...data.casks];
  // Snapshot replacement also invalidates cached metadata and package order.
  packageSearch = new Map(
    allPackages.map((p) => [
      p,
      [p.name, p.displayName, p.description, p.category, p.tap].join(' ').toLowerCase()
    ])
  );
  sortedPackages = null;
  const updates = $('updates-filter');
  const updateCount = allPackages.filter((p) => Boolean(p.availableVersion)).length;
  updates.hidden = updateCount === 0;
  updates.textContent = `Updates ${updateCount}`;
  if (!updateCount && state.filter === 'updates') state.filter = 'all';

  const category = $('category');
  category.innerHTML = '<option value="all">All categories</option>';
  renderOverview();
  if ([...category.options].some((o) => o.value === state.category))
    category.value = state.category;
  else {
    state.category = 'all';
    category.value = 'all';
  }
  render();
};

// Only patch security information; preserve package selection, filters, focus and scroll.
window.setSecurityCheck = function (report, snapshotID) {
  if (brewData?.snapshotID !== snapshotID) return;
  const view = captureInventoryView();
  brewData.securityCheck = report;
  securityFindings = new Map((report.report?.findings || []).map(f => [formulaIdentity(f.formula), f]));
  renderSecurityNote();
  render();
  restoreInventoryView(view);
};
