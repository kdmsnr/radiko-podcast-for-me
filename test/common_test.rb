require_relative 'test_helper'
require 'tmpdir'
require_relative '../lib/common'

class CommonTest < Minitest::Test
  def test_load_yaml_file_returns_parsed_hash
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, "foo: bar\nnumber: 1\n")
      data = RadikoPodcastForMe.load_yaml_file(path)
      assert_equal({'foo' => 'bar', 'number' => 1}, data)
    end
  end

  def test_load_yaml_file_raises_when_missing
    error = assert_raises(RadikoPodcastForMe::ConfigurationFileError) do
      RadikoPodcastForMe.load_yaml_file('/tmp/non-existent-file.yml')
    end
    assert_match(/ファイルが見つかりません/, error.message)
  end

  def test_load_yaml_file_raises_on_invalid_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'invalid.yml')
      File.write(path, "foo: :bar: baz\n")
      error = assert_raises(RadikoPodcastForMe::ConfigurationFileError) do
        RadikoPodcastForMe.load_yaml_file(path)
      end
      assert_match(/YAMLファイルの形式/, error.message)
    end
  end

  def test_load_yaml_file_wraps_other_file_errors
    Dir.mktmpdir do |dir|
      error = assert_raises(RadikoPodcastForMe::ConfigurationFileError) do
        RadikoPodcastForMe.load_yaml_file(dir)
      end
      assert_match(/ファイルを読み込めません/, error.message)
    end
  end

  def test_load_yaml_file_wraps_invalid_encoding
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'invalid-encoding.yml')
      File.binwrite(path, "\xFF\xFE")

      error = assert_raises(RadikoPodcastForMe::ConfigurationFileError) do
        RadikoPodcastForMe.load_yaml_file(path)
      end

      assert_match(/YAMLファイルの形式/, error.message)
    end
  end

  def test_supported_audio_file_is_case_insensitive
    assert RadikoPodcastForMe.supported_audio_file?('episode.MP3')
    assert RadikoPodcastForMe.supported_audio_file?('episode.m4a')
    refute RadikoPodcastForMe.supported_audio_file?('notes.txt')
  end
end
