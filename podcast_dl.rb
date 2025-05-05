#!/usr/bin/env ruby

require 'yaml'
require 'shellwords'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')
KEYWORDS_FILE = File.join(SCRIPT_DIR, 'podcast_keywords.yml')

def load_yaml_file(filepath)
  begin
    YAML.load_file(filepath)
  rescue Errno::ENOENT
    abort("エラー: ファイルが見つかりません: #{filepath}")
  rescue Psych::SyntaxError => e
    abort("エラー: YAMLファイルの形式が正しくありません: #{filepath} - #{e.message}")
  end
end

def download_podcasts(config, keywords)
  area_id = config['area_id']
  output_dir = config['audio_dir']
  yt_dlp_path = config['yt_dlp_path']
  download_count = config.fetch('download_count', 5)

  base_options = [
    '-x',                      # 音声のみ抽出
    '-N', download_count.to_s, # ダウンロードする最大数
    '--embed-metadata',        # メタデータを埋め込む
    '--playlist-reverse',      # プレイリストを逆順に処理
    '-P', output_dir,          # 出力ディレクトリ
  ]

  keywords.each do |keyword|
    search_url = "https://radiko.jp/#!/search/live?key=#{keyword}&filter=past&area_id=#{area_id}"

    command = [yt_dlp_path] + base_options + [search_url]
    puts "実行コマンド: #{command.map(&:shellescape).join(' ')}"
    begin
      success = system(*command)
      unless success
        warn("警告: コマンドの実行に失敗しました (終了ステータス: #{$?.exitstatus})")
      end
    rescue Errno::ENOENT
      abort("エラー: '#{yt_dlp_path}' コマンドが見つかりません。パスを確認してください。")
    rescue => e
      warn("エラー: コマンド実行中に予期せぬエラーが発生しました: #{e.message}")
      warn(e.backtrace.join("\n"))
    end
  end
end

if __FILE__ == $0
  config = load_yaml_file(CONFIG_FILE)
  keywords = load_yaml_file(KEYWORDS_FILE)

  unless config && config['area_id'] && config['audio_dir'] && config['yt_dlp_path']
    abort("エラー: #{CONFIG_FILE} に必要な設定 (area_id, audio_dir, yt_dlp_path) がありません。")
  end
  unless keywords.is_a?(Array)
     abort("エラー: #{KEYWORDS_FILE} はキーワードの配列を含む必要があります。")
  end

  download_podcasts(config, keywords)
  puts "処理が完了しました。"
end
