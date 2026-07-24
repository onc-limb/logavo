// logavo agent エントリポイント (Phase 1 + Phase 4)。
//
// 引数で渡された TOML 設定ファイル (省略時は ./logavo.toml) を読み込み、
// 内容の要約を表示したうえで、各 source のファイルを tokio で並行に非同期 tail し、
// 検知した追記行を spec 2.1 の共通 JSON に正規化して server へバッチ送信する。
// 設定に `[proxy]` があれば HTTP リバースプロキシ (Phase 4) も起動し、経由する
// リクエストの method/path/status/latency_ms/req/res サイズを spec 2.2 形式で
// 記録して server の POST /api/proxy へ送る。
// 設定の欠落・構文エラー時は非ゼロ終了する。
// Ctrl-C を受けると全 tail タスクへ停止を通知し、join してから終了する。
//
// ASSUMPTION: 設定パスの既定値は spec の例に合わせ ./logavo.toml とする。

mod config;
mod parse;
mod proxy;
mod ship;
mod tail;

use std::process;
use std::time::SystemTime;

use config::Config;

#[tokio::main]
async fn main() {
    // ASSUMPTION: 第1引数を設定ファイルパスとして受け取る簡易 CLI。
    let path = std::env::args().nth(1).unwrap_or_else(|| "logavo.toml".to_string());

    let cfg = match Config::from_path(&path) {
        Ok(cfg) => cfg,
        Err(e) => {
            eprintln!("logavo agent: failed to load config from {}: {}", path, e);
            process::exit(1);
        }
    };

    println!("logavo agent");
    println!("server_url = {}", cfg.server_url);
    println!("{} source(s) configured:", cfg.sources.len());
    for s in &cfg.sources {
        println!("  - {} -> {}", s.name, s.path);
    }
    match &cfg.proxy {
        Some(p) => println!("proxy: {} -> {}", p.listen, p.upstream),
        None => println!("proxy: disabled"),
    }

    if cfg.sources.is_empty() {
        println!("no sources to tail; exiting");
        return;
    }

    // agent-tail: 各 source を tokio で並行に非同期 tail する。
    let (tailer, mut rx) = tail::spawn(&cfg.sources);

    // agent-ship: 正規化済みログを最大 100 件 or 1 秒でバッチ化し
    // server の POST /api/ingest へ送信する (server 不在時はバッファ再送)。
    let shipper = ship::Shipper::spawn(&cfg.server_url);

    // agent-proxy: [proxy] 設定があればリバースプロキシを起動する。計測ログは
    // agent-ship の送信経路を流用して server の POST /api/proxy へ送る。
    let proxy = cfg.proxy.as_ref().map(|p| {
        let proxy_url = derive_proxy_url(&cfg.server_url);
        println!(
            "proxy: {} -> {} (requests logged to {})",
            p.listen, p.upstream, proxy_url
        );
        proxy::Proxy::spawn(p, &proxy_url)
    });

    println!(
        "tailing {} source(s); append to a file or press Ctrl-C to stop",
        cfg.sources.len()
    );

    // 追記行の受信と Ctrl-C を待つ。Ctrl-C 受信、または全 tail タスク終了で
    // ループを抜け、tailer / shipper / proxy を正常停止してから終了する。
    loop {
        tokio::select! {
            maybe_line = rx.recv() => {
                match maybe_line {
                    Some(line) => {
                        // agent-parse: 1行を spec 2.1 の共通 JSON へ正規化する。
                        // timestamp がパース不能な場合は受信時刻を採用する。
                        let entry = parse::normalize(
                            &line.source,
                            &line.raw,
                            &line.path.display().to_string(),
                            line.line_no as u64,
                            SystemTime::now(),
                        );
                        // agent-ship の送信キューへ積む (バッチ化・再送はタスク側)。
                        shipper.send(entry.to_json());
                    }
                    // すべての tail タスクが終了しチャネルが閉じた。
                    None => break,
                }
            }
            _ = tokio::signal::ctrl_c() => {
                println!("\nreceived Ctrl-C; stopping tailers");
                break;
            }
        }
    }

    // 停止を通知し、全 tail タスクの終了を待つ。tail タスク終了後にチャネルへ
    // 残った行を回収してから送信を締めることで、停止時の取りこぼしを防ぐ。
    tailer.stop().await;
    while let Some(line) = rx.recv().await {
        let entry = parse::normalize(
            &line.source,
            &line.raw,
            &line.path.display().to_string(),
            line.line_no as u64,
            SystemTime::now(),
        );
        shipper.send(entry.to_json());
    }

    // プロキシを止め、計測ログを最終フラッシュする。
    if let Some(proxy) = proxy {
        proxy.stop().await;
    }

    // 送信キューを閉じ、バッファを最終フラッシュしてから終了する。
    shipper.stop().await;
}

/// ログ送信先 (`server_url`) から proxy 計測ログの送信先 (`POST /api/proxy`) を導く。
///
/// ASSUMPTION: server_url は spec の例 "http://localhost:4000/api/ingest"。
/// proxy ログは同じ server の POST /api/proxy へ送るため、末尾の `/api/ingest`
/// を `/api/proxy` に差し替える。想定外の形なら scheme://authority を取り出して
/// `/api/proxy` を付ける。
fn derive_proxy_url(server_url: &str) -> String {
    if let Some(base) = server_url.strip_suffix("/api/ingest") {
        return format!("{}/api/proxy", base);
    }
    let after_scheme = server_url.find("://").map(|i| i + 3).unwrap_or(0);
    let authority_end = server_url[after_scheme..]
        .find('/')
        .map(|i| after_scheme + i)
        .unwrap_or(server_url.len());
    format!("{}/api/proxy", &server_url[..authority_end])
}
