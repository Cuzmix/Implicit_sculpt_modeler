#!/usr/bin/env node
// Runs the web version (build/web/site, from scripts/web_build.py) in headless Chromium and
// checks the whole app works there: the page starts WebGPU and the app's Home screen shows,
// Start opens a sphere, a scripted mouse stroke changes the picture, Ctrl+Z brings back the
// picture before it and Ctrl+Shift+Z the stroke, a drag off the sphere turns the view,
// Ctrl+S hands a .sculpt file to the browser's downloads, and nothing on the way logs a
// WebGPU error or throws. Screenshots go to build/web/check/*.png; the last line is
// key=value results.
//
//     node scripts/web_check.mjs [--headed] [--verbose]
//
// Needs Node and Playwright's Chromium (npm i -g playwright; npx playwright install chromium).
// Headless Chromium draws WebGPU on SwiftShader where there is no GPU (a cloud container),
// so its times say nothing about a real GPU.
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
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch({
	headless: !("headed" in args),
	// SwiftShader's Vulkan behind WebGPU: Chromium's default software path renders, but its
	// canvases come out blank in screenshots and its readbacks lose their instance.
	args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-vulkan=swiftshader", "--use-webgpu-adapter=swiftshader",
		"--disable-vulkan-surface", "--use-angle=swiftshader"],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, acceptDownloads: true });
const problems = [];
page.on("console", (m) => {
	const text = m.text();
	// WebGPU's validation messages come as warnings; the app's own log as plain logs, its
	// errors marked [ERROR].
	if (m.type() !== "log" || /\[ERROR\]|\[FATAL\]/.test(text)) problems.push(`console ${m.type()}: ${text}`);
	if ("verbose" in args) console.log(`[page] ${text}`);
});
page.on("pageerror", (e) => problems.push(`page error: ${e.message}`));

// The sphere's part of the window: the panels, the tips and the notes under the viewport,
// which change by themselves, stay out of the comparisons.
const CLIP = { x: 320, y: 240, width: 560, height: 400 };
// Empty viewport, where the pointer rests between strokes so no ring is on the sphere.
const REST = [150, 450];
async function shot(name) {
	await page.waitForTimeout(800);
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
		await page.waitForTimeout(16);
	}
	await page.mouse.up();
	for (const m of mods) await page.keyboard.up(m);
	await page.mouse.move(REST[0], REST[1]);
}
async function failure() {
	return page.$eval("#failure", (e) => (e.style.display === "grid" ? e.textContent : ""));
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
	// The loading note goes once the app reaches its frame loop.
	await page.waitForFunction(() => document.getElementById("note").style.display === "none" ||
		document.getElementById("failure").style.display === "grid", null, { timeout: 120000 });
	results.start_ms = Date.now() - t0;
	const why = await failure();
	if (why) throw new Error(`the page failed: ${why}`);
	await shot("1-home");

	// Home's Start (a fresh sphere). The first-run tips above the sphere change as they
	// go, so the comparisons start below them.
	await page.mouse.click(500, 382);
	await page.waitForTimeout(3000);
	await page.mouse.move(REST[0], REST[1]);
	const before = await shot("2-start");

	// A Draw stroke across the middle of the sphere.
	await stroke([520, 420], [760, 380]);
	const drawn = await shot("3-draw");
	results.draw_diff = await maxDiff(before, drawn);
	expect(results.draw_diff > 8, "a Draw stroke changed nothing on screen");

	// Undo brings back the picture before the stroke, redo the stroke. Undo puts the
	// positions back exactly; the normals around the stroke are worked out again from them,
	// and the studio look's soft shading over them with them, which can round a channel by
	// a few levels.
	await page.keyboard.press("Control+z");
	const undone = await shot("4-undo");
	results.undo_diff = await maxDiff(before, undone);
	expect(results.undo_diff <= 4, "undo did not bring back the picture before the stroke");
	await page.keyboard.press("Control+Shift+z");
	const redone = await shot("5-redo");
	results.redo_diff = await maxDiff(drawn, redone);
	expect(results.redo_diff <= 4, "redo did not bring back the stroke");

	// A drag on empty space turns the view.
	await stroke([200, 500], [300, 430], 20);
	const turned = await shot("6-turned");
	results.turn_diff = await maxDiff(redone, turned);
	expect(results.turn_diff > 8, "a drag off the sphere did not turn the view");

	// Save hands the scene file to the browser's downloads.
	const download = page.waitForEvent("download", { timeout: 30000 }).catch(() => null);
	await page.keyboard.press("Control+s");
	const file = await download;
	results.saved = file ? file.suggestedFilename() : "none";
	results.saved_bytes = file ? fs.statSync(await file.path()).size : 0;
	expect(file && results.saved.endsWith(".sculpt") && results.saved_bytes > 1000, "Ctrl+S gave no .sculpt download");
	await shot("7-saved");
	const late = await failure();
	expect(!late, `the page failed: ${late}`);
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
