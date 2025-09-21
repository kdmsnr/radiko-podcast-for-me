
require 'yaml'

module RadikoPodcastForMe
  def self.load_yaml_file(filepath)
    begin
      YAML.load_file(filepath)
    rescue Errno::ENOENT
      abort("エラー: ファイルが見つかりません: #{filepath}")
    rescue Psych::SyntaxError => e
      abort("エラー: YAMLファイルの形式が正しくありません: #{filepath} - #{e.message}")
    end
  end
end
