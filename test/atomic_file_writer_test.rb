require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/atomic_file_writer'

class AtomicFileWriterTest < Minitest::Test
  def test_write_replaces_content_and_preserves_existing_permissions
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'rss.xml')
      File.write(path, 'old')
      File.chmod(0o640, path)

      result = RadikoPodcastForMe::AtomicFileWriter.new.write(path, 'new')

      assert_equal path, result
      assert_equal 'new', File.read(path)
      assert_equal 0o640, File.stat(path).mode & 0o777
    end
  end

  def test_write_preserves_an_existing_group
    alternate_group = Process.groups.find { |group| group != Process.egid }
    skip 'no alternate process group is available' unless alternate_group

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'rss.xml')
      File.write(path, 'old')
      File.chown(-1, alternate_group, path)

      RadikoPodcastForMe::AtomicFileWriter.new.write(path, 'new')

      assert_equal alternate_group, File.stat(path).gid
    end
  end

  def test_write_keeps_existing_file_when_rename_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'rss.xml')
      File.write(path, 'known good')
      writer = RadikoPodcastForMe::AtomicFileWriter.new(
        rename: ->(_source, _target) { raise Errno::EIO, 'rename failed' }
      )

      assert_raises(Errno::EIO) do
        writer.write(path, 'partial')
      end

      assert_equal 'known good', File.read(path)
      assert_equal ['rss.xml'], Dir.children(dir)
    end
  end

  def test_write_follows_an_existing_symlink
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'target.xml')
      link = File.join(dir, 'rss.xml')
      File.write(target, 'old')
      File.symlink(target, link)

      RadikoPodcastForMe::AtomicFileWriter.new.write(link, 'new')

      assert File.symlink?(link)
      assert_equal 'new', File.read(target)
    end
  end

  def test_write_follows_a_dangling_symlink
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'new-target.xml')
      link = File.join(dir, 'rss.xml')
      File.symlink('new-target.xml', link)

      RadikoPodcastForMe::AtomicFileWriter.new.write(link, 'new')

      assert File.symlink?(link)
      assert_equal 'new', File.read(target)
    end
  end

  def test_write_resolves_a_relative_dangling_link_from_its_real_directory
    Dir.mktmpdir do |dir|
      real_dir = File.join(dir, 'real')
      nested_dir = File.join(real_dir, 'nested')
      FileUtils.mkdir_p(nested_dir)
      directory_link = File.join(dir, 'alias')
      File.symlink(nested_dir, directory_link)
      output_link = File.join(directory_link, 'rss.xml')
      File.symlink('../target.xml', output_link)
      expected_target = File.join(real_dir, 'target.xml')

      RadikoPodcastForMe::AtomicFileWriter.new.write(output_link, 'new')

      assert File.symlink?(output_link)
      assert_equal 'new', File.read(expected_target)
      refute File.exist?(File.join(dir, 'target.xml'))
    end
  end
end
