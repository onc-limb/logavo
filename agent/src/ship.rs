// agent-ship: 正規化済みログのバッチ送信とバッファ再送 (Phase 1)。
//
// docs/spec.md 3.1 に従い、正規化済みログ (1件 = spec 2.1 の JSON オブジェクト
// 文字列) を最大 100 件 or 1 秒ごとにバッチ化し、`{ "entries": [ ... ] }` として
// server の `POST /api/ingest` へ送信する。
//
// 堅牢性 (spec 5.):
//   - server 不在時は送信せずバッファ (VecDeque) に蓄積し、復帰後に再送する。
//   - バッファには上限があり、超過分は最も古いものから破棄する。
//   - 送信失敗 (接続不可 / タイムアウト / 5xx) はバッファに残し、次の周期で
//     リトライする。4xx (server がバッチを不正と判定) はリトライしても解消しない
//     ため、バッファを詰まらせないよう当該バッチを破棄する。
//
// 依存最小主義 (spec 5.1): 送信先は localhost のみ (spec 5.) のため HTTP
// クライアントは新規依存を足さず tokio::net::TcpStream 上に HTTP/1.1 POST を
// 自作する。
//
// ASSUMPTION: server_url は spec の例に合わせ `http://<host>:<port>/<path>` 形式の
// http URL を想定する (localhost 前提のため https は非対応)。

use std::collections::VecDeque;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{interval, MissedTickBehavior};

/// バッチ 1 回あたりの最大件数 (spec 3.1)。
const MAX_BATCH: usize = 100;
/// バッチ化の最大待ち時間 (spec 3.1)。
const BATCH_INTERVAL: Duration = Duration::from_secs(1);
/// 未送信バッファの上限件数。超過分は最も古いものから破棄する (spec 5. 堅牢性)。
///
/// ASSUMPTION: spec は上限値を定めていない。ローカル開発でのメモリ影響を抑えつつ
/// 数分程度の server 不在を吸収できる値として 10,000 件を既定とする。
const MAX_BUFFER: usize = 10_000;
/// 1 回の POST (接続〜レスポンス受信) の全体タイムアウト。
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// 送信タスクへのハンドル。追記行を enqueue し、停止時に残りをフラッシュする。
pub struct Shipper {
    tx: mpsc::UnboundedSender<String>,
    handle: JoinHandle<()>,
}

impl Shipper {
    /// 送信バックグラウンドタスクを起動する。
    pub fn spawn(server_url: &str) -> Shipper {
        let (tx, rx) = mpsc::unbounded_channel::<String>();
        let target = Target::parse(server_url);
        let server_url = server_url.to_string();
        let handle = tokio::spawn(run(rx, target, server_url));
        Shipper { tx, handle }
    }

    /// 正規化済みログ (spec 2.1 の JSON オブジェクト文字列) を送信キューへ積む。
    ///
    /// 実際の送信はバックグラウンドタスクがバッチ化して行う。タスクが既に停止して
    /// いる場合 (通常は起こらない) は黙って捨てる。
    pub fn send(&self, entry_json: String) {
        let _ = self.tx.send(entry_json);
    }

    /// 送信キューを閉じ、バックグラウンドタスクが残りをフラッシュして終了するのを待つ。
    pub async fn stop(self) {
        drop(self.tx);
        let _ = self.handle.await;
    }
}

/// 送信先 URL を分解したもの。
struct Target {
    host: String,
    port: u16,
    /// リクエストライン用のパス (先頭 `/` を含む)。
    path: String,
    /// Host ヘッダ用の authority (`host:port`)。
    authority: String,
}

impl Target {
    /// `http://host:port/path` 形式の URL を分解する。
    fn parse(url: &str) -> Result<Target, String> {
        let rest = url
            .strip_prefix("http://")
            .ok_or_else(|| "only http:// URLs are supported (localhost only)".to_string())?;

        let (authority, path) = match rest.find('/') {
            Some(i) => (&rest[..i], &rest[i..]),
            None => (rest, "/"),
        };
        if authority.is_empty() {
            return Err("missing host in server_url".to_string());
        }

        let (host, port) = match authority.rfind(':') {
            Some(i) => {
                let host = &authority[..i];
                let port = authority[i + 1..]
                    .parse::<u16>()
                    .map_err(|_| "invalid port in server_url".to_string())?;
                (host.to_string(), port)
            }
            // ASSUMPTION: ポート省略時は http 既定の 80 を用いる。
            None => (authority.to_string(), 80),
        };

        Ok(Target {
            host,
            port,
            path: path.to_string(),
            authority: authority.to_string(),
        })
    }
}

/// 送信バックグラウンドタスク本体。
async fn run(mut rx: mpsc::UnboundedReceiver<String>, target: Result<Target, String>, server_url: String) {
    let target = match target {
        Ok(t) => t,
        Err(e) => {
            eprintln!("logavo agent: invalid server_url {}: {}", server_url, e);
            // 送信不能。呼び出し側 (main) をブロックしないよう受信だけ続けて捨てる。
            while rx.recv().await.is_some() {}
            return;
        }
    };

    let mut buffer: VecDeque<String> = VecDeque::new();
    let mut healthy = true;
    let mut dropped_total: u64 = 0;

    let mut ticker = interval(BATCH_INTERVAL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            maybe = rx.recv() => {
                match maybe {
                    Some(entry) => {
                        push_bounded(&mut buffer, entry, &mut dropped_total);
                        // 100 件たまったら周期を待たず即フラッシュ (spec 3.1)。
                        // ただし server 不在時 (unhealthy) は毎行リトライせず周期に任せる。
                        if healthy && buffer.len() >= MAX_BATCH {
                            flush_and_report(&mut buffer, &target, &mut healthy, &mut dropped_total).await;
                        }
                    }
                    // 送信キューが閉じられた (停止要求)。残りをベストエフォートで送って終了。
                    None => {
                        flush_and_report(&mut buffer, &target, &mut healthy, &mut dropped_total).await;
                        if !buffer.is_empty() {
                            eprintln!(
                                "logavo agent: {} buffered entrie(s) undelivered at shutdown",
                                buffer.len()
                            );
                        }
                        break;
                    }
                }
            }
            _ = ticker.tick() => {
                if !buffer.is_empty() {
                    flush_and_report(&mut buffer, &target, &mut healthy, &mut dropped_total).await;
                }
            }
        }
    }
}

/// バッファへ 1 件積む。上限超過時は最も古いものを破棄する (spec 5. 堅牢性)。
fn push_bounded(buffer: &mut VecDeque<String>, entry: String, dropped_total: &mut u64) {
    if buffer.len() >= MAX_BUFFER {
        buffer.pop_front();
        *dropped_total += 1;
        if *dropped_total == 1 || *dropped_total % 1000 == 0 {
            eprintln!(
                "logavo agent: buffer full ({} entries); dropping oldest (total dropped {})",
                MAX_BUFFER, *dropped_total
            );
        }
    }
    buffer.push_back(entry);
}

/// フラッシュを実行し、server の可用性が変化したらログする。
async fn flush_and_report(
    buffer: &mut VecDeque<String>,
    target: &Target,
    healthy: &mut bool,
    dropped_total: &mut u64,
) {
    let was_healthy = *healthy;
    let ok = flush(buffer, target, dropped_total).await;
    if ok && !was_healthy {
        eprintln!("logavo agent: server recovered; buffered entries flushed");
    } else if !ok && was_healthy {
        eprintln!(
            "logavo agent: server unavailable ({}); buffering entries for resend",
            target.authority
        );
    }
    *healthy = ok;
}

/// バッファを 100 件ずつバッチ POST する。
///
/// 全て送りきれたら true。途中で再試行対象の失敗 (接続不可 / タイムアウト / 5xx) が
/// あればそのバッチ以降をバッファに残して false を返す (次周期でリトライ)。
async fn flush(buffer: &mut VecDeque<String>, target: &Target, dropped_total: &mut u64) -> bool {
    while !buffer.is_empty() {
        let take = buffer.len().min(MAX_BATCH);
        let body = {
            let batch: Vec<&String> = buffer.iter().take(take).collect();
            build_body(&batch)
        };
        match post(target, &body).await {
            Ok(code) if (200..300).contains(&code) => {
                for _ in 0..take {
                    buffer.pop_front();
                }
            }
            // 4xx はバッチが不正 (spec 3.1 の 422 等)。再送しても解消しないため破棄し、
            // バッファの詰まりを防ぐ。
            Ok(code) if (400..500).contains(&code) => {
                eprintln!(
                    "logavo agent: server rejected batch of {} (HTTP {}); discarding",
                    take, code
                );
                for _ in 0..take {
                    buffer.pop_front();
                }
                *dropped_total += take as u64;
            }
            // 5xx / 予期しないコード / 接続エラーは一時障害とみなしリトライ。
            Ok(_) | Err(_) => {
                return false;
            }
        }
    }
    true
}

/// `{ "entries": [ <entry>, ... ] }` のリクエストボディを組み立てる。
/// 各 entry は正規化済みの JSON オブジェクト文字列 (spec 2.1)。
fn build_body(entries: &[&String]) -> String {
    let mut body = String::from("{\"entries\":[");
    for (i, entry) in entries.iter().enumerate() {
        if i > 0 {
            body.push(',');
        }
        body.push_str(entry.as_str());
    }
    body.push_str("]}");
    body
}

/// localhost 向けの最小 HTTP/1.1 POST。成功時はステータスコードを返す。
async fn post(target: &Target, body: &str) -> Result<u16, String> {
    let addr = format!("{}:{}", target.host, target.port);
    let exchange = async {
        let mut stream = TcpStream::connect(&addr).await.map_err(|e| e.to_string())?;
        let head = format!(
            "POST {path} HTTP/1.1\r\n\
             Host: {host}\r\n\
             Content-Type: application/json\r\n\
             Content-Length: {len}\r\n\
             Connection: close\r\n\
             \r\n",
            path = target.path,
            host = target.authority,
            len = body.len(),
        );
        stream.write_all(head.as_bytes()).await.map_err(|e| e.to_string())?;
        stream.write_all(body.as_bytes()).await.map_err(|e| e.to_string())?;
        stream.flush().await.map_err(|e| e.to_string())?;

        // Connection: close なので server はレスポンス後に切断する。EOF まで読む。
        let mut resp = Vec::new();
        stream.read_to_end(&mut resp).await.map_err(|e| e.to_string())?;
        parse_status(&resp)
    };

    match tokio::time::timeout(REQUEST_TIMEOUT, exchange).await {
        Ok(result) => result,
        Err(_) => Err("request timed out".to_string()),
    }
}

/// HTTP レスポンスのステータス行からステータスコードを取り出す。
fn parse_status(resp: &[u8]) -> Result<u16, String> {
    if resp.is_empty() {
        return Err("empty response".to_string());
    }
    let end = resp
        .iter()
        .position(|&b| b == b'\r' || b == b'\n')
        .unwrap_or(resp.len());
    let line = std::str::from_utf8(&resp[..end]).map_err(|_| "invalid status line".to_string())?;
    // 例: "HTTP/1.1 200 OK"
    let mut parts = line.split_whitespace();
    let _version = parts.next().ok_or_else(|| "malformed status line".to_string())?;
    let code = parts.next().ok_or_else(|| "missing status code".to_string())?;
    code.parse::<u16>().map_err(|_| "invalid status code".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_url_with_port_and_path() {
        let t = Target::parse("http://localhost:4000/api/ingest").unwrap();
        assert_eq!(t.host, "localhost");
        assert_eq!(t.port, 4000);
        assert_eq!(t.path, "/api/ingest");
        assert_eq!(t.authority, "localhost:4000");
    }

    #[test]
    fn parse_url_defaults_path_and_port() {
        let t = Target::parse("http://127.0.0.1").unwrap();
        assert_eq!(t.host, "127.0.0.1");
        assert_eq!(t.port, 80);
        assert_eq!(t.path, "/");
    }

    #[test]
    fn parse_url_rejects_non_http() {
        assert!(Target::parse("https://localhost:4000/api/ingest").is_err());
        assert!(Target::parse("localhost:4000").is_err());
    }

    #[test]
    fn parse_url_rejects_bad_port() {
        assert!(Target::parse("http://localhost:notaport/api").is_err());
    }

    #[test]
    fn build_body_wraps_entries() {
        let a = String::from("{\"raw\":\"a\"}");
        let b = String::from("{\"raw\":\"b\"}");
        let batch: Vec<&String> = vec![&a, &b];
        assert_eq!(
            build_body(&batch),
            "{\"entries\":[{\"raw\":\"a\"},{\"raw\":\"b\"}]}"
        );
    }

    #[test]
    fn build_body_empty() {
        let batch: Vec<&String> = Vec::new();
        assert_eq!(build_body(&batch), "{\"entries\":[]}");
    }

    #[test]
    fn push_bounded_drops_oldest_over_cap() {
        let mut buffer: VecDeque<String> = VecDeque::new();
        let mut dropped = 0u64;
        for i in 0..(MAX_BUFFER + 5) {
            push_bounded(&mut buffer, i.to_string(), &mut dropped);
        }
        assert_eq!(buffer.len(), MAX_BUFFER);
        assert_eq!(dropped, 5);
        // 最も古い 5 件 (0..5) が破棄され、先頭は "5" になっている。
        assert_eq!(buffer.front().map(String::as_str), Some("5"));
    }

    #[test]
    fn parse_status_reads_code() {
        assert_eq!(parse_status(b"HTTP/1.1 200 OK\r\n\r\n").unwrap(), 200);
        assert_eq!(parse_status(b"HTTP/1.1 422 Unprocessable Entity\r\n").unwrap(), 422);
        assert!(parse_status(b"").is_err());
    }
}
