# iPhone Duoのレイアウトと検証

[English](iphone-duo.md) | **日本語**

Xcode 27.1以降のiOS SDKでビルドします。iOS 27.1の予約領域とArrangementViewのAPIは、iOS専用の実装と可用性チェックで限定し、iOS 27.0では通常のレイアウトへ戻します。macOSのネイティブ操作とデッキの寸法は維持します。

## 画面の選択

機種名、`UIDevice`のidiom、物理ピクセル数から表示を判定しません。シーンのhorizontal size classがcompactならiPhoneのタブとデッキ、regularなら広い画面用のライブラリを使います。size classを取得できない場合だけ、現在のViewの幅600ptを境界にします。

展開したDuoでは、`reservedRegions(kind: .division, options: [.includeInactive])`から画面の分割領域も取得できます。rootでこの機能の有無を確認し、`usesDividedDisplay`で共有するため、ヒンジ領域がinactiveなOpenでもDuo用の表示を選べます。横向きではNavigationSplitViewと下部パネル、縦向きでは後述の再生画面を使います。iPadは広い画面用のライブラリ、macOSはネイティブ操作と既存のデッキ寸法を使います。

広いiOS画面のサイドバーは180〜240pt、基準200ptです。一覧と詳細を含む領域に幅620pt・高さ300pt以上があるとき、240ptの詳細を横に置きます。領域が狭い場合やアクセシビリティ用の文字サイズでは、Detailsボタンからシートで表示します。EQも一覧の高さが430pt未満になる場合はシートに移します。これらの数値は部品の配置に必要な幅と高さであり、Duoの画面解像度ではありません。

## 再生パネルと半折り表示

Duoの横向きでは、再生パネルの右半分をLED領域、左半分をコンパクトな操作領域に割り当てます。音量調整は高さ44ptの横一列にまとめ、ミュートと出力先のボタンを除いた残りの幅いっぱいにバーを伸ばします。再生・音量・調整ボタンは44pt以上のタッチ領域を保ち、狭い領域では段組を変え、さらに不足する場合は操作部をスクロールできます。展開した操作部のミュート／ミュート解除と出力先（AirPlay）にも、再生ボタンと同じ四角い背景・輪郭・影を使います。

Duoの縦向きでは、再生画面の上半分を幅いっぱいの上下2段に分け、上段にLED、下段にメーターとランプを置きます。画面の下半分には、シーク・再生・音量・調整と画面移動の操作を置きます。Libraryボタンで同じView内のライブラリを開き、Closeで再生画面へ戻ります。半折りの縦向きでは、ライブラリを有効な横方向の分割領域より下に、上端の角を丸めたシートの形で表示し、上半分のLEDとメーターを隠しません。キーボードなどで分割領域より下の高さが280pt未満になる場合は、従来どおり画面全体に表示します。どちらの配置でも同じViewを使うため、検索や閲覧の状態は保たれます。同じ姿勢では、再生画面の設定・イコライザー・詳細のシートも`.medium`の高さで開き、引き上げると`.large`に広がります。この配置はOpenとBookの両方で使います。展開したDuoでは保存済みのClassicやLED左配置よりこのデザインを優先し、iPadとmacOSでは保存済みの設定を使います。縦向きのLEDは画面の角に接しないため、LED板の角がアダプティブの場合も、OpenとBookの両方でLEDの4つの角すべてに同じ小さな固定の半径を使います。角丸を選んだ場合の表示は変わりません。

縦向きの再生画面は、BookでもOpenと同じく現在のViewの中央で上下に分け、折り目のdivisionによる空白を追加しません。シークバーもdivisionを避けず、折り目をまたいで配置できます。カメラなどのactiveなocclusionは引き続き各部品のローカル座標で避けます。横向きの再生パネルとライブラリの標準コンテナは、従来どおり折り目に適応します。

ClosedでNow Playingを開いてから展開した場合も、デッキのDisplayページを同じ縦向き・横向きのデザインに切り替えます。全画面表示の提示元、選択中のページ、編集シートの所有者は維持します。通常のcompact表示では既存の縦スクロールを使います。ほかのデッキ配置に使うArrangementViewは、NavigationStackの内側、各ScrollViewの外側に置きます。標準ツールバーに属する表示切り替え・設定・フィルターには、iOS 27.1の縦配置の優先設定を適用します。

フルスクリーン動画は、縦向きで半折りの場合、有効な横方向の画面分割領域とそのマージンより上の領域に収めます。再生／一時停止・閉じるボタンは分割領域より下に置き、動画と重ならず、カメラなどのactiveなocclusionも避けます。完全に開くか横向きにすると、動画は画面全体へ、操作ボタンは右上へ戻ります。配置変更中も同じAVPlayerを使用し、再生・一時停止・閉じる操作を維持します。開いたDuo、通常のiPhone、iPad、macOSでは従来どおり中央に表示します。

iPhoneのデッキの再生・停止・曲送り・ミュートは、macOSと同じ角丸3ptの四角いボタンを使います。横の安全領域がある縦に短いcompactデッキでは、再生ボタンを52pt、調整用ランプを44ptにし、縦の間隔も詰めます。LEDの情報とステレオスペクトラムを残したまま、Closedの初期表示に再生操作を収めます。操作領域は44pt以上を維持し、さらに狭い領域ではスクロールできるようにします。通常のiPhoneの縦向き、横向き、アクセシビリティ文字サイズでは、従来の300ptの表示と縦スクロールを維持します。曲一覧の複数選択バーは、背景の拡張を下の安全領域だけに限り、縦のタブバーの下へ広がらないようにします。再生ドックの上に置く既存の配置は維持します。

## ツールバーとキーボードコマンド

iOS 27.1のClosedの外側画面では、ナビゲーションバーとタブバーを右端に縦に並べます。ツールバーの項目は縦に並べられる標準の`ToolbarItem`のままにし、`HStack`でまとめず、ボタンに固定の寸法やアイコンだけのラベルスタイルを指定しません。ライブラリのルート、曲一覧、デッキの補助的な操作は`ToolbarOverflowMenu`に置き、省略記号のボタンはシステムのoverflowボタンだけにします。Filters、Add Tracks、Done、Close、Edit Lyricsには`visibilityPriority(.high)`を指定し、領域が足りない場合もoverflowへ移さないようにします。ほかの項目は既定の順序に従います。Doneは文字だけの項目なので横に残る場合があります。ツールバーの項目がCloseだけのシート（設定、再生の調整、イコライザー）は、iOS 27.1で`toolbarVerticalBehavior(.disabled)`を指定して横のバーを保ちます。狭い画面でボタン1つのために縦の列を使わないためです。

再生のキーボードコマンドは、端末のidiomではなく、フォーカス中のシーンにある操作の提供元で判断します。compactと展開の各レイアウトは`AppMenuActions`を提供します。Duoの縦向き再生画面のように、iOSの再生シーンにレイアウト固有の提供元がない場合は、SpaceとCommand+左右矢印キーでplayerを直接操作します。macOSでは提供元がなければ、これらのコマンドは無効のままです。

## 状態と処理の所有者

LibraryBrowsingStateはレイアウトの分岐より上で保持します。分類・グループ・プレイリストの経路、検索・フィルター・並び順、選択、複数編集と閲覧位置を共有し、縦向きの再生画面とライブラリの切り替えでも引き継ぎます。iOSの設定、情報・歌詞編集、複数編集、アートワーク拡大、書き出しの命名シートも、分岐で消えない提示元から開きます。デッキのページと編集シート、動画の全画面表示は、それぞれの安定した親Viewが保持します。

一覧の更新を行うLibraryListUpdatesは、縦向き・横向きの分岐より上の親に1つ置きます。各枝に付けると、新しい枝が更新した後に古い枝の`onDisappear`が共通の一覧をキャンセルし、入力と表示項目を消す場合があります。共通の親に置くことで、回転中も更新元の寿命を維持します。

PlayerViewModelを作り直したり、開閉を理由に停止・再読み込みしたりしません。シーク操作は開始時の項目IDと再生世代を記録し、停止・切り替え・同じ曲の再読み込み・エンジンリセット・失敗のあとに届く古い完了を拒否します。一時停止・再開・レイアウト変更では世代を変更しません。

共有用の書き出しファイルはSharedExportSessionが所有します。共有コントローラーの破棄では削除せず、共有の完了・キャンセルかセッションの解放で削除します。提示がシステムによって終了した場合、もう一度Exportを選ぶと既存の出力を共有できます。古いコントローラーの完了通知は提示IDで拒否します。

## 確認方法

IPhoneDeckLayoutTestsと、ClosedのDuo・通常の縦向きiPhone上のIPhoneDeckLayoutUITestsで、スペクトラムと再生操作の同時表示、LED内容の見切れ、通常iPhoneの表示高、アクセシビリティ文字サイズのスクロールを確認します。CompactSelectionToolbarUITestsは、再生ドック表示中の選択と編集を英語・日本語で確認し、最大アクセシビリティ文字サイズも使います。OpenのSplit Viewの左右でも繰り返します。XCTestのキャプチャが非表示の画面を指す場合、選択テストはskipするためDevice Hubで直接確認します。Duoの撮影では`simctl io <device> enumerate`で画面IDを調べ、`simctl io <device> screenshot --display=<screen-ID> <path>`で表示中の画面を明示します。

Xcodeの全体設定を切り替えず、コマンドごとに`DEVELOPER_DIR`を指定します。

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.0-Release.Candidate.app/Contents/Developer \
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -derivedDataPath .build/DuoDerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

- 単体テスト: LibraryLayoutPolicyTests、DuoPortraitPlayerLayoutTests、LibraryBrowsingStateTests、AdaptiveBottomPanelTests、PlayerPlaybackGenerationTests、SharedExportSessionTests、iOSのIPhoneShareSheetTests。境界サイズ、縦向きの表示部の段組、予約領域、削除、曲の再読み込み、共有コントローラーの再生成を確認します。
- DuoPlayerDesignUITestsは、各ケースの実際の姿勢と向きをDevice Hubで選んでから実行します。`testLandscapeLEDConsumesRightHalf`はOpenの横向き、`testPortraitVisualsStayAboveControlsAndLibraryReturns`はOpenまたはBookの縦向きで実行します。LEDと操作部の配分、44ptの操作領域、Library・Settingsの表示と終了を挟んだ再生継続を確認します。領域の配分はGeometryReaderの診断値を使い、rootの寸法・安全領域を画面座標に対応付けて、Bookでも表示部と操作部が中央で隙間なく接することを確認します。向きや座標の条件が合わない場合、またはactiveなocclusionがある場合はskipします。`testPartiallyFoldedPortraitDoesNotReserveACenterGap`は半折りの縦向き専用で、中央の配分とシークバーの操作可否を確認します。`testPartiallyFoldedPortraitLibraryAndSettingsStayBelowTheFold`も半折りの縦向き専用で、ライブラリが分割領域の下端から画面の下端までを占め、LEDがその上に残ること、設定シートのCloseが分割領域より下にあることを確認します。`XCUIDevice.orientation`は変更しません。向きの通知だけではDuoの実画面が回転しない場合があるためです。起動時にClassicとLED左配置を指定し、展開したDuoのデザインが優先されることも確認します。
- `DuoPlayerDesignUITests/testLibrarySurvivesRealRotationFromPortrait`はOpenまたはBookの縦向きから起動し、xcodebuildの環境に`TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1`を指定して実行します。ログの`DuoOrientationStep`に従い、Device Hubで実画面を縦向き→横向き→縦向きに回転します。横向きのライブラリと、縦向きに戻ってLibraryを開いた後の一覧にfixtureの曲が表示され、再生中の項目・キュー・世代が変わらないことを確認します。対話式の回転を有効にしない場合はskipします。
- DuoのOpenをDevice Hubで選び、DuoLayoutUITestsとDuoBrowsingUITestsを実行します。回転、再生、設定、分類、プレイリスト、歌詞と書き出し名の草稿を確認します。Xcode 27.1 Betaでは、XCTestが回転を通知しても実際の画面が回転しない場合があります。その場合は`TEST_RUNNER_DUO_INTERACTIVE_ORIENTATION_TESTS=1`を指定し、ログの`DuoOrientationStep`に従ってDevice Hubで回転します。テストは実際のシーン寸法が変わったことを待ち、通知だけでは成功にしません。
- 実際の開閉はDuoFoldTransitionUITestsを使います。`TEST_RUNNER_DUO_INTERACTIVE_POSE_TESTS=1`をxcodebuildの環境に指定し、ログの`DuoPostureStep`に従ってDevice HubでClosed→Book→Openを選びます。XCTestの公開APIに折り姿勢の操作がないため、このテストには操作者が必要です。
- `--ui-testing-duo-layout`のDEBUG診断では、Viewの寸法、size class、安全領域、予約領域、再生状態を記録します。各パネルの`<regionID>Metrics`は、割り当てた領域のグローバル座標`x/y/width/height`を返します。アクセシビリティのグループ矩形は子要素の範囲まで含む場合があるため、パネルの配分を測る用途には使いません。`--ui-testing-compact-layout`は従来iPhoneのテスト用強制指定であり、Duoの実開閉の代わりには使いません。
- UI runnerの入力に制約がある場合は、`--ui-testing-phone-layout --ui-testing-duo-layout --ui-testing-duo-autoplay-probe --ui-testing-audible-layout --ui-testing-duo-long-playback`でDEBUG版を起動します。fixtureの先頭曲を一度だけ再生し、毎秒の`DuoPlaybackMetrics`をstdoutに出します。Device Hubで実際に開閉し、同一項目・キュー・世代、時刻の進行、左右RMSを確認します。UIからの再生開始や編集操作の検証とは区別します。
- macOSとiPad、iOS 27.0のiPhoneもビルドし、関連する操作テストを実行します。`scripts/lint.sh`と`git diff --check`も実行します。

実行結果、観測した寸法と残る未検証条件は[GitHub Wikiの実装記録](https://github.com/log5r/simple-media-player/wiki/iPhone-Duo-Implementation-Plan)に記録します。

FullScreenVideoLayoutTestsで動画の上側配置と操作部の下側配置、分割領域のマージンとローカル座標、完全に開いた状態、横向き、画面を分割しない領域を確認します。縦向きの半折りでDuoFullScreenVideoUITestsを実行すると、生成した動画で実際の分割領域と配置を比較し、両ボタンが分割領域より下にあり、動画と重ならず44pt以上の操作領域を持つことを確認できます。一時停止・再開、ダブルタップで閉じる操作、閉じるボタンも確認します。xcodebuildの環境に`TEST_RUNNER_DUO_FULL_SCREEN_TEST_LANGUAGE=ja`を指定すると、日本語のラベルで同じ検証を実行します。既定は英語です。姿勢や画面座標が一致しない場合はskipします。フルスクリーン再生中に完全に開く・回転する遷移は手動で確認します。`--ui-testing-duo-layout`では`fullScreenVideoMetrics`が動画の配置領域を返すため、有効な分割領域と比較できます。

## Appleの資料

[Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)、[Prepare your app for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/)、[Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)と、Tech Talkの[Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)、[Adapt tab bars and toolbars](https://developer.apple.com/videos/play/tech-talks/111462/)、[Adapt custom layouts](https://developer.apple.com/videos/play/tech-talks/111463/)、[Displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/)に従います。App Storeのスクリーンショットの要件は、Wikiの[TestFlight配布準備](https://github.com/log5r/simple-media-player/wiki/TestFlight-Distribution-Preparation)に記録します。
