# Runs only pinned upstream helper functions and BrewPeek's read-only projection.
# No Homebrew loader, Cellar, filesystem package metadata, or mutation command is used.
require "json"
require "set"

# Homebrew normally supplies Sorbet/ActiveSupport and Ruby >= 3.4. These adapters
# allow the unchanged helper files to run with macOS's system Ruby as well.
module Kernel
  def sig; end
end
module T
  Set = ::Set
  Array = ::Array
  Hash = ::Hash
  def self.let(value, _type); value; end
  def self.cast(value, _type); value; end
  def self.nilable(type); type; end
  def self.untyped; Object; end
end
module Enumerable
  def exclude?(item); !include?(item); end
  unless method_defined?(:filter_map)
    def filter_map; map { |item| yield item }.select { |item| item }; end
  end
end
if RUBY_VERSION < "2.7"
  class Set
    def intersect?(items); items.any? { |item| include?(item) }; end
  end
end
class FormulaUnavailableError < StandardError; end
Tab = Struct.new(:runtime_dependencies, :poured_from_bottle, :installed_on_request) do
  def installed_on_request_present?; true; end
end
class Dependency
  attr_reader :name
  def initialize(name, build = false); @name, @build = name, build; end
  def build?; @build; end
  def to_formula; Formulary.factory(name); end
  alias to_installed_formula to_formula
end
Keg = Struct.new(:formula, :tab) do
  def name; formula.name; end
  def to_formula; formula; end
  def optlinked?; true; end
  def scheme_and_version; 1; end
end
class Formula
  attr_reader :name, :full_name, :deps, :any_installed_keg
  def initialize(name, runtime: [], build: [], source: false, pinned: false, requested: false)
    @name = @full_name = name
    @pinned = pinned
    @deps = build.map { |name| Dependency.new(name, true) }
    @any_installed_keg = Keg.new(self, Tab.new(runtime.map { |name| { "full_name" => name } }, !source, requested))
  end
  def self.installed; @installed; end
  def self.installed=(items); @installed = items; end
  def pinned?; @pinned; end
  def possible_names; [name]; end
  def installed_kegs; [any_installed_keg]; end
  def tap; "fixture/tools"; end
  def to_s; name; end
  def installed_runtime_formula_dependencies
    any_installed_keg.tab.runtime_dependencies.map { |dep| Formulary.factory(dep.fetch("full_name")) }
  end
  # Formula#missing_dependencies in the pinned commit uses receipt runtime
  # dependencies and the hidden keg names. Build deps do not enter this list.
  def missing_dependencies(hide: [])
    any_installed_keg.tab.runtime_dependencies.filter_map do |dep|
      name = dep.fetch("full_name")
      Dependency.new(name) if hide.include?(name)
    end
  end
end
module Formulary
  def self.factory(name)
    Formula.installed.find { |formula| formula.full_name == name } || raise(FormulaUnavailableError, name)
  end
end
module Utils
  def self.name_from_full_name(name); name.split("/").last; end
end
module Cask
  class Cask
    attr_reader :full_token, :depends_on
    def initialize(name, dependencies)
      @full_token = name
      @depends_on = Struct.new(:formula).new(dependencies)
    end
    def to_s; full_token; end
  end
  class Caskroom
    def self.casks; @casks; end
    def self.casks=(items); @casks = items; end
  end
end
class CaskDependent
  def initialize(cask); @cask = cask; end
  def runtime_dependencies
    @cask.depends_on.formula.flat_map do |name|
      formula = Formulary.factory(name)
      [formula, *formula.installed_runtime_formula_dependencies]
    end.uniq.map { |formula| Dependency.new(formula.full_name) }
  end
end
module Homebrew
  module EnvConfig
    def self.no_cleanup_formulae; $scenario == "cleanup-excluded" ? "bar" : ""; end
  end
  class Cleanup
    def self.skip_clean_formula?(formula); formula.name == "bar"; end
  end
end

$scenario, phase, capability, projection_path = ARGV
$LOADED_FEATURES.concat(["cleanup.rb", "cask/caskroom.rb", "utils/autoremove.rb", "installed_dependents.rb", "cask_dependent.rb"])
load File.join(__dir__, "autoremove.rb")
load File.join(__dir__, "installed_dependents.rb")
if capability == "missing"
  Utils::Autoremove.singleton_class.send(:remove_method, :formulae_safe_to_remove)
elsif capability == "broken"
  Utils::Autoremove.define_singleton_method(:formulae_safe_to_remove) { |*args| raise "fixture safety API failure" }
end

cmake = Formula.new("cmake")
bar = Formula.new("bar", build: ["cmake"], source: $scenario != "bottle", pinned: $scenario == "pinned")
Formula.installed = [bar, cmake]
selected = Cask::Cask.new("remove-me", ["bar", "cmake"])
Cask::Caskroom.casks = [selected]
case $scenario
when "cask-kept", "bottle"
  Cask::Caskroom.casks << Cask::Cask.new("keep-me", ["bar"])
when "outside-scope"
  selected = Cask::Cask.new("remove-me", ["cmake"])
  Cask::Caskroom.casks = [selected]
when "runtime"
  bar = Formula.new("bar", runtime: ["cmake"])
  Formula.installed = [bar, cmake]
  Cask::Caskroom.casks << Cask::Cask.new("keep-me", ["bar"])
when "chain"
  mid = Formula.new("mid", build: ["cmake"], source: true)
  bar = Formula.new("bar", build: ["mid"], source: true)
  Formula.installed = [bar, mid, cmake]
  selected = Cask::Cask.new("remove-me", ["bar", "mid", "cmake"])
  Cask::Caskroom.casks = [selected, Cask::Cask.new("keep-me", ["bar"])]
end
if $scenario == "selected-formula"
  selected = Formula.new("remove-me", runtime: ["cmake"], build: ["cmake"], source: true, requested: true)
  Formula.installed = [selected, cmake]
  Cask::Caskroom.casks = []
end
if phase == "after"
  Cask::Caskroom.casks -= [selected]
  Formula.installed -= [selected]
end
eval(File.read(projection_path), TOPLEVEL_BINDING, projection_path)
