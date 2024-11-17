#!/usr/bin/env ruby

require 'yaml'
require 'fileutils'

config = YAML.load_file(File.join(File.dirname(__FILE__), 'config.yml'))
directory = config['audio_dir']
exit unless Dir.exist?(directory)

n_months_ago = Time.now - (config['expire_month'].to_i * 30 * 24 * 60 * 60)

Dir.glob("#{directory}/*").each do |file|
  if File.file?(file) && File.mtime(file) < n_months_ago
    FileUtils.rm(file)
    puts "Deleted: #{file}"
  end
end
