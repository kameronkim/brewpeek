trust.rb is unmodified Homebrew/brew 7.0.11:
https://github.com/Homebrew/brew/blob/7.0.11/Library/Homebrew/trust.rb
Homebrew BSD 2-Clause license: LICENSE.txt

source_checks.rb runs the actual UpgradeTrust.script against that official
implementation with private Tap/metadata and filesystem doubles. Its config
root is nested inside the Swift test workspace. It never loads the installed
Homebrew source, evaluates Formula/Cask recipes, or writes user trust settings.
The old qualified-name behavior is reproduced only inside that private store.

Requires Ruby >= 3.4. The test accepts BREWPEEK_TEST_RUBY or locates common
Homebrew Ruby paths, without running brew or installing anything. If no default
runtime is suitable XCTest reports an explicit skip. An invalid explicit
override is a test failure. This is a source-contract test, not live CLI proof.
