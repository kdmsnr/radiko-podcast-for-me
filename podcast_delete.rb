#!/usr/bin/env ruby

require 'fileutils'
require 'date'
require_relative 'lib/common'

class PodcastDeleter
  class ConfigurationError < ArgumentError; end

  INTEGER_STRING = /\A[+-]?\d+\z/

  def initialize(
    config,
    today: -> { Date.today },
    stat: ->(path) { File.stat(path) },
    remover: ->(path) { FileUtils.rm(path) },
    out: $stdout,
    err: $stderr
  )
    @config = config
    validate_config
    @today = today
    @stat = stat
    @remover = remover
    @out = out
    @err = err
  end

  def delete_old_files
    unless Dir.exist?(@directory)
      @err.puts("エラー: 指定されたディレクトリが存在しません: #{@directory}")
      return false
    end

    threshold_date = @today.call << @expire_months
    threshold_time = threshold_date.to_time

    @out.puts "INFO: 保持期間: #{@expire_months}ヶ月"
    @out.puts "INFO: #{threshold_time} より前の最終更新日時のファイルを削除します。"

    success = true
    begin
      Dir.each_child(@directory) do |name|
        next if name.start_with?('.')

        path = File.join(@directory, name)
        success = false unless process_path(path, threshold_time)
      end
    rescue SystemCallError => e
      @err.puts("エラー: ディレクトリの読み取りに失敗しました: #{@directory} - #{e.message}")
      return false
    end
    success
  end

  private

  def validate_config
    unless @config.is_a?(Hash)
      raise ConfigurationError, '設定ファイルのルートはハッシュである必要があります。'
    end

    required_keys = %w[audio_dir expire_month]
    missing_keys = required_keys.reject { |key| @config.key?(key) && !@config[key].nil? }
    unless missing_keys.empty?
      raise ConfigurationError, "設定ファイルに必要なキーが不足しています: #{missing_keys.join(', ')}"
    end

    @directory = @config['audio_dir']
    unless @directory.is_a?(String) && !@directory.strip.empty?
      raise ConfigurationError, "'audio_dir' は空でない文字列で指定してください。"
    end
    @expire_months = parse_expire_month(@config['expire_month'])
  end

  def parse_expire_month(value)
    expire_months = case value
                    when Integer
                      value
                    when String
                      raise ArgumentError unless INTEGER_STRING.match?(value)

                      Integer(value, 10)
                    else
                      raise TypeError
                    end

    raise TypeError unless expire_months.positive?

    expire_months
  rescue ArgumentError, TypeError
    raise ConfigurationError, "'expire_month' は正の整数で指定してください" \
                              "（現在値: #{value.inspect}, 型: #{value.class}）。"
  end

  def process_path(path, threshold_time)
    begin
      file_stat = @stat.call(path)
      return true unless file_stat.file?
      return true unless file_stat.mtime < threshold_time
    rescue Errno::ENOENT
      return true
    rescue SystemCallError => e
      @err.puts("警告: ファイル情報の取得に失敗しました: #{path} - #{e.message}")
      return false
    end

    begin
      @remover.call(path)
      @out.puts "削除しました: #{path}"
      true
    rescue Errno::ENOENT
      true
    rescue SystemCallError => e
      @err.puts("警告: ファイルの削除に失敗しました: #{path} - #{e.message}")
      false
    end
  end
end

module PodcastDeleteRunner
  def self.run(config, out: $stdout, err: $stderr, **dependencies)
    deleter = PodcastDeleter.new(config, out: out, err: err, **dependencies)
    if deleter.delete_old_files
      out.puts "処理が完了しました。"
      0
    else
      err.puts "エラー: 一部のファイルを処理できませんでした。"
      1
    end
  rescue PodcastDeleter::ConfigurationError => e
    err.puts "エラー: #{e.message}"
    1
  end
end

# :nocov:
if __FILE__ == $0
  SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
  CONFIG_FILE = File.join(SCRIPT_DIR, 'config.yml')

  config = RadikoPodcastForMe.load_yaml_file(CONFIG_FILE)
  exit PodcastDeleteRunner.run(config)
end
# :nocov:
