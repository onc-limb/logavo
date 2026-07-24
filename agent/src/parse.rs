//! ログ1行を docs/spec.md 2.1 の共通 JSON フォーマットに正規化する (agent-parse)。
//!
//! tail で得た1行 (raw) を受け取り、以下を行う:
//!   - level を推定する (推定失敗時は `unknown`)。
//!   - 行頭のタイムスタンプを ISO8601 へ正規化する (パース不能時は受信時刻)。
//!   - 元テキスト `raw` は必ずそのまま保持する。
//!   - source / file / line_no を meta に載せて spec 2.1 の JSON へ変換する。
//!
//! ASSUMPTION: docs/spec.md 5.1「依存最小主義／原則自作」に従い、level 推定・
//! timestamp 正規化・JSON 直列化はいずれも std のみで自作した (regex/serde_json 等の
//! 追加クレートは足していない)。中核依存 (tokio/axum/serde/regex) 以外を増やさないため
//! であり、level 推定は行を英字トークンへ分割して既知レベル語と照合する軽量実装で
//! 妥当なコストで足りる。将来パターンが複雑化した場合に限り regex クレート
//! (中核依存) の導入を検討する。

use std::fmt::Write as _;
use std::time::{SystemTime, UNIX_EPOCH};

/// ログレベル (spec 2.1: debug / info / warn / error / unknown)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
    Unknown,
}

impl Level {
    /// spec の enum 値としての文字列表現。
    pub fn as_str(&self) -> &'static str {
        match self {
            Level::Debug => "debug",
            Level::Info => "info",
            Level::Warn => "warn",
            Level::Error => "error",
            Level::Unknown => "unknown",
        }
    }
}

/// 追加情報 (spec 2.1 meta)。ここではファイルパスと行番号のみ。
#[derive(Debug, Clone)]
pub struct Meta {
    pub file: String,
    pub line_no: u64,
}

/// 正規化済みログエントリ (spec 2.1)。
#[derive(Debug, Clone)]
pub struct LogEntry {
    pub timestamp: String,
    pub source: String,
    pub level: Level,
    pub message: String,
    pub raw: String,
    pub meta: Meta,
}

impl LogEntry {
    /// spec 2.1 の JSON 文字列へ直列化する。
    ///
    /// serde_json を足さず自作するため、文字列は最小限のエスケープを施す。
    pub fn to_json(&self) -> String {
        let mut s = String::new();
        s.push_str("{\"timestamp\":\"");
        json_escape(&self.timestamp, &mut s);
        s.push_str("\",\"source\":\"");
        json_escape(&self.source, &mut s);
        s.push_str("\",\"level\":\"");
        s.push_str(self.level.as_str());
        s.push_str("\",\"message\":\"");
        json_escape(&self.message, &mut s);
        s.push_str("\",\"raw\":\"");
        json_escape(&self.raw, &mut s);
        s.push_str("\",\"meta\":{\"file\":\"");
        json_escape(&self.meta.file, &mut s);
        // `{}` が line_no、末尾 `}}}}` は meta とルートを閉じる2つの `}`。
        let _ = write!(s, "\",\"line_no\":{}}}}}", self.meta.line_no);
        s
    }
}

/// tail で得た1行を spec 2.1 の `LogEntry` へ正規化する。
///
/// - `raw` は元テキストをそのまま保持する (trim もしない)。
/// - 行頭にタイムスタンプが見つかればそれを ISO8601 に正規化し、
///   見つからない/不正なら `received` (受信時刻) を採用する。
/// - level は行から推定し、失敗時は `Level::Unknown`。
pub fn normalize(
    source: &str,
    raw: &str,
    file: &str,
    line_no: u64,
    received: SystemTime,
) -> LogEntry {
    // 解析はトリム済みテキストに対して行う (raw 自体は保持する)。
    let trimmed = raw.trim();

    let (timestamp, ts_len) = match parse_timestamp(trimmed) {
        Some((ts, len)) => (ts, len),
        None => (format_iso8601(received), 0),
    };

    let level = detect_level(trimmed);
    let message = extract_message(trimmed, ts_len);

    LogEntry {
        timestamp,
        source: source.to_string(),
        level,
        message,
        raw: raw.to_string(),
        meta: Meta {
            file: file.to_string(),
            line_no,
        },
    }
}

/// 行を英字トークンに分割し、最初に一致した既知レベル語からレベルを推定する。
/// 一致がなければ `Level::Unknown`。
fn detect_level(raw: &str) -> Level {
    for tok in raw.split(|c: char| !c.is_ascii_alphabetic()) {
        if let Some(level) = level_of_word(tok) {
            return level;
        }
    }
    Level::Unknown
}

/// 1つの単語がレベル語であればそのレベルを返す (大文字小文字は無視)。
fn level_of_word(word: &str) -> Option<Level> {
    match word.to_ascii_lowercase().as_str() {
        "error" | "err" | "fatal" | "critical" | "crit" | "panic" => Some(Level::Error),
        "warn" | "warning" => Some(Level::Warn),
        "info" | "information" | "notice" => Some(Level::Info),
        "debug" | "trace" | "verbose" => Some(Level::Debug),
        _ => None,
    }
}

fn is_level_word(word: &str) -> bool {
    level_of_word(word).is_some()
}

/// タイムスタンプとレベルの前置きを取り除いた本文を抽出する。
/// 取り除いた結果が空になる場合は、行全体をメッセージとして扱う。
fn extract_message(trimmed: &str, ts_len: usize) -> String {
    let after_ts = trimmed[ts_len..].trim_start();
    let after_level = strip_level_prefix(after_ts);
    let msg = after_level.trim();
    if msg.is_empty() {
        trimmed.to_string()
    } else {
        msg.to_string()
    }
}

/// 行頭の `[LEVEL]` や `LEVEL:` / `LEVEL -` のようなレベル表記を取り除く。
fn strip_level_prefix(s: &str) -> &str {
    // `[LEVEL]` 形式。
    if let Some(rest) = s.strip_prefix('[') {
        if let Some(idx) = rest.find(']') {
            if is_level_word(&rest[..idx]) {
                return rest[idx + 1..].trim_start();
            }
        }
    }

    // `LEVEL` / `LEVEL:` / `LEVEL -` 形式 (行頭トークンがレベル語のとき)。
    let end = s.find(|c: char| !c.is_ascii_alphabetic()).unwrap_or(s.len());
    if end > 0 && is_level_word(&s[..end]) {
        let rest = s[end..]
            .trim_start()
            .trim_start_matches(|c| c == ':' || c == '-' || c == '|');
        return rest.trim_start();
    }

    s
}

/// 行頭のタイムスタンプを検出し、`(正規化済み ISO8601, 消費したバイト数)` を返す。
///
/// 対応形式 (いずれも `YYYY-MM-DD` の後に日時):
///   - `YYYY-MM-DDTHH:MM:SS`（`T` 区切り）
///   - `YYYY-MM-DD HH:MM:SS`（空白区切り）
/// いずれも任意で小数秒 (`.sss`) とタイムゾーン (`Z` または `+09:00` / `+0900`)。
/// タイムゾーン省略時は UTC とみなして `Z` を付与する。
/// 構造・範囲が不正なら `None` (呼び出し側が受信時刻へフォールバック)。
fn parse_timestamp(s: &str) -> Option<(String, usize)> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let digit = |i: usize| b[i].is_ascii_digit();

    // YYYY-MM-DD
    if !(digit(0) && digit(1) && digit(2) && digit(3)) {
        return None;
    }
    if b[4] != b'-' || !(digit(5) && digit(6)) {
        return None;
    }
    if b[7] != b'-' || !(digit(8) && digit(9)) {
        return None;
    }
    // 区切り ('T' または空白)
    if b[10] != b' ' && b[10] != b'T' {
        return None;
    }
    // HH:MM:SS
    if !(digit(11) && digit(12)) || b[13] != b':' {
        return None;
    }
    if !(digit(14) && digit(15)) || b[16] != b':' {
        return None;
    }
    if !(digit(17) && digit(18)) {
        return None;
    }

    // 値域チェック (明らかに不正な日時はフォールバックさせる)。
    let two = |i: usize| (b[i] - b'0') * 10 + (b[i + 1] - b'0');
    let month = two(5);
    let day = two(8);
    let hour = two(11);
    let min = two(14);
    let sec = two(17);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if hour > 23 || min > 59 || sec > 60 {
        return None;
    }

    let mut i = 19;

    // 小数秒 (`.` の直後に1桁以上の数字があるときのみ)。
    if i < b.len() && b[i] == b'.' {
        let mut j = i + 1;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        if j > i + 1 {
            i = j;
        }
    }

    // タイムゾーン (`Z` / `+HH:MM` / `+HHMM`)。
    let mut had_tz = false;
    if i < b.len() {
        let rest = &b[i..];
        match rest[0] {
            b'Z' | b'z' => {
                i += 1;
                had_tz = true;
            }
            b'+' | b'-' => {
                if rest.len() >= 3 && rest[1].is_ascii_digit() && rest[2].is_ascii_digit() {
                    let mut off = 3;
                    if rest.len() > off && rest[off] == b':' {
                        off += 1;
                    }
                    if rest.len() >= off + 2
                        && rest[off].is_ascii_digit()
                        && rest[off + 1].is_ascii_digit()
                    {
                        i += off + 2;
                        had_tz = true;
                    }
                }
            }
            _ => {}
        }
    }

    // 消費部分を ISO8601 に正規化する (ASCII のみなのでバイト操作で安全)。
    let mut norm = s[..i].to_string();
    if norm.as_bytes()[10] == b' ' {
        norm.replace_range(10..11, "T");
    }
    if !had_tz {
        norm.push('Z');
    }

    Some((norm, i))
}

/// `SystemTime` を `YYYY-MM-DDTHH:MM:SS.mmmZ` (UTC) へ整形する。
fn format_iso8601(t: SystemTime) -> String {
    let dur = t.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = dur.as_secs() as i64;
    let millis = dur.subsec_millis();
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    let sod = secs.rem_euclid(86_400);
    let (hh, mm, ss) = (sod / 3600, (sod % 3600) / 60, sod % 60);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y, m, d, hh, mm, ss, millis
    )
}

/// エポック (1970-01-01) からの日数を (年, 月, 日) へ変換する。
/// Howard Hinnant の days_from_civil の逆算 (civil_from_days) アルゴリズム。
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

/// JSON 文字列値としての最小限のエスケープを施して `out` へ書き出す。
fn json_escape(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn at(secs: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(secs)
    }

    // --- level 推定 ---------------------------------------------------------

    #[test]
    fn detects_level_from_bracket() {
        let e = normalize(
            "backend-api",
            "2026-07-09 12:34:56 [ERROR] connection refused",
            "/var/log/app.log",
            10,
            at(0),
        );
        assert_eq!(e.level, Level::Error);
        assert_eq!(e.level.as_str(), "error");
        assert_eq!(e.message, "connection refused");
    }

    #[test]
    fn detects_level_variants() {
        assert_eq!(detect_level("WARN retrying"), Level::Warn);
        assert_eq!(detect_level("a warning appeared"), Level::Warn);
        assert_eq!(detect_level("[debug] cache hit"), Level::Debug);
        assert_eq!(detect_level("INFO server started"), Level::Info);
        assert_eq!(detect_level("FATAL out of memory"), Level::Error);
    }

    #[test]
    fn level_unknown_when_absent() {
        let e = normalize("app", "connection refused", "/f", 1, at(0));
        assert_eq!(e.level, Level::Unknown);
        assert_eq!(e.level.as_str(), "unknown");
    }

    #[test]
    fn timestamp_letter_t_is_not_a_level() {
        // ISO8601 の 'T' を level 語と誤検出しないこと。
        let e = normalize("app", "2026-07-09T12:34:56Z all good", "/f", 1, at(0));
        assert_eq!(e.level, Level::Unknown);
    }

    // --- timestamp フォールバック ------------------------------------------

    #[test]
    fn timestamp_fallback_when_missing() {
        let e = normalize("app", "no timestamp here", "/f", 1, at(0));
        assert_eq!(e.timestamp, "1970-01-01T00:00:00.000Z");
    }

    #[test]
    fn timestamp_fallback_when_invalid() {
        // 月13・時99 など範囲外はパース不能扱い → 受信時刻を採用。
        let e = normalize("app", "2026-13-40 99:99:99 broken", "/f", 1, at(1000));
        assert_eq!(e.timestamp, "1970-01-01T00:16:40.000Z");
    }

    #[test]
    fn parses_space_separated_timestamp() {
        let e = normalize("app", "2026-07-09 12:34:56 [ERROR] boom", "/f", 1, at(0));
        assert_eq!(e.timestamp, "2026-07-09T12:34:56Z");
    }

    #[test]
    fn parses_iso8601_with_millis_and_z() {
        let (ts, _) = parse_timestamp("2026-07-09T12:34:56.789Z rest").unwrap();
        assert_eq!(ts, "2026-07-09T12:34:56.789Z");
    }

    #[test]
    fn parses_offset_timezone() {
        let (ts, _) = parse_timestamp("2026-07-09T12:34:56+09:00 x").unwrap();
        assert_eq!(ts, "2026-07-09T12:34:56+09:00");
    }

    #[test]
    fn format_iso8601_known_dates() {
        assert_eq!(format_iso8601(at(0)), "1970-01-01T00:00:00.000Z");
        // 2021-01-01T00:00:00Z = 1609459200 秒。
        assert_eq!(format_iso8601(at(1_609_459_200)), "2021-01-01T00:00:00.000Z");
    }

    // --- raw 保持 -----------------------------------------------------------

    #[test]
    fn raw_is_always_preserved_verbatim() {
        let original = "  weird\tunparseable line  ";
        let e = normalize("app", original, "/f", 1, at(0));
        // trim せず元テキストをそのまま保持する。
        assert_eq!(e.raw, original);
    }

    #[test]
    fn raw_preserved_even_when_message_is_stripped() {
        let raw = "2026-07-09 12:34:56 [ERROR] connection refused";
        let e = normalize("app", raw, "/f", 1, at(0));
        assert_eq!(e.raw, raw);
        assert_ne!(e.message, raw); // message は整形されるが raw は不変
    }

    // --- JSON 直列化 --------------------------------------------------------

    #[test]
    fn json_contains_all_fields_and_escapes() {
        let e = normalize(
            "backend-api",
            "2026-07-09 12:34:56 [ERROR] boom \"quoted\"",
            "/var/log/app.log",
            1024,
            at(0),
        );
        let json = e.to_json();
        assert!(json.starts_with('{') && json.ends_with('}'));
        assert!(json.contains("\"timestamp\":\"2026-07-09T12:34:56Z\""));
        assert!(json.contains("\"source\":\"backend-api\""));
        assert!(json.contains("\"level\":\"error\""));
        assert!(json.contains("\"file\":\"/var/log/app.log\""));
        assert!(json.contains("\"line_no\":1024}}"));
        // ダブルクォートがエスケープされていること。
        assert!(json.contains("\\\"quoted\\\""));
    }
}
