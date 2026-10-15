#!/usr/bin/env ruby

require 'shellwords'
require 'uri'
require 'open3'
require_relative 'lib/common'

class PodcastDownloader
  class ConfigurationError < ArgumentError; end

  DEFAULT_CONCURRENT_FRAGMENTS = 5
  REQUIRED_CONFIG_KEYS = %w[area_id audio_dir yt_dlp_path].freeze
  MAX_DIAGNOSTIC_LINES = 10
  MAX_LOG_LINE_BYTES = 4096
  UNAVAILABLE_PROGRAM_ERROR = /\AERROR: \[RadikoTimeFree\] [\w-]+-\d{14}: (?:This programme is not available\.(?: If this is an NHK station, you may wish to try NHK Radiru\.)?|Programme is no longer available\.)\z/

  attr_reader :failures

  def initialize(config, keywords, command_runner: nil, stdout: $stdout, stderr: $stderr)
    @stdout = stdout
    @stderr = stderr
    @command_runner = command_runner || method(:run_command)

    validate_config(config)
    @keywords = validate_keywords(keywords)
    @area_id = config['area_id'].strip
    @audio_dir = config['audio_dir'].strip
    @yt_dlp_path = config['yt_dlp_path'].strip
    @concurrent_fragments = concurrent_fragments(config)
    @failures = []
  end

  def failed_keywords
    @failures.map { |failure| failure[:keyword] }
  end

  def download
    base_options = build_base_options
    @failures = []

    @keywords.each do |keyword_str|
      @stdout.puts "検索キーワード: #{keyword_str}"
      search_key, station_id = parse_keyword(keyword_str)
      search_url = build_search_url(search_key, station_id)
      command = build_command(search_url, base_options)

      unless execute_command(command)
        @failures << {
          keyword: keyword_str,
          message: @failure_message,
          details: @command_errors.empty? ? @command_tail : @command_errors
        }
      end
    end

    @failures.empty?
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
      '--no-abort-on-error',
      '--newline',
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
    @process_status = nil
    @failure_message = nil
    @command_errors = []
    @command_tail = []
    @unavailable_program_count = 0
    @unexpected_error = false
    @playlist_finished = false
    @stdout.puts "実行コマンド: #{command.map(&:shellescape).join(' ')}"
    @stdout.flush
    success = @command_runner.call(*command)

    if success.nil?
      return command_failed("エラー: '#{@yt_dlp_path}' コマンドを実行できませんでした。パスを確認してください。")
    end

    return true if success
    if @process_status&.exitstatus == 1 && @unavailable_program_count.positive? &&
       !@unexpected_error && @playlist_finished
      @stderr.puts "警告: 取得不可の番組 #{@unavailable_program_count}件をスキップしました。"
      return true
    end

    status = if @process_status&.signaled?
               "シグナル: #{@process_status.termsig}"
             else
               "終了ステータス: #{@process_status&.exitstatus || 'unknown'}"
             end
    command_failed("警告: コマンドの実行に失敗しました (#{status})")
  rescue Errno::ENOENT
    command_failed("エラー: '#{@yt_dlp_path}' コマンドが見つかりません。パスを確認してください。")
  rescue StandardError => e
    command_failed("エラー: コマンド実行中に予期せぬエラーが発生しました: #{e.message}")
    @stderr.puts Array(e.backtrace).join("\n")
    false
  end

  def command_failed(message)
    @failure_message = message
    @stderr.puts message
    false
  end

  def run_command(*command)
    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      output_lock = Mutex.new
      readers = [[stdout, @stdout], [stderr, @stderr]].map do |source, destination|
        Thread.new do
          source.each_line(MAX_LOG_LINE_BYTES) do |line|
            output_lock.synchronize do
              destination.print(remember_output(line))
              destination.flush
            end
          end
        end
      end
      readers.each(&:value)
      @process_status = wait_thread.value
      @process_status.success?
    end
  end

  def remember_output(line)
    # Keep diagnostics bounded even when a download produces a long progress log.
    text = line.scrub.gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '').strip
    return line if text.empty?

    @playlist_finished ||= text.start_with?('[download] Finished downloading playlist: ')
    if text.match?(UNAVAILABLE_PROGRAM_ERROR)
      @unavailable_program_count += 1
      line = "警告: 取得不可の番組をスキップ: #{text.delete_prefix('ERROR: ')}\n"
      text = line.strip
    elsif text.match?(/\bERROR:|エラー:|\ATraceback \(most recent call last\):/i)
      # Track every failure, including errors that fall out of the bounded log.
      @unexpected_error = true
      @command_errors << text
      @command_errors.shift if @command_errors.length > MAX_DIAGNOSTIC_LINES
    end

    @command_tail << text
    @command_tail.shift if @command_tail.length > MAX_DIAGNOSTIC_LINES
    line
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
      downloader.failures.each do |failure|
        stderr.puts "  - #{failure[:keyword]}"
        stderr.puts "    #{failure[:message]}"
        failure[:details].each { |line| stderr.puts "    #{line}" }
      end
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
