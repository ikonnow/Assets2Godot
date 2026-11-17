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
## Texture repeat on the ground plane's material — a dropped .tres is
## duplicated first so the on-disk resource keeps its own scale.
@export_range(0.25, 8.0, 0.25) var ground_tiling := 1.0:
	set(v):
		ground_tiling = v
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
@export_tool_button("Autoplace A2G assets") var autoplace := _autoplace
@export_tool_button("Scatter A2G assets") var scatter := _random_place

const SceneDrop := preload("res://addons/assets2godot/a2g/a2g_scene_drop.gd")

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
const PANEL_NAME := "A2GPreviewPanel"
## Identity marker that survives add_child auto-renames — a second
## parked panel gets renamed "@PanelContainer@<id>" and escapes every
## name match.
const PANEL_GROUP := "a2g_preview_panel"
## The editor rebuilds the viewport's input surface at its own pace —
## the panel re-attaches on this cadence, same rule as the drop overlay.
const HOST_RECHECK := 45

## The duplicate parked on the ground so UV edits never touch the
## shared or freshly dropped resource.
var _ground_dup: StandardMaterial3D
## Editor-side copy of the overlay, parked inside the 3D viewport's
## input surface — ownerless, so it never enters the edited scene.
var _editor_panel: Control
var _host_tick := 0

const PANEL_SCENE_PATH := \
		"res://addons/assets2godot/a2g/a2g_preview_panel.tscn"


func _ready() -> void:
	_apply_sky()
	_apply_tiling()
	_apply_zones()
	_style_zone_labels()
	if Engine.is_editor_hint():
		set_process(true)
		call_deferred("_attach_editor_panel")
		return
	var p: Control = _spawn_runtime_ui()
	_wire_ui(p.get_node(^"Margin/VBox"))
	_sync_controls(p.get_node(^"Margin/VBox"))


## The runtime overlay is instanced from its own scene when the
## game runs — no PreviewUI node exists in the .tscn, so it never
## clutters the scene dock while editing (and can't be saved back
## into the scene by accident).
func _spawn_runtime_ui() -> Control:
	var layer := CanvasLayer.new()
	layer.name = "PreviewUI"
	var panel: Control = load(PANEL_SCENE_PATH).instantiate()
	layer.add_child(panel)
	add_child(layer)
	return panel


func _process(_dt: float) -> void:
	# Editor-only (process is off in the game): keep the panel parked
	# inside the live viewport surface, rebuilt by the editor anytime.
	_host_tick += 1
	if _host_tick >= HOST_RECHECK:
		_host_tick = 0
		_attach_editor_panel()


func _exit_tree() -> void:
	if is_instance_valid(_editor_panel):
		_editor_panel.queue_free()


## Editor twin of the runtime overlay — an instance of the same panel
## so both surfaces share one layout and one wiring. The viewport's
## input surface is where Control children actually receive input in an
## edited scene (the drop overlay lives there too); parking the panel
## inside the scene itself would render it unclickable.
##
## Several copies of this scene can be alive at once — an injected
## instance, the .tscn open in a tab, an orphan left by a plugin
## reload. To keep exactly ONE panel, each parks with an "a2g_owner"
## meta pointing at its instance: a sweep over the whole editor tree
## frees orphans and pre-meta leftovers (the old surface-children sweep
## missed strays in rebuilt hosts), a live in-tree foreign owner keeps
## the slot, and the edited scene root outranks injected copies so the
## scene the user is actually editing drives the panel.
func _attach_editor_panel() -> void:
	if not Engine.is_editor_hint():
		set_process(false)
		return
	if not is_inside_tree():
		# Detached but not freed yet (scene swap / plugin reload) —
		# get_tree() is null and this copy must never park a panel.
		return
	var surface := SceneDrop.find_3d_surface()
	if surface == null:
		return
	var root := EditorInterface.get_edited_scene_root()
	var foreign: Control = null
	# Candidates: group members (a rename-proof identity), name matches,
	# and structurally matching strays in the live surface — a
	# duplicate that collides on add_child loses the panel name
	# entirely ("@PanelContainer@<id>") yet still carries the
	# Margin/VBox/SkyCheck subtree.
	var cands: Array = surface.get_children().duplicate()
	for g in get_tree().get_nodes_in_group(PANEL_GROUP):
		if g not in cands:
			cands.append(g)
	for p in get_tree().root.find_children(
			"*" + PANEL_NAME + "*", "Control", true, false):
		if p not in cands:
			cands.append(p)
	for p in cands:
		if p == _editor_panel:
			p.set_meta(&"a2g_owner", self)
			p.add_to_group(PANEL_GROUP)
			continue
		# Variant, not Object: a freed ref fails typed assignment.
		# And no default on get_meta — it errors on missing keys anyway.
		var owner: Variant = p.get_meta(&"a2g_owner") \
				if p.has_meta(&"a2g_owner") else null
		var is_panel: bool = owner != null or p.is_in_group(PANEL_GROUP) \
				or str(p.name).contains(PANEL_NAME) \
				or p.get_node_or_null(^"Margin/VBox/SkyCheck") != null
		if not is_panel:
			continue
		if owner == self:
			if is_instance_valid(_editor_panel):
				_editor_panel.queue_free()  # only one may own the slot
			_editor_panel = p  # re-adopt it after the member got lost
			p.add_to_group(PANEL_GROUP)
		elif is_instance_valid(owner) and owner is Node \
				and (owner as Node).is_inside_tree() \
				and not (self == root and owner != root):
			foreign = p
		else:
			# No meta, a freed owner, or a detached-but-alive orphan:
			# an out-of-tree owner can't drive its exports anyway.
			p.queue_free()
	if foreign != null:
		if is_instance_valid(_editor_panel):
			_editor_panel.queue_free()
		_editor_panel = null
		return
	if not is_instance_valid(_editor_panel):
		_editor_panel = ResourceLoader.load(PANEL_SCENE_PATH, "",
				ResourceLoader.CACHE_MODE_REPLACE).instantiate()
		_editor_panel.name = PANEL_NAME
		_editor_panel.set_meta(&"a2g_owner", self)
		_editor_panel.add_to_group(PANEL_GROUP)
		_wire_ui(_editor_panel.get_node(^"Margin/VBox"))
	_sync_controls(_editor_panel.get_node(^"Margin/VBox"))
	if _editor_panel.get_parent() != surface:
		if _editor_panel.get_parent() != null:
			_editor_panel.reparent(surface)
		else:
			surface.add_child(_editor_panel)


func _wire_ui(vb: VBoxContainer) -> void:
	# Orphaned panels keep these connections — without a weak owner a
	# dead capture logs "lambda capture freed" on every emit.
	var wr := weakref(self)
	vb.get_node("SkyCheck").toggled.connect(
		func(on: bool) -> void:
			var o = wr.get_ref()
			if o != null:
				o.activate_sky = on)
	_bind_slider(vb.get_node("SkyRow/SkySlider"),
		vb.get_node("SkyRow/SkyVal"), wr, &"sky_energy")
	_bind_slider(vb.get_node("UvRow/UvSlider"),
		vb.get_node("UvRow/UvVal"), wr, &"ground_tiling")
	var zones := {
		"ZoneGrid/ZnRefs": &"show_references",
		"ZoneGrid/ZnTargets": &"show_targets",
		"ZoneGrid/ZnScale": &"show_scale",
		"ZoneGrid/ZnStages": &"show_stages"}
	for path in zones:
		vb.get_node(path).toggled.connect(
			func(on: bool) -> void:
				var o = wr.get_ref()
				if o == null:
					return
				o.set(zones[path], on)
				if on:
					o._focus_visible_zones())
	vb.get_node("BtnRow/BtnAutoplace").pressed.connect(
		func() -> void:
			var o = wr.get_ref()
			if o != null:
				o._autoplace())
	vb.get_node("BtnRow/BtnScatter").pressed.connect(
		func() -> void:
			var o = wr.get_ref()
			if o != null:
				o._random_place())


func _bind_slider(s: HSlider, val: Label, wr: WeakRef, prop: StringName) -> void:
	s.value_changed.connect(
		func(v: float) -> void:
			var o = wr.get_ref()
			if o != null:
				o.set(prop, v)
				val.text = "×%.2f" % v)


## Checkbox ON → frames the bounds of all enabled zones together:
## keeps the current view direction, pulls the camera to fit — the
## editor "Focus" feel. In the editor this moves the viewport's
## editor camera; in the game it moves the scene's Camera3D.
func _focus_visible_zones() -> void:
	var nodes: Array = []
	if show_references:
		nodes.append($References)
	if show_targets:
		nodes.append($DropTargets)
	if show_scale:
		nodes.append($ScaleRow)
	if show_stages:
		nodes.append_array([$PolyhavenStage, $AmbientcgStage])
	var aabb := AABB()
	var first := true
	for n in nodes:
		var b: Variant = _zone_aabb(n)
		if b != null:
			aabb = b if first else aabb.merge(b)
			first = false
	if first:
		return
	var cam := _focus_cam()
	if cam == null:
		return
	var center := aabb.get_center()
	var radius := maxf(0.5, aabb.size.length() * 0.5)
	var dist := radius / tan(deg_to_rad(cam.fov) * 0.5) * 1.15
	var dir := -cam.global_transform.basis.z.normalized()
	cam.global_position = center - dir * dist
	cam.look_at(center, Vector3.UP)


## The camera a zone toggle should move — viewport editor camera in
## the editor, the scene camera when running.
func _focus_cam() -> Camera3D:
	if Engine.is_editor_hint():
		var vp := EditorInterface.get_editor_viewport_3d(0)
		if vp != null:
			return vp.get_camera_3d()
		return null
	return $Camera3D


## Merged global AABB of the node's visible visuals — null when the
## node holds nothing worth framing.
func _zone_aabb(n: Node) -> Variant:
	var aabb := AABB()
	var first := true
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is VisualInstance3D and c.is_visible_in_tree():
			var b: AABB = c.global_transform * c.get_aabb()
			aabb = b if first else aabb.merge(b)
			first = false
		stack.append_array(c.get_children())
	return null if first else aabb


## Push the live exports into a control tree — without this, a
## recreated panel (or an inspector edit while the panel is parked)
## leaves checkboxes showing the .tscn's default "pressed" instead of
## the real state. Only diverged controls are written so a mid-click
## press is never disturbed.
func _sync_controls(vb: VBoxContainer) -> void:
	_sync_check(vb.get_node(^"SkyCheck"), activate_sky)
	_sync_check(vb.get_node(^"ZoneGrid/ZnRefs"), show_references)
	_sync_check(vb.get_node(^"ZoneGrid/ZnTargets"), show_targets)
	_sync_check(vb.get_node(^"ZoneGrid/ZnScale"), show_scale)
	_sync_check(vb.get_node(^"ZoneGrid/ZnStages"), show_stages)
	var sky: HSlider = vb.get_node(^"SkyRow/SkySlider")
	if not is_equal_approx(sky.value, sky_energy):
		sky.set_value_no_signal(sky_energy)
		vb.get_node(^"SkyRow/SkyVal").text = "×%.2f" % sky_energy
	var uv: HSlider = vb.get_node(^"UvRow/UvSlider")
	if not is_equal_approx(uv.value, ground_tiling):
		uv.set_value_no_signal(ground_tiling)
		vb.get_node(^"UvRow/UvVal").text = "×%.2f" % ground_tiling


func _sync_check(c: CheckBox, on: bool) -> void:
	if c.button_pressed != on:
		c.set_pressed_no_signal(on)


## Both surfaces — the runtime overlay and the parked editor twin.
func _resync_controls() -> void:
	var vb := get_node_or_null(^"PreviewUI/Panel/Margin/VBox") as VBoxContainer
	if vb != null:
		_sync_controls(vb)
	if is_instance_valid(_editor_panel):
		_sync_controls(_editor_panel.get_node(^"Margin/VBox"))


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
	mat.uv1_scale = Vector3(ground_tiling, ground_tiling, ground_tiling)


## White text over a faint dark halo — the same read as the
## "DOWNLOADING A2G" status (white caps, shadow at 0.3 alpha), not a
## hard black outline.
func _style_zone_labels() -> void:
	for l in find_children("*", "Label3D", true, false):
		l.modulate = Color.WHITE
		l.outline_size = 10
		l.outline_modulate = Color(0.0, 0.0, 0.0, 0.3)


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
			_resync_controls()
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
		elif ext in SKY_EXTS and _is_sky_path(dir):
			out["hdris"].append(path)
		elif ext in SCENE_EXTS:
			out["models"].append(path)
	if depth <= 0:
		return
	for s in DirAccess.get_directories_at(dir):
		_scan_dir(dir.path_join(s), out, depth - 1)


## .hdr/.exr only counts as a sky HDRI under an hdri* type dir — the
## same extensions carry normal maps and terrain heightmaps in the
## materials/terrains trees, which must not reach the sky.
func _is_sky_path(dir: String) -> bool:
	for seg in dir.split("/"):
		if seg.begins_with("hdri"):
			return true
	return false


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
	# Mesh-usable types: *Material AND *Material3D — StandardMaterial3D /
	# ORMMaterial3D end on "3D", not "Material". *SkyMaterial stays out.
	if not (t.ends_with("Material") or t.ends_with("Material3D")) \
			or t.ends_with("SkyMaterial"):
		return false
	for l in head.split("\n"):
		if l.begins_with("[ext_resource"):
			var p := _attr(l, "path")
			if p == "":
				continue
			# Provider materials reference their maps relative to the
			# .tres ("./textures_2K/x.jpg") — ResourceLoader only takes
			# res://, user:// or absolute OS paths, so resolve first.
			if not p.begins_with("res://") and not p.begins_with("user://") \
					and not p.is_absolute_path():
				p = path.get_base_dir().path_join(p).simplify_path()
			if not ResourceLoader.exists(p) or not _map_loadable(p):
				return false
	return true


## A map can pass ResourceLoader.exists (a stale .import claims
## Texture2D) yet fail to decode — BlendKit ships JPEG/PNG payloads
## under .exr names. The declared extension's magic bytes decide
## cheaply; unknown extensions skip the check.
const _MAGIC := {
	"exr": [0x76, 0x2f, 0x31, 0x01],
	"png": [0x89, 0x50, 0x4e, 0x47],
	"jpg": [0xff, 0xd8],
	"jpeg": [0xff, 0xd8],
	"hdr": [0x23],
}


func _map_loadable(path: String) -> bool:
	var magic: Array = _MAGIC.get(path.get_extension().to_lower(), [])
	if magic.is_empty():
		return true
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var head := f.get_buffer(magic.size())
	if head.size() < magic.size():
		return false
	for i in magic.size():
		if head[i] != magic[i]:
			return false
	return true


func _attr(line: String, key: String) -> String:
	var a := line.find(key + "=\"")
	if a < 0:
		return ""
	a += key.length() + 2
	var b := line.find("\"", a)
	return line.substr(a, b - a)
