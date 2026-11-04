//! A single-file, loopback-only HTTP endpoint. Native file handles stay on the
//! reader worker; sockets carry bounded binary chunks with backpressure.
use std::{
    collections::HashMap,
    io::{self, Read, Write},
    net::{Shutdown, TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};
use vhdx_core::{Error, Result};
use zeroize::Zeroizing;

const CHUNK: usize = 256 * 1024;
struct Shared {
    closed: AtomicBool,
    sockets: Mutex<HashMap<u64, TcpStream>>,
    active: AtomicUsize,
    next: AtomicU64,
    bytes: AtomicU64,
    requests: AtomicU64,
    ranges: AtomicU64,
}
impl Shared {
    fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        if let Ok(sockets) = self.sockets.lock() {
            for socket in sockets.values() {
                let _ = socket.shutdown(Shutdown::Both);
            }
        }
    }
}
pub(crate) struct Stream {
    shared: Arc<Shared>,
    pub url: String,
}
impl Drop for Stream {
    fn drop(&mut self) {
        self.shared.shutdown();
    }
}
impl Stream {
    pub fn start(context: u64, session: u64, file: u64, size: u64) -> Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0))?;
        listener.set_nonblocking(true)?;
        let host = listener.local_addr()?.to_string();
        let mut token = [0u8; 32];
        getrandom::fill(&mut token)
            .map_err(|_| Error::Invalid("random token generation failed".into()))?;
        let path = format!(
            "/{}/stream",
            token.iter().map(|b| format!("{b:02x}")).collect::<String>()
        );
        let url = format!("http://{host}{path}");
        let shared = Arc::new(Shared {
            closed: AtomicBool::new(false),
            sockets: Mutex::new(HashMap::new()),
            active: AtomicUsize::new(0),
            next: AtomicU64::new(1),
            bytes: AtomicU64::new(0),
            requests: AtomicU64::new(0),
            ranges: AtomicU64::new(0),
        });
        let server = shared.clone();
        thread::Builder::new()
            .name("vhdx-media-http".into())
            .spawn(move || {
                while !server.closed.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((mut socket, peer)) => {
                            if !peer.ip().is_loopback() {
                                continue;
                            }
                            let _ = socket.set_read_timeout(Some(Duration::from_secs(2)));
                            let _ = socket.set_write_timeout(Some(Duration::from_secs(2)));
                            if server.active.fetch_add(1, Ordering::AcqRel) >= 4 {
                                server.active.fetch_sub(1, Ordering::AcqRel);
                                let _ = status(
                                    &mut socket,
                                    "503 Service Unavailable",
                                    "Retry-After: 1\r\n",
                                );
                                continue;
                            }
                            let id = server.next.fetch_add(1, Ordering::Relaxed);
                            let Ok(copy) = socket.try_clone() else {
                                server.active.fetch_sub(1, Ordering::AcqRel);
                                continue;
                            };
                            if let Ok(mut sockets) = server.sockets.lock() {
                                sockets.insert(id, copy);
                            }
                            let shared = server.clone();
                            let host = host.clone();
                            let path = path.clone();
                            let result = thread::Builder::new()
                                .name("vhdx-media-client".into())
                                .spawn(move || {
                                    let _ = serve(
                                        &mut socket,
                                        &host,
                                        &path,
                                        size,
                                        &shared,
                                        |offset, length| {
                                            crate::read_media(
                                                context, session, file, offset, length,
                                            )
                                        },
                                    );
                                    let _ = socket.shutdown(Shutdown::Both);
                                    if let Ok(mut sockets) = shared.sockets.lock() {
                                        sockets.remove(&id);
                                    }
                                    shared.active.fetch_sub(1, Ordering::AcqRel);
                                });
                            if result.is_err() {
                                server.active.fetch_sub(1, Ordering::AcqRel);
                                if let Ok(mut sockets) = server.sockets.lock() {
                                    sockets.remove(&id);
                                }
                            }
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(20))
                        }
                        Err(_) => break,
                    }
                }
            })?;
        Ok(Self { shared, url })
    }
    pub fn stats(&self) -> serde_json::Value {
        serde_json::json!({"bytes":self.shared.bytes.load(Ordering::Relaxed), "requests":self.shared.requests.load(Ordering::Relaxed), "ranges":self.shared.ranges.load(Ordering::Relaxed)})
    }
}

fn status(socket: &mut TcpStream, code: &str, extra: &str) -> io::Result<()> {
    write!(socket, "HTTP/1.1 {code}\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n{extra}\r\n")
}

/// Return inclusive start/end. Unsupported units and multi-ranges are ignored,
/// as allowed by HTTP; malformed or unsatisfiable byte ranges return 416.
fn range(value: Option<&str>, size: u64) -> std::result::Result<Option<(u64, u64)>, ()> {
    let Some(value) = value else {
        return Ok(None);
    };
    let Some(value) = value.strip_prefix("bytes=") else {
        return Ok(None);
    };
    if value.contains(',') {
        return Ok(None);
    }
    let (start, end) = value.split_once('-').ok_or(())?;
    let number = |text: &str| -> std::result::Result<u64, ()> {
        if text.is_empty() || !text.bytes().all(|c| c.is_ascii_digit()) {
            return Err(());
        }
        text.parse().map_err(|_| ())
    };
    if size == 0 {
        return Err(());
    }
    if start.is_empty() {
        let suffix = number(end)?;
        if suffix == 0 {
            return Err(());
        }
        return Ok(Some((size.saturating_sub(suffix), size - 1)));
    }
    let start = number(start)?;
    let end = if end.is_empty() {
        size - 1
    } else {
        number(end)?.min(size - 1)
    };
    if start >= size || end < start {
        return Err(());
    }
    Ok(Some((start, end)))
}

fn serve(
    socket: &mut TcpStream,
    host: &str,
    path: &str,
    size: u64,
    shared: &Shared,
    mut read: impl FnMut(u64, usize) -> Result<Zeroizing<Vec<u8>>>,
) -> io::Result<()> {
    // One request per connection. Limit total header length and slow clients.
    let started = Instant::now();
    let mut raw = Vec::with_capacity(1024);
    while !raw.ends_with(b"\r\n\r\n") {
        if shared.closed.load(Ordering::Acquire) {
            return Ok(());
        }
        if raw.len() >= 8192 || started.elapsed() > Duration::from_secs(5) {
            return status(socket, "431 Request Header Fields Too Large", "");
        }
        let mut byte = [0];
        if socket.read(&mut byte)? == 0 {
            return Ok(());
        }
        raw.push(byte[0]);
    }
    let Ok(header) = std::str::from_utf8(&raw) else {
        return status(socket, "400 Bad Request", "");
    };
    let mut lines = header.split("\r\n");
    let parts = lines.next().unwrap_or("").split(' ').collect::<Vec<_>>();
    if parts.len() != 3 || !["HTTP/1.0", "HTTP/1.1"].contains(&parts[2]) {
        return status(socket, "400 Bad Request", "");
    }
    let mut headers = HashMap::new();
    for line in lines.filter(|s| !s.is_empty()) {
        let Some((name, value)) = line.split_once(':') else {
            return status(socket, "400 Bad Request", "");
        };
        let name = name.to_ascii_lowercase();
        if headers.insert(name, value.trim()).is_some() {
            return status(socket, "400 Bad Request", "");
        }
    }
    if parts[1] != path || headers.get("host") != Some(&host) || headers.contains_key("origin") {
        return status(socket, "404 Not Found", "");
    }
    if !["GET", "HEAD"].contains(&parts[0]) {
        return status(socket, "405 Method Not Allowed", "Allow: GET, HEAD\r\n");
    }
    if headers.contains_key("transfer-encoding")
        || headers.get("content-length").is_some_and(|v| *v != "0")
    {
        return status(socket, "400 Bad Request", "");
    }
    shared.requests.fetch_add(1, Ordering::Relaxed);
    let selection = if parts[0] == "HEAD" || headers.contains_key("if-range") {
        Ok(None)
    } else {
        range(headers.get("range").copied(), size)
    };
    let selection = match selection {
        Ok(value) => value,
        Err(()) => {
            return status(
                socket,
                "416 Range Not Satisfiable",
                &format!("Content-Range: bytes */{size}\r\n"),
            )
        }
    };
    let (start, length, code, extra) = match selection {
        Some((start, end)) => {
            shared.ranges.fetch_add(1, Ordering::Relaxed);
            (
                start,
                end - start + 1,
                "206 Partial Content",
                format!("Content-Range: bytes {start}-{end}/{size}\r\n"),
            )
        }
        None => (0, size, "200 OK", String::new()),
    };
    // Validate the first read before committing a successful GET response.
    let mut first = if length > 0 && parts[0] == "GET" {
        match read(start, length.min(CHUNK as u64) as usize) {
            Ok(bytes) if bytes.len() == length.min(CHUNK as u64) as usize => Some(bytes),
            _ => return status(socket, "503 Service Unavailable", ""),
        }
    } else {
        None
    };
    if shared.closed.load(Ordering::Acquire) {
        return Ok(());
    }
    write!(socket, "HTTP/1.1 {code}\r\nContent-Type: application/octet-stream\r\nContent-Length: {length}\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n{extra}\r\n")?;
    if parts[0] == "HEAD" {
        return Ok(());
    }
    let mut done = 0;
    while done < length && !shared.closed.load(Ordering::Acquire) {
        let wanted = (length - done).min(CHUNK as u64) as usize;
        let bytes = match first
            .take()
            .map(Ok)
            .unwrap_or_else(|| read(start + done, wanted))
        {
            Ok(bytes) if bytes.len() == wanted => bytes,
            _ => break, // Truncated HTTP body signals a read failure to the player.
        };
        if shared.closed.load(Ordering::Acquire) {
            break;
        }
        socket.write_all(&bytes)?;
        shared
            .bytes
            .fetch_add(bytes.len() as u64, Ordering::Relaxed);
        done += bytes.len() as u64;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn byte_ranges_cover_open_suffix_clamp_and_rejection() {
        assert_eq!(range(Some("bytes=2-5"), 10), Ok(Some((2, 5))));
        assert_eq!(range(Some("bytes=2-"), 10), Ok(Some((2, 9))));
        assert_eq!(range(Some("bytes=-3"), 10), Ok(Some((7, 9))));
        assert_eq!(range(Some("bytes=-30"), 10), Ok(Some((0, 9))));
        assert_eq!(range(Some("bytes=7-999"), 10), Ok(Some((7, 9))));
        for invalid in [
            "bytes=10-",
            "bytes=-0",
            "bytes=5-2",
            "bytes=1-a",
            "bytes=18446744073709551616-",
        ] {
            assert_eq!(range(Some(invalid), 10), Err(()));
        }
        assert_eq!(range(Some("bytes=0-"), 0), Err(()));
        assert_eq!(range(Some("bytes=0-1,3-4"), 10), Ok(None));
        assert_eq!(range(Some("items=0-1"), 10), Ok(None));
    }
}
