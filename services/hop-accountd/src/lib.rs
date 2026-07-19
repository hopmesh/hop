//! hop-accountd: the account/invoice backend behind the Hop console's billing surfaces.
//!
//! `stripe_api` is the pure Stripe read layer (request builders + parsers behind a `Transport`
//! seam); `api` is the pure console-facing layer (routing, the bearer-token gate, the tenant map,
//! and the ownership rule). The binary (`main.rs`) glues them to sockets and, under
//! `--features live`, to the real Stripe API with the restricted `stripe-account-key`.

pub mod api;
pub mod auth;
pub mod auth_api;
pub mod domain;
pub mod email;
pub mod pg;
pub mod session;
pub mod store;
pub mod stripe_api;
