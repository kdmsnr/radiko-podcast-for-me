#!/usr/bin/env ruby

require 'shellwords'
require 'uri'
require_relative 'lib/common'

class PodcastDownloader
  def initialize(config, keywords)
    @config = config
    @keywords = keywords
    validate_config
  end

  def download
    base_options = build_base_options

    @keywords.each do |keyword_str|
      search_key, station_id = parse_keyword(keyword_str)
      search_url = build_search_url(search_key, station_id)
      command = build_command(search_url, base_options)

      execute_command(command)
    end
  end

  private

  def validate_config
    required_keys = %w[area_id audio_dir yt_dlp_path]
    missing_keys = required_keys.reject { |k| @config[k] }
    unless missing_keys.empty?
      abort("エラー: 設定ファイルに必要なキーが不足しています: #{missing_keys.join(', ')}")
    end
  end

  def build_base_options
    [
      '-x',
      '-N', @config.fetch('download_count', 5).to_s,
      '--embed-metadata',
      '--playlist-reverse',
      '-P', @config['audio_dir'],
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
      "area_id" => @config['area_id']
    }
    query_params["station_id"] = station_id if station_id

    "https://radiko.jp/#!/search/live?" + URI.encode_www_form(query_params)
  end

  def build_command(search_url, base_options)
    [@config['yt_dlp_path']] + base_options + [search_url]
  end

  def execute_command(command)
    puts "実行コマンド: #{command.map(&:shellescape).join(' ')}"
    begin
      success = system(*command)
      unless success
        exit_status = ($?.respond_to?(:exitstatus) ? $?.exitstatus : 'unknown')
        warn("警告: コマンドの実行に失敗しました (終了ステータス: #{exit_status})")
      end
    rescue Errno::ENOENT
      abort("エラー: '#{@config['yt_dlp_path']}' コマンドが見つかりません。パスを確認してください。")
    rescue => e
      warn("エラー: コマンド実行中に予期せぬエラーが発生しました: #{e.message}")
      warn(e.backtrace.join("
"))
    end
  end
end

# :nocov:
if __FILE__ == $0
  SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
  CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')
  KEYWORDS_FILE = File.join(SCRIPT_DIR, 'podcast_keywords.yml')

  config = RadikoPodcastForMe.load_yaml_file(CONFIG_FILE)
  keywords = RadikoPodcastForMe.load_yaml_file(KEYWORDS_FILE)

  unless keywords.is_a?(Array)
    abort("エラー: #{KEYWORDS_FILE} はキーワードの配列を含む必要があります。")
  end

  downloader = PodcastDownloader.new(config, keywords)
  downloader.download
  puts "処理が完了しました。"
end
# :nocov:
