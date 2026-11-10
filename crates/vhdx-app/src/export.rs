//! Cooperative exports: native reads stay on the reader, target I/O uses one
//! bounded writer per export. A single zeroizing buffer is handed back and forth.
use super::{Request, State, WorkItem};
use serde_json::{json, Value};
use std::{
    fs::File,
    io::Write,
    path::PathBuf,
    sync::mpsc::{self, Receiver, SyncSender, TryRecvError},
    thread,
};
use vhdx_core::{
    session::{Cancellation, File as SourceFile},
    source::duplicate_file_descriptor,
    Error, Result,
};
use zeroize::{Zeroize, Zeroizing};

pub(crate) const MAX_EXPORTS: usize = 4;
pub(crate) const CHUNK: usize = 256 * 1024;

struct Destination {
    file: Option<File>,
    cleanup: Option<PathBuf>,
}
impl Drop for Destination {
    fn drop(&mut self) {
        // Windows cannot remove an open destination.
        self.file.take();
        if let Some(path) = &self.cleanup {
            let _ = std::fs::remove_file(path);
        }
    }
}
struct Completion {
    destination: Destination,
    result: Result<()>,
}
pub(crate) enum Step {
    Waiting,
    Progress,
    Finished(Result<Value>),
}
pub(crate) struct Transfer {
    source: Option<SourceFile>,
    size: u64,
    position: u64,
    pub(crate) cancel: Cancellation,
    revoked: Cancellation,
    send: Option<SyncSender<Zeroizing<Vec<u8>>>>,
    recycled: Receiver<Zeroizing<Vec<u8>>>,
    completed: Receiver<Completion>,
    buffer: Option<Zeroizing<Vec<u8>>>,
    error: Option<Error>,
}
impl Transfer {
    pub(crate) fn start(
        state: &State,
        request: &Request,
        cancel: Cancellation,
        wake: SyncSender<WorkItem>,
    ) -> Result<Self> {
        cancel.check()?;
        if request.session() != Some(state.generation) {
            return Err(Error::Invalid("stale_session".into()));
        }
        let Request::Export {
            path,
            output,
            output_fd,
            ..
        } = request
        else {
            return Err(Error::Invalid("expected export".into()));
        };
        let source = state
            .volume
            .as_ref()
            .ok_or(Error::Locked)?
            .open_file(path)?;
        let size = source.len();
        let destination = Destination {
            file: Some(if let Some(fd) = output_fd {
                duplicate_file_descriptor(*fd)?
            } else {
                File::options().create_new(true).write(true).open(output)?
            }),
            cleanup: output_fd.is_none().then(|| PathBuf::from(output)),
        };
        cancel.check()?;
        let revoked = state.export_revoked.clone();
        let (send, receive) = mpsc::sync_channel::<Zeroizing<Vec<u8>>>(1);
        let (recycle, recycled) = mpsc::sync_channel(1);
        let (done, completed) = mpsc::sync_channel(1);
        let writer_cancel = cancel.clone();
        let writer_revoked = revoked.clone();
        thread::Builder::new()
            .name("vhdx-export-writer".into())
            .spawn(move || {
                let mut destination = destination;
                let result =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
                        while let Ok(mut bytes) = receive.recv() {
                            writer_cancel.check()?;
                            writer_revoked.check()?;
                            destination.file.as_mut().unwrap().write_all(&bytes)?;
                            writer_cancel.check()?;
                            writer_revoked.check()?;
                            bytes.as_mut_slice().zeroize();
                            recycle.try_send(bytes).map_err(|_| Error::Cancelled)?;
                            // If full, existing queued work already wakes the reader.
                            let _ = wake.try_send(WorkItem::ExportReady);
                        }
                        writer_cancel.check()?;
                        writer_revoked.check()?;
                        destination.file.as_ref().unwrap().sync_all()?;
                        writer_cancel.check()?;
                        writer_revoked.check()
                    }))
                    .unwrap_or_else(|_| Err(Error::Invalid("export_writer_panicked".into())));
                destination.file.take();
                // Keep cleanup armed until the reader checks cancellation/revocation
                // and commits success. A dropped receiver also cleans up the file.
                let _ = done.send(Completion {
                    destination,
                    result,
                });
                let _ = wake.try_send(WorkItem::ExportReady);
            })?;
        Ok(Self {
            source: Some(source),
            size,
            position: 0,
            cancel,
            revoked,
            send: Some(send),
            recycled,
            completed,
            buffer: Some(Zeroizing::new(vec![0; CHUNK])),
            error: None,
        })
    }
    fn check(&self) -> Result<()> {
        self.cancel.check()?;
        self.revoked.check()
    }
    fn abort(&mut self, error: Error) {
        if self.error.is_none() {
            self.error = Some(error);
        }
        self.cancel.cancel();
        self.source.take();
        self.send.take();
        self.buffer.take();
    }
    /// Release native handles before acknowledging lock/close/engine teardown.
    pub(crate) fn revoke_if_needed(&mut self) {
        if self.error.is_none() {
            if let Err(error) = self.check() {
                self.abort(error);
            }
        }
    }
    pub(crate) fn step(&mut self) -> Step {
        match self.completed.try_recv() {
            Ok(mut completion) => {
                let result = self
                    .error
                    .take()
                    .map_or(completion.result, Err)
                    .and_then(|()| self.check());
                return Step::Finished(result.map(|()| {
                    completion.destination.cleanup = None;
                    json!({"size": self.position})
                }));
            }
            Err(TryRecvError::Disconnected) => {
                return Step::Finished(Err(self
                    .error
                    .take()
                    .unwrap_or_else(|| Error::Invalid("export_writer_stopped".into()))));
            }
            Err(TryRecvError::Empty) => {}
        }
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.advance()))
            .unwrap_or_else(|_| Err(Error::Invalid("export_reader_panicked".into())));
        match result {
            Ok(step) => step,
            Err(error) => {
                self.abort(error);
                Step::Progress
            }
        }
    }
    fn advance(&mut self) -> Result<Step> {
        if self.error.is_some() {
            return Ok(Step::Waiting);
        }
        self.check()?;
        if self.send.is_none() {
            return Ok(Step::Waiting); // target sync/close is still in flight
        }
        if self.position == self.size {
            self.source.take();
            self.send.take(); // EOF: writer drains the last buffer, then syncs
            self.buffer.take();
            return Ok(Step::Progress);
        }
        if self.buffer.is_none() {
            match self.recycled.try_recv() {
                Ok(buffer) => self.buffer = Some(buffer),
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => {
                    return Ok(Step::Waiting);
                }
            }
        }
        let mut bytes = self.buffer.take().unwrap();
        // The writer erased the recycled buffer before returning ownership.
        let wanted = (self.size - self.position).min(CHUNK as u64) as usize;
        bytes.resize(wanted, 0);
        let n = self
            .source
            .as_ref()
            .unwrap()
            .read_at(self.position, &mut bytes, &self.cancel)?;
        if n == 0 || n > wanted {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "unexpected export EOF",
            )
            .into());
        }
        self.check()?;
        bytes.truncate(n);
        self.send
            .as_ref()
            .unwrap()
            .try_send(bytes)
            .map_err(|_| Error::Cancelled)?;
        self.position += n as u64;
        Ok(Step::Progress)
    }
}
impl Drop for Transfer {
    fn drop(&mut self) {
        self.cancel.cancel();
        self.send.take();
    }
}
