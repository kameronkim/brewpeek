# Isolated filesystem/receipt doubles around unmodified upstream method extracts.
# Cleanup records a removed marker; it never uninstalls or deletes any directory.
require "json"
require "pathname"
require "rubygems/version"

class Object
  def presence; respond_to?(:empty?) && empty? ? nil : self; end
end
class FixtureVersion
  include Comparable
  def initialize(text); @text = text; end
  def head?; @text.start_with?("HEAD-"); end
  def to_s; @text; end
  def <=>(other)
    [head? ? 1 : 0, Gem::Version.new(head? ? "0" : to_s), head? ? to_s : ""] <=>
      [other.head? ? 1 : 0, Gem::Version.new(other.head? ? "0" : other.to_s), other.head? ? other.to_s : ""]
  end
end
module AbstractTab
  FILENAME = "INSTALL_RECEIPT.json"
end
class Keg
  def initialize(path); @path = Pathname.new(path); end
  def to_path; @path.to_s; end
  def to_s; to_path; end
  def /(child); @path/child; end
  def version; FixtureVersion.new(@path.basename.to_s); end
  def data; $state.fetch("kegs").find { |k| k.fetch("version") == version.to_s } || raise("unknown fixture keg"); end
  def tab
    # Tab.for_keg uses Tab.empty (version_scheme 0) when the receipt is absent.
    # This fallback is in memory only; malformed/read failures still propagate.
    receipt = @path/AbstractTab::FILENAME
    record = receipt.exist? ? JSON.parse(receipt.read) : {}
    Struct.new(:version_scheme).new(record.fetch("source", {}).fetch("versions", {}).fetch("version_scheme", 0))
  end
  def scheme_and_version; [tab.version_scheme, version]; end
  def linked?; data.fetch("linked", false); end
  def optlinked?; data.fetch("optlinked", false); end
  def keepme_refs; data.fetch("keepme", []); end
  def ==(other); other.is_a?(Keg) && to_path == other.to_path; end
  alias eql? ==
  def hash; to_path.hash; end
  def uninstall(raise_failures:)
    raise "not a fixture path" unless @path.parent == $root/"cellar"
    ($root/"cleanup-calls").open("a") { |f| f.puts(version.to_s) }
    raise Errno::EACCES, "fixture cleanup failure" if data["cleanup_error"]
    ($root/"removed-#{version}").write("")
  end
end
class Formula
  def name; "fixture"; end
  def full_name; "fixture"; end
  def pinned?; $state.fetch("pinned", false); end
  def excluded?; $state.fetch("excluded", false); end
  def head?; $state.fetch("head_spec", false); end
  def latest_head_prefix
    value = $state["latest_head"]
    value && $root/"cellar"/value
  end
  def latest_version_installed?; installed_kegs.any? { |k| k.version.to_s == $state.fetch("latest") }; end
  def version_scheme; $state.fetch("version_scheme", 0); end
  def pkg_version; FixtureVersion.new($state.fetch("latest")); end
  def installed_kegs
    $state.fetch("kegs").map { |k| Keg.new($root/"cellar"/k.fetch("version")) }
      .reject { |k| ($root/"removed-#{k.version}").exist? }
  end
  def installed_prefixes; installed_kegs.map { |k| Pathname.new(k) }; end
  def resolved_path(path); path; end
  def opoo(message); warn(message); end
  def lock; ($root/"locks").open("a") { |f| f.puts("lock") }; end
  def unlock; ($root/"locks").open("a") { |f| f.puts("unlock") }; end
  def initialize
    @pin = Struct.new(:path).new($root/"cellar"/$state.fetch("pin_version", "0.2"))
  end
end
module Formulary
  def self.factory(name)
    raise "unknown fixture formula" unless name == "fixture"
    Formula.new
  end
end
module Homebrew
  class Cleanup
    attr_reader :unremovable_kegs
    def initialize; @unremovable_kegs = []; end
    def self.skip_clean_formula?(formula); formula.excluded?; end
    def cleanup_path(path); yield; end
    def opoo(message); warn(message); end
  end
end

root, mode, script = ARGV
$root = Pathname.new(root).realpath
raise "not a test workspace" unless ($root/"state.json").file? && ($root/"cellar").directory?
$state = JSON.parse(($root/"state.json").read)
$LOADED_FEATURES << "cleanup.rb"
Formula.class_eval(File.read(File.join(__dir__, mode == "before" ? "eligible_before.rb" : "eligible_713.rb")))
Homebrew::Cleanup.class_eval(File.read(File.join(__dir__, "cleanup_keg_713.rb")))
eval(script, TOPLEVEL_BINDING, "fixture-request")
