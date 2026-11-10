    def cleanup_keg(keg)
      cleanup_path(Pathname.new(keg)) { keg.uninstall(raise_failures: true) }
    rescue Errno::EACCES, Errno::ENOTEMPTY => e
      opoo e.message
      unremovable_kegs << keg
    end
