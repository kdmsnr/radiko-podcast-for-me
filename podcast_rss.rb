#!/usr/bin/env ruby

require 'rss'
require 'fileutils'
require 'cgi'
require 'time'
require 'uri'
require 'yaml'
require 'mini_exiftool'

config = YAML.load_file(File.join(File.dirname(__FILE__), 'config.yml'))
audio_dir = config['audio_dir']
output_file = config['rss_file']
base_url = config['base_url']

def h(text)
  CGI.escapeHTML(text)
end

def u(text)
  URI::DEFAULT_PARSER.escape(text, /[^a-zA-Z0-9\-\._~]/)
end

rss = RSS::Maker.make("2.0") do |maker|
  maker.encoding = "UTF-8"
  maker.channel.title = config['channel_title']
  maker.channel.link = config['channel_link']
  maker.channel.description = config['channel_description']
  maker.channel.language = "ja"

  files = Dir.glob("#{audio_dir}/*.{mp3,m4a}").sort_by { |file| File.mtime(file) }
  files.each do |file|
    exif = MiniExiftool.new(file)
    maker.items.new_item do |item|
      filename = File.basename(file)
      item.link = base_url + u(filename)
      item.title = h(exif.title + ' - ' + exif.contentcreatedate.to_s)
      item.description = h(exif.description)
      item.enclosure.url = item.link
      item.enclosure.length = exif.mediadatasize.to_s
      item.enclosure.type = "audio/mpeg"
      item.pubDate = Time.strptime(filename[/\d{14}/], '%Y%m%d%H%M%S').rfc822 rescue nil
      item.guid.content = item.link
      item.guid.isPermaLink = true
    end
  end
end

File.write(output_file, rss.to_s, encoding: "UTF-8")
puts "RSS feed generated at #{output_file}"
