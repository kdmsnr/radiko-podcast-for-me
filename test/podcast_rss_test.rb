require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'rss'
require 'stringio'
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
      error = assert_raises(RssGenerator::Error) do
        generator.generate
      end
      assert_match(/音声ファイルディレクトリ/, error.message)
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

  def test_generate_omits_artwork_when_channel_image_is_unconfigured_or_null
    [{}, { 'channel_image' => nil }].each do |image_config|
      Dir.mktmpdir do |dir|
        rss_file = File.join(dir, 'rss.xml')
        config = base_config(dir, rss_file).merge(image_config)

        assert RssGenerator.new(config, out: StringIO.new).generate

        rss = RSS::Parser.parse(File.read(rss_file), false)
        assert_nil rss.channel.itunes_image
        assert_nil rss.image
      end
    end
  end

  def test_generate_sets_itunes_and_rss_artwork_with_unescaped_values
    Dir.mktmpdir do |dir|
      rss_file = File.join(dir, 'rss.xml')
      image_url = 'https://example.com/cover.jpg?size=large&version=2'
      channel_link = 'https://example.com/podcast?show=rock&lang=ja'
      config = base_config(dir, rss_file).merge(
        'channel_image' => "  #{image_url}\n",
        'channel_title' => 'Rock & Roll <Live>',
        'channel_link' => channel_link
      )

      assert RssGenerator.new(config, out: StringIO.new).generate

      rss = RSS::Parser.parse(File.read(rss_file), false)
      assert_equal image_url, rss.channel.itunes_image.href
      assert_equal image_url, rss.image.url
      assert_equal 'Rock & Roll <Live>', rss.image.title
      assert_equal channel_link, rss.image.link
    end
  end

  def test_generate_maps_a_local_channel_image_to_an_escaped_public_url
    Dir.mktmpdir do |dir|
      rss_file = File.join(dir, 'rss.xml')
      image_path = './unused/../art work/cover & % # ? あ.jpg'
      config = base_config(dir, rss_file).merge(
        'base_url' => ' https://example.com/podcast/ ',
        'channel_image' => image_path
      )

      assert RssGenerator.new(config, out: StringIO.new).generate

      rss = RSS::Parser.parse(File.read(rss_file), false)
      expected_url = 'https://example.com/podcast/art%20work/cover%20%26%20%25%20%23%20%3F%20%E3%81%82.jpg'
      assert_equal expected_url, rss.channel.itunes_image.href
      assert_equal expected_url, rss.image.url
      refute File.exist?(File.expand_path(image_path, dir))
      assert_equal ['rss.xml'], Dir.children(dir)
    end
  end

  def test_generate_resolves_relative_and_absolute_channel_images_inside_audio_dir
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      working_dir = File.join(dir, 'elsewhere')
      FileUtils.mkdir_p([audio_dir, working_dir])
      rss_file = File.join(dir, 'rss.xml')
      images = {
        ' cover.jpg ' => 'cover.jpg',
        './art/../cover.jpg' => 'cover.jpg',
        File.join(audio_dir, 'art', '.', 'cover.jpg') => 'art/cover.jpg'
      }

      Dir.chdir(working_dir) do
        images.each do |image, public_path|
          config = base_config(audio_dir, rss_file).merge('channel_image' => image)

          assert RssGenerator.new(config, out: StringIO.new).generate

          rss = RSS::Parser.parse(File.read(rss_file), false)
          expected_url = "http://example.com/files/#{public_path}"
          assert_equal expected_url, rss.channel.itunes_image.href, image
          assert_equal expected_url, rss.image.url, image
        end
      end
    end
  end

  def test_generate_with_match_filters_items
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      rss_file = File.join(dir, 'rss.xml')
      config = base_config(audio_dir, rss_file).merge(
        'match' => ['news_', '/music_/']
      )
      news = File.join(audio_dir, 'news_20240101000000.mp3')
      music = File.join(audio_dir, 'music_20240102000000.mp3')
      other = File.join(audio_dir, 'other_20240103000000.mp3')
      File.write(news, 'data1')
      File.write(music, 'data2')
      File.write(other, 'data3')
      MiniExiftool.register(news, { mediadatasize: 1, title: '', contentcreatedate: nil, description: '' })
      MiniExiftool.register(music, { mediadatasize: 1, title: '', contentcreatedate: nil, description: '' })
      MiniExiftool.register(other, { mediadatasize: 1, title: '', contentcreatedate: nil, description: '' })

      generator = RssGenerator.new(config)
      generator.generate
      rss = RSS::Parser.parse(File.read(rss_file), false)
      assert_equal 2, rss.items.size
      titles = rss.items.map(&:title)
      assert_includes titles, 'news_20240101000000.mp3'
      assert_includes titles, 'music_20240102000000.mp3'
      refute_includes titles, 'other_20240103000000.mp3'
    end
  end

  def test_generate_treats_glob_characters_in_audio_directory_as_literals
    Dir.mktmpdir do |parent|
      audio_dir = File.join(parent, 'audio*')
      sibling_dir = File.join(parent, 'audio-other')
      FileUtils.mkdir_p([audio_dir, sibling_dir])
      rss_file = File.join(parent, 'rss.xml')
      included = File.join(audio_dir, 'included_20240101000000.mp3')
      excluded = File.join(sibling_dir, 'excluded_20240102000000.mp3')
      File.write(included, 'included')
      File.write(excluded, 'excluded')
      MiniExiftool.register(included, { mediadatasize: 8, title: 'Included', contentcreatedate: nil, description: '' })
      MiniExiftool.register(excluded, { mediadatasize: 8, title: 'Excluded', contentcreatedate: nil, description: '' })

      assert RssGenerator.new(base_config(audio_dir, rss_file)).generate

      rss = RSS::Parser.parse(File.read(rss_file), false)
      assert_equal ['Included'], rss.items.map(&:title)
    end
  end

  def test_initialize_with_missing_config_key
    config = {
      'audio_dir' => '/tmp',
      'rss_file' => '/tmp/rss.xml'
    }
    assert_raises(RssConfigResolver::Error) do
      RssGenerator.new(config)
    end
  end

  def test_config_resolver_rejects_blank_or_non_string_required_values
    config = base_config('/tmp/audio', '/tmp/rss.xml').merge(
      'audio_dir' => ' ',
      'channel_title' => 123
    )

    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end

    assert_match(/audio_dir, channel_title/, error.message)
  end

  def test_config_resolver_resolves_single_feed
    config = base_config('/tmp/audio', '/tmp/rss.xml')

    resolved = RssConfigResolver.resolve(config)

    assert_equal [config], resolved
    refute_same config, resolved.first
  end

  def test_config_resolver_rejects_empty_feeds
    config = base_config('/tmp/audio', '/tmp/rss.xml').merge('feeds' => [])

    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end

    assert_match(/1件以上/, error.message)
  end

  def test_config_resolver_rejects_invalid_feed_types
    config = base_config('/tmp/audio', '/tmp/rss.xml').merge('feeds' => 'news')
    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end
    assert_match(/feeds は配列/, error.message)

    config['feeds'] = [nil]
    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end
    assert_match(/feeds\[0\] はハッシュ/, error.message)
  end

  def test_config_resolver_inherits_top_level_feed_values
    config = base_config('/tmp/audio', '/tmp/default.xml').merge(
      'channel_language' => 'en',
      'match' => 'common_',
      'feeds' => [
        {
          'name' => 'news',
          'rss_file' => '/tmp/news.xml',
          'match' => 'news_'
        }
      ]
    )

    resolved = RssConfigResolver.resolve(config).first

    assert_equal '/tmp/audio', resolved['audio_dir']
    assert_equal 'My Podcast', resolved['channel_title']
    assert_equal 'en', resolved['channel_language']
    assert_equal '/tmp/news.xml', resolved['rss_file']
    assert_equal 'news_', resolved['match']
    refute resolved.key?('feeds')
  end

  def test_config_resolver_rejects_duplicate_rss_files
    Dir.mktmpdir do |dir|
      nested_dir = File.join(dir, 'feeds')
      FileUtils.mkdir_p(nested_dir)
      config = base_config('/tmp/audio', File.join(dir, 'default.xml')).merge(
        'feeds' => [
          { 'name' => 'news', 'rss_file' => File.join(dir, 'podcast.xml') },
          { 'name' => 'music', 'rss_file' => File.join(nested_dir, '..', 'podcast.xml') }
        ]
      )

      error = assert_raises(RssConfigResolver::Error) do
        RssConfigResolver.resolve(config)
      end

      assert_match(/rss_file が重複/, error.message)
    end
  end

  def test_config_resolver_rejects_symlinked_duplicate_rss_files
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'podcast.xml')
      link = File.join(dir, 'podcast-link.xml')
      File.write(target, 'existing feed')
      File.symlink(target, link)
      config = base_config('/tmp/audio', File.join(dir, 'default.xml')).merge(
        'feeds' => [
          { 'name' => 'linked', 'rss_file' => link },
          { 'name' => 'target', 'rss_file' => target }
        ]
      )

      error = assert_raises(RssConfigResolver::Error) do
        RssConfigResolver.resolve(config)
      end

      assert_match(/rss_file が重複/, error.message)
    end
  end

  def test_config_resolver_rejects_an_invalid_regexp_matcher
    config = base_config('/tmp/audio', '/tmp/rss.xml').merge('match' => '/[/')

    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end

    assert_match(/正規表現が無効/, error.message)
  end

  def test_config_resolver_rejects_invalid_matcher_types
    config = base_config('/tmp/audio', '/tmp/rss.xml').merge('match' => ['news', nil])

    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end

    assert_match(/2番目/, error.message)
  end

  def test_config_resolver_rejects_base_url_with_query
    config = base_config('/tmp/audio', '/tmp/rss.xml').merge(
      'base_url' => 'https://example.com/files?token=secret'
    )

    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end

    assert_match(/HTTP\(S\) URL/, error.message)
  end

  def test_config_resolver_rejects_a_non_http_channel_link
    config = base_config('/tmp/audio', '/tmp/rss.xml').merge(
      'channel_link' => 'javascript:alert(1)'
    )

    error = assert_raises(RssConfigResolver::Error) do
      RssConfigResolver.resolve(config)
    end

    assert_match(/channel_link.*HTTP\(S\) URL/, error.message)
  end

  def test_config_resolver_rejects_invalid_channel_images
    invalid_images = [
      '', ' ', 123, true, [], {},
      '/cover.jpg', 'file:///tmp/cover.jpg', 'ftp://example.com/cover.jpg',
      'javascript:alert(1)', 'data:image/png;base64,AAAA',
      'https://', 'http://[invalid', 'https://example.com/cover image.jpg'
    ]

    invalid_images.each do |image|
      config = base_config('/tmp/audio', '/tmp/rss.xml').merge('channel_image' => image)

      error = assert_raises(RssConfigResolver::Error, "channel_image: #{image.inspect}") do
        RssConfigResolver.resolve(config)
      end

      assert_match(/channel_image/, error.message, "channel_image: #{image.inspect}")
    end
  end

  def test_config_resolver_rejects_channel_image_paths_outside_audio_dir_or_pointing_to_it
    audio_dir = '/tmp/audio'
    invalid_paths = [
      '../cover.jpg', 'art/../../cover.jpg', '/tmp/audio-other/cover.jpg',
      '/tmp/cover.jpg', '.', './', 'art/..', audio_dir, "#{audio_dir}/"
    ]

    invalid_paths.each do |image|
      config = base_config(audio_dir, '/tmp/rss.xml').merge('channel_image' => image)

      error = assert_raises(RssConfigResolver::Error, "channel_image: #{image.inspect}") do
        RssConfigResolver.resolve(config)
      end

      assert_match(/channel_image/, error.message, "channel_image: #{image.inspect}")
    end
  end

  def test_runner_generates_multiple_filtered_feeds
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      news_rss_file = File.join(dir, 'news.xml')
      music_rss_file = File.join(dir, 'music.xml')
      default_rss_file = File.join(dir, 'default.xml')
      news = File.join(audio_dir, 'news_20240101000000.mp3')
      music = File.join(audio_dir, 'music_20240102000000.mp3')
      File.write(news, 'news')
      File.write(music, 'music')
      MiniExiftool.register(news, { mediadatasize: 4, title: 'News', contentcreatedate: nil, description: '' })
      MiniExiftool.register(music, { mediadatasize: 5, title: 'Music', contentcreatedate: nil, description: '' })
      config = base_config(audio_dir, default_rss_file).merge(
        'feeds' => [
          { 'rss_file' => news_rss_file, 'channel_title' => 'News Feed', 'match' => 'news_' },
          { 'rss_file' => music_rss_file, 'channel_title' => 'Music Feed', 'match' => 'music_' }
        ]
      )

      assert RssRunner.new(config).run

      news_rss = RSS::Parser.parse(File.read(news_rss_file), false)
      music_rss = RSS::Parser.parse(File.read(music_rss_file), false)
      assert_equal 'News Feed', news_rss.channel.title
      assert_equal ['News'], news_rss.items.map(&:title)
      assert_equal 'Music Feed', music_rss.channel.title
      assert_equal ['Music'], music_rss.items.map(&:title)
      refute File.exist?(default_rss_file)
    end
  end

  def test_runner_inherits_overrides_and_disables_channel_images_per_feed
    Dir.mktmpdir do |dir|
      inherited_rss_file = File.join(dir, 'inherited.xml')
      overridden_rss_file = File.join(dir, 'overridden.xml')
      disabled_rss_file = File.join(dir, 'disabled.xml')
      inherited_image_url = 'http://example.com/default.jpg'
      overridden_image_url = 'https://example.com/other.jpg?size=large&version=2'
      config = base_config(dir, File.join(dir, 'default.xml')).merge(
        'channel_image' => inherited_image_url,
        'feeds' => [
          { 'rss_file' => inherited_rss_file },
          {
            'rss_file' => overridden_rss_file,
            'channel_title' => 'Other Podcast',
            'channel_link' => 'https://example.com/other',
            'channel_image' => " #{overridden_image_url} "
          },
          { 'rss_file' => disabled_rss_file, 'channel_image' => nil }
        ]
      )

      assert RssRunner.new(config, out: StringIO.new).run

      inherited = RSS::Parser.parse(File.read(inherited_rss_file), false)
      overridden = RSS::Parser.parse(File.read(overridden_rss_file), false)
      disabled = RSS::Parser.parse(File.read(disabled_rss_file), false)
      assert_equal inherited_image_url, inherited.channel.itunes_image.href
      assert_equal inherited_image_url, inherited.image.url
      assert_equal 'My Podcast', inherited.image.title
      assert_equal 'http://example.com', inherited.image.link
      assert_equal overridden_image_url, overridden.channel.itunes_image.href
      assert_equal overridden_image_url, overridden.image.url
      assert_equal 'Other Podcast', overridden.image.title
      assert_equal 'https://example.com/other', overridden.image.link
      assert_nil disabled.channel.itunes_image
      assert_nil disabled.image
    end
  end

  def test_runner_resolves_inherited_local_channel_images_for_each_feed
    Dir.mktmpdir do |dir|
      default_audio_dir = File.join(dir, 'audio')
      other_audio_dir = File.join(dir, 'other-audio')
      FileUtils.mkdir_p([default_audio_dir, other_audio_dir])
      default_rss_file = File.join(dir, 'default.xml')
      other_rss_file = File.join(dir, 'other.xml')
      overridden_rss_file = File.join(dir, 'overridden.xml')
      config = base_config(default_audio_dir, File.join(dir, 'unused.xml')).merge(
        'channel_image' => 'cover.jpg',
        'feeds' => [
          { 'rss_file' => default_rss_file },
          {
            'rss_file' => other_rss_file,
            'audio_dir' => other_audio_dir,
            'base_url' => 'https://example.org/other/'
          },
          {
            'rss_file' => overridden_rss_file,
            'audio_dir' => other_audio_dir,
            'base_url' => 'https://example.org/another',
            'channel_image' => './art/other cover.jpg'
          }
        ]
      )

      assert RssRunner.new(config, out: StringIO.new).run

      {
        default_rss_file => 'http://example.com/files/cover.jpg',
        other_rss_file => 'https://example.org/other/cover.jpg',
        overridden_rss_file => 'https://example.org/another/art/other%20cover.jpg'
      }.each do |rss_file, expected_url|
        rss = RSS::Parser.parse(File.read(rss_file), false)
        assert_equal expected_url, rss.channel.itunes_image.href
        assert_equal expected_url, rss.image.url
      end
    end
  end

  def test_runner_continues_after_one_feed_has_an_operational_error
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      file = File.join(audio_dir, 'show_20240101000000.mp3')
      File.write(file, 'show')
      MiniExiftool.register(file, { mediadatasize: 4, title: 'Show', contentcreatedate: nil, description: '' })
      failed_rss = File.join(dir, 'failed.xml')
      working_rss = File.join(dir, 'working.xml')
      config = base_config(audio_dir, File.join(dir, 'default.xml')).merge(
        'feeds' => [
          { 'name' => 'missing', 'audio_dir' => File.join(dir, 'missing'), 'rss_file' => failed_rss },
          { 'name' => 'working', 'rss_file' => working_rss }
        ]
      )
      err = StringIO.new

      refute RssRunner.new(config, out: StringIO.new, err: err).run
      refute File.exist?(failed_rss)
      assert File.exist?(working_rss)
      assert_match(/missing/, err.string)
    end
  end

  def test_runner_keeps_existing_feed_after_write_failure_and_continues
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'show_20240101000000.mp3')
      failed_rss = File.join(dir, 'failed.xml')
      working_rss = File.join(dir, 'working.xml')
      File.write(file, 'show')
      File.write(failed_rss, 'known good feed')
      MiniExiftool.register(file, { mediadatasize: 4, title: 'Show', contentcreatedate: nil, description: '' })
      config = base_config(dir, File.join(dir, 'default.xml')).merge(
        'feeds' => [
          { 'name' => 'failed', 'rss_file' => failed_rss },
          { 'name' => 'working', 'rss_file' => working_rss }
        ]
      )
      atomic_writer = RadikoPodcastForMe::AtomicFileWriter.new
      writer = Object.new
      writer.define_singleton_method(:write) do |path, content|
        raise Errno::ENOSPC, 'disk full' if path == failed_rss

        atomic_writer.write(path, content)
      end
      err = StringIO.new

      refute RssRunner.new(config, writer: writer, out: StringIO.new, err: err).run
      assert_equal 'known good feed', File.read(failed_rss)
      assert File.exist?(working_rss)
      assert_match(/failed.*書き込みに失敗/, err.string)
    end
  end

  def test_create_rss_item_handles_missing_exif_file
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      file = File.join(audio_dir, 'missing_20240101000000.mp3')
      File.write(file, 'data')
      stderr = StringIO.new
      generator = RssGenerator.new(
        base_config(audio_dir, File.join(dir, 'rss.xml')),
        out: StringIO.new,
        err: stderr
      )
      maker = RSS::Maker.make("2.0") do |m|
        m.channel.title = 't'
        m.channel.link = 'http://example.com'
        m.channel.description = 'desc'
      end
      result = generator.send(:create_rss_item, maker, file)
      refute result
      assert_match(/警告: ファイルが見つかりません/, stderr.string)
    end
  end

  def test_runner_reports_skipped_metadata_as_failure
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'missing_metadata_20240101000000.mp3')
      rss_file = File.join(dir, 'rss.xml')
      File.write(file, 'data')

      result = nil
      _stdout, stderr = capture_io do
        result = RssRunner.new(base_config(dir, rss_file)).run
      end

      refute result
      refute File.exist?(rss_file)
      assert_match(/ファイルが見つかりません/, stderr)
    end
  end

  def test_generate_publishes_successful_items_and_reports_partial_metadata_failure
    Dir.mktmpdir do |dir|
      good_file = File.join(dir, 'good_20240101000000.mp3')
      bad_file = File.join(dir, 'bad_20240102000000.mp3')
      rss_file = File.join(dir, 'rss.xml')
      File.write(good_file, 'good')
      File.write(bad_file, 'bad')
      File.write(rss_file, 'known good feed')
      MiniExiftool.register(good_file, {
        mediadatasize: 4,
        title: 'Good',
        contentcreatedate: nil,
        description: ''
      })
      err = StringIO.new

      result = RssGenerator.new(
        base_config(dir, rss_file),
        out: StringIO.new,
        err: err
      ).generate

      refute result
      rss = RSS::Parser.parse(File.read(rss_file), false)
      assert_equal ['Good'], rss.items.map(&:title)
      assert_match(/ファイルが見つかりません/, err.string)
    end
  end

  def test_generate_keeps_existing_feed_when_all_metadata_reads_fail
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'bad_20240102000000.mp3')
      rss_file = File.join(dir, 'rss.xml')
      File.write(file, 'bad')
      File.write(rss_file, 'known good feed')
      err = StringIO.new

      result = RssGenerator.new(
        base_config(dir, rss_file),
        out: StringIO.new,
        err: err
      ).generate

      refute result
      assert_equal 'known good feed', File.read(rss_file)
      assert_match(/既存のRSSフィードを保持/, err.string)
    end
  end

  def test_generate_rejects_an_invalid_base_url_before_writing
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'show_20240101000000.mp3')
      rss_file = File.join(dir, 'rss.xml')
      File.write(file, 'data')
      MiniExiftool.register(file, { mediadatasize: 4, title: 'Show', contentcreatedate: nil, description: '' })
      config = base_config(dir, rss_file).merge('base_url' => 'http://[invalid')

      assert_raises(RssConfigResolver::Error) do
        RssGenerator.new(config).generate
      end
      refute File.exist?(rss_file)
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
      stderr = StringIO.new
      generator = RssGenerator.new(config, out: StringIO.new, err: stderr)
      result = generator.send(:extract_pub_date, 'episode_20241301000000.mp3', Time.now, file)
      refute_nil result
      assert_match(/解析できません/, stderr.string)
    end
  end

  def test_mime_type_defaults_to_octet_stream
    generator = RssGenerator.new(base_config('/tmp', '/tmp/rss.xml'))
    assert_equal 'application/octet-stream', generator.send(:mime_type, 'file.wav')
  end

  def test_generate_preserves_special_characters_in_item_text
    Dir.mktmpdir do |dir|
      filename = 'rock & roll_20240101000000.mp3'
      file = File.join(dir, filename)
      rss_file = File.join(dir, 'rss.xml')
      File.write(file, 'data')
      MiniExiftool.register(file, {
        mediadatasize: 4,
        title: 'Rock & Roll <Live>',
        contentcreatedate: nil,
        description: 'A < B & C > D'
      })

      RssGenerator.new(base_config(dir, rss_file)).generate
      item = RSS::Parser.parse(File.read(rss_file), false).items.first

      assert_equal 'Rock & Roll <Live>', item.title
      assert_equal 'A < B & C > D', item.description
      assert_equal 'http://example.com/files/rock%20%26%20roll_20240101000000%2Emp3', item.enclosure.url
    end
  end

  def test_generate_replaces_characters_forbidden_by_xml_1_0
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'control_20240101000000.mp3')
      rss_file = File.join(dir, 'rss.xml')
      File.write(file, 'data')
      MiniExiftool.register(file, {
        mediadatasize: 4,
        title: "Before\u0001After",
        contentcreatedate: nil,
        description: "Description\uFFFF"
      })
      config = base_config(dir, rss_file).merge('channel_title' => "Channel\u0002Title")

      assert RssGenerator.new(config).generate

      raw_rss = File.read(rss_file)
      refute_match(RssGenerator::INVALID_XML_CHARACTERS, raw_rss)
      rss = RSS::Parser.parse(raw_rss, false)
      assert_equal "Channel\uFFFDTitle", rss.channel.title
      assert_equal "Before\uFFFDAfter", rss.items.first.title
      assert_equal "Description\uFFFD", rss.items.first.description
    end
  end

  def test_cli_run_from_file_loads_config
    Dir.mktmpdir do |dir|
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      rss_file = File.join(dir, 'rss.xml')
      config_path = File.join(dir, 'config.yml')
      File.write(config_path, base_config(audio_dir, rss_file).to_yaml)

      status = PodcastRssCLI.run_from_file(
        config_path: config_path,
        out: StringIO.new,
        err: StringIO.new
      )

      assert_equal 0, status
      assert File.exist?(rss_file)
    end
  end

  def test_cli_run_returns_nonzero_when_generation_is_incomplete
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'missing_metadata_20240101000000.mp3')
      rss_file = File.join(dir, 'rss.xml')
      File.write(file, 'data')
      err = StringIO.new

      status = PodcastRssCLI.run(
        config: base_config(dir, rss_file),
        out: StringIO.new,
        err: err
      )

      assert_equal 1, status
      refute File.exist?(rss_file)
      assert_match(/一部のRSSフィード/, err.string)
    end
  end

  def test_cli_run_returns_nonzero_for_invalid_config
    err = StringIO.new

    status = PodcastRssCLI.run(config: {}, out: StringIO.new, err: err)

    assert_equal 1, status
    assert_match(/必要なキーが不足/, err.string)
  end

  def test_cli_run_from_file_reports_load_errors
    Dir.mktmpdir do |dir|
      err = StringIO.new

      status = PodcastRssCLI.run_from_file(
        config_path: File.join(dir, 'missing.yml'),
        out: StringIO.new,
        err: err
      )

      assert_equal 1, status
      assert_match(/ファイルが見つかりません/, err.string)
    end
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
