// Layout and on-canvas affordances against `mix popcorn.dev` (http://localhost:4000).
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/workspace.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const FIXTURE = new URL("../test/fixtures/kie_sample.dmn", import.meta.url).pathname;
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};
const settle = (ms = 400) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();
const text = (sel) => page.locator(sel).first().textContent();
const xmlText = async () => {
  await page.locator(".xmlbtn").click();
  await page.waitForFunction(() => document.querySelectorAll("#xcode .xc").length > 0);
  await settle(400);
  const t = await page.evaluate(
    () => [...document.querySelectorAll("#xcode .xc")].map((c) => c.textContent).join("\n") + "\n"
  );
  await page.locator(".xmlbtn").click();
  await settle(500);
  return t;
};

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);

ok(
  "the app fits the window (no page scroll)",
  (await page.evaluate(() => document.documentElement.scrollHeight)) <= 900
);
// the canvas fills the area under the top bar and the dock floats over its bottom edge, so both are in view
const stage = await page.locator(".stage").boundingBox();
const panel = await page.locator("#panel table").first().boundingBox();
ok(
  "the canvas fills the window under the top bar",
  stage.x === 0 && stage.width >= 1279 && stage.y + stage.height >= 899,
  JSON.stringify(stage)
);
ok("canvas and the editing table are visible together", panel.y < 900 && panel.y > stage.y, `${panel.y}`);

// selecting a node shows its expression in the dock without scrolling
await page.locator('#scene g[data-id="risk"] .shape').click();
await settle();
ok("selecting a node shows its table in view", (await page.locator("table.dt").first().boundingBox()).y < 900);

// the grip on the dock's top edge resizes it and the height is remembered
const dock0 = (await page.locator("#dock").boundingBox()).height;
const sp = await page.locator("#splitter").boundingBox();
await page.mouse.move(sp.x + sp.width / 2, sp.y + 7);
await page.mouse.down();
await page.mouse.move(sp.x + sp.width / 2, sp.y - 120, { steps: 5 });
await page.mouse.up();
await settle(300);
const dock1 = (await page.locator("#dock").boundingBox()).height;
ok("dragging the grip enlarges the dock", dock1 > dock0 + 80, `${dock0} -> ${dock1}`);
await page.reload();
await page.waitForFunction(() => document.querySelector("#panel table"), null, { timeout: 90000 });
await settle(600);
ok("dock height survives a reload", Math.abs((await page.locator("#dock").boundingBox()).height - dock1) < 3);

// help popover
await page.locator("#help-btn").click();
ok("help popover opens", await page.locator("#help").isVisible());
await page.keyboard.press("Escape");
ok("Escape closes it", await page.locator("#help").isHidden());

// rename: double-click edits the name in place on the canvas; F2 goes to the name field of the panel
await page.locator('#scene g[data-id="front"] .shape').dblclick();
await settle(600);
ok(
  "double-click opens an in-place name field on the node",
  await page.evaluate(() => document.activeElement?.classList.contains("rename")),
  await page.evaluate(() => document.activeElement?.outerHTML.slice(0, 80))
);
await page.keyboard.press("Enter");
await settle(300);
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
// a node at the right edge gets its pad on its left side, so it is never cut off by the window
await page.locator('#scene g[data-id="piti"] .shape').click({ force: true });
await settle(400);
const padBox = await page.locator("#pad-piti .pad").boundingBox();
const stageBox = await page.locator(".stage").boundingBox();
ok(
  "the pad stays inside the canvas",
  padBox.x >= stageBox.x && padBox.x + padBox.width <= stageBox.x + stageBox.width,
  JSON.stringify(padBox)
);
await page.locator('#scene g[data-id="front"] .shape').click({ force: true });
await settle(400);
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
const xmlA = await xmlText();
ok("the XML has the annotation and association", xmlA.includes("<textAnnotation") && xmlA.includes("<association"));
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
// the middle of the new node can sit under the floating zoom controls: aim at its lower left part
await page.mouse.move(tt.x + 12, tt.y + tt.height - 12, { steps: 6 });
await page.mouse.up();
await settle(600);
ok("an input can be joined to the source as its authority", (await count("#scene line.vis")) === se + 2);
const xmlS = await xmlText();
ok(
  "the XML has the source and both authority requirements",
  xmlS.includes("<knowledgeSource") &&
    xmlS.includes("<requiredAuthority") &&
    xmlS.includes('<requiredInput href="#app"/>')
);
await page.dragAndDrop('#palette [data-kind="source"]', "#drd", { targetPosition: { x: 120, y: 120 } });
await settle(600);
ok("a source can be dragged in from the palette", (await count("#scene g.source")) === 2);

// groups
// drop it centred on Applicant Data, so that the group covers that node
const appBox = await page.locator('#scene g[data-id="app"] .shape').boundingBox();
const drdBox = await page.locator("#drd").boundingBox();
await page.dragAndDrop('#palette [data-kind="group"]', "#drd", {
  targetPosition: { x: appBox.x + appBox.width / 2 - drdBox.x, y: appBox.y + appBox.height / 2 - drdBox.y },
});
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
// the group is drawn behind its elements, so grab it at a point of the band that nothing covers
const grabX = await page.evaluate(
  ([bx, by, bw, id]) => {
    for (let dx = 20; dx < bw - 10; dx += 10) {
      if (document.elementFromPoint(bx + dx, by + 12)?.closest("[data-id]")?.dataset.id === id) return bx + dx;
    }
    return null;
  },
  [band.x, band.y, band.width, gid]
);
await page.mouse.move(grabX, band.y + 12);
await page.mouse.down();
await page.mouse.move(grabX - 40 * k, band.y + 12 + 10 * k, { steps: 5 });
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

// only decisions offer a decision table (fit the view first: earlier steps may have left a node under the header)
await page.locator('[data-click="fit"]').click();
await settle(300);
await page.locator('#scene g[data-id="dti"] .shape').click();
await settle(400);
ok(
  "a business knowledge model has no decision table option",
  (await count("select[data-op=nexpr] option[value=table]")) === 0
);
await page.locator('#scene g[data-id="front"] .shape').click();
await settle(400);
ok("a decision has it", (await count("select[data-op=nexpr] option[value=table]")) === 1);

// the problems list
ok(
  "a clean model says so",
  (await text("#problems-btn")).includes("No problems") &&
    (await page.locator("#problems-btn").getAttribute("data-level")) === "ok"
);
ok("the list is closed", await page.locator("#problems-pop").isHidden());
await page.locator('#scene g[data-id="front"] .shape').click();
await settle(400);
await page.locator('[data-click="dock:expr"]').click();
await settle(300);
await page.locator('textarea[data-cell="front:4"]').fill("1 +");
await settle(700);
ok(
  "a broken cell shows up as an error",
  (await page.locator("#problems-btn").getAttribute("data-level")) === "bad" &&
    (await text("#problems-btn")).includes("error"),
  await text("#problems-btn")
);
await page.locator("#problems-btn").click();
ok("the button opens the list", await page.locator("#problems-pop").isVisible());
ok("it names the node and the cell", (await text("#problems-list .problem.error")).includes("Front End Ratio"));
await page
  .locator('#scene g[data-id="loan"] .shape')
  .click({ force: true })
  .catch(() => {});
await page.keyboard.press("Escape");
ok("Escape closes it", await page.locator("#problems-pop").isHidden());
await page.locator('#scene g[data-id="app"] .shape').click();
await settle(300);
await page.locator("#problems-btn").click();
await page.locator("#problems-list .problem.error").first().click();
await settle(500);
ok(
  "clicking a problem selects its node",
  (await count('.node.sel[data-id="front"]')) === 1 && (await page.locator("#problems-pop").isHidden())
);
await page.locator("[data-click=undo]").click();
await settle(600);
ok("fixing it clears the list", (await text("#problems-btn")).includes("No problems"));

// test scenarios: named sets of input values, in a menu of their own
const scenarioMenu = async (item) => {
  await page.locator("#scn-toggle").click();
  await item();
};
const choose = (i) => scenarioMenu(() => page.locator(`#scn-list [data-click="scn:go:${i}"]`).click());
const names = () => page.locator("#scn-list button").allTextContents();
await page.locator("#scn-toggle").click();
ok(
  "one scenario to begin with",
  (await names()).join() === "Scenario 1" && (await page.locator("[data-click='scn:delete']").isDisabled())
);
await page.locator("#scn-toggle").click();
const base = await text("#nv-front");
await page.locator('#scene g[data-id="app"] .shape').click();
await settle(300);
page.once("dialog", (d) => d.accept("High debt"));
await scenarioMenu(() => page.locator("[data-click='scn:new']").click());
await settle(600);
ok(
  "a new scenario is added, selected and starts as a copy",
  (await names()).join() === "Scenario 1,High debt" &&
    (await text("#scn-name")) === "High debt" &&
    (await text("#nv-front")) === base
);
await page.locator('#scene g[data-id="app"] .shape').click();
await settle(300);
ok("an input says which scenario its value belongs to", (await text("#panel thead")).includes("High debt"));
await page.locator('textarea[data-cell="app:0"]').fill("{Income: 1000, Tax: 0, Insurance: 0, Debt: 900}");
await settle(600);
const high = await text("#nv-back");
ok("the value changes the results in this scenario", high !== "31.5562", high);
await choose(0);
await settle(600);
ok(
  "switching back brings the other values back",
  (await text("#nv-front")) === base && (await text("#nv-back")) === "31.5562"
);
await choose(1);
await settle(600);
ok("and forth", (await text("#nv-back")) === high);
page.once("dialog", (d) => d.accept("Heavy debt"));
await scenarioMenu(() => page.locator("[data-click='scn:rename']").click());
await settle(500);
ok("a scenario can be renamed", (await text("#scn-name")) === "Heavy debt");
await scenarioMenu(() => page.locator("[data-click='scn:delete']").click());
await settle(600);
ok(
  "deleting the active one goes back to the previous one",
  (await text("#scn-name")) === "Scenario 1" && (await text("#nv-front")) === base
);
await page.locator("[data-click=undo]").click();
await settle(600);
ok("and can be undone", (await text("#scn-name")) === "Heavy debt");
for (let i = 0; i < 8; i++) {
  if (await page.locator("[data-click=undo]").isDisabled()) break;
  await page.locator("[data-click=undo]").click();
  await settle(250);
}

// leaving the page with unsaved changes asks first
const unsaved = () => page.locator("body").getAttribute("data-unsaved");
// the page has been edited a lot by now: leaving it must ask
ok("the page is unsaved after all those edits", (await unsaved()) === "true");
let asked = null;
page.once("dialog", (d) => {
  asked = d.type();
  d.accept();
});
await page.goto("http://localhost:4000");
await page.waitForFunction(() => document.querySelector("#panel table"), null, { timeout: 90000 });
ok("leaving it asks first", asked === "beforeunload", String(asked));
ok("a fresh page has nothing to save", (await unsaved()) === "false");
await page.locator('#scene g[data-id="front"] .shape').click();
await settle(300);
await page.locator('[data-click="dock:expr"]').click();
await page.locator('textarea[data-cell="front:0"]').fill("1 + 1");
await settle(500);
ok("an edit makes the page unsaved", (await unsaved()) === "true");
await page.locator("[data-click=undo]").click();
await settle(500);
ok("undoing it makes it clean again", (await unsaved()) === "false");
// the inspector floats over the bottom of the canvas: close it to reach the input
await page.keyboard.press("Escape");
await settle(300);
await page.locator('#scene g[data-id="app"] .shape').click();
await settle(300);
await page.locator('textarea[data-cell="app:0"]').fill("{Income: 5}");
await settle(500);
ok("a changed test value counts too", (await unsaved()) === "true");
await page.locator("#scn-toggle").click();
const [saved] = await Promise.all([
  page.waitForEvent("download", { timeout: 15000 }),
  page.locator("[data-click='scn:save']").click(),
]);
await settle(400);
ok("saving the scenarios clears it", (await unsaved()) === "false", saved.suggestedFilename());
await page.locator('#scene g[data-id="front"] .shape').click();
await page.locator('textarea[data-cell="front:0"]').fill("2 + 2");
await settle(500);
ok("a DMN edit is unsaved again", (await unsaved()) === "true");
await page.getByRole("button", { name: /File/ }).click();
await Promise.all([
  page.waitForEvent("download", { timeout: 15000 }),
  page.getByRole("menuitem", { name: "Export DMN" }).click(),
]);
await settle(400);
ok("exporting the DMN clears it", (await unsaved()) === "false");
for (let i = 0; i < 8; i++) {
  if (await page.locator("[data-click=undo]").isDisabled()) break;
  await page.locator("[data-click=undo]").click();
  await settle(250);
}

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
ok(
  "the description is in the XML",
  (await xmlText()).includes("<description>Monthly housing cost as a share of income.</description>")
);
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
// a floating card in the corner (the summary used to span the whole window): a few lines, details collapsed
ok("import summary is compact", rep.height < 190 && rep.width <= 30 * 16 + 2, `${rep.width}x${rep.height}`);
ok("details are collapsed", (await page.locator("#report details").getAttribute("open")) === null);
await page.locator("#report details summary").click();
ok("details open on demand", await page.locator("#report ul.dropped").first().isVisible());
await page.locator("#report .x").click();
await settle();
ok("the summary can be dismissed", (await page.locator("#report").innerHTML()) === "");

// unconnected values show a dash, not "null"
await page.screenshot({ path: `${OUT}/ws1.png` });
await page.evaluate(() => document.activeElement?.blur());

// a problem with a data type opens the Data types view on that type (this replaces the model: keep it last)
const badType = `<definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="bad" id="d"><itemDefinition id="t1" name="tOk"><typeRef>number</typeRef></itemDefinition><itemDefinition id="t2" name="tBad"><typeRef>number</typeRef><allowedValues><text>((</text></allowedValues></itemDefinition></definitions>`;
await page.locator("#file").setInputFiles({ name: "bad.dmn", mimeType: "text/xml", buffer: Buffer.from(badType) });
await settle(900);
ok(
  "an invalid constraint is a problem",
  (await text("#problems-btn")).includes("1 problem"),
  await text("#problems-btn")
);
await page.locator("#problems-btn").click();
await page.locator("#problems-list .problem").first().click();
await settle(600);
ok(
  "clicking it opens the Data types view on that type",
  (await page.locator("#view-types").isVisible()) &&
    (await page.locator("#trow-1.sel, #trow-1[aria-selected=true]").count()) === 1,
  await page
    .locator("#ttree .trow.sel")
    .first()
    .textContent()
    .catch(() => "no selected row")
);
console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
// a runner (CI, a shell script) reads the result from the exit status
process.exitCode = fails === 0 ? 0 : 1;
await browser.close();
