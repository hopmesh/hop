//! # hop-endpoint — a `hops://` origin endpoint (DESIGN.md §30)
//!
//! An operator runs this on their own infrastructure to make their service reachable over
//! Hop. It's a **listening** Hop node (clients dial it directly, so the operator bears the
//! cost of their own traffic — our relay fleet is never a conduit for domain traffic) plus
//! an HTTP translator **bound to one origin**: a `hops://` request carries only a path, and
//! the endpoint executes it against its *own* configured backend. It is never an open proxy.
//!
//! The operator publishes `_hopaddress.<domain>  TXT  <printed-address>` (HNS) and fronts
//! `--listen` with TLS (the LB terminates `wss://<domain>:9444/` → plain `ws` here), exactly
//! like the relay fleet.
//!
//! Usage:
//!   hop-endpoint --listen 0.0.0.0:9444 --origin https://localhost:8080 \
//!                [--identity-file PATH] [--max-resp BYTES]

use std::collections::HashMap;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hop_core::prelude::*;
use tungstenite::Message;

static NEXT_LINK: AtomicU64 = AtomicU64::new(1);

/// Driver events: bearer lifecycle + a completed backend fetch handed back from a worker.
enum Ev {
    Up(u64, Role, Sender<Vec<u8>>),
    Data(u64, Vec<u8>),
    Down(u64),
    /// A finished HTTP fetch: reply (to, for_request_id, status, body).
    Fetched(PubKeyBytes, BundleId, u16, Vec<u8>),
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

fn main() {
    let mut listen = "0.0.0.0:9444".to_string();
    let mut origin: Option<String> = None;
    let mut identity_file: Option<String> = None;
    let mut max_resp: u32 = 8 * 1024 * 1024; // 8 MiB cap on a translated response
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--listen" => listen = args.next().unwrap_or(listen),
            "--origin" => origin = args.next(),
            "--identity-file" => identity_file = args.next(),
            "--max-resp" => max_resp = args.next().and_then(|s| s.parse().ok()).unwrap_or(max_resp),
            other => eprintln!("ignoring unknown arg: {other}"),
        }
    }
    let origin = origin.unwrap_or_else(|| {
        eprintln!("--origin https://your-backend is required (the ONLY host this endpoint serves)");
        std::process::exit(2);
    });
    // Bind to a single origin: scheme://host[:port], no trailing slash. Requests only ever
    // get this prefix + their path — never an arbitrary host (no open proxy).
    let origin = origin.trim_end_matches('/').to_string();

    let identity = load_identity(&identity_file);
    let addr = identity.address();
    let node = Node::new(identity);
    println!("hop-endpoint: address {}", bs58::encode(addr).into_string());
    println!("hop-endpoint: serving origin {origin}");
    println!("hop-endpoint: publish DNS →  _hopaddress.<domain>  TXT  \"{}\"", bs58::encode(addr).into_string());
    println!("hop-endpoint: listening (ws) on {listen}");

    let http = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .expect("http client");

    let (tx, rx) = mpsc::channel::<Ev>();

    // Accept inbound client WebSocket connections (one thread per connection).
    {
        let tx = tx.clone();
        let listener = TcpListener::bind(&listen).expect("bind --listen address");
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let tx = tx.clone();
                std::thread::spawn(move || serve_ws(stream, &tx));
            }
        });
    }

    run(node, origin, http, max_resp, tx, rx);
}

/// The driver: sole owner of the node. Routes outgoing bytes to per-link writers, and on a
/// `hops` request spawns a worker to fetch the origin, replying when it returns.
fn run(
    mut node: Node,
    origin: String,
    http: reqwest::blocking::Client,
    max_resp: u32,
    tx: Sender<Ev>,
    rx: mpsc::Receiver<Ev>,
) {
    let mut writers: HashMap<u64, Sender<Vec<u8>>> = HashMap::new();
    loop {
        match rx.recv_timeout(Duration::from_millis(1000)) {
            Ok(Ev::Up(link, role, out)) => {
                writers.insert(link, out);
                node.handle(BearerEvent::Connected(link, role));
            }
            Ok(Ev::Data(link, bytes)) => node.handle(BearerEvent::Data(link, bytes)),
            Ok(Ev::Down(link)) => {
                writers.remove(&link);
                node.handle(BearerEvent::Disconnected(link));
            }
            Ok(Ev::Fetched(to, for_id, status, body)) => {
                let _ = node.send_http_response(to, for_id, status, vec![], body);
            }
            Err(RecvTimeoutError::Timeout) => node.tick(now_ms()),
            Err(RecvTimeoutError::Disconnected) => break,
        }

        // Translate any inbound hops requests against our OWN origin (path only).
        for r in node.take_http_requests() {
            let (origin, http, tx) = (origin.clone(), http.clone(), tx.clone());
            std::thread::spawn(move || {
                let (status, body) = fetch(&http, &origin, &r, max_resp);
                let _ = tx.send(Ev::Fetched(r.from, r.id, status, body));
            });
        }

        for (link, bytes) in node.drain_outgoing() {
            if let Some(out) = writers.get(&link) {
                if out.send(bytes).is_err() {
                    writers.remove(&link);
                }
            }
        }
    }
}

/// Execute one request against our origin. The request's `url` is treated as a **path** and
/// appended to the fixed origin — the endpoint never fetches any other host. v1 is GET-only.
fn fetch(
    http: &reqwest::blocking::Client,
    origin: &str,
    r: &hop_core::node::HttpReqItem,
    max_resp: u32,
) -> (u16, Vec<u8>) {
    if !r.method.eq_ignore_ascii_case("GET") {
        return (405, b"hop-endpoint: only GET in v1".to_vec());
    }
    let path = path_of(&r.url);
    let url = format!("{origin}{path}");
    match http.get(&url).send() {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let mut body = resp.bytes().map(|b| b.to_vec()).unwrap_or_default();
            if body.len() > max_resp as usize {
                body.truncate(max_resp as usize);
            }
            (status, body)
        }
        Err(_) => (502, b"hop-endpoint: backend unreachable".to_vec()),
    }
}

/// Reduce a request target to a path+query, discarding any scheme/host a client may have
/// sent — so a request can only ever hit our own origin (no open proxy).
fn path_of(url: &str) -> String {
    let after = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .or_else(|| url.strip_prefix("hops://"))
        .map(|rest| rest.split_once('/').map(|(_, p)| format!("/{p}")).unwrap_or_else(|| "/".to_string()))
        .unwrap_or_else(|| url.to_string());
    if after.starts_with('/') {
        after
    } else {
        format!("/{after}")
    }
}

/// Drive one inbound client WebSocket as a Hop link (we're the Responder). Same
/// interleave-by-read-timeout pattern as the relay's WS bearer.
fn serve_ws(stream: TcpStream, ev_tx: &Sender<Ev>) {
    let _ = stream.set_nodelay(true);
    let mut ws = match tungstenite::accept(stream) {
        Ok(w) => w,
        Err(_) => return,
    };
    let _ = ws.get_ref().set_read_timeout(Some(Duration::from_millis(100)));

    let link = NEXT_LINK.fetch_add(1, Ordering::Relaxed);
    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>();
    if ev_tx.send(Ev::Up(link, Role::Responder, out_tx)).is_err() {
        return;
    }
    'conn: loop {
        loop {
            match out_rx.try_recv() {
                Ok(bytes) => {
                    if ws.write(Message::Binary(bytes)).is_err() {
                        break 'conn;
                    }
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => break 'conn,
            }
        }
        if ws.flush().is_err() {
            break;
        }
        match ws.read() {
            Ok(Message::Binary(b)) => {
                if ev_tx.send(Ev::Data(link, b.to_vec())).is_err() {
                    break;
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(_) => break,
        }
    }
    let _ = ev_tx.send(Ev::Down(link));
}

/// Load a stable identity from a 32-byte file (so the endpoint's address — published in DNS
/// — survives restarts), generating and persisting one on first run.
fn load_identity(path: &Option<String>) -> Identity {
    if let Some(path) = path {
        if let Ok(bytes) = std::fs::read(path) {
            if let Ok(seed) = <[u8; 32]>::try_from(bytes.as_slice()) {
                return Identity::from_secret_bytes(&seed);
            }
        }
        let id = Identity::generate();
        if std::fs::write(path, id.to_secret_bytes()).is_err() {
            eprintln!("warning: could not persist identity to {path}; address will change on restart");
        }
        return id;
    }
    eprintln!("warning: no --identity-file; address will change on restart (DNS would go stale)");
    Identity::generate()
}
