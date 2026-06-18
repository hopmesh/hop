//! Hop demo site. A single-page landing built with Dioxus that animates the two
//! problems Hop solves — reaching the internet with no connection, and reaching
//! another device with no infrastructure — plus how binary spray-and-wait works.

use dioxus::prelude::*;

fn main() {
    dioxus::launch(App);
}

#[component]
fn App() -> Element {
    rsx! {
        style { dangerous_inner_html: CSS }
        div { class: "wrap",
            Header {}
            Hero {}
            SceneInternet {}
            SceneDevice {}
            SceneBridge {}
            SceneSpray {}
            Closing {}
            footer { class: "foot",
                "Hop · delay-tolerant mesh networking · "
                span { class: "muted", "source-available under FSL-1.1-ALv2" }
            }
        }
    }
}

#[component]
fn Header() -> Element {
    rsx! {
        header { class: "hdr",
            div { class: "logo",
                span { class: "logo-mark", "⇢" }
                span { "hop" }
            }
            nav { class: "nav",
                a { href: "#internet", "Reach the web" }
                a { href: "#device", "Reach a device" }
                a { href: "#spray", "How it routes" }
            }
        }
    }
}

#[component]
fn Hero() -> Element {
    rsx! {
        section { class: "hero",
            h1 {
                "The network that "
                span { class: "grad", "finds a way." }
            }
            p { class: "lede",
                "Hop relays your messages device to device over Bluetooth until they "
                "reach the internet — or the person you're trying to reach. No tower, "
                "no Wi-Fi, no problem."
            }
            div { class: "pills",
                span { class: "pill", "Offline-first" }
                span { class: "pill", "End-to-end sealed" }
                span { class: "pill", "Works between apps" }
                span { class: "pill", "Rust core" }
            }
        }
    }
}

/// A node in a demo track, absolutely positioned at `left`% with a glyph + label.
#[component]
fn Node(left: f32, top: f32, glyph: String, label: String, kind: String) -> Element {
    rsx! {
        div {
            class: "node {kind}",
            style: "left:{left}%; top:{top}%;",
            span { class: "glyph", "{glyph}" }
            span { class: "label", "{label}" }
        }
    }
}

#[component]
fn SceneInternet() -> Element {
    rsx! {
        section { id: "internet", class: "scene",
            div { class: "scene-copy",
                h2 { "Problem 1 — you're offline, the answer isn't" }
                p {
                    "A user only gets online on known Wi-Fi. Away from it, updates and "
                    "requests pile up undelivered. Hop carries a sealed request hand to "
                    "hand across nearby devices until it reaches a node that "
                    span { class: "hl-cy", "has internet" }
                    " — which fulfills it and relays the "
                    span { class: "hl-gn", "response back" }
                    " the same way."
                }
            }
            div { class: "track track-a",
                Node { left: 8.0,  top: 50.0, glyph: "📵", label: "You (offline)", kind: "origin" }
                Node { left: 31.0, top: 50.0, glyph: "📱", label: "Relay", kind: "" }
                Node { left: 54.0, top: 50.0, glyph: "📱", label: "Relay", kind: "" }
                Node { left: 77.0, top: 50.0, glyph: "🛰️", label: "Gateway", kind: "gateway" }
                Node { left: 95.0, top: 50.0, glyph: "🌐", label: "Internet", kind: "cloud" }
                div { class: "packet packet-a" }
            }
            div { class: "legend",
                span { span { class: "dot cy" } "request hops out" }
                span { span { class: "dot gn" } "response hops back" }
            }
        }
    }
}

#[component]
fn SceneDevice() -> Element {
    rsx! {
        section { id: "device", class: "scene",
            div { class: "scene-copy",
                h2 { "Problem 2 — no infrastructure, just people" }
                p {
                    "In a remote community, two people want to reach each other with no "
                    "cell network at all. A message hops from device to device across "
                    "everyone in between until it reaches its "
                    span { class: "hl-gn", "destination" }
                    " — sealed the whole way, so relays carry it but can't read it."
                }
            }
            div { class: "track track-b",
                Node { left: 8.0,  top: 50.0, glyph: "🧑", label: "Sender", kind: "origin" }
                Node { left: 29.0, top: 50.0, glyph: "📱", label: "Neighbor", kind: "" }
                Node { left: 50.0, top: 50.0, glyph: "📱", label: "Passerby", kind: "" }
                Node { left: 71.0, top: 50.0, glyph: "📱", label: "Neighbor", kind: "" }
                Node { left: 92.0, top: 50.0, glyph: "🧑‍🌾", label: "Recipient", kind: "dest" }
                div { class: "packet packet-b" }
            }
            div { class: "legend",
                span { span { class: "dot gn" } "sealed message, hop by hop" }
            }
        }
    }
}

#[component]
fn SceneBridge() -> Element {
    rsx! {
        section { id: "bridge", class: "scene",
            div { class: "scene-copy",
                h2 { "Problem 3 — distance is no object" }
                p {
                    "Two communities are far apart, each its own little Bluetooth island. "
                    "The moment any carrier on one side "
                    span { class: "hl-cy", "touches the internet" }
                    ", Hop parks the sealed message in a shared online store — and a "
                    "device near the other island "
                    span { class: "hl-vi", "picks it up" }
                    " and finishes the hops to the recipient. One internet leg becomes "
                    "one very long hop."
                }
            }
            div { class: "track track-d",
                div { class: "zone zone-l", "BLE island" }
                div { class: "zone zone-r", "BLE island" }
                Node { left: 5.0,  top: 62.0, glyph: "🧑", label: "Sender", kind: "origin" }
                Node { left: 19.0, top: 62.0, glyph: "📱", label: "Relay", kind: "" }
                Node { left: 33.0, top: 62.0, glyph: "📶", label: "Online here", kind: "gateway" }
                Node { left: 50.0, top: 14.0, glyph: "☁️", label: "Hop online store", kind: "cloud" }
                Node { left: 67.0, top: 62.0, glyph: "📶", label: "Online there", kind: "gateway" }
                Node { left: 81.0, top: 62.0, glyph: "📱", label: "Relay", kind: "" }
                Node { left: 95.0, top: 62.0, glyph: "🧑‍🌾", label: "Recipient", kind: "dest" }
                div { class: "packet packet-d" }
            }
            div { class: "legend",
                span { span { class: "dot cy" } "sealed hops over Bluetooth" }
                span { span { class: "dot vi" } "leaps across the internet" }
                span { span { class: "dot gn" } "delivered on the far island" }
            }
        }
    }
}

#[component]
fn SceneSpray() -> Element {
    rsx! {
        section { id: "spray", class: "scene",
            div { class: "scene-copy",
                h2 { "How it routes — binary spray-and-wait" }
                p {
                    "Flooding everyone is wasteful; carrying one copy is too slow. Hop "
                    "gives each message a small "
                    span { class: "hl-cy", "copy budget" }
                    ". A carrier hands half its copies to each new device it meets, "
                    "spreading copies across independent paths in parallel — then the "
                    "first to reach the destination "
                    span { class: "hl-gn", "delivers" }
                    "."
                }
            }
            div { class: "track track-c",
                Node { left: 6.0,  top: 50.0, glyph: "🧑", label: "Source · 8", kind: "origin" }
                Node { left: 50.0, top: 13.0, glyph: "📱", label: "Carrier · 4", kind: "" }
                Node { left: 50.0, top: 50.0, glyph: "📱", label: "Carrier · 2", kind: "" }
                Node { left: 50.0, top: 87.0, glyph: "📱", label: "Carrier · 2", kind: "" }
                Node { left: 94.0, top: 50.0, glyph: "🧑‍🌾", label: "Destination", kind: "dest" }
                div { class: "packet packet-c c0" }
                div { class: "packet packet-c c1" }
                div { class: "packet packet-c c2" }
            }
            div { class: "legend",
                span { span { class: "dot cy" } "copies fan out" }
                span { span { class: "dot gn" } "first arrival wins" }
            }
        }
    }
}

#[component]
fn Closing() -> Element {
    rsx! {
        section { class: "closing",
            h2 { "One mesh, shared by every app" }
            p {
                "Hop is a Rust library you embed. Every Hop-enabled app relays for every "
                "other, so no app is ever alone on the network — and when any carrier "
                "touches the internet, messages can leap across the world."
            }
            div { class: "cards",
                Card { icon: "🔒", title: "Sealed end-to-end", body: "Relays forward ciphertext they can't read. Only the destination opens it." }
                Card { icon: "🛰️", title: "Internet when available", body: "Online nodes park messages in a shared store for far-away nodes to fetch." }
                Card { icon: "🧭", title: "Discover by gossip", body: "Find people and services the moment you meet anyone who's seen them." }
            }
        }
    }
}

#[component]
fn Card(icon: String, title: String, body: String) -> Element {
    rsx! {
        div { class: "card",
            div { class: "card-icon", "{icon}" }
            h3 { "{title}" }
            p { "{body}" }
        }
    }
}

const CSS: &str = r#"
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0a0e17; --bg2:#111726; --card:#151c2e; --line:#243049;
  --tx:#e7ecf5; --mut:#8a97b1; --cy:#37e0ff; --gn:#46e6a4; --vi:#8b7dff;
}
html{scroll-behavior:smooth}
body{background:radial-gradient(1200px 600px at 70% -10%,#16204022,transparent),
  linear-gradient(180deg,#0a0e17,#0a0e17 60%,#0b1322);
  color:var(--tx);font:16px/1.6 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
  -webkit-font-smoothing:antialiased}
.wrap{max-width:1040px;margin:0 auto;padding:0 22px}
a{color:inherit;text-decoration:none}

.hdr{display:flex;align-items:center;justify-content:space-between;
  padding:20px 0;position:sticky;top:0;z-index:9;
  backdrop-filter:blur(8px);background:#0a0e17cc;border-bottom:1px solid var(--line)}
.logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:20px;letter-spacing:.5px}
.logo-mark{color:var(--cy);font-size:24px}
.nav{display:flex;gap:22px;color:var(--mut);font-size:14px}
.nav a:hover{color:var(--tx)}

.hero{padding:80px 0 40px;text-align:center}
.hero h1{font-size:clamp(34px,6vw,64px);line-height:1.05;letter-spacing:-1px;font-weight:800}
.grad{background:linear-gradient(90deg,var(--cy),var(--gn));-webkit-background-clip:text;background-clip:text;color:transparent}
.lede{max-width:620px;margin:22px auto 0;color:var(--mut);font-size:clamp(16px,2vw,19px)}
.pills{display:flex;flex-wrap:wrap;gap:10px;justify-content:center;margin-top:28px}
.pill{border:1px solid var(--line);background:var(--bg2);color:var(--mut);
  padding:7px 14px;border-radius:999px;font-size:13px}

.scene{margin:54px 0;padding:30px;border:1px solid var(--line);border-radius:18px;
  background:linear-gradient(180deg,#121a2c,#0e1422)}
.scene-copy h2{font-size:clamp(22px,3vw,30px);letter-spacing:-.5px}
.scene-copy p{color:var(--mut);max-width:760px;margin-top:10px}
.hl-cy{color:var(--cy);font-weight:600}
.hl-gn{color:var(--gn);font-weight:600}

.track{position:relative;height:170px;margin:26px 0 6px}
.track-c{height:330px}
.track-d{height:240px}
.node{position:absolute;transform:translate(-50%,-50%);
  display:flex;flex-direction:column;align-items:center;gap:8px;width:92px;text-align:center}
.node .glyph{width:58px;height:58px;border-radius:16px;display:grid;place-items:center;
  font-size:26px;background:var(--card);border:1px solid var(--line);
  box-shadow:0 6px 20px #0006}
.node .label{font-size:12px;color:var(--mut)}
.node.origin .glyph{border-color:#48527a}
.node.gateway .glyph{border-color:var(--cy);box-shadow:0 0 22px #37e0ff44}
.node.cloud .glyph{border-color:var(--cy)}
.node.dest .glyph{border-color:var(--gn);box-shadow:0 0 22px #46e6a444}

/* connecting line behind nodes */
.track::before{content:"";position:absolute;left:6%;right:5%;top:50%;height:2px;
  background:repeating-linear-gradient(90deg,#2b3858 0 8px,transparent 8px 16px)}
.track-c::before{display:none}

.packet{position:absolute;width:18px;height:18px;border-radius:50%;
  transform:translate(-50%,-50%);top:50%;left:8%;
  background:var(--cy);box-shadow:0 0 16px 3px #37e0ffaa;z-index:3}

/* Scene A: round trip, cyan out then green back */
.packet-a{animation:hopA 9s cubic-bezier(.5,0,.5,1) infinite}
@keyframes hopA{
  0%,4%{left:8%;background:var(--cy);box-shadow:0 0 16px 3px #37e0ffaa}
  12%,16%{left:31%}
  24%,28%{left:54%}
  36%,40%{left:77%}
  46%{left:95%;background:var(--cy)}
  50%{left:95%;background:var(--gn);box-shadow:0 0 16px 3px #46e6a4aa}
  56%{left:95%;background:var(--gn)}
  64%{left:77%;background:var(--gn);box-shadow:0 0 16px 3px #46e6a4aa}
  72%{left:54%;background:var(--gn)}
  80%{left:31%;background:var(--gn)}
  92%,100%{left:8%;background:var(--gn);box-shadow:0 0 16px 3px #46e6a4aa}
}

/* Scene B: one-way delivery, loops invisibly */
.packet-b{background:var(--gn);box-shadow:0 0 16px 3px #46e6a4aa;animation:hopB 6s ease-in-out infinite}
@keyframes hopB{
  0%{left:8%;opacity:0}
  4%{opacity:1}
  6%{left:8%}
  20%{left:29%}
  36%{left:50%}
  52%{left:71%}
  68%,82%{left:92%}
  90%{left:92%;opacity:1}
  100%{left:92%;opacity:0}
}

/* Scene C: three copies fan out to carriers, then converge to destination */
.packet-c{background:var(--cy);box-shadow:0 0 14px 2px #37e0ffaa}
.c0{animation:sprayTop 5s ease-in-out infinite}
.c1{animation:sprayMid 5s ease-in-out infinite}
.c2{animation:sprayBot 5s ease-in-out infinite}
@keyframes sprayTop{
  0%{left:6%;top:50%;opacity:0;background:var(--cy)}
  6%{opacity:1}
  40%{left:50%;top:13%}
  55%{left:50%;top:13%}
  88%{left:94%;top:50%;background:var(--gn);box-shadow:0 0 14px 2px #46e6a4aa}
  100%{left:94%;top:50%;opacity:0}
}
@keyframes sprayMid{
  0%{left:6%;top:50%;opacity:0}
  10%{opacity:1}
  40%{left:50%;top:50%}
  58%{left:50%;top:50%}
  80%{left:94%;top:50%;background:var(--gn);box-shadow:0 0 18px 4px #46e6a4cc}
  100%{left:94%;top:50%;opacity:0}
}
@keyframes sprayBot{
  0%{left:6%;top:50%;opacity:0}
  8%{opacity:1}
  40%{left:50%;top:87%}
  60%{left:50%;top:87%}
  92%{left:94%;top:50%;background:var(--gn);box-shadow:0 0 14px 2px #46e6a4aa}
  100%{left:94%;top:50%;opacity:0}
}

/* Scene D: two BLE islands bridged by the internet (the online store) */
.node{z-index:2}
.zone{position:absolute;top:36%;height:52%;border:1px dashed #2b3858;border-radius:14px;
  display:flex;align-items:flex-end;justify-content:center;padding-bottom:8px;z-index:0;
  font-size:11px;color:var(--mut);letter-spacing:1px;text-transform:uppercase}
.zone-l{left:1%;width:38%}
.zone-r{right:1%;width:38%}
.node.cloud .glyph{border-color:var(--vi);box-shadow:0 0 22px #8b7dff55}
.hl-vi{color:var(--vi);font-weight:600}
.dot.vi{background:var(--vi);box-shadow:0 0 8px #8b7dff}
.packet-d{animation:hopBridge 8.5s ease-in-out infinite}
@keyframes hopBridge{
  0%{left:5%;top:62%;opacity:0;background:var(--cy);box-shadow:0 0 16px 3px #37e0ffaa}
  3%{opacity:1}
  6%{left:5%;top:62%}
  14%{left:19%;top:62%}
  22%,28%{left:33%;top:62%;background:var(--cy);box-shadow:0 0 16px 3px #37e0ffaa}
  39%{left:50%;top:14%;background:var(--vi);box-shadow:0 0 18px 4px #8b7dffcc}
  49%{left:50%;top:14%;background:var(--vi)}
  60%{left:67%;top:62%;background:var(--vi);box-shadow:0 0 18px 4px #8b7dffcc}
  65%{left:67%;top:62%;background:var(--gn);box-shadow:0 0 16px 3px #46e6a4aa}
  74%{left:81%;top:62%;background:var(--gn)}
  85%,93%{left:95%;top:62%;background:var(--gn);box-shadow:0 0 16px 3px #46e6a4aa;opacity:1}
  100%{left:95%;top:62%;opacity:0}
}

.legend{display:flex;gap:22px;color:var(--mut);font-size:13px;margin-top:8px;flex-wrap:wrap}
.legend span{display:flex;align-items:center;gap:7px}
.dot{width:11px;height:11px;border-radius:50%}
.dot.cy{background:var(--cy);box-shadow:0 0 8px #37e0ff}
.dot.gn{background:var(--gn);box-shadow:0 0 8px #46e6a4}

.closing{margin:60px 0 30px;text-align:center}
.closing h2{font-size:clamp(24px,3.5vw,34px);letter-spacing:-.5px}
.closing>p{color:var(--mut);max-width:640px;margin:12px auto 0}
.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-top:34px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:22px;text-align:left}
.card-icon{font-size:26px}
.card h3{margin:12px 0 6px;font-size:17px}
.card p{color:var(--mut);font-size:14px}

.foot{padding:40px 0;text-align:center;color:var(--mut);font-size:13px;border-top:1px solid var(--line);margin-top:40px}
.muted{opacity:.7}

@media(max-width:720px){
  .nav{display:none}
  .cards{grid-template-columns:1fr}
  .node{width:70px}
  .node .glyph{width:48px;height:48px;font-size:22px}
}
@media(prefers-reduced-motion:reduce){
  .packet,.packet-a,.packet-b,.packet-c{animation:none}
}
"#;
