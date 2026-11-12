Official Homebrew source extracts, unchanged method bodies:
- eligible_before.rb: Formula#eligible_kegs_for_cleanup at
  4d1e464ca686408052b9ff46b38d0847d119715b, Library/Homebrew/formula.rb
- eligible_713.rb: same method at tag 7.0.13, Library/Homebrew/formula.rb
- cleanup_keg_713.rb: Cleanup#cleanup_keg at tag 7.0.13, Library/Homebrew/cleanup.rb
PR: https://github.com/Homebrew/brew/pull/24465
Merge: acfb13671c538b277a1ceb0b7aa0b0f003a18426
License: LICENSE.txt (Homebrew BSD 2-Clause)

projection_fixture.rb models Formula/Keg/Tab/locks and a small numeric/HEAD
version comparator. It uses real temporary keg directories, receipt files,
inodes and SHA256 through the product script. The upstream eligibility and
cleanup_keg methods run unchanged. Keg#uninstall only writes a removed marker;
it never deletes a directory or invokes Homebrew. This does not verify the
complete Homebrew version parser, loader, live symlinks/locks or filesystem
permissions. The Tab double follows Tab.for_keg's missing-file fallback to
an in-memory empty receipt (version_scheme 0); it does not create a receipt.
Missing, malformed and non-file receipts are tested separately, as are receipt
appearance/disappearance between confirmation and execution.
