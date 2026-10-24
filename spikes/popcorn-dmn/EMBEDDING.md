# Embedding the editor

Popcorn runs the BEAM with threads (the runtime is built with `-pthread`), so it needs `SharedArrayBuffer`, and browsers only provide that to **cross-origin isolated** pages (`self.crossOriginIsolated === true`). That decides where this editor can run. Everything below was measured, not assumed: `embedding/matrix.mjs` (Chrome, see "Reproduce") and `embedding/vscode-probe` (VS Code 1.139 desktop).

## Results

| Scenario                                                                                                                               | Isolated                                | Editor                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Standalone page with `COOP: same-origin` + `COEP: require-corp`                                                                        | yes                                     | **works**                                                                                                                                        |
| Same-origin iframe in such a page                                                                                                      | yes                                     | **works**                                                                                                                                        |
| Cross-site iframe, host page has **no** isolation headers                                                                              | no                                      | cannot start                                                                                                                                     |
| Cross-site iframe, host isolated, iframe **without** `allow="cross-origin-isolated"`                                                   | no                                      | cannot start                                                                                                                                     |
| Cross-site iframe, host isolated (`require-corp`), app sends `COEP` + `CORP: cross-origin`, iframe has `allow="cross-origin-isolated"` | yes                                     | **works**                                                                                                                                        |
| Same, host uses `COEP: credentialless` (app `credentialless` or `require-corp`)                                                        | yes                                     | **works**                                                                                                                                        |
| Host isolated, app does **not** send `CORP: cross-origin` (or has no headers)                                                          | n/a                                     | the browser refuses to load the iframe (`ERR_BLOCKED_BY_RESPONSE`)                                                                               |
| Host with `COOP: same-origin-allow-popups` + `COEP: require-corp`                                                                      | no                                      | cannot start (only `COOP: same-origin` counts)                                                                                                   |
| Editor in a popup (`window.open`) from a plain host                                                                                    | yes                                     | starts, but **the host loses the window**: `popup.opener` is `null` and `popup.closed` reads `true`, so no `postMessage` between host and editor |
| **VS Code desktop webview**                                                                                                            | no (`SharedArrayBuffer` is `undefined`) | **cannot run**                                                                                                                                   |

Without isolation the page now says why (and which headers to set) instead of hanging on "Starting Popcorn…".

## What this means for the product

**Standalone:** fine. Serve with `COOP: same-origin` and `COEP: require-corp` (the dev server `mix popcorn.dev` does).

**Embedded in another web product:** only if the _host_ becomes cross-origin isolated. The contract a host has to accept:

1. Its top-level page sends `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`, Chromium-based browsers; Firefox and Safari support was not checked).
2. Every cross-origin resource that page loads (images, scripts, fonts, other iframes, analytics) must then send `CORP`/CORS headers, or the host must use `credentialless`.
3. The editor is served with the same `COOP`/`COEP` plus `Cross-Origin-Resource-Policy: cross-origin`, and embedded with `<iframe allow="cross-origin-isolated">`.
4. `COOP: same-origin` severs `window.opener`, which breaks OAuth/payment popups that rely on it. `same-origin-allow-popups` is not enough.

Hosts that cannot meet this (a typical third-party site, a page that needs popups) cannot embed the editor. A popup is **not** a fallback: it boots, but there is no message channel back to the host. Only file hand-off (download/upload) or a shared server works there.

**VS Code:** the webview is not isolated, so a custom editor built on Popcorn does not work today. VS Code extensions cannot change that: a webview's headers are not under the extension's control.

## Options

- **A. Ship the host contract.** Works today for products we or our users control. Needs: an iframe SDK with a `postMessage` API (open file, get/set content, change events, save), documentation of the header contract, and a preflight check in the host (the editor already reports it).
- **B. Ask upstream for a build without threads / `SharedArrayBuffer`.** The runtime is compiled with `-pthread` (`scripts/build-beam.sh` in Popcorn), so this is an engineering task upstream, not a switch. It would remove the whole class of limits above (plain hosts, popups, VS Code). Effort and feasibility are unknown; worth asking Software Mansion before building anything that depends on it.
- **C. VS Code until B exists.** The extension can start a local server (with the headers) and open the editor in the browser, syncing the file over a local socket. It works but is not an in-editor experience. A Chrome extension page can opt into cross-origin isolation through its manifest (not tried here).
- **Not recommended:** a second, non-Popcorn evaluation backend just for hosts that cannot be isolated.

## Reproduce

```sh
mix deps.get && mix popcorn.cook --out-dir public/out   # or run mix popcorn.dev once
node embedding/server.mjs &                              # apps on localhost:410x, hosts on 127.0.0.1:411x
PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core node embedding/matrix.mjs
```

VS Code probe (opens a window for a few seconds, uses a temporary profile):

```sh
COI_PROBE_OUT=/tmp/coi.json code --extensionDevelopmentPath=embedding/vscode-probe \
  --user-data-dir=/tmp/vsc-user --extensions-dir=/tmp/vsc-ext --disable-extensions --new-window
```
