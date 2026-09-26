# SwiftLint

[English](swiftlint.md) | **日本語**

[READMEに戻る](../README.ja.md)

以下のコマンドはリポジトリのルートで実行してください。

## 初回設定

[SwiftLintPluginsパッケージ](https://github.com/SimplyDanny/SwiftLintPlugins)を使い、SwiftLintのバージョンを **0.65.1** に固定しています。
Xcodeはアプリ、ユニットテスト、UIテストの各ターゲットをビルドするときに `SwiftLintBuildToolPlugin` を実行します。Homebrewでのインストールは不要です。
初回ビルド時はXcodeでパッケージの依存関係を解決し、プラグインの有効化を求められたら **Trust & Enable** を選択してください。
`start.sh` を含むコマンドラインからのビルドでも、最初にこの信頼設定が必要です。新しくチェックアウトした環境で依存関係を解決するには、ネットワークへのアクセスが必要です。

## lintの実行

ビルドやテストを実行せずに、3つのソースディレクトリをまとめてlintするには、次のコマンドを使います。

```sh
./scripts/lint.sh
./scripts/lint.sh --strict # エラーに加え、新たな警告でも失敗させる
```

このスクリプトは初回実行時にXcodeのパッケージ解決機能で固定バージョンのバイナリをダウンロードし、パッケージとキャッシュを `.build/` に保存します。
どの作業ディレクトリからでも呼び出せます。追加の引数は `swiftlint lint` に渡されます。

## ルールとベースライン

`.swiftlint.yml` はSwiftLintの既定のルールと重大度を使っています。
既存の違反は `.swiftlint-baseline.json` に記録しています。
新たな警告はXcodeに表示され、新たなエラーはビルドを失敗させます。`--fix` などのオプションを明示しない限り、lintによってソースファイルが変更されることはありません。

保留した指摘には個別の確認が必要です。対象は、ファイル・型・関数の長さ、複雑度、引数の数、タプルや型の構造、SwiftDataモデルとマイグレーション用テストデータに明示した `nil` の初期値、AVFoundationの強制キャスト、テスト用パーサーで意図的に使っている失敗しないUTF-8デコードです。
初期値の削除、キャスト失敗時の扱いの変更、不正な入力を代替文字で補うデコード処理の置き換えは、動作に影響する可能性があるため、一括で自動修正しないでください。

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

## ビルドへの組み込み

各ターゲットのビルドにlintの処理が加わりますが、ターゲットごとのキャッシュで再処理を抑えています。
この導入では `ENABLE_USER_SCRIPT_SANDBOXING = YES` を維持し、配布するアプリにライブラリを追加しません。
対話操作なしでビルドする場合、Xcodeの `-skipPackagePluginValidation` オプションを使えます。ただし、その実行ではプラグインの信頼チェックを省略するため、固定バージョンのプラグインを確認したうえで使ってください。
詳しくは[公式のセットアップ手順](https://github.com/realm/SwiftLint#xcode-projects)を参照してください。
