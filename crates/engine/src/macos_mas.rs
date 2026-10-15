//! App Store file access. The signed sandbox remains the authority; paths never grant access.
//! Bookmark guards stay alive across background reads and atomic replacement writes.
#![forbid(unsafe_code)]

use std::path::{Path, PathBuf};

/// True only for the macOS App Store variant.
pub const fn enabled() -> bool {
    cfg!(all(target_os = "macos", feature = "mac-app-store"))
}

/// Foundation returns the sandbox home; inherited HOME and portable overrides are not used.
pub fn container_dir(name: &str) -> Option<PathBuf> {
    directory(name, "Library/Application Support")
}
pub fn cache_dir(name: &str) -> Option<PathBuf> {
    directory(name, "Library/Caches")
}
/// Private scratch space below the verified container, independent of TMPDIR overrides.
pub fn temporary_dir(name: &str) -> Option<PathBuf> {
    cache_dir(name).map(|p| p.join("Temporary"))
}

fn directory(name: &str, kind: &str) -> Option<PathBuf> {
    if name.is_empty()
        || !matches!((Path::new(name).components().next(), Path::new(name).components().nth(1)), (Some(std::path::Component::Normal(_)), None))
    {
        return None;
    }
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    {
        let home = PathBuf::from(objc2_foundation::NSHomeDirectory().to_string());
        let bundle = objc2_foundation::NSBundle::mainBundle().bundleIdentifier()?;
        sandbox_home(&home, &bundle.to_string()).then(|| home.join(kind).join(name))
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        let _ = kind;
        None
    }
}

#[cfg(any(test, all(target_os = "macos", feature = "mac-app-store")))]
fn sandbox_home(home: &Path, bundle: &str) -> bool {
    !bundle.is_empty()
        && home.is_absolute()
        && home.file_name().is_some_and(|p| p == "Data")
        && home.parent().is_some_and(|p| p.file_name().is_some_and(|n| n == bundle))
        && home.ancestors().nth(2).is_some_and(|p| p.file_name().is_some_and(|n| n == "Containers"))
        && home.ancestors().nth(3).is_some_and(|p| p.file_name().is_some_and(|n| n == "Library"))
        && !home.components().any(|c| matches!(c, std::path::Component::ParentDir))
}

/// Whether an explicitly selected directory grant (or the app container) covers this path.
pub fn directory_granted(path: impl AsRef<Path>) -> bool {
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    {
        imp::directory_granted(path.as_ref())
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        let _ = path;
        true
    }
}

/// Restore all persisted grants before preferences, recent files, media or recovery are read.
pub fn initialize(name: &str) -> Vec<String> {
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    {
        imp::initialize(name)
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        let _ = name;
        Vec::new()
    }
}

/// Record only a path returned by a native panel, Finder open event or user drop.
/// Save destinations that do not exist are finished by after_write/poll after successful creation.
pub fn selected(path: impl AsRef<Path>, save: bool) -> Result<PathBuf, String> {
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    {
        imp::selected(path.as_ref(), save)
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        let _ = save;
        Ok(path.as_ref().to_path_buf())
    }
}

/// Panel convenience: report errors via poll, never pass an unusable choice to a document command.
pub fn picked(path: impl AsRef<Path>, save: bool) -> Option<PathBuf> {
    match selected(path, save) {
        Ok(path) => Some(path),
        Err(error) => {
            report(error);
            None
        }
    }
}

/// Resolve stored old paths to their current location while retaining the OS access guard.
pub fn resolve(path: impl AsRef<Path>) -> Result<PathBuf, String> {
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    {
        imp::resolve(path.as_ref())
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        Ok(path.as_ref().to_path_buf())
    }
}

/// Update explicit filesystem parameters, including nested batch commands, after files move.
/// Relative paths retain their ordinary container-relative meaning.
pub fn resolve_params(value: &mut serde_json::Value) -> Result<(), String> {
    if !enabled() {
        return Ok(());
    }
    fn visit(value: &mut serde_json::Value, path_key: bool, depth: usize) -> Result<(), String> {
        if depth > 64 {
            return Err("File parameters are nested too deeply".into());
        }
        match value {
            serde_json::Value::Object(fields) => {
                for (key, value) in fields {
                    visit(
                        value,
                        matches!(
                            key.as_str(),
                            "path" | "paths" | "file" | "files" | "folder" | "directory" | "sourcePath" | "output" | "destination"
                        ),
                        depth + 1,
                    )?;
                }
            }
            serde_json::Value::Array(values) => {
                for value in values {
                    visit(value, path_key, depth + 1)?;
                }
            }
            serde_json::Value::String(path) if path_key && Path::new(path).is_absolute() => {
                *path = resolve(Path::new(path))?.to_string_lossy().into_owned();
            }
            _ => {}
        }
        Ok(())
    }
    visit(value, false, 0)
}

/// Refresh a bookmark after a successful atomic save, which can change the target file identity.
pub fn after_write(path: impl AsRef<Path>) -> Result<(), String> {
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    {
        let result = imp::after_write(path.as_ref());
        if let Err(error) = &result {
            report(error.clone());
        }
        result
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        let _ = path;
        Ok(())
    }
}

/// Finish newly created save destinations and return actionable warnings for the host to display.
pub fn poll() -> Vec<String> {
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    {
        imp::poll()
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        Vec::new()
    }
}
/// Queue an actionable file-access warning for the host without reporting a completed save as failed.
pub fn notice(error: String) {
    report(error);
}

fn report(error: String) {
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    imp::report(error);
    #[cfg(not(all(target_os = "macos", feature = "mac-app-store")))]
    {
        let _ = error;
    }
}

#[cfg(any(test, all(target_os = "macos", feature = "mac-app-store")))]
mod store {
    use super::*;
    use serde::{Deserialize, Serialize};
    use std::collections::BTreeMap;
    pub const LIMIT: usize = 4096;
    #[cfg(all(target_os = "macos", feature = "mac-app-store"))]
    pub const LIVE_LIMIT: usize = 8192;
    pub const MAX_BYTES: usize = 16 * 1024 * 1024;
    #[derive(Clone, Serialize, Deserialize)]
    #[serde(deny_unknown_fields)]
    pub struct Entry {
        pub bookmark: Vec<u8>,
        pub directory: bool,
    }
    #[derive(Serialize, Deserialize)]
    #[serde(deny_unknown_fields)]
    pub struct Store {
        pub version: u32,
        #[serde(deserialize_with = "unique_entries")]
        pub entries: BTreeMap<String, Entry>,
    }
    fn unique_entries<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<BTreeMap<String, Entry>, D::Error> {
        struct Entries;
        impl<'de> serde::de::Visitor<'de> for Entries {
            type Value = BTreeMap<String, Entry>;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("unique bounded bookmark paths")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut entries = BTreeMap::new();
                while let Some((path, entry)) = map.next_entry::<String, Entry>()? {
                    if entries.len() >= LIMIT || entries.insert(path, entry).is_some() {
                        return Err(serde::de::Error::custom("duplicate or excessive bookmark paths"));
                    }
                }
                Ok(entries)
            }
        }
        deserializer.deserialize_map(Entries)
    }
    impl Default for Store {
        fn default() -> Self {
            Self { version: 1, entries: BTreeMap::new() }
        }
    }
    pub fn valid_path(path: &Path) -> bool {
        path.is_absolute()
            && !path.as_os_str().is_empty()
            && path.to_str().is_some_and(|s| s.len() <= 8192)
            && !path.components().any(|c| matches!(c, std::path::Component::ParentDir))
    }
    pub fn decode(bytes: &[u8]) -> Result<Store, String> {
        if bytes.len() > MAX_BYTES {
            return Err("bookmark store exceeds the safe size limit".into());
        }
        let value: Store = serde_json::from_slice(bytes).map_err(|e| format!("invalid bookmark store: {e}"))?;
        if value.version != 1 || value.entries.len() > LIMIT {
            return Err("unsupported or oversized bookmark store".into());
        }
        for (path, entry) in &value.entries {
            if !valid_path(Path::new(path)) || entry.bookmark.is_empty() || entry.bookmark.len() > 65536 {
                return Err("bookmark store contains an invalid path or bookmark".into());
            }
        }
        Ok(value)
    }
    pub fn encode(data: &Store) -> Result<Vec<u8>, String> {
        if data.entries.len() > LIMIT {
            return Err("Bookmark storage has reached its entry limit; select containing folders to consolidate access".into());
        }
        let bytes = serde_json::to_vec(data).map_err(|e| e.to_string())?;
        decode(&bytes)?;
        Ok(bytes)
    }
    pub fn refreshed(entry: &Entry, stale: bool, create: impl FnOnce() -> Result<Vec<u8>, String>) -> Result<Option<Entry>, String> {
        if !stale {
            return Ok(None);
        }
        let bookmark = create()?;
        if bookmark.is_empty() || bookmark.len() > 65536 {
            return Err("Refreshed OS bookmark has an invalid size".into());
        }
        Ok(Some(Entry { bookmark, directory: entry.directory }))
    }
    pub fn preserve(file: &Path, pid: u32) -> Result<Option<PathBuf>, String> {
        for n in 0..128 {
            let backup = file.with_file_name(format!("security-scoped-bookmarks.corrupt-{pid}-{n}.json"));
            match std::fs::hard_link(file, &backup) {
                Ok(()) => return Ok(Some(backup)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(format!("Cannot preserve damaged bookmark store: {e}; original is unchanged")),
            }
        }
        Err("No unused damaged-bookmark backup name is available; original is unchanged".into())
    }
    pub fn mapped(path: &Path, old: &Path, current: &Path, directory: bool) -> Option<PathBuf> {
        if !valid_path(path) || !valid_path(old) || !valid_path(current) {
            return None;
        }
        if path == old {
            Some(current.to_path_buf())
        } else if directory {
            path.strip_prefix(old).ok().map(|suffix| current.join(suffix))
        } else {
            None
        }
    }
}

#[cfg(all(target_os = "macos", feature = "mac-app-store"))]
mod imp {
    use super::{store::*, *};
    use apple_scoped_bookmarks::{Bookmark, ScopedAccess};
    use std::collections::{BTreeMap, BTreeSet};
    use std::io::{Read, Write};
    use std::sync::{Mutex, OnceLock};
    struct Live {
        access: ScopedAccess,
        directory: bool,
    }
    #[derive(Default)]
    struct Registry {
        name: Option<String>,
        file: Option<PathBuf>,
        data: Store,
        live: BTreeMap<String, Live>,
        pending: BTreeSet<PathBuf>,
        errors: Vec<String>,
        blocked: bool,
    }
    fn registry() -> &'static Mutex<Registry> {
        static VALUE: OnceLock<Mutex<Registry>> = OnceLock::new();
        VALUE.get_or_init(|| Mutex::new(Registry::default()))
    }
    fn lock() -> std::sync::MutexGuard<'static, Registry> {
        registry().lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
    fn help(path: &Path, error: impl std::fmt::Display) -> String {
        format!("Cannot restore access to {}: {error}. Choose the file or its containing folder again with File > Open.", path.display())
    }
    fn internal(path: &Path, state: &Registry) -> bool {
        state
            .name
            .as_deref()
            .and_then(container_dir)
            .and_then(|d| d.ancestors().nth(3).map(Path::to_path_buf))
            .is_some_and(|home| path.starts_with(home))
    }
    fn persist(state: &Registry) -> Result<(), String> {
        if state.blocked {
            return Err("The existing bookmark store is damaged and unchanged. Choose a file or folder again; the damaged store will be preserved separately before new access is saved.".into());
        }
        let file = state.file.as_ref().ok_or("App Store file access has not been initialized")?;
        let parent = file.parent().ok_or("bookmark store has no parent")?;
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let bytes = encode(&state.data)?;
        for number in 0..32 {
            let temp = parent.join(format!(".bookmarks-{}-{number}.tmp", std::process::id()));
            let mut opts = std::fs::OpenOptions::new();
            opts.write(true).create_new(true);
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
            let mut output = match opts.open(&temp) {
                Ok(f) => f,
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.to_string()),
            };
            let result = output.write_all(&bytes).and_then(|_| output.sync_all()).and_then(|_| std::fs::rename(&temp, file));
            if result.is_err() {
                let _ = std::fs::remove_file(&temp);
            }
            result.map_err(|e| e.to_string())?;
            std::fs::File::open(parent).and_then(|f| f.sync_all()).map_err(|e| e.to_string())?;
            return Ok(());
        }
        Err("No unused temporary bookmark-store filename is available".into())
    }
    pub fn initialize(name: &str) -> Vec<String> {
        let mut state = lock();
        if let Some(old) = &state.name {
            return if old == name { std::mem::take(&mut state.errors) } else { vec!["Conflicting App Store file-access identity".into()] };
        }
        let Some(dir) = container_dir(name) else {
            return vec!["Cannot locate the App Store container".into()];
        };
        state.name = Some(name.to_owned());
        state.file = Some(dir.join("security-scoped-bookmarks.json"));
        let file = state.file.clone().unwrap_or_default();
        match std::fs::metadata(&file) {
            Ok(meta) if meta.len() > MAX_BYTES as u64 => {
                state.blocked = true;
                state.errors.push("Bookmark store is oversized and has been preserved".into());
            }
            Ok(_) => match std::fs::File::open(&file)
                .and_then(|f| {
                    let mut b = Vec::new();
                    f.take(MAX_BYTES as u64 + 1).read_to_end(&mut b)?;
                    Ok(b)
                })
                .map_err(|e| e.to_string())
                .and_then(|b| decode(&b))
            {
                Ok(data) => state.data = data,
                Err(e) => {
                    state.blocked = true;
                    state.errors.push(format!("{e}; the original store is preserved"));
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                state.blocked = true;
                state.errors.push(format!("Cannot read bookmark store: {e}; original preserved"));
            }
        }
        let entries = state.data.entries.clone();
        let mut changed = false;
        for (old, entry) in entries {
            match Bookmark::from_bytes(entry.bookmark.clone()).resolve() {
                Ok(access) if valid_path(access.path()) => {
                    // The captured access guard remains alive during stale refresh and persistence.
                    match refreshed(&entry, access.is_stale(), || {
                        Bookmark::create(access.path()).map(Bookmark::into_bytes).map_err(|e| help(access.path(), e))
                    }) {
                        Ok(Some(fresh)) => {
                            state.data.entries.insert(old.clone(), fresh);
                            changed = true;
                        }
                        Ok(None) => {}
                        Err(e) => state.errors.push(e),
                    }
                    state.live.insert(old, Live { access, directory: entry.directory });
                }
                Ok(_) => state.errors.push(help(Path::new(&old), "bookmark resolved to an invalid path")),
                Err(e) => state.errors.push(help(Path::new(&old), e)),
            }
        }
        if changed && let Err(e) = persist(&state) {
            state.errors.push(e);
        }
        std::mem::take(&mut state.errors)
    }
    fn preserve_damaged(state: &mut Registry) -> Result<(), String> {
        if !state.blocked {
            return Ok(());
        }
        let file = state.file.as_ref().ok_or("Bookmark store has no location")?;
        let backup = preserve(file, std::process::id())?;
        state.blocked = false;
        if let Some(backup) = backup {
            state
                .errors
                .push(format!("Damaged bookmark store preserved at {}. Access selected now will be saved in a fresh store.", backup.display()));
        }
        Ok(())
    }
    pub fn directory_granted(path: &Path) -> bool {
        let state = lock();
        valid_path(path) && (internal(path, &state) || state.live.values().any(|v| v.directory && path.starts_with(v.access.path())))
    }
    fn grant(state: &mut Registry, path: &Path) -> Result<PathBuf, String> {
        if internal(path, state) || state.live.values().any(|v| v.directory && path.starts_with(v.access.path())) {
            return Ok(path.to_path_buf());
        }
        let key = path.to_str().ok_or("File path is not valid Unicode")?.to_owned();
        if !state.live.contains_key(&key) && state.live.len() >= LIVE_LIMIT {
            return Err(
                "This launch has reached its file-access limit. Save work, then restart; select containing folders to avoid individual-file grants."
                    .into(),
            );
        }
        let bookmark = Bookmark::create(path).map_err(|e| help(path, e))?;
        if bookmark.as_bytes().is_empty() || bookmark.as_bytes().len() > 65536 {
            return Err(help(path, "the OS bookmark exceeds the supported size"));
        }
        let access = bookmark.resolve().map_err(|e| help(path, e))?;
        if !valid_path(access.path()) {
            return Err(help(path, "invalid resolved path"));
        }
        let resolved = access.path().to_path_buf();
        let directory = resolved.is_dir();
        let original = state.data.entries.clone();
        if directory {
            // Only the folder the user explicitly selected may consolidate descendant grants.
            // Existing live guards are retained for active documents and workers.
            let covered: Vec<String> =
                state.live.iter().filter(|(_, v)| v.access.path().starts_with(&resolved)).map(|(old, _)| old.clone()).collect();
            for old in covered {
                state.data.entries.remove(&old);
            }
            state.data.entries.retain(|old, _| !Path::new(old).starts_with(path));
        }
        state.data.entries.insert(key.clone(), Entry { bookmark: bookmark.into_bytes(), directory });
        state.live.insert(key, Live { access, directory });
        let saved = preserve_damaged(state).and_then(|_| persist(state));
        if let Err(e) = saved {
            state.data.entries = original;
            state.errors.push(format!("File access is available for this launch, but could not be saved: {e}"));
        }
        Ok(resolved)
    }
    pub fn selected(path: &Path, save: bool) -> Result<PathBuf, String> {
        if !valid_path(path) {
            return Err(help(path, "choose an absolute file path without parent traversal"));
        }
        let mut state = lock();
        if state.name.is_none() {
            return Err("App Store file access has not been initialized".into());
        }
        if save && !path.exists() {
            if state.pending.len() >= LIMIT {
                return Err("Too many pending save destinations; save work and restart".into());
            }
            state.pending.insert(path.to_path_buf());
            return Ok(path.to_path_buf());
        }
        grant(&mut state, path)
    }
    pub fn resolve(path: &Path) -> Result<PathBuf, String> {
        if !valid_path(path) {
            return Err(help(path, "invalid file path"));
        }
        let state = lock();
        if let Some(live) = state.live.get(&path.to_string_lossy().into_owned()) {
            return Ok(live.access.path().to_path_buf());
        }
        let mut folders: Vec<_> = state.live.iter().filter(|(_, live)| live.directory).collect();
        folders.sort_by_key(|(old, _)| std::cmp::Reverse(old.len()));
        for (old, live) in folders {
            if let Some(path) = mapped(path, Path::new(old), live.access.path(), true) {
                return Ok(path);
            }
        }
        if state.data.entries.contains_key(&path.to_string_lossy().into_owned()) {
            return Err(help(path, "the stored bookmark was denied"));
        }
        Ok(path.to_path_buf())
    }
    pub fn after_write(path: &Path) -> Result<(), String> {
        let mut state = lock();
        let aliases: Vec<String> = state.live.iter().filter(|(_, live)| live.access.path() == path).map(|(old, _)| old.clone()).collect();
        if state.pending.contains(path) || !aliases.is_empty() {
            let resolved = grant(&mut state, path)?;
            let key = resolved.to_string_lossy().into_owned();
            if let Some(entry) = state.data.entries.get(&key).cloned() {
                for alias in aliases {
                    state.data.entries.insert(alias, entry.clone());
                }
            }
            state.pending.remove(path);
            if let Err(e) = persist(&state) {
                state.errors.push(e);
            }
        }
        Ok(())
    }
    pub fn poll() -> Vec<String> {
        let pending: Vec<PathBuf> = { lock().pending.iter().filter(|p| p.is_file() || p.is_dir()).cloned().collect() };
        for path in pending {
            if let Err(e) = after_write(&path) {
                report(e);
            }
        }
        std::mem::take(&mut lock().errors)
    }
    pub fn report(error: String) {
        let mut state = lock();
        if state.errors.len() < 64 && !state.errors.contains(&error) {
            state.errors.push(error);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::store::*;
    use std::path::{Path, PathBuf};

    fn native_path(relative: &str) -> PathBuf {
        let path = std::env::current_dir().unwrap().join(relative);
        assert!(path.is_absolute());
        path
    }

    #[test]
    fn corrupt_or_unsupported_store_is_rejected_without_replacement() {
        let path = native_path("a");
        let key = path.to_str().unwrap();
        let valid = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "entries": { (key): { "bookmark": [1], "directory": false } }
        }))
        .unwrap();
        assert!(decode(&valid).is_ok());
        let empty = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "entries": { (key): { "bookmark": [], "directory": false } }
        }))
        .unwrap();
        for bytes in [
            b"bad".as_slice(),
            br#"{"version":2,"entries":{}}"#,
            br#"{"version":1,"entries":{"relative":{"bookmark":[1],"directory":false}}}"#,
            empty.as_slice(),
        ] {
            assert!(decode(bytes).is_err());
        }
    }
    #[test]
    fn duplicate_bookmark_paths_are_rejected_instead_of_silently_replaced() {
        let path = native_path("a");
        let key = serde_json::to_string(path.to_str().unwrap()).unwrap();
        let first = r#"{"bookmark":[1],"directory":false}"#;
        let second = r#"{"bookmark":[2],"directory":true}"#;
        let first_only = format!(r#"{{"version":1,"entries":{{{key}:{first}}}}}"#);
        let second_only = format!(r#"{{"version":1,"entries":{{{key}:{second}}}}}"#);
        assert!(decode(first_only.as_bytes()).is_ok());
        assert!(decode(second_only.as_bytes()).is_ok());
        let bytes = format!(r#"{{"version":1,"entries":{{{key}:{first},{key}:{second}}}}}"#);
        assert!(decode(bytes.as_bytes()).is_err());
    }
    #[test]
    fn bookmark_payload_round_trips_exactly() {
        let path = native_path("old/doc");
        let key = path.to_str().unwrap();
        let bytes = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "entries": { (key): { "bookmark": [0, 1, 255], "directory": false } }
        }))
        .unwrap();
        let data = decode(&bytes).unwrap();
        assert_eq!(data.entries[key].bookmark, [0, 1, 255]);
        let encoded = serde_json::to_vec(&data).unwrap();
        assert_eq!(decode(&encoded).unwrap().entries[key].bookmark, [0, 1, 255]);
    }
    #[test]
    fn moved_files_and_folders_use_resolved_paths_without_expanding_file_grants() {
        let old_file = native_path("old/a");
        let new_file = native_path("new/a");
        let old_folder = native_path("old/folder");
        let new_folder = native_path("new/folder");
        assert!(old_file.extension().is_none());
        assert!(new_file.extension().is_none());
        assert_eq!(mapped(&old_file, &old_file, &new_file, false).unwrap(), new_file);
        assert_eq!(mapped(&old_folder.join("sub/a"), &old_folder, &new_folder, true).unwrap(), new_folder.join("sub/a"));
        let file_child = old_file.join("child");
        let folderish = native_path("old/folderish/a");
        assert!(valid_path(&file_child));
        assert!(valid_path(&folderish));
        assert!(mapped(&file_child, &old_file, &new_file, false).is_none());
        assert!(mapped(&folderish, &old_folder, &new_folder, true).is_none());
    }
    #[test]
    fn invalid_resolved_paths_and_traversal_are_rejected() {
        let traversal = native_path("old/../escape");
        assert!(traversal.components().any(|c| matches!(c, std::path::Component::ParentDir)));
        for path in [Path::new(""), Path::new("relative"), traversal.as_path()] {
            assert!(!valid_path(path));
        }
        let old_file = native_path("old/a");
        assert!(valid_path(&old_file));
        assert!(mapped(&old_file, &old_file, Path::new(""), false).is_none());
    }
    #[test]
    fn unsigned_or_wrong_bundle_home_is_never_a_container() {
        let home = native_path("Users/test/Library/Containers/ch.mixel.photo/Data");
        assert!(super::sandbox_home(&home, "ch.mixel.photo"));
        let traversal = native_path("Users/test/../test/Library/Containers/ch.mixel.photo/Data");
        assert!(traversal.components().any(|c| matches!(c, std::path::Component::ParentDir)));
        for path in [
            native_path("Users/test"),
            native_path("Users/test/Library/Containers/other/Data"),
            native_path("tmp/Data"),
            home.join("..").join("Data"),
            traversal,
        ] {
            assert!(!super::sandbox_home(&path, "ch.mixel.photo"));
        }
    }
    #[test]
    fn stale_refresh_is_conditional_and_failures_preserve_old_payload() {
        let entry = Entry { bookmark: vec![1, 2], directory: true };
        assert!(refreshed(&entry, false, || panic!("fresh bookmark must not be recreated")).unwrap().is_none());
        assert_eq!(refreshed(&entry, true, || Ok(vec![3, 4])).unwrap().unwrap().bookmark, [3, 4]);
        assert!(refreshed(&entry, true, || Err("OS denied refresh".into())).is_err());
        assert!(refreshed(&entry, true, || Ok(vec![])).is_err());
        assert_eq!(entry.bookmark, [1, 2]);
    }
    #[test]
    fn persistence_encoding_rejects_oversized_bookmarks_before_writing() {
        let path = native_path("picked");
        let key = path.to_str().unwrap();
        let mut data = Store::default();
        data.entries.insert(key.into(), Entry { bookmark: vec![1, 2], directory: false });
        assert_eq!(decode(&encode(&data).unwrap()).unwrap().entries[key].bookmark, [1, 2]);
        data.entries.get_mut(key).unwrap().bookmark = vec![1; 65537];
        assert!(encode(&data).is_err());
        data.entries.get_mut(key).unwrap().bookmark = vec![1, 2];
        assert_eq!(decode(&encode(&data).unwrap()).unwrap().entries[key].bookmark, [1, 2]);
    }
    #[test]
    fn corrupt_store_backup_remains_exact_after_canonical_replacement() {
        let root = std::env::temp_dir().join(format!("mixel-bookmark-preserve-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("bookmarks.json");
        std::fs::write(&file, b"damaged original").unwrap();
        let backup = preserve(&file, std::process::id()).unwrap().unwrap();
        let next = root.join("new.json");
        std::fs::write(&next, b"new valid store").unwrap();
        std::fs::rename(&next, &file).unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), b"damaged original");
        assert_eq!(std::fs::read(&file).unwrap(), b"new valid store");
        std::fs::remove_file(&backup).unwrap();
        std::fs::remove_file(&file).unwrap();
        std::fs::remove_dir(&root).unwrap();
    }
    #[test]
    fn oversized_store_is_rejected() {
        assert!(decode(&vec![b' '; MAX_BYTES + 1]).is_err());
    }
}
