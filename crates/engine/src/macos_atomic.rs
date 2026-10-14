//! Atomic App Sandbox publication through Foundation's same-volume replacement directory.
//! The OS grants the private staging location; a file grant never becomes a parent grant.
#![forbid(unsafe_code)]

use objc2_foundation::{NSFileManager, NSFileManagerItemReplacementOptions, NSSearchPathDirectory, NSSearchPathDomainMask, NSString, NSURL};
use std::fs::{File, Metadata, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

fn failure(error: impl std::fmt::Display) -> io::Error {
    io::Error::other(error.to_string())
}
fn unicode(path: &Path) -> io::Result<&str> {
    path.to_str().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "The save path is not valid Unicode"))
}
fn state(path: &Path) -> io::Result<Option<Metadata>> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_file() => {
            Err(io::Error::new(io::ErrorKind::InvalidInput, "Select a regular file or choose a new file name for the save destination"))
        }
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}
fn same_state(old: &Metadata, current: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    old.dev() == current.dev()
        && old.ino() == current.ino()
        && old.len() == current.len()
        && old.mtime() == current.mtime()
        && old.mtime_nsec() == current.mtime_nsec()
        && old.ctime() == current.ctime()
        && old.ctime_nsec() == current.ctime_nsec()
}

/// A streaming file whose final destination stays untouched until commit succeeds.
#[derive(Debug)]
pub struct StagedFile {
    file: File,
    directory: PathBuf,
    staged: PathBuf,
    target: PathBuf,
    original: Option<Metadata>,
    preserve: bool,
}
impl StagedFile {
    pub fn new(target: &Path) -> io::Result<Self> {
        if !target.is_absolute() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "Choose an absolute save destination"));
        }
        let original = state(target)?;
        let target_url = NSURL::fileURLWithPath(&NSString::from_str(unicode(target)?));
        let directory_url = NSFileManager::defaultManager()
            .URLForDirectory_inDomain_appropriateForURL_create_error(
                NSSearchPathDirectory::ItemReplacementDirectory,
                NSSearchPathDomainMask::UserDomainMask,
                Some(&target_url),
                true,
            )
            .map_err(failure)?;
        let directory = PathBuf::from(directory_url.path().ok_or_else(|| failure("The replacement directory has no filesystem path"))?.to_string());
        if !directory.is_absolute() {
            return Err(failure("The replacement directory is not absolute"));
        }
        let staged = directory.join("mixel-save-stage");
        let file = match OpenOptions::new().create_new(true).read(true).write(true).mode(0o600).open(&staged) {
            Ok(file) => file,
            Err(error) => {
                let _ = std::fs::remove_dir(&directory);
                return Err(error);
            }
        };
        Ok(Self { file, directory, staged, target: target.to_path_buf(), original, preserve: false })
    }
    pub fn file_mut(&mut self) -> &mut File {
        &mut self.file
    }
    pub fn staged_path(&self) -> &Path {
        &self.staged
    }
    pub fn target_path(&self) -> &Path {
        &self.target
    }
    /// Sync complete bytes and reject target changes detected before publishing on the same volume.
    /// A failed Foundation publication retains its owned staging directory for recovery.
    pub fn commit(self) -> io::Result<PathBuf> {
        self.commit_with_sync(true)
    }
    /// `sync=false` is only for outputs that can always be recreated, such as exported previews.
    pub fn commit_with_sync(mut self, sync: bool) -> io::Result<PathBuf> {
        self.file.flush()?;
        if let Some(original) = &self.original {
            self.file.set_permissions(original.permissions())?;
        }
        if sync {
            self.file.sync_all()?;
        }
        let current = state(&self.target)?;
        match (&self.original, &current) {
            (Some(old), Some(now)) if same_state(old, now) => {}
            (None, None) => {}
            (None, Some(_)) => return Err(io::Error::new(io::ErrorKind::AlreadyExists, "A file appeared at the save destination; it was preserved")),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "The destination changed while saving; it was preserved. Save again or choose another destination",
                ));
            }
        }
        let manager = NSFileManager::defaultManager();
        let target = NSURL::fileURLWithPath(&NSString::from_str(unicode(&self.target)?));
        let staged = NSURL::fileURLWithPath(&NSString::from_str(unicode(&self.staged)?));
        // Foundation can report an original-item recovery location on rare replacement errors.
        // Never delete that directory after a publication attempt fails.
        self.preserve = true;
        let mut resulting = None;
        let result = if self.original.is_some() {
            manager.replaceItemAtURL_withItemAtURL_backupItemName_options_resultingItemURL_error(
                &target,
                &staged,
                None,
                NSFileManagerItemReplacementOptions::UsingNewMetadataOnly,
                Some(&mut resulting),
            )
        } else {
            manager.moveItemAtURL_toURL_error(&staged, &target)
        };
        result.map_err(|error| failure(format!("Atomic save failed: {error:?}. Recovery staging is retained at {}", self.directory.display())))?;
        let final_path = resulting.and_then(|url| url.path()).map(|path| PathBuf::from(path.to_string())).unwrap_or_else(|| self.target.clone());
        // Only remove the newly allocated directory if it is empty. Never traverse/delete it.
        let _ = std::fs::remove_dir(&self.directory);
        Ok(final_path)
    }
}
impl Drop for StagedFile {
    fn drop(&mut self) {
        if !self.preserve {
            let _ = std::fs::remove_file(&self.staged);
            let _ = std::fs::remove_dir(&self.directory);
        }
    }
}
impl Write for StagedFile {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.file.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}
impl Read for StagedFile {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.file.read(bytes)
    }
}
impl Seek for StagedFile {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        self.file.seek(position)
    }
}

pub fn write_with<T>(path: &Path, fill: impl FnOnce(&mut File) -> io::Result<T>) -> io::Result<(T, PathBuf)> {
    write_with_sync(path, true, fill)
}
pub fn write_with_sync<T>(path: &Path, sync: bool, fill: impl FnOnce(&mut File) -> io::Result<T>) -> io::Result<(T, PathBuf)> {
    let mut staged = StagedFile::new(path)?;
    let value = fill(staged.file_mut())?;
    let path = staged.commit_with_sync(sync)?;
    Ok((value, path))
}
pub fn write(path: &Path, bytes: &[u8]) -> io::Result<PathBuf> {
    write_with(path, |file| file.write_all(bytes)).map(|(_, path)| path)
}
