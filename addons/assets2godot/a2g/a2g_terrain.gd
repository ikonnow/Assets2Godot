@tool
extends RefCounted
## Heightmap terrain assembly for remote providers — ambientCG is the
## first (its "Terrains" type ships a normalized float EXR heightmap,
## pre-displaced OBJs nobody wants to import at 118MB-2GB, and a maps
## zip with no .tres). Pure statics, no network — the tab feeds files,
## scene_drop feeds the download dir.
##
## The mesh is built in real meters (extent × relief), node scale stays
## 1 — the inspector shows true dimensions and nonuniform rescale still
## lights correctly through the normal matrix. Normals are sobel-
## computed from the decimated grid the mesh uses, not the full-res
## heightmap, so lighting matches the actual geometry.

const DEFAULT_EXTENT_M := 5000.0
const DEFAULT_RELIEF_M := 500.0
## Mesh grid per side — 257 ≈ 66k verts / 131k tris: honest relief for
## editor placement without a per-drop VRAM spike; the setting scales
## up to 1025 for production bakes.
const GRID_RES := 257
## HeightMapShape3D cells are 1m×1m — the collision body scales them to
## the terrain's cell size; this is its grid per side (kept lower than
## the visual mesh — physics doesn't need render detail).
const COLLISION_RES := 257
const SETTING_EXTENT := "assets2godot/terrain_extent_m"
const SETTING_RELIEF := "assets2godot/terrain_relief_m"
const SETTING_RES := "assets2godot/terrain_grid_res"
## Obj bounds probe — the first rows of a regular grid are enough to
## measure spacing; a 256KB head read covers ~10 rows of a 1K grid.
const OBJ_PROBE_BYTES := 262144


## First *.exr in [param dir] (ambientCG heightmaps land as the only EXR
## next to the maps) — "" when the download carries no heightmap.
static func find_heightmap(dir: String) -> String:
	if not DirAccess.dir_exists_absolute(dir):
		return ""
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "exr":
			return dir.path_join(f)
	return ""


## EXR → {w, h, data (PackedFloat32Array), min, max}. Height lives in R;
## ambientCG normalizes to 0..1 regardless of the asset's OBJ scale.
## {} on failure — caller falls back to the flat plane.
static func load_heights(path: String) -> Dictionary:
	var img := Image.new()
	if img.load(path) != OK or img.is_empty():
		return {}
	img.convert(Image.FORMAT_RF)
	var data := img.get_data().to_float32_array()
	var mn := INF
	var mx := -INF
	for v in data:
		mn = minf(mn, v)
		mx = maxf(mx, v)
	return {"w": img.get_width(), "h": img.get_height(),
		"data": data, "min": mn, "max": mx}


## Decimate [param heights] to res×res (edge-preserving stride) — the
## mesh/collision grid never needs the heightmap's full resolution.
static func decimate(heights: Dictionary, res: int) -> Dictionary:
	var w: int = heights["w"]
	var h: int = heights["h"]
	var src: PackedFloat32Array = heights["data"]
	var out := PackedFloat32Array()
	out.resize(res * res)
	var fx := float(w - 1) / float(res - 1)
	var fz := float(h - 1) / float(res - 1)
	for j in res:
		var sy := mini(int(roundf(j * fz)), h - 1)
		for i in res:
			var sx := mini(int(roundf(i * fx)), w - 1)
			out[j * res + i] = src[sy * w + sx]
	return {"w": res, "h": res, "data": out}


## The terrain's real XZ extent in meters. Order: a sibling OBJ's grid
## spacing (metric exports carry real meters) → the editor setting →
## DEFAULT_EXTENT_M. Normalized OBJs (unit-square verts) read as
## useless spacing and fall through to the setting.
static func extent_for(dir: String) -> float:
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			if f.get_extension().to_lower() == "obj":
				var e := obj_extent_m(dir.path_join(f))
				if e > 0.0:
					return e
				break
	return float(_setting(SETTING_EXTENT, DEFAULT_EXTENT_M))


## First-row vertex spacing × row vertex count. ambientCG exports a
## regular row-major grid — the first z-change ends the row, so the row
## itself measures the grid resolution: extent = spacing × (row-1) in
## the OBJ's own units (meters on metric exports). 0.0 when unparseable
## or normalized (<2m total extent is a unit export, not real scale).
static func obj_extent_m(path: String) -> float:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0.0
	var text := f.get_buffer(OBJ_PROBE_BYTES).get_string_from_ascii()
	f.close()
	var spacing := -1.0
	var last_x := NAN
	var first_z := NAN
	var row_verts := 0
	for line in text.split("\n"):
		if not line.begins_with("v "):
			continue
		var p := line.split(" ", false)
		if p.size() < 4:
			continue
		var x := float(p[1])
		var z := float(p[3])
		if is_nan(first_z):
			first_z = z
		elif not is_equal_approx(z, first_z):
			break # row ended — spacing and count are known
		if not is_nan(last_x):
			spacing = x - last_x
		last_x = x
		row_verts += 1
	if spacing <= 0.0 or row_verts < 2:
		return 0.0
	var extent := spacing * float(row_verts - 1)
	return extent if extent >= 2.0 else 0.0


## relief = EXR max_normalized × relief_m — the height a 1.0 sample
## reaches. From the editor setting, defaulting to DEFAULT_RELIEF_M.
static func relief_for(_dir: String) -> float:
	return float(_setting(SETTING_RELIEF, DEFAULT_RELIEF_M))


## Grid res the mesh builds at — setting, default GRID_RES.
static func grid_res_for() -> int:
	return int(_setting(SETTING_RES, GRID_RES))


## Heights → centered displaced ArrayMesh in real meters: XZ spans
## [-extent/2, extent/2], Y = sample×relief. Sobel normals off the same
## decimated grid so shading matches the geometry exactly.
static func build_mesh(heights: Dictionary, extent: float, relief: float) -> ArrayMesh:
	# Upsampling past the heightmap's own resolution buys nothing.
	var res := clampi(grid_res_for(), 3, mini(int(heights["w"]), int(heights["h"])))
	var g := decimate(heights, res)
	var d: PackedFloat32Array = g["data"]
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	verts.resize(res * res)
	uvs.resize(res * res)
	normals.resize(res * res)
	var step := extent / float(res - 1)
	var half := extent * 0.5
	for j in res:
		for i in res:
			var idx := j * res + i
			verts[idx] = Vector3(i * step - half, d[idx] * relief, j * step - half)
			uvs[idx] = Vector2(float(i) / (res - 1), float(j) / (res - 1))
	# Sobel normals: central differences on the height grid, converted to
	# a normal with the real cell spacing — edge cells clamp the stencil.
	for j in res:
		for i in res:
			var l := d[j * res + maxi(i - 1, 0)] * relief
			var r := d[j * res + mini(i + 1, res - 1)] * relief
			var u := d[maxi(j - 1, 0) * res + i] * relief
			var dn := d[mini(j + 1, res - 1) * res + i] * relief
			normals[j * res + i] = Vector3(l - r, 2.0 * step, u - dn).normalized()
	var indices := PackedInt32Array()
	indices.resize((res - 1) * (res - 1) * 6)
	var k := 0
	for j in res - 1:
		for i in res - 1:
			var a := j * res + i
			var b := a + 1
			var c := a + res
			var e := c + 1
			# Y-up, counter-clockwise seen from above (Godot front faces).
			indices[k] = a; indices[k + 1] = b; indices[k + 2] = c
			indices[k + 3] = b; indices[k + 4] = e; indices[k + 5] = c
			k += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## The collision body: HeightMapShape3D takes heights in meters at 1m
## cells — the cell size arrives as a UNIFORM scale on the
## CollisionShape3D node (non-uniform scales earn Godot's config
## warning; a uniform one stretches XZ cells and Y heights alike, so
## map_data pre-divides the heights). Returns
## StaticBody3D → CollisionShape3D.
static func build_collision(heights: Dictionary, extent: float, relief: float) -> StaticBody3D:
	var g := decimate(heights, COLLISION_RES)
	var res := int(g["w"])
	var d: PackedFloat32Array = g["data"]
	var s := extent / float(res - 1)
	var map := PackedFloat32Array()
	map.resize(d.size())
	for i in d.size():
		map[i] = d[i] * relief / s
	var shape := HeightMapShape3D.new()
	shape.map_width = res
	shape.map_depth = res
	shape.map_data = map
	var col := CollisionShape3D.new()
	col.shape = shape
	col.scale = Vector3(s, s, s)
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.add_child(col)
	return body


## One settings read — EditorSettings-backed with the const fallback.
static func _setting(key: String, fallback: Variant) -> Variant:
	var es := EditorInterface.get_editor_settings()
	if es and es.has_setting(key):
		return es.get_setting(key)
	return fallback
