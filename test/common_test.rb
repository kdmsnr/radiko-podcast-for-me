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
    assert_raises(SystemExit) do
      RadikoPodcastForMe.load_yaml_file('/tmp/non-existent-file.yml')
    end
  end

  def test_load_yaml_file_raises_on_invalid_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'invalid.yml')
      File.write(path, "foo: :bar: baz\n")
      assert_raises(SystemExit) do
        RadikoPodcastForMe.load_yaml_file(path)
      end
    end
  end
end
