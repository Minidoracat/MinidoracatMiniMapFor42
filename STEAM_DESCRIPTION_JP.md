[h1]🗺️ Minidoracat MiniMap for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⚠️ 必須の前提 MOD（0.20.0 以降）[/h2]
[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701][b]Minidoracat UI Library for B42[/b][/url] が必須。Required Itemsから購読してください。未導入では読み込めません。

[hr][/hr]

[h2]✨ これは何？[/h2]
地図・材質を事前描画したフルカラー俯瞰図を、B42のワールドマップとミニマップに表示。POI・通り名検索・道路ナビで物資探しと経路計画を支援。

[h2]マップ画像の特徴[/h2]
[list]
[*] [b]マップと材質から画像を作成[/b]——建物・植物・地表の材質を合成し、各地域の色合いと景観を真上から表示。
[*] [b]MOD マップの画像も補完[/b]——MOD Maps パックは、地形画像のない収録マップにも別途描画画像を提供。対応は収録マップか作者提供の互換画像があるマップのみ。
[*] [b]標準の段階別ズーム[/b]——ImagePyramid がズームに応じた解像度のタイルを読み込み、バニラのベクターマップにも切替可。
[/list]

背景画像は事前描画のため、プレイヤーの建築・解体・伐採は即時反映されません。ゾンビ・動物・車両アイコンはクライアントの取得済みデータから更新します。

[h2]🧰 主な機能[/h2]
[list]
[*] [b]行程ナビ[/b]：最大16点。追加・挿入・優先、並替・削除／復元・スキップ・経路表示。新規は停車後に自動継続、停留／逐点は待機（既存は逐点）。逸脱時再計算、派閥共有は現在地点のみ
[*] [b]検索／行程ウィンドウ[/b]：虫眼鏡または ;（変更可）で開き、折畳対応。座標・通り名（[u]原名／翻訳名[/u]）・施設20種を検索、地図表示や行程追加。「MOD マップ：名前」は確認済み出所
[*] [b]ホットキー＋フローティングアイコン[/b]：既定 /（変更可）、サンドボックスでミニマップ無効でも自前生成；常駐アイコンは左クリックで開閉・右クリックでゴーストモード、ドラッグで配置
[*] [b]サイズ自由調整[/b]：4 段プリセット＋端ドラッグで自由リサイズ（自動記憶）；ボタンバー常時表示でガタつかない
[*] [b]ゾンビ位置ドット[/b]（既定オフ）：リアルタイム位置表示、色／サイズ／不透明度／上限調整可；バニラのヒートマップ切替も同居
[*] [b]動物＆車両アイコン[/b]（既定オフ）：野生／家畜の独立切替、種と車両カテゴリのフィルタ（互換パックで犬・馬など追加）；2 スタイル、色覚多様性対応パレット
[*] [b]ワールドマップアイコン[/b]：ゾンビ／動物／車両の同アイコンをワールドマップ（M）にも表示、4 独立スイッチ
[*] [b]通り名＋セーフハウス[/b]：ミニマップにも通り名（バニラは非表示）；枠／アイコン／名前の3スイッチ、自分は緑・陣営は水色・他人は赤
[*] [b]座標表示＋コピー[/b]：両マップ下部にx, y, z。ツールバーで現在地、右クリックで任意地点をコピーし、/teleporttoに貼り付け可
[*] [b]ゴーストモード[/b]：クリック・ホイールが透過してゲームに届き、マップは半透明——大きくして常駐しても邪魔しない；' キー
[*] [b]フリールック[/b]：ドラッグ先に留まり、クリック一回でプレイヤーに戻る
[*] [b]マップ表示設定[/b]（歯車）：分類・横断検索、分割画面／大字は1ペイン。即適用・保存、ESC不要。設定／検索／ミニマップ共通の角丸ダークスキン、項目別の性能説明・対策付き
[*] [b]サーバー管理（サンドボックス）[/b]：各アイコンの無効化・表示距離の上限・家畜可視性 4 段階・派閥共有の許可——変更は即時反映
[*] [b]シングル＆マルチ対応[/b]：クライアントが元々受信しているデータの可視化のみ（追加情報なし）；繁体字／簡体字中国語・英語・日本語
[/list]

[b]⚠️ -debug 利用者へ[/b]：HOME はエンジンの隠しレンダリングデバッグキー（FPS 半減）。本 MOD は既定 / で旧バインドを自動移行、競合検出時はオレンジ警告バーを表示。

[h2]🧩 マップ MOD サポート[/h2]
[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps パック[/url]：有効な対応マップの画像＋枠線を自動表示。本体42.20.4-0.27.0+、パック42.20.4-0.9.0+が必要、更新後は再起動。重複区域は優先順に従い、道路が検索・ナビから除外される場合があります。[url=https://steamcommunity.com/workshop/filedetails/discussion/3763913359/569297034317714443/]道路データ要件[/url]。
マップ作者は事前描画した [b]minidoracat_minimap.pyramid.zip[/b] を [b]media/minimap/[/b] に配置（[u]Lua 不要[/u]）。

[h2]🗺️ 内蔵 POI ＋ ゾーンレイヤー API[/h2]
バニラPOI 1669件・20分類。染色／フルカラーアイコンか半透明区画、分類別切替可。位置は公式地図、分類は部屋の[u]loot用途[/u]から判定。地図の色より実際の物資を優先。
地下施設はアイコンに「↓」、検索名に「（地下室）」。用途が地上と異なる場合があります。
`registerZoneProvider` ゾーン描画フレームワークも提供；[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones addon[/url] でサーバー定義ゾーン（zones.json）を表示可、専用の表示距離（サンドボックス＋スライダー）付き。

[h2]🔗 シリーズ MOD[/h2]
必須ライブラリ導入後は[b]本体のみで動作[/b]；addon は任意：
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url]——マップ MOD の画像＋枠線
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url]——動物アイコンに犬・馬など追加
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url]——サーバー定義ゾーン表示
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3792675881]AutoDrive[/url]——複数地点の自動運転は本体0.28.0+とAutoDrive0.8.0+が必要。更新後は完全再起動
[/list]

[h2]📋 MOD 情報[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapFor42
[*] [b]対応バージョン:[/b] Build 42.20.1+
[*] シングル／マルチ対応（マルチはサーバー側で有効化）
[/list]

[h2]💬 フィードバック & コミュニティ[/h2]
[url=https://discord.gg/Gur2V67]👉 Discord サーバーに参加[/url]

[url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml][b]道路・経路の報告[/b][/url]：ずれ・欠落・遠回りは[b]経路・座標が写る画像＋座標テキスト[/b]と症状を一言。起終点・方向・マップMOD／版も推奨。ログ不要。地図上の問題地点を右クリックして座標をコピー。

[h2]☕ 作者を応援[/h2]
常に無料、ソースはGitHubで公開。ご支援はサーバーとMOD開発に使います。
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatMiniMapFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#Minidoracat[/b]

Workshop ID: 3763913359
Mod ID: MinidoracatMiniMapFor42
