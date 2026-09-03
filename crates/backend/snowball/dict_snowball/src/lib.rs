// The stemmer modules under `stemmers/` are a mechanical, line-for-line port
// of the upstream Snowball compiler's generated C output (one file per
// algorithm, tens of thousands of lines, never hand-edited): control flow,
// mutability, and unsafe-block placement all mirror the C exactly rather than
// idiomatic Rust, so the lints below fire pervasively and are allowed at the
// crate level rather than one `#[allow]` per site.
#![allow(non_snake_case, non_upper_case_globals, non_camel_case_types)]
#![allow(unused_mut, unused_assignments, unused_unsafe)]
#![allow(clippy::missing_safety_doc)]
#![allow(clippy::needless_return)]
#![allow(clippy::nonminimal_bool)]
#![allow(clippy::if_same_then_else)]
#![allow(clippy::single_match)]
#![allow(clippy::needless_late_init)]
#![allow(clippy::collapsible_if)]
#![allow(clippy::precedence)]
#![allow(clippy::assign_op_pattern)]
#![allow(clippy::manual_ignore_case_cmp)]
#![allow(clippy::manual_range_contains)]
#![allow(clippy::blocks_in_conditions)]

pub mod api;
pub mod builtins;
pub mod dict;
pub mod mem;
pub mod types;
pub mod utilities;

pub mod stemmers {
    pub mod stem_iso_8859_1_english;
    pub mod stem_utf8_english;
}

#[cfg(test)]
mod tests;
