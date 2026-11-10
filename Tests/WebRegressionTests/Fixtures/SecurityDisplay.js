return (() => {
  const assert = (ok, message) => { if (!ok) throw Error(message); };
  const pkg = (name, type='formula') => ({id:type+':'+name, name, type, version:'1', availableVersion:'2', description:'fixture', category:'Other', paths:[], dependencies:[], usedBy:[], apps:[], installedVersions:['1']});
  const vuln = {id:'<img src=x onerror=alert(1)>', severity:'HIGH', summary:'<script>bad</script>', aliases:[], fixed_versions:['2']};
  const data = {formulae:[pkg('alpha'), pkg('vendor/tools/alpha'), pkg('patched')], casks:[pkg('alpha','cask')], taps:[], environment:{updated:'fixture',cellarSize:0}, updateCheck:{status:'succeeded'}, securityCheck:{scope:'formulae',status:'incomplete',complete:false,report:{checked:2,complete:false,skipped_formulae:[],outdated_without_sbom:['alpha'],unscanned_formulae:{'other':'resolution_error'},findings:[{formula:'homebrew/core/alpha',version:'1',vulnerabilities:[vuln],patched:[]},{formula:'patched',version:'1',vulnerabilities:[],patched:[vuln]}]}}};
  setInventory(data);
  inventoryRefreshState = 'idle'; syncActionAvailability();
  assert(document.querySelectorAll('.security-label').length === 1, 'Only the matched Formula gets a review label');
  assert(!securityFor(data.formulae[1]) && !securityFor(data.casks[0]), 'Tap and Cask identities stay separate');
  assert(document.getElementById('security-note').textContent.includes('Scan incomplete'), 'Coverage warning visible');
  assert(document.getElementById('security-note').textContent.includes('Casks are not scanned'), 'Scope visible');
  assert(detail(data.formulae[0]).includes('Installed source unknown'), 'SBOM warning visible');
  assert(detail(data.formulae[2]).includes('Resolved by Formula patch'), 'Patch resolution distinct');
  assert(detail(data.formulae[0]).includes('&lt;img') && !detail(data.formulae[0]).includes('<script>bad'), 'OSV text escaped');
  assert(document.querySelectorAll('[data-update]').length === 4, 'Normal update actions unchanged');
  showPlan({token:'fixture',selectedCount:1,packages:[{name:'alpha',version:'1',availableVersion:'2'}],excluded:[]});
  assert(document.getElementById('confirm').open && updateMode === 'confirming', 'Original confirmation flow intact');
  document.getElementById('confirm').close();
  for (const status of ['failed','unsupported']) {
    data.securityCheck = {scope:'formulae',status}; setInventory(data);
    assert(document.querySelectorAll('[data-update]').length === 4, 'Security failure/unsupported must not remove ordinary updates');
    assert(!document.querySelector('.security-label'), 'Old findings cleared on refresh');
  }
  data.snapshotID = 'new-inventory';
  data.securityCheck = {scope:'formulae',status:'checking'}; setInventory(data);
  assert(document.getElementById('security-note').textContent.includes('Checking Formula'), 'Pending scan has a dedicated label');
  const completed = {scope:'formulae',status:'succeeded',complete:true,report:{checked:3,findings:[{formula:'alpha',version:'1',vulnerabilities:[vuln],patched:[]}]}};
  setSecurityCheck(completed, 'old-inventory', 1);
  assert(brewData.securityCheck.status === 'checking' && !document.querySelector('.security-label'), 'Stale result must not replace a new inventory');
  state.expanded.add('formula:alpha'); render();
  const search = document.getElementById('search'); search.focus();
  setSecurityCheck(completed, 'new-inventory', 2);
  assert(document.querySelector('.security-label') && state.expanded.has('formula:alpha'), 'Current result patches labels while preserving expanded rows');
  assert(document.activeElement === search, 'Security refresh preserves user focus');
  assert(document.querySelectorAll('[data-update]').length === 4, 'Security-only update leaves action availability unchanged');
  delete data.securityCheck; setInventory(data);
  assert(document.getElementById('security-note').hidden, 'Legacy snapshot has no invented security result');
  data.securityCheck = {scope:'formulae',status:'succeeded',complete:true,report:{checked:3,findings:[]}}; setInventory(data);
  assert(!/all.*safe|secure packages|vulnerability.free/i.test(document.getElementById('security-note').textContent), 'No global safety assertion');
  return 'PASS WebKit findings/patch/SBOM/scope, identity separation, escaped text, retained Update confirmation, unsupported/failure fallback and legacy refresh';
})()
