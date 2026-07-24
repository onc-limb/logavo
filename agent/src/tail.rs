// logavo agent: ファイル追記行の非同期 tail (Phase 1, agent-tail)。
//
// agent-config が読んだ各 source について、対象ファイルへの追記行を tokio で
// 非同期に検知し、mpsc チャネル経由で呼び出し側へ渡す。複数 source を tokio の
// タスクとして並行に tail する。検知した行は agent-parse が spec 2.1 の JSON へ
// 正規化する。
//
// spec 5.1 依存最小主義 / PR 記録用: 本モジュールは中核要件『tokio でファイルの
// 追記行を非同期に検知する』を満たすため tokio 非同期ランタイムを用いる。tokio は
// docs/spec.md 5.1 と親 epic が中核依存 (tokio/axum/serde/regex) として明示的に
// 追加を許可・推奨しており、依存最小主義の対象は中核依存以外である。
//
// ファイル追記の検知はポーリング (EOF 到達時に非同期 sleep して再読込) で行う。
// tokio 単体にファイル変更のイベント通知機構は無く、真のイベント駆動には notify
// クレート (中核依存以外) が必要になるため、その導入は後続の判断に委ねる。ただし
// sleep は非同期であり、旧実装のようにスレッドをブロックしないため、ランタイムや
// 他 source の tail を妨げない。

use std::io::{ErrorKind, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::fs::File;
use tokio::io::{AsyncBufReadExt, AsyncSeekExt, BufReader};
use tokio::sync::mpsc::{self, Receiver, Sender};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::config::Source;

// ASSUMPTION: 追記のポーリング間隔。ローカル開発ツールとして体感遅延と CPU の
// バランスを取り 200ms とする (spec 5.1「監視対象アプリに影響を与えない」)。
// EOF 到達時のみ非同期 sleep するため、他タスクやランタイムはブロックしない。
const POLL_INTERVAL: Duration = Duration::from_millis(200);

// mpsc チャネルのバッファ容量。バースト書き込みで送信側が過度にブロックしない
// 程度に確保する。受信が滞れば送信側は自然に背圧を受ける。
const CHANNEL_CAPACITY: usize = 1024;

/// tail が検知した 1 行。
///
/// source 名・元ファイルパス・(tail 開始以降の) 行番号・生テキストを持つ。
/// agent-parse がこれを spec 2.1 の JSON (message/level/raw/meta.file/meta.line_no)
/// へ正規化する。`raw` は改行を除いた元の行 (spec: raw は必ず保持)。
pub struct TailLine {
    pub source: String,
    pub path: PathBuf,
    /// tail 開始 (ファイル末尾) 以降に検知した行の連番 (1 始まり)。
    ///
    /// ASSUMPTION: spec 2.1 の meta.line_no は絶対行番号を想起させるが、末尾から
    /// tail する Phase 1 では開始前の行数を数えないため、ここでは「tail 開始以降の
    /// 検知順」を採用する。絶対行番号が必要になれば起動時に既存行を数えて基点にする。
    pub line_no: u64,
    pub raw: String,
}

/// 起動した tail タスク群のハンドル。`stop()` で全タスクを停止・join する。
pub struct Tailer {
    stop_tx: watch::Sender<bool>,
    handles: Vec<JoinHandle<()>>,
}

impl Tailer {
    /// 全 tail タスクへ停止を通知し、終了を待つ。
    ///
    /// watch チャネルで停止フラグをブロードキャストする。各タスクは次のポーリング
    /// 待ちを中断して速やかに抜けるため、Ctrl-C からの正常停止経路として機能する。
    pub async fn stop(self) {
        // 受信タスクが既に全終了していると send は Err になるが、その場合は停止済み。
        let _ = self.stop_tx.send(true);
        for handle in self.handles {
            let _ = handle.await;
        }
    }
}

/// 設定の各 source を並行に tail する。
///
/// 返り値の `Receiver<TailLine>` から検知行を順に受け取れる。すべての tail
/// タスクが終了する (受信側が drop される等) と、チャネルは自然に閉じる。
pub fn spawn(sources: &[Source]) -> (Tailer, Receiver<TailLine>) {
    let targets: Vec<(String, PathBuf)> = sources
        .iter()
        .map(|s| (s.name.clone(), PathBuf::from(&s.path)))
        .collect();
    spawn_all(targets)
}

/// (name, path) の組を並行 tail する内部エントリ。テストからも利用する。
fn spawn_all(targets: Vec<(String, PathBuf)>) -> (Tailer, Receiver<TailLine>) {
    let (tx, rx) = mpsc::channel(CHANNEL_CAPACITY);
    let (stop_tx, _) = watch::channel(false);
    let mut handles = Vec::with_capacity(targets.len());

    for (name, path) in targets {
        let tx = tx.clone();
        let stop_rx = stop_tx.subscribe();
        let handle = tokio::spawn(async move {
            watch_file(name, path, tx, stop_rx).await;
        });
        handles.push(handle);
    }

    // オリジナルの送信端を捨て、tail タスクの送信端のみを残す。
    // 全タスク終了時に rx が閉じるようにするため。
    drop(tx);

    (Tailer { stop_tx, handles }, rx)
}

/// 1 つのファイルを末尾から tail し、追記行を tx へ送り続ける。
async fn watch_file(
    source: String,
    path: PathBuf,
    tx: Sender<TailLine>,
    mut stop_rx: watch::Receiver<bool>,
) {
    let mut reader = match open_at_end(&path, &mut stop_rx).await {
        Some(reader) => reader,
        None => return, // 停止要求がファイル出現より先に来た。
    };

    // 改行が来るまでの部分行を溜めるバッファ。
    let mut pending = String::new();
    let mut line_no: u64 = 0;

    while !*stop_rx.borrow() {
        let mut chunk = String::new();
        match reader.read_line(&mut chunk).await {
            Ok(0) => {
                // EOF: 追記を待つ (非同期 sleep)。停止通知が来れば即座に抜ける。
                //
                // TODO: ログローテーション対応 (Phase 1 では後回し)。現状は同一の
                // ファイルハンドルを読み続けるだけで、ローテーション
                // (truncate による切り詰め / rename + 新規作成 / inode 変更) を
                // 検知できない。将来は tokio::fs::metadata の len と inode/ctime を
                // 監視し、ファイルの縮小・付け替えを検知したら再オープンする。
                tokio::select! {
                    _ = sleep(POLL_INTERVAL) => {}
                    _ = stop_rx.changed() => return,
                }
            }
            Ok(_) => {
                pending.push_str(&chunk);
                if pending.ends_with('\n') {
                    line_no += 1;
                    let raw = strip_eol(&pending).to_string();
                    let emitted = TailLine {
                        source: source.clone(),
                        path: path.clone(),
                        line_no,
                        raw,
                    };
                    if tx.send(emitted).await.is_err() {
                        // 受信側が閉じられた: このタスクを終了する。
                        return;
                    }
                    pending.clear();
                }
                // 改行未達なら部分行として pending に保持し、次の追記を待つ。
            }
            Err(ref e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => {
                // 読み取りエラー (一時的な IO エラー等): 少し待って継続する。
                // busy-spin を避けるため必ずスリープする。停止通知が来れば抜ける。
                // TODO: ローテーション起因のエラーもここへ来うる。再オープン検討。
                tokio::select! {
                    _ = sleep(POLL_INTERVAL) => {}
                    _ = stop_rx.changed() => return,
                }
            }
        }
    }
}

/// 対象ファイルを開いて末尾へシークする。
///
/// ファイルがまだ存在しなければ、出現するまで (または停止要求まで) 待つ。
async fn open_at_end(
    path: &Path,
    stop_rx: &mut watch::Receiver<bool>,
) -> Option<BufReader<File>> {
    while !*stop_rx.borrow() {
        if let Ok(file) = File::open(path).await {
            let mut reader = BufReader::new(file);
            if reader.seek(SeekFrom::End(0)).await.is_ok() {
                return Some(reader);
            }
        }
        // ファイル未作成: 出現を待つ。停止通知が来れば即座に抜ける。
        // TODO: ローテーションで再作成されるケースの検知もここで扱う (後回し)。
        tokio::select! {
            _ = sleep(POLL_INTERVAL) => {}
            _ = stop_rx.changed() => return None,
        }
    }
    None
}

/// 行末の改行 (`\n` および直前の `\r`) を取り除く。
fn strip_eol(line: &str) -> &str {
    match line.strip_suffix('\n') {
        Some(rest) => rest.strip_suffix('\r').unwrap_or(rest),
        None => line,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;
    use tokio::time::{sleep, timeout};

    // テスト用一時ファイル名の重複を避けるためのカウンタ。
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_path(tag: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        path.push(format!(
            "logavo-tail-test-{}-{}-{}.log",
            std::process::id(),
            tag,
            n
        ));
        path
    }

    fn append_line(path: &Path, text: &str) {
        let mut f = OpenOptions::new().append(true).open(path).unwrap();
        writeln!(f, "{}", text).unwrap();
        f.flush().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn detects_appended_lines_in_order() {
        let path = temp_path("append");
        std::fs::File::create(&path).unwrap();

        let (tailer, mut rx) = spawn_all(vec![("app".to_string(), path.clone())]);
        // watcher が open + 末尾シークを終えるのを待つ。
        sleep(Duration::from_millis(100)).await;

        append_line(&path, "hello");
        append_line(&path, "world");

        let l1 = timeout(Duration::from_secs(2), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let l2 = timeout(Duration::from_secs(2), rx.recv())
            .await
            .unwrap()
            .unwrap();

        assert_eq!(l1.source, "app");
        assert_eq!(l1.raw, "hello");
        assert_eq!(l1.line_no, 1);
        assert_eq!(l1.path, path);

        assert_eq!(l2.raw, "world");
        assert_eq!(l2.line_no, 2);

        tailer.stop().await;
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ignores_content_written_before_tail_start() {
        let path = temp_path("preexisting");
        {
            let mut f = std::fs::File::create(&path).unwrap();
            writeln!(f, "old-1").unwrap();
            writeln!(f, "old-2").unwrap();
            f.flush().unwrap();
        }

        let (tailer, mut rx) = spawn_all(vec![("app".to_string(), path.clone())]);
        sleep(Duration::from_millis(100)).await;

        append_line(&path, "new-1");

        let line = timeout(Duration::from_secs(2), rx.recv())
            .await
            .unwrap()
            .unwrap();
        // 既存行はスキップし、tail 開始後の追記だけを検知する。
        assert_eq!(line.raw, "new-1");
        assert_eq!(line.line_no, 1);

        tailer.stop().await;
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn tails_multiple_sources_concurrently() {
        let p1 = temp_path("multi1");
        let p2 = temp_path("multi2");
        std::fs::File::create(&p1).unwrap();
        std::fs::File::create(&p2).unwrap();

        let (tailer, mut rx) = spawn_all(vec![
            ("one".to_string(), p1.clone()),
            ("two".to_string(), p2.clone()),
        ]);
        sleep(Duration::from_millis(100)).await;

        append_line(&p1, "from-one");
        append_line(&p2, "from-two");

        let mut got = HashSet::new();
        for _ in 0..2 {
            let line = timeout(Duration::from_secs(2), rx.recv())
                .await
                .unwrap()
                .unwrap();
            got.insert((line.source, line.raw));
        }

        assert!(got.contains(&("one".to_string(), "from-one".to_string())));
        assert!(got.contains(&("two".to_string(), "from-two".to_string())));

        tailer.stop().await;
        let _ = std::fs::remove_file(&p1);
        let _ = std::fs::remove_file(&p2);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn assembles_partial_line_until_newline() {
        let path = temp_path("partial");
        std::fs::File::create(&path).unwrap();

        let (tailer, mut rx) = spawn_all(vec![("app".to_string(), path.clone())]);
        sleep(Duration::from_millis(100)).await;

        // 改行なしの部分書き込み → まだ 1 行として確定しない。
        {
            let mut f = OpenOptions::new().append(true).open(&path).unwrap();
            write!(f, "par").unwrap();
            f.flush().unwrap();
        }
        // ポーリング 1 周以上待ってから残りを書く。
        sleep(Duration::from_millis(250)).await;
        {
            let mut f = OpenOptions::new().append(true).open(&path).unwrap();
            writeln!(f, "tial").unwrap();
            f.flush().unwrap();
        }

        let line = timeout(Duration::from_secs(2), rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(line.raw, "partial");

        tailer.stop().await;
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn strips_trailing_crlf() {
        assert_eq!(strip_eol("abc\n"), "abc");
        assert_eq!(strip_eol("abc\r\n"), "abc");
        assert_eq!(strip_eol("abc"), "abc");
        assert_eq!(strip_eol(""), "");
    }
}
