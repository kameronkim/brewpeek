import Foundation
import XCTest
@testable import BrewPeek

/// Pump native callbacks until a positive condition; fail and stop the case on timeout.
enum NativeTestWait {
  static func until(_ condition: () -> Bool, timeout: TimeInterval = 8,
                    file: StaticString = #filePath, line: UInt = #line) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard condition() else {
      XCTFail("Native callback timed out", file: file, line: line)
      throw InventoryError(message: "Fixture callback timed out")
    }
  }

  /// Negative assertions need a bounded observation window, not just an eventual check.
  static func remains(_ condition: () -> Bool, for duration: TimeInterval = 0.4,
                      file: StaticString = #filePath, line: UInt = #line) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + duration
    repeat {
      guard condition() else {
        XCTFail("Native state changed during observation", file: file, line: line)
        throw InventoryError(message: "Fixture state changed")
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    } while ProcessInfo.processInfo.systemUptime < deadline
    XCTAssertTrue(condition(), file: file, line: line)
  }
}
