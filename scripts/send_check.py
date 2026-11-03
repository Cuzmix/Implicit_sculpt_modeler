#!/usr/bin/env python3
"""Send between two app processes on this machine: a receiver as a desktop runs it and a
sender as a tablet runs it, over loopback.

    python scripts/send_check.py            # needs build/sculpt (build.bat / ./build.sh)
    python scripts/send_check.py --keep     # leaves build/send_check for a look

1. A receiver starts with --receive --send-allow --exit-after-receive in a send folder of
   its own; a sender makes a sphere, sends it with --send-to and saves it. The two have
   never met, so they pair first: both logs must show the same six digits. Every chunk
   goes over, the receiver opens the scene and exits, and both print the same file hash
   and the same mesh; the chunks go over shuffled and LZ4-coded, well under the file's size.
2. A new receiver in the same folder, and the saved scene sent again by a new sender in
   its folder: they are paired already, so no code is shown, and the receiver builds the
   file from the copy it kept, so fewer chunks than the file has go over. The hashes and
   the mesh must match again.

3. The same, found on the network (--send-to=@ and --send-to=@NAME): the receiver answers
   the sender's multicast DNS question, and the send goes to the address it answered from.
   A name no computer has is said so after the wait, and nothing is sent.
4. A send cut short (--send-cut-after=3 drops the connection after three chunks, as a lost
   Wi-Fi would) and the same scene sent again to the same receiver: the second send asks
   only for what the first did not write (but the first chunk, which holds the time the
   scene was written), read back from the partial file it kept, and the hashes and the
   mesh match.
5. Round trips, the scene the receiver already has coming back: the receiver saves its
   copy as pc_dragon.sculpt, then opens it and receives the scene again, which opens in
   place and says Save goes to pc_dragon.sculpt; then, with a new scene of two objects open
   (a duplicate), another scene's arrival is kept for later (--send-arrived=keep: the
   receiver's mesh stays its own) or opened (--send-arrived=open: the open scene is kept
   in the send folder's kept first, and the mesh is the sender's). A setup script's
   changes count as the scene's starting state, so the same scene changed here too is
   left to the app's own test (send_arrive_test.odin).
6. Back: a sender that receives too (as a tablet does while it is open) sends; the
   computer keeps where it came from as Send scene's target (send_last), and the scene
   sent there opens in place on the "tablet", unchanged there since it went out.

Each check prints PASS or FAIL and the script exits 1 on any FAIL. Like link_check, it is a
development aid outside the gate: it opens a port on loopback and runs two apps at once.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import headless  # noqa: E402

WINDOWS = os.name == "nt"
APP = os.path.join(ROOT, "build", "sculpt.exe" if WINDOWS else "sculpt")
WORK = os.path.join(ROOT, "build", "send_check")
# Far from the app's own port, so a desktop's running app is not disturbed.
PORT = 47931
WAIT = 300

failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def stat(log, key):
    m = re.findall(rf"\b{key}=(\S+)", log)
    return m[-1] if m else None


def mesh(log):
    return stat(log, "mesh_vertices"), stat(log, "mesh_triangles"), stat(log, "mesh_volume")


def receiver(env, tag, args=()):
    log_path = os.path.join(WORK, f"receive{tag}.log")
    log = open(log_path, "w")
    p = subprocess.Popen([APP, "--receive", "--send-allow", "--exit-after-receive", "--frames=6000",
                          "--send-folder=" + os.path.join(WORK, "pc"), f"--send-port={PORT}",
                          "--check-mesh"] + list(args), env=env, stdout=log, stderr=subprocess.STDOUT, cwd=ROOT)
    # The sender starts once the receiver says it is listening, or the send would find
    # nobody there; a receiver that dies first ends the wait.
    start = time.monotonic()
    while time.monotonic() - start < WAIT:
        with open(log_path, errors="replace") as f:
            if "receiving scenes on port" in f.read():
                break
        if p.poll() is not None:
            break
        time.sleep(0.2)
    return p, log, log_path


def sender(env, tag, args, target, folder="tab"):
    log_path = os.path.join(WORK, f"send{tag}.log")
    with open(log_path, "w") as log:
        p = subprocess.run([APP, "--frames=60", "--send-folder=" + os.path.join(WORK, folder),
                            "--send-to=" + target, "--check-mesh"] + args,
                           env=env, stdout=log, stderr=subprocess.STDOUT, cwd=ROOT, timeout=WAIT)
    with open(log_path, errors="replace") as f:
        return p.returncode, f.read()


def finish(p, log, log_path):
    try:
        code = p.wait(timeout=WAIT)
    except subprocess.TimeoutExpired:
        p.kill()
        code = p.wait()
    log.close()
    with open(log_path, errors="replace") as f:
        return code, f.read()


def round_trip(env, tag, args, target=f"127.0.0.1:{PORT}", receiver_args=(), same_mesh=True):
    r = receiver(env, tag, receiver_args)
    s_code, s_log = sender(env, tag, args, target)
    r_code, r_log = finish(*r)
    check(f"{tag}: sender exits 0", s_code == 0, f"exit {s_code}")
    check(f"{tag}: receiver exits 0", r_code == 0, f"exit {r_code}")
    check(f"{tag}: no leaks", "allocation tracking: no leaks" in s_log and "allocation tracking: no leaks" in r_log)
    check(f"{tag}: one sent, one received", stat(s_log, "send_sent") == "1" and stat(r_log, "send_received") == "1",
          f"sent {stat(s_log, 'send_sent')}, received {stat(r_log, 'send_received')}")
    sh, rh = stat(s_log, "send_sent_hash"), stat(r_log, "send_received_hash")
    check(f"{tag}: the same file hash", sh is not None and sh == rh and sh != "0" * 16, f"{sh} {rh}")
    if same_mesh:
        check(f"{tag}: the same mesh", mesh(s_log) == mesh(r_log) and mesh(s_log)[0] is not None,
              f"{mesh(s_log)} {mesh(r_log)}")
    return s_log, r_log


def chunks(log):
    m = re.findall(r"(\d+) of (\d+) chunks went over", log)
    return (int(m[-1][0]), int(m[-1][1])) if m else (None, None)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep", action="store_true", help="keep build/send_check")
    a = ap.parse_args()
    if not os.path.exists(APP):
        print(f"no {APP}: build the app first")
        return 1
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    env = headless.env()
    scene = os.path.join(WORK, "tab.sculpt")

    s_log, r_log = round_trip(env, "first", ["--vertices=200000", "--save=" + scene])
    codes_s = re.findall(r"shows (\d{3} \d{3})", s_log)
    codes_r = re.findall(r"code (\d{3} \d{3})", r_log)
    check("first: paired with the same code on both", codes_s and codes_s == codes_r, f"{codes_s} {codes_r}")
    went, total = chunks(r_log)
    check("first: every chunk went over", went is not None and went == total, f"{went} of {total}")
    wire = int(stat(s_log, "send_wire_bytes") or 0)
    size = os.path.getsize(scene) if os.path.exists(scene) else 0
    check("first: the chunks went over packed, well under the file", 0 < wire < size * 0.7, f"{wire} of {size} bytes")

    s_log, r_log = round_trip(env, "again", ["--open=" + scene])
    check("again: no pairing", "Pairing with" not in s_log and "Paired with" not in r_log)
    went, total = chunks(r_log)
    check("again: only some chunks went over", went is not None and went < total, f"{went} of {total}")

    # Found on the network rather than by address: the receiver answers the sender's
    # question for the service, by this machine's name and then as the first to answer.
    with open(os.path.join(WORK, "receiveagain.log"), errors="replace") as f:
        names = re.findall(r"answering for (.+) on the local network", f.read())
    check("found: the receiver answers on the network", bool(names), names[-1] if names else "no 'answering for' line")
    if names:
        for tag, target in (("found", "@"), ("named", "@" + names[-1])):
            s_log, r_log = round_trip(env, tag, ["--open=" + scene], target)
            check(f"{tag}: found the receiver", stat(s_log, "send_found") == "1", f"send_found={stat(s_log, 'send_found')}")
            check(f"{tag}: no pairing", "Pairing with" not in s_log and "Paired with" not in r_log)
        _, s_log = sender(env, "nobody", ["--vertices=2000"], "@no such computer")
        check("nobody: a name nobody has is said so", "No computer called no such computer answered" in s_log
              and stat(s_log, "send_sent") == "0" and stat(s_log, "send_found") == "0")

    # Cut short, then carried on: a new scene (so no copy of it to start from), its send
    # dropped after three chunks, then sent again to the same receiver.
    big = os.path.join(WORK, "big.sculpt")
    r = receiver(env, "resume")
    _, cut_log = sender(env, "cut", ["--vertices=400000", "--save=" + big, "--send-cut-after=3"], f"127.0.0.1:{PORT}")
    check("cut: the sender says the connection dropped", "dropped after 3 of" in cut_log and stat(cut_log, "send_sent") == "0")
    s_code, s_log = sender(env, "resume", ["--open=" + big], f"127.0.0.1:{PORT}")
    r_code, r_log = finish(*r)
    check("resume: both exit 0", s_code == 0 and r_code == 0, f"exit {s_code} {r_code}")
    check("resume: no leaks", "allocation tracking: no leaks" in s_log and "allocation tracking: no leaks" in r_log)
    sh, rh = stat(s_log, "send_sent_hash"), stat(r_log, "send_received_hash")
    check("resume: the same file hash", sh is not None and sh == rh and sh != "0" * 16, f"{sh} {rh}")
    check("resume: the same mesh", mesh(s_log) == mesh(r_log) and mesh(s_log)[0] is not None, f"{mesh(s_log)} {mesh(r_log)}")
    went, total = chunks(r_log)
    # The three chunks the cut send wrote are the file's first, and the first holds the time
    # the scene was written, which differs between the two sends: the other two are not
    # sent again.
    check("resume: the chunks the cut send wrote are not sent again", went is not None and went <= total - 2, f"{went} of {total}")

    # Round trips: the receiver's copy of the scene, saved where a person would keep it.
    received = os.path.join(WORK, "pc", "received")
    copies = [f for f in os.listdir(received) if f.endswith(".sculpt")] if os.path.isdir(received) else []
    dragon = os.path.join(WORK, "pc_dragon.sculpt")
    first_copy = None
    # The copy the first sends made: the 200k scene's, the smaller of the two.
    if copies:
        first_copy = min((os.path.join(received, f) for f in copies), key=os.path.getsize)
    check("trip: the receiver kept the scene's copy", first_copy is not None, str(copies))
    if first_copy:
        with open(os.path.join(WORK, "savecopy.log"), "w") as log:
            subprocess.run([APP, "--open=" + first_copy, "--frames=5", "--save=" + dragon,
                            "--send-folder=" + os.path.join(WORK, "pc")],
                           env=env, stdout=log, stderr=subprocess.STDOUT, cwd=ROOT, timeout=WAIT)
        _, r_log = round_trip(env, "inplace", ["--open=" + scene], receiver_args=["--open=" + dragon])
        check("inplace: opened in place, saving where it was saved", "opened it in place; Save goes to pc_dragon.sculpt" in r_log)
        s_log, r_log = round_trip(env, "keep", ["--open=" + scene], same_mesh=False,
                                  receiver_args=["--script=duplicate_object", "--send-arrived=keep"])
        check("keep: kept for later, the receiver's own mesh stays", "Kept for later in Received" in r_log
              and mesh(r_log)[1] is not None and mesh(r_log) != mesh(s_log), f"{mesh(s_log)} {mesh(r_log)}")
        s_log, r_log = round_trip(env, "open", ["--open=" + scene],
                                  receiver_args=["--script=duplicate_object", "--send-arrived=open"])
        kept = os.listdir(os.path.join(WORK, "pc", "kept")) if os.path.isdir(os.path.join(WORK, "pc", "kept")) else []
        check("open: the changed copy is kept first", "the scene open before is kept as" in r_log and len(kept) == 1, str(kept))

    # Back: the "tablet" receives too (on a port of its own) while it sends; the computer
    # remembers where it came from as Send scene's target, and a send there opens in place,
    # the scene being unchanged on the tablet since it went out.
    back_port = PORT + 1
    settings = os.path.join(WORK, "pc_settings.txt")
    r = receiver(env, "back", ["--settings-file=" + settings])
    tab_log_path = os.path.join(WORK, "sendback.log")
    tab_log = open(tab_log_path, "w")
    tab = subprocess.Popen([APP, "--open=" + scene, "--frames=6000", "--send-folder=" + os.path.join(WORK, "tab"),
                            f"--send-to=127.0.0.1:{PORT}", "--receive", f"--send-port={back_port}",
                            "--exit-after-receive", "--check-mesh"],
                           env=env, stdout=tab_log, stderr=subprocess.STDOUT, cwd=ROOT)
    r_code, r_log = finish(*r)
    check("back: the computer received", stat(r_log, "send_received") == "1", f"exit {r_code}")
    last = ""
    if os.path.exists(settings):
        with open(settings, errors="replace") as f:
            m = re.findall(r"^send_last (\S+)", f.read(), re.M)
            last = m[-1] if m else ""
    check("back: Send scene's target is where the tablet listens", last.startswith(f"127.0.0.1:{back_port}%7C")
          or last.startswith(f"127.0.0.1:{back_port}|"), last)
    # The computer's copy of the scene the tablet sent: the smallest it holds.
    copy = min((os.path.join(received, f) for f in os.listdir(received) if f.endswith(".sculpt")), key=os.path.getsize)
    _, pc_log = sender(env, "pcback", ["--open=" + copy], f"127.0.0.1:{back_port}", folder="pc")
    t_code, t_log = finish(tab, tab_log, tab_log_path)
    check("back: the tablet got it back and opened it in place", "opened it in place" in t_log and t_code == 0, f"exit {t_code}")
    check("back: the same mesh", mesh(pc_log) == mesh(t_log) and mesh(t_log)[0] is not None, f"{mesh(pc_log)} {mesh(t_log)}")

    if not a.keep:
        shutil.rmtree(WORK, ignore_errors=True)
    print("send_check: " + ("all passed" if not failures else f"{len(failures)} failed"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
