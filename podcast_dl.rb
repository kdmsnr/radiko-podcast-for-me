#!/usr/bin/env ruby

require 'yaml'

config = YAML.load_file('config.yml')
area_id = config['area_id']
output_dir = config['audio_dir']
yt_dlp_path = config['yt_dlp_path']

keywords = YAML.load_file('podcast_keywords.yml')
keywords.each do |keyword|
  command = "#{yt_dlp_path} -x " \
            " -N 5 " \
            " --embed-metadata " \
            " --playlist-reverse " \
            " -P #{output_dir} " \
            "'https://radiko.jp/#!/search/live?key=#{keyword}&filter=past&area_id=#{area_id}'"
  puts "Executing: #{command}"
  system(command)
end
