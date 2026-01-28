#!/usr/bin/env ruby

require 'rss'
require 'fileutils'
require 'cgi'
require 'time'
require 'uri'
require_relative 'lib/common'

begin
  require 'mini_exiftool'
rescue LoadError => e
  abort "エラー: 必要な gem 'mini_exiftool' がインストールされていないか、ロードできません。\n" \
        "`gem install mini_exiftool` を実行してください。\n詳細: #{e.message}"
end

class RssGenerator
  SUPPORTED_EXTENSIONS = %w[.mp3 .m4a].freeze
  DATE_FORMAT_IN_TITLE = '%Y-%m-%d'
  FILENAME_DATE_PATTERN = /\d{14}/
  FILENAME_DATE_FORMAT = '%Y%m%d%H%M%S'

  def initialize(config)
    @config = config
    validate_config
    @audio_dir = @config['audio_dir']
    @base_url = @config['base_url'].chomp('/') + '/'
    @matchers = normalize_matchers(@config['match'])
  end

  def generate
    rss_content = RSS::Maker.make("2.0") do |maker|
      setup_channel(maker)
      add_items(maker)
    end

    write_rss_file(rss_content)
  end

  private

  def validate_config
    if @config['feeds']
      required_top = %w[audio_dir base_url]
      missing_top = required_top.reject { |k| @config[k] }
      unless missing_top.empty?
        abort("エラー: 設定ファイルに必要なキーが不足しています: #{missing_top.join(', ')}")
      end
      validate_feeds_config(@config['feeds'])
    else
      required_keys = %w[audio_dir rss_file base_url channel_title channel_link channel_description]
      missing_keys = required_keys.reject { |k| @config[k] }
      unless missing_keys.empty?
        abort("エラー: 設定ファイルに必要なキーが不足しています: #{missing_keys.join(', ')}")
      end
    end
  end

  def validate_feeds_config(feeds)
    unless feeds.is_a?(Array)
      abort("エラー: feeds は配列である必要があります")
    end
    feeds.each_with_index do |feed, idx|
      unless feed.is_a?(Hash)
        abort("エラー: feeds[#{idx}] はハッシュである必要があります")
      end
      required_feed = %w[rss_file channel_title channel_link channel_description]
      missing = required_feed.reject { |k| feed[k] || @config[k] }
      unless missing.empty?
        name = feed['name'] || "feeds[#{idx}]"
        abort("エラー: #{name} に必要なキーが不足しています: #{missing.join(', ')}")
      end
    end
  end

  def setup_channel(maker)
    maker.encoding = "UTF-8"
    maker.channel.title = @config['channel_title']
    maker.channel.link = @config['channel_link']
    maker.channel.description = @config['channel_description']
    maker.channel.language = @config.fetch('channel_language', 'ja')
  end

  def add_items(maker)
    files = get_audio_files
    files = filter_files(files)
    if files.empty?
      puts "INFO: 対象の音声ファイル (#{SUPPORTED_EXTENSIONS.join(', ')}) が見つかりませんでした in #{@audio_dir}"
    else
      puts "INFO: #{files.count}個の音声ファイルを処理します..."
      files.each do |file|
        create_rss_item(maker, file)
      end
    end

    if maker.items.empty? && !files.empty?
      warn "WARN: 音声ファイルは見つかりましたが、有効なRSSアイテムは生成されませんでした。"
    end
  end

  def get_audio_files
    unless Dir.exist?(@audio_dir)
      abort("エラー: 音声ファイルディレクトリが見つかりません: #{@audio_dir}")
    end
    glob_pattern = File.join(@audio_dir, "*")
    Dir.glob(glob_pattern).select do |f|
      File.file?(f) && SUPPORTED_EXTENSIONS.include?(File.extname(f).downcase)
    end.sort
  end

  def normalize_matchers(matchers)
    return [] if matchers.nil?
    list = matchers.is_a?(Array) ? matchers : [matchers]
    list.map do |matcher|
      str = matcher.to_s
      if str.start_with?('/') && str.end_with?('/') && str.length >= 2
        begin
          Regexp.new(str[1..-2])
        rescue RegexpError
          warn "警告: 正規表現が無効です (#{str})。文字列一致として扱います。"
          str
        end
      else
        str
      end
    end
  end

  def filter_files(files)
    return files if @matchers.empty?
    files.select do |file|
      name = File.basename(file)
      @matchers.any? do |matcher|
        matcher.is_a?(Regexp) ? name.match?(matcher) : name.include?(matcher.to_s)
      end
    end
  end

  def create_rss_item(maker, file)
    filename = File.basename(file)
    puts "  処理中: #{filename}"

    begin
      exif = MiniExiftool.new(file, ignore_minor_errors: true)
      file_size = exif.mediadatasize
      if file_size.nil?
        begin
          file_size = File.size(file)
        rescue => e
          warn "警告: ファイルサイズが取得できませんでした (スキップ): #{file} - #{e.message}"
          return
        end
      end

      item_title = build_item_title(filename, exif.title, exif.contentcreatedate)
      item_url = URI.join(@base_url, u(filename)).to_s
      pub_date = extract_pub_date(filename, exif.contentcreatedate, file)

      maker.items.new_item do |item|
        item.link = item_url
        item.title = h(item_title)
        item.description = h(exif.description)
        item.pubDate = pub_date&.rfc822
        item.guid.content = item_url
        item.guid.isPermaLink = true
        item.enclosure.url = item_url
        item.enclosure.length = file_size.to_s
        item.enclosure.type = mime_type(filename)
      end

    rescue Errno::ENOENT
      warn "警告: ファイルが見つかりません (スキップ): #{file}"
    rescue MiniExiftool::Error => e
      warn "警告: Exif情報取得エラー (#{e.message}) (スキップ): #{file}"
    rescue => e
      warn "警告: RSSアイテム生成中にエラーが発生しました (#{e.class}: #{e.message}) (スキップ): #{file}"
      warn e.backtrace.first
    end
  end

  def build_item_title(filename, title, create_date)
    item_title = title.to_s.empty? ? filename : title.to_s
    if create_date.is_a?(Time)
      item_title += " - #{create_date.strftime(DATE_FORMAT_IN_TITLE)}"
    end
    item_title
  end

  def extract_pub_date(filename, create_date, file)
    pub_date = nil
    if (date_match = filename.match(FILENAME_DATE_PATTERN))
      begin
        pub_date = Time.strptime(date_match[0], FILENAME_DATE_FORMAT)
      rescue ArgumentError
        warn "警告: ファイル名 '#{filename}' の日付文字列 '#{date_match[0]}' を解析できません。"
      end
    else
      warn "警告: ファイル名 '#{filename}' に日付パターン '#{FILENAME_DATE_PATTERN}' が見つかりません。"
    end
    pub_date ||= create_date if create_date.is_a?(Time)
    pub_date ||= File.mtime(file) rescue nil
    pub_date
  end

  def write_rss_file(rss_content)
    output_file = @config['rss_file']
    begin
      File.write(output_file, rss_content.to_s, encoding: "UTF-8")
      puts "RSSフィードを生成しました: #{output_file}"
    rescue => e
      abort("エラー: RSSファイルの書き込みに失敗しました: #{output_file} - #{e.message}")
    end
  end

  def h(text)
    CGI.escapeHTML(text.to_s)
  end

  def u(text)
    URI::DEFAULT_PARSER.escape(text.to_s, /[^a-zA-Z0-9\-_~]/)
  end

  def mime_type(filename)
    case File.extname(filename).downcase
    when '.mp3' then 'audio/mpeg'
    when '.m4a' then 'audio/mp4'
    else 'application/octet-stream'
    end
  end
end

# :nocov:
if __FILE__ == $0
  SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
  CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')

  config = RadikoPodcastForMe.load_yaml_file(CONFIG_FILE)
  if config['feeds']
    base_config = config.reject { |k, _| k == 'feeds' }
    config['feeds'].each do |feed|
      merged_config = base_config.merge(feed)
      generator = RssGenerator.new(merged_config)
      generator.generate
    end
  else
    generator = RssGenerator.new(config)
    generator.generate
  end
end
# :nocov:
