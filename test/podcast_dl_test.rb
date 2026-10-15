require_relative 'test_helper'
require 'stringio'
require 'tmpdir'
require 'rbconfig'
require_relative '../podcast_dl'

class PodcastDownloaderTest < Minitest::Test
  def setup
    @downloader = build_downloader
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

  def test_search_key_preserves_internal_spaces_and_trims_surrounding_spaces
    executed = []
    downloader = build_downloader(
      keywords: [' TM Network ', 'Tokyo Midtown presents The Lifestyle MUSEUM', 'GURU 水曜日 '],
      command_runner: ->(*command) { executed << command; true }
    )

    assert downloader.download
    keys = executed.map do |command|
      query = URI.parse(command.last).fragment.split('?', 2).last
      URI.decode_www_form(query).to_h.fetch('key')
    end
    assert_equal ['TM Network', 'Tokyo Midtown presents The Lifestyle MUSEUM', 'GURU 水曜日'], keys
  end

  def test_build_command_includes_base_options
    base_options = @downloader.send(:build_base_options)
    command = @downloader.send(:build_command, 'https://example.com', base_options)
    assert_equal '/usr/local/bin/yt-dlp', command.first
    assert_equal 'https://example.com', command.last
    assert_includes command, '-x'
    assert_includes command, '--embed-metadata'
  end

  def test_build_base_options_uses_default_concurrent_fragments
    options = @downloader.send(:build_base_options)
    assert_equal '5', option_value(options, '-N')
  end

  def test_build_base_options_uses_custom_concurrent_fragments
    downloader = build_downloader(config: default_config.merge('concurrent_fragments' => 10))
    options = downloader.send(:build_base_options)
    assert_equal '10', option_value(options, '-N')
  end

  def test_legacy_download_count_is_an_alias_with_a_warning
    stderr = StringIO.new
    downloader = build_downloader(
      config: default_config.merge('download_count' => '3'),
      stderr: stderr
    )

    options = downloader.send(:build_base_options)
    assert_equal '3', option_value(options, '-N')
    assert_match(/download_count.*非推奨/, stderr.string)
    assert_match(/concurrent_fragments/, stderr.string)
  end

  def test_concurrent_fragments_takes_precedence_over_legacy_alias
    stderr = StringIO.new
    downloader = build_downloader(
      config: default_config.merge('concurrent_fragments' => 7, 'download_count' => 3),
      stderr: stderr
    )

    options = downloader.send(:build_base_options)
    assert_equal '7', option_value(options, '-N')
    assert_match(/download_count.*非推奨/, stderr.string)
  end

  def test_concurrent_fragments_must_be_a_positive_integer
    [0, -1, 'abc', 1.5, true].each do |invalid_value|
      error = assert_raises(PodcastDownloader::ConfigurationError) do
        build_downloader(config: default_config.merge('concurrent_fragments' => invalid_value))
      end
      assert_match(/正の整数/, error.message)
    end
  end

  def test_download_invokes_runner_for_each_keyword_and_returns_true
    executed = []
    runner = lambda do |*command|
      executed << command
      true
    end
    downloader = build_downloader(
      keywords: ['foo', 'bar&station_id=ABC'],
      command_runner: runner
    )

    assert downloader.download
    assert_equal 2, executed.size
    assert_match(/key=foo/, executed.first.last)
    assert_match(/station_id=ABC/, executed.last.last)
  end

  def test_download_continues_after_failure_and_aggregates_result
    executed = []
    results = [false, true, false]
    runner = lambda do |*command|
      executed << command
      results.shift
    end
    downloader = build_downloader(
      keywords: %w[first second third],
      command_runner: runner
    )

    refute downloader.download
    assert_equal 3, executed.size
    assert executed[1].last.include?('key=second')
    assert_equal %w[first third], downloader.failed_keywords
  end

  def test_download_clears_failures_before_running_again
    results = [false, true]
    downloader = build_downloader(command_runner: ->(*_command) { results.shift })

    refute downloader.download
    assert_equal ['keyword'], downloader.failed_keywords
    assert downloader.download
    assert_empty downloader.failed_keywords
  end

  def test_download_treats_nil_runner_result_as_missing_binary
    stderr = StringIO.new
    downloader = build_downloader(
      keywords: ['foo'],
      command_runner: ->(*_command) {},
      stderr: stderr
    )

    refute downloader.download
    assert_match(%r{/usr/local/bin/yt-dlp}, stderr.string)
    assert_match(/実行できませんでした/, stderr.string)
  end

  def test_download_handles_missing_binary_exception_and_continues
    calls = 0
    runner = lambda do |*_command|
      calls += 1
      raise Errno::ENOENT if calls == 1

      true
    end
    stderr = StringIO.new
    downloader = build_downloader(
      keywords: %w[first second],
      command_runner: runner,
      stderr: stderr
    )

    refute downloader.download
    assert_equal 2, calls
    assert_match(/コマンドが見つかりません/, stderr.string)
  end

  def test_download_handles_unexpected_runner_error_and_continues
    calls = 0
    runner = lambda do |*_command|
      calls += 1
      raise 'boom' if calls == 1

      true
    end
    stderr = StringIO.new
    downloader = build_downloader(
      keywords: %w[first second],
      command_runner: runner,
      stderr: stderr
    )

    refute downloader.download
    assert_equal 2, calls
    assert_match(/予期せぬエラー/, stderr.string)
    assert_match(/boom/, stderr.string)
  end

  def test_initialize_rejects_non_hash_config
    error = assert_raises(PodcastDownloader::ConfigurationError) do
      build_downloader(config: nil)
    end
    assert_match(/キーと値の組/, error.message)
  end

  def test_initialize_rejects_missing_config_key
    config = {'audio_dir' => '/tmp', 'yt_dlp_path' => '/bin/echo'}
    error = assert_raises(PodcastDownloader::ConfigurationError) do
      build_downloader(config: config)
    end
    assert_match(/area_id/, error.message)
  end

  def test_initialize_rejects_blank_or_non_string_config_values
    config = default_config.merge('audio_dir' => ' ', 'area_id' => 13)
    error = assert_raises(PodcastDownloader::ConfigurationError) do
      build_downloader(config: config)
    end
    assert_match(/area_id, audio_dir/, error.message)
  end

  def test_initialize_rejects_invalid_keywords
    [nil, 'keyword', [], ['valid', nil], [' ']].each do |invalid_keywords|
      error = assert_raises(PodcastDownloader::ConfigurationError) do
        build_downloader(keywords: invalid_keywords)
      end
      assert_match(/キーワード/, error.message)
    end
  end

  def test_initialize_normalizes_surrounding_whitespace_in_paths_and_area
    downloader = build_downloader(
      config: default_config.merge(
        'area_id' => ' JP13 ',
        'audio_dir' => ' /tmp/audio ',
        'yt_dlp_path' => ' /usr/local/bin/yt-dlp '
      )
    )

    command = downloader.send(:build_command, 'https://example.com', downloader.send(:build_base_options))
    assert_equal '/usr/local/bin/yt-dlp', command.first
    assert_equal '/tmp/audio', option_value(command, '-P')
    assert_includes downloader.send(:build_search_url, 'show', nil), 'area_id=JP13'
  end

  def test_cli_run_returns_zero_and_reports_completion_on_success
    stdout = StringIO.new
    stderr = StringIO.new

    status = PodcastDownloaderCLI.run(
      config: default_config,
      keywords: ['foo'],
      command_runner: ->(*_command) { true },
      stdout: stdout,
      stderr: stderr
    )

    assert_equal 0, status
    assert_match(/処理が完了しました/, stdout.string)
    assert_equal '', stderr.string
  end

  def test_cli_run_returns_nonzero_and_omits_completion_on_failure
    stdout = StringIO.new
    stderr = StringIO.new

    status = PodcastDownloaderCLI.run(
      config: default_config,
      keywords: ['foo'],
      command_runner: ->(*_command) { false },
      stdout: stdout,
      stderr: stderr
    )

    assert_equal 1, status
    refute_match(/処理が完了しました/, stdout.string)
    assert_match(/一部のダウンロードに失敗/, stderr.string)
    assert_match(/終了ステータス: unknown/, stderr.string)
  end

  def test_cli_run_reports_the_real_process_exit_status
    stderr = StringIO.new
    config = default_config.merge('yt_dlp_path' => '/usr/bin/false')

    status = PodcastDownloaderCLI.run(
      config: config,
      keywords: ['foo'],
      stdout: StringIO.new,
      stderr: stderr
    )

    assert_equal 1, status
    assert_match(/終了ステータス: 1/, stderr.string)
  end

  def test_cli_identifies_earlier_failure_when_last_search_has_no_results
    stdout = StringIO.new
    stderr = StringIO.new
    runner = lambda do |*command|
      if command.last.include?('key=failed')
        false
      else
        stdout.puts '[RadikoSearch] Playlist empty: Downloading 0 items'
        stdout.puts '[download] Finished downloading playlist: empty'
        true
      end
    end

    status = PodcastDownloaderCLI.run(
      config: default_config,
      keywords: ['failed&station_id=LFR', 'empty'],
      command_runner: runner,
      stdout: stdout,
      stderr: stderr
    )

    assert_equal 1, status
    assert_includes stdout.string, 'Downloading 0 items'
    assert_includes stdout.string, '検索キーワード: failed&station_id=LFR'
    assert_includes stderr.string, "失敗したキーワード:\n  - failed&station_id=LFR\n"
    refute_includes stderr.string, '  - empty'
    refute_includes stdout.string, '処理が完了しました。'
  end

  def test_cli_repeats_subprocess_error_after_later_output_and_successful_search
    with_fake_yt_dlp(<<~'RUBY') do |path|
      require 'uri'
      query = URI.parse(ARGV.last).fragment.split('?', 2).last
      key = URI.decode_www_form(query).to_h.fetch('key')
      if key == 'TM Network'
        STDERR.puts "\e[31mERROR: この番組は取得できません\e[0m"
        2000.times do |index|
          STDOUT.puts "stdout progress #{index} " + 'x' * 100
          STDERR.puts "stderr progress #{index} " + 'x' * 100
        end
        exit 7
      end
      STDOUT.puts 'successful next search'
    RUBY
      stdout = StringIO.new
      stderr = StringIO.new
      status = PodcastDownloaderCLI.run(
        config: default_config.merge('yt_dlp_path' => path),
        keywords: ['TM Network', 'TMNetwork'],
        stdout: stdout,
        stderr: stderr
      )

      assert_equal 1, status
      assert_includes stdout.string, 'successful next search'
      assert_includes stdout.string, 'stdout progress 1999'
      assert_includes stderr.string, 'stderr progress 1999'
      refute_includes stdout.string, 'stderr progress'
      summary = stderr.string.split("失敗したキーワード:\n", 2).last
      assert_includes summary, '  - TM Network'
      refute_includes summary, '  - TMNetwork'
      assert_includes summary, '終了ステータス: 7'
      assert_includes summary, 'ERROR: この番組は取得できません'
      refute_includes summary, "\e["
      refute_includes summary, 'progress'
    end
  end

  def test_cli_shows_bounded_output_tail_when_subprocess_has_no_error_line
    with_fake_yt_dlp(<<~'RUBY') do |path|
      30.times { |index| STDERR.puts "diagnostic line #{index}" }
      exit 2
    RUBY
      stderr = StringIO.new
      status = PodcastDownloaderCLI.run(
        config: default_config.merge('yt_dlp_path' => path),
        keywords: ['TM Network'],
        stdout: StringIO.new,
        stderr: stderr
      )

      assert_equal 1, status
      summary = stderr.string.split("失敗したキーワード:\n", 2).last
      assert_includes summary, '終了ステータス: 2'
      assert_includes summary, 'diagnostic line 29'
      refute_includes summary, 'diagnostic line 19'
      assert_equal 10, summary.lines.count { |line| line.include?('diagnostic line') }
    end
  end

  def test_cli_includes_missing_executable_reason_in_summary
    Dir.mktmpdir do |dir|
      stderr = StringIO.new
      status = PodcastDownloaderCLI.run(
        config: default_config.merge('yt_dlp_path' => File.join(dir, 'missing')),
        keywords: ['TM Network'],
        stdout: StringIO.new,
        stderr: stderr
      )

      assert_equal 1, status
      summary = stderr.string.split("失敗したキーワード:\n", 2).last
      assert_includes summary, 'コマンドが見つかりません'
    end
  end

  def test_cli_skips_unavailable_program_and_continues_with_other_spelling
    status, stdout, stderr = run_cli_with_fake_yt_dlp(<<~'RUBY', keywords: ['TM Network', 'TMNetwork'])
      if ARGV.last.include?('key=TM+Network&')
        STDERR.puts "\e[31mERROR: [RadikoTimeFree] JOAK-FM-20260904123000: This programme is not available. If this is an NHK station, you may wish to try NHK Radiru.\e[0m"
        STDOUT.puts '[download] Finished downloading playlist: TM Network'
        exit 1
      end
      STDOUT.puts 'TMNetwork downloaded'
    RUBY

    assert_equal 0, status
    assert_includes stdout, 'TMNetwork downloaded'
    assert_includes stdout, '処理が完了しました。'
    assert_includes stderr, '警告: 取得不可の番組をスキップ:'
    assert_includes stderr, '取得不可の番組 1件をスキップしました。'
    refute_includes stderr, 'ERROR:'
    refute_includes stderr, '失敗したキーワード:'
  end

  def test_cli_skips_expired_program
    status, stdout, stderr = run_cli_with_fake_yt_dlp(<<~'RUBY')
      STDERR.puts 'ERROR: [RadikoTimeFree] INT-20260101223000: Programme is no longer available.'
      STDOUT.puts '[download] Finished downloading playlist: TM Network'
      exit 1
    RUBY

    assert_equal 0, status
    assert_includes stdout, '処理が完了しました。'
    assert_includes stderr, '取得不可の番組 1件をスキップしました。'
  end

  def test_cli_preserves_real_failure_among_many_unavailable_programs
    status, stdout, stderr = run_cli_with_fake_yt_dlp(<<~'RUBY')
      STDERR.puts 'ERROR: [RadikoTimeFree] INT-20260909223000: Unable to download webpage: HTTP Error 500'
      20.times do
        STDERR.puts 'ERROR: [RadikoTimeFree] JOAK-FM-20260904123000: This programme is not available.'
      end
      STDOUT.puts '[download] Finished downloading playlist: TM Network'
      exit 1
    RUBY

    assert_equal 1, status
    refute_includes stdout, '処理が完了しました。'
    summary = stderr.split("失敗したキーワード:\n", 2).last
    assert_includes summary, 'HTTP Error 500'
    assert_includes summary, '  - TM Network'
  end

  def test_cli_does_not_treat_aborted_or_unexpected_exit_as_an_unavailable_only_result
    [
      [1, false, nil],
      [2, true, nil],
      [1, true, 'Traceback (most recent call last):'],
      [1, true, 'ERROR: unable to open for writing: Permission denied']
    ].each do |exit_status, finished, extra_error|
      source = <<~RUBY
        STDERR.puts 'ERROR: [RadikoTimeFree] JOAK-FM-20260904123000: This programme is not available.'
        STDERR.puts #{extra_error.inspect} if #{!extra_error.nil?}
        STDOUT.puts '[download] Finished downloading playlist: TM Network' if #{finished}
        exit #{exit_status}
      RUBY
      status, stdout, stderr = run_cli_with_fake_yt_dlp(source)

      assert_equal 1, status
      refute_includes stdout, '処理が完了しました。'
      assert_includes stderr, '失敗したキーワード:'
    end
  end

  def test_cli_treats_empty_playlist_with_successful_exit_as_success
    stdout = StringIO.new
    stderr = StringIO.new
    runner = lambda do |*_command|
      stdout.puts '[RadikoSearch] Playlist empty: Downloading 0 items'
      true
    end

    status = PodcastDownloaderCLI.run(
      config: default_config,
      keywords: ['empty'],
      command_runner: runner,
      stdout: stdout,
      stderr: stderr
    )

    assert_equal 0, status
    assert_includes stdout.string, '処理が完了しました。'
    assert_empty stderr.string
  end

  def test_cli_run_returns_nonzero_for_invalid_input
    stderr = StringIO.new

    status = PodcastDownloaderCLI.run(
      config: default_config,
      keywords: nil,
      command_runner: ->(*_command) { true },
      stdout: StringIO.new,
      stderr: stderr
    )

    assert_equal 1, status
    assert_match(/キーワードは配列/, stderr.string)
  end

  def test_cli_run_returns_nonzero_for_empty_keywords
    stdout = StringIO.new
    stderr = StringIO.new

    status = PodcastDownloaderCLI.run(
      config: default_config,
      keywords: [],
      command_runner: ->(*_command) { flunk 'command should not be called' },
      stdout: stdout,
      stderr: stderr
    )

    assert_equal 1, status
    refute_match(/処理が完了しました/, stdout.string)
    assert_match(/1件以上/, stderr.string)
  end

  def test_cli_run_from_files_loads_config_and_keywords
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, 'config.yml')
      keywords_path = File.join(dir, 'keywords.yml')
      File.write(config_path, default_config.to_yaml)
      File.write(keywords_path, "- show\n")
      commands = []

      status = PodcastDownloaderCLI.run_from_files(
        config_path: config_path,
        keywords_path: keywords_path,
        command_runner: ->(*command) { commands << command; true },
        stdout: StringIO.new,
        stderr: StringIO.new
      )

      assert_equal 0, status
      assert_equal 1, commands.length
    end
  end

  def test_cli_run_from_files_reports_load_errors
    Dir.mktmpdir do |dir|
      stderr = StringIO.new

      status = PodcastDownloaderCLI.run_from_files(
        config_path: File.join(dir, 'missing.yml'),
        keywords_path: File.join(dir, 'keywords.yml'),
        stdout: StringIO.new,
        stderr: stderr
      )

      assert_equal 1, status
      assert_match(/ファイルが見つかりません/, stderr.string)
    end
  end

  private

  def run_cli_with_fake_yt_dlp(source, keywords: ['TM Network'])
    with_fake_yt_dlp(source) do |path|
      stdout = StringIO.new
      stderr = StringIO.new
      status = PodcastDownloaderCLI.run(
        config: default_config.merge('yt_dlp_path' => path),
        keywords: keywords,
        stdout: stdout,
        stderr: stderr
      )
      [status, stdout.string, stderr.string]
    end
  end

  def with_fake_yt_dlp(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'fake-yt-dlp')
      File.write(path, "#!#{RbConfig.ruby}\n" + source)
      File.chmod(0o755, path)
      yield path
    end
  end

  def parse_keyword(str)
    @downloader.send(:parse_keyword, str)
  end

  def build_downloader(
    config: default_config,
    keywords: ['keyword'],
    command_runner: ->(*_command) { true },
    stdout: StringIO.new,
    stderr: StringIO.new
  )
    PodcastDownloader.new(
      config,
      keywords,
      command_runner: command_runner,
      stdout: stdout,
      stderr: stderr
    )
  end

  def option_value(options, option)
    options.fetch(options.index(option) + 1)
  end

  def default_config
    {
      'area_id' => 'JP13',
      'audio_dir' => '/tmp/audio',
      'yt_dlp_path' => '/usr/local/bin/yt-dlp'
    }
  end
end
