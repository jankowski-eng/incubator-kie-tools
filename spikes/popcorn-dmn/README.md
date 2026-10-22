# Popcorn DMN spike

Throwaway spike: can a DMN editor be built on [Popcorn](https://popcorn.swmansion.com) (real BEAM/OTP in WebAssembly) with almost no JavaScript?

- `model.ex` – hardcoded DRD (loan pre-qualification), edges with kinds, cell edits, add/delete nodes, DMN requirement rules for connecting.
- `types.ex` / `types_panel.ex` – data types as in KIE's editor (built-in or custom type, structure components, list, enumeration/range/expression constraint as FEEL unary tests), validation of node values against them, rename refactoring, and the Data types tab.
- `dmn.ex` – DMN 1.6 XML export (own indenting writer) and import ([Saxy](https://hex.pm/packages/saxy)); import returns a report of everything it dropped. Fixture: `test/fixtures/kie_sample.dmn` (hand-written, KIE style, with unsupported elements).
- `view.ex` – pan and zoom as pure functions over the SVG viewBox.
- `layout.ex` – layered auto-layout (requirements below dependents, barycenter ordering).
- `eval.ex` – evaluates all nodes with [`feel`](https://hex.pm/packages/feel) in requirement order; cells see requirement names and earlier rows.
- `svg.ex` – nodes, and edges clipped to node borders with filled/open arrowheads (information/knowledge requirements).
- `highlight.ex` – FEEL syntax highlighting from `Feel.Syntax.Lexer` byte spans, error underline from the parser span.
- `panel.ex` / `autocomplete.ex` – boxed-expression table with live values; name completion (Tab or click).
- `editor.ex` – GenServer owning model, selection, undo/redo history and patches. Its two JS snippets only forward DOM events (pointer capture and screen→SVG coordinates need the DOM) and apply `[kind, selector, …]` patches.
- `public/index.html` – static page and CSS, no bundler, no npm.

## Run

Popcorn `0.4.0-next.9` ships a runtime built for OTP 29.0.6 and rejects a newer host OTP, so this spike pins `erlang 29.0.6` / `elixir 1.20.4-otp-29` (`.tool-versions`).

```sh
mix deps.get
mix test            # native, uses the Popcorn.JS no-op mock
mix popcorn.dev     # http://localhost:4000 (sets the COOP/COEP headers)
```

Open it in Chrome. The Claude desktop app's in-app browser pane downloads everything but never finishes booting the VM.

Interactions: drag items from the palette onto the canvas; drag a selected node's top handle onto another node to connect (invalid requirements are refused with a reason); click an edge or node and press Delete; Auto-layout is one undo step. Wheel zooms around the pointer, dragging the background pans, +/−/Fit buttons. Import… opens a `.dmn`/`.xml` file, Export downloads one, the XML tab shows the generated XML. Decision-table nodes have rules, input columns, one or several named output columns, an annotation column and a hit policy (UNIQUE, FIRST, ANY, COLLECT, RULE ORDER). Business knowledge models are FEEL functions with parameters (call them as `Name(arg: value)` or `Name()`); an imported `<invocation>` becomes such a call.

## Verification

`mix test` covers the pure logic (48 tests, including the real KIE sample). `e2e/*.mjs` drive the running dev server with Playwright and Chrome (editing, diagram and data types, decision tables, DMN XML round trip, pan and zoom, the real KIE `Sample.dmn` imported and evaluated, 1,000-node scale and drag latency); see the header of each file for how to run it.

Notes from building this:

- Popcorn `0.4.0-next.9` traps (`memory access out of bounds`) when a single JS→BEAM message is larger than 64 KiB, so file imports are sent in 16K-character chunks. BEAM→JS messages are not affected.
- `config/config.exs` enables the experimental `treeshake` with `:elixir` preserved. Shaking the Elixir app itself breaks dynamic dispatch (e.g. `Exception.message/1`) and silently kills the editor process.
- The deps archive ships Popcorn's own two `beam.wasm` runtimes and a `brotli.so` that the browser never uses (about 2 MB brotli).
