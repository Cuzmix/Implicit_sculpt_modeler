// The app's way into ufbx (deps/ufbx-src, UFBX_TAG in scripts/versions.env): the few
// calls src/fbx/fbx.odin binds, so Odin never mirrors ufbx's large structs. ufbx.c is
// included whole, making the shim and the library one translation unit that each
// platform compiles once (scripts/build_ufbx.py, Android's CMakeLists, build.sh ios).
//
// A scene is read Y up and in metres, as glTF and the app's space are. Each node that
// holds a mesh is a part, placed by the node's geometry-to-world matrix (geometric
// transforms and the axis change included), so a mesh two nodes place comes twice.
// Faces are split into triangles by ufbx_triangulate_face; a node that mirrors its
// mesh turns the triangles round so they still face outward. A vertex's colour is the
// mean of its corners' colours, taken as stored: FBX colours are sRGB, as Blender and
// Maya write and read them. A face's material is its group: 0 for none, k + 1 for the
// mesh's material k. For the paint the scene's materials give their base colour (linear,
// as ufbx's PBR view of any FBX material has it) and the texture file of their base
// colour map, whose bytes come from the file when embedded or are named by path; each
// triangle names its scene material, and each corner its texture coordinate. Each
// triangle names the face it was cut from, so quads and polygons come back whole, and a
// part names the node above its own for its folder. Skins, animation stacks and blend
// shape channels are counted, never applied: a skinned mesh comes in its bind pose.

#include "ufbx.c"

#include <string.h>

typedef struct sculpt_fbx {
	ufbx_scene *scene;
	size_t parts;
	ufbx_node **nodes; // the parts' nodes, in the scene's node order
} sculpt_fbx;

// Reads an FBX file (binary or text, any version ufbx reads) from memory. NULL on a
// failure, with ufbx's reason in `error` (cut to `error_size`, terminated).
sculpt_fbx *sculpt_fbx_load(const void *data, size_t size, char *error, size_t error_size) {
	ufbx_load_opts opts = {0};
	opts.target_axes = ufbx_axes_right_handed_y_up;
	opts.target_unit_meters = 1.0f;
	// Only FBX: ufbx reads OBJ too, which the app's own reader handles.
	opts.file_format = UFBX_FILE_FORMAT_FBX;
	opts.load_external_files = false;
	// Animation is read only to be counted (sculpt_fbx_rig); nothing evaluates it.
	opts.ignore_animation = false;
	opts.ignore_embedded = false;
	ufbx_error err;
	ufbx_scene *scene = ufbx_load_memory(data, size, &opts, &err);
	if (!scene) {
		if (error && error_size > 0) ufbx_format_error(error, error_size, &err);
		return NULL;
	}
	sculpt_fbx *f = (sculpt_fbx *)calloc(1, sizeof(sculpt_fbx));
	ufbx_node **nodes = (ufbx_node **)calloc(scene->nodes.count + 1, sizeof(ufbx_node *));
	if (!f || !nodes) {
		free(f);
		free(nodes);
		ufbx_free_scene(scene);
		if (error && error_size > 0) snprintf(error, error_size, "out of memory");
		return NULL;
	}
	f->scene = scene;
	f->nodes = nodes;
	for (size_t i = 0; i < scene->nodes.count; i++) {
		ufbx_node *node = scene->nodes.data[i];
		if (node->mesh && node->mesh->num_triangles > 0) f->nodes[f->parts++] = node;
	}
	return f;
}

size_t sculpt_fbx_part_count(const sculpt_fbx *f) {
	return f ? f->parts : 0;
}

// What the scene holds for animation, which Import leaves for later: its skin deformers,
// its animation stacks (takes) and its blend shape channels (shape keys).
void sculpt_fbx_rig(const sculpt_fbx *f, size_t *skins, size_t *animations, size_t *shapes) {
	*skins = f ? f->scene->skin_deformers.count : 0;
	*animations = f ? f->scene->anim_stacks.count : 0;
	*shapes = f ? f->scene->blend_channels.count : 0;
}

size_t sculpt_fbx_material_count(const sculpt_fbx *f) {
	return f ? f->scene->materials.count : 0;
}

// Material `k`'s base colour (linear red, green and blue, times its factor) and the
// texture file of its base colour map, or -1 for none.
void sculpt_fbx_material(const sculpt_fbx *f, size_t k, float *color, int32_t *texture_file) {
	const ufbx_material *m = f->scene->materials.data[k];
	const ufbx_material_map *base = &m->pbr.base_color;
	double factor = m->pbr.base_factor.has_value ? m->pbr.base_factor.value_real : 1.0;
	for (int c = 0; c < 3; c++) {
		double x = (base->has_value ? base->value_vec4.v[c] : 1.0) * factor;
		color[c] = (float)(x < 0 ? 0 : x > 1 ? 1 : x);
	}
	*texture_file = -1;
	const ufbx_texture *t = base->texture;
	if (t && base->texture_enabled && t->has_file) *texture_file = (int32_t)t->file_index;
}

static double map_real(const ufbx_material_map *m, double missing) {
	return m->has_value ? m->value_real : missing;
}

static void map_vec3(const ufbx_material_map *m, float *out, double missing) {
	for (int c = 0; c < 3; c++) out[c] = (float)(m->has_value ? m->value_vec3.v[c] : missing);
}

// A map's texture file name as the file gives it (relative, else absolute), or none.
static void map_file(const ufbx_material_map *m, const char **name, size_t *len) {
	*name = NULL;
	*len = 0;
	const ufbx_texture *t = m->texture;
	if (!t || !m->texture_enabled) return;
	if (t->relative_filename.length > 0) {
		*name = t->relative_filename.data;
		*len = t->relative_filename.length;
	} else {
		*name = t->filename.data;
		*len = t->filename.length;
	}
}

// Material `k` in ufbx's PBR view of any FBX shader (Blender's Principled export, Maya's
// and 3ds Max's physical materials, Phong): `out` takes metallic, roughness, then the 32
// values of geom.Material_Layers in its order (the app clamps them); `valued` whether
// ufbx found PBR values at all; its name and its maps' files (base colour, metalness or
// roughness, normal), all valid until sculpt_fbx_free.
void sculpt_fbx_material_values(const sculpt_fbx *f, size_t k, float *out, int32_t *valued, const char **name, size_t *name_len, const char **maps, size_t *map_lens) {
	const ufbx_material *m = f->scene->materials.data[k];
	const ufbx_material_pbr_maps *p = &m->pbr;
	*name = m->name.data;
	*name_len = m->name.length;
	*valued = m->features.pbr.enabled || p->roughness.has_value || p->metalness.has_value;
	double rough = map_real(&p->roughness, 0.5);
	if (m->features.roughness_as_glossiness.enabled) rough = 1.0 - rough;
	out[0] = (float)map_real(&p->metalness, 0.0);
	out[1] = (float)rough;
	float *l = out + 2;
	map_vec3(&p->subsurface_color, l + 0, 1.0);
	l[3] = (float)map_real(&p->subsurface_factor, 0.0);
	map_vec3(&p->subsurface_radius, l + 4, 0.0);
	l[7] = (float)map_real(&p->subsurface_scale, 0.0);
	double coat = map_real(&p->coat_factor, 0.0);
	double coat_rough = map_real(&p->coat_roughness, 0.0);
	if (m->features.coat_roughness_as_glossiness.enabled) coat_rough = 1.0 - coat_rough;
	l[8] = (float)coat;
	l[9] = (float)coat_rough;
	l[10] = (float)map_real(&p->coat_ior, 0.0);
	l[11] = (float)map_real(&p->specular_ior, 0.0);
	map_vec3(&p->sheen_color, l + 12, 0.0);
	l[15] = (float)map_real(&p->sheen_factor, 0.0);
	map_vec3(&p->emission_color, l + 16, 0.0);
	l[19] = (float)map_real(&p->emission_factor, 0.0);
	map_vec3(&p->transmission_color, l + 20, 1.0);
	l[23] = (float)map_real(&p->transmission_factor, 0.0);
	l[24] = (float)map_real(&p->transmission_depth, 0.0);
	l[25] = m->features.thin_walled.enabled ? 1.0f : 0.0f;
	l[26] = (float)map_real(&p->sheen_roughness, 0.0);
	l[27] = (float)map_real(&p->subsurface_anisotropy, 0.0);
	l[28] = (float)map_real(&p->thin_film_factor, 0.0);
	l[29] = (float)map_real(&p->thin_film_thickness, 0.0);
	l[30] = (float)map_real(&p->thin_film_ior, 0.0);
	// A specular weight only from a physically based shader: Blender's and FBX's Phong
	// carry a Phong specular strength there (Blender writes 0.25 for its default), which
	// would dim every reflection to a quarter.
	bool phong = m->shader_type == UFBX_SHADER_FBX_LAMBERT || m->shader_type == UFBX_SHADER_FBX_PHONG || m->shader_type == UFBX_SHADER_BLENDER_PHONG || m->shader_type == UFBX_SHADER_UNKNOWN;
	l[31] = phong ? 0.0f : (float)(1.0 - map_real(&p->specular_factor, 1.0));
	map_file(&p->base_color, &maps[0], &map_lens[0]);
	map_file(p->metalness.texture ? &p->metalness : &p->roughness, &maps[1], &map_lens[1]);
	map_file(&p->normal_map, &maps[2], &map_lens[2]);
}

size_t sculpt_fbx_texture_file_count(const sculpt_fbx *f) {
	return f ? f->scene->texture_files.count : 0;
}

// Texture file `k`: its embedded bytes (NULL and 0 when not embedded) and the paths the
// file gives for it (UTF-8, not terminated), all valid until sculpt_fbx_free.
void sculpt_fbx_texture_file(const sculpt_fbx *f, size_t k, const void **content, size_t *content_size, const char **relative, size_t *relative_len, const char **absolute, size_t *absolute_len) {
	const ufbx_texture_file *t = &f->scene->texture_files.data[k];
	*content = t->content.size > 0 ? t->content.data : NULL;
	*content_size = t->content.size;
	*relative = t->relative_filename.data;
	*relative_len = t->relative_filename.length;
	*absolute = t->absolute_filename.data;
	*absolute_len = t->absolute_filename.length;
}

// Part `part`'s name (UTF-8, not terminated, valid until sculpt_fbx_free) and sizes: its
// vertices, its triangles, and whether it has colours, more than one group, texture
// coordinates and faces of more than three corners.
void sculpt_fbx_part_size(const sculpt_fbx *f, size_t part, const char **name, size_t *name_len, size_t *vertices, size_t *triangles, bool *colors, bool *groups, bool *uvs, bool *polygons) {
	ufbx_node *node = f->nodes[part];
	ufbx_mesh *mesh = node->mesh;
	*name = node->name.data;
	*name_len = node->name.length;
	*polygons = mesh->num_triangles > mesh->faces.count;
	*vertices = mesh->num_vertices;
	*triangles = mesh->num_triangles;
	*colors = mesh->vertex_color.exists;
	bool more = false;
	for (size_t i = 1; i < mesh->face_material.count && !more; i++) more = mesh->face_material.data[i] != mesh->face_material.data[0];
	*groups = more;
	*uvs = mesh->vertex_uv.exists;
}

// The scene material of a face's material slot: the node's own list wins, as an instance
// may change its mesh's materials.
static int32_t sculpt_fbx_face_material(const ufbx_node *node, const ufbx_mesh *mesh, size_t face) {
	if (mesh->face_material.count <= face) return -1;
	uint32_t slot = mesh->face_material.data[face];
	const ufbx_material_list *list = node->materials.count == mesh->materials.count ? &node->materials : &mesh->materials;
	if (slot >= list->count || !list->data[slot]) return -1;
	return (int32_t)list->data[slot]->typed_id;
}

static uint8_t sculpt_fbx_byte(double x) {
	if (!(x > 0)) return 0;
	if (x >= 1) return 255;
	return (uint8_t)(x * 255 + 0.5);
}

// Fills part `part`'s positions (3 floats a vertex), triangles (3 indices each), and,
// when not NULL, its colours (RGBA bytes a vertex, alpha 255 where corners gave one),
// How many nodes part `part`'s node is under, the scene's root left out.
size_t sculpt_fbx_part_folders(const sculpt_fbx *f, size_t part) {
	size_t n = 0;
	for (const ufbx_node *p = f->nodes[part]->parent; p && !p->is_root; p = p->parent) n++;
	return n;
}

// The name of the `k`th node above part `part`'s node, counted from the top (UTF-8, not
// terminated, valid until sculpt_fbx_free), as sculpt_fbx_part_folders counts them.
void sculpt_fbx_part_folder(const sculpt_fbx *f, size_t part, size_t k, const char **name, size_t *name_len) {
	size_t n = sculpt_fbx_part_folders(f, part);
	const ufbx_node *p = f->nodes[part]->parent;
	for (size_t up = n - 1 - k; up > 0 && p; up--) p = p->parent;
	*name = p ? p->name.data : "";
	*name_len = p ? p->name.length : 0;
}

// groups (one a triangle), scene materials (one a triangle, -1 for none), texture
// coordinates (2 floats a corner, v down from the image's top) and the face each triangle
// was cut from (one a triangle), sized as sculpt_fbx_part_size said. False when out of
// memory.
bool sculpt_fbx_part_fill(const sculpt_fbx *f, size_t part, float *positions, uint32_t *indices, uint8_t *colors, uint16_t *groups, int32_t *materials, float *uvs, uint32_t *polys) {
	ufbx_node *node = f->nodes[part];
	ufbx_mesh *mesh = node->mesh;
	const ufbx_matrix *to_world = &node->geometry_to_world;
	bool mirrored = ufbx_matrix_determinant(to_world) < 0;
	for (size_t v = 0; v < mesh->num_vertices; v++) {
		ufbx_vec3 p = ufbx_transform_position(to_world, mesh->vertices.data[v]);
		positions[3 * v + 0] = (float)p.x;
		positions[3 * v + 1] = (float)p.y;
		positions[3 * v + 2] = (float)p.z;
	}
	size_t room = 3 * (mesh->max_face_triangles + 1);
	uint32_t *corners = (uint32_t *)malloc(sizeof(uint32_t) * room);
	if (!corners) return false;
	size_t t = 0;
	for (size_t face = 0; face < mesh->faces.count; face++) {
		uint32_t n = ufbx_triangulate_face(corners, room, mesh, mesh->faces.data[face]);
		uint32_t group = 0;
		if (mesh->face_material.count > face) group = mesh->face_material.data[face] + 1;
		int32_t material = materials ? sculpt_fbx_face_material(node, mesh, face) : -1;
		for (uint32_t k = 0; k < n && t < mesh->num_triangles; k++, t++) {
			uint32_t order[3] = {corners[3 * k], mirrored ? corners[3 * k + 2] : corners[3 * k + 1], mirrored ? corners[3 * k + 1] : corners[3 * k + 2]};
			for (int j = 0; j < 3; j++) {
				indices[3 * t + j] = mesh->vertex_indices.data[order[j]];
				if (uvs && mesh->vertex_uv.exists) {
					ufbx_vec2 uv = ufbx_get_vertex_vec2(&mesh->vertex_uv, order[j]);
					uvs[6 * t + 2 * j] = (float)uv.x;
					uvs[6 * t + 2 * j + 1] = (float)(1.0 - uv.y);
				}
			}
			if (groups) groups[t] = group > 65535 ? 65535 : (uint16_t)group;
			if (materials) materials[t] = material;
			if (polys) polys[t] = (uint32_t)face;
		}
	}
	free(corners);
	// Triangles a face could not make (one of fewer than three corners) are left as
	// repeated corners, which the app's cleanup drops.
	for (; t < mesh->num_triangles; t++) {
		indices[3 * t] = indices[3 * t + 1] = indices[3 * t + 2] = 0;
		if (groups) groups[t] = 0;
		if (materials) materials[t] = -1;
		if (uvs) memset(&uvs[6 * t], 0, 6 * sizeof(float));
		if (polys) polys[t] = (uint32_t)mesh->faces.count + (uint32_t)t;
	}
	if (colors && mesh->vertex_color.exists) {
		double *sum = (double *)calloc(mesh->num_vertices, 4 * sizeof(double));
		if (!sum) return false;
		for (size_t i = 0; i < mesh->num_indices; i++) {
			ufbx_vec4 c = ufbx_get_vertex_vec4(&mesh->vertex_color, i);
			uint32_t v = mesh->vertex_indices.data[i];
			sum[4 * v + 0] += c.x;
			sum[4 * v + 1] += c.y;
			sum[4 * v + 2] += c.z;
			sum[4 * v + 3] += 1;
		}
		for (size_t v = 0; v < mesh->num_vertices; v++) {
			double n = sum[4 * v + 3];
			for (int k = 0; k < 3; k++) colors[4 * v + k] = n > 0 ? sculpt_fbx_byte(sum[4 * v + k] / n) : 0;
			colors[4 * v + 3] = n > 0 ? 255 : 0;
		}
		free(sum);
	}
	return true;
}

void sculpt_fbx_free(sculpt_fbx *f) {
	if (!f) return;
	ufbx_free_scene(f->scene);
	free(f->nodes);
	free(f);
}
