require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'rss'
require_relative '../podcast_rss'

class PodcastRssTest < Minitest::Test
  def setup
    MiniExiftool.reset if MiniExiftool.respond_to?(:reset)
  end

  def test_generate_creates_rss_with_items
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      rss_file = File.join(dir, 'rss.xml')
      config = base_config(audio_dir, rss_file)
      first = File.join(audio_dir, 'show_20240101000000.mp3')
      second = File.join(audio_dir, 'show_20240202000000.m4a')
      File.write(first, 'data1')
      File.write(second, 'data2')
      MiniExiftool.register(first, {
        mediadatasize: 2048,
        title: 'First Show',
        contentcreatedate: Time.new(2024, 1, 3, 10, 0, 0, '+00:00'),
        description: 'desc1'
      })
      MiniExiftool.register(second, {
        mediadatasize: nil,
        title: '',
        contentcreatedate: nil,
        description: 'desc2'
      })
      generator = RssGenerator.new(config)
      generator.generate
      rss = RSS::Parser.parse(File.read(rss_file), false)
      assert_equal 'My Podcast', rss.channel.title
      assert_equal 2, rss.items.size
      first_item = rss.items.first
      assert_equal 'First Show - 2024-01-03', first_item.title
      assert_equal 'desc1', first_item.description
      assert_equal 'http://example.com/files/show_20240101000000%2Emp3', first_item.enclosure.url
      assert_equal 2048, first_item.enclosure.length
      second_item = rss.items.last
      assert_equal 'show_20240202000000.m4a', second_item.title
      assert_equal 'desc2', second_item.description
      assert_equal 'http://example.com/files/show_20240202000000%2Em4a', second_item.enclosure.url
      assert_equal File.size(second), second_item.enclosure.length
    end
  end

  def test_generate_raises_when_audio_dir_missing
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'missing')
      rss_file = File.join(dir, 'rss.xml')
      config = base_config(audio_dir, rss_file)
      generator = RssGenerator.new(config)
      assert_raises(SystemExit) do
        generator.generate
      end
    end
  end

  def test_generate_with_no_audio_files_creates_empty_feed
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      rss_file = File.join(dir, 'rss.xml')
      generator = RssGenerator.new(base_config(audio_dir, rss_file))
      generator.generate
      rss = RSS::Parser.parse(File.read(rss_file), false)
      assert_empty rss.items
    end
  end

  def test_initialize_with_missing_config_key
    config = {
      'audio_dir' => '/tmp',
      'rss_file' => '/tmp/rss.xml'
    }
    assert_raises(SystemExit) do
      RssGenerator.new(config)
    end
  end

  def test_create_rss_item_handles_missing_exif_file
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      file = File.join(audio_dir, 'missing_20240101000000.mp3')
      File.write(file, 'data')
      generator = RssGenerator.new(base_config(audio_dir, File.join(dir, 'rss.xml')))
      maker = RSS::Maker.make("2.0") do |m|
        m.channel.title = 't'
        m.channel.link = 'http://example.com'
        m.channel.description = 'desc'
      end
      _stdout, stderr = capture_io do
        generator.send(:create_rss_item, maker, file)
      end
      assert_match(/警告: ファイルが見つかりません/, stderr)
    end
  end

  def test_extract_pub_date_without_pattern_uses_mtime
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'episode.mp3')
      File.write(file, 'x')
      config = base_config(dir, File.join(dir, 'rss.xml'))
      generator = RssGenerator.new(config)
      pub_date = generator.send(:extract_pub_date, 'episode.mp3', nil, file)
      assert_in_delta File.mtime(file), pub_date, 1
    end
  end

  def test_extract_pub_date_with_invalid_timestamp_warns
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'episode_20241301000000.mp3')
      File.write(file, 'x')
      config = base_config(dir, File.join(dir, 'rss.xml'))
      generator = RssGenerator.new(config)
      result = nil
      stdout, stderr = capture_io do
        result = generator.send(:extract_pub_date, 'episode_20241301000000.mp3', Time.now, file)
      end
      refute_nil result
      assert_equal '', stdout
      assert_match(/解析できません/, stderr)
    end
  end

  def test_mime_type_defaults_to_octet_stream
    generator = RssGenerator.new(base_config('/tmp', '/tmp/rss.xml'))
    assert_equal 'application/octet-stream', generator.send(:mime_type, 'file.wav')
  end

  def test_helpers_escape_values
    generator = RssGenerator.new(base_config('/tmp', '/tmp/rss.xml'))
    assert_equal 'a&amp;b', generator.send(:h, 'a&b')
    assert_equal 'file%20name%2Emp3', generator.send(:u, 'file name.mp3')
  end

  private

  def base_config(audio_dir, rss_file)
    {
      'audio_dir' => audio_dir,
      'rss_file' => rss_file,
      'base_url' => 'http://example.com/files',
      'channel_title' => 'My Podcast',
      'channel_link' => 'http://example.com',
      'channel_description' => 'desc'
    }
  end
end
