# SimpleMediaPlayer

[English](README.md) | **日本語**

自分の好みを詰め込んだメディアプレイヤーです。
音声・動画ファイルの取り込み、ローカルライブラリの閲覧、プレイリスト管理、再生操作、歌詞表示、音声のビジュアライザーに対応しています。

## 必要な環境

- Xcode 27以降（Swift 6以降とMusic UnderstandingのSDKを含む）
- Xcodeプロジェクトが対応するAppleプラットフォームのSDK
- [Music Understanding](https://developer.apple.com/documentation/musicunderstanding)を使った音楽解析には、macOS 27以降、iOS 27以降、またはiPadOS 27以降が必要です。それより前のOSでは音楽解析を利用できません。

## ローカライズ

アプリは英語と日本語に対応し、システムの言語設定に従って表示します。
画面の文言は `SimpleMediaPlayer/Localizable.xcstrings`、Musicへのアクセス権限の説明は `SimpleMediaPlayer/InfoPlist.xcstrings` で管理しています。
LEDパネルの表記（`EQ`、`KEY`、`SPEED`、`VOLUME`、`ON`／`OFF`）、`BPM`、数値表示は、どちらの言語でも同じ表記を使います。アクセシビリティ用の説明は別途翻訳します。
翻訳不要のカタログ項目には `shouldTranslate: false` を設定します。

## ビルドとテスト

```sh
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer build
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer test
```

## SwiftLint

[SwiftLintPluginsパッケージ](https://github.com/SimplyDanny/SwiftLintPlugins)を使い、SwiftLintのバージョンを **0.65.1** に固定しています。
Xcodeはアプリ、ユニットテスト、UIテストの各ターゲットをビルドするときに `SwiftLintBuildToolPlugin` を実行します。Homebrewでのインストールは不要です。
初回ビルド時はXcodeでパッケージの依存関係を解決し、プラグインの有効化を求められたら **Trust & Enable** を選択してください。
`start.sh` を含むコマンドラインからのビルドでも、最初にこの信頼設定が必要です。新しくチェックアウトした環境で依存関係を解決するには、ネットワークへのアクセスが必要です。

ビルドやテストを実行せずに、3つのソースディレクトリをまとめてlintするには、次のコマンドを使います。

```sh
./scripts/lint.sh
./scripts/lint.sh --strict # エラーに加え、新たな警告でも失敗させる
```

このスクリプトは初回実行時にXcodeのパッケージ解決機能で固定バージョンのバイナリをダウンロードし、パッケージとキャッシュを `.build/` に保存します。
どの作業ディレクトリからでも呼び出せます。追加の引数は `swiftlint lint` に渡されます。

`.swiftlint.yml` はSwiftLintの既定のルールと重大度を使っています。
導入時に98ファイルを検査したところ、413件の違反が見つかりました。整形、ローカル変数名の修正、同じ意味の構文への書き換えで308件を解消し、改行の追加によって関数の長さに関する指摘が3件増えました。
残りの108件は `.swiftlint-baseline.json` に記録し、既存の違反が導入を妨げないようにしています。
新たな警告はXcodeに表示され、新たなエラーはビルドを失敗させます。`--fix` などのオプションを明示しない限り、lintによってソースファイルが変更されることはありません。

保留した指摘には個別の確認が必要です。対象は、ファイル・型・関数の長さ、複雑度、引数の数、タプルや型の構造、SwiftDataモデルとマイグレーション用テストデータに明示した `nil` の初期値、AVFoundationの強制キャスト、テスト用パーサーで意図的に使っている失敗しないUTF-8デコードです。
初期値の削除、キャスト失敗時の扱いの変更、不正な入力を代替文字で補うデコード処理の置き換えは、動作に影響する可能性があるため、一括で自動修正しないでください。
これまでの修正では、永続化スキーマ、呼び出し側の引数ラベル、ローカライズ済みの文言、数値式を維持しています。

ベースラインは既存の問題への対応を保留するもので、問題そのものを修正するものではありません。ベースラインに記録したものも含めてすべての違反を確認するには、次のコマンドを使います。

```sh
mkdir -p .build
printf '[]\n' > .build/swiftlint-empty-baseline.json
./scripts/lint.sh --baseline .build/swiftlint-empty-baseline.json
```

ベースラインを再生成すると新たな違反も記録されるため、レポート全体を確認してから再生成してください。
SwiftLintは既存のベースラインが設定されていても、検出したすべての違反を書き出します。

```sh
./scripts/lint.sh --write-baseline .swiftlint-baseline.json
python3 -m json.tool --no-ensure-ascii --sort-keys --indent 2 \
  .swiftlint-baseline.json .build/swiftlint-baseline-formatted.json
mv .build/swiftlint-baseline-formatted.json .swiftlint-baseline.json
```

ベースラインとの照合には診断メッセージも使うため、既存の長い関数やファイルを編集すると、長さや複雑度の違反が再び報告されることがあります。変更内容を確認してからベースラインを更新してください。
バージョンアップでもルールや解析の動作が変わる可能性があります。Xcodeプロジェクトのパッケージバージョン、`scripts/lint.sh` の `SWIFTLINT_VERSION`、依存関係を固定するロックファイルをまとめて更新し、lintの結果とビルドを確認してください。

各ターゲットのビルドにlintの処理が加わりますが、ターゲットごとのキャッシュで再処理を抑えています。
この導入では `ENABLE_USER_SCRIPT_SANDBOXING = YES` を維持し、配布するアプリにライブラリを追加しません。
対話操作なしでビルドする場合、Xcodeの `-skipPackagePluginValidation` オプションを使えます。ただし、その実行ではプラグインの信頼チェックを省略するため、固定バージョンのプラグインを確認したうえで使ってください。
詳しくは[公式のセットアップ手順](https://github.com/realm/SwiftLint#xcode-projects)を参照してください。

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
