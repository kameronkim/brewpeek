# Executes Homebrew 7.0.11's unmodified trust.rb against a private filesystem and metadata doubles.
require "tmpdir"
require "fileutils"
require "pathname"
require "json"
require "stringio"
ROOT = Dir.mktmpdir("bp-trust-source-", ARGV.fetch(2))
at_exit { FileUtils.remove_entry(ROOT) if File.exist?(ROOT) }
ENV["HOMEBREW_USER_CONFIG_HOME"] = File.join(ROOT, "config")
ENV["USER"] ||= ENV.fetch("LOGNAME", "fixture")
Dir.mkdir(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"), 0700)
stubs = File.join(ROOT, "stubs"); Dir.mkdir(stubs)
%w[env_config tap utils utils/output].each do |name|
  path = File.join(stubs, name + ".rb"); FileUtils.mkdir_p(File.dirname(path)); File.write(path, "")
end
$LOAD_PATH.unshift(stubs)
module T
  class Type; def self.[](*) = nil; end
  Hash = Type; Array = Type
  def self.let(value, *) = value
end
class Module; def sig(*) = nil; end
class Object
  def presence = (respond_to?(:empty?) && empty?) ? nil : self
  def present? = !((respond_to?(:empty?) && empty?) || nil? || self == false)
end
class Pathname
  def atomic_write(text)
    tmp = Pathname(to_s + ".fixture-tmp")
    tmp.write(text); tmp.rename(self)
  end
end
module Utils
  module Output; module Mixin; def opoo(*) = nil; end; end
  def self.full_name?(value) = value.count("/") == 2
  def self.name_from_full_name(value) = value.split("/").last
  def self.tap_from_full_name(value) = full_name?(value) ? value.split("/").first(2).join("/") : nil
end
module Homebrew
  def self.running_as_root? = false
  def self.running_command = "upgrade"
  module EnvConfig
    def self.no_require_tap_trust? = false
    def self.require_tap_trust? = true
  end
end
class Tap
  class InvalidNameError < RuntimeError; end
  attr_reader :name, :path
  def initialize(name)
    @name=name; @path=Pathname(ROOT)/"Taps"/name
    (@path/"Formula").mkpath; (@path/"Casks").mkpath
    (@path/"Formula/alpha.rb").write('raise "Recipe must not be evaluated by inspection"')
    (@path/"Casks/app.rb").write('raise "Cask must not be evaluated by inspection"')
  end
  def self.fetch(name)
    raise InvalidNameError unless name.split("/").size == 2 && !name.start_with?("/")
    @taps ||= {}; @taps[name] ||= new(name)
  end
  def self.from_path(path) = (@taps || {}).values.find { |tap| path.to_s.start_with?(tap.path.to_s + "/") }
  def self.with_formula_name(name) = Utils.full_name?(name) ? [fetch(Utils.tap_from_full_name(name)), Utils.name_from_full_name(name)] : nil
  def self.remote_reference?(name) = name.include?("://")
  def self.same_remote?(left,right) = left == right
  def self.remote_to_reference(name) = name
  def installed? = true
  def official? = name.start_with?("homebrew/")
  def implicitly_trusted? = official?
  def reference(**) = name
  def remote = "https://example.test/" + name
  def matches_reference?(reference) = reference == name
  def uses_custom_remote? = false
  def alias_table = {}
  def formula_renames = {}
  def core_tap? = name == "homebrew/core"
  def formula_files_by_name = {"alpha" => path/"Formula/alpha.rb"}
  def cask_files_by_name = {"app" => path/"Casks/app.rb"}
end
class IO; def ohai(*) = nil; end
$LOAD_PATH << File.dirname(File.expand_path(ARGV.fetch(0)))
require File.expand_path(ARGV.fetch(0))
module CountSandboxWrites
  def write_trust_store(store)
    $writes += 1
    super
  end
end
Homebrew::Trust.singleton_class.prepend(CountSandboxWrites)
projection = File.read(ARGV.fetch(1))
def check(value,message)
  raise message unless value
end
def reset_trust
  if Homebrew::Trust.respond_to?(:replace!)
    Homebrew::Trust.replace!([])
  else
    [:tap, :formula, :cask, :command].each { |type| Homebrew::Trust.clear!(type) }
  end
end
trust_path=Homebrew::Trust.trust_file
raise "Unsafe test configuration" unless trust_path.to_s.start_with?(ROOT + "/")
[:formula, :cask].each do |type|
  token = type == :formula ? "alpha" : "app"
  %w[official tap package untrusted].each do |state|
    tap_name = state == "official" ? (type == :formula ? "homebrew/core" : "homebrew/cask") : "vendor/tools"
    full_name = tap_name + "/" + token
    $writes = 0
    reset_trust
    Homebrew::Trust.trust!(:tap, tap_name) if state == "tap"
    Homebrew::Trust.trust!(type, full_name) if state == "package"
    before=trust_path.exist? ? trust_path.binread : nil
    $writes=0
    request=[{"id"=>"#{type}:#{full_name}","type"=>type.to_s,"name"=>full_name}]
    code=projection.sub("PAYLOAD", JSON.generate([JSON.generate(request)].pack("m0")))
    old_stdout=$stdout; $stdout=StringIO.new
    begin
      eval(code, TOPLEVEL_BINDING)
      rows=JSON.parse($stdout.string)
    ensure
      $stdout=old_stdout
    end
    check(rows.fetch(0).fetch("state") == state, "Incorrect state #{type}/#{state}")
    argument=rows.fetch(0).fetch("argument")
    # This is the actual upgrade entrypoint trust function, with the exact safe argument produced.
    Homebrew::Trust.trust_fully_qualified_items!([argument], type: type)
    ARGV.replace([argument])
    path=type == :formula ? Tap.fetch(tap_name).formula_files_by_name[token] : Tap.fetch(tap_name).cask_files_by_name[token]
    blocked=false
    begin
      if type == :formula
        Homebrew::Trust.require_trusted_formula!(full_name, path)
      else
        Homebrew::Trust.require_trusted_cask!(token, path)
      end
    rescue Homebrew::UntrustedTapError
      blocked=true
    end
    check(blocked == (state == "untrusted"), "Homebrew enforcement must remain active #{state}")
    check($writes == 0 && (trust_path.exist? ? trust_path.binread : nil) == before, "Preview/cancel changed trust #{type}/#{state}")
    if state == "untrusted"
      # Separate explicit approval: call the same API as brew trust, writing only this sandbox.
      target_type,target_name=Homebrew::Trust.target(full_name,type:type)
      Homebrew::Trust.trust!(target_type,target_name)
      check($writes == 1, "Approved trust must be a distinct write")
      check(Homebrew::Trust.trusted?(type,full_name), "Approved item should be trusted")
    end
    puts "PASS official trust.rb #{type}/#{state}: no preview/cancel writes; enforcement retained"
  end
end
# Confirm that the old fully-qualified dry-run argument reproduces the reported side effect.
[:formula,:cask].each do |type|
  token=type==:formula ? "alpha" : "app"
  reset_trust; Homebrew::Trust.trust!(:tap,"vendor/tools"); $writes=0
  Homebrew::Trust.trust_fully_qualified_items!(["vendor/tools/#{token}"],type:type)
  check($writes == 1,"Old argument must reproduce implicit item trust")
end
puts "PASS old fully-qualified argument reproduces implicit writes inside the isolated trust store"
