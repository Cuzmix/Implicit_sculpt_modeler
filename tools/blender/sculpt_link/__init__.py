# SPDX-License-Identifier: GPL-3.0-or-later
"""Sculpt link: Blender's side of the Sculpt app's live link (README "Blender link").

Sculpt's Send to Blender writes each object as `<id>.ply` and then `link.txt` into a
folder; Get from Sculpt here brings them in. Send to Sculpt here writes the selected mesh
objects as `blender-<id>.ply` and then `blender.txt`, which Sculpt takes back with Get from
Blender, or by itself when its window gets the focus. Nothing else passes between the two:
no network, no program started.

Each send from Sculpt also lists its lights that are on, which Get from Sculpt makes
Blender lights of in a "Sculpt lights" collection, with the same watts a glTF export of
them gives (Bring lights in the panel; on by default). Lights go one way only.

Positions stay in the object's own space and are never converted, so a mesh left alone
goes back to Sculpt bit for bit; the turn from Sculpt's Y up to Blender's Z up is in the
object's matrix instead. A mesh from Sculpt is triangles already and keeps its vertex and
triangle order, which is how Sculpt knows a mesh came back with the same triangles and
moves its vertices rather than rebuilding it.

The functions under "The files" and "The link" need no interface and are what
scripts/link_check.py drives with bpy as a module; the panel is a thin layer over them.
"""

import math
import os
import struct
import sys

import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

bl_info = {
    "name": "Sculpt link",
    "author": "Implicit",
    "version": (1, 1, 0),
    "blender": (4, 2, 0),
    "location": "3D Viewport > Sidebar > Sculpt",
    "description": "Sends meshes to and from the Sculpt app, as GoZ does for ZBrush",
    "category": "Import-Export",
}

LIGHT_COLLECTION = "Sculpt lights"
LIGHT_TYPES = {"directional": "SUN", "point": "POINT", "spot": "SPOT"}
# Lumens a watt, as glTF's importers turn lux and candela into a sun's and a lamp's watts.
LUMENS_PER_WATT = 683

SENT_FILE = "link.txt"
BACK_FILE = "blender.txt"
VERSION = 1

# Sculpt is Y up and Blender Z up: Sculpt's (x, y, z) is Blender's (x, -z, y), a quarter
# turn about X.
Y_UP_TO_Z_UP = Matrix.Rotation(math.pi / 2, 4, "X")


# The files.

def default_folder():
    """Where the app keeps its link folder on this system: beside its settings, in the
    folder SDL's GetPrefPath("Implicit", "Sculpt") gives."""
    if sys.platform.startswith("win"):
        base = os.environ.get("APPDATA", os.path.expanduser("~"))
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, "Implicit", "Sculpt", "link")


def name_word(name):
    """A name as one word of a manifest, as Sculpt writes one: %, every control byte and
    space, and every byte of a character past ASCII (some of which are white space to a
    reader splitting at it) as %XX of its UTF-8 bytes, and "-" for no name."""
    word = "".join(chr(b) if 0x21 <= b < 0x7F and b != 0x25 else f"%{b:02X}" for b in name.encode("utf-8"))
    return {"": "-", "-": "%2D"}.get(word, word)


def name_from_word(word):
    if word == "-":
        return ""
    out, i = bytearray(), 0
    raw = word.encode()
    while i < len(raw):
        if raw[i] == ord("%") and i + 2 < len(raw):
            try:
                out.append(int(raw[i + 1:i + 3], 16))
                i += 3
                continue
            except ValueError:
                pass
        out.append(raw[i])
        i += 1
    return out.decode(errors="replace")


def file_ok(name):
    """A link file: a plain name of letters, digits and hyphens in the folder, ending in .ply."""
    stem = name[:-4]
    return name.endswith(".ply") and 0 < len(stem) <= 60 and all(c.isascii() and (c.isalnum() or c == "-") for c in stem)


def read_manifest(path, head):
    """A manifest as a dict (token, seq, objects), or None when it is missing or damaged
    anywhere: one send is taken whole or not at all. Each object is a dict of id, level,
    name, file, vertices, triangles and transform (the seven words as written, so an
    untouched one goes back exactly); each light one of name, type (Blender's), position,
    direction, colour, intensity (lux or candela), range and inner and outer half angles,
    in Sculpt's axes."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError:
        return None
    first = lines[0].split()
    if len(first) != 2 or first[0] != head:
        return None
    token, seq, objects, lights = None, None, [], []
    for line in lines[1:]:
        f = line.split()
        if not f:
            continue
        try:
            if f[0] == "scene" and len(f) == 2 and len(f[1]) == 16:
                token = f[1].lower()
                int(token, 16)
            elif f[0] == "sent" and len(f) == 2:
                seq = int(f[1])
            elif f[0] == "object":
                if len(f) != 14 or not file_ok(f[4]):
                    return None
                values = [float(w) for w in f[7:]]
                if not all(math.isfinite(v) for v in values) or values[6] <= 0:
                    return None
                objects.append({"id": int(f[1]), "level": int(f[2]), "name": name_from_word(f[3]), "file": f[4],
                                "vertices": int(f[5]), "triangles": int(f[6]), "transform": f[7:]})
            elif f[0] == "light":
                if len(f) != 16 or f[2] not in LIGHT_TYPES:
                    return None
                values = [float(w) for w in f[3:]]
                if not all(math.isfinite(v) for v in values) or min(values[6:11]) < 0:
                    return None
                lights.append({"name": name_from_word(f[1]), "type": LIGHT_TYPES[f[2]], "position": values[0:3],
                               "direction": values[3:6], "color": values[6:9], "intensity": values[9],
                               "range": values[10], "inner": values[11], "outer": values[12]})
        except ValueError:
            return None
    if token is None or seq is None:
        return None
    return {"token": token, "seq": seq, "objects": objects, "lights": lights}


def write_manifest(path, head, token, seq, objects):
    """Writes a manifest whole: to a temporary file first, then renamed over the old one, so
    the app never reads half of it."""
    lines = [f"{head} {VERSION}", f"scene {token}", f"sent {seq}"]
    for o in objects:
        lines.append(" ".join(["object", str(o["id"]), str(o["level"]), name_word(o["name"]), o["file"],
                               str(o["vertices"]), str(o["triangles"])] + list(o["transform"])))
    temporary = path + ".partial"
    with open(temporary, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)


def read_ply(path):
    """The positions (n x 3 float32) and triangles (m x 3 int32) of a binary little-endian
    PLY as Sculpt writes it: x y z floats, perhaps rgb bytes, then a byte count and three
    ints a face. Also the colours (n x 3 uint8) when it has them, else None."""
    with open(path, "rb") as f:
        data = f.read()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    head = data[:end].decode("ascii").split("\n")
    if "format binary_little_endian 1.0" not in head:
        raise ValueError(f"{os.path.basename(path)} is not a binary little-endian PLY")
    vertices = faces = 0
    colours = False
    for line in head:
        f = line.split()
        if f[:2] == ["element", "vertex"]:
            vertices = int(f[2])
        elif f[:2] == ["element", "face"]:
            faces = int(f[2])
        elif f[:3] == ["property", "uchar", "red"]:
            colours = True
    vertex = np.dtype([("p", "<f4", 3), ("c", "u1", 3)] if colours else [("p", "<f4", 3)])
    face = np.dtype([("n", "u1"), ("i", "<i4", 3)])
    v = np.frombuffer(data, vertex, vertices, end)
    t = np.frombuffer(data, face, faces, end + vertex.itemsize * vertices)
    if faces and not np.all(t["n"] == 3):
        raise ValueError(f"{os.path.basename(path)} has faces that are not triangles")
    return v["p"].copy(), t["i"].copy(), (v["c"].copy() if colours else None)


def write_ply(path, positions, triangles):
    """Writes a binary little-endian PLY of positions (n x 3) and triangles (m x 3), as
    Sculpt reads it, whole: to a temporary file first, then renamed."""
    n, m = len(positions), len(triangles)
    head = (f"ply\nformat binary_little_endian 1.0\ncomment Sculpt link\nelement vertex {n}\nproperty float x\n"
            f"property float y\nproperty float z\nelement face {m}\nproperty list uchar int vertex_indices\nend_header\n")
    face = np.zeros(m, np.dtype([("n", "u1"), ("i", "<i4", 3)]))
    face["n"] = 3
    face["i"] = triangles
    temporary = path + ".partial"
    with open(temporary, "wb") as f:
        f.write(head.encode("ascii"))
        f.write(np.ascontiguousarray(positions, "<f4").tobytes())
        f.write(face.tobytes())
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)


# The link.

def sculpt_matrix(words):
    """Blender's matrix_world for Sculpt's transform words (x y z, degrees about x then y
    then z, uniform scale): Sculpt's placement, then the turn to Z up."""
    x, y, z, rx, ry, rz, s = (float(w) for w in words)
    turn = Euler((math.radians(rx), math.radians(ry), math.radians(rz)), "XYZ").to_matrix().to_4x4()
    return Y_UP_TO_Z_UP @ Matrix.Translation((x, y, z)) @ turn @ Matrix.Scale(s, 4)


def transform_words(obj):
    """Sculpt's transform words for the object's matrix: those it came with when it has not
    moved since, so an untouched placement goes back exactly; otherwise its place, turn and
    scale in Sculpt's axes. Also the matrix to bake into the positions when the object's
    scale is not uniform, sheared or mirrored, which Sculpt's objects cannot be, else None."""
    words = obj.get("sculpt_transform")
    if words and obj.get("sculpt_matrix") and _matrix_same(obj.matrix_world, obj["sculpt_matrix"]):
        return list(words.split()), None
    m = Y_UP_TO_Z_UP.inverted() @ obj.matrix_world
    location, rotation, scale = m.decompose()
    rebuilt = Matrix.LocRotScale(location, rotation, scale)
    uniform = max(scale) - min(scale) <= 1e-5 * max(abs(max(scale)), 1e-12)
    if not uniform or min(scale) <= 0 or m.to_3x3().determinant() <= 0 or not _matrix_same(rebuilt, m, 1e-5):
        return [repr(float(v)) for v in (location.x, location.y, location.z, 0.0, 0.0, 0.0, 1.0)], Matrix.Translation(location).inverted() @ m
    turn = rotation.to_euler("XYZ")
    s = sum(scale) / 3
    return [_float_word(v) for v in (location.x, location.y, location.z, math.degrees(turn.x), math.degrees(turn.y), math.degrees(turn.z), s)], None


def _float_word(v):
    # The shortest digits that read back as the same 32-bit float, as Sculpt writes them.
    v = struct.unpack("<f", struct.pack("<f", v))[0]
    for digits in range(1, 10):
        word = f"{v:.{digits}g}"
        if struct.unpack("<f", struct.pack("<f", float(word)))[0] == v:
            return word
    return repr(v)


def _matrix_same(a, b, tolerance=1e-6):
    flat_a = [a[i][j] for i in range(4) for j in range(4)]
    flat_b = list(b) if not hasattr(b, "row") else [b[i][j] for i in range(4) for j in range(4)]
    return all(abs(x - y) <= tolerance * max(1.0, abs(y)) for x, y in zip(flat_a, flat_b))


def _set_mesh(mesh, positions, triangles):
    """Gives a mesh exactly these vertices and triangles, in this order."""
    mesh.clear_geometry()
    n, m = len(positions), len(triangles)
    mesh.vertices.add(n)
    mesh.vertices.foreach_set("co", np.ascontiguousarray(positions, np.float32).ravel())
    mesh.loops.add(3 * m)
    mesh.loops.foreach_set("vertex_index", np.ascontiguousarray(triangles, np.int32).ravel())
    mesh.polygons.add(m)
    mesh.polygons.foreach_set("loop_start", np.arange(0, 3 * m, 3, dtype=np.int32))
    mesh.update(calc_edges=True)


def _set_colours(mesh, colours):
    if colours is None:
        return
    attribute = mesh.color_attributes.get("Sculpt paint") or mesh.color_attributes.new("Sculpt paint", "BYTE_COLOR", "POINT")
    rgba = np.ones((len(colours), 4), np.float32)
    rgba[:, :3] = colours / 255.0
    attribute.data.foreach_set("color_srgb", rgba.ravel())
    mesh.color_attributes.active_color = attribute


def _same_triangles(mesh, triangles):
    """Whether the mesh is these triangles over as many vertices, corner for corner."""
    if len(mesh.polygons) != len(triangles) or len(mesh.loops) != 3 * len(triangles):
        return False
    corners = np.empty(len(mesh.loops), np.int32)
    mesh.loops.foreach_get("vertex_index", corners)
    starts = np.empty(len(mesh.polygons), np.int32)
    mesh.polygons.foreach_get("loop_start", starts)
    return np.array_equal(starts, np.arange(0, len(mesh.loops), 3)) and np.array_equal(corners, triangles.ravel())


def light_matrix(position, direction):
    """Blender's matrix_world for a light at Sculpt's `position` shining Sculpt's
    `direction`: its -Z, which a Blender light shines along, turned onto it, Z up."""
    shines = Y_UP_TO_Z_UP.to_3x3() @ Vector(direction)
    shines = shines.normalized() if shines.length > 1e-12 else Vector((0, 0, -1))
    turn = Vector((0, 0, -1)).rotation_difference(shines).to_matrix().to_4x4()
    return Matrix.Translation(Y_UP_TO_Z_UP @ Vector(position)) @ turn


def set_lights(lights, token):
    """Makes the "Sculpt lights" collection hold Sculpt's lights: each updates the light
    made from it before (by name), else a new one is made, and one an earlier send made
    that this one does not list goes. A sun's strength is its lux over 683 lumens a watt
    and a lamp's power its candela times 4 pi over 683, as Blender's glTF importer gives
    them, with no radius, as glTF's lights have none. Returns the light objects."""
    collection = bpy.data.collections.get(LIGHT_COLLECTION)
    if collection is None:
        if not lights:
            return []
        collection = bpy.data.collections.new(LIGHT_COLLECTION)
        bpy.context.scene.collection.children.link(collection)
    old = {o["sculpt_light"]: o for o in collection.objects if o.type == "LIGHT" and "sculpt_light" in o}
    made = []
    for k, l in enumerate(lights):
        key = l["name"] or f"Light {k + 1}"
        while any(o.get("sculpt_light") == key for o in made):
            key += " +"
        obj = old.pop(key, None)
        if obj is None:
            obj = bpy.data.objects.new(key, bpy.data.lights.new(key, l["type"]))
            collection.objects.link(obj)
        elif obj.data.type != l["type"]:
            obj.data.type = l["type"]
        light = obj.data
        light.color = l["color"]
        if l["type"] == "SUN":
            light.energy = l["intensity"] / LUMENS_PER_WATT
        else:
            light.energy = l["intensity"] * 4 * math.pi / LUMENS_PER_WATT
            light.shadow_soft_size = 0
        if l["type"] == "SPOT":
            outer = max(l["outer"], 1e-4)
            light.spot_size = 2 * outer
            light.spot_blend = min(max(1 - l["inner"] / outer, 0), 1)
        obj.matrix_world = light_matrix(l["position"], l["direction"])
        obj["sculpt_light"], obj["sculpt_scene"] = key, token
        made.append(obj)
    for gone in old.values():
        data = gone.data
        bpy.data.objects.remove(gone)
        if data.users == 0:
            bpy.data.lights.remove(data)
    return made


def get_from_sculpt(folder, collection=None, lights=True):
    """Brings in what Sculpt sent: each object updates the Blender object made from it
    before (same scene token and id), its vertices only when the counts match, so its UVs,
    modifiers and materials stay, or else a new mesh; otherwise a new object is made in
    `collection` (the scene's by default). With `lights` the lights come too (set_lights).
    Returns the objects, or a message on failure."""
    sent = read_manifest(os.path.join(folder, SENT_FILE), "sculpt_link")
    if sent is None:
        return f"No send from Sculpt in {folder}: Send to Blender in Sculpt first"
    collection = collection or bpy.context.scene.collection
    meshes = []
    for o in sent["objects"]:
        try:
            positions, triangles, colours = read_ply(os.path.join(folder, o["file"]))
        except (OSError, ValueError) as error:
            return f"Cannot read {o['file']}: {error}"
        if len(positions) != o["vertices"] or len(triangles) != o["triangles"]:
            return f"{o['file']} is still being written: try again"
        meshes.append((positions, triangles, colours))
    made = []
    for o, (positions, triangles, colours) in zip(sent["objects"], meshes):
        obj = next((b for b in bpy.data.objects if b.type == "MESH" and b.get("sculpt_id") == o["id"] and b.get("sculpt_scene") == sent["token"]), None)
        if obj is None:
            mesh = bpy.data.meshes.new(o["name"] or "Sculpt")
            _set_mesh(mesh, positions, triangles)
            obj = bpy.data.objects.new(o["name"] or "Sculpt", mesh)
            collection.objects.link(obj)
        elif _same_triangles(obj.data, triangles):
            obj.data.vertices.foreach_set("co", positions.ravel())
            obj.data.update()
        else:
            _set_mesh(obj.data, positions, triangles)
        _set_colours(obj.data, colours)
        obj["sculpt_id"], obj["sculpt_scene"], obj["sculpt_level"] = o["id"], sent["token"], o["level"]
        obj["sculpt_transform"] = " ".join(o["transform"])
        obj.matrix_world = sculpt_matrix(o["transform"])
        obj["sculpt_matrix"] = [obj.matrix_world[i][j] for i in range(4) for j in range(4)]
        made.append(obj)
    if lights:
        set_lights(sent["lights"], sent["token"])
    bpy.context.scene["sculpt_link_got"] = sent["seq"]
    return made


def send_to_sculpt(folder, objects, apply_modifiers=False, depsgraph=None):
    """Writes the mesh objects for Sculpt's Get from Blender. A mesh of triangles goes in
    its own vertex and triangle order (one from Sculpt keeps it, so Sculpt moves its
    vertices); any other is split into triangles. With `apply_modifiers` the evaluated mesh
    goes, which Sculpt rebuilds its object from. Returns how many went, or a message."""
    objects = [o for o in objects if o.type == "MESH"]
    if not objects:
        return "Select a mesh object to send"
    os.makedirs(folder, exist_ok=True)
    sent = read_manifest(os.path.join(folder, SENT_FILE), "sculpt_link")
    token = sent["token"] if sent else "0" * 16
    back = read_manifest(os.path.join(folder, BACK_FILE), "blender_link")
    seq = (back["seq"] if back else 0) + 1
    lines, new, taken = [], 0, set()
    for obj in objects:
        mesh = obj.evaluated_get(depsgraph).to_mesh() if apply_modifiers and depsgraph else obj.data
        try:
            positions = np.empty(3 * len(mesh.vertices), np.float32)
            mesh.vertices.foreach_get("co", positions)
            positions = positions.reshape(-1, 3)
            sizes = np.empty(len(mesh.polygons), np.int32)
            mesh.polygons.foreach_get("loop_total", sizes)
            if len(sizes) and np.all(sizes == 3):
                triangles = np.empty(len(mesh.loops), np.int32)
                mesh.loops.foreach_get("vertex_index", triangles)
            else:
                mesh.calc_loop_triangles()
                triangles = np.empty(3 * len(mesh.loop_triangles), np.int32)
                mesh.loop_triangles.foreach_get("vertices", triangles)
            triangles = triangles.reshape(-1, 3)
        finally:
            if mesh is not obj.data:
                obj.evaluated_get(depsgraph).to_mesh_clear()
        words, bake = transform_words(obj)
        if bake is not None:
            # Sculpt's objects scale the same way along every axis: the rest goes into the
            # positions.
            rest = np.array(bake.to_3x3(), np.float32)
            positions = positions @ rest.T
        if bake is not None and bake.determinant() < 0:
            # Mirrored: the positions are mirrored now, so the triangles turn the other way
            # round to keep facing out.
            triangles = triangles[:, ::-1].copy()
        # A copy (Shift+D) keeps the custom properties, so only the first object of an id
        # goes back as it; the rest are new to Sculpt.
        own = obj.get("sculpt_scene") == token and isinstance(obj.get("sculpt_id"), int) and obj["sculpt_id"] > 0 and obj["sculpt_id"] not in taken
        if own:
            taken.add(obj["sculpt_id"])
            ident, file = obj["sculpt_id"], f"blender-{obj['sculpt_id']}.ply"
        else:
            new += 1
            ident, file = 0, f"blender-new-{new}.ply"
        write_ply(os.path.join(folder, file), positions, triangles)
        lines.append({"id": ident, "level": int(obj.get("sculpt_level", 0)) if own else 0, "name": obj.name, "file": file,
                      "vertices": len(positions), "triangles": len(triangles), "transform": words})
    # The manifest goes last, so Sculpt never reads one whose files are not all there.
    write_manifest(os.path.join(folder, BACK_FILE), "blender_link", token, seq, lines)
    return len(lines)


# The interface.

def _folder(context):
    preferences = context.preferences.addons[__package__].preferences
    return bpy.path.abspath(preferences.folder) if preferences.folder else default_folder()


class SCULPTLINK_Preferences(bpy.types.AddonPreferences):
    bl_idname = __package__
    folder: bpy.props.StringProperty(name="Link folder", subtype="DIR_PATH",
                                     description="The folder Sculpt's Settings > System > Blender link names (Copy path there); empty for the default")

    def draw(self, context):
        self.layout.prop(self, "folder")
        self.layout.label(text=f"Default: {default_folder()}")


class SCULPTLINK_OT_get(bpy.types.Operator):
    bl_idname = "sculpt_link.get"
    bl_label = "Get from Sculpt"
    bl_description = "Brings in the objects Sculpt's Send to Blender left in the link folder"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        result = get_from_sculpt(_folder(context), lights=context.window_manager.sculpt_link.bring_lights)
        if isinstance(result, str):
            self.report({"WARNING"}, result)
            return {"CANCELLED"}
        self.report({"INFO"}, f"Got {len(result)} object{'s' if len(result) != 1 else ''} from Sculpt")
        return {"FINISHED"}


class SCULPTLINK_OT_send(bpy.types.Operator):
    bl_idname = "sculpt_link.send"
    bl_label = "Send to Sculpt"
    bl_description = "Writes the selected mesh objects for Sculpt, which takes them when you switch to it or with Get from Blender"

    def execute(self, context):
        settings = context.window_manager.sculpt_link
        result = send_to_sculpt(_folder(context), context.selected_objects, settings.apply_modifiers, context.evaluated_depsgraph_get())
        if isinstance(result, str):
            self.report({"WARNING"}, result)
            return {"CANCELLED"}
        self.report({"INFO"}, f"Sent {result} object{'s' if result != 1 else ''} to Sculpt")
        return {"FINISHED"}


def _auto_get():
    # Looks for a new send from Sculpt once a second while Auto get is on.
    context = bpy.context
    settings = context.window_manager.sculpt_link
    if not settings.auto_get:
        return None
    sent = read_manifest(os.path.join(_folder(context), SENT_FILE), "sculpt_link")
    if sent and sent["seq"] > context.scene.get("sculpt_link_got", 0):
        get_from_sculpt(_folder(context), lights=settings.bring_lights)
    return 1.0


def _auto_changed(self, context):
    if self.auto_get and not bpy.app.timers.is_registered(_auto_get):
        bpy.app.timers.register(_auto_get, first_interval=1.0)


class SCULPTLINK_Settings(bpy.types.PropertyGroup):
    apply_modifiers: bpy.props.BoolProperty(name="Apply modifiers", default=False,
                                            description="Sends the meshes as the modifiers leave them; Sculpt then rebuilds its objects from them rather than moving their vertices")
    bring_lights: bpy.props.BoolProperty(name="Bring lights", default=True,
                                         description="Get from Sculpt also makes Sculpt's lights that are on, in a Sculpt lights collection")
    auto_get: bpy.props.BoolProperty(name="Auto get", default=False, update=_auto_changed,
                                     description="Gets each new send from Sculpt by itself, looking once a second")


class SCULPTLINK_PT_panel(bpy.types.Panel):
    bl_label = "Sculpt link"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Sculpt"

    def draw(self, context):
        layout = self.layout
        settings = context.window_manager.sculpt_link
        layout.operator(SCULPTLINK_OT_get.bl_idname, icon="IMPORT")
        layout.prop(settings, "auto_get")
        layout.prop(settings, "bring_lights")
        layout.separator()
        layout.operator(SCULPTLINK_OT_send.bl_idname, icon="EXPORT")
        layout.prop(settings, "apply_modifiers")
        layout.separator()
        layout.label(text=_folder(context))


CLASSES = (SCULPTLINK_Preferences, SCULPTLINK_Settings, SCULPTLINK_OT_get, SCULPTLINK_OT_send, SCULPTLINK_PT_panel)


def register():
    for c in CLASSES:
        bpy.utils.register_class(c)
    bpy.types.WindowManager.sculpt_link = bpy.props.PointerProperty(type=SCULPTLINK_Settings)


def unregister():
    if bpy.app.timers.is_registered(_auto_get):
        bpy.app.timers.unregister(_auto_get)
    del bpy.types.WindowManager.sculpt_link
    for c in reversed(CLASSES):
        bpy.utils.unregister_class(c)
