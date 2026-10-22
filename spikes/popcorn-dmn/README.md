# Popcorn DMN spike

Throwaway spike: can a DMN editor be built on [Popcorn](https://popcorn.swmansion.com) (real BEAM/OTP in WebAssembly) with almost no JavaScript?

- `model.ex` – hardcoded DRD (loan pre-qualification), edges with kinds, cell edits, add/delete nodes, DMN requirement rules for connecting.
- `problems.ex` – the Problems list (FEEL errors, type violations, tables that match nothing, empty expressions, invalid constraints, unconnected elements) behind the button in the toolbar.
- `types.ex` / `types_panel.ex` – data types as in KIE's editor (built-in or custom type, structure components, list, enumeration/range/expression constraint as FEEL unary tests), validation of node values against them, rename refactoring, and the Data types tab.
- `xml_index.ex` / `xml_view.ex` – the XML inspector: `XmlIndex` walks the document `Dmn.to_xml/2` writes (fresh, or an imported file written back by the overlay) and ties each node, requirement, type and field to its lines by the ids they carry; `XmlView` highlights the lines and resolves a line to the most specific element.
- `constraint.ex` – the visual forms of a type constraint (comparison, interval, list of values) and their FEEL text; anything else stays raw FEEL.
- `dmn.ex` – DMN 1.6 XML export (own indenting writer, also available as numbered lines for the XML inspector) and import ([Saxy](https://hex.pm/packages/saxy)); import returns a report of everything it dropped. Fixture: `test/fixtures/kie_sample.dmn` (hand-written, KIE style, with unsupported elements).
- `view.ex` – pan and zoom as pure functions over the SVG viewBox.
- `dmn/overlay.ex` – keeps the imported document next to the model so a file survives being opened and saved (see below).
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

Interactions: the canvas fills the window under the top bar and everything else floats over it. Drag an element (input data, decision, business knowledge, knowledge source, group, text annotation) from the palette; hover a node and click or drag the small blue arrow beside it to connect it to another one (valid targets light up and show four anchors, the edge arrives at the one you point at; invalid requirements are refused with a reason); select a node for the create-and-connect pad, the data type pill and the × badge; double-click a node to rename it in place (F2 jumps to the name field); click an edge or node and press Delete. Wheel zooms around the pointer, dragging the background pans, `+`/`−`/Fit/Auto-layout and `?` (help) are at the top right. The expression/properties dock at the bottom has a grip on its top edge to resize it. **File** has New DMN, Import DMN… and Export DMN; Undo/Redo are icons next to the Editor / Data types switch. **Data types** is a tree with a properties panel (visual editors for comparisons, intervals and lists of values, raw FEEL for everything else; search; keyboard). **XML** opens a read-only source panel beside the editor or Data types: selecting something highlights its element and clicking the code selects the element it is in. Decision-table nodes have rules, typed input and output columns, an annotation column and a hit policy (UNIQUE, FIRST, ANY, COLLECT, RULE ORDER); controls to add and delete appear on hover. Business knowledge models are FEEL functions with parameters (call them as `Name(arg: value)` or `Name()`); an imported `<invocation>` becomes such a call.

## Opening and saving real files

The model covers only part of DMN, so saving must not damage the rest. `Dmn.Overlay` keeps the original document:

- an **unedited** file is written back as the same document (checked on the real KIE `Sample.dmn` and a second fixture: identical after canonicalisation, licence header included);
- an **edited** element is regenerated but keeps its own attributes, ids, `dmn:`-style prefixes and every child the editor does not model, in DMN's child order; elements nothing touched stay byte-for-byte as they were;
- the **diagram** is rebuilt around the original shapes and edges, so styles and labels survive; only bounds and waypoints that changed are rewritten, and entries pointing at deleted elements (e.g. KIE's column widths) are removed;
- text annotations, associations, knowledge sources, authority requirements and groups are edited like any other element (untouched ones are written back as they were); decision services and extension elements are **kept untouched** even though the editor does not show them; expression kinds it cannot edit (relation, function, list, aggregated COLLECT tables, ...) are shown read-only and kept; editing an expression merges the new text into the original element, so ids, typeRefs and unknown children stay (as long as the number of columns or rules is unchanged);
- an `<invocation>` is converted to a FEEL call so it evaluates, but written back as the original `<invocation>` until the expression is edited.

Known limits: comments inside the document (only those before the root are kept), a DOCTYPE, formatting and attribute whitespace are normalised; editing a data type regenerates its components (their ids are not kept).

Test data: the values of input data nodes belong to a **scenario**, not to the file. The Scenario menu in the toolbar switches, adds, renames and deletes scenarios (a new one starts as a copy) and saves or loads them as a JSON file keyed by input name (`Save scenarios`, `Load scenarios…`). A file written by an earlier version that holds a `spike:value` extension element opens with that value in the first scenario and loses the element on the next save. Scenarios are not remembered between page loads: save them.

## Embedding

Where the editor can and cannot run (iframes, popups, VS Code) is measured in [EMBEDDING.md](EMBEDDING.md). Short version: it needs a cross-origin isolated page, so a host must send `COOP: same-origin` + `COEP` headers; VS Code webviews cannot host it.

## Verification

`mix test` covers the pure logic (596 tests, 450 of them random-edit round trips validated against DMN16.xsd, including the real KIE sample and the open-and-save guarantees). `e2e/*.mjs` drive the running dev server with Playwright and Chrome (editing, diagram and data types, decision tables, DMN XML round trip, pan and zoom, workspace layout and on-canvas actions, the real KIE `Sample.dmn` imported and evaluated, 1,000-node scale and drag latency); see the header of each file for how to run it.

Notes from building this:

- Popcorn `0.4.0-next.9` traps (`memory access out of bounds`) when a single JS→BEAM message is larger than 64 KiB, so file imports are sent in 16K-character chunks. BEAM→JS messages are not affected.
- `config/config.exs` enables the experimental `treeshake` with `:elixir` preserved. Shaking the Elixir app itself breaks dynamic dispatch (e.g. `Exception.message/1`) and silently kills the editor process.
- The deps archive ships Popcorn's own two `beam.wasm` runtimes and a `brotli.so` that the browser never uses (about 2 MB brotli).
