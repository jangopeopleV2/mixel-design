//! Host-owned native panels, with UI continuations that run after the sheet closes.
use serde_json::{Value, json};
use std::sync::mpsc::{Receiver, TryRecvError};

use crate::DesignApp;

#[derive(Clone, Debug)]
pub enum NativePick {
    Open(String),
    Save(String),
    Folder { title: String, initial: Option<String> },
}

pub type PickAnswer = Result<Option<String>, String>;
pub type AsyncPicker = Box<dyn FnMut(NativePick) -> Result<Receiver<PickAnswer>, String>>;
type Then = Box<dyn FnOnce(&mut DesignApp, String) -> Result<Value, String>>;

struct Target {
    uid: u64,
    revision: u64,
    selection: designcraft_doc::selection::Selection,
}

pub(crate) struct Pending {
    receiver: Receiver<PickAnswer>,
    target: Option<Target>,
    then: Then,
}

impl DesignApp {
    pub(crate) fn native_pick_targets(&self, uid: u64) -> bool {
        self.pending_pick.as_ref().and_then(|pending| pending.target.as_ref()).is_some_and(|target| target.uid == uid)
    }
    /// Ordinary hosts retain their synchronous picker; MAS hosts must install the async service.
    pub(crate) fn ask_open(
        &mut self,
        purpose: &str,
        then: impl FnOnce(&mut Self, String) -> Result<Value, String> + 'static,
    ) -> Result<Value, String> {
        self.ask_native(NativePick::Open(purpose.into()), Box::new(then))
    }

    pub(crate) fn ask_save(&mut self, name: &str, then: impl FnOnce(&mut Self, String) -> Result<Value, String> + 'static) -> Result<Value, String> {
        self.ask_native(NativePick::Save(name.into()), Box::new(then))
    }

    pub(crate) fn ask_folder(
        &mut self,
        title: &str,
        initial: Option<String>,
        then: impl FnOnce(&mut Self, String) -> Result<Value, String> + 'static,
    ) -> Result<Value, String> {
        self.ask_native(NativePick::Folder { title: title.into(), initial }, Box::new(then))
    }

    fn ask_native(&mut self, request: NativePick, then: Then) -> Result<Value, String> {
        let result = self.begin_native_pick(request, then);
        if let Err(error) = &result {
            self.status(error);
        }
        result
    }

    fn begin_native_pick(&mut self, request: NativePick, then: Then) -> Result<Value, String> {
        if self.pending_pick.is_some() {
            let error = "Another file dialog is open. Finish it before choosing another file.".to_owned();
            self.status(&error);
            return Err(error);
        }
        if let Some(pick) = self.services.pick_native.as_mut() {
            let receiver = pick(request)?;
            let target = self.session.active().map(|d| Target { uid: d.uid, revision: d.revision, selection: d.selection.clone() });
            self.pending_pick = Some(Pending { receiver, target, then });
            return Ok(json!({"dialog": "nativeFilePicker"}));
        }
        // Existing unit fixtures inject synchronous Rust closures, never AppKit. Strict-host
        // tests set the same flag as the real MAS desktop, so that path cannot fall back.
        if self.require_native_async || (designcraft_engine::macos_mas::enabled() && !cfg!(test)) {
            return Err("The app window is not ready for native file selection. Try again from the app window.".into());
        }
        let path = match request {
            NativePick::Open(purpose) => self.services.pick_open.as_mut().and_then(|pick| pick(&purpose)),
            NativePick::Save(name) => self.services.pick_save.as_mut().and_then(|pick| pick(&name)),
            NativePick::Folder { .. } => return Err("No folder picker is available".into()),
        };
        match path {
            Some(path) => then(self, path),
            None => Ok(Value::Null),
        }
    }

    pub(crate) fn drain_native_pick(&mut self) {
        let Some(pending) = self.pending_pick.take() else { return };
        let answer = match pending.receiver.try_recv() {
            Ok(answer) => answer,
            Err(TryRecvError::Empty) => {
                self.pending_pick = Some(pending);
                return;
            }
            Err(TryRecvError::Disconnected) => Err("The file chooser stopped before it could answer. Try again from the app window.".into()),
        };
        let answer = match answer {
            Ok(Some(path)) => path,
            Ok(None) => {
                self.cancel_quit();
                return;
            }
            Err(error) => {
                self.cancel_quit();
                self.status(error);
                return;
            }
        };
        let unchanged = match pending.target {
            Some(target) => {
                self.session.active().is_some_and(|d| d.uid == target.uid && d.revision == target.revision && d.selection == target.selection)
            }
            None => self.session.active().is_none(),
        };
        if !unchanged {
            self.cancel_quit();
            self.status("File selection cancelled because the originating document or selection changed. Try again.");
            return;
        }
        if let Err(error) = (pending.then)(self, answer) {
            self.cancel_quit();
            self.status(error);
        }
    }

    /// Save before running a dependent close/quit operation. A cancelled or failed save runs none.
    pub(crate) fn save_active_then(&mut self, then: impl FnOnce(&mut Self) -> Result<Value, String> + 'static) -> Result<Value, String> {
        if self.services.download.is_some() || self.session.active().is_some_and(|d| d.path.is_some()) {
            self.run("app.save", json!({}))?;
            if self.session.active().is_some_and(|d| !d.is_dirty()) {
                return then(self);
            }
            return Ok(Value::Null);
        }
        let name = self.session.active().map(|d| format!("{}.designcraft", d.doc.title)).ok_or("No document to save")?;
        self.ask_save(&name, move |app, path| {
            app.run("file.saveAs", json!({"path": path}))?;
            if app.session.active().is_some_and(|d| !d.is_dirty()) { then(app) } else { Ok(Value::Null) }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;
    use std::sync::mpsc::{Sender, channel};

    fn queued_app() -> (DesignApp, Sender<PickAnswer>) {
        let mut app = DesignApp::new(designcraft_engine::Session::new(), crate::Services::default());
        app.run("file.new", json!({"title": "Before"})).unwrap();
        app.run("frame.create", json!({"rect": [10, 10, 60, 60]})).unwrap();
        app.require_async_file_dialogs();
        let (sender, receiver) = channel();
        let mut receiver = Some(receiver);
        app.services.pick_native = Some(Box::new(move |_| receiver.take().ok_or_else(|| "No fixture answer remains".into())));
        (app, sender)
    }

    #[test]
    fn strict_host_never_calls_synchronous_fallback_and_failed_start_keeps_document() {
        let (mut app, _sender) = queued_app();
        app.services.pick_native = None;
        let called = Rc::new(Cell::new(false));
        let flag = called.clone();
        app.services.pick_save = Some(Box::new(move |_| {
            flag.set(true);
            Some("wrong.designcraft".into())
        }));
        assert!(app.run("app.saveDialog", json!({})).is_err());
        assert!(!called.get());
        assert!(app.session.active().unwrap().is_dirty());
        assert!(app.pending_pick.is_none());
    }

    #[test]
    fn queued_answer_runs_once_on_a_later_frame_and_a_second_request_cannot_replace_it() {
        let (mut app, sender) = queued_app();
        let count = Rc::new(Cell::new(0));
        let writes = count.clone();
        app.ask_save("chosen.txt", move |_, path| {
            assert_eq!(path, "chosen.txt");
            writes.set(writes.get() + 1);
            Ok(Value::Null)
        })
        .unwrap();
        app.drain_native_pick();
        assert_eq!(count.get(), 0);
        assert!(app.ask_open("open", |_, _| Err("must not run".into())).is_err());
        sender.send(Ok(Some("chosen.txt".into()))).unwrap();
        assert_eq!(count.get(), 0);
        app.drain_native_pick();
        app.drain_native_pick();
        assert_eq!(count.get(), 1);
        assert!(app.pending_pick.is_none());
    }

    #[test]
    fn cancellation_error_and_disconnect_release_the_claim_without_running_continuation() {
        for failure in 0..3 {
            let (mut app, sender) = queued_app();
            let called = Rc::new(Cell::new(false));
            let flag = called.clone();
            app.ask_open("place", move |_, _| {
                flag.set(true);
                Ok(Value::Null)
            })
            .unwrap();
            match failure {
                0 => sender.send(Ok(None)).unwrap(),
                1 => sender.send(Err("Bookmark access denied".into())).unwrap(),
                _ => {}
            }
            drop(sender);
            app.drain_native_pick();
            assert!(!called.get());
            assert!(app.pending_pick.is_none());
            assert!(app.session.active().unwrap().is_dirty());
            if failure > 0 {
                assert!(!app.ui.status.is_empty());
            }
        }
    }

    #[test]
    fn changed_target_revision_or_selection_cannot_receive_a_stale_choice() {
        for drift in 0..3 {
            let (mut app, sender) = queued_app();
            let called = Rc::new(Cell::new(false));
            let flag = called.clone();
            app.ask_open("place", move |_, _| {
                flag.set(true);
                Ok(Value::Null)
            })
            .unwrap();
            match drift {
                0 => {
                    app.run("file.new", json!({})).unwrap();
                }
                1 => {
                    app.run("frame.create", json!({"rect": [70, 70, 90, 90]})).unwrap();
                }
                _ => {
                    app.session.doc_mut().unwrap().selection.content = true;
                }
            }
            sender.send(Ok(Some("chosen.png".into()))).unwrap();
            app.drain_native_pick();
            assert!(!called.get());
            assert!(app.ui.status.contains("changed"));
        }
    }

    #[test]
    fn close_waits_for_successful_save_and_cancel_or_write_failure_preserves_the_document() {
        for outcome in 0..3 {
            let (mut app, sender) = queued_app();
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("saved.designcraft");
            if outcome == 2 {
                std::fs::create_dir(&path).unwrap();
            }
            crate::menus::close_document(&mut app, None);
            crate::dialogs::confirm(&mut app).unwrap();
            assert_eq!(app.session.documents().len(), 1);
            assert!(app.session.active().unwrap().is_dirty());
            assert!(app.pending_pick.is_some());
            sender.send(Ok((outcome != 1).then(|| path.to_string_lossy().into_owned()))).unwrap();
            app.drain_native_pick();
            if outcome == 0 {
                assert!(app.session.documents().is_empty());
                let mut reopened = designcraft_engine::Session::new();
                reopened.execute("file.open", &json!({"path": path})).unwrap();
                assert_eq!(reopened.active().unwrap().doc.title, "Before");
            } else {
                assert_eq!(app.session.documents().len(), 1);
                assert!(app.session.active().unwrap().is_dirty());
            }
        }
    }

    #[test]
    fn quit_approval_is_recorded_only_after_save_succeeds_and_cancel_stops_quitting() {
        for cancel in [false, true] {
            let (mut app, sender) = queued_app();
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("saved.designcraft");
            let uid = app.session.active().unwrap().uid;
            app.quitting = Some(crate::QuitState { original_active: Some(uid), accepted: Default::default(), pending: Some(uid) });
            app.confirm_quit_document(uid, false).unwrap();
            app.handle_quit(&egui::Context::default());
            assert!(app.quitting.as_ref().unwrap().accepted.is_empty());
            assert!(app.session.active().unwrap().is_dirty());
            sender.send(Ok((!cancel).then(|| path.to_string_lossy().into_owned()))).unwrap();
            app.drain_native_pick();
            if cancel {
                assert!(app.quitting.is_none());
                assert!(app.session.active().unwrap().is_dirty());
            } else {
                let document = app.session.active().unwrap();
                assert!(!document.is_dirty());
                assert_eq!(app.quitting.as_ref().unwrap().accepted.get(&uid), Some(&document.revision));
                assert_eq!(app.session.documents().len(), 1);
                assert!(path.is_file());
            }
        }
    }
}
