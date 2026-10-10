# SimpleMediaPlayer

[English](README.md) | **日本語**

自分の好みを詰め込んだメディアプレイヤーです。
音声・動画ファイルの取り込み、ローカルライブラリの閲覧、プレイリスト管理、再生操作、歌詞表示、音声のビジュアライザーに対応しています。

## 必要な環境

- Xcode 27.1以降（Swift 6以降とMusic UnderstandingのSDKを含む。Xcode 27.1 Betaにも対応）
- Xcodeプロジェクトが対応するAppleプラットフォームのSDK
- [Music Understanding](https://developer.apple.com/documentation/musicunderstanding)を使った音楽解析には、macOS 27以降、iOS 27以降、またはiPadOS 27以降が必要です。それより前のOSでは音楽解析を利用できません。

埋め込みタグの形式別・項目別の対応範囲は[音声メタデータの対応表](docs/embedded-audio-metadata.ja.md)（[English](docs/embedded-audio-metadata.md)）を参照してください。
[追加の音声形式](docs/extended-audio-formats.ja.md)（[English](docs/extended-audio-formats.md)）には、WMA・WavPack・Monkey's Audio・Musepackの再生、キャッシュ、制限事項を記載しています。

## iPhone Duo

開いた内側の画面では、サイドバー・メディア一覧・詳細・LED再生パネルを表示します。幅の狭いウィンドウと閉じた外側の画面では、iPhone向けのタブとデッキを使います。レイアウトが変わっても、再生とライブラリの閲覧状態を引き継ぎます。対応する表示とSimulatorでの確認方法は[レイアウトと検証](docs/iphone-duo.ja.md)を参照してください。

## ローカライズ

アプリは英語と日本語に対応し、システムの言語設定に従って表示します。
画面の文言は `SimpleMediaPlayer/Localizable.xcstrings`、Musicへのアクセス権限の説明は `SimpleMediaPlayer/InfoPlist.xcstrings` で管理しています。
LEDパネルの表記（`EQ`、`KEY`、`SPEED`、`VOLUME`、`ON`／`OFF`）、`BPM`、数値表示は、どちらの言語でも同じ表記を使います。アクセシビリティ用の説明は別途翻訳します。
翻訳不要のカタログ項目には `shouldTranslate: false` を設定します。

## ビルドとテスト

ビルド時にSwiftLintが自動実行されます。`start.sh` を含む初回ビルドの前に、Xcodeでプロジェクトを開いてパッケージを解決し、プラグインの **Trust & Enable** を選択してください。
lintの実行方法や設定は[SwiftLintガイド](docs/swiftlint.ja.md)を参照してください。

```sh
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer build
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer test
```

## Xcodeのデバッガーを使わずに起動する

リポジトリ内の起動スクリプトを使うと、Xcodeからデバッグ実行せずに、通常のmacOSアプリとしてビルド・起動できます。

```sh
./start.sh
```

引数を指定しない場合は、既存のReleaseビルドを起動します。ビルド済みのアプリがなければ、先にビルドします。
ビルド成果物は、リポジトリ内のGit管理対象外ディレクトリ `.build/` に保存されます。次のオプションも指定でき、組み合わせて使えます。

```sh
./start.sh rebuild       # クリーン・再ビルド後にRelease版を起動
./start.sh debug         # Debug版をビルドして起動
./start.sh rebuild debug # クリーン・再ビルド後にDebug版を起動
```

アプリバンドル内の実行ファイルは、次の場所にあります。

```text
.build/DerivedData/Build/Products/Release/SimpleMediaPlayer.app/Contents/MacOS/SimpleMediaPlayer
```

配布用のmacOSアプリを作成するには、Xcodeで `SimpleMediaPlayer` スキームを選び、**Product > Archive** からアーカイブを作成して、アプリを書き出してください。
iPhone・iPad向けのビルドは署名が必要で、Xcode、Finder、Apple Configuratorなどを通じてインストールします。macOSアプリのように、単体の実行ファイルとして起動することはできません。

## iPhone・iPadでのMusicライブラリ

iPhone・iPadでは、ライブラリのメニューに **Musicから再生…** と **Musicから取り込み…** があります。どちらもシステムのメディアピッカーを開き、端末にダウンロード済みでDRMのない曲だけを選べます。Apple Musicのサブスクリプション楽曲、保護された曲、クラウドにしかない曲は対象外です。

- **Musicから再生…** は、選んだ1曲を一時的なコピーとして書き出し、アプリ自身のプレーヤーで再生します。イコライザー、キー・速度の調整、ビジュアライザー、音楽解析は通常どおり使えます。ライブラリには追加せず、ほかのメディアへ切り替えたりクリアしたりすると一時コピーを削除します。この曲に対する情報編集、調整済みコピーの保存、AAC版の作成は無効になります。
- **Musicから取り込み…** は、選んだ曲をアプリのメディアディレクトリへ書き出し、通常のライブラリ項目として登録します。AAC、Apple Lossless、MP3、AIFF、WAVは元の符号化を維持し、それ以外の符号化はAACに変換して結果メッセージで知らせます。Music側のメタデータとアートワークを、ファイルに埋め込まれたタグより優先します。すでにMusicから取り込んだ曲は飛ばします。Musicライブラリの原本は変更しません。

この機能にはMusicライブラリへのアクセス権限（`NSAppleMusicUsageDescription`）が必要です。拒否された場合はアプリが理由を示し、設定を開くボタンを表示します。

## メディアの保存場所

取り込んだメディアファイルは、元の場所を直接参照せず、アプリ専用のメディアディレクトリにコピーして管理します。

サンドボックス化されたmacOSアプリでは、バンドルIDに基づく次の場所に保存します。

```text
~/Library/Containers/<Bundle ID>/Data/Library/Application Support/<Bundle ID>/Media
```

ファイル名はUUIDを使って生成し、元の拡張子を維持します。例：`2E3102B4-4359-4180-A481-C7EAB1DE9E49.mp3`。

## コード署名

シミュレーター向けのビルドは、そのまま実行できます。実機向けにビルドするには、Git管理対象外の `Configs/Signing.local.xcconfig` を作成し、自分のApple Developer Team IDを設定してください。

```
DEVELOPMENT_TEAM = XXXXXXXXXX
```

## ライセンス

ソースコードは[MITライセンス](LICENSE)で公開しています。

同梱フォントには、MITライセンスではなくSIL Open Font License（OFL）が適用されます。

- DSEG7 Classic Mini — [OFL-DSEG.txt](SimpleMediaPlayer/Resources/Fonts/OFL-DSEG.txt)
- DotGothic16 — [OFL-DotGothic16.txt](SimpleMediaPlayer/Resources/Fonts/OFL-DotGothic16.txt)
- Dotrice — [OFL-Dotrice.txt](SimpleMediaPlayer/Resources/Fonts/OFL-Dotrice.txt)
