//! Explicit caller permission. Portal consent cannot elevate a read-only request.
#[derive(Debug, PartialEq, Eq)]
pub enum Mode {
    Share { allow_input: bool },
    Check,
    Version,
    Help,
}

pub fn parse(args: &[&str]) -> Result<Mode, &'static str> {
    match args {
        [] | ["--read-only"] => Ok(Mode::Share { allow_input: false }),
        ["--allow-input"] => Ok(Mode::Share { allow_input: true }),
        ["--check"] => Ok(Mode::Check),
        ["--version"] => Ok(Mode::Version),
        ["--help"] => Ok(Mode::Help),
        _ => Err("invalid_arguments"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_permission_only() {
        assert_eq!(parse(&[]), Ok(Mode::Share { allow_input: false }));
        assert_eq!(parse(&["--read-only"]), parse(&[]));
        assert_eq!(
            parse(&["--allow-input"]),
            Ok(Mode::Share { allow_input: true })
        );
        assert!(parse(&["--read-only", "--allow-input"]).is_err());
        assert!(parse(&["--input-authorized"]).is_err());
    }
}
