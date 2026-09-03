#!/usr/bin/env ruby

require 'rss'
require 'time'
require 'uri'
require_relative 'lib/common'
require_relative 'lib/atomic_file_writer'

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

      feeds = if config.key?('feeds')
                resolve_feeds(config)
              else
                validate_feed!(config)
                [config.dup]
              end
      validate_unique_rss_files!(feeds)
      feeds
    end

    def validate_feed!(config, label: '設定ファイル')
      validate_hash!(config, label)
      if config.key?('feeds')
        raise Error, "#{label} は展開済みの単一フィード設定である必要があります"
      end

      validate_required!(config, REQUIRED_KEYS, label)
      normalize_matchers(config['match'], label: "#{label}.match") if config.key?('match')
      validate_http_url!(config['base_url'], "#{label}のbase_url", allow_query_or_fragment: false)
      validate_http_url!(config['channel_link'], "#{label}のchannel_link")
      config
    end

    def normalize_matchers(matchers, label: 'match')
      return [] if matchers.nil?

      list = matchers.is_a?(Array) ? matchers : [matchers]
      invalid_indexes = list.each_index.reject do |index|
        list[index].is_a?(String) && !list[index].strip.empty?
      end
      unless invalid_indexes.empty?
        positions = invalid_indexes.map { |index| index + 1 }
        raise Error, "#{label} は空でない文字列で指定してください（対象: #{positions.join(', ')}番目）"
      end

      list.map do |matcher|
        if matcher.start_with?('/') && matcher.end_with?('/') && matcher.length >= 2
          begin
            Regexp.new(matcher[1..-2])
          rescue RegexpError => e
            raise Error, "#{label} の正規表現が無効です: #{matcher.inspect} - #{e.message}"
          end
        else
          matcher
        end
      end
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

    def validate_unique_rss_files!(feeds)
      paths = feeds.group_by do |feed|
        RadikoPodcastForMe.canonical_file_target(feed.fetch('rss_file').strip)
      end
      duplicates = paths.select { |_path, configs| configs.length > 1 }.keys
      return if duplicates.empty?

      raise Error, "rss_file が重複しています: #{duplicates.join(', ')}"
    rescue SystemCallError => e
      raise Error, "rss_file の出力先を確認できません: #{e.message}"
    end

    def validate_http_url!(value, label, allow_query_or_fragment: true)
      uri = URI.parse(value.strip)
      valid = uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
      valid &&= uri.query.nil? && uri.fragment.nil? unless allow_query_or_fragment
      return if valid

      qualifier = allow_query_or_fragment ? '' : 'クエリ・フラグメントのない'
      raise Error, "#{label} は#{qualifier}HTTP(S) URLで指定してください"
    rescue URI::InvalidURIError => e
      raise Error, "#{label} が正しいURLではありません: #{e.message}"
    end
  end
end

class RssGenerator
  class Error < StandardError; end

  SUPPORTED_EXTENSIONS = RadikoPodcastForMe::SUPPORTED_AUDIO_EXTENSIONS
  DATE_FORMAT_IN_TITLE = '%Y-%m-%d'
  FILENAME_DATE_PATTERN = /\d{14}/
  FILENAME_DATE_FORMAT = '%Y%m%d%H%M%S'
  INVALID_XML_CHARACTERS = /[\u{0}-\u{8}\u{b}\u{c}\u{e}-\u{1f}\u{fffe}\u{ffff}]/

  def initialize(
    config,
    writer: RadikoPodcastForMe::AtomicFileWriter.new,
    out: $stdout,
    err: $stderr
  )
    @config = config
    validate_config
    @audio_dir = @config['audio_dir'].strip
    @output_file = @config['rss_file'].strip
    @base_url = @config['base_url'].strip.chomp('/') + '/'
    @matchers = RssConfigResolver.normalize_matchers(@config['match'])
    @writer = writer
    @out = out
    @err = err
  end

  def generate
    items_succeeded = true
    rss_content = RSS::Maker.make("2.0") do |maker|
      setup_channel(maker)
      items_succeeded = add_items(maker)
    end

    if !items_succeeded && rss_content.items.empty?
      @err.puts "エラー: 有効なRSSアイテムを生成できなかったため、既存のRSSフィードを保持しました: #{@output_file}"
      return false
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
    maker.channel.link = xml_text(@config['channel_link'].strip)
    maker.channel.description = xml_text(@config['channel_description'])
    maker.channel.language = xml_text(@config.fetch('channel_language', 'ja'))
  end

  def add_items(maker)
    files = get_audio_files
    files = filter_files(files)
    if files.empty?
      @out.puts "INFO: 対象の音声ファイル (#{SUPPORTED_EXTENSIONS.join(', ')}) が見つかりませんでした in #{@audio_dir}"
      return true
    end

    @out.puts "INFO: #{files.count}個の音声ファイルを処理します..."
    item_results = files.map do |file|
      create_rss_item(maker, file)
    end

    if maker.items.empty? && !files.empty?
      @err.puts "WARN: 音声ファイルは見つかりましたが、有効なRSSアイテムは生成されませんでした。"
    end

    item_results.all?
  end

  def get_audio_files
    unless Dir.exist?(@audio_dir)
      raise Error, "音声ファイルディレクトリが見つかりません: #{@audio_dir}"
    end
    Dir.each_child(@audio_dir).each_with_object([]) do |name, files|
      next if name.start_with?('.')

      path = File.join(@audio_dir, name)
      files << path if File.file?(path) && RadikoPodcastForMe.supported_audio_file?(path)
    end.sort
  rescue SystemCallError => e
    raise Error, "音声ファイルディレクトリを読み込めません: #{@audio_dir} - #{e.message}"
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
    @out.puts "  処理中: #{filename}"

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
    @err.puts "警告: ファイルが見つかりません (スキップ): #{file}"
    nil
  rescue MiniExiftool::Error => e
    @err.puts "警告: Exif情報取得エラー (#{e.message}) (スキップ): #{file}"
    nil
  rescue SystemCallError => e
    @err.puts "警告: ファイル情報が取得できませんでした (スキップ): #{file} - #{e.message}"
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
        @err.puts "警告: ファイル名 '#{filename}' の日付文字列 '#{date_match[0]}' を解析できません。"
      end
    else
      @err.puts "警告: ファイル名 '#{filename}' に日付パターン '#{FILENAME_DATE_PATTERN}' が見つかりません。"
    end
    pub_date ||= create_date if create_date.is_a?(Time)
    unless pub_date
      begin
        pub_date = File.mtime(file)
      rescue SystemCallError => e
        @err.puts "警告: ファイルの更新日時が取得できませんでした: #{file} - #{e.message}"
      end
    end
    pub_date
  end

  def write_rss_file(rss_content)
    begin
      @writer.write(@output_file, rss_content.to_s)
    rescue SystemCallError, IOError => e
      raise Error, "RSSファイルの書き込みに失敗しました: #{@output_file} - #{e.message}"
    end
    @out.puts "RSSフィードを生成しました: #{@output_file}"
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
  def initialize(
    config,
    generator_class: RssGenerator,
    writer: RadikoPodcastForMe::AtomicFileWriter.new,
    out: $stdout,
    err: $stderr
  )
    @config = config
    @generator_class = generator_class
    @writer = writer
    @out = out
    @err = err
  end

  def run
    succeeded = true
    RssConfigResolver.resolve(@config).each do |feed_config|
      begin
        feed_succeeded = @generator_class.new(
          feed_config,
          writer: @writer,
          out: @out,
          err: @err
        ).generate
        succeeded = false unless feed_succeeded
      rescue RssGenerator::Error => e
        label = feed_config['name'] || feed_config['rss_file']
        @err.puts "エラー: RSSフィードの生成に失敗しました (#{label}): #{e.message}"
        succeeded = false
      end
    end
    succeeded
  end
end

module PodcastRssCLI
  module_function

  def run(config:, out: $stdout, err: $stderr, **dependencies)
    if RssRunner.new(config, out: out, err: err, **dependencies).run
      0
    else
      err.puts 'エラー: 一部のRSSフィードを生成できませんでした。'
      1
    end
  rescue RssConfigResolver::Error => e
    err.puts "エラー: #{e.message}"
    1
  end

  def run_from_file(config_path:, out: $stdout, err: $stderr, **dependencies)
    config = RadikoPodcastForMe.load_yaml_file(config_path)
    run(config: config, out: out, err: err, **dependencies)
  rescue RadikoPodcastForMe::ConfigurationFileError => e
    err.puts "エラー: #{e.message}"
    1
  end
end

# :nocov:
if __FILE__ == $0
  SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
  CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')

  exit PodcastRssCLI.run_from_file(config_path: CONFIG_FILE)
end
# :nocov:
