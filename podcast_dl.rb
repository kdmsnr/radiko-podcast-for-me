#!/usr/bin/env ruby

require 'shellwords'
require 'uri'
require_relative 'lib/common'

class PodcastDownloader
  class ConfigurationError < ArgumentError; end

  DEFAULT_CONCURRENT_FRAGMENTS = 5
  REQUIRED_CONFIG_KEYS = %w[area_id audio_dir yt_dlp_path].freeze

  attr_reader :failed_keywords

  def initialize(config, keywords, command_runner: nil, stdout: $stdout, stderr: $stderr)
    @stdout = stdout
    @stderr = stderr
    @uses_default_command_runner = command_runner.nil?
    @command_runner = command_runner || ->(*command) { system(*command) }

    validate_config(config)
    @keywords = validate_keywords(keywords)
    @area_id = config['area_id'].strip
    @audio_dir = config['audio_dir'].strip
    @yt_dlp_path = config['yt_dlp_path'].strip
    @concurrent_fragments = concurrent_fragments(config)
    @failed_keywords = []
  end

  def download
    base_options = build_base_options
    @failed_keywords = []

    @keywords.each do |keyword_str|
      @stdout.puts "検索キーワード: #{keyword_str}"
      search_key, station_id = parse_keyword(keyword_str)
      search_url = build_search_url(search_key, station_id)
      command = build_command(search_url, base_options)

      @failed_keywords << keyword_str unless execute_command(command)
    end

    @failed_keywords.empty?
  end

  private

  def validate_config(config)
    unless config.is_a?(Hash)
      raise ConfigurationError, '設定ファイルはキーと値の組で指定してください。'
    end

    missing_keys = REQUIRED_CONFIG_KEYS.reject { |key| config.key?(key) }
    unless missing_keys.empty?
      raise ConfigurationError, "設定ファイルに必要なキーが不足しています: #{missing_keys.join(', ')}"
    end

    invalid_keys = REQUIRED_CONFIG_KEYS.reject do |key|
      config[key].is_a?(String) && !config[key].strip.empty?
    end
    return if invalid_keys.empty?

    raise ConfigurationError,
          "設定ファイルの値は空でない文字列で指定してください: #{invalid_keys.join(', ')}"
  end

  def validate_keywords(keywords)
    unless keywords.is_a?(Array)
      raise ConfigurationError, 'キーワードは配列で指定してください。'
    end
    if keywords.empty?
      raise ConfigurationError, 'キーワードには1件以上の番組を指定してください。'
    end

    invalid_indexes = keywords.each_index.reject do |index|
      keywords[index].is_a?(String) && !keywords[index].strip.empty?
    end
    unless invalid_indexes.empty?
      positions = invalid_indexes.map { |index| index + 1 }
      raise ConfigurationError,
            "キーワードは空でない文字列で指定してください（対象: #{positions.join(', ')}番目）。"
    end

    keywords.map(&:strip).freeze
  end

  def concurrent_fragments(config)
    if config.key?('download_count')
      @stderr.puts(
        "警告: 'download_count' は非推奨です。'-N' はダウンロード件数ではなく" \
        "同時フラグメント数のため、'concurrent_fragments' を使用してください。"
      )
    end

    key = if config.key?('concurrent_fragments')
            'concurrent_fragments'
          elsif config.key?('download_count')
            'download_count'
          end

    value = key ? config[key] : DEFAULT_CONCURRENT_FRAGMENTS
    parse_positive_integer(value, key || 'concurrent_fragments')
  end

  def parse_positive_integer(value, key)
    integer = if value.is_a?(Integer)
                value
              elsif value.is_a?(String) && value.match?(/\A[+-]?\d+\z/)
                value.to_i
              end

    return integer if integer&.positive?

    raise ConfigurationError, "'#{key}' は正の整数で指定してください（現在値: #{value.inspect}）。"
  end

  def build_base_options
    [
      '-x',
      '-N', @concurrent_fragments.to_s,
      '--embed-metadata',
      '--playlist-reverse',
      '-P', @audio_dir,
    ]
  end

  def parse_keyword(keyword_str)
    trimmed = keyword_str.strip
    if match = trimmed.match(/\A(.+?)\s*&station_id=([^\s&]+)\s*\z/)
      [match[1], match[2]]
    else
      [trimmed, nil]
    end
  end

  def build_search_url(search_key, station_id)
    query_params = {
      "key" => search_key,
      "filter" => "past",
      "area_id" => @area_id
    }
    query_params["station_id"] = station_id if station_id

    "https://radiko.jp/#!/search/live?" + URI.encode_www_form(query_params)
  end

  def build_command(search_url, base_options)
    [@yt_dlp_path] + base_options + [search_url]
  end

  def execute_command(command)
    @stdout.puts "実行コマンド: #{command.map(&:shellescape).join(' ')}"
    @stdout.flush
    success = @command_runner.call(*command)

    if success.nil?
      @stderr.puts "エラー: '#{@yt_dlp_path}' コマンドを実行できませんでした。パスを確認してください。"
      return false
    end

    return true if success

    process_status = @uses_default_command_runner ? $? : nil
    exit_status = process_status&.exitstatus || 'unknown'
    @stderr.puts "警告: コマンドの実行に失敗しました (終了ステータス: #{exit_status})"
    false
  rescue Errno::ENOENT
    @stderr.puts "エラー: '#{@yt_dlp_path}' コマンドが見つかりません。パスを確認してください。"
    false
  rescue StandardError => e
    @stderr.puts "エラー: コマンド実行中に予期せぬエラーが発生しました: #{e.message}"
    @stderr.puts Array(e.backtrace).join("\n")
    false
  end
end

module PodcastDownloaderCLI
  module_function

  def run(config:, keywords:, command_runner: nil, stdout: $stdout, stderr: $stderr)
    downloader = PodcastDownloader.new(
      config,
      keywords,
      command_runner: command_runner,
      stdout: stdout,
      stderr: stderr
    )

    if downloader.download
      stdout.puts '処理が完了しました。'
      0
    else
      stderr.puts 'エラー: 一部のダウンロードに失敗しました。'
      stderr.puts '失敗したキーワード:'
      downloader.failed_keywords.each { |keyword| stderr.puts "  - #{keyword}" }
      stderr.puts '各キーワードのログにある ERROR: または警告・エラーを確認してください。'
      1
    end
  rescue PodcastDownloader::ConfigurationError => e
    stderr.puts "エラー: #{e.message}"
    1
  end

  def run_from_files(
    config_path:,
    keywords_path:,
    command_runner: nil,
    stdout: $stdout,
    stderr: $stderr
  )
    config = RadikoPodcastForMe.load_yaml_file(config_path)
    keywords = RadikoPodcastForMe.load_yaml_file(keywords_path)
    run(
      config: config,
      keywords: keywords,
      command_runner: command_runner,
      stdout: stdout,
      stderr: stderr
    )
  rescue RadikoPodcastForMe::ConfigurationFileError => e
    stderr.puts "エラー: #{e.message}"
    1
  end
end

# :nocov:
if __FILE__ == $0
  SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
  CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')
  KEYWORDS_FILE = File.join(SCRIPT_DIR, 'podcast_keywords.yml')

  exit PodcastDownloaderCLI.run_from_files(
    config_path: CONFIG_FILE,
    keywords_path: KEYWORDS_FILE
  )
end
# :nocov:
