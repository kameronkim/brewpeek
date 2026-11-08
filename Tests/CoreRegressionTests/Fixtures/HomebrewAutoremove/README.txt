Upstream fixtures pinned to Homebrew/brew commit:
3896e649be31141a0a3b3c5950d78b51ec5b4304 (2026-11-05)

Unmodified upstream files:
- Library/Homebrew/utils/autoremove.rb
- Library/Homebrew/installed_dependents.rb
- LICENSE.txt
Source: https://github.com/Homebrew/brew/commit/3896e649be31141a0a3b3c5950d78b51ec5b4304

projection_fixture.rb supplies in-memory Formula/Cask/receipt objects only.
It executes these real upstream algorithms plus the application's Ruby projection.
Formula#missing_dependencies is modeled as receipt runtime dependency lookup;
this does not exercise real keg paths, stale filesystem metadata, or uninstall.
Tests execute the product projection without source replacement. The execution
case also runs PackageRemoval.execute with fake metadata and command scripts;
only disposable marker files stand in for actual uninstall operations.
