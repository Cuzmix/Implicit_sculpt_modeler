#!/usr/bin/env python3
"""Builds the web version (README "Web") into build/web/site, or type-checks it.

    python scripts/web_build.py            # release: build/web/site/{index.html,sculpt.wasm,odin.js,wgpu.js}
    python scripts/web_build.py --debug    # with bounds checks and debug info
    python scripts/web_build.py --check    # odin check only, with the strict flags
    python scripts/web_build.py --serve    # build, then serve the site at http://localhost:8000
    python scripts/web_build.py --test     # build, then scripts/web_check.mjs in headless Chromium

The page is src/web (the entry) with render/webgpu (its viewport) compiled by Odin's own
wasm target, js_wasm64p32: Odin's int stays 64-bit as on the desktop while pointers are
32-bit, as browsers need. Odin compiles every file of a package, *_test.odin included, and
core:testing and the tests' core:os do not build for js, so the build compiles a copy of
src without its test files (build/web/tree/src, updated in place) and maps the compiler's
paths back to src. Odin's runtime leaves heap_allocator unimplemented on js, which the
sculpt engine allocates with on its jobs: the build runs Odin with an Odin root under
build/web whose base/ is a copy with web/odin_overlay laid over it (deps/odin is never
edited), and core/ and vendor/ linked to the real ones. The site needs no server headers
yet: one thread, no SharedArrayBuffer.
"""

import argparse
import functools
import http.server
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPS = os.path.join(ROOT, "deps")
ODIN = os.path.join(DEPS, "odin", "odin.exe" if os.name == "nt" else "odin")
OUT = os.path.join(ROOT, "build", "web")
TREE = os.path.join(OUT, "tree")
SITE = os.path.join(OUT, "site")
TARGET = "js_wasm64p32"
STRICT = ["-vet", "-strict-style", "-warnings-as-errors"]
# The wasm's memory comes from the page (web/index.html), which asks for up to 4 GB; the
# module must take it rather than make its own, and keep its function table for WebGPU's
# callbacks.
LINKER = "--export-table --import-memory --initial-memory=134217728 --max-memory=4294967296"


def mirror():
    """Copies src into build/web/tree/src without the test files, touching only what changed,
    and gives the copy the assets its packages #load."""
    src = os.path.join(ROOT, "src")
    dst = os.path.join(TREE, "src")
    wanted = set()
    for directory, _, files in os.walk(src):
        rel = os.path.relpath(directory, src)
        for name in files:
            if name.endswith("_test.odin"):
                continue
            path = os.path.normpath(os.path.join(rel, name))
            wanted.add(path)
            a, b = os.path.join(src, path), os.path.join(dst, path)
            sa = os.stat(a)
            try:
                sb = os.stat(b)
                if sb.st_size == sa.st_size and int(sb.st_mtime) == int(sa.st_mtime):
                    continue
            except FileNotFoundError:
                os.makedirs(os.path.dirname(b), exist_ok=True)
            shutil.copy2(a, b)
    # A file deleted or renamed in src goes from the copy too.
    for directory, _, files in os.walk(dst):
        for name in files:
            path = os.path.normpath(os.path.relpath(os.path.join(directory, name), dst))
            if path not in wanted:
                os.remove(os.path.join(directory, name))
    assets = os.path.join(TREE, "assets")
    if os.path.isdir(assets):
        shutil.rmtree(assets)
    shutil.copytree(os.path.join(ROOT, "assets"), assets)


def link_dir(source, link):
    """A link to a folder: a symlink, or on Windows a junction, which needs no privilege."""
    if os.name == "nt":
        import _winapi
        _winapi.CreateJunction(source, link)
    else:
        os.symlink(source, link)


def odin_root():
    """build/web/odin_root: deps/odin with web/odin_overlay laid over it. Each folder that
    holds an overlay file is a copy, every folder on the way to one is made of links to the
    real folders beside it, and everything else is a link, so deps/odin is never written."""
    real = os.path.join(DEPS, "odin")
    root = os.path.join(OUT, "odin_root")
    if os.path.isdir(root):
        clear_links(root)
    os.makedirs(root, exist_ok=True)
    overlay = os.path.join(ROOT, "web", "odin_overlay")
    files = []
    for directory, _, names in os.walk(overlay):
        for name in names:
            files.append(os.path.relpath(os.path.join(directory, name), overlay))
    copied = {os.path.dirname(f) for f in files} | {os.path.dirname(p[0]) for p in PATCHES}
    on_the_way = {os.path.join(*parts[:i]) for d in copied for parts in [d.split(os.sep)] for i in range(1, len(parts))}

    def lay(rel):
        source = os.path.join(real, rel) if rel else real
        for name in sorted(os.listdir(source)):
            child = os.path.join(rel, name) if rel else name
            here, there = os.path.join(source, name), os.path.join(root, child)
            if not os.path.isdir(here):
                if rel:
                    shutil.copy2(here, there)
                continue
            if child in copied:
                shutil.copytree(here, there)
            elif child in on_the_way:
                os.makedirs(there, exist_ok=True)
                lay(child)
            else:
                link_dir(here, there)
    lay("")
    for rel in files:
        target = os.path.join(root, rel)
        # A new file is fine where a folder was copied; a file that replaces nothing in a
        # folder Odin's own never had is a sign the overlay is out of date.
        shutil.copy2(os.path.join(overlay, rel), target)
    for rel, old, new in PATCHES:
        target = os.path.join(root, rel)
        with open(target, encoding="utf-8") as f:
            text = f.read()
        if old not in text:
            raise SystemExit(f"web: {rel} no longer has the line the web build changes; the patch is out of date")
        with open(target, "w", encoding="utf-8", newline="\n") as f:
            f.write(text.replace(old, new, 1))
    return root


# Lines of Odin's own files the web build changes, in the copies odin_root makes: core:flags
# names core:net only where it parses a host, which js leaves out, and -vet then refuses
# the unused import.
PATCHES = [
    ("core/flags/internal_rtti.odin", 'import            "core:net"', '@(require) import "core:net"'),
]


def clear_links(root):
    """Removes build/web/odin_root without following its links into deps/odin."""
    for name in os.listdir(root):
        path = os.path.join(root, name)
        if os.path.islink(path) or (os.name == "nt" and os.path.isjunction(path)):
            os.unlink(path)
        elif os.path.isdir(path):
            clear_links(path)
            os.rmdir(path)
        else:
            os.remove(path)


def odin(args):
    """Runs Odin on the copy with the overlaid root, printing its diagnostics with src's paths."""
    env = dict(os.environ, ODIN_ROOT=odin_root())
    proc = subprocess.run([ODIN, *args], cwd=ROOT, capture_output=True, text=True, env=env)
    tree_src = os.path.join(TREE, "src")
    for stream, text in ((sys.stdout, proc.stdout), (sys.stderr, proc.stderr)):
        if text:
            stream.write(text.replace(tree_src, os.path.join(ROOT, "src")))
    return proc.returncode


def build(debug):
    mirror()
    os.makedirs(SITE, exist_ok=True)
    flags = ["-debug"] if debug else ["-o:speed"]
    code = odin(["build", os.path.join(TREE, "src", "web"), f"-target:{TARGET}", f"-out:{os.path.join(SITE, 'sculpt.wasm')}",
                 f"-collection:deps={DEPS}", *STRICT, *flags, f"-extra-linker-flags:{LINKER}"])
    if code != 0:
        return code
    shutil.copy2(os.path.join(DEPS, "odin", "core", "sys", "wasm", "js", "odin.js"), SITE)
    shutil.copy2(os.path.join(DEPS, "odin", "vendor", "wgpu", "wgpu.js"), SITE)
    shutil.copy2(os.path.join(ROOT, "web", "index.html"), SITE)
    size = os.path.getsize(os.path.join(SITE, "sculpt.wasm"))
    print(f"web: build/web/site ({'debug' if debug else 'release'}, sculpt.wasm {size / 1e6:.1f} MB)")
    return 0


def check():
    mirror()
    code = odin(["check", os.path.join(TREE, "src", "web"), f"-target:{TARGET}", f"-collection:deps={DEPS}", *STRICT])
    if code == 0:
        print("webcheck: src/web and render/webgpu type-check for js_wasm64p32")
    return code


def serve(port):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=SITE)
    # WebGPU needs a secure context, which localhost is.
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"web: serving build/web/site at http://localhost:{port} (Ctrl+C stops)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


def test():
    """Runs scripts/web_check.mjs on the build, or says why it cannot: it needs Node and
    Playwright's Chromium, which a machine set up only for the desktop build may lack."""
    node = shutil.which("node")
    if node is None:
        print("webtest: skipped, no Node (scripts/web_check.mjs needs Node and Playwright)")
        return 0
    probe = subprocess.run([node, "-e", "require('playwright')"], capture_output=True,
                           env=dict(os.environ, NODE_PATH=subprocess.run(["npm", "root", "-g"], capture_output=True, text=True, shell=os.name == "nt").stdout.strip()))
    if probe.returncode != 0:
        print("webtest: skipped, Node has no Playwright (npm i -g playwright; npx playwright install chromium)")
        return 0
    return subprocess.run([node, os.path.join(ROOT, "scripts", "web_check.mjs")], cwd=ROOT).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--debug", action="store_true", help="bounds checks and debug info")
    parser.add_argument("--check", action="store_true", help="type-check only")
    parser.add_argument("--serve", action="store_true", help="serve the site after building it")
    parser.add_argument("--test", action="store_true", help="run scripts/web_check.mjs after building")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    if not os.path.exists(ODIN):
        print("deps missing: run scripts/setup_deps first")
        return 1
    if args.check:
        return check()
    code = build(args.debug)
    if code == 0 and args.test:
        code = test()
    if code == 0 and args.serve:
        return serve(args.port)
    return code


if __name__ == "__main__":
    sys.exit(main())
