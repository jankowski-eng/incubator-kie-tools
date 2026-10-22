// Layout and on-canvas affordances against `mix popcorn.dev` (http://localhost:4000).
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/workspace.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const FIXTURE = new URL("../test/fixtures/kie_sample.dmn", import.meta.url).pathname;
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await (await browser.newContext({ viewport: { width: 1280, height: 720 } })).newPage();
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};
const settle = (ms = 400) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();
const text = (sel) => page.locator(sel).first().textContent();

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);

ok(
  "the app fits the window (no page scroll)",
  (await page.evaluate(() => document.documentElement.scrollHeight)) <= 720
);
const stage = await page.locator(".stage").boundingBox();
const panel = await page.locator("#panel table").first().boundingBox();
ok("canvas and the editing table are visible together", stage.y + stage.height < 720 && panel.y < 720, `${panel.y}`);

// selecting a node shows its expression in the dock without scrolling
await page.locator('#scene g[data-id="risk"] .shape').click();
await settle();
ok("selecting a node shows its table in view", (await page.locator("table.dt").first().boundingBox()).y < 720);

// splitter resizes the dock and remembers it
const dock0 = (await page.locator(".dock").boundingBox()).height;
const sp = await page.locator("#splitter").boundingBox();
await page.mouse.move(sp.x + sp.width / 2, sp.y + 7);
await page.mouse.down();
await page.mouse.move(sp.x + sp.width / 2, sp.y - 120, { steps: 5 });
await page.mouse.up();
const dock1 = (await page.locator(".dock").boundingBox()).height;
ok("dragging the splitter enlarges the dock", dock1 > dock0 + 80, `${dock0} -> ${dock1}`);
await page.reload();
await page.waitForFunction(() => document.querySelector("#panel table"), null, { timeout: 90000 });
ok("dock height survives a reload", Math.abs((await page.locator(".dock").boundingBox()).height - dock1) < 3);

// help popover
await page.locator("#help-btn").click();
ok("help popover opens", await page.locator("#help").isVisible());
await page.keyboard.press("Escape");
ok("Escape closes it", await page.locator("#help").isHidden());

// rename by double-click and F2
await page.locator('#scene g[data-id="front"] .shape').dblclick();
await settle(800);
ok(
  "double-click focuses the name field",
  await page.evaluate(() => document.activeElement?.classList.contains("nname")),
  await page.evaluate(() => document.activeElement?.outerHTML.slice(0, 80))
);
await page.locator("#drd").click({ position: { x: 5, y: 200 } });
await page.locator('#scene g[data-id="front"] .shape').click();
await settle();
await page.evaluate(() => document.activeElement?.blur());
await page.keyboard.press("F2");
ok("F2 focuses the name field", await page.evaluate(() => document.activeElement?.classList.contains("nname")));
await page.evaluate(() => document.activeElement?.blur());

// delete badge
const n0 = await count("#scene g[data-id]");
await page.locator('#scene g[data-id="front"] .del').click();
await settle(600);
ok("the × badge deletes the selected node", (await count("#scene g[data-id]")) === n0 - 1);
await page.locator("[data-click=undo]").click();
await settle(600);
ok("undo brings it back", (await count("#scene g[data-id]")) === n0);

// create-and-connect pad
await page.locator('#scene g[data-id="front"] .shape').click();
await settle();
ok("a selected decision offers 5 things to create", (await count("#pad-front [data-create]")) === 5);
const nn = await count("#scene g[data-id]"),
  ne = await count("#scene line.vis");
await page.locator('#pad-front [data-create="input"]').click();
await settle(800);
ok(
  "creating adds a connected node",
  (await count("#scene g[data-id]")) === nn + 1 && (await count("#scene line.vis")) === ne + 1
);
ok(
  "the new node is selected with its name focused",
  (await page.locator(".node.sel .nm, .node.sel").count()) === 1 &&
    (await page.evaluate(() => document.activeElement?.classList.contains("nname")))
);
ok(
  "an input data node offers only an annotation",
  (await count(".node.sel [data-create]")) === 1 && (await count(".node.sel [data-create=annotation]")) === 1
);
ok("the old pad is gone", (await count("#pad-front [data-create]")) === 0);
await page.locator("[data-click=undo]").click();
await settle(600);
ok("undo removes node and edge", (await count("#scene g[data-id]")) === nn && (await count("#scene line.vis")) === ne);
await page.locator('#scene g[data-id="dti"] .shape').click();
await settle();
ok(
  "a business knowledge model offers business knowledge, a source and an annotation",
  (await count("#pad-dti [data-create]")) === 3
);

// text annotations
await page.locator('#scene g[data-id="front"] .shape').click();
await settle();
const an = await count("#scene g[data-id]"),
  ae = await count("#scene line.vis");
await page.locator('#pad-front [data-create="annotation"]').click();
await settle(800);
ok(
  "the pad creates an annotation joined by an association",
  (await count("#scene g[data-id]")) === an + 1 &&
    (await count("#scene line.vis")) === ae + 1 &&
    (await count("#scene g.annotation")) === 1
);
const aid = await page.locator("#scene g.annotation").getAttribute("data-id");
ok(
  "the annotation is selected and its text field focused",
  await page.evaluate(
    () => document.activeElement?.dataset.op === "nname" && document.activeElement.tagName === "TEXTAREA"
  )
);
await page.keyboard.type(" for review");
await settle(500);
ok("typing shows the text in the diagram", (await text(`#nm-${aid}`)).includes("for review"), await text(`#nm-${aid}`));
ok(
  "the dotted line has no arrow",
  (await page.locator("#scene g.edge").last().locator("line.vis").getAttribute("marker-end")) === null
);
const before = await page.locator(`#scene g[data-id="${aid}"] .hitbox`).boundingBox();
const rz = await page.locator(`#scene g[data-id="${aid}"] .resize`).boundingBox();
await page.mouse.move(rz.x + rz.width / 2, rz.y + rz.height / 2);
await page.mouse.down();
await page.mouse.move(rz.x + rz.width / 2 + 60, rz.y + rz.height / 2 + 30, { steps: 5 });
await page.mouse.up();
await settle(500);
const after = await page.locator(`#scene g[data-id="${aid}"] .hitbox`).boundingBox();
ok(
  "dragging the corner resizes it",
  after.width > before.width + 30 && after.height > before.height + 15,
  `${before.width} -> ${after.width}`
);
await page.locator('[data-click="tab:xml"]').click();
await settle(500);
ok(
  "the XML has the annotation and association",
  (await text("#xml")).includes("<textAnnotation") && (await text("#xml")).includes("<association")
);
await page.locator('[data-click="tab:editor"]').click();
await settle();
// create, typing and resize are three undo steps
for (let i = 0; i < 3; i++) {
  await page.locator("[data-click=undo]").click();
  await settle(500);
}
ok(
  "undo takes the annotation away again",
  (await count("#scene g.annotation")) === 0 && (await count("#scene g[data-id]")) === an
);
await page.dragAndDrop('#palette [data-kind="annotation"]', "#drd", { targetPosition: { x: 120, y: 120 } });
await settle(600);
ok("an annotation can be dragged in from the palette", (await count("#scene g.annotation")) === 1);
await page.locator("[data-click=undo]").click();
await settle(500);

// knowledge sources
await page.locator('#scene g[data-id="loan"] .shape').click();
await settle();
const sn = await count("#scene g[data-id]"),
  se = await count("#scene line.vis");
await page.locator('#pad-loan [data-create="source"]').click();
await settle(800);
ok(
  "the pad creates a knowledge source joined by an authority requirement",
  (await count("#scene g[data-id]")) === sn + 1 &&
    (await count("#scene line.vis")) === se + 1 &&
    (await count("#scene g.source")) === 1
);
const sid = await page.locator("#scene g.source").getAttribute("data-id");
const lastLine = page.locator("#scene g.edge").last().locator("line.vis");
ok(
  "the authority line is dashed and ends in a dot",
  (await lastLine.getAttribute("marker-end")) === "url(#dot)" &&
    (await lastLine.getAttribute("stroke-dasharray")) !== null
);
ok("a source shows no value", (await text(`#nv-${sid}`)) === "");
ok(
  "its panel has a name field and a description",
  (await count(".props input.nname")) === 1 && (await count('textarea[data-op="ndesc"]')) === 1
);
await page.locator(".props input.nname").fill("Credit Bureau");
await settle(400);
ok("renaming shows in the diagram", (await text(`#nm-${sid}`)) === "Credit Bureau");
await page.locator('textarea[data-op="ndesc"]').fill("Where the score comes from");
await settle(400);
ok("a description gives it an info badge", (await count(`#scene g[data-id="${sid}"] .info`)) === 1);
ok("the panel links back to the decision", (await text(".props dl")).includes("Loan Pre-Qualification"));
// join an input to the source with the handle
await page.locator('#scene g[data-id="app"] .shape').click();
await settle(300);
const hh = await page.locator('#scene g[data-id="app"] .handle').boundingBox();
const tt = await page.locator(`#scene g[data-id="${sid}"] .shape`).boundingBox();
await page.mouse.move(hh.x + hh.width / 2, hh.y + hh.height / 2);
await page.mouse.down();
await page.mouse.move(tt.x + tt.width / 2, tt.y + tt.height / 2, { steps: 6 });
await page.mouse.up();
await settle(600);
ok("an input can be joined to the source as its authority", (await count("#scene line.vis")) === se + 2);
await page.locator('[data-click="tab:xml"]').click();
await settle(500);
ok(
  "the XML has the source and both authority requirements",
  (await text("#xml")).includes("<knowledgeSource") &&
    (await text("#xml")).includes("<requiredAuthority") &&
    (await text("#xml")).includes('<requiredInput href="#app"/>')
);
await page.locator('[data-click="tab:editor"]').click();
await settle();
await page.dragAndDrop('#palette [data-kind="source"]', "#drd", { targetPosition: { x: 120, y: 120 } });
await settle(600);
ok("a source can be dragged in from the palette", (await count("#scene g.source")) === 2);

// groups
await page.dragAndDrop('#palette [data-kind="group"]', "#drd", { targetPosition: { x: 400, y: 160 } });
await settle(700);
ok("a group can be dragged in from the palette", (await count("#scene g.group")) === 1);
const gid = await page.locator("#scene g.group").getAttribute("data-id");
// a click on the resize handle without dragging is not an undo step
await page.dragAndDrop('#palette [data-kind="group"]', "#drd", { targetPosition: { x: 200, y: 100 } });
await settle(600);
ok("a second group is added", (await count("#scene g.group")) === 2);
const rzTmp = await page.locator("#scene g.group.sel .resize").boundingBox();
await page.mouse.click(rzTmp.x + rzTmp.width / 2, rzTmp.y + rzTmp.height / 2);
await settle(300);
await page.locator("[data-click=undo]").click();
await settle(500);
ok("a click on the handle adds no undo step (one undo removes the group)", (await count("#scene g.group")) === 1);
await page.locator(`#scene g.group .band`).click({ position: { x: 40, y: 12 } });
await settle(300);

ok(
  "it is drawn behind everything else",
  (await page.locator("#scene g[data-id]").first().getAttribute("data-id")) === gid
);
ok(
  "it has no connect handle or create pad",
  (await count(`#scene g[data-id="${gid}"] .handle`)) === 0 && (await count(`#pad-${gid} [data-create]`)) === 0
);
ok("its panel has a name field", (await count(".props input.nname")) === 1);
await page.locator(".props input.nname").fill("Loan inputs");
await settle(400);
ok("the group's name is shown in the diagram", (await text(`#nm-${gid}`)) === "Loan inputs");
const gb0 = await page.locator(`#scene g[data-id="${gid}"] .shape`).boundingBox();
const insideBefore = await page.locator('#scene g[data-id="front"] .shape').boundingBox();
await page.locator('#scene g[data-id="app"] .shape').click();
await settle(300);
// clicking inside the frame, away from its border, reaches what is behind it, not the group
await page.mouse.click(gb0.x + gb0.width / 2, gb0.y + gb0.height - 20);
await settle(300);
ok("the inside of the frame is not grabbable", (await count(`#scene g.group.sel`)) === 0);
// resize the group to cover the Front End Ratio node, then drag the group by its title band
await page.locator(`#scene g[data-id="${gid}"] .band`).click({ position: { x: 40, y: 12 } });
await settle(300);
ok("clicking the title band selects the group", (await count("#scene g.group.sel")) === 1);
const rz2 = await page.locator(`#scene g[data-id="${gid}"] .resize`).boundingBox();
await page.mouse.move(rz2.x + rz2.width / 2, rz2.y + rz2.height / 2);
await page.mouse.down();
await page.mouse.move(rz2.x + rz2.width / 2 + 120, rz2.y + rz2.height / 2 + 20, { steps: 5 });
await page.mouse.up();
await settle(500);
const gb1 = await page.locator(`#scene g[data-id="${gid}"] .shape`).boundingBox();
ok("dragging the corner resizes the group", gb1.width > gb0.width + 60, `${gb0.width} -> ${gb1.width}`);
// drag the group by its band: the elements it covers go along, the others stay (compared in diagram units,
// since the view re-fits when the diagram grows)
const origins = () =>
  page.evaluate(() =>
    Object.fromEntries(
      [...document.querySelectorAll("#scene g[data-id]")].map((g) => {
        const [x, y] = g
          .getAttribute("transform")
          .match(/-?\d+(\.\d+)?/g)
          .map(Number);
        const r = g.querySelector(".shape").getBBox();
        return [g.dataset.id, { x, y, w: r.width, h: r.height }];
      })
    )
  );
const pos0 = await origins();
const frame = pos0[gid];
const covered = Object.keys(pos0).filter(
  (id) =>
    id !== gid &&
    pos0[id].x >= frame.x &&
    pos0[id].y >= frame.y &&
    pos0[id].x + pos0[id].w <= frame.x + frame.w &&
    pos0[id].y + pos0[id].h <= frame.y + frame.h
);
const band = await page.locator(`#scene g[data-id="${gid}"] .band`).boundingBox();
const k = (await page.locator("#drd").evaluate((el) => el.getScreenCTM().a)) || 1;
await page.mouse.move(band.x + 60, band.y + 12);
await page.mouse.down();
await page.mouse.move(band.x + 60 - 40 * k, band.y + 12 + 10 * k, { steps: 5 });
await page.mouse.up();
await settle(500);
const pos1 = await origins();
const delta = (id) => [Math.round(pos1[id].x - pos0[id].x), Math.round(pos1[id].y - pos0[id].y)];
const carried =
  covered.length > 0 &&
  Object.keys(pos0).every((id) =>
    id === gid || covered.includes(id) ? delta(id).join() === "-40,10" : delta(id).join() === "0,0"
  );
ok(
  "moving a group takes what is inside it along",
  carried,
  `covered: ${covered.join(",")}; ${Object.keys(pos0)
    .map((id) => id + delta(id))
    .join(" ")}`
);
for (let i = 0; i < 4; i++) {
  await page.locator("[data-click=undo]").click();
  await settle(400);
}
ok("undo removes the group again", (await count("#scene g.group")) === 0);

// a FEEL string is shown as text in the value badge, never as markup
await page.locator('#scene g[data-id="front"] .shape').click();
await settle(400);
await page.locator('[data-click="dock:expr"]').click();
await settle(300);
await page.locator('textarea[data-cell="front:4"]').fill('"<i onclick=1>x</i>"');
await settle(600);
ok(
  "a string with markup is displayed as text in the badge",
  (await count("#nv-front *")) === 0 && (await text("#nv-front")).includes("<i onclick"),
  await text("#nv-front")
);
await page.locator("[data-click=undo]").click();
await settle(500);

// only decisions offer a decision table
await page.locator('#scene g[data-id="dti"] .shape').click();
await settle(400);
ok(
  "a business knowledge model has no decision table option",
  (await count("select[data-op=nexpr] option[value=table]")) === 0
);
await page.locator('#scene g[data-id="front"] .shape').click();
await settle(400);
ok("a decision has it", (await count("select[data-op=nexpr] option[value=table]")) === 1);

// type pill
await page.locator('#scene g[data-id="front"] .shape').click();
await settle();
ok("selected node shows its data type", (await text("#scene g[data-id=front] .tpill text")) === "tRatio");
await page.locator("#scene g[data-id=front] .tpill").click();
await settle();
ok("clicking it focuses the type field", await page.evaluate(() => document.activeElement?.dataset.op === "ntype"));
await page.locator("select[data-op=ntype]").selectOption("tVerdict");
await settle(500);
ok("changing the type updates the pill", (await text("#scene g[data-id=front] .tpill text")) === "tVerdict");
await page.locator("[data-click=undo]").click();
await settle(500);
ok("undo restores it", (await text("#scene g[data-id=front] .tpill text")) === "tRatio");

// properties tab: description, identity, wiring
await page.locator('#scene g[data-id="front"] .shape').click();
await settle();
ok("no info badge without a description", (await count("#scene g[data-id=front] .info")) === 0);
await page.locator('[data-click="dock:props"]').click();
await settle();
ok(
  "properties show kind, id and neighbours",
  (await text(".props dl")).includes("decision") &&
    (await text(".props dl")).includes("front") &&
    (await count(".props .chip")) === 5,
  String(await count(".props .chip"))
);
await page.locator('textarea[data-op="ndesc"]').fill("Monthly housing cost as a share of income.");
await settle(500);
ok("a description puts an info badge on the node", (await count("#scene g[data-id=front] .info")) === 1);
ok(
  "its tooltip is the description",
  (await page.locator("#scene g[data-id=front] .info title").textContent()) ===
    "Monthly housing cost as a share of income."
);
await page.locator('.props .chip:has-text("Applicant Data")').click();
await settle(500);
ok(
  "a neighbour chip selects that node and stays on Properties",
  (await count('.node.sel[data-id="app"]')) === 1 && (await count('textarea[data-op="ndesc"]')) === 1
);
await page.locator('#scene g[data-id="front"] .info').click();
await settle(500);
ok(
  "the info badge opens the description",
  (await count('.node.sel[data-id="front"]')) === 1 &&
    (await page.locator('textarea[data-op="ndesc"]').inputValue()) === "Monthly housing cost as a share of income."
);
await page.locator('[data-click="tab:xml"]').click();
await settle(500);
ok(
  "the description is in the XML",
  (await text("#xml")).includes("<description>Monthly housing cost as a share of income.</description>")
);
await page.locator('[data-click="tab:editor"]').click();
await settle();
await page.locator("[data-click=undo]").click();
await settle(500);
ok("undo removes it", (await count("#scene g[data-id=front] .info")) === 0);
await page.locator('[data-click="dock:expr"]').click();
await settle();
ok("Expression tab brings the table back", (await count("table.boxed, table.dt")) >= 1);

// Enter moves down a decision-table column
await page.locator('#scene g[data-id="risk"] .shape').click();
await settle();
const cells = page.locator('table.dt tbody textarea[data-op="dtcell"]');
await cells.first().focus();
const col = await page.evaluate(() => document.activeElement.closest("td")?.cellIndex);
await page.keyboard.press("Enter");
const moved = await page.evaluate(() => {
  const a = document.activeElement;
  return { col: a.closest("td")?.cellIndex, row: a.closest("tr")?.rowIndex };
});
ok("Enter goes to the same column one row down", moved.col === col && moved.row > 1, JSON.stringify(moved));
await page.keyboard.press("Shift+Enter");
ok("Shift+Enter goes back up", (await page.evaluate(() => document.activeElement.closest("tr").rowIndex)) < moved.row);

// compact import summary
await page.locator("#file").setInputFiles(FIXTURE);
await settle(900);
const rep = await page.locator("#report").boundingBox();
ok("import summary is compact", rep.height < 80, `${rep.height}`);
ok("details are collapsed", (await page.locator("#report details").getAttribute("open")) === null);
await page.locator("#report details summary").click();
ok("details open on demand", await page.locator("#report ul.dropped").first().isVisible());
await page.locator("#report .x").click();
await settle();
ok("the summary can be dismissed", (await page.locator("#report").innerHTML()) === "");

// unconnected values show a dash, not "null"
await page.screenshot({ path: `${OUT}/ws1.png` });
await page.evaluate(() => document.activeElement?.blur());

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
await browser.close();
