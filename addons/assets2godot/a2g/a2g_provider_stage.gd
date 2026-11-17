@tool
extends Node3D
## Populates this stage with whatever sits under
## <root>/<provider>/ — the provider download roots inside the shared
## res://Assets2Godot/ parent (polyhaven/, ambientcg/, bk_assets/…).
## Each type dir gets a column (wrapping every WRAP_AT) showing the
## ASSET ITSELF, never a thumbnail: scene instance > .tres/mesh >
## HDRI→unshaded panorama ball > assembled PBR material ball > label.
## Downloads may sit unimported or .gdignored (the GUI bulk-import
## crash surface — see AGENTS.md), so every read is dual-path:
## load() when ResourceLoader exists, else raw GLTFDocument/Image.load.

@export var provider := ""
@export var root := "res://Assets2Godot"

const SCENE_EXTS := ["gltf", "glb", "tscn", "scn", "fbx", "obj"]
const GLTF_EXTS := ["gltf", "glb"]
const SKY_EXTS := ["hdr", "exr"]
const IMAGE_EXTS := ["png", "jpg", "jpeg", "webp", "tga", "bmp"]
const MAP_KEYS := { # filename fragment → material slot
	"albedo": ["color", "basecolor", "albedo", "diff"],
	"normal": ["normalgl", "nor_gl", "normal"],
	"roughness": ["rough"],
	"ao": ["ambientocclusion", "_ao"],
	"metallic": ["metal"],
	"heightmap": ["disp"],
}
const DX := 3.0
const DZ := 4.0
const WRAP_AT := 5

## One deferred repopulate per idle point — filesystem_changed fires
## per scan step, and each pass decodes real assets (gltf, EXR).
var _populate_queued := false

func _ready() -> void:
	_populate()
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if not fs.filesystem_changed.is_connected(_queue_populate):
			fs.filesystem_changed.connect(_queue_populate)

## filesystem_changed fires per scan step — a repopulate per signal
## would decode every representative asset N times over one import.
## Defer to idle (after the scan) and coalesce to a single pass.
func _queue_populate() -> void:
	if _populate_queued:
		return
	_populate_queued = true
	_populate_idle.call_deferred()

func _populate_idle() -> void:
	if not is_inside_tree():
		_populate_queued = false
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and fs.is_scanning():
		_populate_idle.call_deferred()
		return
	_populate_queued = false
	_populate()

func _populate() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	var base := root.path_join(provider)
	if not DirAccess.dir_exists_absolute(base):
		_label("(empty — no %s downloads yet)" % provider, Vector3.ZERO)
		return
	var i := 0
	for type_dir in DirAccess.get_directories_at(base):
		_place_type(base.path_join(type_dir),
			Vector3(float(i % WRAP_AT) * DX, 0, float(i / WRAP_AT) * DZ))
		i += 1
	_plate(i)


## A faint slab under the populated columns — the grid reads as one
## unit instead of objects scattered on open ground.
func _plate(count: int) -> void:
	if count == 0:
		return
	var cols: int = mini(count, WRAP_AT)
	var rows: int = (count - 1) / WRAP_AT + 1
	var bm := BoxMesh.new()
	bm.size = Vector3(cols * DX + 1.0, 0.04, rows * DZ + 1.0)
	var p := MeshInstance3D.new()
	p.mesh = bm
	p.position = Vector3((cols - 1) * DX * 0.5, 0.02,
		(rows - 1) * DZ * 0.5)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.3, 0.3)
	p.material_override = m
	add_child(p)

func _place_type(dir: String, pos: Vector3) -> void:
	var type_name := dir.get_file()
	_label(type_name, pos + Vector3(0, 2.5, 0))
	var subs := DirAccess.get_directories_at(dir)
	if not subs.is_empty():
		dir = dir.path_join(subs[0])
	var files := _collect_files(dir)
	for f in files:
		if f.get_extension() in SCENE_EXTS:
			if _place_scene(f, pos):
				return
	for f in files:
		if f.get_extension() == "tres" and ResourceLoader.exists(f):
			var res: Variant = load(f)
			if res is Material:
				_show_material(res, pos)
				return
	for f in files: # HDR/EXR beats preview jpgs: show the panorama
		if f.get_extension() in SKY_EXTS and "hdri" in type_name.to_lower():
			var tex := _load_tex(f)
			if tex:
				_show_pano(tex, pos)
				return
	var mat := _assemble_material(files)
	if mat != null:
		_show_material(mat, pos)
		return
	_label("(no usable asset)", pos + Vector3(0, 1.0, 0))


## Payload paths inside one asset dir — its own files plus ONE subdir
## level: real downloads nest maps under textures_<res>/, textures/,
## materials/ (flat fixture dirs still work — their files come first
## alphabetically, so a top-level .gltf keeps beating a nested one).
func _collect_files(dir: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".import"):
			out.append(dir.path_join(f))
	for sub in DirAccess.get_directories_at(dir):
		var sd := dir.path_join(sub)
		for f in DirAccess.get_files_at(sd):
			if not f.ends_with(".import"):
				out.append(sd.path_join(f))
	out.sort()
	return out

func _place_scene(path: String, pos: Vector3) -> bool:
	var inst: Node3D = null
	if ResourceLoader.exists(path): # imported → PackedScene or Mesh (.obj)
		var res: Variant = load(path)
		if res is PackedScene:
			inst = res.instantiate()
		elif res is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = res
			inst = mi
	elif path.get_extension() in GLTF_EXTS: # raw, no import needed
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) == OK:
			var node := doc.generate_scene(state)
			if node is Node3D:
				inst = node
	if inst == null:
		return false
	inst.position = pos
	add_child(inst)
	return true

## Dual-path texture: imported → load(), .gdignored → Image.load.
func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)

## Filename-keyed PBR assembly — one StandardMaterial3D with every map
## the download shipped in its proper slot. The material IS the asset.
func _assemble_material(files: Array) -> Material:
	var mat := StandardMaterial3D.new()
	var used := false
	for f in files:
		var ext: String = f.get_extension()
		if ext not in IMAGE_EXTS:
			continue
		var lower: String = f.to_lower()
		var tex := _load_tex(f)
		if tex == null:
			continue
		if MAP_KEYS["albedo"].any(func(k): return k in lower):
			mat.albedo_texture = tex
			used = true
		elif MAP_KEYS["normal"].any(func(k): return k in lower):
			mat.normal_enabled = true
			mat.normal_texture = tex
			used = true
		elif MAP_KEYS["roughness"].any(func(k): return k in lower):
			mat.roughness_texture = tex
			used = true
		elif MAP_KEYS["ao"].any(func(k): return k in lower):
			mat.ao_enabled = true
			mat.ao_texture = tex
			used = true
		elif MAP_KEYS["metallic"].any(func(k): return k in lower):
			mat.metallic = 1.0
			mat.metallic_texture = tex
			used = true
		elif MAP_KEYS["heightmap"].any(func(k): return k in lower):
			if mat.albedo_texture == null:
				mat.albedo_texture = tex # lone disp map stays visible
				used = true
	if not used: # e.g. brushes: no map keywords — first image is the asset
		for f in files:
			if f.get_extension() in IMAGE_EXTS:
				var tex := _load_tex(f)
				if tex:
					mat.albedo_texture = tex
					used = true
					break
	return mat if used else null

func _show_material(mat: Material, pos: Vector3) -> void:
	var ball := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	ball.mesh = sphere
	ball.material_override = mat
	ball.position = pos + Vector3(0, 0.5, 0)
	add_child(ball)

## An unshaded panorama ball under an HDRI dir — proves the file
## decodes and shows its look WITHOUT hijacking the stage's neutral
## sky (the chrome ball in the references row stays on neutral light;
## a downloaded HDRI goes live through an explicit drop, not by
## existing on disk).
func _show_pano(tex: Texture2D, pos: Vector3) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	_show_material(mat, pos)

func _label(text: String, pos: Vector3) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Same read as the zone titles / the "DOWNLOADING A2G" status:
	# white text over a faint dark halo, no hard outline.
	l.modulate = Color.WHITE
	l.outline_size = 8
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.3)
	add_child(l)
