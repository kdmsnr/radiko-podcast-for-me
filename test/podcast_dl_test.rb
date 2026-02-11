require_relative 'test_helper'
require_relative '../podcast_dl'

class PodcastDownloaderTest < Minitest::Test
  def setup
    config = {
      'area_id' => 'JP13',
      'audio_dir' => '/tmp/audio',
      'yt_dlp_path' => '/usr/local/bin/yt-dlp'
    }
    @downloader = PodcastDownloader.new(config, [])
  end

  def test_parse_keyword_with_station_id_suffix
    keyword, station_id = parse_keyword('番組名&station_id=LFR')
    assert_equal '番組名', keyword
    assert_equal 'LFR', station_id
  end

  def test_parse_keyword_without_station_id
    keyword, station_id = parse_keyword('安住紳一郎の日曜天国')
    assert_equal '安住紳一郎の日曜天国', keyword
    assert_nil station_id
  end

  def test_parse_keyword_with_station_fragment_inside_title
    keyword, station_id = parse_keyword(' station_id=特集 station_id=abc ')
    assert_equal 'station_id=特集 station_id=abc', keyword
    assert_nil station_id
  end

  def test_build_search_url_without_station_id
    url = @downloader.send(:build_search_url, 'キーワード', nil)
    assert_includes url, 'key=%E3%82%AD%E3%83%BC%E3%83%AF%E3%83%BC%E3%83%89'
    assert_includes url, 'area_id=JP13'
    refute_includes url, 'station_id='
  end

  def test_build_search_url_with_station_id
    url = @downloader.send(:build_search_url, 'keyword', 'LFR')
    assert_includes url, 'station_id=LFR'
  end

  def test_build_command_includes_base_options
    base_options = @downloader.send(:build_base_options)
    command = @downloader.send(:build_command, 'https://example.com', base_options)
    assert_equal '/usr/local/bin/yt-dlp', command.first
    assert_equal 'https://example.com', command.last
    assert_includes command, '-x'
    assert_includes command, '--embed-metadata'
  end

  def test_build_base_options_uses_custom_download_count
    downloader = PodcastDownloader.new(default_config.merge('download_count' => 10), [])
    options = downloader.send(:build_base_options)
    idx = options.index('-N')
    assert_equal '10', options[idx + 1]
  end

  def test_download_invokes_command_for_each_keyword
    keywords = ['foo', 'bar&station_id=ABC']
    downloader = PodcastDownloader.new(default_config, keywords)
    executed = []
    downloader.define_singleton_method(:execute_command) do |cmd|
      executed << cmd
    end
    downloader.download
    assert_equal 2, executed.size
    assert_match(/key=foo/, executed.first.last)
    assert_match(/station_id=ABC/, executed.last.last)
  end

  def test_initialize_with_missing_config_key
    config = {'audio_dir' => '/tmp', 'yt_dlp_path' => '/bin/echo'}
    assert_raises(SystemExit) do
      PodcastDownloader.new(config, [])
    end
  end

  def test_execute_command_success_outputs_command
    downloader = PodcastDownloader.new(default_config, [])
    downloader.define_singleton_method(:system) { |_cmd = nil, *_rest| true }
    stdout, stderr = capture_io do
      downloader.send(:execute_command, ['echo', 'hello'])
    end
    assert_match(/実行コマンド:/, stdout)
    assert_equal '', stderr
  end

  def test_execute_command_warns_on_failure
    downloader = PodcastDownloader.new(default_config, [])
    downloader.define_singleton_method(:system) { |_cmd = nil, *_rest| false }
    stdout, stderr = capture_io do
      downloader.send(:execute_command, ['cmd'])
    end
    assert_match(/実行コマンド:/, stdout)
    assert_match(/コマンドの実行に失敗/, stderr)
  end

  def test_execute_command_aborts_when_binary_missing
    downloader = PodcastDownloader.new(default_config.merge('yt_dlp_path' => '/missing/bin'), [])
    downloader.define_singleton_method(:system) do |_cmd = nil, *_rest|
      raise Errno::ENOENT
    end
    assert_raises(SystemExit) do
      capture_io { downloader.send(:execute_command, ['cmd']) }
    end
  end

  def test_execute_command_warns_on_unexpected_error
    downloader = PodcastDownloader.new(default_config, [])
    downloader.define_singleton_method(:system) do |_cmd = nil, *_rest|
      raise 'boom'
    end
    stdout, stderr = capture_io do
      downloader.send(:execute_command, ['cmd'])
    end
    assert_match(/実行コマンド:/, stdout)
    assert_match(/予期せぬエラー/, stderr)
  end

  private

  def parse_keyword(str)
    @downloader.send(:parse_keyword, str)
  end

  def default_config
    {
      'area_id' => 'JP13',
      'audio_dir' => '/tmp/audio',
      'yt_dlp_path' => '/usr/local/bin/yt-dlp'
    }
  end
end
