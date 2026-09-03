require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require_relative '../podcast_delete'

class PodcastDeleterTest < Minitest::Test
  TODAY = Date.new(2024, 3, 31)

  def test_delete_old_files_removes_only_expired_items
    Dir.mktmpdir do |dir|
      old_file = create_file(dir, 'old.mp3', Time.local(2024, 1, 30, 23, 59, 59))
      new_file = create_file(dir, 'new.mp3', Time.local(2024, 2, 1))
      deleter = build_deleter(dir, expire_month: 2)

      assert deleter.delete_old_files
      refute File.exist?(old_file)
      assert File.exist?(new_file)
    end
  end

  def test_delete_old_files_uses_calendar_month_boundary
    Dir.mktmpdir do |dir|
      before_boundary = create_file(dir, 'before.mp3', Time.local(2024, 2, 28, 23, 59, 59))
      at_boundary = create_file(dir, 'at.mp3', Time.local(2024, 2, 29))
      deleter = build_deleter(dir, expire_month: 1)

      assert deleter.delete_old_files
      refute File.exist?(before_boundary)
      assert File.exist?(at_boundary)
    end
  end

  def test_delete_old_files_treats_glob_characters_in_directory_as_literals
    Dir.mktmpdir do |parent|
      dir = File.join(parent, 'audio*')
      sibling_dir = File.join(parent, 'audio-other')
      Dir.mkdir(dir)
      Dir.mkdir(sibling_dir)
      old_file = create_file(dir, 'old.mp3', Time.local(2024, 1, 1))
      sibling_file = create_file(sibling_dir, 'must-stay.mp3', Time.local(2024, 1, 1))

      assert build_deleter(dir, expire_month: 1).delete_old_files
      refute File.exist?(old_file)
      assert File.exist?(sibling_file)
    end
  end

  def test_delete_old_files_preserves_hidden_files
    Dir.mktmpdir do |dir|
      hidden_file = create_file(dir, '.keep', Time.local(2024, 1, 1))

      assert build_deleter(dir, expire_month: 1).delete_old_files
      assert File.exist?(hidden_file)
    end
  end

  def test_delete_old_files_preserves_non_audio_files
    Dir.mktmpdir do |dir|
      old_audio = create_file(dir, 'old.MP3', Time.local(2024, 1, 1))
      old_notes = create_file(dir, 'notes.txt', Time.local(2024, 1, 1))
      old_feed = create_file(dir, 'rss.xml', Time.local(2024, 1, 1))

      assert build_deleter(dir, expire_month: 1).delete_old_files
      refute File.exist?(old_audio)
      assert File.exist?(old_notes)
      assert File.exist?(old_feed)
    end
  end

  def test_delete_old_files_can_explicitly_include_all_file_types
    Dir.mktmpdir do |dir|
      old_notes = create_file(dir, 'notes.txt', Time.local(2024, 1, 1))
      settings = config(dir, 1).merge('delete_all_files' => true)
      deleter = PodcastDeleter.new(
        settings,
        today: -> { TODAY },
        out: StringIO.new,
        err: StringIO.new
      )

      assert deleter.delete_old_files
      refute File.exist?(old_notes)
    end
  end

  def test_delete_old_files_returns_false_when_directory_missing
    Dir.mktmpdir do |dir|
      missing_dir = File.join(dir, 'missing')
      err = StringIO.new
      deleter = build_deleter(missing_dir, err: err)

      refute deleter.delete_old_files
      assert_match(/ディレクトリが存在しません/, err.string)
    end
  end

  def test_delete_old_files_ignores_dangling_symlinks
    Dir.mktmpdir do |dir|
      link = File.join(dir, 'missing.mp3')
      File.symlink(File.join(dir, 'does-not-exist'), link)

      assert build_deleter(dir).delete_old_files
      assert File.symlink?(link)
    end
  end

  def test_delete_old_files_continues_after_stat_failure
    Dir.mktmpdir do |dir|
      unreadable_file = create_file(dir, 'unreadable.mp3', Time.local(2024, 1, 1))
      removable_file = create_file(dir, 'removable.mp3', Time.local(2024, 1, 1))
      err = StringIO.new
      stat = lambda do |path|
        raise Errno::EACCES, path if path == unreadable_file

        File.stat(path)
      end
      deleter = build_deleter(dir, expire_month: 1, stat: stat, err: err)

      refute deleter.delete_old_files
      assert File.exist?(unreadable_file)
      refute File.exist?(removable_file)
      assert_match(/ファイル情報の取得に失敗しました/, err.string)
    end
  end

  def test_delete_old_files_continues_after_deletion_failure
    Dir.mktmpdir do |dir|
      failed_file = create_file(dir, 'failed.mp3', Time.local(2024, 1, 1))
      removable_file = create_file(dir, 'removable.mp3', Time.local(2024, 1, 1))
      err = StringIO.new
      remover = lambda do |path|
        raise Errno::EACCES, path if path == failed_file

        FileUtils.rm(path)
      end
      deleter = build_deleter(dir, expire_month: 1, remover: remover, err: err)

      refute deleter.delete_old_files
      assert File.exist?(failed_file)
      refute File.exist?(removable_file)
      assert_match(/ファイルの削除に失敗しました/, err.string)
    end
  end

  def test_delete_old_files_treats_an_already_removed_file_as_success
    Dir.mktmpdir do |dir|
      disappearing_file = create_file(dir, 'disappearing.mp3', Time.local(2024, 1, 1))
      remover = lambda do |path|
        FileUtils.rm(path)
        raise Errno::ENOENT, path
      end
      deleter = build_deleter(dir, expire_month: 1, remover: remover)

      assert deleter.delete_old_files
      refute File.exist?(disappearing_file)
    end
  end

  def test_runner_returns_nonzero_when_a_deletion_fails
    Dir.mktmpdir do |dir|
      create_file(dir, 'old.mp3', Time.local(2024, 1, 1))
      out = StringIO.new
      err = StringIO.new
      remover = ->(_path) { raise Errno::EACCES, 'permission denied' }

      status = PodcastDeleteRunner.run(
        config(dir, 1),
        today: -> { TODAY },
        remover: remover,
        out: out,
        err: err
      )

      assert_equal 1, status
      refute_match(/処理が完了しました/, out.string)
      assert_match(/一部のファイルを処理できませんでした/, err.string)
    end
  end

  def test_runner_returns_zero_after_success
    Dir.mktmpdir do |dir|
      out = StringIO.new
      err = StringIO.new

      status = PodcastDeleteRunner.run(
        config(dir, 1),
        today: -> { TODAY },
        out: out,
        err: err
      )

      assert_equal 0, status
      assert_match(/処理が完了しました/, out.string)
      assert_empty err.string
    end
  end

  def test_initialize_accepts_an_integer_string
    Dir.mktmpdir do |dir|
      deleter = build_deleter(dir, expire_month: '2')

      assert deleter.delete_old_files
    end
  end

  def test_initialize_rejects_invalid_expire_month_string
    assert_invalid_expire_month('abc')
    assert_invalid_expire_month(' 2')
    assert_invalid_expire_month('2.0')
  end

  def test_initialize_rejects_non_integer_expire_month_types
    assert_invalid_expire_month(2.0)
    assert_invalid_expire_month(true)
    assert_invalid_expire_month(false)
    assert_invalid_expire_month([])
  end

  def test_initialize_with_missing_keys
    error = assert_raises(PodcastDeleter::ConfigurationError) do
      PodcastDeleter.new({ 'audio_dir' => '/tmp' })
    end
    assert_match(/expire_month/, error.message)
  end

  def test_initialize_rejects_invalid_audio_directory
    ['', ' ', true].each do |value|
      error = assert_raises(PodcastDeleter::ConfigurationError) do
        PodcastDeleter.new(config(value, 1))
      end
      assert_match(/audio_dir/, error.message)
    end
  end

  def test_initialize_rejects_non_boolean_delete_all_files
    error = assert_raises(PodcastDeleter::ConfigurationError) do
      PodcastDeleter.new(config('/tmp', 1).merge('delete_all_files' => 'true'))
    end

    assert_match(/delete_all_files/, error.message)
  end

  def test_initialize_rejects_root_as_audio_directory
    error = assert_raises(PodcastDeleter::ConfigurationError) do
      PodcastDeleter.new(config('/', 1))
    end

    assert_match(/ルートディレクトリ/, error.message)
  end

  def test_initialize_rejects_a_symlink_path_that_resolves_to_root
    Dir.mktmpdir do |dir|
      root_link = File.join(dir, 'root')
      File.symlink('/', root_link)
      disguised_root = File.join(root_link, '..')

      assert_equal '/', File.realpath(disguised_root)
      error = assert_raises(PodcastDeleter::ConfigurationError) do
        PodcastDeleter.new(config(disguised_root, 1))
      end

      assert_match(/ルートディレクトリ/, error.message)
    end
  end

  def test_initialize_normalizes_surrounding_whitespace_in_audio_directory
    Dir.mktmpdir do |dir|
      old_file = create_file(dir, 'old.mp3', Time.local(2024, 1, 1))

      assert build_deleter(" #{dir} ", expire_month: 1).delete_old_files
      refute File.exist?(old_file)
    end
  end

  def test_runner_returns_nonzero_for_invalid_config
    err = StringIO.new

    status = PodcastDeleteRunner.run({ 'audio_dir' => '/tmp' }, out: StringIO.new, err: err)

    assert_equal 1, status
    assert_match(/expire_month/, err.string)
  end

  def test_runner_from_file_loads_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, 'config.yml')
      audio_dir = File.join(dir, 'audio')
      FileUtils.mkdir_p(audio_dir)
      File.write(config_path, config(audio_dir, 1).to_yaml)
      out = StringIO.new

      status = PodcastDeleteRunner.run_from_file(
        config_path: config_path,
        today: -> { TODAY },
        out: out,
        err: StringIO.new
      )

      assert_equal 0, status
      assert_match(/処理が完了しました/, out.string)
    end
  end

  def test_runner_from_file_reports_load_errors
    Dir.mktmpdir do |dir|
      err = StringIO.new

      status = PodcastDeleteRunner.run_from_file(
        config_path: File.join(dir, 'missing.yml'),
        out: StringIO.new,
        err: err
      )

      assert_equal 1, status
      assert_match(/ファイルが見つかりません/, err.string)
    end
  end

  def test_initialize_with_non_positive_expire_month
    assert_invalid_expire_month(0)
    assert_invalid_expire_month(-1)
    assert_invalid_expire_month('-1')
  end

  private

  def config(dir, expire_month)
    {
      'audio_dir' => dir,
      'expire_month' => expire_month
    }
  end

  def build_deleter(dir, expire_month: 2, **dependencies)
    PodcastDeleter.new(
      config(dir, expire_month),
      today: -> { TODAY },
      out: StringIO.new,
      err: StringIO.new,
      **dependencies
    )
  end

  def create_file(dir, name, mtime)
    path = File.join(dir, name)
    File.write(path, name)
    File.utime(mtime, mtime, path)
    path
  end

  def assert_invalid_expire_month(value)
    error = assert_raises(PodcastDeleter::ConfigurationError) do
      PodcastDeleter.new(config('/tmp', value))
    end
    assert_match(/'expire_month' は正の整数/, error.message)
  end
end
