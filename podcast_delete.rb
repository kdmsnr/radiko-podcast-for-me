#!/usr/bin/env ruby

require 'yaml'
require 'fileutils'

config = YAML.load_file(File.join(File.dirname(__FILE__), 'config.yml'))
directory = config['audio_dir']
exit unless Dir.exist?(directory)

# 半年以上前のファイルを削除するスクリプト
six_months_ago = Time.now - (6 * 30 * 24 * 60 * 60) # 6ヶ月前

Dir.glob("#{directory}/*").each do |file|
  if File.file?(file) && File.mtime(file) < six_months_ago
    FileUtils.rm(file)
    puts "Deleted: #{file}"
  end
end
