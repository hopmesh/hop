# mockups/

Static design references. None of these ship; they exist to explore look, layout, and
interaction before folding the winning direction into the real site (`web/`) or the real
simulator (`sim/`).

## The swarm: `sim/` is canonical, `mockups/swarm.html` is not

There are two swarm demos in this repo. Only one is real:

- **`sim/` (canonical).** Every node is a live `hop-core` instance compiled to wasm
  (`core/hop-wasm`). It runs the actual Hop protocol: real store-and-forward, real crypto,
  real epidemic routing, real §39 private path. This is what the site embeds and what
  the "your browser is running the real Hop protocol" claim on the homepage refers to.
- **`mockups/swarm.html` (superseded, design reference only).** A pure-JS, fake-physics
  animation. It does NOT run the Hop protocol. It is kept solely as a visual/interaction
  reference and for its street-graph + movement generator, which `sim/` still harvests from.
  Its header comment marks it superseded; do not link it publicly.

`mockups/swarm.test.js` tests only the mockup's street-graph/movement math (geometry
invariants), not any protocol behavior. Keep it as long as that generator is a reference.
