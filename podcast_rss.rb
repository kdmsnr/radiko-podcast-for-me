#!/usr/bin/env ruby

require 'rss'
require 'fileutils'
require 'cgi'
require 'time'
require 'uri'
require 'yaml'
begin
  require 'mini_exiftool'
rescue LoadError => e
  abort "エラー: 必要な gem 'mini_exiftool' がインストールされていないか、ロードできません。\n" \
        "`gem install mini_exiftool` を実行してください。\n詳細: #{e.message}"
end

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')
SUPPORTED_EXTENSIONS = %w[.mp3 .m4a].freeze
DATE_FORMAT_IN_TITLE = '%Y-%m-%d'
FILENAME_DATE_PATTERN = /\d{14}/
FILENAME_DATE_FORMAT = '%Y%m%d%H%M%S'

def h(text)
  CGI.escapeHTML(text.to_s)
end

def u(text)
  URI::DEFAULT_PARSER.escape(text.to_s, /[^a-zA-Z0-9\-\._~]/)
end

def mime_type(filename)
  case File.extname(filename).downcase
  when '.mp3' then 'audio/mpeg'
  when '.m4a' then 'audio/mp4'
  else 'application/octet-stream'
  end
end

def load_config(filepath)
  begin
    YAML.load_file(filepath)
  rescue Errno::ENOENT
    abort("エラー: 設定ファイルが見つかりません: #{filepath}")
  rescue Psych::SyntaxError => e
    abort("エラー: 設定ファイルの形式が正しくありません: #{filepath} - #{e.message}")
  end
end

def create_rss_item(maker, file, base_url)
  filename = File.basename(file)
  puts "  処理中: #{filename}"

  begin
    exif = MiniExiftool.new(file, ignore_minor_errors: true)
  rescue Errno::ENOENT
    warn "警告: ファイルが見つかりません (スキップ): #{file}"
    return
  rescue MiniExiftool::Error => e
    warn "警告: Exif情報取得エラー (#{e.message}) (スキップ): #{file}"
    return
  rescue => e
    warn "警告: 予期せぬExif情報取得エラー (#{e.class}: #{e.message}) (スキップ): #{file}"
    return
  end

  title = exif.title
  create_date = exif.contentcreatedate
  description = exif.description
  file_size = exif.mediadatasize

  unless file_size
    warn "警告: ファイルサイズ(MediaDataSize)が取得できませんでした (スキップ): #{file}"
    return
  end

  item_title = title.to_s.empty? ? filename : title.to_s
  if create_date.is_a?(Time)
    item_title += " - #{create_date.strftime(DATE_FORMAT_IN_TITLE)}"
  end

  item_url = URI.join(base_url, u(filename)).to_s

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

  maker.items.new_item do |item|
    item.link = item_url
    item.title = h(item_title)
    item.description = h(description)
    item.pubDate = pub_date&.rfc822
    item.guid.content = item_url
    item.guid.isPermaLink = true
    item.enclosure.url = item_url
    item.enclosure.length = file_size.to_s
    item.enclosure.type = mime_type(filename)
  end

rescue => e
  warn "警告: RSSアイテム生成中にエラーが発生しました (#{e.class}: #{e.message}) (スキップ): #{file}"
  warn e.backtrace.first
end

def generate_rss(config)
  required_keys = %w[audio_dir rss_file base_url channel_title channel_link channel_description]
  missing_keys = required_keys.reject { |k| config[k] }
  unless missing_keys.empty?
    abort("エラー: 設定ファイルに必要なキーが不足しています: #{missing_keys.join(', ')}")
  end

  audio_dir = config['audio_dir']
  output_file = config['rss_file']
  base_url = config['base_url'].chomp('/') + '/'

  unless Dir.exist?(audio_dir)
    abort("エラー: 音声ファイルディレクトリが見つかりません: #{audio_dir}")
  end

  glob_pattern = File.join(audio_dir, "*")
  files = Dir.glob(glob_pattern).select do |f|
    File.file?(f) && SUPPORTED_EXTENSIONS.include?(File.extname(f).downcase)
  end.sort

  puts "INFO: RSSフィードの生成を開始します..."
  rss_content = RSS::Maker.make("2.0") do |maker|
    maker.encoding = "UTF-8"
    maker.channel.title = config['channel_title']
    maker.channel.link = config['channel_link']
    maker.channel.description = config['channel_description']
    maker.channel.language = config.fetch('channel_language', 'ja')

    if files.empty?
      puts "INFO: 対象の音声ファイル (#{SUPPORTED_EXTENSIONS.join(', ')}) が見つかりませんでした in #{audio_dir}"
    else
      puts "INFO: #{files.count}個の音声ファイルを処理します..."
      files.each do |file|
        create_rss_item(maker, file, base_url)
      end
    end

    if maker.items.empty? && !files.empty?
      warn "WARN: 音声ファイルは見つかりましたが、有効なRSSアイテムは生成されませんでした。"
    end
  end

  begin
    File.write(output_file, rss_content.to_s, encoding: "UTF-8")
    puts "RSSフィードを生成しました: #{output_file}"
  rescue => e
    abort("エラー: RSSファイルの書き込みに失敗しました: #{output_file} - #{e.message}")
  end
end

if __FILE__ == $0
  config = load_config(CONFIG_FILE)
  generate_rss(config)
end
