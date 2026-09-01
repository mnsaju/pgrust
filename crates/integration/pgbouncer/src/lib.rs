//! A Rust implementation of the PgBouncer PostgreSQL connection-pooler role.
//!
//! The implementation is derived from PgBouncer's public protocol and test
//! contracts, but does not vendor its C source or Python test harness.

mod config;
mod protocol;
mod proxy;

pub use config::{Config, ConfigError, PoolMode};
pub use proxy::run;

/// The upstream PgBouncer test directory used to derive compatibility cases.
pub const UPSTREAM_TEST_ROOT: &str = "https://github.com/pgbouncer/pgbouncer/tree/master/test";
