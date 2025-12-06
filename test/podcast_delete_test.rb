require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../podcast_delete'

class PodcastDeleterTest < Minitest::Test
  def test_delete_old_files_removes_only_expired_items
    Dir.mktmpdir do |dir|
      old_file = File.join(dir, 'old.mp3')
      new_file = File.join(dir, 'new.mp3')
      File.write(old_file, 'old')
      File.write(new_file, 'new')
      old_time = Time.now - (60 * 60 * 24 * 120)
      File.utime(old_time, old_time, old_file)
      config = {
        'audio_dir' => dir,
        'expire_month' => 2
      }
      deleter = PodcastDeleter.new(config)
      deleter.delete_old_files
      refute File.exist?(old_file)
      assert File.exist?(new_file)
    end
  end

  def test_delete_old_files_raises_when_directory_missing
    config = {
      'audio_dir' => '/tmp/non-existent-dir',
      'expire_month' => 1
    }
    deleter = PodcastDeleter.new(config)
    assert_raises(SystemExit) do
      deleter.delete_old_files
    end
  end

  def test_initialize_with_invalid_expire_month
    config = {
      'audio_dir' => '/tmp',
      'expire_month' => 'abc'
    }
    assert_raises(SystemExit) do
      PodcastDeleter.new(config)
    end
  end

  def test_initialize_with_missing_keys
    config = {'audio_dir' => '/tmp'}
    assert_raises(SystemExit) do
      PodcastDeleter.new(config)
    end
  end

  def test_initialize_with_non_positive_expire_month
    config = {
      'audio_dir' => '/tmp',
      'expire_month' => 0
    }
    assert_raises(SystemExit) do
      PodcastDeleter.new(config)
    end
  end

  def test_delete_old_files_warns_when_deletion_fails
    Dir.mktmpdir do |dir|
      old_file = File.join(dir, 'old.mp3')
      File.write(old_file, 'old')
      File.utime(Time.now - (60 * 60 * 24 * 120), Time.now - (60 * 60 * 24 * 120), old_file)
      config = {
        'audio_dir' => dir,
        'expire_month' => 2
      }
      deleter = PodcastDeleter.new(config)
      FileUtils.stub(:rm, proc { |_path| raise 'permission denied' }) do
        _stdout, stderr = capture_io do
          deleter.delete_old_files
        end
        assert_match(/警告: ファイルの削除に失敗しました/, stderr)
      end
    end
  end
end
