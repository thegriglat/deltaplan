use std::fmt;

/// Код результата команды (W1): 0 OK, 1 BAD_INPUT, 2 NO_PLACE, 3 NOT_READY.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    Ok,
    BadInput,
    NoPlace,
    NotReady,
}

impl Code {
    /// Числовой код W1.
    pub fn as_int(self) -> i32 {
        match self {
            Code::Ok => 0,
            Code::BadInput => 1,
            Code::NoPlace => 2,
            Code::NotReady => 3,
        }
    }
}

/// Ошибка команды: код W1 и текст для `last_error()`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub code: Code,
    pub msg: String,
}

impl Error {
    pub fn new(code: Code, msg: impl Into<String>) -> Self {
        Error {
            code,
            msg: msg.into(),
        }
    }
    pub fn bad_input(msg: impl Into<String>) -> Self {
        Self::new(Code::BadInput, msg)
    }
    pub fn no_place(msg: impl Into<String>) -> Self {
        Self::new(Code::NoPlace, msg)
    }
    pub fn not_ready(msg: impl Into<String>) -> Self {
        Self::new(Code::NotReady, msg)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.msg)
    }
}

impl std::error::Error for Error {}
