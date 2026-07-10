# logavo — ローカル開発向けログ収集・監視ツール 仕様書

## 1. プロジェクト概要

### 1.1 目的

ローカル環境で開発中のWebアプリ・バックエンドの挙動を可視化する、自分で育てていく開発支援ツール。
開発者のローカル環境で動き、開発時の実装・デバッグ・データ分析を支援して開発者体験の向上に寄与する。
改善についても直感ではなく、データに基づいたレイテンシーなどを確認できるようにする。

- 複数プロセスのログを1か所に集約してリアルタイム表示(ログビューア)
- HTTPリクエスト/レスポンスの記録とレイテンシ計測(プロキシロガー)
- ログを構造化してSQLiteに保存し、検索・集計できる基盤(構造化パイプライン)

### 1.2 技術スタック

| 層 | 技術 | 役割 |
|---|---|---|
| エージェント | Rust (tokio, axum, serde, regex) | ログ収集・パース・HTTPプロキシ |
| サーバー | Elixir (Phoenix, LiveView, Ecto) | 受信・保存・リアルタイム表示 |
| ストレージ | SQLite (ecto_sqlite3) | ログの永続化 |
| 通信 | HTTP(JSON) → 将来WebSocket | エージェント→サーバー |

### 1.3 リポジトリ構成(モノレポ)

```
logavo/
├── README.md
├── docs/
│   └── spec.md              # 本仕様書
├── agent/                   # Rust エージェント
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs
│       ├── tailer.rs        # ファイルtail
│       ├── parser.rs        # ログ構造化
│       ├── shipper.rs       # サーバーへ送信
│       └── proxy.rs         # HTTPプロキシ (Phase 4)
└── server/                  # Elixir/Phoenix サーバー
    ├── mix.exs
    ├── config/
    ├── lib/
    │   ├── logavo/
    │   │   ├── ingest/      # 受信・保存
    │   │   └── logs/        # 検索・集計コンテキスト
    │   └── logavo_web/
    │       ├── controllers/ # 受信API
    │       └── live/        # LiveView ダッシュボード
    └── priv/repo/migrations/
```

---

## 2. データモデル

### 2.1 ログエントリ(共通フォーマット)

エージェントはあらゆるログをこのJSONに正規化してサーバーへ送る。

```json
{
  "timestamp": "2026-07-09T12:34:56.789Z",
  "source": "backend-api",
  "level": "error",
  "message": "connection refused",
  "raw": "2026-07-09 12:34:56 [ERROR] connection refused",
  "meta": { "file": "/var/log/app.log", "line_no": 1024 }
}
```

| フィールド | 型 | 説明 |
|---|---|---|
| timestamp | ISO8601 | ログ発生時刻(パース不能ならエージェント受信時刻) |
| source | string | ログの出所(エージェント設定で命名) |
| level | enum | debug / info / warn / error / unknown |
| message | string | パース後の本文 |
| raw | string | 元の生ログ行(必ず保持) |
| meta | object | 追加情報(ファイルパス、行番号、HTTP情報など) |

### 2.2 HTTPリクエストログ(Phase 4)

```json
{
  "timestamp": "...",
  "source": "proxy",
  "level": "info",
  "message": "GET /api/users 200",
  "meta": {
    "method": "GET",
    "path": "/api/users",
    "status": 200,
    "latency_ms": 42,
    "req_size": 0,
    "res_size": 1532
  }
}
```

### 2.3 テーブル定義(SQLite)

```sql
CREATE TABLE log_entries (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp  TEXT NOT NULL,        -- ISO8601
  source     TEXT NOT NULL,
  level      TEXT NOT NULL,
  message    TEXT NOT NULL,
  raw        TEXT NOT NULL,
  meta       TEXT,                 -- JSON文字列
  inserted_at TEXT NOT NULL
);

CREATE INDEX idx_log_entries_timestamp ON log_entries (timestamp);
CREATE INDEX idx_log_entries_source_level ON log_entries (source, level);
```

---

## 3. API仕様

### 3.1 ログ受信API(サーバー側)

```
POST /api/ingest
Content-Type: application/json

{ "entries": [ <ログエントリ>, ... ] }   # バッチ送信

200 { "accepted": 12 }
422 { "error": "invalid entries", "details": [...] }
```

- エージェントは最大100件 or 1秒ごとにバッチ送信
- 認証はPhase 1では省略(localhost前提)。将来トークンヘッダを追加

### 3.2 検索API(Phase 3)

```
GET /api/logs?source=backend-api&level=error&q=timeout&from=...&to=...&limit=100
```

---

## 4. 開発フェーズ

### Phase 0: プロジェクトセットアップ(目安: 半日)

- [ ] GitHubリポジトリ(README, .gitignore, MITライセンス)を整備
- [ ] `cargo new agent` でRustプロジェクト初期化
- [ ] `mix phx.new server --database sqlite3` でPhoenixプロジェクト初期化
- [ ] 両方がビルド・起動できることを確認しコミット
- [ ] GitHub Actions でCI設定(`cargo check` / `mix test` を回すだけ)

**完了条件:** クローンして両プロジェクトが起動できる。

### Phase 1: 最小エージェント(目安: 1〜2週)

- [ ] 設定ファイル(TOML)で監視対象ファイルとsource名を指定
- [ ] ファイルのtail(追記の検知、ローテーション対応は後回し)
- [ ] 1行 = 1エントリとしてJSON化(levelは正規表現で推定、失敗時 unknown)
- [ ] バッチでPOST(バッファリング、送信失敗時のリトライ)

**設定ファイル例:**
```toml
server_url = "http://localhost:4000/api/ingest"

[[sources]]
name = "backend-api"
path = "/path/to/app.log"
```

**完了条件:** `echo "test" >> app.log` するとサーバーにJSONが届く。

### Phase 2: 受信・保存・表示(目安: 1〜2週)

- [ ] `POST /api/ingest` 実装(バリデーション + Ecto でSQLiteに保存)
- [ ] 保存後 Phoenix.PubSub でブロードキャスト
- [ ] LiveView ダッシュボード: 新着ログがリアルタイムに流れる一覧画面
- [ ] レベル別の色分け表示

**完了条件:** ブラウザを開いたままログを吐くと、リロードなしで画面に流れる。
**→ ここで「形になる」。核が完成。**

### Phase 3: 検索・フィルタ(目安: 1週)

- [ ] 画面上のフィルタ(source / level / キーワード / 期間)
- [ ] 検索API `GET /api/logs`
- [ ] 古いログの保持ポリシー(例: 7日 or 10万件で削除)

### Phase 4: HTTPプロキシロガー(目安: 2週)

- [ ] Rustエージェントにリバースプロキシ機能を追加(例: :9000 → :3000)
- [ ] メソッド / パス / ステータス / レイテンシを記録し 2.2 の形式で送信
- [ ] ダッシュボードにリクエスト用ビュー(遅いリクエスト順、ステータス別集計)

### Phase 5以降(育てる方向性メモ)

- アラートルール(「ERRORが5分に3回」→ デスクトップ/Slack通知)
- 複数行ログ対応(スタックトレースを1エントリに結合)
- リクエストのリプレイ機能
- WebSocket化による送信効率改善
- プロセスのCPU/メモリ監視

---

## 5. 非機能要件・方針

- **対象環境:** ローカル開発マシン(localhost)のみ。当面セキュリティは最小限
- **オーバーヘッド:** エージェントは監視対象アプリに影響を与えない(CPU数%以内)
- **堅牢性:** サーバーが落ちていてもエージェントは動き続け、復帰後に再送(バッファ上限あり、超過分は破棄)
- **生ログの保持:** パースに失敗しても `raw` は必ず保存し、データを失わない
- **テスト:** parser(Rust)とingest(Elixir)はユニットテスト必須。他はPhase進行を優先

### 5.1 依存関係ポリシー(最小主義)

本プロジェクトの目的は Rust/Elixir の学習であり、また依存が増えるほど攻撃面と
更新負担(Dependabot PR)が広がる。そのため依存は「本当に必要なもの」だけに絞る。

- **原則自作:** 標準ライブラリ+既存依存で妥当なコストで実現できるものはライブラリを
  足さず自分で書く(学習の題材にする)。「便利だから」は追加理由にならない
- **許容する依存:** 1.2 の技術スタックの中核(Rust: tokio/axum/serde/regex、
  Elixir: Phoenix/LiveView/Ecto+SQLite/JSON/HTTPサーバ)と、開発・テスト専用の軽量ツール
- **除外する依存:** アセットパイプライン(tailwind/esbuild 等 — 素の CSS/JS を静的配信)、
  メール送信、i18n、クラスタリング、内蔵監視ダッシュボード等、ローカル専用の
  ログ収集ツールに不要なもの。雛形生成ツールが持ち込んだ不要依存は削除する
- **追加時の手続き:** 新しい依存を足すときは、自作しない理由(コスト/安全性)を
  PR 説明または本仕様書に1〜2行で記録する
- **Phase 2 の LiveView JS:** Phase 2 で LiveView 用の JS が必要になっても esbuild は再導入せず、
  `deps/phoenix_live_view/priv/static/` のビルド済みファイルを `priv/static/` にコピーして直接参照する

## 6. 学習ポイント(言語別)

| Phase | Rust | Elixir |
|---|---|---|
| 1 | tokio非同期, ファイルIO, serde, エラー処理 | — |
| 2 | — | Phoenix, Ecto, LiveView, PubSub |
| 3 | — | Ectoクエリ組み立て |
| 4 | axum/hyperでのプロキシ, レイテンシ計測 | 集計クエリ |
| 5 | — | GenServer, Supervisor(アラート監視) |
