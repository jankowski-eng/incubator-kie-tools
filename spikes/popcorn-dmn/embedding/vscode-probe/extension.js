// Throwaway extension: asks a VS Code webview whether it is cross-origin isolated, writes the answer to $COI_PROBE_OUT, quits.
const vscode = require("vscode");
const fs = require("fs");
exports.activate = () => {
  const out = process.env.COI_PROBE_OUT;
  const finish = (msg) => {
    fs.writeFileSync(
      out,
      JSON.stringify(
        { vscodeVersion: vscode.version, appHost: vscode.env.appHost, uiKind: vscode.env.uiKind, ...msg },
        null,
        2
      )
    );
    setTimeout(() => vscode.commands.executeCommand("workbench.action.quit"), 400);
  };
  const panel = vscode.window.createWebviewPanel("probe", "probe", vscode.ViewColumn.One, { enableScripts: true });
  panel.webview.onDidReceiveMessage(finish);
  panel.webview.html = `<!doctype html><body><script>
    const vscode = acquireVsCodeApi();
    let canConstruct = false;
    try { new SharedArrayBuffer(8); canConstruct = true; } catch (e) {}
    let workerOk = "untested";
    try { const w = new Worker(URL.createObjectURL(new Blob(["onmessage=e=>postMessage('ok')"]))); w.postMessage(new SharedArrayBuffer(8)); workerOk = "can post a SharedArrayBuffer to a worker"; w.terminate(); } catch (e) { workerOk = String(e.message).slice(0, 90); }
    vscode.postMessage({ crossOriginIsolated: self.crossOriginIsolated, typeofSharedArrayBuffer: typeof SharedArrayBuffer, canConstructSAB: canConstruct, workerPost: workerOk, origin: location.origin, ua: navigator.userAgent.slice(0, 80) });
  </script></body>`;
  setTimeout(() => finish({ timeout: true }), 25000);
};
