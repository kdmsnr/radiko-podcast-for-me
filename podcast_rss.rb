#!/usr/bin/env ruby

require 'rss'
require 'time'
require 'uri'
require_relative 'lib/common'

begin
  require 'mini_exiftool'
rescue LoadError => e
  abort "エラー: 必要な gem 'mini_exiftool' がインストールされていないか、ロードできません。\n" \
        "`gem install mini_exiftool` を実行してください。\n詳細: #{e.message}"
end

class RssConfigResolver
  class Error < StandardError; end

  SHARED_KEYS = %w[audio_dir base_url].freeze
  FEED_KEYS = %w[rss_file channel_title channel_link channel_description].freeze
  REQUIRED_KEYS = (SHARED_KEYS + FEED_KEYS).freeze

  class << self
    def resolve(config)
      validate_hash!(config, '設定ファイル')

      if config.key?('feeds')
        resolve_feeds(config)
      else
        validate_feed!(config)
        [config.dup]
      end
    end

    def validate_feed!(config, label: '設定ファイル')
      validate_hash!(config, label)
      if config.key?('feeds')
        raise Error, "#{label} は展開済みの単一フィード設定である必要があります"
      end

      validate_required!(config, REQUIRED_KEYS, label)
      config
    end

    private

    def resolve_feeds(config)
      feeds = config['feeds']
      unless feeds.is_a?(Array)
        raise Error, 'feeds は配列である必要があります'
      end
      if feeds.empty?
        raise Error, 'feeds には1件以上のフィード設定が必要です'
      end

      validate_required!(config, SHARED_KEYS, '設定ファイル')
      base_config = config.reject { |key, _| key == 'feeds' }

      feeds.each_with_index.map do |feed, index|
        label = "feeds[#{index}]"
        validate_hash!(feed, label)
        label = feed['name'] || label
        resolved = base_config.merge(feed)
        validate_feed!(resolved, label: label)
        resolved
      end
    end

    def validate_hash!(config, label)
      return if config.is_a?(Hash)

      raise Error, "#{label} はハッシュである必要があります"
    end

    def validate_required!(config, required_keys, label)
      missing = required_keys.reject { |key| config.key?(key) && !config[key].nil? }
      unless missing.empty?
        raise Error, "#{label}に必要なキーが不足しています: #{missing.join(', ')}"
      end

      invalid = required_keys.reject do |key|
        config[key].is_a?(String) && !config[key].strip.empty?
      end
      return if invalid.empty?

      raise Error, "#{label}の値は空でない文字列で指定してください: #{invalid.join(', ')}"
    end
  end
end

class RssGenerator
  SUPPORTED_EXTENSIONS = %w[.mp3 .m4a].freeze
  DATE_FORMAT_IN_TITLE = '%Y-%m-%d'
  FILENAME_DATE_PATTERN = /\d{14}/
  FILENAME_DATE_FORMAT = '%Y%m%d%H%M%S'
  INVALID_XML_CHARACTERS = /[\u{0}-\u{8}\u{b}\u{c}\u{e}-\u{1f}\u{fffe}\u{ffff}]/

  def initialize(config)
    @config = config
    validate_config
    @audio_dir = @config['audio_dir']
    @base_url = @config['base_url'].chomp('/') + '/'
    @matchers = normalize_matchers(@config['match'])
  end

  def generate
    items_succeeded = true
    rss_content = RSS::Maker.make("2.0") do |maker|
      setup_channel(maker)
      items_succeeded = add_items(maker)
    end

    write_rss_file(rss_content)
    items_succeeded
  end

  private

  def validate_config
    RssConfigResolver.validate_feed!(@config)
  end

  def setup_channel(maker)
    maker.encoding = "UTF-8"
    maker.channel.title = xml_text(@config['channel_title'])
    maker.channel.link = xml_text(@config['channel_link'])
    maker.channel.description = xml_text(@config['channel_description'])
    maker.channel.language = xml_text(@config.fetch('channel_language', 'ja'))
  end

  def add_items(maker)
    files = get_audio_files
    files = filter_files(files)
    if files.empty?
      puts "INFO: 対象の音声ファイル (#{SUPPORTED_EXTENSIONS.join(', ')}) が見つかりませんでした in #{@audio_dir}"
    else
      puts "INFO: #{files.count}個の音声ファイルを処理します..."
      item_results = files.map do |file|
        create_rss_item(maker, file)
      end
    end

    if maker.items.empty? && !files.empty?
      warn "WARN: 音声ファイルは見つかりましたが、有効なRSSアイテムは生成されませんでした。"
    end

    files.empty? || item_results.all?
  end

  def get_audio_files
    unless Dir.exist?(@audio_dir)
      abort("エラー: 音声ファイルディレクトリが見つかりません: #{@audio_dir}")
    end
    Dir.each_child(@audio_dir).each_with_object([]) do |name, files|
      next if name.start_with?('.')

      path = File.join(@audio_dir, name)
      files << path if File.file?(path) && SUPPORTED_EXTENSIONS.include?(File.extname(path).downcase)
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

    metadata = read_audio_metadata(file)
    return false unless metadata

    item_title = build_item_title(filename, metadata[:title], metadata[:create_date])
    item_url = URI.join(@base_url, u(filename)).to_s
    pub_date = extract_pub_date(filename, metadata[:create_date], file)

    maker.items.new_item do |item|
      item.link = item_url
      item.title = xml_text(item_title)
      item.description = xml_text(metadata[:description])
      item.pubDate = pub_date&.rfc822
      item.guid.content = item_url
      item.guid.isPermaLink = true
      item.enclosure.url = item_url
      item.enclosure.length = metadata[:file_size].to_s
      item.enclosure.type = mime_type(filename)
    end

    true
  end

  def read_audio_metadata(file)
    exif = MiniExiftool.new(file, ignore_minor_errors: true)
    file_size = exif.mediadatasize
    file_size = File.size(file) if file_size.nil?

    {
      file_size: file_size,
      title: exif.title,
      create_date: exif.contentcreatedate,
      description: exif.description
    }
  rescue Errno::ENOENT
    warn "警告: ファイルが見つかりません (スキップ): #{file}"
    nil
  rescue MiniExiftool::Error => e
    warn "警告: Exif情報取得エラー (#{e.message}) (スキップ): #{file}"
    nil
  rescue SystemCallError => e
    warn "警告: ファイル情報が取得できませんでした (スキップ): #{file} - #{e.message}"
    nil
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
    unless pub_date
      begin
        pub_date = File.mtime(file)
      rescue SystemCallError => e
        warn "警告: ファイルの更新日時が取得できませんでした: #{file} - #{e.message}"
      end
    end
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

  def u(text)
    URI::DEFAULT_PARSER.escape(text.to_s, /[^a-zA-Z0-9\-_~]/)
  end

  def xml_text(value)
    text = value.to_s
    text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    text.scrub("\uFFFD").gsub(INVALID_XML_CHARACTERS, "\uFFFD")
  end

  def mime_type(filename)
    case File.extname(filename).downcase
    when '.mp3' then 'audio/mpeg'
    when '.m4a' then 'audio/mp4'
    else 'application/octet-stream'
    end
  end
end

class RssRunner
  def initialize(config, generator_class: RssGenerator)
    @config = config
    @generator_class = generator_class
  end

  def run
    succeeded = true
    RssConfigResolver.resolve(@config).each do |feed_config|
      feed_succeeded = @generator_class.new(feed_config).generate
      succeeded = false unless feed_succeeded
    end
    succeeded
  end
end

# :nocov:
if __FILE__ == $0
  SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
  CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')

  begin
    config = RadikoPodcastForMe.load_yaml_file(CONFIG_FILE)
    succeeded = RssRunner.new(config).run
  rescue RssConfigResolver::Error => e
    abort("エラー: #{e.message}")
  end
  exit(false) unless succeeded
end
# :nocov:
