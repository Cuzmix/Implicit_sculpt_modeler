#!/usr/bin/env node
// Runs the web build (build/web/site, from scripts/web_build.py) in headless Chromium and
// checks it sculpts: the page starts WebGPU and shows the sphere, a scripted mouse stroke
// changes the picture and leaves one undo step, Ctrl+Z brings back the very same pixels,
// a Grab and a Shift-smooth stroke land, and nothing on the way logs a WebGPU error or
// throws. Screenshots go to build/web/check/*.png; the last line is key=value stats.
//
//     node scripts/web_check.mjs [--vertices=N] [--headed]
//
// Needs Node and Playwright's Chromium (npm i -g playwright; npx playwright install chromium).
// Headless Chromium draws WebGPU on SwiftShader where there is no GPU (a cloud container),
// so frame times here say nothing about a real GPU; dab times are the wasm's own.
import { createRequire } from "node:module";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
let chromium;
try {
	({ chromium } = require("playwright"));
} catch {
	// A global install (npm i -g playwright) is not on an ES module's own path.
	const { execSync } = await import("node:child_process");
	const root = execSync("npm root -g").toString().trim();
	({ chromium } = require(path.join(root, "playwright")));
}

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const SITE = path.join(ROOT, "build", "web", "site");
const OUT = path.join(ROOT, "build", "web", "check");
const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, "").split("=")));
const vertices = +(args.vertices || 250000);

if (!fs.existsSync(path.join(SITE, "sculpt.wasm"))) {
	console.error("web_check: build/web/site/sculpt.wasm missing; run python scripts/web_build.py first");
	process.exit(1);
}
fs.mkdirSync(OUT, { recursive: true });

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };
const server = http.createServer((req, res) => {
	const name = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\/$/, "/index.html");
	const file = path.join(SITE, path.normalize(name));
	if (!file.startsWith(SITE) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
	res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" });
	fs.createReadStream(file).pipe(res);
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const url = `http://127.0.0.1:${server.address().port}/?vertices=${vertices}`;

const browser = await chromium.launch({
	headless: !("headed" in args),
	// SwiftShader's Vulkan behind WebGPU: Chromium's default software path renders, but its
	// canvases come out blank in screenshots and its readbacks lose their instance.
	args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-vulkan=swiftshader", "--use-webgpu-adapter=swiftshader",
		"--disable-vulkan-surface", "--use-angle=swiftshader"],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
const problems = [];
page.on("console", (m) => {
	const text = m.text();
	if (/WebGPU|error/i.test(text) && m.type() !== "log") problems.push(`console ${m.type()}: ${text}`);
	if (/WebGPU .* error/.test(text)) problems.push(text);
	if ("verbose" in args) console.log(`[page] ${text}`);
});
page.on("pageerror", (e) => problems.push(`page error: ${e.message}`));

function parse(text) {
	return Object.fromEntries(text.split(" ").map((kv) => kv.split("=")));
}
async function state() {
	const text = await page.$eval("#state", (e) => e.textContent);
	if (text.startsWith("failed=")) throw new Error(text);
	return parse(text);
}
// The page writes its state twice a second: wait for a write after now.
async function fresh() {
	const before = await page.$eval("#state", (e) => e.textContent);
	await page.waitForFunction((b) => document.getElementById("state").textContent !== b, before, { timeout: 5000 }).catch(() => {});
	await page.waitForTimeout(600);
	return state();
}
// The middle of the canvas, where the sphere is: the bars and the status line, whose
// numbers change by themselves, stay out of the comparisons.
const CLIP = { x: 300, y: 110, width: 680, height: 630 };
async function shot(name) {
	await page.screenshot({ path: path.join(OUT, `${name}.png`) });
	return page.screenshot({ clip: CLIP });
}
async function stroke(from, to, steps = 30, mods = []) {
	for (const m of mods) await page.keyboard.down(m);
	await page.mouse.move(from[0], from[1]);
	await page.mouse.down();
	for (let i = 1; i <= steps; i++) {
		const k = i / steps;
		await page.mouse.move(from[0] + (to[0] - from[0]) * k, from[1] + (to[1] - from[1]) * k);
		await page.waitForTimeout(8);
	}
	await page.mouse.up();
	for (const m of mods) await page.keyboard.up(m);
	await page.mouse.move(20, 780); // off the sphere: no ring in the next picture
}

// The largest difference of any channel of any pixel between two screenshots, worked out
// by the page's own 2D canvas (Node has no PNG decoder of its own).
async function maxDiff(a, b) {
	return page.evaluate(async ([a, b]) => {
		const load = async (data) => {
			const img = new Image();
			img.src = "data:image/png;base64," + data;
			await img.decode();
			const c = document.createElement("canvas");
			c.width = img.width; c.height = img.height;
			const g = c.getContext("2d");
			g.drawImage(img, 0, 0);
			return g.getImageData(0, 0, c.width, c.height).data;
		};
		const [pa, pb] = [await load(a), await load(b)];
		let most = 0;
		for (let i = 0; i < pa.length; i++) most = Math.max(most, Math.abs(pa[i] - pb[i]));
		return most;
	}, [a.toString("base64"), b.toString("base64")]);
}

const results = {};
let failed = false;
function expect(ok, what) {
	if (!ok) { failed = true; console.error(`web_check: FAIL ${what}`); }
}
try {
	const t0 = Date.now();
	await page.goto(url);
	await page.waitForFunction(() => /vertices=[1-9]/.test(document.getElementById("state").textContent) ||
		document.getElementById("state").textContent.startsWith("failed="), null, { timeout: 60000 });
	results.start_ms = Date.now() - t0;
	let s = await fresh();
	results.vertices = +s.vertices;
	results.ready_ms = +s.ready_ms;
	await page.mouse.move(20, 780);
	await page.waitForTimeout(300);
	const before = await shot("1-start");

	// A Draw stroke across the middle of the sphere.
	await stroke([520, 420], [760, 380]);
	s = await fresh();
	const drawn = await shot("2-draw");
	results.draw_diff = await maxDiff(before, drawn);
	results.draw_changed = results.draw_diff > 8;
	results.undo_after_draw = +s.undo;
	results.dab_ms = +s.dab_ms;
	expect(results.draw_changed, "a Draw stroke changed nothing on screen");
	expect(results.undo_after_draw === 1, `one stroke left ${s.undo} undo steps`);

	// Undo brings back the same pixels; redo the stroke again.
	await page.keyboard.press("Control+z");
	s = await fresh();
	const undone = await shot("3-undo");
	// Undo puts the positions back exactly; the normals around the stroke are worked out
	// again from them, where the sphere's own were made with it, which can round a
	// channel by one.
	results.undo_diff = await maxDiff(before, undone);
	results.undo_restores = results.undo_diff <= 1;
	results.redo_after_undo = +s.redo;
	expect(results.undo_restores, "undo did not bring back the picture before the stroke");
	await page.keyboard.press("Control+Shift+z");
	s = await fresh();
	expect(+s.undo === 1 && +s.redo === 0, `redo left undo=${s.undo} redo=${s.redo}`);

	// Clay with X symmetry, then Grab, then Shift to smooth.
	await page.keyboard.press("2");
	await page.keyboard.press("x");
	await stroke([600, 300], [700, 520], 25);
	await page.keyboard.press("9");
	await stroke([640, 250], [640, 160], 15);
	await page.keyboard.press("1");
	await stroke([560, 470], [720, 470], 25, ["Shift"]);
	s = await fresh();
	results.brush = s.brush;
	results.symmetry = +s.symmetry;
	results.undo_steps = +s.undo;
	expect(s.brush === "Draw" && +s.symmetry === 1, `keys left brush=${s.brush} symmetry=${s.symmetry}`);
	expect(+s.undo === 4, `four strokes left ${s.undo} undo steps`);
	// Turn the view with a drag off the sphere, so the last picture shows the work from the side.
	await stroke([150, 400], [320, 330], 20);
	await page.waitForTimeout(300);
	await shot("4-sculpted");
	s = await fresh();
	results.view_turned = Math.abs(+s.yaw - 0.6) > 0.1 || Math.abs(+s.pitch - 0.35) > 0.1;
	expect(results.view_turned, `a drag off the sphere left the view at yaw=${s.yaw} pitch=${s.pitch}`);
	results.fps = +s.fps;
	results.frame_ms = +s.frame_ms;
} catch (e) {
	failed = true;
	console.error(`web_check: ${e.message}`);
}
results.problems = problems.length;
for (const p of problems) console.error(`web_check: ${p}`);
if (problems.length) failed = true;
await browser.close();
server.close();
console.log(Object.entries(results).map(([k, v]) => `${k}=${v}`).join(" "));
console.log(failed ? "web_check: FAILED" : "web_check: passed (screenshots in build/web/check)");
process.exit(failed ? 1 : 0);
