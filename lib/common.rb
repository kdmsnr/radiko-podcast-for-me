require 'yaml'

module RadikoPodcastForMe
  SUPPORTED_AUDIO_EXTENSIONS = %w[.mp3 .m4a].freeze

  class ConfigurationFileError < StandardError; end

  def self.load_yaml_file(filepath)
    YAML.load_file(filepath)
  rescue Errno::ENOENT
    raise ConfigurationFileError, "ファイルが見つかりません: #{filepath}"
  rescue Psych::Exception, ArgumentError => e
    raise ConfigurationFileError,
          "YAMLファイルの形式が正しくありません: #{filepath} - #{e.message}"
  rescue SystemCallError => e
    raise ConfigurationFileError,
          "ファイルを読み込めません: #{filepath} - #{e.message}"
  end

  def self.supported_audio_file?(path)
    SUPPORTED_AUDIO_EXTENSIONS.include?(File.extname(path).downcase)
  end

  def self.canonical_file_target(filepath)
    begin
      return File.realpath(filepath)
    rescue Errno::ENOENT
      # Continue with a possibly dangling target.
    end

    if File.symlink?(filepath)
      link_directory = File.realpath(File.dirname(filepath))
      linked_path = File.expand_path(File.readlink(filepath), link_directory)
      return canonical_file_target(linked_path)
    end

    directory = begin
      File.realpath(File.dirname(filepath))
    rescue Errno::ENOENT
      File.expand_path(File.dirname(filepath))
    end
    File.join(directory, File.basename(filepath))
  end
end
