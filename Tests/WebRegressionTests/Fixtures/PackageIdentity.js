window.assert=(ok,message)=>{if(!ok)throw Error(message)};
inventoryRefreshState='idle';
const original=JSON.stringify(fixtures);
const expected={
  triple:['Formula · alpha/tools · Selected','Formula · beta/tools · Selected','Cask · homebrew/cask · Selected'],
  kinds:['Formula · homebrew/core · Selected','Cask · homebrew/cask · Selected'],
  taps:['Formula · alpha/tools · Selected','Formula · beta/tools · Selected'],
  single:['Selected'], relationship:['Uses sdk']
};
for(const [name,packages] of Object.entries(fixtures)) {
  showPlan({token:'fixture',selectedCount:packages.length,packages,excluded:[]});
  const notes=[...document.querySelectorAll('#confirm-list .dependency-note')].map(n=>n.textContent);
  assert(JSON.stringify(notes)===JSON.stringify(expected[name]),name+' confirmation identity');
  const rows=[...document.querySelectorAll('#confirm-list tr')];
  assert(rows.every(row=>row.cells[1].textContent==='1.0' && row.cells[2].textContent==='2.0'), 'Versions unchanged');
  $('confirm').close();
  beginProgress({token:'fixture',packages});
  $('progress-items').open=true;
  progressStates=Object.fromEntries(packages.map((p,i)=>[p.id,['Downloading…','Installing…','Waiting for Homebrew'][i]]));
  paintProgress();
  const progress=[...document.querySelectorAll('#progress-rows .download-item')];
  assert(JSON.stringify(progress.map(row=>row.querySelector('.dependency-note').textContent))===JSON.stringify(expected[name]),name+' progress identity');
  assert(progress.every((row,i)=>row.dataset.package===packages[i].id && row.querySelector('.download-state').textContent===progressStates[packages[i].id]),name+' exact state keys preserved');
}
assert(JSON.stringify(fixtures)===original,'Display helper must not modify package data');
beginProgress({packages:[fixtures.triple[0]]}); $('progress-items').open=true; paintProgress();
const existing=$('progress-rows').firstElementChild;
assert(existing.querySelector('.dependency-note').textContent==='Selected','Initial unique row stays compact');
progressPackages=[...fixtures.triple];paintProgress();
assert($('progress-rows').firstElementChild===existing,'Dynamic collision preserves existing keyed row');
assert(existing.querySelector('.dependency-note').textContent===expected.triple[0],'Previously unique row gains identity');
const injection=fixtures.taps.map(p=>({...p}));injection[0].id='formula:alpha/<img src=x onerror=alert(1)>/demo';
showPlan({token:'escaped',selectedCount:2,packages:injection,excluded:[]});
assert(!document.querySelector('#confirm-list img'),'Tap label is escaped');
$('confirm').close();beginProgress({packages:injection});$('progress-items').open=true;paintProgress();
assert(!document.querySelector('#progress-rows img'),'Progress label is escaped');
window.checkNarrowIdentity=()=>{
showPlan({token:'narrow',selectedCount:3,packages:fixtures.triple,excluded:[]});
assert(document.querySelector('.confirm-scroll').scrollWidth<=document.querySelector('.confirm-scroll').clientWidth+1,'Narrow confirmation does not gain horizontal overflow');
assert([...document.querySelectorAll('#confirm-list .dependency-note')].map(n=>n.textContent).join('|')===expected.triple.join('|'),'Narrow confirmation retains identities');
$('confirm').close(); beginProgress({packages:fixtures.triple}); $('progress-items').open=true;paintProgress();
assert($('progress-rows').scrollWidth<=$('progress-rows').clientWidth+1,'Narrow progress does not gain horizontal overflow');
};
return true;
