# iPhone Duoのレイアウトと検証

[English](iphone-duo.md) | **日本語**

Xcode 27.1以降のiOS SDKでビルドします。iOS 27.1の予約領域とArrangementViewのAPIは、iOS専用の実装と可用性チェックで限定し、iOS 27.0では通常のレイアウトへ戻します。macOSのネイティブ操作とデッキの寸法は維持します。

## 画面の選択

機種名、`UIDevice`のidiom、物理ピクセル数から表示を判定しません。シーンのhorizontal size classがcompactならiPhoneのタブとデッキ、regularなら広い画面用のライブラリを使います。size classを取得できない場合だけ、現在のViewの幅600ptを境界にします。

展開したDuoでは、`reservedRegions(kind: .division, options: [.includeInactive])`から画面の分割領域も取得できます。rootでこの機能の有無を確認し、`usesDividedDisplay`で共有するため、ヒンジ領域がinactiveなOpenでもDuo用の表示を選べます。横向きではNavigationSplitViewと下部パネル、縦向きでは後述の再生画面を使います。iPadは広い画面用のライブラリ、macOSはネイティブ操作と既存のデッキ寸法を使います。

広いiOS画面のサイドバーは180〜240pt、基準200ptです。一覧と詳細を含む領域に幅620pt・高さ300pt以上があるとき、240ptの詳細を横に置きます。領域が狭い場合やアクセシビリティ用の文字サイズでは、Detailsボタンからシートで表示します。EQも一覧の高さが430pt未満になる場合はシートに移します。これらの数値は部品の配置に必要な幅と高さであり、Duoの画面解像度ではありません。

## 再生パネルと半折り表示

Duoの横向きでは、再生パネルの右半分をLED領域、左半分をコンパクトな操作領域に割り当てます。音量調整は幅188pt以下・高さ44ptの横一列にまとめます。再生・音量・調整ボタンは44pt以上のタッチ領域を保ち、狭い領域では段組を変え、さらに不足する場合は操作部をスクロールできます。展開した操作部にもミュート／ミュート解除と出力先（AirPlay）の選択を残します。

Duoの縦向きでは、再生画面の上半分を幅いっぱいの上下2段に分け、上段にLED、下段にメーターとランプを置きます。画面の下半分には、シーク・再生・音量・調整と画面移動の操作を置きます。Libraryボタンで同じView内のライブラリを開き、Closeで再生画面へ戻ります。この配置はOpenとBookの両方で使います。展開したDuoでは保存済みのClassicやLED左配置よりこのデザインを優先し、iPadとmacOSでは保存済みの設定を使います。

Bookでは、activeな横方向のdivisionとそのmarginsから、表示領域の下端と操作領域の上端を決めます。LEDとメーターはヒンジより上、操作はヒンジより下に収めます。iOS 27.1ではactiveなocclusionとそのmarginsも、各部品のローカル座標で避けます。配置の判断には取得した領域と現在のViewの寸法を使います。

ClosedでNow Playingを開いてから展開した場合も、デッキのDisplayページを同じ縦向き・横向きのデザインに切り替えます。全画面表示の提示元、選択中のページ、編集シートの所有者は維持します。通常のcompact表示では既存の縦スクロールを使います。ほかのデッキ配置に使うArrangementViewは、NavigationStackの内側、各ScrollViewの外側に置きます。標準ツールバーに属する表示切り替え・設定・フィルターには、iOS 27.1の縦配置の優先設定を適用します。

## 状態と処理の所有者

LibraryBrowsingStateはレイアウトの分岐より上で保持します。分類・グループ・プレイリストの経路、検索・フィルター・並び順、選択、複数編集と閲覧位置を共有し、縦向きの再生画面とライブラリの切り替えでも引き継ぎます。iOSの設定、情報・歌詞編集、複数編集、アートワーク拡大、書き出しの命名シートも、分岐で消えない提示元から開きます。デッキのページと編集シート、動画の全画面表示は、それぞれの安定した親Viewが保持します。

一覧の更新を行うLibraryListUpdatesは、縦向き・横向きの分岐より上の親に1つ置きます。各枝に付けると、新しい枝が更新した後に古い枝の`onDisappear`が共通の一覧をキャンセルし、入力と表示項目を消す場合があります。共通の親に置くことで、回転中も更新元の寿命を維持します。

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

- 単体テスト: LibraryLayoutPolicyTests、DuoPortraitPlayerLayoutTests、LibraryBrowsingStateTests、AdaptiveBottomPanelTests、PlayerPlaybackGenerationTests、SharedExportSessionTests、iOSのIPhoneShareSheetTests。境界サイズ、縦向きの表示部の段組、予約領域、削除、曲の再読み込み、共有コントローラーの再生成を確認します。
- DuoPlayerDesignUITestsは、各ケースの実際の姿勢と向きをDevice Hubで選んでから実行します。`testLandscapeLEDConsumesRightHalf`はOpenの横向き、`testPortraitVisualsStayAboveControlsAndLibraryReturns`はOpenまたはBookの縦向きで実行します。LEDと操作部の配分、44ptの操作領域、Library・Settingsの表示と終了を挟んだ再生継続を確認します。領域の配分はGeometryReaderの診断値を使い、rootの寸法・安全領域を画面座標に対応付けて、Bookのヒンジのマージンも確認します。向きや座標の条件が合わない場合、またはactiveなocclusion、複数・横方向以外のdivisionがある場合はskipします。`XCUIDevice.orientation`は変更しません。向きの通知だけではDuoの実画面が回転しない場合があるためです。起動時にClassicとLED左配置を指定し、展開したDuoのデザインが優先されることも確認します。
- `DuoPlayerDesignUITests/testLibrarySurvivesRealRotationFromPortrait`はOpenまたはBookの縦向きから起動し、xcodebuildの環境に`TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1`を指定して実行します。ログの`DuoOrientationStep`に従い、Device Hubで実画面を縦向き→横向き→縦向きに回転します。横向きのライブラリと、縦向きに戻ってLibraryを開いた後の一覧にfixtureの曲が表示され、再生中の項目・キュー・世代が変わらないことを確認します。対話式の回転を有効にしない場合はskipします。
- DuoのOpenをDevice Hubで選び、DuoLayoutUITestsとDuoBrowsingUITestsを実行します。回転、再生、設定、分類、プレイリスト、歌詞と書き出し名の草稿を確認します。Xcode 27.1 Betaでは、XCTestが回転を通知しても実際の画面が回転しない場合があります。その場合は`TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1`を指定し、ログの`DuoOrientationStep`に従ってDevice Hubで回転します。テストは実際のシーン寸法が変わったことを待ち、通知だけでは成功にしません。
- 実際の開閉はDuoFoldTransitionUITestsを使います。`TEST_RUNNER_DUO_INTERACTIVE_POSE_TESTS=1`をxcodebuildの環境に指定し、ログの`DuoPostureStep`に従ってDevice HubでClosed→Book→Openを選びます。XCTestの公開APIに折り姿勢の操作がないため、このテストには操作者が必要です。
- `--ui-testing-duo-layout`のDEBUG診断では、Viewの寸法、size class、安全領域、予約領域、再生状態を記録します。各パネルの`<regionID>Metrics`は、割り当てた領域のグローバル座標`x/y/width/height`を返します。アクセシビリティのグループ矩形は子要素の範囲まで含む場合があるため、パネルの配分を測る用途には使いません。`--ui-testing-compact-layout`は従来iPhoneのテスト用強制指定であり、Duoの実開閉の代わりには使いません。
- UI runnerの入力に制約がある場合は、`--ui-testing-phone-layout --ui-testing-duo-layout --ui-testing-duo-autoplay-probe --ui-testing-audible-layout --ui-testing-duo-long-playback`でDEBUG版を起動します。fixtureの先頭曲を一度だけ再生し、毎秒の`DuoPlaybackMetrics`をstdoutに出します。Device Hubで実際に開閉し、同一項目・キュー・世代、時刻の進行、左右RMSを確認します。UIからの再生開始や編集操作の検証とは区別します。
- macOSとiPad、iOS 27.0のiPhoneもビルドし、関連する操作テストを実行します。`scripts/lint.sh`と`git diff --check`も実行します。

実行結果、観測した寸法と残る未検証条件は[GitHub Wikiの実装記録](https://github.com/log5r/simple-media-player/wiki/iPhone-Duo-Implementation-Plan)に記録します。

## Appleの資料

[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)、[Adapt custom layouts](https://developer.apple.com/videos/play/tech-talks/111463/)、[Adapt tab bars and toolbars](https://developer.apple.com/videos/play/tech-talks/111462/)、[Displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/)に従います。
