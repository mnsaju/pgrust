use crate::schedule::{is_due, parse, BrokenDownTime, CronSchedule};
use crate::scheduler::{decide_slot, CronSlot, SlotDecision};

fn tm(minute: u32, hour: u32, day_of_month: u32, month: u32, day_of_week: u32) -> BrokenDownTime {
    BrokenDownTime {
        minute,
        hour,
        day_of_month,
        month,
        day_of_week,
    }
}

#[test]
fn every_minute_matches_anything() {
    let s = parse("* * * * *").expect("parses");
    assert!(is_due(&s, tm(0, 0, 1, 1, 0)));
    assert!(is_due(&s, tm(59, 23, 31, 12, 6)));
}

#[test]
fn exact_minute_and_hour_must_match() {
    let s = parse("30 6 * * *").expect("parses");
    assert!(is_due(&s, tm(30, 6, 15, 3, 2)));
    assert!(!is_due(&s, tm(31, 6, 15, 3, 2)));
    assert!(!is_due(&s, tm(30, 7, 15, 3, 2)));
}

#[test]
fn ranges_and_lists() {
    let s = parse("0 9-17 * * 1,3,5").expect("parses");
    assert!(is_due(&s, tm(0, 9, 1, 1, 1)));
    assert!(is_due(&s, tm(0, 17, 1, 1, 3)));
    assert!(!is_due(&s, tm(0, 18, 1, 1, 1)));
    assert!(!is_due(&s, tm(0, 9, 1, 1, 2)));
}

#[test]
fn steps() {
    let s = parse("*/15 * * * *").expect("parses");
    for minute in [0, 15, 30, 45] {
        assert!(
            is_due(&s, tm(minute, 0, 1, 1, 0)),
            "minute {minute} should match */15"
        );
    }
    for minute in [1, 14, 16, 44, 59] {
        assert!(
            !is_due(&s, tm(minute, 0, 1, 1, 0)),
            "minute {minute} should not match */15"
        );
    }
}

#[test]
fn month_and_day_of_week_names_are_case_insensitive() {
    let s = parse("0 0 * JAN,Feb mon-Fri").expect("parses");
    assert!(is_due(&s, tm(0, 0, 10, 1, 3))); // January, Wednesday
    assert!(is_due(&s, tm(0, 0, 10, 2, 1))); // February, Monday
    assert!(!is_due(&s, tm(0, 0, 10, 3, 3))); // March
    assert!(!is_due(&s, tm(0, 0, 10, 1, 0))); // Sunday
}

#[test]
fn day_of_week_seven_means_sunday_same_as_zero() {
    let s = parse("0 0 * * 7").expect("parses");
    assert!(
        is_due(&s, tm(0, 0, 1, 1, 0)),
        "day-of-week 0 (Sunday) must match a schedule written as 7"
    );
}

#[test]
fn day_of_month_and_day_of_week_are_ored_when_both_restricted() {
    // Fires on the 1st, the 15th, OR any Monday -- not only when both
    // conditions coincide (real cron's classic day-field OR rule).
    let s = parse("0 0 1,15 * 1").expect("parses");
    assert!(is_due(&s, tm(0, 0, 1, 6, 3))); // the 1st, a Wednesday
    assert!(is_due(&s, tm(0, 0, 3, 6, 1))); // not the 1st/15th, but a Monday
    assert!(!is_due(&s, tm(0, 0, 3, 6, 3))); // neither
}

#[test]
fn day_of_month_wildcard_lets_day_of_week_alone_constrain() {
    let s = parse("0 0 * * 1").expect("parses");
    assert!(is_due(&s, tm(0, 0, 3, 6, 1))); // any Monday
    assert!(!is_due(&s, tm(0, 0, 3, 6, 2))); // a Tuesday
}

#[test]
fn seconds_shorthand_always_answers_due_and_leaves_interval_gating_to_the_caller() {
    let s = parse("5 seconds").expect("parses");
    assert_eq!(s, CronSchedule::Seconds(5));
    assert!(is_due(&s, tm(0, 0, 1, 1, 0)));
}

#[test]
fn reboot_is_recognized_but_never_matched_by_is_due() {
    let s = parse("@reboot").expect("parses");
    assert_eq!(s, CronSchedule::Reboot);
    assert!(!is_due(&s, tm(0, 0, 1, 1, 0)));
}

#[test]
fn rejects_wrong_field_count() {
    assert!(parse("* * * *").is_err());
    assert!(parse("* * * * * *").is_err());
}

#[test]
fn rejects_out_of_range_values() {
    assert!(parse("60 * * * *").is_err());
    assert!(parse("* 24 * * *").is_err());
    assert!(parse("* * 0 * *").is_err());
    assert!(parse("* * * 13 *").is_err());
    assert!(parse("* * * * 8").is_err());
}

#[test]
fn rejects_invalid_names_and_zero_step() {
    assert!(parse("0 0 * notamonth *").is_err());
    assert!(parse("*/0 * * * *").is_err());
}

#[test]
fn rejects_out_of_range_seconds_interval() {
    assert!(parse("0 seconds").is_err());
    assert!(parse("60 seconds").is_err());
}

fn slot(in_use: bool, jobid: i64) -> CronSlot {
    CronSlot {
        in_use,
        jobid,
        command: String::new(),
        database: String::new(),
        username: String::new(),
    }
}

#[test]
fn already_running_job_is_refused_even_with_a_free_slot() {
    let slots = [slot(true, 1), slot(false, 2)];
    assert_eq!(decide_slot(&slots, 1, 32), SlotDecision::AlreadyRunning);
}

#[test]
fn pool_full_when_in_use_count_reaches_max_running_with_no_free_slot() {
    let slots = [slot(true, 1), slot(true, 2)];
    assert_eq!(decide_slot(&slots, 3, 2), SlotDecision::PoolFull);
}

#[test]
fn a_freed_slot_is_reused_by_index_rather_than_growing_the_pool() {
    let slots = [slot(true, 1), slot(false, 2), slot(true, 3)];
    assert_eq!(decide_slot(&slots, 4, 32), SlotDecision::Reuse(1));
}

#[test]
fn no_free_slot_under_the_cap_appends() {
    let slots = [slot(true, 1), slot(true, 2)];
    assert_eq!(decide_slot(&slots, 3, 32), SlotDecision::Append);
}

#[test]
fn max_running_jobs_zero_always_reports_pool_full() {
    assert_eq!(decide_slot(&[], 1, 0), SlotDecision::PoolFull);
}
