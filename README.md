# radiko-podcast-for-me

- Radikoを録音してPodcastにします
- 家庭内のサーバーで私的利用することを前提としています
- 各スクリプトはcronで実行するとよいでしょう

## 使い方
- [yt-dlp-rajiko](https://github.com/garret1317/yt-dlp-rajiko)とウェブサーバーを用意します（説明省略）
- [exiftool](https://exiftool.org/)をインストールします
  - `brew install exiftool` or `sudo apt install exiftool`
- `bundle install`を実行します
- config.ymlを設定します
- podcast_keywords.ymlに録音したいキーワードを記入します
  - 放送局を限定したい場合は`&station_id=XXX`を末尾に追加するとよいです
    - See: [radikoの放送局一覧を取得してみよう　radiko api - Qiita](https://qiita.com/miyama_daily/items/87c7694a10c36a11a96c)
- スクリプトを実行します
  - podcast_dl.rb はファイルをダウンロードします
  - podcast_rss.rb はダウンロードしたファイルからrss.xmlを生成します
  - podcast_delete.rb は古いファイルを削除します（必要なければ使わない）
