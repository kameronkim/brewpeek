  def eligible_kegs_for_cleanup(quiet: false)
    eligible_for_cleanup = []
    if installed_prefixes.length > 1
      eligible_kegs = if head? && (head_prefix = latest_head_prefix)
        head, stable = installed_kegs.partition { |keg| keg.version.head? }
        stable = stable.sort_by(&:scheme_and_version)

        # Remove newest head and stable kegs.
        stable.pop
        head - [Keg.new(head_prefix)] + stable
      elsif latest_version_installed?
        installed_kegs.select do |keg|
          tab = keg.tab
          if version_scheme > tab.version_scheme
            true
          elsif version_scheme == tab.version_scheme
            pkg_version > keg.version
          else
            false
          end
        end
      else
        kegs = installed_kegs.select { |keg| (keg/AbstractTab::FILENAME).file? }
                             .reject { |keg| keg.version.head? }
                             .sort_by(&:scheme_and_version)
        newest_keg = kegs.pop
        if !kegs.empty? && !quiet && !pinned?
          opoo "Skipping #{newest_keg}: most recent version #{pkg_version} not installed"
        end
        kegs
      end

      unless eligible_kegs.empty?
        eligible_kegs.each do |keg|
          if keg.linked?
            opoo "Skipping (old) #{keg} due to it being linked" unless quiet
          elsif pinned? && keg == Keg.new(resolved_path(@pin.path))
            opoo "Skipping (old) #{keg} due to it being pinned" unless quiet
          elsif (keepme_refs = keg.keepme_refs.presence)
            opoo "Skipping #{keg} as it is needed by #{keepme_refs.join(", ")}" unless quiet
          else
            eligible_for_cleanup << keg
          end
        end
      end
    end
    eligible_for_cleanup
  end
