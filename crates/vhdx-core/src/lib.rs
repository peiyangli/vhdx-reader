//! Read-only, thread-confined disk-image sessions. Native handles never cross threads.
pub mod credentials;
pub mod native;
pub mod partition;
pub mod session;
pub mod source;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Invalid image: {0}")]
    Invalid(String),
    #[error("Unsupported: {0}")]
    Unsupported(String),
    #[error("Native library error: {0}")]
    Native(String),
    #[error("Volume is locked; supply a password or recovery password")]
    Locked,
    #[error("The supplied credential could not unlock this volume")]
    WrongCredential,
    #[error("Not found: {0}")]
    NotFound(String),
    #[error("Operation cancelled")]
    Cancelled,
}

pub type Result<T> = std::result::Result<T, Error>;
