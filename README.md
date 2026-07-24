# logavo

logavo は、ローカル開発中の Web アプリ・バックエンドの挙動を可視化する、自分で育てていく開発支援ツールです。複数プロセスのログを 1 か所に集約してリアルタイム表示し、構造化して SQLite に保存・検索できます（Phase 4 では HTTP プロキシによるレイテンシ計測も追加）。

- **エージェント（Rust）**: 設定した各ログファイルを tail し、1 行を共通 JSON に正規化してサーバーへバッチ送信する。
- **サーバー（Elixir/Phoenix）**: 受信ログを SQLite に保存し、LiveView ダッシュボードでリアルタイム表示・検索する。

詳細な設計・データモデル・フェーズ計画は [`docs/spec.md`](docs/spec.md) を参照してください。

> **対象環境:** ローカル開発マシン（localhost）のみ。認証は省略しており、外部公開を想定していません（`docs/spec.md` 5. 非機能要件）。

---

## リポジトリ構成

```
logavo/
├── README.md
├── docs/spec.md          # 仕様書（設計の source of truth）
├── agent/                # Rust エージェント（ログ収集・パース・送信）
│   ├── Cargo.toml
│   ├── logavo.example.toml   # 設定サンプル
│   └── src/
└── server/               # Elixir/Phoenix サーバー（受信・保存・表示）
```

---

## 前提ツール

依存は最小限に絞っています（`docs/spec.md` 5.1 依存最小主義）。追加のパッケージマネージャやアセットパイプライン（tailwind/esbuild 等）は不要です。

| 用途 | ツール | 補足 |
|---|---|---|
| エージェント | Rust ツールチェーン（`cargo`） | 安定版でビルドできます |
| サーバー | Elixir / Erlang（`mix`） | Phoenix が動くバージョン |
| ストレージ | SQLite | サーバーが同梱の Ecto ドライバ経由で利用（別途インストール不要） |

- Rust: <https://rustup.rs/>
- Elixir: <https://elixir-lang.org/install.html>

---

## 使い方（ログがダッシュボードに届くまで）

以下の手順で、`echo "test" >> app.log` が **リロードなしで** ダッシュボードに流れる状態を再現できます。ターミナルを 3 枚（サーバー / エージェント / ログ書き込み）用意すると分かりやすいです。

### 1. サーバーを起動する

`server/` ディレクトリで、依存取得と DB のセットアップを行ってから起動します。

```bash
cd server
mix deps.get          # 依存取得（初回のみ）
mix ecto.setup        # SQLite DB 作成＋マイグレーション（初回のみ）
mix phx.server        # http://localhost:4000 で起動
```

ブラウザで <http://localhost:4000> を開くと、LiveView ダッシュボードが表示されます（この時点ではログは空です）。以降、このタブは **開いたまま** にしておきます。

- ログ受信 API: `POST /api/ingest`（バッチ受信。詳細は `docs/spec.md` 3.1）
- 検索 API: `GET /api/logs`（source / level / キーワード / 期間で絞り込み。詳細は `docs/spec.md` 3.2）

### 2. エージェントの設定を用意する

設定サンプル [`agent/logavo.example.toml`](agent/logavo.example.toml) をコピーして、監視したいログファイルの `path` と `name`（source 名）を指定します。

```bash
cd agent
cp logavo.example.toml logavo.toml
```

`logavo.toml` の内容（サンプルと同形式）:

```toml
server_url = "http://localhost:4000/api/ingest"

[[sources]]
name = "backend-api"
path = "/absolute/path/to/app.log"
```

- `server_url`: 手順 1 で起動したサーバーの ingest エンドポイント。
- `[[sources]]`: 監視対象ごとに 1 ブロック。複数指定すると並行して tail します。`name` がダッシュボード上の source 名になります。
- `server_url` や `path` が欠けている／TOML が壊れている場合、エージェントは非ゼロ終了で起動を中止します。

動作確認用に空のログファイルを作っておきます:

```bash
touch /absolute/path/to/app.log
```

### 3. エージェントを起動する

`agent/` ディレクトリで、用意した設定ファイルを渡して起動します。

```bash
cd agent
cargo run --release -- logavo.toml
```

エージェントは各 source のファイル末尾を監視し、追記された行を検知して JSON に正規化（`docs/spec.md` 2.1）、最大 100 件 or 1 秒ごとにサーバーへバッチ送信します。サーバーが一時的に落ちていてもバッファに蓄積し、復帰後に再送します（上限超過分は破棄）。

### 4. ログを流してダッシュボードで確認する

別のターミナルで、監視対象ファイルに 1 行追記します。

```bash
echo "test" >> /absolute/path/to/app.log
```

手順 1 で開いたままのダッシュボードに、リロードなしで新着ログが流れます（`Phoenix.PubSub` によるブロードキャストで反映）。レベル（debug / info / warn / error / unknown）は行内容から正規表現で推定され、色分け表示されます。推定に失敗しても元の行は `raw` として必ず保持されます。

エラーレベルの色分けを確認するには、例えば次のように書き込みます:

```bash
echo "2026-07-25 12:34:56 [ERROR] connection refused" >> /absolute/path/to/app.log
```

---

## 検索・フィルタと保持ポリシー（Phase 3）

ダッシュボード上部のフィルタで **source / level / キーワード / 期間** による絞り込みができます。同じ条件は検索 API `GET /api/logs?source=...&level=...&q=...&from=...&to=...&limit=...` でも取得できます。

古いログはサーバー側の保持ポリシーで自動的に間引かれます（既定値は `docs/spec.md` および server 側の設定を参照）。

---

## HTTP プロキシロガー（Phase 4）

エージェントはリバースプロキシとして動作し、通過する HTTP リクエストの method / path / status / latency_ms / req_size / res_size を記録して `docs/spec.md` 2.2 の形式で送信できます（例: `:9000` で受けて `:3000` の実サーバーへ転送）。ダッシュボードにはリクエスト用のビュー（遅い順・ステータス別集計）が用意されています。設定・起動方法は `agent/logavo.example.toml` のプロキシ関連項目を参照してください。

---

## 開発・テスト

品質ゲートは各サブプロジェクトのディレクトリで実行します。

```bash
# エージェント（Rust）
cd agent && cargo check && cargo test

# サーバー（Elixir/Phoenix）
cd server && mix test
```

parser（Rust）と ingest（Elixir）はユニットテスト必須です（`docs/spec.md` 5. テスト方針）。

---

## ライセンス

MIT License.
