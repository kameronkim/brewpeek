import Foundation

/// One identifier policy for installed metadata and confirmed package operations.
enum HomebrewPackageName {
  static func isValid(_ name: String) -> Bool {
    name.range(
      of: #"^[a-zA-Z0-9][a-zA-Z0-9@+_.-]*(/[a-zA-Z0-9][a-zA-Z0-9@+_.-]*){0,2}$"#,
      options: .regularExpression) != nil
  }
}
