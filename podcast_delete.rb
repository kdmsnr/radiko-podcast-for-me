#!/usr/bin/env ruby

require 'yaml'
require 'fileutils'
require 'date'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')

def load_config(filepath)
  begin
    YAML.load_file(filepath)
  rescue Errno::ENOENT
    abort("エラー: 設定ファイルが見つかりません: #{filepath}")
  rescue Psych::SyntaxError => e
    abort("エラー: 設定ファイルの形式が正しくありません: #{filepath} - #{e.message}")
  end
end

# directory: 対象ディレクトリのパス
# expire_months: 保持期間（この月数より古いファイルを削除）
def delete_old_files(directory, expire_months)
  unless Dir.exist?(directory)
    abort("エラー: 指定されたディレクトリが存在しません: #{directory}")
  end

  threshold_date = Date.today << expire_months
  threshold_time = threshold_date.to_time

  puts "INFO: 保持期間: #{expire_months}ヶ月"
  puts "INFO: #{threshold_time} より前の最終更新日時のファイルを削除します。"

  Dir.glob(File.join(directory, '*')).each do |path|
    if File.file?(path) && File.mtime(path) < threshold_time
      begin
        FileUtils.rm(path)
        puts "削除しました: #{path}"
      rescue => e
        warn("警告: ファイルの削除に失敗しました: #{path} - #{e.message}")
      end
    end
  end
end

if __FILE__ == $0
  config = load_config(CONFIG_FILE)
  directory = config['audio_dir']
  expire_months_str = config['expire_month']

  unless directory
    abort("エラー: 設定ファイル '#{CONFIG_FILE}' に 'audio_dir' が指定されていません。")
  end
  unless expire_months_str
    abort("エラー: 設定ファイル '#{CONFIG_FILE}' に 'expire_month' が指定されていません。")
  end

  begin
    expire_months = Integer(expire_months_str)
    if expire_months <= 0
      abort("エラー: 'expire_month' は正の整数で指定してください（現在値: #{expire_months}）。")
    end
  rescue ArgumentError
    abort("エラー: 'expire_month' に有効な整数が指定されていません: #{expire_months_str}")
  end

  delete_old_files(directory, expire_months)

  puts "処理が完了しました。"
end
