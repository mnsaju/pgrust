//! Rust implementation of the local-repository pgBackRest command contracts.
//!
//! This compatibility slice is based on pgBackRest's public command behavior:
//! stanza metadata is duplicated, archive pushes are idempotent, and backup
//! manifests protect restore and verification with SHA-256 checksums.

mod config;
mod repository;

pub use config::{Config, ConfigError};
pub use repository::{BackupInfo, Repository, RepositoryError};
