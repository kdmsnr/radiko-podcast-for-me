# radiko-podcast-for-me

- Radikoを録音してPodcastにします
- 家庭内のサーバーで私的利用することを前提としています
- 各スクリプトはcronで実行するとよいでしょう

## 使い方
- [yt-dlp-rajiko](https://github.com/garret1317/yt-dlp-rajiko)とウェブサーバーを用意します（説明省略）
  - pipx install 'yt-dlp[plugins]'
  - pipx inject yt-dlp yt-dlp-rajiko
- [exiftool](https://exiftool.org/)をインストールします
  - `brew install exiftool` or `sudo apt install exiftool`
- `bundle install`を実行します
- config.ymlを設定します
  - `concurrent_fragments` はyt-dlpが同時取得するフラグメント数です（省略時は5、番組の取得件数ではありません）
  - カバー画像は `channel_image` にHTTP(S) URL、または `audio_dir` 内のパスを指定します（[設定例](config.sample.yml)）
  - RSSを複数出力したい場合は `feeds` を使います（`match` でファイル名を絞り込み）
    - `match` は文字列 or `/正規表現/` を指定でき、配列で複数指定可能
- podcast_keywords.ymlに録音したいキーワードを記入します
  - 放送局を限定したい場合は`&station_id=XXX`を末尾に追加するとよいです
    - See: [radikoの放送局一覧を取得してみよう　radiko api - Qiita](https://qiita.com/miyama_daily/items/87c7694a10c36a11a96c)
- スクリプトを実行します
  - podcast_dl.rb はファイルをダウンロードします
  - podcast_rss.rb はダウンロードしたファイルからrss.xmlを生成します
    - 音声ファイルが見つかったのに有効なRSSアイテムを1件も生成できない場合、既存のRSSは保持されます
    - 安全に置き換えるため、RSS出力先ディレクトリには一時ファイルの作成とrenameの権限が必要です
    - 既存のRSSの所有者・グループ・モードを引き継ぐため、実行ユーザーからそれらを設定できる必要があります
  - podcast_delete.rb は古い `.mp3` / `.m4a` ファイルを削除します（必要なければ使わない）
    - yt-dlpの残骸など他形式も削除する場合は `delete_all_files: true` を明示します

```sh
cd /path/to/radiko-podcast-for-me
bundle exec ruby podcast_dl.rb
bundle exec ruby podcast_rss.rb
bundle exec ruby podcast_delete.rb
```

カバー画像を音声ファイルと同じディレクトリに置く場合は、`channel_image` にファイル名を指定します。
付属の [カバー画像](assets/cover.jpg) を使う場合は、`audio_dir` で指定したディレクトリにコピーしてください。
画像は3000×3000pxの透過なしJPEGです。
これは [Apple Podcastsの推奨サイズ](https://podcasters.apple.com/support/5514-show-cover-template) に合わせています。

```yaml
audio_dir: "/var/www/html/podcast/files"
base_url: "http://raspberrypi.local/podcast/files/"
channel_image: "cover.jpg"
```

相対パスは `audio_dir` を基準に解決します。
`/var/www/html/podcast/files/cover.jpg` のような絶対パスも指定できます。
パスで指定する画像は `audio_dir` 内に置いてください。
`podcast_rss.rb` を実行すると、`base_url` と画像の相対パスからURLを組み立て、RSSの `<itunes:image>` と `<image>` に出力します。
上の設定では `http://raspberrypi.local/podcast/files/cover.jpg` になります。
HTTP(S) URLを直接指定することもできます。

`feeds` を使う場合は共通設定を引き継ぎ、各フィードの `channel_image` で上書きできます。
`channel_image: null` を指定したフィードには画像を出力しません。

cronからも、リポジトリへ移動して `bundle exec ruby ...` の形で実行してください。各スクリプトは一部でも処理に失敗すると終了コード1を返します。

`podcast_dl.rb` は、途中で失敗しても残りのキーワードを処理し、最後に失敗したキーワードを表示します。
`Downloading 0 items` は、その検索で取得対象が0件だったことを示します。yt-dlpが正常終了した場合は成功として扱います。
最後に「一部のダウンロードに失敗しました」と表示された場合は、失敗したキーワードのログにある `ERROR:` または警告・エラーを確認してください。
標準エラーも含めてログを保存するには、次のように実行します。

```sh
bundle exec ruby podcast_dl.rb > podcast_dl.log 2>&1
```

## テスト

```sh
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```
