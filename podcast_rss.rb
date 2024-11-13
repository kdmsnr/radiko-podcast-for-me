#!/usr/bin/env ruby

require 'rss'
require 'fileutils'
require 'cgi'
require 'time'
require 'uri'

audio_dir = "/var/www/html/podcast/files"
output_file = "/var/www/html/podcast/rss.xml"
base_url = "http://raspberrypi.local/podcast/files/"

def h(text)
  CGI.escapeHTML(text)
end

def u(text)
  URI::DEFAULT_PARSER.escape(text, /[^a-zA-Z0-9\-\._~]/)
end

rss = RSS::Maker.make("2.0") do |maker|
  maker.encoding = "UTF-8"
  maker.channel.title = "kdmsnr local podcast"
  maker.channel.link = "http://raspberrypi.local"
  maker.channel.description = "Podcast description"
  maker.channel.language = "ja"

  files = Dir.glob("#{audio_dir}/*.{mp3,m4a}").sort_by { |file| File.mtime(file) }
  files.each do |file|
    maker.items.new_item do |item|
      filename = File.basename(file)
      item.title = h(filename)
      item.link = "#{base_url}#{u(filename)}"
      item.enclosure.url = item.link
      item.enclosure.length = File.size(file).to_s
      item.enclosure.type = "audio/mpeg"
      item.pubDate = File.mtime(file).rfc822
      item.guid.content = item.link
      item.guid.isPermaLink = true
    end
  end
end

File.write(output_file, rss.to_s, encoding: "UTF-8")
puts "RSS feed generated at #{output_file}"

