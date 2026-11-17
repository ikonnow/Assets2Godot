@tool
extends Node3D
## Root of the opt-in A2G preview stage — the settings menu's
## "Preview scene" instance and the repo's run/main_scene. The same
## controls live twice: inspector exports (edited scenes don't run
## Control input) and the runtime overlay (F5).

## Sky backdrop on/off. Ambient + reflections stay SKY-sourced, so
## hiding the panorama changes only the backdrop, not the light —
## the lookdev trick for judging a dropped HDRI's contribution.
@export var activate_sky := true:
	set(v):
		activate_sky = v
		_apply_sky()
## Sky energy — scales the backdrop AND the sky-sourced ambient /
## reflections together, i.e. "how present is the HDRI".
@export_range(0.0, 2.0, 0.05) var sky_energy := 1.0:
	set(v):
		sky_energy = v
		_apply_sky()
## UV1 scale on the ground plane's material — a dropped .tres is
## duplicated first so the on-disk resource keeps its own scale.
@export_range(0.25, 8.0, 0.25) var ground_uv := 1.0:
	set(v):
		ground_uv = v
		_apply_tiling()

@export_group("Zones")
@export var show_references := true:
	set(v):
		show_references = v
		_apply_zones()
@export var show_targets := true:
	set(v):
		show_targets = v
		_apply_zones()
@export var show_scale := true:
	set(v):
		show_scale = v
		_apply_zones()
@export var show_stages := true:
	set(v):
		show_stages = v
		_apply_zones()

@export_group("Downloads")
@export_tool_button("Autoplace downloads") var autoplace := _autoplace
@export_tool_button("Random place") var random_place := _random_place

const PROVIDER_ROOTS := [
	"res://Assets2Godot/polyhaven",
	"res://Assets2Godot/ambientcg",
	"res://Assets2Godot/bk_assets",
]
const SCENE_EXTS := ["gltf", "glb", "obj", "fbx"]
const GLTF_EXTS := ["gltf", "glb"]
const SKY_EXTS := ["hdr", "exr"]
const SCAN_DEPTH := 4
const SCATTER_COUNT := 3

## The duplicate parked on the ground so UV edits never touch the
## shared or freshly dropped resource.
var _ground_dup: StandardMaterial3D


func _ready() -> void:
	_apply_sky()
	_apply_tiling()
	_apply_zones()
	if Engine.is_editor_hint():
		$PreviewUI.hide()
		return
	_wire_ui()


func _wire_ui() -> void:
	var vb := $PreviewUI/Panel/Margin/VBox
	vb.get_node("SkyCheck").toggled.connect(
		func(on: bool) -> void: activate_sky = on)
	_bind_slider(vb.get_node("SkyRow/SkySlider"),
		vb.get_node("SkyRow/SkyVal"),
		func(v: float) -> void: sky_energy = v)
	_bind_slider(vb.get_node("UvRow/UvSlider"),
		vb.get_node("UvRow/UvVal"),
		func(v: float) -> void: ground_uv = v)
	vb.get_node("ZoneGrid/ZnRefs").toggled.connect(
		func(on: bool) -> void: show_references = on)
	vb.get_node("ZoneGrid/ZnTargets").toggled.connect(
		func(on: bool) -> void: show_targets = on)
	vb.get_node("ZoneGrid/ZnScale").toggled.connect(
		func(on: bool) -> void: show_scale = on)
	vb.get_node("ZoneGrid/ZnStages").toggled.connect(
		func(on: bool) -> void: show_stages = on)
	vb.get_node("BtnRow/BtnAutoplace").pressed.connect(_autoplace)
	vb.get_node("BtnRow/BtnRandom").pressed.connect(_random_place)


func _bind_slider(s: HSlider, val: Label, apply: Callable) -> void:
	s.value_changed.connect(
		func(v: float) -> void:
			apply.call(v)
			val.text = "×%.2f" % v)


func _apply_sky() -> void:
	if not is_inside_tree():
		return
	var env: Environment = $WorldEnvironment.environment
	if env == null:
		return
	env.background_mode = Environment.BG_SKY if activate_sky \
		else Environment.BG_COLOR
	env.background_color = Color(0.2, 0.2, 0.22)
	env.background_energy_multiplier = maxf(sky_energy, 0.0)


func _apply_zones() -> void:
	if not is_inside_tree():
		return
	$References.visible = show_references
	$DropTargets.visible = show_targets
	$ScaleRow.visible = show_scale
	$PolyhavenStage.visible = show_stages
	$AmbientcgStage.visible = show_stages
	$LblStages.visible = show_stages


func _apply_tiling() -> void:
	if not is_inside_tree():
		return
	var mi := $Ground
	var mat := mi.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	if _ground_dup != mat:
		mat = mat.duplicate()
		mi.set_surface_override_material(0, mat)
		_ground_dup = mat
	mat.uv1_scale = Vector3(ground_uv, ground_uv, ground_uv)


# MARK: downloads → stage

## Random downloaded material onto every drop target + a random
## downloaded HDRI into the sky + one model centered on the pad —
## the "populate the whole stage" button.
func _autoplace() -> void:
	var d := _collect_downloads()
	if not d["materials"].is_empty():
		d["materials"].shuffle()
		var i := 0
		for c in $DropTargets.get_children():
			if not c is MeshInstance3D:
				continue
			var m: Variant = load(d["materials"][i % d["materials"].size()])
			if m is Material:
				c.set_surface_override_material(0, m)
			i += 1
	if not d["hdris"].is_empty():
		var tex := _load_tex(d["hdris"].pick_random())
		if tex != null:
			var sm := PanoramaSkyMaterial.new()
			sm.panorama = tex
			var sky := Sky.new()
			sky.sky_material = sm
			$WorldEnvironment.environment.sky = sky
			activate_sky = true
			var check := get_node_or_null(
				^"PreviewUI/Panel/Margin/VBox/SkyCheck")
			if check != null:
				check.set_pressed_no_signal(true)
	_center_model(d["models"])


## Up to SCATTER_COUNT random downloaded models, random spot + yaw
## on the drop pad. Re-pressing replaces the scatter.
func _random_place() -> void:
	var box := $AutoPlaced
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	var models: Array = _collect_downloads()["models"]
	models.shuffle()
	var placed := 0
	for p in models:
		if placed >= SCATTER_COUNT:
			break
		var inst := _instantiate(p)
		if inst == null:
			continue
		var a := randf() * TAU
		var r := 0.6 + randf() * 1.9
		inst.position = Vector3(cos(a) * r, 0, sin(a) * r)
		inst.rotation.y = randf() * TAU
		box.add_child(inst)
		_ground(inst)
		placed += 1


func _center_model(models: Array) -> void:
	var box := $AutoPlaced
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	models.shuffle()
	for p in models:
		var inst := _instantiate(p)
		if inst == null:
			continue
		box.add_child(inst)
		_ground(inst)
		return


## Dual-path instance: imported → load() (PackedScene or Mesh),
## unimported .gltf/.glb → raw GLTFDocument (same rule the provider
## stage uses — .gdignored downloads never reach the importer).
func _instantiate(path: String) -> Node3D:
	var inst: Node3D = null
	if ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is PackedScene:
			inst = res.instantiate()
		elif res is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = res
			inst = mi
	elif path.get_extension() in GLTF_EXTS:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) == OK:
			var n := doc.generate_scene(state)
			if n is Node3D:
				inst = n
	return inst


## Drop the instance so its global AABB's lowest point rests on y=0.
func _ground(n: Node3D) -> void:
	var aabb := AABB()
	var first := true
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is VisualInstance3D:
			var b: AABB = c.global_transform * c.get_aabb()
			aabb = b if first else aabb.merge(b)
			first = false
		stack.append_array(c.get_children())
	if not first:
		n.position.y -= aabb.position.y


func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)


## Every usable payload under the provider roots, by kind — real
## download layout (type/asset/textures_*/), bounded depth.
func _collect_downloads() -> Dictionary:
	var out := {"materials": [], "models": [], "hdris": []}
	for prov in PROVIDER_ROOTS:
		if DirAccess.dir_exists_absolute(prov):
			_scan_dir(prov, out, SCAN_DEPTH)
	return out


func _scan_dir(dir: String, out: Dictionary, depth: int) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".import"):
			continue
		var ext := f.get_extension()
		var path := dir.path_join(f)
		if ext == "tres":
			if _tres_is_material(path):
				out["materials"].append(path)
		elif ext in SKY_EXTS:
			out["hdris"].append(path)
		elif ext in SCENE_EXTS:
			out["models"].append(path)
	if depth <= 0:
		return
	for s in DirAccess.get_directories_at(dir):
		_scan_dir(dir.path_join(s), out, depth - 1)


## Header + ext_resource sniff instead of load(): a .tres whose maps
## never went through the importer spams parse errors on load() and
## would come back with null texture slots anyway. Type check keeps
## *SkyMaterial resources (they ARE Material but don't belong on a
## mesh) out of the materials list.
func _tres_is_material(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var head := ""
	while f.get_position() < f.get_length() and head.length() < 8192:
		var l := f.get_line()
		head += l + "\n"
		if l.begins_with("[resource") or l.begins_with("[sub_resource"):
			break
	var t := _attr(head.get_slice("\n", 0), "type")
	if not t.ends_with("Material") or t.ends_with("SkyMaterial"):
		return false
	for l in head.split("\n"):
		if l.begins_with("[ext_resource"):
			var p := _attr(l, "path")
			if p != "" and not ResourceLoader.exists(p):
				return false
	return true


func _attr(line: String, key: String) -> String:
	var a := line.find(key + "=\"")
	if a < 0:
		return ""
	a += key.length() + 2
	var b := line.find("\"", a)
	return line.substr(a, b - a)
