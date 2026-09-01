//! Rust-only compatibility tests for pgrust behind an external PgBouncer.
//!
//! PgBouncer remains a separate process. This crate owns the pgrust backend
//! contracts derived from PgBouncer's upstream test suite; it does not vendor
//! or reimplement PgBouncer's C implementation.

/// The upstream PgBouncer test directory used to derive compatibility cases.
pub const UPSTREAM_TEST_ROOT: &str = "https://github.com/pgbouncer/pgbouncer/tree/master/test";
