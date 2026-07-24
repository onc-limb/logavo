//! logavo agent — HTTP リバースプロキシ (Phase 4, agent-proxy)
//!
//! docs/spec.md 2.2 / Phase 4。設定 `[proxy]` の `listen`(例 :9000) で待ち受け、
//! `upstream`(例 :3000) へ素通しで転送する localhost 専用リバースプロキシ。
//! リクエストごとに method / path / status / latency_ms / req_size / res_size を
//! 計測し、spec 2.2 形式の JSON エントリに正規化して agent-ship の送信経路
//! (`ship::Shipper`) 経由で server の `POST /api/proxy` へ送る。
//!
//! 依存最小主義 (docs/spec.md 5.1): axum/hyper は中核依存だが、既存の
//! `ship.rs` が tokio の `TcpStream` 上に HTTP/1.1 を自作している方針に合わせ、
//! プロキシも新規 crate を足さず tokio net で自作する (学習題材/攻撃面・更新
//! 負担の抑制)。新規 crate は不要で、既存の tokio feature ("net"/"io-util"/
//! "sync") だけで実装する。
//!
//! ASSUMPTION: localhost の開発用途に絞り、以下は割り切る:
//!   - 転送は接続ごとに 1 リクエスト/1 レスポンス。上流・クライアントとも
//!     `Connection: close` として、レスポンスは EOF まで読み切る (keep-alive
//!     多重化はしない)。
//!   - リクエストボディ長は `Content-Length` を見る (chunked リクエストボディは
//!     未対応。TODO)。レスポンスは close 前提で全バイトを読み切る。

use std::io;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use crate::config::ProxyConfig;
use crate::ship::Shipper;

/// upstream レスポンス読み取りのタイムアウト。localhost 前提の割り切りだが、
/// upstream が `Connection: close` を無視して接続を保持し続けた場合に、
/// コネクションタスクが無期限にハングしないためのガード。
const FORWARD_READ_TIMEOUT: Duration = Duration::from_secs(30);

/// 起動中のリバースプロキシ。`stop().await` で待受を止め、計測ログの送信を
/// 最終フラッシュしてから終了する。
pub struct Proxy {
    accept_shutdown: Option<oneshot::Sender<()>>,
    forward_shutdown: Option<oneshot::Sender<()>>,
    accept_task: JoinHandle<()>,
    forward_task: JoinHandle<()>,
}

impl Proxy {
    /// `[proxy]` 設定でリバースプロキシを起動する。
    ///
    /// `proxy_url` は計測ログの送信先 (server の `POST /api/proxy`)。agent-ship の
    /// 送信経路をそのまま流用するため、専用の `Shipper` を 1 つ立ち上げ、
    /// 各コネクションはそこへ spec 2.2 形式の JSON を積むだけにする。
    pub fn spawn(cfg: &ProxyConfig, proxy_url: &str) -> Proxy {
        // コネクションタスク → 送信タスク へ計測ログを渡す経路。tx は各コネク
        // ションに clone して渡し、送信 (バッチ化・再送) は Shipper に委ねる。
        let (tx, rx) = mpsc::unbounded_channel::<String>();
        let (accept_sd_tx, accept_sd_rx) = oneshot::channel::<()>();
        let (fwd_sd_tx, fwd_sd_rx) = oneshot::channel::<()>();

        let shipper = Shipper::spawn(proxy_url);
        let forward_task = tokio::spawn(async move {
            let mut rx = rx;
            let mut fwd_rx = fwd_sd_rx;
            loop {
                tokio::select! {
                    _ = &mut fwd_rx => break,
                    msg = rx.recv() => match msg {
                        Some(json) => shipper.send(json),
                        None => break,
                    }
                }
            }
            // バッファを最終フラッシュしてから終了する。
            shipper.stop().await;
        });

        let listen = cfg.listen.clone();
        let upstream = cfg.upstream.clone();
        let accept_task = tokio::spawn(async move {
            run_accept_loop(listen, upstream, tx, accept_sd_rx).await;
        });

        Proxy {
            accept_shutdown: Some(accept_sd_tx),
            forward_shutdown: Some(fwd_sd_tx),
            accept_task,
            forward_task,
        }
    }

    /// 待受を止め、送信タスクを締めてから終了する。
    pub async fn stop(mut self) {
        if let Some(tx) = self.accept_shutdown.take() {
            let _ = tx.send(());
        }
        let _ = self.accept_task.await;

        // 待受停止後に送信タスクへ停止を通知する。以後、飛行中のコネクション
        // からの `tx.send` は Err になるだけで無害 (受信側が閉じている)。
        if let Some(tx) = self.forward_shutdown.take() {
            let _ = tx.send(());
        }
        let _ = self.forward_task.await;
    }
}

/// 待受ループ。停止通知を受けるまで accept し、各コネクションを非同期に捌く。
async fn run_accept_loop(
    listen: String,
    upstream: String,
    tx: UnboundedSender<String>,
    shutdown: oneshot::Receiver<()>,
) {
    let listener = match TcpListener::bind(&listen).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("logavo proxy: failed to bind {}: {}", listen, e);
            return;
        }
    };
    println!("proxy listening on {} -> {}", listen, upstream);

    let mut shutdown = shutdown;
    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => {
                match accepted {
                    Ok((client, _peer)) => {
                        let upstream = upstream.clone();
                        let tx = tx.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_conn(client, &upstream, &tx).await {
                                eprintln!("logavo proxy: connection error: {}", e);
                            }
                        });
                    }
                    Err(e) => eprintln!("logavo proxy: accept error: {}", e),
                }
            }
        }
    }
}

/// 1 コネクション = 1 リクエスト/レスポンスを転送し、計測ログを積む。
async fn handle_conn(
    mut client: TcpStream,
    upstream: &str,
    tx: &UnboundedSender<String>,
) -> io::Result<()> {
    // 受信時刻 (spec 2.1: timestamp はエージェント受信時刻でよい)。
    let received_at = SystemTime::now();
    let req = read_request(&mut client).await?;

    let started = Instant::now();
    match forward(upstream, &req.forward).await {
        Ok(res_bytes) => {
            let latency = started.elapsed();
            let status = parse_status(&res_bytes);
            client.write_all(&res_bytes).await?;
            let _ = client.shutdown().await;
            emit_log(
                tx,
                &req.method,
                &req.path,
                status,
                latency,
                req.req_body_size,
                body_size(&res_bytes),
                received_at,
            );
        }
        Err(e) => {
            // 上流に到達できない場合は 502 を返し、status=502 として記録する。
            let latency = started.elapsed();
            let body = b"502 Bad Gateway (upstream unreachable)";
            let mut out = format!(
                "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .into_bytes();
            out.extend_from_slice(body);
            let _ = client.write_all(&out).await;
            let _ = client.shutdown().await;
            emit_log(
                tx,
                &req.method,
                &req.path,
                502,
                latency,
                req.req_body_size,
                body.len(),
                received_at,
            );
            eprintln!("logavo proxy: upstream {} error: {}", upstream, e);
        }
    }
    Ok(())
}

/// クライアントから読み取ったリクエストと、上流へ転送するバイト列。
struct Request {
    method: String,
    path: String,
    /// 上流へ送るリクエスト全体 (`Connection: close` に整形済み)。
    forward: Vec<u8>,
    /// リクエストボディのサイズ (spec 2.2 の req_size)。
    req_body_size: usize,
}

/// クライアントから HTTP リクエストを読み取り、上流転送用に整形する。
async fn read_request(client: &mut TcpStream) -> io::Result<Request> {
    let (head, body) = read_http(client).await?;
    let head_text = String::from_utf8_lossy(&head);
    let request_line = head_text.split("\r\n").next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let path = parts.next().unwrap_or("").to_string();
    let forward = rebuild_with_close(&head, &body);
    Ok(Request {
        method,
        path,
        forward,
        req_body_size: body.len(),
    })
}

/// ヘッダ (末尾の `\r\n\r\n` を含む) とボディに分けて HTTP メッセージを読む。
/// ボディ長は `Content-Length` に従う (無ければ 0)。
async fn read_http(stream: &mut TcpStream) -> io::Result<(Vec<u8>, Vec<u8>)> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 8192];

    let header_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            if buf.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before request",
                ));
            }
            // ヘッダ終端が来ないまま EOF。ある分だけをヘッダとして扱う。
            break buf.len();
        }
        buf.extend_from_slice(&tmp[..n]);
    };

    let head = buf[..header_end].to_vec();
    let mut body = buf[header_end..].to_vec();
    let content_length = parse_content_length(&head);
    while body.len() < content_length {
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    Ok((head, body))
}

/// リクエストヘッダを `Connection: close` に整形し直して転送バイト列を作る。
fn rebuild_with_close(head: &[u8], body: &[u8]) -> Vec<u8> {
    let text = String::from_utf8_lossy(head);
    let mut lines: Vec<&str> = Vec::new();
    for line in text.split("\r\n") {
        if line.is_empty() {
            break; // ヘッダ終端に到達。
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("connection:") || lower.starts_with("proxy-connection:") {
            continue; // 既存の Connection 系ヘッダは落とす。
        }
        lines.push(line);
    }
    let mut rebuilt = lines.join("\r\n");
    rebuilt.push_str("\r\nConnection: close\r\n\r\n");
    let mut bytes = rebuilt.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

/// 上流へ接続してリクエストを送り、レスポンスを EOF まで読み切って返す。
async fn forward(upstream: &str, req: &[u8]) -> io::Result<Vec<u8>> {
    let mut up = TcpStream::connect(upstream).await?;
    up.write_all(req).await?;
    up.flush().await?;
    // 書き込み側を閉じてリクエスト完了を通知する (レスポンスは読み続ける)。
    let _ = up.shutdown().await;
    let mut res = Vec::new();
    // upstream が `Connection: close` を無視して接続を保持し続けても、
    // コネクションタスクが無期限にハングしないよう読み取りにタイムアウトの
    // ガードを設ける。タイムアウト時はそこまでに読めた分を返す (localhost 前提)。
    match tokio::time::timeout(FORWARD_READ_TIMEOUT, up.read_to_end(&mut res)).await {
        Ok(result) => {
            result?;
        }
        Err(_) => {
            eprintln!(
                "logavo proxy: upstream {} read timed out after {}s; returning partial response",
                upstream,
                FORWARD_READ_TIMEOUT.as_secs()
            );
        }
    }
    Ok(res)
}

/// レスポンス先頭行からステータスコードを取り出す (失敗時 0)。
fn parse_status(res: &[u8]) -> u16 {
    let head = &res[..res.len().min(64)];
    let text = String::from_utf8_lossy(head);
    text.split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// レスポンス全体からボディサイズ (spec 2.2 の res_size) を求める。
fn body_size(response: &[u8]) -> usize {
    match find(response, b"\r\n\r\n") {
        Some(pos) => response.len().saturating_sub(pos + 4),
        None => 0,
    }
}

/// `Content-Length` ヘッダ値を読む (無ければ 0)。
fn parse_content_length(head: &[u8]) -> usize {
    let text = String::from_utf8_lossy(head);
    for line in text.split("\r\n") {
        let lower = line.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("content-length:") {
            if let Ok(n) = rest.trim().parse::<usize>() {
                return n;
            }
        }
    }
    0
}

/// `needle` が最初に現れる位置を返す。
fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// 計測結果を spec 2.2 形式の JSON エントリにして送信キューへ積む。
#[allow(clippy::too_many_arguments)]
fn emit_log(
    tx: &UnboundedSender<String>,
    method: &str,
    path: &str,
    status: u16,
    latency: Duration,
    req_size: usize,
    res_size: usize,
    when: SystemTime,
) {
    let latency_ms = latency.as_millis() as u64;
    // ステータスから level を推定する (spec 2.1 の enum に丸める)。
    let level = if status >= 500 || status == 0 {
        "error"
    } else if status >= 400 {
        "warn"
    } else {
        "info"
    };
    let message = format!("{} {} {}", method, path, status);
    let raw = format!("{} {} {} {}ms", method, path, status, latency_ms);
    let timestamp = iso8601_utc(when);

    // spec 2.2: 消費側 (server の /api/proxy → proxy_requests 列、および
    // ダッシュボードの normalize_proxy / proxy_entry?) は method / path / status /
    // latency_ms / req_size / res_size を平坦なトップレベルフィールドとして読む。
    // そのため spec 2.1 のログ封筒 (timestamp/source/level/message/raw) に対して
    // 計測フィールドを meta 配下へネストせず、同じトップレベルへ併記する。
    let json = format!(
        concat!(
            "{{",
            "\"timestamp\":\"{ts}\",",
            "\"source\":\"proxy\",",
            "\"level\":\"{lvl}\",",
            "\"message\":\"{msg}\",",
            "\"raw\":\"{raw}\",",
            "\"method\":\"{method}\",",
            "\"path\":\"{path}\",",
            "\"status\":{status},",
            "\"latency_ms\":{lat},",
            "\"req_size\":{req},",
            "\"res_size\":{res}",
            "}}"
        ),
        ts = esc(&timestamp),
        lvl = level,
        msg = esc(&message),
        raw = esc(&raw),
        method = esc(method),
        path = esc(path),
        status = status,
        lat = latency_ms,
        req = req_size,
        res = res_size,
    );

    // 送信タスクが閉じている場合 (停止処理中) は破棄する。
    let _ = tx.send(json);
}

/// JSON 文字列値としてエスケープする。
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// `SystemTime` を ISO8601 (UTC, ミリ秒付き) 文字列にする。
///
/// ASSUMPTION: 依存最小主義に従い chrono 等を足さず、std だけで epoch 秒から
/// 年月日を求める (Howard Hinnant の civil_from_days アルゴリズム)。
fn iso8601_utc(t: SystemTime) -> String {
    let dur = t.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = dur.as_secs() as i64;
    let millis = dur.subsec_millis();
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, mo, d) = civil_from_days(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y, mo, d, h, m, s, millis
    )
}

/// 1970-01-01 からの経過日数を (年, 月, 日) に変換する。
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}
