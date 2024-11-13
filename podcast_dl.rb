#!/usr/bin/env ruby

require 'yaml'

keywords_file = 'podcast_keywords.yml'
output_dir = '/var/www/html/podcast/files'
yt_dlp_path = '/home/kdmsnr/.local/bin/yt-dlp'

keywords = YAML.load_file(keywords_file)
keywords.each do |keyword|
  command = "#{yt_dlp_path} -x " \
            " -N 5 " \
            " --embed-metadata " \
            " --download-archive archive --break-on-existing --break-per-input" \
            " --playlist-reverse " \
            " -P #{output_dir} " \
            "'https://radiko.jp/#!/search/live?key=#{keyword}&filter=past&area_id=JP13'"
  puts "Executing: #{command}"
  system(command)
end
