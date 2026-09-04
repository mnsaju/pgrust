seam_core::seam!(
    pub fn my_proc_pid() -> i32
);

// Authoritative critical-section depth.  The storage lives in
// init_small::globals; error reporting reaches it through this seam to avoid
// introducing an elog <-> init_small dependency cycle.
seam_core::seam!(
    pub fn crit_section_count() -> u32
);
