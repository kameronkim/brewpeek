// Preserve the reading position while replacing a snapshot, including removed rows.
let inventoryRefreshState = 'refreshing';
function captureInventoryFocus(element = document.activeElement) {
  if (!element || element === document.body) return null;
  const row = element.closest('.package-row');
  return {
    element,
    id: element.id,
    key: row?.dataset.key,
    update: element.hasAttribute('data-update'),
    sort: element.dataset.sort,
    section: element.closest('.section')?.id
  };
}
function restoreInventoryFocus(focus, fallback) {
  if (!focus) return;
  let element = focus.element.isConnected ? focus.element : focus.id ? $(focus.id) : null;
  if (focus.key && (!element || element.disabled)) {
    const row = [...document.querySelectorAll('.package-row')].find(
      (r) => r.dataset.key === focus.key
    );
    element = focus.update ? row?.querySelector('[data-update]:not(:disabled)') : null;
    element ||= row?.querySelector('.package-button');
  }
  if (!element && focus.sort) {
    const section = focus.section ? $(focus.section) : document;
    element = section?.querySelector(`[data-sort="${CSS.escape(focus.sort)}"]`);
  }
  if (!element || element.disabled || !element.getClientRects().length)
    element = fallback || $('search');
  element?.focus({ preventScroll: true });
}
function captureInventoryView() {
  const toolbarBottom = document.querySelector('.toolbar').getBoundingClientRect().bottom;
  const headers = [...document.querySelectorAll('.package-table thead')].map((h) =>
    h.getBoundingClientRect()
  );
  const top = Math.max(
    toolbarBottom,
    ...headers.filter((h) => h.top <= toolbarBottom + 1).map((h) => h.bottom)
  );
  const rows = [...document.querySelectorAll('.package-row')];
  // An expanded detail may occupy the viewport while its parent row is above it.
  const visible = (row) => {
    const end = row.nextElementSibling?.hidden === false ? row.nextElementSibling : row;
    return (
      end.getBoundingClientRect().bottom > top && row.getBoundingClientRect().top < innerHeight
    );
  };
  const focused = document.activeElement?.closest('.package-row');
  const index = focused && visible(focused) ? rows.indexOf(focused) : rows.findIndex(visible);
  const anchors =
    index < 0
      ? []
      : rows
          .slice(index)
          .concat(rows.slice(0, index).reverse())
          .map((row) => ({ key: row.dataset.key, top: row.getBoundingClientRect().top }));
  return {
    x: scrollX,
    y: scrollY,
    anchors: scrollY > 0 ? anchors : [],
    focus: captureInventoryFocus()
  };
}
function restoreInventoryView(view) {
  const rows = new Map(
    [...document.querySelectorAll('.package-row')].map((r) => [r.dataset.key, r])
  );
  const anchor = view.anchors.find((a) => rows.has(a.key));
  const row = anchor && rows.get(anchor.key);
  scrollTo(view.x, row ? scrollY + row.getBoundingClientRect().top - anchor.top : view.y);
  restoreInventoryFocus(view.focus, row?.querySelector('.package-button'));
}
function refreshInventoryStatus() {
  const updated = brewData.environment?.updated;
  const suffix =
    inventoryRefreshState === 'refreshing'
      ? ' · Refreshing…'
      : inventoryRefreshState === 'failed'
        ? ' · Refresh failed — showing saved data'
        : '';
  if (updated) $('footer-updated').textContent = 'Last updated · ' + updated + suffix;
  $('refresh').classList.toggle('refreshing', inventoryRefreshState === 'refreshing');
  $('refresh').setAttribute('aria-busy', String(inventoryRefreshState === 'refreshing'));
  $('refresh').title =
    inventoryRefreshState === 'refreshing' ? 'Refreshing inventory…' : 'Refresh (⌘R)';
}
window.setRefreshState = function (value) {
  inventoryRefreshState = value;
  refreshInventoryStatus();
  syncActionAvailability();
};
const replaceInventory = window.setInventory;
window.setInventory = function (data) {
  const view = captureInventoryView();
  replaceInventory(data);
  refreshInventoryStatus();
  restoreInventoryView(view);
};
window.focusPackageSearch = function () {
  if (document.querySelector('dialog[open]')) return;
  $('search').focus({ preventScroll: true });
  $('search').select();
};
document.addEventListener('keydown', (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') {
    event.preventDefault();
    window.focusPackageSearch();
  }
});
