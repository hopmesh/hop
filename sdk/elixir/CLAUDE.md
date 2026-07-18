# sdk/elixir

The Elixir server-side endpoint SDK: `Hop.Endpoint`, an embeddable Hop endpoint with a Phoenix/Plug-
shaped surface, over `hop-core` via a Rustler NIF. Sibling to `sdk/node` (both are SERVER SDKs); the
same C-ABI-era contract, a different runtime.

```
mix.exs                       the mix project (dep: rustler); .mise.toml pins erlang 27 + elixir 1.18
native/hop_endpoint/          the Rustler NIF crate: binds the `hop` crate's HopNode Rust API
lib/hop/native.ex             the NIF module (use Rustler); stubs replaced at load
lib/hop/endpoint.ex           Hop.Endpoint GenServer (pump loop + handler dispatch) + Hop.Request
lib/hop/tcp_bearer.ex         the raw-TCP Internet bearer (opaque frames over :gen_tcp with packet: 4)
lib/hop/wss_bearer.ex         the WSS bearer over :ssl (no WS hex deps): minimal RFC 6455 handshake +
                              binary framing; packet: :line for the HTTP head, then :raw for frames
lib/hop/discovery.ex          well_known_body + resolve (raw :ssl HTTPS GET + Native.verify_reach_record)
lib/hop/native.ex             ...also sign_reach_record + verify_reach_record NIFs
test/ examples/               the round-trip + discovery ExUnit tests + a runnable demo
```

## Non-obvious things

- **The NIF binds the `hop` crate directly, not `sdk/hop.h`.** Rustler hosts Rust natively, so it calls
  `hop::HopNode`'s public Rust API (the same object the C ABI wraps, panic guards intact) rather than
  doing an unsafe extern-C round trip. C-FFI languages (`sdk/node` via koffi, future Python/Go/Ruby)
  bind the C ABI; Rust-hosting runtimes (Elixir/Rustler) bind the crate. The contract is the same `hop`.
- **`native/hop_endpoint` is EXCLUDED from the root workspace** (it has its own empty `[workspace]`, and
  is in the root `Cargo.toml` `exclude` list). So the main Rust CI job (`cargo ... --workspace`) never
  touches it, no tax, no cdylib-link risk on the main job. It builds only via Rustler/mix (or an explicit
  `cargo build --manifest-path`). In the Copybara export, the empty workspace marker is removed and
  `hop`, `hop-core`, `hop-endpoint-core`, and `hop-store-sqlite` are vendored under `native/vendor` in a
  package-local workspace. Hex checksums that source and the root `Cargo.lock`; no exported dependency
  path leaves the package.
- **core is poll-model.** `Hop.Endpoint` pumps via `:timer.send_interval` (tick, drain outbound to the
  bearer, take requests -> handlers, take responses -> reply to callers). Handlers currently run inline
  in the pump; a slow handler stalls the pump (a known prototype simplification, spawn for real work).
- **Bearer seam:** a bearer calls `Hop.Endpoint.register_link(pid, link, role, send_fun)` and feeds
  inbound frames via `deliver/3`. `Hop.TcpBearer` uses `packet: 4` so each recv is a whole frame.

## Verify

`mise trust && mise exec -- mix deps.get && mise exec -- mix test` (needs the workspace built once so
Rustler can compile the NIF into `<repo>/target`). The NIF must also pass `cargo fmt --all --check` and
`cargo clippy -p hop_endpoint --all-targets -- -D warnings`. Prototype: not yet a required CI job.
