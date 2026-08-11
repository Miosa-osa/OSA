//! Scoped, restoring environment-variable overrides for tests.
//!
//! Environment variables are process-global, and cargo runs tests on a thread
//! pool. A test that pins `HOME` to a fixture value is therefore not adjusting
//! *its* world, it is adjusting everyone's: `config::cli` resolves `~/.osa`
//! from `HOME`, so a concurrent test can read a path that belongs to a
//! different test — or, if the override outlives the test that set it, a path
//! outside the sandbox entirely. Left unrestored, the same suite also produces
//! different results depending on execution order, which makes any failure
//! unreproducible.
//!
//! Two things are needed and neither is sufficient alone:
//!
//!   1. `#[serial]` (from `serial_test`) on every test that mutates the
//!      environment, so no other test observes the window in which it differs;
//!   2. [`EnvGuard`], which puts the previous value back on drop — including on
//!      panic, since the guard unwinds with the test.
//!
//! ```ignore
//! #[test]
//! #[serial]
//! fn something() {
//!     let _home = EnvGuard::set("HOME", "/Users/rhl");
//!     // ... HOME is pinned for the body, restored at the closing brace.
//! }
//! ```

/// Sets an environment variable for the lifetime of the guard and restores the
/// previous state (including *absence*) when it drops.
///
/// Hold it in a binding — `let _guard = …`, never `let _ = …`, which drops it
/// immediately and restores before the test body has run.
#[must_use = "the override is reverted as soon as the guard drops"]
pub struct EnvGuard {
    key: String,
    previous: Option<std::ffi::OsString>,
}

impl EnvGuard {
    /// Pin `key` to `value` until the guard drops.
    pub fn set(key: &str, value: &str) -> Self {
        let previous = std::env::var_os(key);
        // SAFETY: callers pair this with `#[serial]`, so no other test thread is
        // running while the process environment is mutated.
        unsafe { std::env::set_var(key, value) };
        Self {
            key: key.to_string(),
            previous,
        }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        // SAFETY: same serialization contract as `set`.
        unsafe {
            match self.previous.take() {
                Some(prev) => std::env::set_var(&self.key, prev),
                // The variable did not exist before us; leaving an empty value
                // behind is not the same as absence for `var_os`-style checks.
                None => std::env::remove_var(&self.key),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn a_pre_existing_value_is_restored() {
        let _outer = EnvGuard::set("OSA_TEST_ENV_GUARD", "original");
        {
            let _inner = EnvGuard::set("OSA_TEST_ENV_GUARD", "shadowed");
            assert_eq!(std::env::var("OSA_TEST_ENV_GUARD").unwrap(), "shadowed");
        }
        assert_eq!(
            std::env::var("OSA_TEST_ENV_GUARD").unwrap(),
            "original",
            "dropping the inner guard must restore the outer value"
        );
    }

    /// Absence is a distinct state from "set to empty" — restoring must remove.
    #[test]
    #[serial]
    fn an_absent_variable_is_removed_again() {
        let key = "OSA_TEST_ENV_GUARD_ABSENT";
        assert!(std::env::var_os(key).is_none(), "fixture must start unset");
        {
            let _g = EnvGuard::set(key, "temporary");
            assert_eq!(std::env::var(key).unwrap(), "temporary");
        }
        assert!(
            std::env::var_os(key).is_none(),
            "a variable that did not exist must not be left behind as empty"
        );
    }

    /// The restore has to survive a panicking test body, or one failure
    /// contaminates every test that runs after it.
    #[test]
    #[serial]
    fn the_value_is_restored_even_when_the_body_panics() {
        let key = "OSA_TEST_ENV_GUARD_PANIC";
        let _outer = EnvGuard::set(key, "original");
        let result = std::panic::catch_unwind(|| {
            let _g = EnvGuard::set(key, "during-panic");
            panic!("boom");
        });
        assert!(result.is_err(), "the body was supposed to panic");
        assert_eq!(std::env::var(key).unwrap(), "original");
    }
}
