//! # hop-core
//!
//! The pure-Rust core of Hop, a delay-tolerant mesh network. Everything
//! deterministic lives here — bundle codec, crypto, store-and-forward, routing,
//! and link framing — so it runs identically in unit tests, the `hop-sim`
//! simulator, and on-device via `hop-ffi`. Only the BLE bearer is native.
//!
//! See `DESIGN.md` at the repo root for the full protocol specification.

pub mod bundle;
pub mod crypto;
pub mod discover;
pub mod error;
pub mod link;
pub mod node;
pub mod relay;
pub mod route;
pub mod routing;
pub mod session;
pub mod store;
pub mod stream;
pub mod util;

pub use error::{Error, Result};

/// Application namespace on the shared Hop fabric. See DESIGN.md §17.
///
/// Every Hop-enabled app advertises the **same** BLE service UUID and relays for
/// every other app — the fabric is shared, not per-app, so a single app is never
/// alone on the mesh. `AppId` tags each bundle and advert so an app can
/// demultiplex its own traffic; relays forward all apps' traffic regardless and
/// can't read sealed payloads. Derive a stable id from a reverse-DNS app name via
/// [`app_id`].
pub type AppId = [u8; 16];

/// The shared/default namespace. Traffic tagged here is fabric-wide (e.g. peer
/// discovery common to all apps).
pub const FABRIC_APP: AppId = [0u8; 16];

/// Derive a stable [`AppId`] from an application name (e.g. "com.example.jobs").
pub fn app_id(name: &str) -> AppId {
    let mut id = [0u8; 16];
    id.copy_from_slice(&blake3::hash(name.as_bytes()).as_bytes()[..16]);
    id
}

/// Common imports for working with hop-core.
pub mod prelude {
    pub use crate::bundle::{
        Bundle, BundleFlags, BundleId, BundleOpts, Destination, Payload, StreamId, StreamKind,
    };
    pub use crate::stream::{StreamBuffer, StreamReassembler};
    pub use crate::crypto::{
        seal, short_addr, verify, Identity, PubKeyBytes, Sealed, ShortAddr, XPubKeyBytes,
    };
    pub use crate::route::RouteTable;
    pub use crate::discover::{Advert, AdvertBody, AdvertId, AdvertKind, Directory};
    pub use crate::error::{Error, Result};
    pub use crate::link::{
        fragment, Bearer, BearerEvent, Frame, LinkHandshake, LinkId, LinkSession, Reassembler,
        Role,
    };
    pub use crate::node::Node;
    pub use crate::relay::RelayScorer;
    pub use crate::routing::{
        BundleMeta, ForwardDecision, GatewayBeacon, PeerId, Router, SprayAndWait,
    };
    pub use crate::store::{HaveSet, MemoryStore, Store};
    pub use crate::util::{compress, decompress};
    pub use crate::{app_id, AppId, FABRIC_APP};
}
