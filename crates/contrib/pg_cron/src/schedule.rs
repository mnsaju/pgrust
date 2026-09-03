//! Cron-expression parsing and due-check, matching real pg_cron's supported
//! syntax (`src/entry.c`'s ParseCronLine grammar): standard 5-field cron
//! (minute hour day-of-month month day-of-week) with `*`, ranges (`a-b`),
//! lists (`a,b,c`), steps (`*/n` or `a-b/n`), month/day-of-week name
//! aliases, plus pg_cron's own `<N> seconds` shorthand and `@reboot`.
//!
//! Deliberately field-matching against the current minute (mirrors real
//! pg_cron's `IsCronJobDue`), not a "compute the next occurrence"
//! date-arithmetic engine — the scheduler wakes on a fixed cadence and asks
//! "is this schedule due right now," it never needs to know when a job will
//! next fire before that moment arrives.
//!
//! No dependency on Postgres's timestamp types on purpose: `BrokenDownTime`
//! is a plain calendar tuple, so this module (and its tests) never need to
//! fabricate a `TimestampTz` — converting "now" into one is `scheduler.rs`'s
//! job, not this module's.

const MONTH_NAMES: [(&str, u32); 12] = [
    ("jan", 1),
    ("feb", 2),
    ("mar", 3),
    ("apr", 4),
    ("may", 5),
    ("jun", 6),
    ("jul", 7),
    ("aug", 8),
    ("sep", 9),
    ("oct", 10),
    ("nov", 11),
    ("dec", 12),
];

// 0 and 7 both mean Sunday (standard cron convention); resolved to 0 here,
// folded back onto 0 in `parse` for the numeral "7".
const DOW_NAMES: [(&str, u32); 7] = [
    ("sun", 0),
    ("mon", 1),
    ("tue", 2),
    ("wed", 3),
    ("thu", 4),
    ("fri", 5),
    ("sat", 6),
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CronSchedule {
    /// Standard 5-field expression.
    Fields {
        minute: FieldSpec,
        hour: FieldSpec,
        day_of_month: FieldSpec,
        month: FieldSpec,
        day_of_week: FieldSpec,
    },
    /// pg_cron's `<N> seconds` shorthand: fire every N seconds (1-59). The
    /// scheduler enforces the interval itself; `is_due` always answers true
    /// for this variant since there is no calendar field to check.
    Seconds(u32),
    /// pg_cron's `@reboot`: fire exactly once, at scheduler startup. Never
    /// matched by `is_due` — the caller fires it once, out of band.
    Reboot,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldSpec {
    // Indexed 0..=max for this field; true where the schedule matches.
    matches: Vec<bool>,
    // True only when the raw field text was the literal "*" — governs
    // cron's day-of-month/day-of-week OR-vs-AND rule, which is NOT the same
    // as "a range/list that happens to cover every value."
    is_wildcard: bool,
}

impl FieldSpec {
    fn contains(&self, value: u32) -> bool {
        self.matches.get(value as usize).copied().unwrap_or(false)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BrokenDownTime {
    pub minute: u32,
    pub hour: u32,
    pub day_of_month: u32,
    pub month: u32,
    /// 0 = Sunday .. 6 = Saturday.
    pub day_of_week: u32,
}

pub fn parse(schedule_text: &str) -> Result<CronSchedule, String> {
    let text = schedule_text.trim();
    if text == "@reboot" {
        return Ok(CronSchedule::Reboot);
    }
    if let Some(rest) = text.strip_suffix("seconds") {
        let rest = rest.trim();
        let n: u32 = rest
            .parse()
            .map_err(|_| format!("invalid \"seconds\" schedule \"{schedule_text}\""))?;
        if !(1..=59).contains(&n) {
            return Err(format!(
                "seconds interval must be between 1 and 59, found {n} in \"{schedule_text}\""
            ));
        }
        return Ok(CronSchedule::Seconds(n));
    }

    let fields: Vec<&str> = text.split_whitespace().collect();
    if fields.len() != 5 {
        return Err(format!(
            "cron expression must have 5 fields (minute hour day-of-month month \
             day-of-week), found {} in \"{schedule_text}\"",
            fields.len()
        ));
    }
    let minute = parse_field(fields[0], 0, 59, &[])?;
    let hour = parse_field(fields[1], 0, 23, &[])?;
    let day_of_month = parse_field(fields[2], 1, 31, &[])?;
    let month = parse_field(fields[3], 1, 12, &MONTH_NAMES)?;
    let mut day_of_week = parse_field(fields[4], 0, 7, &DOW_NAMES)?;
    if day_of_week.matches[7] {
        day_of_week.matches[0] = true;
    }

    Ok(CronSchedule::Fields {
        minute,
        hour,
        day_of_month,
        month,
        day_of_week,
    })
}

fn parse_field(text: &str, min: u32, max: u32, names: &[(&str, u32)]) -> Result<FieldSpec, String> {
    let mut matches = vec![false; (max + 1) as usize];
    let mut is_wildcard = false;
    for part in text.split(',') {
        if part.is_empty() {
            return Err(format!("empty field component in \"{text}\""));
        }
        let (range_part, step) = match part.split_once('/') {
            Some((r, s)) => (
                r,
                Some(
                    s.parse::<u32>()
                        .map_err(|_| format!("invalid step \"{s}\" in \"{part}\""))?,
                ),
            ),
            None => (part, None),
        };
        let (start, end) = if range_part == "*" {
            if text == "*" {
                is_wildcard = true;
            }
            (min, max)
        } else if let Some((a, b)) = range_part.split_once('-') {
            (resolve_value(a, names)?, resolve_value(b, names)?)
        } else {
            let v = resolve_value(range_part, names)?;
            (v, v)
        };
        if start < min || end > max || start > end {
            return Err(format!(
                "field value out of range in \"{part}\" (expected {min}-{max})"
            ));
        }
        let step = step.unwrap_or(1);
        if step == 0 {
            return Err(format!("step cannot be zero in \"{part}\""));
        }
        let mut v = start;
        while v <= end {
            matches[v as usize] = true;
            v = match v.checked_add(step) {
                Some(next) => next,
                None => break,
            };
        }
    }
    Ok(FieldSpec {
        matches,
        is_wildcard,
    })
}

fn resolve_value(text: &str, names: &[(&str, u32)]) -> Result<u32, String> {
    if let Ok(v) = text.parse::<u32>() {
        return Ok(v);
    }
    let lower = text.to_ascii_lowercase();
    names
        .iter()
        .find(|(name, _)| *name == lower)
        .map(|(_, v)| *v)
        .ok_or_else(|| format!("invalid value \"{text}\""))
}

/// Real cron's day-of-month/day-of-week rule: when EITHER field is a literal
/// `*`, only the other constrains (both-wildcard means always due on the
/// day axis); when NEITHER is a wildcard, the day fires if either matches
/// (OR, not AND) — a schedule like "0 0 1,15 * MON" runs on the 1st, the
/// 15th, AND every Monday, not only when both coincide.
pub fn is_due(schedule: &CronSchedule, now: BrokenDownTime) -> bool {
    match schedule {
        CronSchedule::Reboot => false,
        CronSchedule::Seconds(_) => true,
        CronSchedule::Fields {
            minute,
            hour,
            day_of_month,
            month,
            day_of_week,
        } => {
            if !minute.contains(now.minute)
                || !hour.contains(now.hour)
                || !month.contains(now.month)
            {
                return false;
            }
            let dom_ok = day_of_month.contains(now.day_of_month);
            let dow_ok = day_of_week.contains(now.day_of_week);
            if day_of_month.is_wildcard || day_of_week.is_wildcard {
                dom_ok && dow_ok
            } else {
                dom_ok || dow_ok
            }
        }
    }
}
