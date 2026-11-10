return (() => {
  const assert=(ok,message)=>{if(!ok)throw Error(message)};
  const pkg=versions=>({id:'formula:demo',name:'demo',type:'formula',version:versions.join(', '),installedVersions:versions,description:'fixture',category:'Other',paths:[],dependencies:[],usedBy:[],apps:[]});
  const vulnerability={id:'CVE-fixture',severity:'HIGH',summary:'fixture only',aliases:[],fixed_versions:[]};
  for(const versions of [['1.0'],['1.0','2.0']]) for(const status of ['succeeded','incomplete','failed']) for(const found of [false,true]) {
    const p=pkg(versions),multi=versions.length>1;
    const report={checked:1,complete:status!=='incomplete',findings:found?[{formula:'demo',version:'1.0',vulnerabilities:[vulnerability],patched:[]}]:[],skipped_formulae:[],outdated_without_sbom:[],unscanned_formulae:{}};
    
    const input={formulae:[p],casks:[],taps:[],environment:{},securityCheck:{scope:'formulae',status,complete:report.complete,report}};
  const before=JSON.stringify(input);
  setInventory(input);
    state.expanded.add('formula:demo');render();
    const field=[...document.querySelectorAll('.detail-field')].find(f=>f.querySelector('dt').textContent==='SECURITY · HOMEBREW');
    assert(!!field,'Security field rendered');
    const detailText=field.textContent,note=document.getElementById('security-note').textContent;
  if(!found)assert(detailText.includes('No finding reported'),'Empty finding message');
  if(status==='incomplete')assert(detailText.includes('Scan incomplete'),'Incomplete detail warning');
  if(status==='failed')assert(detailText.includes('Security check failed')&&note.includes('failed'),'Failure detail and note warning');
    assert(detailText.includes('not per installed version')===multi,'Per-package scope note is conditional');
    assert(note.includes('does not confirm every installed version')===multi,'Global multi-version scope is conditional');
    assert(note.includes('complete Formula coverage')===(status==='succeeded'),'Failure/incomplete must not claim completion');
    assert(detailText.includes('Reported version: 1.0')===found,'Only Homebrew-reported version is shown');
    assert(!detailText.includes('2.0'),'Other version coverage is not inferred');
    if(!found)assert(!detailText.includes('Reported version:')&&!detailText.includes('1.0'),'Empty result cannot identify a scanned version');
    assert(JSON.stringify(input)===before,'Original report, complete values and installed versions are preserved');
  }
  assert(!hasMultipleInstalledVersions(pkg(['1.0','1.0'])),'Duplicate version is not multiple coverage');
  assert(!hasMultipleInstalledVersions({...pkg(['1.0','2.0']),type:'cask'}),'Cask does not receive Formula coverage');
  assert(!hasMultipleInstalledVersions({type:'formula'}),'Missing installed versions');
  return 'PASS WebKit 12 version/finding/status combinations: visible scope notes, unchanged Reported version and no inferred per-version safety';
})()
