# MusicSync — iPhone へ音楽だけをシンプルに同期

PC の音楽フォルダを、Wi-Fi 経由で iPhone の専用プレーヤーアプリへ **差分同期** します。
iTunes / Finder 同期のような写真・アプリ・バックアップなどは一切扱わず、**音楽だけ** を対象にしています。

- **音楽のみ同期**: 追加・変更・削除された曲だけを転送（SHA-256 で内容を検証）
- **アルバムアート自動追加**: 埋め込み画像 → フォルダ画像 (`cover.jpg` など) → オンライン検索（iTunes / MusicBrainz）の順に自動で補完。必要なら音楽ファイルへ埋め込みも可能
- **プレイリスト作成**: iPhone でも PC（Web 画面・コマンド）でも作成・編集でき、双方向に同期

```
┌──────────── PC ────────────┐         Wi-Fi (HTTP)        ┌────────── iPhone ──────────┐
│ musicsync serve ~/Music    │  manifest / 曲 / アート     │ MusicSync アプリ           │
│  ・フォルダを差分スキャン  │ ─────────────────────────▶ │  ・差分ダウンロード        │
│  ・アート自動取得          │                             │  ・オフライン再生          │
│  ・プレイリスト保存        │ ◀───────────────────────── │  ・プレイリスト作成/編集   │
│  ・Web 画面 (playlist編集) │   プレイリスト双方向マージ  │  ・ロック画面操作          │
└────────────────────────────┘                             └────────────────────────────┘
```

> **なぜ専用アプリなのか**: Apple は他社アプリから iPhone 標準の「ミュージック」アプリのライブラリへ
> 曲を書き込む API を公開していません。そのため、同期した曲は MusicSync アプリ内のライブラリで再生します。

---

## 1. PC 側（同期サーバー）

Python 3.10 以上（Windows / macOS / Linux）。

```bash
cd server
pip install -e ".[art]"         # Pillow はアートの縮小・PNG→JPEG 変換に使用（推奨）

musicsync serve ~/Music          # 音楽フォルダを指定して起動
```

起動すると次のように表示されます。iPhone アプリにアドレスとトークンを入力してください。

```
MusicSync 1.0.0
  音楽フォルダ : /Users/you/Music
  曲数         : 1234 曲 (追加 1234 / 更新 0 / 削除 0)
  iPhone アプリの「サーバーを追加」に次を入力してください:
    アドレス   : 192.168.1.10:8765
    トークン   : 7KQ2M9XHPA
  PC でプレイリスト編集: http://localhost:8765/
```

### 主なコマンド

| コマンド | 内容 |
|---|---|
| `musicsync serve <フォルダ>` | 同期サーバー起動（アート自動取得つき） |
| `musicsync serve <フォルダ> --embed-artwork` | 取得したアートを音楽ファイルにも埋め込む |
| `musicsync serve <フォルダ> --no-artwork` | オンラインでのアート取得をしない |
| `musicsync scan <フォルダ>` | スキャンのみ（アートが無いアルバム数も表示） |
| `musicsync artwork <フォルダ> [--embed] [--force]` | アルバムアートを一括取得（`--embed` でファイルへ埋め込み） |
| `musicsync playlist <フォルダ> list` | プレイリスト一覧 |
| `musicsync playlist <フォルダ> create "ドライブ" "曲名" ...` | 作成（曲はタイトルの部分一致・相対パス・ID で指定） |
| `musicsync playlist <フォルダ> add/remove "ドライブ" "曲名" ...` | 曲の追加・削除 |
| `musicsync playlist <フォルダ> rename/delete/show "ドライブ"` | 名前変更・削除・内容表示 |
| `musicsync playlist <フォルダ> export "ドライブ"` | M3U8 に書き出し |
| `musicsync token <フォルダ> [--reset]` | トークン表示（`--reset` で再発行。旧トークンは無効に） |

PC のブラウザで `http://localhost:8765/` を開くと、トークンでログインしてプレイリストを作成・編集できます。

### 対応形式

iPhone で再生できる形式のみ同期します: `mp3, m4a (AAC/ALAC), m4b, aac, wav, aif/aiff, flac, caf`
（`.` で始まる隠しフォルダ・ファイルは対象外）

### アルバムアートの仕組み

1. 曲に埋め込まれた画像（同じアルバムの他の曲にも流用）
2. 曲と同じフォルダの `cover / folder / front / album` 画像（画像が 1 枚だけならそれ）
3. iTunes Search API → MusicBrainz / Cover Art Archive をアルバム名 + アーティストで検索

- 画像は最大 600px の JPEG に揃えて `<音楽フォルダ>/.musicsync/artwork/` にキャッシュ
- 見つからなかったアルバムは 7 日間再検索しません（`--force` で再検索）。ネット未接続時は「見つからない」扱いにしません
- 検索 API の利用制限を守るため、問い合わせ間隔を自動で空けます
- 元の音楽ファイルは `--embed` / `--embed-artwork` を指定したときだけ変更します

### データの保存場所

`<音楽フォルダ>/.musicsync/`（`--data-dir` で変更可）に、スキャン結果・アートのキャッシュ・プレイリスト・トークンを保存します。

---

## 2. iPhone アプリ

要件: macOS + Xcode 15 以降、iOS 17 以降の iPhone。

```bash
brew install xcodegen
cd ios
xcodegen                 # MusicSync.xcodeproj を生成
open MusicSync.xcodeproj
```

1. Xcode で **Signing & Capabilities → Team** に自分の Apple ID を選択（無料アカウントでも実機インストール可。7 日ごとに再インストールが必要）
2. 必要なら Bundle Identifier を一意な値に変更
3. iPhone を接続して ▶︎ で実行

### 使い方

1. 「同期」タブ → **サーバーを設定** → PC に表示されたアドレスとトークンを入力
   （初回は「ローカルネットワーク」へのアクセス許可を求められるので許可してください）
2. **今すぐ同期** — 以降は差分のみ転送されます
3. 「ライブラリ」タブ: アルバム / 曲 / アーティスト表示、検索、長押しで「次に再生」「プレイリストに追加」
4. 「プレイリスト」タブ: 作成・名前変更・削除・曲の追加・並べ替え（編集ボタン）・スワイプ削除

### 同期の動作

- **PC が正**（ミラー同期）: PC から消した曲は iPhone からも消えます
  - ただし PC 側の曲が 0 曲になった場合や半分以上が消える場合は、削除前に確認を表示します（外付けディスク未接続などの事故防止）
- ダウンロードは SHA-256 で検証してから反映。途中で中止しても完了した曲は残り、次回は続きから
- フォルダ名の変更など曲の移動は内容で検出し、プレイリストの参照を自動で付け替えます
- iPhone の空き容量が足りない場合は開始前に知らせます
- 音楽ファイルは iCloud バックアップの対象外（PC から再同期できるため）
- 再生: バックグラウンド再生、ロック画面・コントロールセンター・イヤホン操作、シャッフル・リピート、イヤホンを抜くと一時停止

### プレイリストの同期ルール

プレイリスト単位の **最終更新優先**（Last-Writer-Wins）。iPhone で編集すると数秒後に PC へ自動送信され、
PC で編集した内容は次回の同期で iPhone に反映されます。削除も双方向に伝わります。

---

## 3. 開発・テスト

```bash
# サーバー（ffmpeg があると MP3/M4A/FLAC の実ファイルでテスト）
cd server && pip install -e ".[test]" && python -m pytest -q

# iOS のロジック部分（Mac 上で）
cd ios/MusicSyncCore && swift test
```

- `server/tests/test_contract.py` は Swift 側のモデル定義（`Models.swift`）とサーバーの JSON のキーが一致しているかを検査します
- `ios/MusicSyncCore/Tests/.../Fixtures/manifest.json` は実サーバーの出力で、Swift 側でデコードできることを検査します

### 構成

```
server/musicsync/
  library.py     音楽フォルダの差分スキャン・タグ読み込み・移動検出
  artwork.py     アートの抽出/検索/取得/埋め込み、レート制限
  playlists.py   プレイリスト保存と LWW マージ
  service.py     上記をまとめるサービス層
  server.py      HTTP API（標準ライブラリのみ、Range 対応）
  cli.py         コマンドライン
  web/index.html PC 用プレイリスト編集画面
ios/
  MusicSyncCore/ 純粋ロジック（モデル・差分計画・プレイリストマージ・再生キュー）+ テスト
  MusicSync/     SwiftUI アプリ（同期エンジン・プレーヤー・画面）
  project.yml    XcodeGen 設定
```

### HTTP API

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/api/ping` | サーバー情報（認証不要） |
| GET | `/api/manifest` | 全曲 + プレイリスト |
| GET | `/api/tracks/<id>/audio` | 音声ファイル（Range 対応） |
| GET | `/api/artwork/<id>` | アルバムアート (JPEG) |
| GET/POST | `/api/playlists` | 一覧 / 作成 |
| GET/PUT/DELETE | `/api/playlists/<id>` | 取得 / 更新 / 削除 |
| POST | `/api/playlists/sync` | 双方向マージ |
| POST | `/api/rescan` | 再スキャン |

認証は `Authorization: Bearer <トークン>`。通信は LAN 内の HTTP です（自宅など信頼できるネットワークで使用してください）。

## 制限事項

- iPhone 標準「ミュージック」アプリへは追加されません（Apple の制限）。MusicSync アプリで再生します
- 同期は iPhone と PC が同じネットワークにあり、アプリを開いている間に行います（バックグラウンドでは短時間のみ継続）
- DRM 付きの曲（旧 iTunes Store の保護 AAC など）は再生できません
