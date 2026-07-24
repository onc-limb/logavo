// logavo agent エントリポイント (Phase 1)。
//
// 引数で渡された TOML 設定ファイル (省略時は ./logavo.toml) を読み込み、
// 内容の要約を表示したうえで、各 source のファイルを tokio で並行に非同期 tail し、
// 検知した追記行を表示する。設定の欠落・構文エラー時は非ゼロ終了する。
// Ctrl-C を受けると全 tail タスクへ停止を通知し、join してから終了する。
// parse / ship / proxy は後続サブタスクで追加する。
//
// ASSUMPTION: 設定パスの既定値は spec の例に合わせ ./logavo.toml とする。

mod config;
mod tail;

use std::process;

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

    // agent-tail: 各 source を tokio で並行に非同期 tail する。parse / ship は後続
    // サブタスクで追加するため、ここでは検知した追記行を標準出力へ表示するにとどめる。
    let (tailer, mut rx) = tail::spawn(&cfg.sources);
    println!(
        "tailing {} source(s); append to a file or press Ctrl-C to stop",
        cfg.sources.len()
    );

    // 追記行の受信と Ctrl-C を待つ。Ctrl-C 受信、または全 tail タスク終了で
    // ループを抜け、tailer を正常停止 (停止通知 + join) してから終了する。
    loop {
        tokio::select! {
            maybe_line = rx.recv() => {
                match maybe_line {
                    Some(line) => {
                        println!(
                            "[{}] {}:{} {}",
                            line.source,
                            line.path.display(),
                            line.line_no,
                            line.raw
                        );
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

    // 停止を通知し、全 tail タスクの終了を待って正常終了する。
    tailer.stop().await;
}
