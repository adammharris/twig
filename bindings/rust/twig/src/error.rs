use std::fmt;

use crate::ffi;

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum Error {
    InvalidArgument,
    ParseError,
    OutOfMemory,
    UnsupportedFormat,
    Internal,
}

impl Error {
    pub(crate) fn from_status(status: ffi::TwigStatus) -> Result<(), Self> {
        match status.0 {
            ffi::TwigStatus::OK => Ok(()),
            ffi::TwigStatus::INVALID_ARGUMENT => Err(Self::InvalidArgument),
            ffi::TwigStatus::PARSE_ERROR => Err(Self::ParseError),
            ffi::TwigStatus::OUT_OF_MEMORY => Err(Self::OutOfMemory),
            ffi::TwigStatus::UNSUPPORTED_FORMAT => Err(Self::UnsupportedFormat),
            _ => Err(Self::Internal),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidArgument => f.write_str("invalid argument"),
            Error::ParseError => f.write_str("parse error"),
            Error::OutOfMemory => f.write_str("out of memory"),
            Error::UnsupportedFormat => f.write_str("unsupported format"),
            Error::Internal => f.write_str("internal error"),
        }
    }
}

impl std::error::Error for Error {}
