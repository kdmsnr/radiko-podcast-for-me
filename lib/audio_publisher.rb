#!/usr/bin/env ruby

require 'securerandom'

module RadikoPodcastForMe
  module AudioPublisher
    module_function

    def publish(directory, source)
      destination = File.join(directory, File.basename(source))
      temporary_path = nil

      begin
        File.open(source, 'rb') do |input|
          mode = input.stat.mode & 0o777
          temporary_path, output = create_temporary_file(directory)
          begin
            IO.copy_stream(input, output)
            output.flush
            output.fsync
            output.chmod(mode)
          ensure
            output.close
          end
        end

        # A hard link publishes the complete file atomically and fails if the
        # destination already exists, even when another process creates it.
        File.link(temporary_path, destination)
        File.unlink(temporary_path)
        temporary_path = nil
        File.unlink(source)
      ensure
        File.unlink(temporary_path) if temporary_path && File.exist?(temporary_path)
      end

      destination
    end

    def create_temporary_file(directory)
      loop do
        path = File.join(directory, ".podcast-publish-#{SecureRandom.hex(16)}.tmp")
        begin
          file = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o000)
          return [path, file]
        rescue Errno::EEXIST
          next
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length != 2
    warn '使用方法: ruby audio_publisher.rb 公開先ディレクトリ 音声ファイル'
    exit 1
  end

  begin
    destination = RadikoPodcastForMe::AudioPublisher.publish(*ARGV)
    puts "音声ファイルを公開しました: #{destination}"
  rescue SystemCallError, IOError => e
    warn "エラー: 音声ファイルの公開に失敗しました: #{e.message}"
    exit 1
  end
end
