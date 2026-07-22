//! # hop-example-origin
//!
//! A deliberately tiny HTTP backend (no dependencies) used to demonstrate `hops://` end to
//! end at **example.hopme.sh** (DESIGN.md §30). A `hop-endpoint` runs in front of it and
//! translates `hops://example.hopme.sh/<path>` requests into plain HTTP against this server
//! on localhost, so this is the "origin" the endpoint is bound to.
//!
//! It answers any GET with a small example payload and echoes the path, so you can see the
//! whole chain working: client → mesh → endpoint → this origin → back.
//!
//! Usage:  hop-example-origin [--listen 127.0.0.1:8080]

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};

fn main() {
    let mut listen = "127.0.0.1:8080".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--listen" => listen = args.next().unwrap_or(listen),
            other => eprintln!("ignoring unknown arg: {other}"),
        }
    }

    let listener = TcpListener::bind(&listen).expect("bind --listen address");
    println!("hop-example-origin: serving demo payload on http://{listen}");
    for stream in listener.incoming().flatten() {
        // One short-lived request per connection is plenty for a demo backend.
        std::thread::spawn(move || handle(stream));
    }
}

fn handle(mut stream: TcpStream) {
    let (path, scheme) = match read_request(&mut stream) {
        Some(p) => p,
        None => return,
    };

    let (status, content_type, body) = route(&path, &scheme);
    let resp = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         Cache-Control: no-store\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.write_all(body.as_bytes());
    let _ = stream.flush();
}

/// Read the request line + headers, returning (path, scheme). The endpoint in front of us
/// tags each request with `X-Hop-Scheme: hops|https` so we can tell whether the client came
/// over the mesh (`hops://`) or standard HTTPS; the two reach this same origin. We don't
/// read the body (a GET has none; blocking for it would hang the waiting client).
fn read_request(stream: &mut TcpStream) -> Option<(String, String)> {
    let mut reader = BufReader::new(stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).ok()? == 0 {
        return None;
    }
    // "GET /path HTTP/1.1"
    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();
    let mut scheme = "hops".to_string(); // default: assume mesh unless the endpoint says https
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) if line == "\r\n" || line == "\n" => break,
            Ok(_) => {
                if let Some((k, v)) = line.split_once(':') {
                    if k.trim().eq_ignore_ascii_case("x-hop-scheme") {
                        scheme = v.trim().to_ascii_lowercase();
                    }
                }
            }
            Err(_) => break,
        }
    }
    Some((path, scheme))
}

fn route(path: &str, scheme: &str) -> (&'static str, &'static str, String) {
    let hops = scheme == "hops";
    let clean = path.split('?').next().unwrap_or(path);
    match clean {
        "/" | "/index.html" => ("200 OK", "text/html; charset=utf-8", home(hops)),
        "/hello" => (
            "200 OK",
            "application/json; charset=utf-8",
            format!(
                r#"{{"service":"example.hopme.sh","message":"hello over {}","ok":true}}"#,
                if hops { "hops://" } else { "https://" }
            ),
        ),
        other => (
            "200 OK",
            "text/plain; charset=utf-8",
            format!(
                "example.hopme.sh, you asked for: {other}\nThis reached the origin over {}.\n",
                if hops {
                    "hops:// (the mesh)"
                } else {
                    "standard https://"
                }
            ),
        ),
    }
}

/// The home page, worded for how it was actually fetched (DESIGN.md §30). The same origin is
/// reachable both over the mesh (`hops://`) and over standard HTTPS (the endpoint reverse-
/// proxies plain HTTP to it), so we say which one this request used.
fn home(hops: bool) -> String {
    let how = if hops {
        "You fetched this over <code>hops://</code>, the request crossed the Hop mesh as sealed \
         datagrams, was terminated at this domain's own <code>hop-endpoint</code>, and served by \
         a tiny origin on localhost. It never touched the public internet's HTTP stack, no third \
         party in the middle, no open proxy. The very same page is also reachable at \
         <code>https://example.hopme.sh</code>."
    } else {
        "You fetched this over standard <code>https://</code>, the global load balancer \
         terminated TLS and the domain's <code>hop-endpoint</code> reverse-proxied it to a tiny \
         origin on localhost. The very same page is also reachable over the mesh at \
         <code>hops://example.hopme.sh</code>, sealed end-to-end, with no third party in the middle."
    };
    format!(
        "<!doctype html>\
<html><head><meta charset=\"utf-8\"><title>example.hopme.sh</title></head>\
<body style=\"font-family:system-ui;max-width:40rem;margin:3rem auto;line-height:1.5\">\
<h1>example.hopme.sh</h1>\
<p>{how}</p>\
<p>Try <code>/hello</code> for a JSON payload.</p>\
</body></html>"
    )
}
