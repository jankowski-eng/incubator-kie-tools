// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/connect-and-menu.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 1300, height: 800 } });
const logs = [];
page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`.slice(0, 300)));
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};
const settle = (ms = 300) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();
const shown = (sel) => page.locator(sel).first().evaluate((e) => getComputedStyle(e).display !== "none");
const center = async (sel) => {
  const b = await page.locator(sel).first().boundingBox();
  return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
};

await page.goto("http://localhost:4000");
await page.waitForFunction(() => document.querySelector("#scene")?.children.length > 0, null, { timeout: 90000 });
await page.keyboard.press("Escape");
await settle();

// ---------- the handle: only on hover, beside the node, small
await page.mouse.move(2, 300);
ok("handle is hidden when the pointer is elsewhere", !(await shown('[data-id="app"] .handle')));
await page.locator('#scene [data-id="app"] .shape').hover();
ok("hovering a node shows its handle", await shown('[data-id="app"] .handle'));
const nb = await page.locator('[data-id="app"] .shape').boundingBox();
const hb = await page.locator('[data-id="app"] .handle').first().boundingBox();
ok("handle sits outside the node's right edge and is small", hb.x >= nb.x + nb.width - 1 && hb.width < nb.width * 0.14, `${hb.width.toFixed(0)}px of a ${nb.width.toFixed(0)}px node`);

// ---------- click on the handle opens a connection that follows the pointer
const h = await center('[data-id="app"] .handle');
await page.mouse.move(h.x, h.y);
await page.mouse.down();
await page.mouse.up();
await settle();
ok("a click on the handle starts connecting", await page.locator("#drd.connecting").count());
ok("valid targets are marked, the source too", (await count("#scene .node.target")) === 2 && (await count("#scene .node.src")) === 1);
const loan = await center('[data-id="loan"] .shape');
await page.mouse.move(loan.x, loan.y, { steps: 4 });
await settle();
const lb = await page.locator('[data-id="loan"] .shape').boundingBox();
ok("a valid target shows four anchors in a cross; the source and other nodes none", await (async () => {
  const pts = await page.locator('[data-id="loan"] .anchor').evaluateAll((els) => els.map((e) => e.getBoundingClientRect()).map((r) => [r.x + r.width / 2, r.y + r.height / 2]));
  const near = (a, b) => Math.abs(a - b) < 3;
  const cx = lb.x + lb.width / 2, cy = lb.y + lb.height / 2;
  const cross = pts.length === 4 && pts.some(([x, y]) => near(x, cx) && near(y, lb.y)) && pts.some(([x, y]) => near(x, cx) && near(y, lb.y + lb.height)) && pts.some(([x, y]) => near(x, lb.x) && near(y, cy)) && pts.some(([x, y]) => near(x, lb.x + lb.width) && near(y, cy));
  const shownOn = await page.locator("#scene .node").evaluateAll((ns) => ns.filter((n) => [...n.querySelectorAll(".anchor")].some((a) => getComputedStyle(a).display !== "none")).map((n) => n.dataset.id));
  return cross && shownOn.sort().join() === "loan,risk";
})());
ok("pointing at the left of the target highlights that anchor", await (async () => {
  await page.mouse.move(lb.x - 6, lb.y + lb.height / 2, { steps: 3 });
  await settle();
  return (await page.locator('[data-id="loan"] .anchor.hot').getAttribute("data-side")) === "left";
})());
await page.mouse.move(loan.x, loan.y, { steps: 3 });
await settle();
ok("the node under the pointer is highlighted and the line follows", (await count("#scene .node.hot")) === 1 && (await count("#preview line")) === 1);
await page.mouse.move(lb.x - 6, lb.y + lb.height / 2, { steps: 3 });
await settle();
await page.mouse.down();
await page.mouse.up();
await settle(500);
ok("clicking a target connects", (await count("#scene line.vis")) === 11 && (await count("#drd.connecting")) === 0);
const e11 = await page.locator("#scene line.vis").last().evaluate((l) => [+l.getAttribute("x2"), +l.getAttribute("y2")]);
const loanBox = await page.evaluate(() => { const t = document.querySelector('[data-id="loan"]').getAttribute("transform").match(/-?[\d.]+/g); return [+t[0], +t[1]]; });
ok("the new edge arrives at the left side of the target", Math.abs(e11[0] - loanBox[0]) < 1.5, `${e11} vs ${loanBox}`);

// ---------- Esc cancels
await page.locator('#scene [data-id="prod"] .shape').hover();
const h2 = await center('[data-id="prod"] .handle');
await page.mouse.move(h2.x, h2.y);
await page.mouse.down();
await page.mouse.up();
await settle();
ok("connecting again", (await count("#drd.connecting")) === 1);
await page.keyboard.press("Escape");
await settle();
ok("Esc cancels without connecting", (await count("#drd.connecting")) === 0 && (await count("#scene line.vis")) === 11);

// ---------- clicking an invalid target explains why
await page.locator('#scene [data-id="app"] .shape').hover();
const h3 = await center('[data-id="app"] .handle');
await page.mouse.move(h3.x, h3.y);
await page.mouse.down();
await page.mouse.up();
const prod = await center('[data-id="prod"] .shape');
await page.mouse.move(prod.x, prod.y, { steps: 4 });
await page.mouse.down();
await page.mouse.up();
await settle();
ok("an invalid target gives a reason", (await page.locator("#toast").textContent()).includes("cannot be required"));

// ---------- input data: no expression picker, rename in place, value still visible and editable below
await page.locator('#scene [data-id="app"] .shape').click();
await settle();
ok("an input node has a name and a type but no expression selector", (await count('select[data-op=nexpr]')) === 0 && (await count('select[data-op=ntype]')) === 1);
ok("a decision node still has it", await (async () => {
  await page.locator('#scene [data-id="risk"] .shape').click({ force: true });
  await settle();
  const n = await count('select[data-op=nexpr]');
  await page.locator('#scene [data-id="app"] .shape').click({ force: true });
  await settle();
  return n === 1;
})());
await page.locator('#scene [data-id="app"] .shape').dblclick();
await settle();
ok("double click opens a rename field with the current name", (await page.locator("input.rename").inputValue()) === "Applicant Data");
await page.keyboard.type("Borrower");
await settle(400);
ok("the node name and the panel name follow while typing", (await page.locator("#nm-app").textContent()) === "Borrower" && (await page.locator('input[data-op=nname]').inputValue()) === "Borrower");
await page.keyboard.press("Enter");
await settle();
ok("Enter closes the field and keeps the name", (await count("input.rename")) === 0 && (await page.locator("#nm-app").textContent()) === "Borrower");
ok("the node's value text is still shown", (await page.locator("#nv-app").textContent()).startsWith("{Debt"));
await page.locator("textarea[data-cell]").first().fill("{Income: 1, Tax: 1, Insurance: 1, Debt: 1}");
await settle(400);
ok("the value is edited in the panel and the node follows", (await page.locator("#nv-app").textContent()).startsWith("{Debt: 1"));
await page.mouse.move(2, 300);

// ---------- File menu
await page.mouse.move(2, 300);
ok("menu starts closed", (await page.locator("#file-items").isHidden()) === true);
await page.getByRole("button", { name: /File/ }).click();
ok("File opens New, Import and Export", (await page.getByRole("menuitem").allTextContents()).join("|") === "New DMN|Import DMN…|Export DMN");
await page.keyboard.press("Escape");
ok("Esc closes the menu", await page.locator("#file-items").isHidden());
await page.getByRole("button", { name: /File/ }).click();
await page.mouse.click(600, 400);
ok("clicking outside closes the menu", await page.locator("#file-items").isHidden());
await page.getByRole("button", { name: /File/ }).click();
const [chooser] = await Promise.all([page.waitForEvent("filechooser"), page.getByRole("menuitem", { name: "Import DMN…" }).click()]);
ok("Import DMN opens the file chooser and closes the menu", !!chooser && (await page.locator("#file-items").isHidden()));

ok("no page errors", logs.length === 0, logs.join(" | "));
console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
await browser.close();
process.exit(fails ? 1 : 0);
