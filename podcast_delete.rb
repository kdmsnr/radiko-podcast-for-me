#!/usr/bin/env ruby

require 'fileutils'
require 'date'
require_relative 'lib/common'

class PodcastDeleter
  def initialize(config)
    @config = config
    validate_config
    @directory = @config['audio_dir']
    @expire_months = Integer(@config['expire_month'])
  end

  def delete_old_files
    unless Dir.exist?(@directory)
      abort("エラー: 指定されたディレクトリが存在しません: #{@directory}")
    end

    threshold_date = Date.today << @expire_months
    threshold_time = threshold_date.to_time

    puts "INFO: 保持期間: #{@expire_months}ヶ月"
    puts "INFO: #{threshold_time} より前の最終更新日時のファイルを削除します。"

    Dir.glob(File.join(@directory, '*')).each do |path|
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

  private

  def validate_config
    required_keys = %w[audio_dir expire_month]
    missing_keys = required_keys.reject { |k| @config[k] }
    unless missing_keys.empty?
      abort("エラー: 設定ファイルに必要なキーが不足しています: #{missing_keys.join(', ')}")
    end

    begin
      expire_months = Integer(@config['expire_month'])
      if expire_months <= 0
        abort("エラー: 'expire_month' は正の整数で指定してください（現在値: #{expire_months}）。")
      end
    rescue ArgumentError
      abort("エラー: 'expire_month' に有効な整数が指定されていません: #{@config['expire_month']}")
    end
  end
end

# :nocov:
if __FILE__ == $0
  SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
  CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')

  config = RadikoPodcastForMe.load_yaml_file(CONFIG_FILE)

  deleter = PodcastDeleter.new(config)
  deleter.delete_old_files

  puts "処理が完了しました。"
end
# :nocov:
