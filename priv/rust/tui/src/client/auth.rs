use anyhow::Result;
use std::io::Write;
use std::path::{Path, PathBuf};
use tracing::debug;

/// Create `dir` (and parents) owner-only, and force 0700 if it already exists.
///
/// A 0755 directory holding credentials leaks the *names* of what is stored and
/// lets any local user stat the files; the directory is part of the secret.
pub(crate) fn create_dir_private(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        // `recursive(true)` is a no-op on an existing directory, so a 0755 dir
        // left by an older build would keep its mode. Force it.
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(dir)?;
    }
    Ok(())
}

/// Write `contents` to `path` such that the bytes are **never** observable at a
/// permissive mode -- not even for an instant.
///
/// NEVER `fs::write` then `set_permissions`. That is a real TOCTOU hole, not a
/// theoretical one: between the two calls the file exists at the process umask
/// (commonly 0644) with the secret already in it, and any local process can
/// read it. Instead:
///
///   1. open with `OpenOptionsExt::mode(0o600)`, which applies at *creation*
///      time, so a brand-new file is owner-only from birth;
///   2. `fchmod` the open handle to 0600 -- `mode()` is ignored when the file
///      already exists, so a 0644 file left by an older OSA build is repaired
///      here, on the descriptor (no path re-resolution to race);
///   3. only then truncate and write the payload.
pub(crate) fn write_private(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    let mut opts = std::fs::OpenOptions::new();
    // Deliberately NOT `.truncate(true)`: truncation happens after the mode is
    // known-good, so the window between "file exists" and "file is 0600" never
    // contains freshly written secret bytes.
    opts.write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut file = opts.open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    file.set_len(0)?;
    file.write_all(contents)?;
    file.flush()?;
    Ok(())
}

/// Like [`write_private`], but refuses to write through an existing path.
///
/// For files spooled into a world-writable shared directory (`$TMPDIR`), where
/// the name is predictable: `fs::write` follows symlinks, so a pre-planted
/// symlink at the target is an arbitrary-write primitive. `create_new(true)`
/// is `O_EXCL`, which fails outright if anything -- symlink or not -- is
/// already sitting at that path.
pub(crate) fn write_private_new(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut file = opts.open(path)?;
    file.write_all(contents)?;
    file.flush()?;
    Ok(())
}

/// Authentication state with compile-time enforcement.
///
/// Callers must pattern-match or call `require_token()` before using
/// authenticated endpoints, making "forgot to login" a compile-time concept.
#[derive(Debug, Clone)]
pub enum AuthState {
    Unauthenticated,
    Authenticated {
        token: String,
        refresh_token: String,
    },
}

impl AuthState {
    /// Returns token or error -- compile-time enforces auth check.
    pub fn require_token(&self) -> Result<&str> {
        match self {
            AuthState::Authenticated { token, .. } => Ok(token),
            AuthState::Unauthenticated => anyhow::bail!("Not authenticated - call login() first"),
        }
    }

    pub fn refresh_token(&self) -> Option<&str> {
        match self {
            AuthState::Authenticated { refresh_token, .. } => Some(refresh_token),
            AuthState::Unauthenticated => None,
        }
    }

    pub fn is_authenticated(&self) -> bool {
        matches!(self, AuthState::Authenticated { .. })
    }
}

/// Persist tokens to the profile directory for session resumption.
pub fn save_tokens(profile_dir: &PathBuf, token: &str, refresh_token: &str) -> Result<()> {
    create_dir_private(profile_dir)?;
    let token_path = profile_dir.join("token");
    let refresh_path = profile_dir.join("refresh_token");
    write_private(&token_path, token.as_bytes())?;
    write_private(&refresh_path, refresh_token.as_bytes())?;
    debug!("Tokens saved to {:?}", profile_dir);
    Ok(())
}

/// Load saved tokens from the profile directory.
/// Returns None if tokens are missing or empty.
pub fn load_tokens(profile_dir: &PathBuf) -> Option<(String, String)> {
    let token_path = profile_dir.join("token");
    let refresh_path = profile_dir.join("refresh_token");

    match (
        std::fs::read_to_string(&token_path),
        std::fs::read_to_string(&refresh_path),
    ) {
        (Ok(token), Ok(refresh)) => {
            let token = token.trim().to_string();
            let refresh = refresh.trim().to_string();
            if token.is_empty() {
                return None;
            }
            debug!("Loaded tokens from {:?}", profile_dir);
            Some((token, refresh))
        }
        _ => {
            debug!("No saved tokens found");
            None
        }
    }
}

/// Remove saved tokens from the profile directory.
pub fn clear_tokens(profile_dir: &PathBuf) {
    let _ = std::fs::remove_file(profile_dir.join("token"));
    let _ = std::fs::remove_file(profile_dir.join("refresh_token"));
    debug!("Tokens cleared");
}

/// A self-cleaning scratch directory. Rolled by hand rather than pulling in a
/// dev-dependency: these tests only need "a fresh path that goes away".
#[cfg(test)]
pub(crate) struct TempDir(pub PathBuf);

#[cfg(test)]
impl TempDir {
    pub(crate) fn new(tag: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "osa-test-{tag}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        Self(dir)
    }

    pub(crate) fn path(&self) -> &Path {
        &self.0
    }
}

#[cfg(test)]
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(all(test, unix))]
mod perm_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn mode_of(path: &Path) -> u32 {
        std::fs::metadata(path).expect("stat").permissions().mode() & 0o777
    }

    #[test]
    fn save_tokens_writes_credentials_owner_only() {
        let tmp = TempDir::new("tokens");
        let profile = tmp.path().join("profile");

        save_tokens(&profile, "live-token", "live-refresh").expect("save");

        assert_eq!(
            mode_of(&profile.join("token")),
            0o600,
            "auth token must not be world-readable"
        );
        assert_eq!(
            mode_of(&profile.join("refresh_token")),
            0o600,
            "refresh token must not be world-readable"
        );
        // Round-trip: hardening must not have broken persistence.
        assert_eq!(
            load_tokens(&profile),
            Some(("live-token".to_string(), "live-refresh".to_string()))
        );
    }

    #[test]
    fn save_tokens_creates_profile_dir_owner_only() {
        let tmp = TempDir::new("profiledir");
        let profile = tmp.path().join("nested").join("profile");

        save_tokens(&profile, "t", "r").expect("save");

        assert_eq!(
            mode_of(&profile),
            0o700,
            "credential directory must not be traversable by others"
        );
    }

    #[test]
    fn save_tokens_repairs_preexisting_world_readable_files() {
        let tmp = TempDir::new("legacy");
        let profile = tmp.path().join("profile");
        std::fs::create_dir_all(&profile).unwrap();

        // Simulate an older OSA build: 0755 dir, 0644 credential files that
        // already exist, so O_CREAT's mode argument is ignored on reopen.
        let token_path = profile.join("token");
        let refresh_path = profile.join("refresh_token");
        std::fs::write(&token_path, "stale").unwrap();
        std::fs::write(&refresh_path, "stale").unwrap();
        std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::set_permissions(&refresh_path, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::set_permissions(&profile, std::fs::Permissions::from_mode(0o755)).unwrap();

        save_tokens(&profile, "fresh-token", "fresh-refresh").expect("save");

        assert_eq!(mode_of(&token_path), 0o600, "pre-existing 0644 token not repaired");
        assert_eq!(
            mode_of(&refresh_path),
            0o600,
            "pre-existing 0644 refresh token not repaired"
        );
        assert_eq!(mode_of(&profile), 0o700, "pre-existing 0755 profile dir not repaired");
        assert_eq!(
            load_tokens(&profile),
            Some(("fresh-token".to_string(), "fresh-refresh".to_string())),
            "truncate-after-chmod must still replace the old contents"
        );
    }

    #[test]
    fn write_private_truncates_longer_previous_contents() {
        let tmp = TempDir::new("truncate");
        let path = tmp.path().join("f");
        write_private(&path, b"a very long previous value").unwrap();
        write_private(&path, b"short").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "short");
        assert_eq!(mode_of(&path), 0o600);
    }

    #[test]
    fn write_private_new_refuses_existing_path() {
        let tmp = TempDir::new("exclusive");
        let path = tmp.path().join("compose.md");

        write_private_new(&path, b"first").expect("first write");
        assert_eq!(mode_of(&path), 0o600);

        let err = write_private_new(&path, b"second").expect_err("must refuse to clobber");
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "first");
    }

    #[test]
    fn write_private_new_refuses_planted_symlink() {
        let tmp = TempDir::new("symlink");
        let victim = tmp.path().join("victim");
        std::fs::write(&victim, "do not overwrite me").unwrap();
        let planted = tmp.path().join("osa-compose-predictable.md");
        std::os::unix::fs::symlink(&victim, &planted).unwrap();

        let err = write_private_new(&planted, b"attacker-controlled")
            .expect_err("must not follow a pre-planted symlink");
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(
            std::fs::read_to_string(&victim).unwrap(),
            "do not overwrite me",
            "symlink target was clobbered -- arbitrary write primitive"
        );
    }
}
