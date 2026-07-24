defmodule Logavo.Logs.Retention do
  @moduledoc """
  ログ保持ポリシー（spec Phase 3）。

  ローカル開発用途のログ収集ツールなので、古いログを間引いて DB が
  無制限に肥大化しないようにする。ポリシーは「期間」と「件数」の二本立てで、
  どちらも既定値を持つ。

  ## 既定値（文書化 — spec Phase 3「既定値を文書化」）

    * 最大保持期間 `max_age_days`: **7 日**（`timestamp` がこれより古い行を削除）
    * 最大保持件数 `max_entries`: **100_000 件**（新しい方から 10 万件を残し、超過分を削除）

  いずれも `enforce/1` のオプション（`:max_age_days` / `:max_entries` / `:now`）で
  上書きできる。

  ## 依存最小主義（spec 5.1）

  外部スケジューラ（quantum 等）は新たな依存を増やすため足さない。呼び出し側
  （取り込み後の定期実行など）から `enforce/0,1` を明示的に呼ぶ最小構成とする。
  対象は localhost のみ。

  ## 配線状況（要フォローアップ — 本サブタスクでは未配線）

  本サブタスク（server-search）のスコープは検索 API・フィルタ UI・および
  この保持ポリシー**モジュール本体**までで、実際にこれを起動する呼び出し側
  （取り込み後フック／application 起動時の周期実行）は含まれて**いない**。
  それらの配線先はいずれも本サブタスクの宣言対象パス外
  （`Logavo.Application` の supervision tree = `application.ex`、
  取り込み後フック = `ingest_controller.ex`）にあたるため、本変更では触らない。

  したがって現状では `enforce/1` / `run/0` を呼ぶ箇所が無く、このまま放置すると
  古いログは一切間引かれない（＝ epic の完了条件『保持ポリシーで古いログが
  間引かれる』は未達）。これは本 PR で残る**統合ギャップ**であり、別サブタスクで
  次のいずれかを配線して閉じること:

    * `Logavo.Application` の supervision tree に、一定間隔で `Retention.run/0` を
      呼ぶ小さな周期実行タスク（`Process.send_after` ベースの GenServer 等。新規
      依存は増やさない）を追加する。
    * もしくは `IngestController` の保存成功後フックから `Retention.enforce/0` を
      （毎回が重い場合は間引いて）呼ぶ。

  本モジュール自体は上記いずれの配線からも副作用なく呼べるよう、純粋な関数
  （`enforce/1` / `run/0`）として提供する。
  """

  import Ecto.Query, warn: false

  alias Logavo.Repo
  alias Logavo.Logs.LogEntry

  # 保持ポリシーの既定値（上のモジュールドキュメントと対で管理する）。
  @max_age_days 7
  @max_entries 100_000

  @doc "既定の最大保持日数。"
  def max_age_days, do: @max_age_days

  @doc "既定の最大保持件数。"
  def max_entries, do: @max_entries

  @doc """
  保持ポリシーを適用し、期間・件数それぞれで削除した件数を返す。

  返り値: `{deleted_by_age, deleted_by_count}`

  オプション:
    * `:max_age_days` — この日数より古い行（`timestamp` 基準）を削除。既定 `#{@max_age_days}`
    * `:max_entries`  — 新しい方からこの件数を残し超過分を削除。既定 `#{@max_entries}`
    * `:now`          — 期間判定の基準時刻（`DateTime`）。既定は現在時刻
  """
  def enforce(opts \\ []) do
    max_age_days = Keyword.get(opts, :max_age_days, @max_age_days)
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    deleted_by_age = delete_older_than(max_age_days, now)
    deleted_by_count = delete_beyond(max_entries)

    {deleted_by_age, deleted_by_count}
  end

  @doc "既定値で `enforce/1` を実行する。"
  def run, do: enforce([])

  # --- 期間ポリシー ------------------------------------------------------
  # ASSUMPTION: `timestamp` は spec 2.1/2.3 の ISO8601(UTC, 末尾 Z) 文字列で
  # 保存される（エージェントはパース不能時も受信時刻を ISO8601 で入れる）。
  # 同一フォーマットの UTC ISO8601 は辞書順が時系列順と一致するため、DateTime を
  # ロードせず文字列比較で古い行を判定する（`inserted_at` の Ecto 型に依存しない）。
  defp delete_older_than(days, %DateTime{} = now) when is_integer(days) and days > 0 do
    cutoff =
      now
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    {deleted, _} = Repo.delete_all(from le in LogEntry, where: le.timestamp < ^cutoff)
    deleted
  end

  defp delete_older_than(_days, _now), do: 0

  # --- 件数ポリシー ------------------------------------------------------
  # 新しい方から `max` 件を残す。id は AUTOINCREMENT で単調増加するため、
  # 「新しい方から max 件目」の id を境界に、それ以下を削除する。
  defp delete_beyond(max) when is_integer(max) and max > 0 do
    threshold_id =
      from(le in LogEntry,
        order_by: [desc: le.id],
        offset: ^max,
        limit: 1,
        select: le.id
      )
      |> Repo.one()

    case threshold_id do
      nil ->
        0

      id ->
        {deleted, _} = Repo.delete_all(from le in LogEntry, where: le.id <= ^id)
        deleted
    end
  end

  defp delete_beyond(_max), do: 0
end
