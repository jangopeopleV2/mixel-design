//! Begin AppKit sheets on main, after the event loop and a real parent are available.
use designcraft_ui_egui::{NativePick, PickAnswer};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, channel};

pub type Busy = Arc<AtomicBool>;
type Answer = Pin<Box<dyn Future<Output = PickAnswer> + Send>>;

struct Claim(Busy);
impl Drop for Claim {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

pub fn running() -> bool {
    objc2::MainThreadMarker::new().is_some_and(|main| objc2_app_kit::NSApplication::sharedApplication(main).isRunning())
}

pub fn start(
    request: NativePick,
    parent: Option<&rfd::AsyncFileDialog>,
    busy: &Busy,
    context: egui::Context,
) -> Result<Receiver<PickAnswer>, String> {
    if !running() {
        return Err("The app window is not ready for file selection. Try again from the app window.".into());
    }
    let mut dialog = parent.cloned().ok_or("No app window is available for file selection")?;
    if busy.swap(true, Ordering::SeqCst) {
        return Err("Another file dialog is open. Finish it before choosing another file.".into());
    }
    let claim = Claim(busy.clone());
    let (future_tx, future_rx) = channel::<Answer>();
    let (answer_tx, answer_rx) = channel();
    // Start the receiver before opening a sheet, so failure cannot strand an unanswered panel.
    std::thread::Builder::new()
        .name("design-file-sheet".into())
        .spawn(move || {
            if let Ok(answer) = future_rx.recv() {
                let result = pollster::block_on(answer);
                drop(claim);
                let _ = answer_tx.send(result);
                context.request_repaint();
            }
        })
        .map_err(|error| format!("Cannot start the file chooser: {error}"))?;
    let save = matches!(&request, NativePick::Save(_));
    let picked = move |handle: Option<rfd::FileHandle>| {
        handle.map(|handle| designcraft_engine::macos_mas::selected(handle.path(), save).map(|path| path.to_string_lossy().into_owned())).transpose()
    };
    // rfd constructs ModalFuture here and immediately begins the sheet. Only awaiting moves.
    let answer: Answer = match request {
        NativePick::Open(purpose) => {
            for filter in crate::open_filters(&purpose) {
                dialog = dialog.add_filter(filter.name, filter.extensions);
            }
            let future = dialog.pick_file();
            Box::pin(async move { picked(future.await) })
        }
        NativePick::Save(name) => {
            let future = dialog.set_file_name(name).save_file();
            Box::pin(async move { picked(future.await) })
        }
        NativePick::Folder { title, initial } => {
            dialog = dialog.set_title(title);
            if let Some(initial) = initial {
                dialog = dialog.set_directory(initial);
            }
            let future = dialog.pick_folder();
            Box::pin(async move { picked(future.await) })
        }
    };
    future_tx.send(answer).map_err(|_| "The file chooser stopped before it could answer".to_owned())?;
    Ok(answer_rx)
}
