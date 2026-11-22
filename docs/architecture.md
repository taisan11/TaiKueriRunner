# 画面とコードの構成

TaiKueriRunnerは「機能ごとの画面」と「機能に依存しない共有ロジック」を分けて配置しています。
画面の役割（最上位層・中位層・下位層）はナビゲーション上の概念として残し、ディレクトリ名には使いません。

## ディレクトリ構成

```
TaiKueriRunner/
├── App/                 アプリの入口と全体状態
├── Features/            機能ごとの画面と、その機能だけが使うロジック
│   ├── Wallpaper/
│   ├── Keypad/
│   ├── LINE/
│   ├── MobileGestalt/
│   ├── Applications/
│   ├── AppGroups/
│   ├── FileBrowser/
│   └── Settings/
├── Core/                複数の機能から使うモデル・サービス
├── UI/                  複数の機能から使うSwiftUI部品
├── Native/              Objective-Cブリッジ
└── Resources/
```

### Features

各機能は必要な範囲で `Views/` と `Services/` に分けます。
画面から機能固有のモデルやサービスを参照する向きだけを許可し、サービスから画面を参照しません。

- `Features/Wallpaper`: 壁紙ライブラリ、tendie・Batterの編集
- `Features/Keypad`: キーパッドのテーマ編集とエクスポート
- `Features/LINE`: LINEデータの閲覧とメディア表示
- `Features/MobileGestalt`: MobileGestaltの読み込みと編集
- `Features/Applications`: アプリ一覧・詳細・ZIPエクスポート
- `Features/AppGroups`: App Groups一覧・詳細・ZIPエクスポート
- `Features/FileBrowser`: パス指定、ファイル一覧、テキスト・Plist・SQLite等のビューア
- `Features/Settings`: 設定タブ、キャッシュ削除、アクセス状態、ログ

### Core

複数の機能から共有するロジックを役割別に置きます。

- `Core/Models`: 全機能で共有する値型とエラー
- `Core/Access`: Sandbox Extensionの取得、`FileAccessManager`、書き込みトランザクション
- `Core/Archive`: ZIPの読み書きとエクスポート
- `Core/Backup`: バックアップの保存・復元・一覧
- `Core/Files`: ファイル操作の共通型、使用量、セッションキャッシュ
- `Core/Storage`: アプリのキャッシュ管理
- `Core/System`: Respringなど端末操作

`FileAccessManager` はファイルシステム操作を一か所に集約するactorです。
各機能のサービスは `FileAccessManager` を受け取り、画面はサービスを通して読み書きします。

### UI

`BackupsView`、`FileShareButton`、`FileWriteConfirmationView`、`RespringAttemptView` のように、
複数の画面から呼び出すSwiftUI部品は `UI/` に置きます。特定の機能でしか使わない画面は `Features/` に置きます。

## 画面の3層

`App/AppLayer.swift` の `AppLayer` / `AppFeature` はホーム画面のグルーピングにだけ使います。

- 最上位層（Top）: 壁紙、キーパッド、LINE、MobileGestaltの編集・閲覧
- 中位層（Middle）: アプリ一覧、App Groups
- 下位層（Bottom）: パスをたどるファイルビューア

上位層の画面がアプリ一覧やApp Groupsを必要とする場合は、`AppModel.loadApplications()` / `AppModel.scanAppGroups()` を通して中位層のキャッシュを利用します。アプリ一覧を探す処理を最上位層に複製しません。

ファイルビューアへフォルダを渡す場合は `AppModel.browse(path:)` を使います。

## アプリシェル

`App/` にアプリ全体の状態と入口があります。

- `AppLayer.swift`: 層・機能・タブの定義
- `HomeView.swift`: 最上位層への入口
- `AppModel.swift`: 共有モデル、セッションキャッシュ、タブ移動
- `TaiKueriRunnerApp.swift`: 4タブの構成

## テスト

`Package.swift` の `RunnerCore` ターゲットは `Core/` と各 `Features/*/Services/` だけをコンパイルします。
SwiftUIの画面はXcodeのアプリターゲットでのみビルドされるため、macOS上でロジックのテストを実行できます。
