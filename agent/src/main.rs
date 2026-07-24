// logavo agent エントリポイント (Phase 1)。
//
// 引数で渡された TOML 設定ファイル (省略時は ./logavo.toml) を読み込み、
// 内容の要約を表示する。設定の欠落・構文エラー時は非ゼロ終了する。
// tail / parse / ship / proxy は後続サブタスクで追加する。
//
// ASSUMPTION: 設定パスの既定値は spec の例に合わせ ./logavo.toml とする。

mod config;

use std::process;

use config::Config;

fn main() {
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
}
