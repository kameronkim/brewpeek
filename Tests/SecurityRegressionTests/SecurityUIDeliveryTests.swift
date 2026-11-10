import Cocoa
import WebKit
import XCTest
@testable import BrewPeek

/// Real WebKit with deliberate old-message holding, not a claim that WebKit reorders FIFO calls.
final class SecurityUIDeliveryTests: XCTestCase {
  private final class Page {
    let web: WKWebView
    let window: NSWindow
    init() throws {
      _ = NSApplication.shared
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700), configuration: configuration)
      window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = web // No window is shown or activated.
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let base = root.appendingPathComponent("BrewPeek/Web")
      web.loadFileURL(base.appendingPathComponent("index.html"), allowingReadAccessTo: base)
      try NativeTestWait.until({ !self.web.isLoading }, timeout: 15)
      _ = try run(#"if (typeof window.setSecurityCheck !== 'function') throw Error('Page did not load'); return true;"#)
    }
    deinit { window.close() }
    @discardableResult func run(_ code: String, arguments: [String: Any] = [:]) throws -> Any {
      var completed: Result<Any, Error>?
      web.callAsyncJavaScript(code, arguments: arguments, in: nil, in: .page) { completed = $0 }
      try NativeTestWait.until({ completed != nil }, timeout: 15)
      return try XCTUnwrap(completed).get()
    }
  }

  private let setup = #"""
    const pkg = name => ({id:'formula:'+name,name,type:'formula',category:'Tools',version:'1',description:'fixture',paths:[],dependencies:[],usedBy:[],apps:[]});
    window.fixtureReport = (status, name) => ({scope:'formulae',status,report:{complete:status==='succeeded',checked:1,skipped_formulae:[],outdated_without_sbom:[],unscanned_formulae:{},findings:name?[{formula:name,version:'1',vulnerabilities:[{id:'CVE-fixture',severity:'HIGH'}],patched:[]}]:[]}});
    window.fixtureSnapshot = id => ({snapshotID:id,formulae:Array.from({length:55},(_,i)=>pkg('fixture-'+String(i).padStart(2,'0'))),casks:[],taps:[],environment:{},securityCheck:fixtureReport('checking')});
    setInventory(fixtureSnapshot('same-snapshot'));
    inventoryRefreshState='idle'; syncActionAvailability();
    return true;
    """#

  func testDelayedSameSnapshotDeliveryCannotOverwriteNewerUIOrMoveView() throws {
    let p = try Page(); try p.run(setup)
    let result = try p.run(#"""
      const old = () => setSecurityCheck(fixtureReport('incomplete','fixture-21'),'same-snapshot',1);
      setSecurityCheck(fixtureReport('checking'),'same-snapshot',2);
      setSecurityCheck(fixtureReport('succeeded','fixture-20'),'same-snapshot',3);
      const search=document.getElementById('search');search.value='fixture';search.dispatchEvent(new Event('input'));
      document.querySelector('[data-key="formula:fixture-20"] .package-button').click();
      const button=document.querySelector('[data-key="formula:fixture-20"] .package-button');
      button.focus();button.scrollIntoView({block:'center'});
      await new Promise(resolve=>setTimeout(resolve,60));
      const before={query:state.query,category:state.category,filter:state.filter,sort:state.sort,direction:state.direction,expanded:[...state.expanded],scroll:window.scrollY};
      const table=document.querySelector('.package-table'), focused=document.activeElement;
      if(!table)throw Error('Missing package table');
      old();
      return JSON.stringify({status:brewData.securityCheck.status,oldLabel:Boolean(document.querySelector('[data-key="formula:fixture-21"] .security-label')),newLabel:Boolean(document.querySelector('[data-key="formula:fixture-20"] .security-label')),sameTable:table===document.querySelector('.package-table'),sameFocus:focused===document.activeElement,sameState:JSON.stringify(before)===JSON.stringify({query:state.query,category:state.category,filter:state.filter,sort:state.sort,direction:state.direction,expanded:[...state.expanded],scroll:window.scrollY})});
      """#) as? String
    let data = try XCTUnwrap(result?.data(using: .utf8))
    let r = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? Record)
    XCTAssertEqual(r["status"] as? String, "succeeded")
    XCTAssertEqual(r["oldLabel"] as? Bool, false)
    for key in ["newLabel", "sameTable", "sameFocus", "sameState"] { XCTAssertEqual(r[key] as? Bool, true, key) }
  }

  func testSnapshotGuardInvalidSequencesDuplicatesAndPageReplacement() throws {
    let p = try Page(); try p.run(setup)
    let result = try p.run(#"""
      const accepted=fixtureReport('succeeded');setSecurityCheck(accepted,'same-snapshot',3);
      setSecurityCheck(fixtureReport('failed'),'wrong-snapshot',999);
      for(const n of [undefined,null,0,-1,1.5,NaN,Infinity,'4',1,3]) setSecurityCheck(fixtureReport('failed'),'same-snapshot',n);
      const invalidIgnored=brewData.securityCheck===accepted;
      setSecurityCheck(fixtureReport('incomplete'),'same-snapshot',4);
      const newerAccepted=brewData.securityCheck.status==='incomplete';
      setSecurityCheck(fixtureReport('failed'),'same-snapshot',4);
      const duplicateIgnored=brewData.securityCheck.status==='incomplete';
      setInventory(fixtureSnapshot('new-snapshot'));
      setSecurityCheck(fixtureReport('succeeded'),'new-snapshot',5);
      setSecurityCheck(fixtureReport('failed'),'same-snapshot',1000);
      const oldSnapshotIgnored=brewData.securityCheck.status==='succeeded';
      setInventory(fixtureSnapshot('same-snapshot'));
      setSecurityCheck(fixtureReport('failed'),'same-snapshot',2);
      return JSON.stringify({invalidIgnored,newerAccepted,duplicateIgnored,oldSnapshotIgnored,oldVisitIgnored:brewData.securityCheck.status==='checking'});
      """#) as? String
    let r = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result).utf8)) as? [String: Bool])
    for (key, value) in r { XCTAssertTrue(value, key) }
  }

  func testNativeTrustRefreshAndUpdateCancellationKeepFreshFileAndDelayedUI() throws {
    let p = try Page(), f = try TrustTestFixture(formulaeOnly: true)
    var old = try SecurityFixture.check("incomplete-untrusted", status: 1); old["fixtureOld"] = true
    let snapshot = SecurityFixture.snapshot(id: UUID().uuidString, check: old)
    let id = try XCTUnwrap(snapshot["snapshotID"] as? String)
    try SecurityFixture.saveSnapshot(snapshot, to: f.workspace.inventory)
    f.app.observeSecuritySnapshot(snapshot, at: f.workspace.inventory)
    f.app.web = p.web; f.app.pageReady = true; f.app.latestSecurityReport = (id, old)
    let oldOwner = SecurityReportGeneration()
    f.app.securityGeneration = oldOwner
    defer { f.app.pageReady = false; f.app.cancelSecurityRefresh() }
    try p.run(#"""
      setInventory(snapshot);
      const apply=window.setSecurityCheck;
      window.deliveryTrace=[];
      window.setSecurityCheck=(report,id,sequence)=>{
        deliveryTrace.push({sequence,status:report.status});
        if(report.fixtureOld) {window.releaseOld=()=>apply(report,id,sequence);return;}
        return apply(report,id,sequence);
      };
      return true;
      """#, arguments: ["snapshot": snapshot])
    f.app.restoreSecurityReport()
    XCTAssertEqual(try p.run("return typeof releaseOld;") as? String, "function")
    try f.workspace.write("delay-scan", "")
    f.approve(try f.requiredPlan())
    try f.wait { if case .update? = f.app.operation.plan { return true }; return false }
    f.app.handleUpdate(["action": "cancel"])
    XCTAssertFalse(f.app.operation.hasPlan)
    XCTAssertEqual(try p.run("return brewData.securityCheck.status;") as? String, "checking")
    try f.workspace.write("release-scan", "")
    try f.wait { f.app.securityGeneration == nil && f.app.latestSecurityReport?.report["status"] as? String == "succeeded" }
    let saved = try Data(contentsOf: f.workspace.inventory)
    let report = try XCTUnwrap(InventoryStore.load(f.workspace.inventory)["securityCheck"] as? Record)
    XCTAssertEqual(report["status"] as? String, "succeeded")
    XCTAssertFalse(try SecurityReportStore.update(old, snapshotID: id, at: f.workspace.inventory, generation: oldOwner))
    XCTAssertEqual(try p.run("releaseOld(); return brewData.securityCheck.status;") as? String, "succeeded")
    XCTAssertEqual(try Data(contentsOf: f.workspace.inventory), saved)
    XCTAssertEqual(try p.run("return deliveryTrace.length >= 3 && deliveryTrace.every(d=>Number.isSafeInteger(d.sequence)&&d.sequence>0) && new Set(deliveryTrace.map(d=>d.sequence)).size===deliveryTrace.length;") as? Bool, true)
    print("Native WebKit delivery trace:", try p.run("return JSON.stringify(deliveryTrace);"))
  }
}
