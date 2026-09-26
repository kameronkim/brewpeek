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
function matches(p) {
  const q = state.query.trim().toLowerCase();
  const search = [p.name, p.displayName, p.description, p.category, p.tap].join(' ').toLowerCase();
  return (
    (!q || search.includes(q)) &&
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
  return `<div class="detail-field${wide ? ' wide' : ''}"><dt>${label}</dt><dd>${content}</dd></div>`;
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
    field('INSTALLED PATH', list(p.paths), true);
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
          : 'No app bundle expected'
    );
  }
  return `<div class="details-grid"><dl style="display:contents">${fields}</dl></div>`;
}
function row(p) {
  const id = 'detail-' + encodeURIComponent(key(p)),
    open = state.expanded.has(key(p));
  return `<tr class="package-row" data-key="${esc(key(p))}"><td><button class="package-button" aria-expanded="${open}" aria-controls="${esc(id)}"><span class="chevron" aria-hidden="true">${open ? '−' : '+'}</span><span>${highlighted(p.name)}</span><span class="sr-only"> details</span></button><p class="description">${highlighted(p.type === 'cask' ? [p.displayName, p.description].filter(Boolean).join(' · ') : p.description)}</p></td><td class="version"><div class="version-content"><span class="installed-value" title="${esc(p.version)}">${esc(p.version)}</span>${p.availableVersion ? `<span class="available-version"><span class="available-value" title="${esc(p.availableVersion)}">Available: ${esc(p.availableVersion)}</span></span><button class="update-btn row-update" data-update="${esc(key(p))}">Update</button>` : ''}</div></td>${p.type === 'formula' ? `<td><span class="status ${p.leaf ? 'leaf' : ''}">${status(p)}</span>${p.direct ? '<span class="direct-label">DIRECT</span>' : ''}</td>` : ''}</tr><tr class="detail-row" id="${esc(id)}" ${open ? '' : 'hidden'}><td colspan="${p.type === 'formula' ? 3 : 2}">${open ? detail(p) : ''}</td></tr>`;
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
  const filtered = allPackages.filter(matches).sort(compare);
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
  if (open) target.firstElementChild.innerHTML = detail(p);
});
window.setInventory = function (data) {
  brewData = data;
  allPackages = [...data.formulae, ...data.casks];
  const updates = $('updates-filter');
  const updateCount = allPackages.filter((p) => Boolean(p.availableVersion)).length;
  updates.hidden = updateCount === 0;
  updates.textContent = `Updates ${updateCount}`;
  if (!updateCount && state.filter === 'updates') {
    state.filter = 'all';
    if (document.activeElement === updates) document.querySelector('[data-filter="all"]').focus();
  }

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
