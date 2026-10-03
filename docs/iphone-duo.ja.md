# iPhone Duoのレイアウトと検証

[English](iphone-duo.md) | **日本語**

Xcode 27.1以降のiOS SDKでビルドします。iOS 27.1の予約領域とArrangementViewのAPIは、iOS専用の実装と可用性チェックで限定し、iOS 27.0では通常のレイアウトへ戻します。macOSのネイティブ操作とデッキの寸法は維持します。

## 画面の選択

機種名、`UIDevice`のidiom、物理ピクセル数から表示を判定しません。シーンのhorizontal size classがcompactならiPhoneのタブとデッキ、regularならNavigationSplitViewと下部パネルを使います。size classを取得できない場合だけ、現在のViewの幅600ptを境界にします。

広いiOS画面のサイドバーは180〜240pt、基準200ptです。一覧と詳細を含む領域に幅620pt・高さ300pt以上があるとき、240ptの詳細を横に置きます。領域が狭い場合やアクセシビリティ用の文字サイズでは、Detailsボタンからシートで表示します。EQも一覧の高さが430pt未満になる場合はシートに移します。これらの数値は部品の配置に必要な幅と高さであり、Duoの画面解像度ではありません。

## 再生パネルと半折り表示

広いiOS画面の再生・音量・調整操作は、44pt以上のタッチ領域を持ちます。LEDと操作部の配分は内容に必要な幅で決め、狭い領域では段組を変え、さらに不足する場合は操作部をスクロールできます。iOS 27.1ではactiveなdivision・occlusionとそのmarginsを、各部品のローカル座標で避けます。

デッキのDisplayページでは、NavigationStackの内側、各ScrollViewの外側にArrangementViewを置き、LED／動画と操作を分けます。半折りのヒンジをまたぐ操作を避け、通常のcompact表示では既存の縦スクロールを使います。レイアウトの判断にヒンジ角度は使いません。標準ツールバーに属する表示切り替え・設定・フィルターには、iOS 27.1の縦配置の優先設定を適用します。

## 状態と処理の所有者

LibraryBrowsingStateはレイアウトの分岐より上で保持します。分類・グループ・プレイリストの経路、検索・フィルター・並び順、選択、複数編集と閲覧位置を共有します。iOSの設定、情報・歌詞編集、複数編集、アートワーク拡大、書き出しの命名シートも、分岐で消えない提示元から開きます。デッキのページと編集シート、動画の全画面表示は、それぞれの安定した親Viewが保持します。

PlayerViewModelを作り直したり、開閉を理由に停止・再読み込みしたりしません。シーク操作は開始時の項目IDと再生世代を記録し、停止・切り替え・同じ曲の再読み込み・エンジンリセット・失敗のあとに届く古い完了を拒否します。一時停止・再開・レイアウト変更では世代を変更しません。

共有用の書き出しファイルはSharedExportSessionが所有します。共有コントローラーの破棄では削除せず、共有の完了・キャンセルかセッションの解放で削除します。提示がシステムによって終了した場合、もう一度Exportを選ぶと既存の出力を共有できます。古いコントローラーの完了通知は提示IDで拒否します。

## 確認方法

Xcodeの全体設定を切り替えず、コマンドごとに`DEVELOPER_DIR`を指定します。

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer \
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -derivedDataPath .build/DuoDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

- 単体テスト: LibraryLayoutPolicyTests、LibraryBrowsingStateTests、AdaptiveBottomPanelTests、PlayerPlaybackGenerationTests、SharedExportSessionTests、iOSのIPhoneShareSheetTests。境界サイズ、予約領域、削除、曲の再読み込み、共有コントローラーの再生成を確認します。
- DuoのOpenをDevice Hubで選び、DuoLayoutUITestsとDuoBrowsingUITestsを実行します。回転、再生、設定、分類、プレイリスト、歌詞と書き出し名の草稿を確認します。Xcode 27.1 Betaでは、XCTestが回転を通知しても実際の画面が回転しない場合があります。その場合は`TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1`を指定し、ログの`DuoOrientationStep`に従ってDevice Hubで回転します。テストは実際のシーン寸法が変わったことを待ち、通知だけでは成功にしません。
- 実際の開閉はDuoFoldTransitionUITestsを使います。`TEST_RUNNER_DUO_INTERACTIVE_POSE_TESTS=1`をxcodebuildの環境に指定し、ログの`DuoPostureStep`に従ってDevice HubでClosed→Book→Openを選びます。XCTestの公開APIに折り姿勢の操作がないため、このテストには操作者が必要です。
- `--ui-testing-duo-layout`のDEBUG診断では、Viewの寸法、size class、安全領域、予約領域、再生状態を記録します。`--ui-testing-compact-layout`は従来iPhoneのテスト用強制指定であり、Duoの実開閉の代わりには使いません。
- UI runnerの入力に制約がある場合は、`--ui-testing-phone-layout --ui-testing-duo-layout --ui-testing-duo-autoplay-probe --ui-testing-audible-layout --ui-testing-duo-long-playback`でDEBUG版を起動します。fixtureの先頭曲を一度だけ再生し、毎秒の`DuoPlaybackMetrics`をstdoutに出します。Device Hubで実際に開閉し、同一項目・キュー・世代、時刻の進行、左右RMSを確認します。UIからの再生開始や編集操作の検証とは区別します。
- macOSとiPad、iOS 27.0のiPhoneもビルドし、関連する操作テストを実行します。`scripts/lint.sh`と`git diff --check`も実行します。

実行結果、観測した寸法と残る未検証条件は[GitHub Wikiの実装記録](https://github.com/log5r/simple-media-player/wiki/iPhone-Duo-Implementation-Plan)に記録します。

## Appleの資料

[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)、[Adapt custom layouts](https://developer.apple.com/videos/play/tech-talks/111463/)、[Adapt tab bars and toolbars](https://developer.apple.com/videos/play/tech-talks/111462/)、[Displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/)に従います。
