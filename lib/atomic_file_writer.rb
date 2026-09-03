require 'tempfile'
require_relative 'common'

module RadikoPodcastForMe
  class AtomicFileWriter
    def initialize(rename: File.method(:rename))
      @rename = rename
    end

    def write(filepath, content)
      target = resolve_target(filepath)
      directory = File.dirname(target)
      metadata = target_metadata(target)
      mode = metadata ? metadata.mode & 0o7777 : default_mode

      Tempfile.create([".#{File.basename(target)}.", '.tmp'], directory) do |temporary_file|
        temporary_file.binmode
        temporary_file.write(content)
        temporary_file.flush
        temporary_file.fsync
        preserve_ownership(temporary_file, metadata) if metadata
        temporary_file.chmod(mode)
        temporary_file.close
        @rename.call(temporary_file.path, target)
      end

      filepath
    end

    private

    def resolve_target(filepath)
      RadikoPodcastForMe.canonical_file_target(filepath)
    end

    def target_metadata(filepath)
      File.stat(filepath)
    rescue Errno::ENOENT
      nil
    end

    def preserve_ownership(file, metadata)
      unless Process.euid.zero? || metadata.uid == Process.euid
        raise Errno::EPERM, "cannot preserve owner uid=#{metadata.uid}"
      end

      file.chown(metadata.uid, metadata.gid)
    end

    def default_mode
      0o666 & ~File.umask
    end
  end
end
