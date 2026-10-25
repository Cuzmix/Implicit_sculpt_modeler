// The Draw brush's hot loops in Dart, written the same way as ../../main.odin over the
// same mesh and stroke, so the two print comparable rows. Dart isolates share no heap,
// so the mesh lives in native memory (package:ffi) and every isolate views it through
// typed lists: the fastest way Dart has to let several threads write one mesh. With
// one thread the main isolate runs everything; with N, it and N - 1 worker isolates
// each take a contiguous share of the nodes, and the main isolate waits for replies
// between phases, as the Odin job pool waits for its workers.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const tile = 16;
const tileVerts = (tile + 1) * (tile + 1);
const tileTris = tile * tile * 2;
const dabs = 77;
const dabsPerFrame = 4;
const radius = 0.13;
const strength = 0.3;
const drawHeight = 0.1;

/// Addresses and sizes of the native buffers, which is all a worker needs to view them.
class Layout {
  final int nodes, pos, nrm, tris, bounds, touched, hit, sums, moved, list;
  Layout(this.nodes, this.pos, this.nrm, this.tris, this.bounds, this.touched, this.hit,
      this.sums, this.moved, this.list);
}

class Mesh {
  final int nodes;
  final Float32List pos, nrm, bounds, sums;
  final Uint32List tris, hit, moved, list;
  final Uint8List touched;
  Mesh(this.nodes, this.pos, this.nrm, this.tris, this.bounds, this.touched, this.hit,
      this.sums, this.moved, this.list);

  factory Mesh.view(Layout l) {
    final n = l.nodes, v = n * tileVerts;
    return Mesh(
      n,
      Pointer<Float>.fromAddress(l.pos).asTypedList(v * 3),
      Pointer<Float>.fromAddress(l.nrm).asTypedList(v * 3),
      Pointer<Uint32>.fromAddress(l.tris).asTypedList(n * tileTris * 3),
      Pointer<Float>.fromAddress(l.bounds).asTypedList(n * 6),
      Pointer<Uint8>.fromAddress(l.touched).asTypedList(n),
      Pointer<Uint32>.fromAddress(l.hit).asTypedList(n),
      Pointer<Float>.fromAddress(l.sums).asTypedList(n * 3),
      Pointer<Uint32>.fromAddress(l.moved).asTypedList(n),
      Pointer<Uint32>.fromAddress(l.list).asTypedList(n),
    );
  }
}

Layout allocate(int nodes) {
  final v = nodes * tileVerts;
  int a(int bytes) => calloc<Uint8>(bytes).address;
  return Layout(nodes, a(v * 12), a(v * 12), a(nodes * tileTris * 12), a(nodes * 24),
      a(nodes), a(nodes * 4), a(nodes * 12), a(nodes * 4), a(nodes * 4));
}

void release(Layout l) {
  for (final p in [l.pos, l.nrm, l.tris, l.bounds, l.touched, l.hit, l.sums, l.moved, l.list]) {
    calloc.free(Pointer<Uint8>.fromAddress(p));
  }
}

/// Builds the cube-sphere in the order the Odin version builds it.
void build(Mesh m, int tiles) {
  final side = (tiles * tile).toDouble();
  for (var face = 0; face < 6; face++) {
    for (var ti = 0; ti < tiles; ti++) {
      for (var tj = 0; tj < tiles; tj++) {
        final node = (face * tiles + ti) * tiles + tj;
        final base = node * tileVerts;
        for (var a = 0; a <= tile; a++) {
          for (var b = 0; b <= tile; b++) {
            final u = _f32((ti * tile + a) / side * 2 - 1);
            final v = _f32((tj * tile + b) / side * 2 - 1);
            double x, y, z;
            switch (face) {
              case 0: x = 1; y = u; z = v;
              case 1: x = -1; y = v; z = u;
              case 2: x = u; y = 1; z = v;
              case 3: x = v; y = -1; z = u;
              case 4: x = u; y = v; z = 1;
              default: x = v; y = u; z = -1;
            }
            final l = math.sqrt(x * x + y * y + z * z);
            final i = (base + a * (tile + 1) + b) * 3;
            m.pos[i] = m.nrm[i] = x / l;
            m.pos[i + 1] = m.nrm[i + 1] = y / l;
            m.pos[i + 2] = m.nrm[i + 2] = z / l;
          }
        }
        var t = node * tileTris * 3;
        for (var a = 0; a < tile; a++) {
          for (var b = 0; b < tile; b++) {
            final i = base + a * (tile + 1) + b;
            m.tris[t] = i; m.tris[t + 1] = i + tile + 1; m.tris[t + 2] = i + 1;
            m.tris[t + 3] = i + 1; m.tris[t + 4] = i + tile + 1; m.tris[t + 5] = i + tile + 2;
            t += 6;
          }
        }
        nodeBounds(m, node);
      }
    }
  }
}

final _scratch = Float32List(1);
double _f32(double x) {
  _scratch[0] = x;
  return _scratch[0];
}

void nodeBounds(Mesh m, int node) {
  var lx = double.maxFinite, ly = lx, lz = lx, hx = -lx, hy = hx, hz = hx;
  final p = m.pos;
  for (var i = node * tileVerts * 3, e = i + tileVerts * 3; i < e; i += 3) {
    lx = math.min(lx, p[i]); ly = math.min(ly, p[i + 1]); lz = math.min(lz, p[i + 2]);
    hx = math.max(hx, p[i]); hy = math.max(hy, p[i + 1]); hz = math.max(hz, p[i + 2]);
  }
  final b = m.bounds, o = node * 6;
  b[o] = lx; b[o + 1] = ly; b[o + 2] = lz; b[o + 3] = hx; b[o + 4] = hy; b[o + 5] = hz;
}

double falloff(double x2) {
  if (x2 >= 1) return 0;
  final t = 1 - x2;
  return t * t;
}

// The three phases, each over hit-list (or touched-list) entries [lo, hi).

void area(Mesh m, int lo, int hi, double cx, double cy, double cz) {
  const r2 = radius * radius, invR2 = 1 / r2;
  final p = m.pos, n = m.nrm;
  for (var k = lo; k < hi; k++) {
    var sx = 0.0, sy = 0.0, sz = 0.0;
    for (var i = m.hit[k] * tileVerts * 3, e = i + tileVerts * 3; i < e; i += 3) {
      final dx = p[i] - cx, dy = p[i + 1] - cy, dz = p[i + 2] - cz;
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 < r2) {
        final w = falloff(d2 * invR2);
        sx += n[i] * w; sy += n[i + 1] * w; sz += n[i + 2] * w;
      }
    }
    m.sums[k * 3] = sx; m.sums[k * 3 + 1] = sy; m.sums[k * 3 + 2] = sz;
  }
}

void displace(Mesh m, int lo, int hi, double cx, double cy, double cz, double nx, double ny,
    double nz) {
  const r2 = radius * radius, invR2 = 1 / r2, amount = strength * drawHeight * radius;
  final p = m.pos;
  for (var k = lo; k < hi; k++) {
    final node = m.hit[k];
    var moved = 0;
    var lx = double.maxFinite, ly = lx, lz = lx, hx = -lx, hy = hx, hz = hx;
    for (var i = node * tileVerts * 3, e = i + tileVerts * 3; i < e; i += 3) {
      var x = p[i], y = p[i + 1], z = p[i + 2];
      final dx = x - cx, dy = y - cy, dz = z - cz;
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 < r2) {
        final w = falloff(d2 * invR2);
        if (w > 0) {
          final s = amount * w;
          p[i] = x += nx * s; p[i + 1] = y += ny * s; p[i + 2] = z += nz * s;
          x = p[i]; y = p[i + 1]; z = p[i + 2];
          moved++;
        }
      }
      lx = math.min(lx, x); ly = math.min(ly, y); lz = math.min(lz, z);
      hx = math.max(hx, x); hy = math.max(hy, y); hz = math.max(hz, z);
    }
    final b = m.bounds, o = node * 6;
    b[o] = lx; b[o + 1] = ly; b[o + 2] = lz; b[o + 3] = hx; b[o + 4] = hy; b[o + 5] = hz;
    m.moved[k] = moved;
    if (moved > 0) m.touched[node] = 1;
  }
}

void normals(Mesh m, int lo, int hi) {
  final p = m.pos, n = m.nrm, t = m.tris;
  for (var k = lo; k < hi; k++) {
    final node = m.list[k];
    final first = node * tileVerts * 3;
    n.fillRange(first, first + tileVerts * 3, 0);
    for (var j = node * tileTris * 3, e = j + tileTris * 3; j < e; j += 3) {
      final a = t[j] * 3, b = t[j + 1] * 3, c = t[j + 2] * 3;
      final ex = p[b] - p[a], ey = p[b + 1] - p[a + 1], ez = p[b + 2] - p[a + 2];
      final fx = p[c] - p[a], fy = p[c + 1] - p[a + 1], fz = p[c + 2] - p[a + 2];
      final cx = ey * fz - ez * fy, cy = ez * fx - ex * fz, cz = ex * fy - ey * fx;
      n[a] += cx; n[a + 1] += cy; n[a + 2] += cz;
      n[b] += cx; n[b + 1] += cy; n[b + 2] += cz;
      n[c] += cx; n[c + 1] += cy; n[c + 2] += cz;
    }
    for (var i = first, e = first + tileVerts * 3; i < e; i += 3) {
      final l = math.sqrt(n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2]);
      if (l > 0) {
        n[i] /= l; n[i + 1] /= l; n[i + 2] /= l;
      }
    }
  }
}

/// One phase message: which phase, the share of entries, and the dab's numbers.
void runPhase(Mesh m, List<num> msg) {
  final lo = msg[1] as int, hi = msg[2] as int;
  switch (msg[0]) {
    case 0: area(m, lo, hi, msg[3] as double, msg[4] as double, msg[5] as double);
    case 1:
      displace(m, lo, hi, msg[3] as double, msg[4] as double, msg[5] as double,
          msg[6] as double, msg[7] as double, msg[8] as double);
    default: normals(m, lo, hi);
  }
}

void worker(List<Object> args) {
  final reply = args[0] as SendPort;
  final layout = args[1] as Layout;
  final m = Mesh.view(layout);
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg == null) {
      inbox.close();
      return;
    }
    runPhase(m, msg as List<num>);
    reply.send(0);
  });
}

class Pool {
  final List<SendPort> ports;
  final StreamIterator<dynamic> replies;
  final ReceivePort inbox;
  Pool(this.ports, this.replies, this.inbox);

  static Future<Pool> start(int workers, Layout layout) async {
    final inbox = ReceivePort();
    final replies = StreamIterator(inbox);
    for (var w = 0; w < workers; w++) {
      await Isolate.spawn(worker, [inbox.sendPort, layout]);
    }
    final ports = <SendPort>[];
    for (var w = 0; w < workers; w++) {
      await replies.moveNext();
      ports.add(replies.current as SendPort);
    }
    return Pool(ports, replies, inbox);
  }

  /// Splits [0, count) into contiguous shares, one per worker plus the main isolate,
  /// runs them, and returns once every worker has replied.
  Future<void> run(Mesh m, int phase, int count, List<double> args) async {
    final shares = ports.length + 1;
    final per = (count + shares - 1) ~/ shares;
    var sent = 0;
    for (var w = 0; w < ports.length; w++) {
      final lo = math.min(count, (w + 1) * per), hi = math.min(count, (w + 2) * per);
      if (lo >= hi) break;
      ports[w].send(<num>[phase, lo, hi, ...args]);
      sent++;
    }
    runPhase(m, <num>[phase, 0, math.min(per, count), ...args]);
    for (var i = 0; i < sent; i++) {
      await replies.moveNext();
    }
  }

  void stop() {
    for (final p in ports) {
      p.send(null);
    }
    inbox.close();
  }
}

double median(List<double> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

Future<void> runStroke(Mesh m, Pool? pool, int vertices) async {
  final frames = (dabs + dabsPerFrame - 1) ~/ dabsPerFrame;
  final frame = List<double>.filled(frames, 0), norm = List<double>.filled(frames, 0);
  final dab = List<double>.filled(dabs, 0);
  var totalMoved = 0;
  final sw = Stopwatch()..start();
  double ms(int t0) => (sw.elapsedMicroseconds - t0) / 1000;
  for (var i = 0; i < dabs; i++) {
    final k = i / (dabs - 1);
    var x = -0.6 + 1.2 * k, y = 0.3 * math.sin(k * 4 * math.pi), z = 1.0;
    final l = math.sqrt(x * x + y * y + z * z);
    final cx = x / l, cy = y / l, cz = z / l;
    final tb = sw.elapsedMicroseconds;
    var hits = 0;
    final b = m.bounds;
    for (var n = 0; n < m.nodes; n++) {
      final o = n * 6;
      final qx = cx.clamp(b[o], b[o + 3]) - cx, qy = cy.clamp(b[o + 1], b[o + 4]) - cy,
          qz = cz.clamp(b[o + 2], b[o + 5]) - cz;
      if (qx * qx + qy * qy + qz * qz < radius * radius) m.hit[hits++] = n;
    }
    if (pool == null) {
      area(m, 0, hits, cx, cy, cz);
    } else {
      await pool.run(m, 0, hits, [cx, cy, cz]);
    }
    var sx = 0.0, sy = 0.0, sz = 0.0;
    for (var h = 0; h < hits; h++) {
      sx += m.sums[h * 3]; sy += m.sums[h * 3 + 1]; sz += m.sums[h * 3 + 2];
    }
    final sl = math.sqrt(sx * sx + sy * sy + sz * sz);
    final nx = sl > 0 ? sx / sl : 0.0, ny = sl > 0 ? sy / sl : 0.0, nz = sl > 0 ? sz / sl : 0.0;
    if (pool == null) {
      displace(m, 0, hits, cx, cy, cz, nx, ny, nz);
    } else {
      await pool.run(m, 1, hits, [cx, cy, cz, nx, ny, nz]);
    }
    for (var h = 0; h < hits; h++) {
      totalMoved += m.moved[h];
    }
    dab[i] = ms(tb);
    final f = i ~/ dabsPerFrame;
    frame[f] += dab[i];
    if (i % dabsPerFrame == dabsPerFrame - 1 || i == dabs - 1) {
      final tn = sw.elapsedMicroseconds;
      var count = 0;
      for (var n = 0; n < m.nodes; n++) {
        if (m.touched[n] != 0) {
          m.list[count++] = n;
          m.touched[n] = 0;
        }
      }
      if (pool == null) {
        normals(m, 0, count);
      } else {
        await pool.run(m, 2, count, const []);
      }
      norm[f] = ms(tn);
      frame[f] += norm[f];
    }
  }
  var checksum = 0.0;
  final p = m.pos;
  for (var i = 0; i < p.length; i += 3) {
    checksum += p[i] + p[i + 1] * 3 + p[i + 2] * 7;
  }
  final threads = pool == null ? 1 : pool.ports.length + 1;
  print('| Dart | $threads | $vertices | ${totalMoved ~/ dabs} | ${median(dab).toStringAsFixed(3)} '
      '| ${median(norm).toStringAsFixed(3)} | ${median(frame).toStringAsFixed(2)} '
      '| ${frame.reduce(math.max).toStringAsFixed(2)} | ${checksum.toStringAsFixed(4)} |');
}

int tilesFor(int target) => math.max(1, math.sqrt(target / (6 * tileVerts)).round());

/// Usage: kernel [sizes...] [--threads=N]; sizes default to 1M 5M 10M, threads to one
/// per core, as the Odin version.
Future<void> main(List<String> args) async {
  var threads = Platform.numberOfProcessors;
  final sizes = <int>[];
  for (final a in args) {
    if (a.startsWith('--threads=')) {
      threads = int.parse(a.substring(10));
    } else {
      sizes.add(int.parse(a));
    }
  }
  if (sizes.isEmpty) sizes.addAll([1000000, 5000000, 10000000]);
  for (final target in sizes) {
    final tiles = tilesFor(target);
    final nodes = 6 * tiles * tiles;
    for (final parallel in [false, true]) {
      final layout = allocate(nodes);
      final m = Mesh.view(layout);
      build(m, tiles);
      final pool = parallel ? await Pool.start(threads - 1, layout) : null;
      await runStroke(m, pool, nodes * tileVerts);
      pool?.stop();
      release(layout);
    }
  }
}
