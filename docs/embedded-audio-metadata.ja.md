# 埋め込み音声メタデータの対応範囲

[English](embedded-audio-metadata.md) | **日本語**

Issue #3 の実装範囲。外部ライブラリやユーザー環境のコマンドには依存しない。ファイルの拡張子と先頭のコンテナ識別子を確認し、Ogg は識別パケットで Vorbis または Opus であることも確認する。編集は元ファイルと同じディレクトリの一時ファイルに書き出し、完了時に置換する。キャンセルや書き込みエラー時には元ファイルを残す。

| 形式 | 読み取りと書き込み | 画像 | 歌詞 | 変換保存先 |
| --- | --- | --- | --- | --- |
| FLAC (`.flac`) | Vorbis Comment。未知のコメントとメタデータブロックを保持 | FLAC PICTURE ブロック。既存のコメント形式の画像も読み取り | `LYRICS`、`UNSYNCEDLYRICS` を読み、`LYRICS` に保存 | 対応 |
| Ogg Vorbis (`.ogg`、`.oga`) | Vorbis Comment。未知のコメントを保持 | Base64 の `METADATA_BLOCK_PICTURE`。既存の `COVERART` も読み取り | 同上 | 対象外 |
| Ogg Opus (`.opus`、`.ogg`、`.oga`) | OpusTags。未知のコメントを保持 | 同上 | 同上 | 対象外 |
| WAV (`.wav`) | RIFF INFO と ID3v2 チャンク。両方ある場合は ID3v2 を優先して読み取り、保存時は両方を更新 | ID3v2 `APIC` | ID3v2 `USLT` | 対応 |

共通の編集項目は、曲名、アーティスト、アルバム、ジャンル、年、トラック番号、コメント、アルバムアーティスト、作曲者、ディスク番号、コンピレーション、画像、歌詞。アプリ内だけの歌詞保存とファイルへの埋め込み保存は引き続き別操作。空文字と画像・歌詞の削除は対象タグをファイルから取り除く。WAV の RIFF INFO は基本的な文字項目を、ID3v2 は全項目を記録する。未知の RIFF チャンクと音声データはそのままコピーする。

Ogg は単一の論理ストリームに対応する。コメントを含むヘッダーページを再構成して CRC とページ番号を更新し、後続ページの音声ペイロードと granule position を維持する。連結ストリーム、複数ストリームの多重化、Ogg FLAC は編集対象外。WAV は通常の RIFF/WAVE に対応し、RF64 と RIFX は対象外。FLAC の画像は標準 PICTURE ブロックに保存する。Ogg と Opus の画像は Vorbis Comment の `METADATA_BLOCK_PICTURE` に保存する。表紙以外の画像と未知のコメント末尾データは保持する。

macOS では、Music が起動中の場合に MP4 系音声の取り込みで Music の表示用メタデータを取得できる。取り込み操作ごとに一度だけライブラリ情報を取得し、元ファイルの場所で照合する。一致しない場合はソート用の曲名・アーティスト・アルバムと長さで照合する。取り込み時に Music の値を MP4・AVFoundation の値より優先する既存の順序は維持する。ライブラリを利用できない場合やオートメーションの権限がない場合は埋め込み値を使う。取り込みによって Music を起動することはない。情報編集と一括編集ではアプリ管理下のファイルとライブラリ項目を読み、Music への照合を行わないため、変更・削除した値が Music の古い値から復元されることはない。iPhone と iPad はこの Music 照合を行わず、埋め込み値を使う。

検証には 0.35 秒の合成音声を使用した。macOS 27.0 で４形式それぞれのタグ・画像・歌詞の保存、削除、再取り込み、PCM の一致、未知チャンクの保持、破損したファイルでの原本保持、キャンセル、Ogg の複数ページにまたがる画像、および FLAC/WAV の変換保存を自動テストした。既存の MP3・M4A・AIFF を含むユニットテストも通過した。

iOS/iPadOS 27 シミュレータでは FLAC・Ogg Opus・WAV の再取り込みとタグ編集が通過した。Ogg Vorbis はタグの書き込み・削除は通過したが、iOS 27 の `AVAudioFile` がテスト用 `.ogg` を開けず、現行の取り込み・再生経路では利用できない。追加デコーダーは Issue #3 の対象外。iOS 用アプリ本体のビルドは通過した。macOS の最低対応 26.5 と iPhone/iPad の実機での動作は未検証。

仕様: [FLAC format](https://xiph.org/flac/format.html)、[Vorbis Comment](https://www.xiph.org/vorbis/doc/v-comment.html)、[Ogg framing](https://xiph.org/ogg/doc/framing.html)、[Opus in Ogg](https://www.rfc-editor.org/rfc/rfc7845)。
