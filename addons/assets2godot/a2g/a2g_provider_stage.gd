@tool
extends Node3D
## Populates this stage with whatever sits under
## <root>/<provider>/ — the provider download roots inside the shared
## res://Assets2Godot/ parent (polyhaven/, ambientcg/, bk_assets/…).
## Each type dir gets a column (wrapping every WRAP_AT) showing the
## ASSET ITSELF, never a thumbnail: scene instance > .tres/mesh >
## HDRI→sky+chrome ball > assembled PBR material ball > honest label.
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
	for f in files: # HDR/EXR beats preview jpgs: feed sky + chrome ball
		if f.get_extension() in SKY_EXTS and "hdri" in type_name.to_lower():
			var tex := _load_tex(f)
			if tex:
				_feed_sky(tex)
				_show_chrome(pos)
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

## A chrome ball under an HDRI dir: proves the sky feeds reflections.
func _show_chrome(pos: Vector3) -> void:
	var mat := StandardMaterial3D.new()
	mat.metallic = 1.0
	mat.roughness = 0.05
	_show_material(mat, pos)

## A real downloaded HDRI as the sky — proves the file loads and
## lights. Scoped to the nearest ancestor that carries a
## WorldEnvironment: inside the preview instance that's the preview's
## own env, never the edited scene's.
func _feed_sky(tex: Texture2D) -> void:
	if tex == null:
		return
	var env := _stage_world_env()
	if env == null or env.environment == null:
		return
	var cur := env.environment.sky
	if cur != null and cur.sky_material is PanoramaSkyMaterial \
			and cur.sky_material.panorama == tex:
		return
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = tex
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.environment.sky = sky
	env.environment.background_mode = Environment.BG_SKY

## Walks ancestors outward — the first subtree with a
## WorldEnvironment is this stage's own sky host.
func _stage_world_env() -> WorldEnvironment:
	var n: Node = self
	while n != null:
		var we := n.find_child("WorldEnvironment", true, false) as WorldEnvironment
		if we != null:
			return we
		n = n.get_parent()
	return null

func _label(text: String, pos: Vector3) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(l)
