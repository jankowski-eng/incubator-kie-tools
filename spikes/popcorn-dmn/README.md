# Popcorn DMN spike

Throwaway spike: can a DMN editor be built on [Popcorn](https://popcorn.swmansion.com) (real BEAM/OTP in WebAssembly) with almost no JavaScript?

- `model.ex` – hardcoded DRD (loan pre-qualification), edges with kinds, cell edits.
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
