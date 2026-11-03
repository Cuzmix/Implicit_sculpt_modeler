#!/usr/bin/env python3
"""Builds the web version (README "Web") into build/web/site, or type-checks it.

    python scripts/web_build.py            # release: build/web/site/{index.html,sculpt.wasm,odin.js,wgpu.js,sdl_web.js}
    python scripts/web_build.py --debug    # with bounds checks and debug info
    python scripts/web_build.py --check    # odin check only, with the strict flags
    python scripts/web_build.py --serve    # build, then serve the site at http://localhost:8000
    python scripts/web_build.py --serve --lan  # the same over HTTPS on this computer's network address, for a tablet
    python scripts/web_build.py --test     # build, then scripts/web_check.mjs in headless Chromium

The page runs the whole app, src/app (src/app/web.odin is its web entry), drawn by render's
WebGPU backend, with web/sdl_web.js answering SDL's procs, compiled by Odin's own wasm
target, js_wasm64p32: Odin's int stays 64-bit as on the desktop while pointers are 32-bit,
as browsers need. Odin compiles every file of a package, *_test.odin included, and
core:testing and the tests' core:os do not build for js, so the build compiles a copy of
src without its test files (build/web/tree/src, updated in place) and maps the compiler's
paths back to src. Odin's runtime leaves heap_allocator unimplemented on js, which the
sculpt engine allocates with on its jobs, and core:os and core:thread have nothing for js:
the build runs Odin with an Odin root under
build/web whose base/ is a copy with web/odin_overlay laid over it (deps/odin is never
edited), and core/ and vendor/ linked to the real ones. The site needs no server headers
yet: one thread, no SharedArrayBuffer.
"""

import argparse
import functools
import http.server
import os
import re
import shutil
import socket
import ssl
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
# vendor:sdl3 imports SDL's procs from the page (web/sdl_web.js) rather than linking SDL.
DEFINES = ["-define:SDL3_WASM_LIB=sdl3"]
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


def own_file(root, rel):
    """The path of rel under odin_root, refusing one that a link leads back into deps/odin:
    the web build changes only its own copies."""
    target = os.path.join(root, os.path.normpath(rel))
    inside, home = os.path.realpath(target), os.path.realpath(root)
    if os.path.commonpath([inside, home]) != home:
        raise SystemExit(f"web: {rel} is reached through a link into {os.path.dirname(inside)}; the web build would change deps/odin")
    return target


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
    # PATCHES names its files with forward slashes while the walk below joins with the
    # system's separator, so every name is normalised: on Windows "core/flags" never matched
    # the walk's own name, the folder became a junction and the patches went into deps/odin.
    copied = {os.path.normpath(os.path.dirname(f)) for f in files} | {os.path.normpath(os.path.dirname(p[0])) for p in PATCHES} | {os.path.normpath(r[0]) for r in REWRITES}
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
        target = own_file(root, rel)
        # A new file is fine where a folder was copied; a file that replaces nothing in a
        # folder Odin's own never had is a sign the overlay is out of date.
        shutil.copy2(os.path.join(overlay, rel), target)
    for folder, pattern, replacement in REWRITES:
        for name in sorted(os.listdir(os.path.join(root, folder))):
            if not name.endswith(".odin"):
                continue
            target = own_file(root, os.path.join(folder, name))
            with open(target, encoding="utf-8") as f:
                text = f.read()
            with open(target, "w", encoding="utf-8", newline="\n") as f:
                f.write(re.sub(pattern, replacement, text))
    for rel, old, new in PATCHES:
        target = own_file(root, rel)
        with open(target, encoding="utf-8") as f:
            text = f.read()
        if old not in text:
            raise SystemExit(f"web: {rel} no longer has the line the web build changes; the patch is out of date")
        with open(target, "w", encoding="utf-8", newline="\n") as f:
            f.write(text.replace(old, new, 1))
    return root


# Lines of Odin's own files the web build changes, in the copies odin_root makes: core:flags
# names core:net only where it parses a host, which js leaves out, and -vet then refuses
# the unused import; and Odin's wasm64p32 code generation stops on an assertion at a global
# slice made from constants (zlib's and PNG's tables), which a fixed array of the same
# values avoids. The app's own code keeps clear of them (and of #load as bytes rather than a
# string) for the same reason.
PATCHES = [
    ("core/flags/internal_rtti.odin", 'import            "core:net"', '@(require) import "core:net"'),
    ("core/compress/zlib/zlib.odin", "Z_LENGTH_DEZIGZAG := []u8{", "Z_LENGTH_DEZIGZAG := [?]u8{"),
    ("core/image/png/png.odin", "ADAM7_X_ORIG    := []int{", "ADAM7_X_ORIG    := [?]int{"),
    ("core/image/png/png.odin", "ADAM7_Y_ORIG    := []int{", "ADAM7_Y_ORIG    := [?]int{"),
    ("core/image/png/png.odin", "ADAM7_X_SPACING := []int{", "ADAM7_X_SPACING := [?]int{"),
    ("core/image/png/png.odin", "ADAM7_Y_SPACING := []int{", "ADAM7_Y_SPACING := [?]int{"),
    # Two lengths REWRITES leaves as Odin's int where the shim now takes 32 bits.
    ("vendor/libc-shim/string.odin", "return len(sdst)", "return u32(len(sdst))"),
    ("vendor/libc-shim/stdio.odin", "size_of(byte), len(buf), file)", "size_of(byte), u32(len(buf)), file)"),
]


# Words of Odin's own folders the web build replaces in every file of its copies:
# vendor:stb's C objects for wasm are built for wasm32, whose size_t is 32 bits, while
# vendor:libc-shim, which answers their malloc, memcpy and the rest, takes Odin's uint, 64
# bits on wasm64p32, so the linker would turn every call into a trap.
REWRITES = [
    (os.path.join("vendor", "libc-shim"), r"\buint\b", "u32"),
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
    # -o:minimal rather than -o:speed: LLVM's wasm back end stops on the vectors of f16 the
    # optimiser makes of the app's half-float loops (the detail skin, EXR, environments).
    flags = ["-debug"] if debug else ["-o:minimal"]
    code = odin(["build", os.path.join(TREE, "src", "app"), f"-target:{TARGET}", f"-out:{os.path.join(SITE, 'sculpt.wasm')}",
                 f"-collection:deps={DEPS}", *DEFINES, *STRICT, *flags, f"-extra-linker-flags:{LINKER}"])
    if code != 0:
        return code
    shutil.copy2(os.path.join(DEPS, "odin", "core", "sys", "wasm", "js", "odin.js"), SITE)
    shutil.copy2(os.path.join(DEPS, "odin", "vendor", "wgpu", "wgpu.js"), SITE)
    shutil.copy2(os.path.join(ROOT, "web", "index.html"), SITE)
    shutil.copy2(os.path.join(ROOT, "web", "sdl_web.js"), SITE)
    size = os.path.getsize(os.path.join(SITE, "sculpt.wasm"))
    print(f"web: build/web/site ({'debug' if debug else 'release'}, sculpt.wasm {size / 1e6:.1f} MB)")
    return 0


def check():
    mirror()
    code = odin(["check", os.path.join(TREE, "src", "app"), f"-target:{TARGET}", f"-collection:deps={DEPS}", *DEFINES, *STRICT])
    if code == 0:
        print("webcheck: src/app type-checks for js_wasm64p32")
    return code


def lan_address():
    """This computer's address on the local network: the one a route out would leave from
    (a UDP connect sends nothing)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
        except OSError:
            return None


def find_openssl():
    """openssl on PATH, or the one Git for Windows ships beside git.exe."""
    found = shutil.which("openssl")
    if found:
        return found
    git = shutil.which("git")
    if git:
        base = os.path.dirname(os.path.dirname(os.path.realpath(git)))
        for rel in (("mingw64", "bin", "openssl.exe"), ("usr", "bin", "openssl.exe")):
            path = os.path.join(base, *rel)
            if os.path.exists(path):
                return path
    return None


def lan_certificate(address):
    """A self-signed certificate for address, made once per address in build/web/cert, so a
    tablet that accepted it once is not asked again until the computer's address changes."""
    folder = os.path.join(OUT, "cert")
    cert, key = os.path.join(folder, f"{address}.crt"), os.path.join(folder, f"{address}.key")
    if os.path.exists(cert) and os.path.exists(key):
        return cert, key
    openssl = find_openssl()
    if openssl is None:
        raise SystemExit("web: --lan needs openssl to make its certificate (Git for Windows ships one)")
    os.makedirs(folder, exist_ok=True)
    subprocess.run([openssl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-days", "365", "-subj", "/CN=Sculpt web (this computer)",
                    "-addext", f"subjectAltName=IP:{address},DNS:localhost,IP:127.0.0.1",
                    "-keyout", key, "-out", cert], check=True, capture_output=True)
    return cert, key


class Tls_Server(http.server.ThreadingHTTPServer):
    """HTTPS with each connection's handshake on that connection's own thread. A listening
    socket wrapped whole shakes hands inside accept, on the one thread that accepts, so a
    browser showing its certificate warning, which keeps its connection open and silent,
    stopped the server answering anyone."""

    HANDSHAKE_SECONDS = 10

    def __init__(self, address, handler, context):
        self.context = context
        super().__init__(address, handler)

    def finish_request(self, request, address):
        request.settimeout(self.HANDSHAKE_SECONDS)
        try:
            first = request.recv(1, socket.MSG_PEEK)
        except OSError:
            return
        if first != b"\x16":
            # Not a TLS handshake: an address typed without https:// reaches here as plain
            # HTTP, which is sent on to the same address over HTTPS rather than dropped.
            self.redirect(request)
            return
        try:
            tls = self.context.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            # A browser that has not accepted the certificate yet hangs up here.
            return
        # The wrapped socket replaces the accepted one, which the server's own close no
        # longer reaches, so it is closed here.
        try:
            tls.settimeout(None)
            super().finish_request(tls, address)
        finally:
            self.shutdown_request(tls)

    def redirect(self, request):
        try:
            head = request.recv(8192).decode("latin-1")
            host = next((line.split(":", 1)[1].strip() for line in head.split("\r\n") if line.lower().startswith("host:")), None)
            path = head.split(" ", 2)[1] if head.count(" ") >= 2 else "/"
            if host is None or not path.startswith("/"):
                return
            target = f"https://{host}{path}"
            request.sendall((f"HTTP/1.1 301 Moved Permanently\r\nLocation: {target}\r\n"
                             "Content-Length: 0\r\nConnection: close\r\n\r\n").encode("latin-1"))
        except OSError:
            pass

    def handle_error(self, request, address):
        # A tablet that drops a connection mid-file is not worth a traceback.
        if not isinstance(sys.exc_info()[1], (ConnectionError, ssl.SSLError, TimeoutError)):
            super().handle_error(request, address)


class Site_Handler(http.server.SimpleHTTPRequestHandler):
    """The site's files, and POST /failure, where the page sends the message and last log
    lines of a failure, a script error or a start still loading after ten seconds
    (web/index.html), printed here since a tablet has no console."""

    def do_POST(self):
        if self.path != "/failure":
            self.send_error(404)
            return
        length = min(int(self.headers.get("Content-Length") or 0), 64 * 1024)
        text = self.rfile.read(length).decode("utf-8", "replace")
        print(f"web: report from {self.client_address[0]}:", flush=True)
        for line in text.splitlines():
            print(f"    {line}", flush=True)
        self.send_response(204)
        self.end_headers()


def serve(port, lan):
    handler = functools.partial(Site_Handler, directory=SITE)
    if not lan:
        # WebGPU needs a secure context, which localhost is.
        with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
            print(f"web: serving build/web/site at http://localhost:{port} (Ctrl+C stops)")
            try:
                httpd.serve_forever()
            except KeyboardInterrupt:
                pass
        return 0
    # Another device reaches this computer by its address, which a browser counts as a
    # secure context only over HTTPS, and WebGPU exists only in a secure context: plain
    # HTTP there gives the page no navigator.gpu. So the network gets HTTPS with a
    # self-signed certificate, which each browser asks to accept once.
    address = lan_address()
    if address is None:
        raise SystemExit("web: --lan found no local network address")
    cert, key = lan_certificate(address)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    with Tls_Server(("0.0.0.0", port), handler, context) as httpd:
        print(f"web: serving build/web/site at https://{address}:{port} to this network, and https://localhost:{port} here (Ctrl+C stops)")
        print("web: each browser warns once about the self-signed certificate; continue past it to open the app")
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
    parser.add_argument("--lan", action="store_true", help="with --serve: HTTPS on this computer's network address, for a tablet")
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
        return serve(args.port, args.lan)
    return code


if __name__ == "__main__":
    sys.exit(main())
