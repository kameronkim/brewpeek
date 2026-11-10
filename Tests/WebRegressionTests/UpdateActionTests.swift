import XCTest

final class UpdateActionTests: XCTestCase {
  func testQuitRequestApprovedRetryAndOrdinaryRetryKeepSeparateActions() throws {
    let page = try WebTestPage(width: 900, height: 760)
    try page.run("""
      inventoryRefreshState='idle'; operationKind='update'; activeRequest='blocked'; requestedKeys=['cask:example'];
      showCheckError('Close app',['Example'],'approved');
      assert(!$('quit-update-apps').hidden && $('quit-update-apps').textContent==='Quit app','Single app quit request visible');
      $('quit-update-apps').click(); return true;
      """)
    try page.wait { page.messages.values.count == 1 }
    XCTAssertEqual(page.messages.values[0]["action"] as? String, "quitUpdateApps")
    XCTAssertEqual(page.messages.values[0]["token"] as? String, "approved")
    try page.run("""
      receiveUpdate({kind:'appQuitRequested',requestID:activeRequest,message:'Quit requested'});
      assert($('quit-update-apps').disabled,'No duplicate quit request');
      assert(updateMode==='check-failed','Quit request does not start update');
      $('retry-plan').click(); return true;
      """)
    try page.wait { page.messages.values.count == 2 }
    XCTAssertEqual(page.messages.values[1]["action"] as? String, "start")
    XCTAssertEqual(page.messages.values[1]["token"] as? String, "approved")
    try page.run("showCheckError('Cannot check',[],null); $('retry-plan').click(); return true;")
    try page.wait { page.messages.values.count == 3 }
    XCTAssertEqual(page.messages.values[2]["action"] as? String, "prepare")
    XCTAssertEqual(page.messages.values[2]["keys"] as? [String], ["cask:example"])
  }
}
