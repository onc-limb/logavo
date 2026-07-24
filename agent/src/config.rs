//! logavo agent — 設定読込 (Phase 1)
//!
//! TOML 設定ファイルから以下を読み込む:
//!   - `server_url`: 送信先 server の ingest エンドポイント
//!   - `[[sources]]`: 監視対象ログ (name / path)
//!   - `[proxy]` (任意): 将来 agent-proxy が使うリバースプロキシ設定
//!     (listen 待受アドレス → upstream 転送先, 例 :9000 → :3000)
//!
//! ASSUMPTION: docs/spec.md 5.1「依存最小主義」と本サブタスクの受け入れ条件
//! "no new deps" に従い、`toml`/`serde` クレートを足さず std のみで、この設定
//! フォーマットに必要な TOML のサブセット (二重引用符文字列 / `[[sources]]`
//! 配列テーブル / `[proxy]` テーブル / `#` コメント) だけを自作パースする。
//! ネストテーブルや配列・数値・真偽値などフルの TOML 文法は対象外。

use std::fmt;
use std::fs;
use std::path::Path;

/// 監視対象ログ 1 件分。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub name: String,
    pub path: String,
}

/// リバースプロキシ設定 (Phase 4 agent-proxy 用、Phase 1 では読み込むのみ)。
///
/// ASSUMPTION: `listen`/`upstream` は spec の例 (:9000 → :3000) に沿って
/// `host:port` 形式の文字列とする。対象は localhost のみ (issue #4)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyConfig {
    pub listen: String,
    pub upstream: String,
}

/// エージェント設定全体。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub server_url: String,
    pub sources: Vec<Source>,
    pub proxy: Option<ProxyConfig>,
}

/// 設定読込時のエラー。いずれも main 側で非ゼロ終了に用いる。
#[derive(Debug)]
pub enum ConfigError {
    /// ファイル読込失敗。
    Io(std::io::Error),
    /// TOML 構文エラー。
    Parse(String),
    /// 必須項目の欠落。
    Missing(String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::Io(e) => write!(f, "I/O error: {}", e),
            ConfigError::Parse(msg) => write!(f, "syntax error: {}", msg),
            ConfigError::Missing(msg) => write!(f, "missing required field: {}", msg),
        }
    }
}

impl std::error::Error for ConfigError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ConfigError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl Config {
    /// 指定パスの TOML を読み込んで設定を返す。
    pub fn from_path<P: AsRef<Path>>(path: P) -> Result<Config, ConfigError> {
        let content = fs::read_to_string(path).map_err(ConfigError::Io)?;
        Config::from_toml(&content)
    }

    /// TOML 文字列から設定をパースする。
    pub fn from_toml(content: &str) -> Result<Config, ConfigError> {
        parse(content)
    }
}

/// パース中に注目している「セクション」。
enum Section {
    Top,
    /// `sources` 配列内の pending 要素インデックス。
    Source(usize),
    Proxy,
}

/// name/path が揃うまで保持する途中状態の source。
struct PendingSource {
    name: Option<String>,
    path: Option<String>,
}

fn parse(content: &str) -> Result<Config, ConfigError> {
    let mut server_url: Option<String> = None;
    let mut sources: Vec<PendingSource> = Vec::new();
    let mut proxy_listen: Option<String> = None;
    let mut proxy_upstream: Option<String> = None;
    let mut has_proxy = false;
    let mut section = Section::Top;

    for (i, raw_line) in content.lines().enumerate() {
        let line_no = i + 1;
        let line = strip_comment(raw_line).trim();
        if line.is_empty() {
            continue;
        }

        // テーブル/配列テーブルのヘッダ。
        if line.starts_with('[') {
            match line {
                "[[sources]]" => {
                    sources.push(PendingSource {
                        name: None,
                        path: None,
                    });
                    section = Section::Source(sources.len() - 1);
                }
                "[proxy]" => {
                    has_proxy = true;
                    section = Section::Proxy;
                }
                other => {
                    return Err(ConfigError::Parse(format!(
                        "line {}: unknown or malformed table header: {}",
                        line_no, other
                    )));
                }
            }
            continue;
        }

        // `key = "value"` 形式。
        let (key, value) = parse_kv(line, line_no)?;
        match section {
            Section::Top => match key {
                "server_url" => server_url = Some(value),
                other => {
                    return Err(ConfigError::Parse(format!(
                        "line {}: unknown top-level key: {}",
                        line_no, other
                    )));
                }
            },
            Section::Source(idx) => match key {
                "name" => sources[idx].name = Some(value),
                "path" => sources[idx].path = Some(value),
                other => {
                    return Err(ConfigError::Parse(format!(
                        "line {}: unknown key in [[sources]]: {}",
                        line_no, other
                    )));
                }
            },
            Section::Proxy => match key {
                "listen" => proxy_listen = Some(value),
                "upstream" => proxy_upstream = Some(value),
                other => {
                    return Err(ConfigError::Parse(format!(
                        "line {}: unknown key in [proxy]: {}",
                        line_no, other
                    )));
                }
            },
        }
    }

    // 必須項目の検証。
    let server_url = server_url
        .ok_or_else(|| ConfigError::Missing("server_url".to_string()))?;

    let mut resolved_sources = Vec::with_capacity(sources.len());
    for (idx, s) in sources.into_iter().enumerate() {
        let name = s
            .name
            .ok_or_else(|| ConfigError::Missing(format!("sources[{}].name", idx)))?;
        let path = s
            .path
            .ok_or_else(|| ConfigError::Missing(format!("sources[{}].path", idx)))?;
        resolved_sources.push(Source { name, path });
    }

    // ASSUMPTION: 監視対象が 1 件も無い設定は運用上意味を成さないため、
    // 少なくとも 1 つの [[sources]] を必須とする。
    if resolved_sources.is_empty() {
        return Err(ConfigError::Missing(
            "at least one [[sources]] entry".to_string(),
        ));
    }

    let proxy = if has_proxy {
        let listen = proxy_listen
            .ok_or_else(|| ConfigError::Missing("proxy.listen".to_string()))?;
        let upstream = proxy_upstream
            .ok_or_else(|| ConfigError::Missing("proxy.upstream".to_string()))?;
        Some(ProxyConfig { listen, upstream })
    } else {
        None
    };

    Ok(Config {
        server_url,
        sources: resolved_sources,
        proxy,
    })
}

/// 文字列リテラルの外にある `#` 以降をコメントとして落とす。
///
/// ASSUMPTION: 文字列内のエスケープされた引用符 (`\"`) は考慮しない簡易実装。
/// この設定フォーマットの値 (URL / パス / host:port) では実害がない。
fn strip_comment(line: &str) -> &str {
    let mut in_str = false;
    for (idx, ch) in line.char_indices() {
        match ch {
            '"' => in_str = !in_str,
            '#' if !in_str => return &line[..idx],
            _ => {}
        }
    }
    line
}

/// `key = value` を分解する。value は二重引用符文字列のみ許容。
fn parse_kv(line: &str, line_no: usize) -> Result<(&str, String), ConfigError> {
    let eq = line.find('=').ok_or_else(|| {
        ConfigError::Parse(format!(
            "line {}: expected 'key = value', found: {}",
            line_no, line
        ))
    })?;
    let key = line[..eq].trim();
    let raw_val = line[eq + 1..].trim();
    if key.is_empty() {
        return Err(ConfigError::Parse(format!(
            "line {}: empty key",
            line_no
        )));
    }
    let value = parse_string_value(raw_val, line_no)?;
    Ok((key, value))
}

/// `"..."` 形式の文字列をアンエスケープして返す。
fn parse_string_value(raw: &str, line_no: usize) -> Result<String, ConfigError> {
    let bytes = raw.as_bytes();
    if bytes.len() < 2 || bytes[0] != b'"' || bytes[bytes.len() - 1] != b'"' {
        return Err(ConfigError::Parse(format!(
            "line {}: expected a double-quoted string value, found: {}",
            line_no, raw
        )));
    }
    let inner = &raw[1..raw.len() - 1];
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(other) => {
                    return Err(ConfigError::Parse(format!(
                        "line {}: invalid escape sequence: \\{}",
                        line_no, other
                    )));
                }
                None => {
                    return Err(ConfigError::Parse(format!(
                        "line {}: dangling escape at end of string",
                        line_no
                    )));
                }
            },
            '"' => {
                return Err(ConfigError::Parse(format!(
                    "line {}: unexpected unescaped quote inside string",
                    line_no
                )));
            }
            _ => out.push(c),
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_full_config_with_proxy() {
        let toml = r#"
            # logavo agent config
            server_url = "http://localhost:4000/api/ingest"

            [[sources]]
            name = "backend-api"
            path = "/var/log/app.log"

            [[sources]]
            name = "frontend"   # inline comment
            path = "/var/log/web.log"

            [proxy]
            listen = "127.0.0.1:9000"
            upstream = "127.0.0.1:3000"
        "#;

        let cfg = Config::from_toml(toml).expect("should parse");
        assert_eq!(cfg.server_url, "http://localhost:4000/api/ingest");
        assert_eq!(
            cfg.sources,
            vec![
                Source {
                    name: "backend-api".to_string(),
                    path: "/var/log/app.log".to_string(),
                },
                Source {
                    name: "frontend".to_string(),
                    path: "/var/log/web.log".to_string(),
                },
            ]
        );
        assert_eq!(
            cfg.proxy,
            Some(ProxyConfig {
                listen: "127.0.0.1:9000".to_string(),
                upstream: "127.0.0.1:3000".to_string(),
            })
        );
    }

    #[test]
    fn proxy_is_optional() {
        let toml = r#"
            server_url = "http://localhost:4000/api/ingest"

            [[sources]]
            name = "app"
            path = "/tmp/app.log"
        "#;

        let cfg = Config::from_toml(toml).expect("should parse");
        assert_eq!(cfg.sources.len(), 1);
        assert_eq!(cfg.proxy, None);
    }

    #[test]
    fn missing_server_url_is_error() {
        let toml = r#"
            [[sources]]
            name = "app"
            path = "/tmp/app.log"
        "#;

        match Config::from_toml(toml) {
            Err(ConfigError::Missing(field)) => assert!(field.contains("server_url")),
            other => panic!("expected Missing(server_url), got {:?}", other),
        }
    }

    #[test]
    fn missing_source_path_is_error() {
        let toml = r#"
            server_url = "http://localhost:4000/api/ingest"

            [[sources]]
            name = "app"
        "#;

        match Config::from_toml(toml) {
            Err(ConfigError::Missing(field)) => assert!(field.contains("path")),
            other => panic!("expected Missing(path), got {:?}", other),
        }
    }

    #[test]
    fn no_sources_is_error() {
        let toml = r#"server_url = "http://localhost:4000/api/ingest""#;
        match Config::from_toml(toml) {
            Err(ConfigError::Missing(field)) => assert!(field.contains("sources")),
            other => panic!("expected Missing(sources), got {:?}", other),
        }
    }

    #[test]
    fn missing_proxy_field_is_error() {
        let toml = r#"
            server_url = "http://localhost:4000/api/ingest"

            [[sources]]
            name = "app"
            path = "/tmp/app.log"

            [proxy]
            listen = "127.0.0.1:9000"
        "#;

        match Config::from_toml(toml) {
            Err(ConfigError::Missing(field)) => assert!(field.contains("upstream")),
            other => panic!("expected Missing(proxy.upstream), got {:?}", other),
        }
    }

    #[test]
    fn syntax_error_missing_equals() {
        let toml = r#"
            server_url "http://localhost:4000/api/ingest"

            [[sources]]
            name = "app"
            path = "/tmp/app.log"
        "#;

        match Config::from_toml(toml) {
            Err(ConfigError::Parse(_)) => {}
            other => panic!("expected Parse error, got {:?}", other),
        }
    }

    #[test]
    fn syntax_error_unquoted_value() {
        let toml = r#"
            server_url = http://localhost:4000/api/ingest

            [[sources]]
            name = "app"
            path = "/tmp/app.log"
        "#;

        match Config::from_toml(toml) {
            Err(ConfigError::Parse(_)) => {}
            other => panic!("expected Parse error, got {:?}", other),
        }
    }

    #[test]
    fn syntax_error_unknown_table() {
        let toml = r#"
            server_url = "http://localhost:4000/api/ingest"

            [nope]
            foo = "bar"
        "#;

        match Config::from_toml(toml) {
            Err(ConfigError::Parse(msg)) => assert!(msg.contains("table header")),
            other => panic!("expected Parse error, got {:?}", other),
        }
    }

    #[test]
    fn syntax_error_unknown_key() {
        let toml = r#"
            server_url = "http://localhost:4000/api/ingest"
            bogus = "x"

            [[sources]]
            name = "app"
            path = "/tmp/app.log"
        "#;

        match Config::from_toml(toml) {
            Err(ConfigError::Parse(msg)) => assert!(msg.contains("unknown top-level key")),
            other => panic!("expected Parse error, got {:?}", other),
        }
    }

    #[test]
    fn handles_escapes_in_strings() {
        let toml = r#"
            server_url = "http://localhost:4000/api/ingest"

            [[sources]]
            name = "quoted \"app\""
            path = "/tmp/tab\tsep.log"
        "#;

        let cfg = Config::from_toml(toml).expect("should parse");
        assert_eq!(cfg.sources[0].name, "quoted \"app\"");
        assert_eq!(cfg.sources[0].path, "/tmp/tab\tsep.log");
    }

    #[test]
    fn hash_inside_string_is_not_a_comment() {
        let toml = r#"
            server_url = "http://localhost:4000/api/ingest#frag"

            [[sources]]
            name = "app"
            path = "/tmp/app.log"
        "#;

        let cfg = Config::from_toml(toml).expect("should parse");
        assert_eq!(cfg.server_url, "http://localhost:4000/api/ingest#frag");
    }
}
