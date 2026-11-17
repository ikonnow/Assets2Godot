@tool
extends Control
## Invisible drop target for remote-provider payloads on surfaces the
## editor already owns: a full-rect, MOUSE_FILTER_PASS child parked
## inside the 3D viewport's input "surface" (scene mode) or a
## FileSystem dock Tree (filesystem mode).
##
## The engine's drop walk asks the topmost control under the cursor
## first — that's this overlay. A remote_* payload (what provider cards
## emit via set_drag_forwarding) answers true and drives the
## download → ghost → place/assign/HDRI flow; every other payload
## answers false so the walk continues to the surface/Tree and the
## editor's native drop runs unchanged. PASS keeps normal mouse input
## falling through to the surface — the viewport stays fully native.
##
## The scene ghost is a self-drawn MeshInstance3D (progress-fill
## shader + wireframe edges), an INTERNAL child of the edited scene
## root — never EditorSelection, which would hang the transform gizmo
## on it — and the host is re-resolved periodically because editor
## internals can be rebuilt.

const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")
const AcgTerrain = preload("res://addons/assets2godot/a2g/a2g_terrain.gd")
const Conversions = preload("res://addons/assets2godot/conversions.gd")

enum Mode { SCENE, FILESYSTEM }

## Unshaded gradient — one 12-triangle box, no lighting/fog/depth
## pipeline, one `progress` uniform per tick. Below `progress` the fill
## color shows, above it the empty tint; `dims_y` normalizes height.
const GHOST_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled, depth_draw_never;

uniform vec4 fill_col : source_color = vec4(0.25, 0.6, 1.0, 0.35);
uniform vec4 empty_col : source_color = vec4(0.25, 0.6, 1.0, 0.06);
uniform float progress : hint_range(0.0, 1.0) = 1.0;
uniform float dims_y = 1.0;

varying float h;

void vertex() {
	h = VERTEX.y / dims_y + 0.5;
}

void fragment() {
	float filled = 1.0 - smoothstep(progress - 0.03, progress, h);
	vec4 c = mix(empty_col, fill_col, filled);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
"""

const RAY_LEN := 4000.0
## Frames without a remote_dir/progress before a busy-looking provider
## is treated as a rejected start (queue full, plan-gated, …).
const ABORT_FRAMES := 240
const HOST_RECHECK := 30
## Idle editor (no scan running) with a material's maps still
## unimported: after this long the import wait rescans once — and after
## that rescan, gives up.
const IMPORT_IDLE_MS := 1000

const PLACE_COLOR := Color(0.25, 0.6, 1.0, 0.35)
const PLACE_EMPTY := Color(0.25, 0.6, 1.0, 0.06)
const ASSIGN_COLOR := Color(1.0, 0.55, 0.2, 0.35)
const ASSIGN_EMPTY := Color(1.0, 0.55, 0.2, 0.06)
const HDRI_COLOR := Color(0.5, 0.9, 0.5, 0.35)
const HDRI_EMPTY := Color(0.5, 0.9, 0.5, 0.06)
## The HDRI ghost is a dome around the drop point, not the payload
## AABB — a sky's placement is global, so the box's footprint meant
## nothing. The fill sweeps as a rising horizon: progress = sky loaded.
const DOME_RADIUS := 8.0

const PLACE_EXTS := ["glb", "gltf", "fbx", "obj", "tscn", "blend"]
const HDRI_EXTS := ["hdr", "exr"]
const MAT_EXTS := ["tres", "res", "material"]

var mode := Mode.SCENE
## Fallback parent while the real host doesn't exist yet (hidden
## parking spot — the overlay still processes for the remote poll).
var parking: Control

var _ghost: MeshInstance3D
var _ghost_mat: ShaderMaterial
var _ghost_dome := false
var _shader: Shader
var _status: Label
var _mat_cache := {}
var _visuals: Array[Node3D] = []
var _remote := {}
var _remote_kind := ""
var _remote_target: MeshInstance3D
var _remote_point := Vector3.ZERO
var _remote_wait := 0
var _import_idle_since := 0
var _import_nudged := false
var _host_tick := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func _ready() -> void:
	set_process(true)
	_attach_host()
	_status = Label.new()
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.hide()
	add_child(_status)
	_style_status()


## The status look — small bold tracked caps centered just under the
## viewport toolbar. Applied in _show_status too, not only _ready:
## an overlay instance created before a script reload keeps its old
## label geometry (its _ready never re-runs), so the visible path
## must re-assert the style itself.
func _style_status() -> void:
	if _status == null:
		return
	_status.add_theme_color_override("font_color", Color.WHITE)
	# Faint dark shadow so the white caps stay readable over bright sky
	# — low alpha keeps it a soft halo, not a hard offset copy.
	_status.add_theme_color_override("font_shadow_color",
		Color(0.0, 0.0, 0.0, 0.3))
	_status.add_theme_constant_override("shadow_offset_x", 1)
	_status.add_theme_constant_override("shadow_offset_y", 1)
	_status.add_theme_font_size_override("font_size", 10)
	var tracked := FontVariation.new()
	# Editor font names shifted in 4.8 (MSDF variants); has_theme_font
	# resolves them inconsistently with get_theme_font, so walk the
	# candidates newest-first and take the first that actually resolves.
	for fname in [&"main_bold_msdf", &"main_bold", &"main"]:
		if not has_theme_font(fname, "EditorFonts"):
			continue
		var f := get_theme_font(fname, "EditorFonts")
		if f != null:
			tracked.base_font = f
			break
	tracked.variation_embolden = 0.8
	tracked.spacing_glyph = 2
	tracked.spacing_space = 4
	if tracked.base_font != null:
		# No base font at all → keep the theme default (a FontVariation
		# with no base renders nothing).
		_status.add_theme_font_override("font", tracked)
	_status.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_status.offset_top = 28.0


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_EXIT:
			# A drag leaving the surface unpins the hover ghost; a
			# running remote download keeps its pinned box.
			if _remote.is_empty():
				_clear_ghost()
		NOTIFICATION_DRAG_BEGIN:
			_visuals = _collect_visuals()
		NOTIFICATION_DRAG_END:
			_visuals.clear()
			# A drop pins the ghost for the remote download — same rule as
			# MOUSE_EXIT: only the hover ghost leaves with the drag.
			if _remote.is_empty():
				_clear_ghost()


func _process(_dt: float) -> void:
	_host_tick += 1
	if _host_tick >= HOST_RECHECK:
		_host_tick = 0
		_attach_host()
	if not _remote.is_empty():
		_poll_remote()


## Keeps the overlay parked inside the live host — viewport surface or
## FileSystem Tree may be rebuilt by the editor at any time.
func _attach_host() -> void:
	var want: Control = find_3d_surface() if mode == Mode.SCENE \
		else _find_fs_target()
	if want == null:
		want = parking
	if want != null and get_parent() != want:
		reparent(want)
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# MARK: drop contract

func _can_drop_data(at: Vector2, data: Variant) -> bool:
	var kind := _drop_kind(data)
	if kind == "":
		_clear_ghost()
		return false
	if mode == Mode.FILESYSTEM:
		return kind.begins_with("remote")
	if EditorInterface.get_edited_scene_root() == null:
		# No scene yet — the drop itself creates a Node3D root (same
		# result as the editor's own scene-file drop), so placeable
		# kinds still accept. No ghost though: it needs a root to hang
		# from, and assign kinds need a live mesh to hit.
		if kind in ["remote", "remote_terrain", "remote_hdri", "local_hdri"]:
			return true
		_clear_ghost()
		return false
	var hit := _pick_hit(at)
	if hit.is_empty():
		_clear_ghost()
		return false
	match kind:
		"remote_file":
			# Download-only payload — no scene placement, no ghost.
			_clear_ghost()
			return false
		"remote", "remote_hdri", "local_hdri":
			_show_ghost(_payload_aabb(data), hit.get("point"), kind)
		"remote_terrain":
			_show_ghost(_terrain_aabb(data), hit.get("point"), kind)
		"remote_assign", "local_assign":
			var mi := _assign_target(hit.get("node"))
			if mi == null:
				_clear_ghost()
				return false
			_show_ghost(_mesh_world_aabb(mi), mi.global_position, kind)
	return true


func _drop_data(at: Vector2, data: Variant) -> void:
	var kind := _drop_kind(data)
	if mode == Mode.FILESYSTEM:
		if kind.begins_with("remote"):
			_start_download_fs(data)
		return
	var hit := _pick_hit(at)
	match kind:
		"remote", "remote_assign", "remote_hdri", "remote_terrain":
			if not _ensure_scene_root():
				_show_status("couldn't create a scene")
				return
			var point: Vector3 = hit.get("point", _ghost_bottom())
			_start_remote(data, kind, point, _assign_target(hit.get("node")))
		"local_assign":
			var mi := _assign_target(hit.get("node"))
			var mat := _load_material(str(data["files"][0]))
			if mi != null and mat != null:
				_commit_assign(mat, mi)
			_clear_ghost()
		"local_hdri":
			if _ensure_scene_root():
				_commit_hdri(str(data["files"][0]))
			_clear_ghost()


## What a payload wants: remote_* dicts route by remote_kind, native
## "files" drags only answer for what the editor can't do itself
## (.hdr/.exr → sky, Material resources → assign) — scenes/meshes stay
## on the editor's own drop path.
func _drop_kind(data: Variant) -> String:
	if not data is Dictionary:
		return ""
	var d: Dictionary = data
	if str(d.get("remote_slug", "")) != "":
		var kind := str(d.get("remote_kind", "")).to_lower()
		if kind in ["hdri", "hdr", "hdri-element"]:
			return "remote_hdri"
		if kind in ["material", "texture"]:
			return "remote_assign"
		# Map-set kinds carry no geometry — a terrain/decal/atlas is a
		# stack of images, so it places a textured plane, not a model.
		if kind in ["terrain", "decal", "atlas", "plain-image", "brush"]:
			return "remote_terrain"
		# File-only payloads: .sbsar has no Godot importer or runtime —
		# the FileSystem-dock drop still downloads it (external pipeline
		# use), a scene drop refuses instead of downloading then
		# aborting on "no usable asset".
		if kind == "substance":
			return "remote_file"
		return "remote"
	if str(d.get("type", "")) == "files" and d.get("files") is Array \
			and not d["files"].is_empty():
		var path := str(d["files"][0])
		var ext := path.get_extension().to_lower()
		if ext in HDRI_EXTS:
			return "local_hdri"
		if ext in MAT_EXTS and _is_material_file(path):
			return "local_assign"
	return ""


## The ghost box for a payload: provider dimensions when the catalog
## ships real meters, otherwise a unit box — for HDRIs the position is
## cosmetic, the sky is global. Provider data can be malformed, so a
## 1 km cap keeps a bad value from swallowing the whole viewport.
func _payload_aabb(data: Variant) -> AABB:
	var dims: Variant = (data as Dictionary).get("remote_dimensions")
	if dims is Callable:
		# Providers may answer dims lazily (a /info fetch kicked on the
		# first drag frame) — can_drop_data re-reads this every move, so
		# the ghost adopts the real box as soon as it lands.
		dims = dims.call()
	if dims is Vector3 and dims.x > 0.0:
		for i in 3:
			dims[i] = minf(dims[i], 1000.0)
		return AABB(-dims * 0.5, dims)
	return AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


## Terrain ghosts are flat slabs, not cubes — the placed plane's real
## footprint. A real terrain previews at its configured extent/relief
## (the box it will actually occupy); provider dims still win when
## present. Decals/atlases keep the 4×4 map-set slab.
func _terrain_aabb(data: Variant) -> AABB:
	var box := _payload_aabb(data)
	if box.size != Vector3.ONE:
		box.size.y = maxf(box.size.y, 0.05)
		return box
	var d: Dictionary = data if data is Dictionary else {}
	if str(d.get("remote_kind", "")).to_lower() == "terrain":
		var e: float = AcgTerrain.extent_for("")
		var r: float = AcgTerrain.relief_for("")
		return AABB(Vector3(-e * 0.5, 0.0, -e * 0.5), Vector3(e, r, e))
	return AABB(Vector3(-2.0, 0.0, -2.0), Vector3(4.0, 0.05, 4.0))


# MARK: picking — physics first, then the nearest VisualInstance3D
## AABB, so collider-less scene assets are still hit (the editor's own
## selection works the same way); y=0 is the last resort.
func _pick_hit(at: Vector2) -> Dictionary:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return {}
	var origin := cam.project_ray_origin(at)
	var dir := cam.project_ray_normal(at)
	var far := origin + dir * RAY_LEN
	var best := INF
	var out := {}
	if vp.world_3d != null:
		var space := vp.world_3d.direct_space_state
		var q := PhysicsRayQueryParameters3D.create(origin, far)
		var hit: Dictionary = space.intersect_ray(q)
		if not hit.is_empty():
			best = origin.distance_to(hit["position"])
			out = {"point": hit["position"], "node": hit.get("collider"), "dist": best}
	var v := _ray_visuals(origin, far, best)
	if not v.is_empty():
		out = v
	if out.is_empty() and absf(dir.y) > 0.001:
		var t := -origin.y / dir.y
		if t > 0.0:
			out = {"point": origin + dir * t, "node": null}
	if out.is_empty():
		out = {"point": origin + dir * 10.0, "node": null}
	return out


## Visual nodes collected once per drag (DRAG_BEGIN) — a fresh scene
## walk per mouse move would be the expensive part of hovering.
func _collect_visuals() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n := stack.pop_back()
		var n3d := n as Node3D
		if n3d != null and (n3d is VisualInstance3D or n3d.has_method("get_aabb")):
			out.append(n3d)
		stack.append_array(n.get_children())
	return out


func _ray_visuals(origin: Vector3, far: Vector3, current_best: float) -> Dictionary:
	var best := current_best
	var out := {}
	for n3d in _visuals:
		if n3d == _ghost or n3d.get_parent() == _ghost:
			continue
		var box: Variant = null
		if n3d is VisualInstance3D:
			box = (n3d as VisualInstance3D).get_aabb()
		elif n3d.has_method("get_aabb"):
			var b: Variant = n3d.call("get_aabb")
			box = b if b is AABB else null
		if not box is AABB or not n3d.is_visible_in_tree():
			continue
		var wbox: AABB = n3d.global_transform * box
		var p: Variant = wbox.intersects_segment(origin, far)
		if p == null:
			continue
		var d := origin.distance_to(p)
		if d < best:
			best = d
			out = {"point": p, "node": n3d, "dist": d}
	return out


## The MeshInstance3D an assign drop would touch: the hit itself, or a
## collider's/ancestor's subtree — meshes nested under a StaticBody3D
## are the common shape.
func _assign_target(node: Variant) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	if node is Node3D:
		var mi := _mesh_in_subtree(node)
		if mi != null:
			return mi
		var parent := (node as Node).get_parent()
		if parent != null:
			return _mesh_in_subtree(parent)
	return null


func _mesh_in_subtree(root: Node) -> MeshInstance3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n := stack.pop_back()
		if n is MeshInstance3D:
			return n
		stack.append_array(n.get_children())
	return null


func _mesh_world_aabb(mi: MeshInstance3D) -> AABB:
	return mi.global_transform * mi.get_aabb()


## Empty editor → a bare Node3D root so the drop has somewhere to
## land, like the editor's own scene-file drop creating a scene.
## add_root_node covers both "no scene tabs" and "open but empty".
func _ensure_scene_root() -> bool:
	if EditorInterface.get_edited_scene_root() != null:
		return true
	# EditorInterface.add_root_node exists only on 4.5+ — call() keeps
	# the file parse-clean on 4.4, where the drop just reports no
	# landing spot instead of creating the bare root.
	if not EditorInterface.has_method(&"add_root_node"):
		return false
	var root := Node3D.new()
	root.name = "Node3D"
	EditorInterface.call(&"add_root_node", root)
	if EditorInterface.get_edited_scene_root() != null:
		return true
	root.free()
	return false


# MARK: ghost — self-drawn INTERNAL children of the scene root

func _ensure_ghost(kind: String) -> void:
	if _ghost != null:
		return
	if _shader == null:
		_shader = Shader.new()
		_shader.code = GHOST_SHADER
	_ghost = MeshInstance3D.new()
	_ghost.name = "a2g_drop_ghost"
	_ghost_dome = kind.ends_with("hdri")
	_ghost.mesh = SphereMesh.new() if _ghost_dome else BoxMesh.new()
	_ghost_mat = ShaderMaterial.new()
	_ghost_mat.shader = _shader
	_ghost.material_override = _ghost_mat
	var edges := MeshInstance3D.new()
	edges.name = "a2g_drop_edges"
	edges.mesh = _equator_mesh() if _ghost_dome else _edge_mesh()
	var em := StandardMaterial3D.new()
	em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	em.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
	em.no_depth_test = true
	em.disable_fog = true
	edges.material_override = em
	_ghost.add_child(edges)
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		root.add_child(_ghost, false, Node.INTERNAL_MODE_BACK)


## Unit box wireframe (±0.5 corners) — it scales with the ghost.
func _edge_mesh() -> ImmediateMesh:
	var c := []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				c.append(Vector3(x, y, z))
	var pairs := [[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
		[2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]]
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in pairs:
		im.surface_add_vertex(c[e[0]])
		im.surface_add_vertex(c[e[1]])
	im.surface_end()
	return im


## Unit equator ring (radius 0.5 in XZ) — the dome's horizon cue at
## the height the fill sweeps past.
func _equator_mesh() -> ImmediateMesh:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in 33:
		var a := TAU * i / 32.0
		im.surface_add_vertex(Vector3(cos(a), 0.0, sin(a)) * 0.5)
	im.surface_end()
	return im


## Positions the ghost — for place kinds the bottom-center of the box
## rests on the picked point; for assign kinds it frames the target's
## own world AABB (slightly padded); HDRI kinds get the fixed-size
## dome centered on the hit (the sky is global — the point only
## anchors WHERE the horizon line shows).
func _show_ghost(box: AABB, at: Variant, kind: String) -> void:
	var dome := kind.ends_with("hdri")
	if _ghost != null and _ghost_dome != dome:
		_clear_ghost()
	_ensure_ghost(kind)
	if _ghost == null:
		return
	var assign := kind.ends_with("assign")
	var pos: Vector3
	var sc: Vector3
	if dome:
		pos = at
		sc = Vector3.ONE * DOME_RADIUS * 2.0
	elif assign:
		pos = box.get_center()
		sc = box.size * 1.03
	else:
		pos = at + Vector3(0.0, box.size.y * 0.5, 0.0)
		sc = box.size
	for i in 3:
		sc[i] = maxf(sc[i], 0.05)
	_ghost.global_position = pos
	_ghost.scale = sc
	var place := kind == "remote" or kind == "remote_terrain"
	var fill := PLACE_COLOR if place else \
		HDRI_COLOR if dome else ASSIGN_COLOR
	var empty := PLACE_EMPTY if place else \
		HDRI_EMPTY if dome else ASSIGN_EMPTY
	_ghost_mat.set_shader_parameter("fill_col", fill)
	_ghost_mat.set_shader_parameter("empty_col", empty)
	# Unit meshes normalize over local height 1 — dims_y = 1 gives the
	# dome an exactly linear bottom-to-top fill; the box keeps its
	# legacy scale-based sweep.
	_ghost_mat.set_shader_parameter("dims_y", 1.0 if dome else sc.y)
	# Drag-phase ghost: local payloads get the filled "ready" box,
	# remote ones only the wireframe — the fill then reads as literal
	# download progress instead of a 100% box for everything.
	_ghost_mat.set_shader_parameter("progress",
		1.0 if _remote.is_empty() and not kind.begins_with("remote") else 0.0)


func _ghost_bottom() -> Vector3:
	if _ghost == null:
		return _remote_point
	return _ghost.global_position - Vector3(0.0, _ghost.scale.y * 0.5, 0.0)


func _clear_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
		_ghost_mat = null
		_ghost_dome = false


func _show_status(text: String) -> void:
	if _status == null:
		return
	_style_status()
	_status.text = text.to_upper()
	_status.visible = not text.is_empty()


# MARK: remote flow — options → download → dir poll → commit

## Drops pin the ghost and kick the provider's own pipeline: options
## may need a fetch, so remote_download only fires once the option
## answer lands. Already-downloaded assets skip straight to commit.
func _start_remote(data: Dictionary, kind: String, point: Vector3,
		target: MeshInstance3D) -> void:
	_remote = data.duplicate()
	_remote_kind = kind
	_remote_target = target
	_remote_point = point
	_remote_wait = 0
	_import_idle_since = 0
	_import_nudged = false
	set_process(true)
	# "Already downloaded" = progress 1.0 AND the payload we'd commit
	# is actually there — a folder can exist while being useless
	# (aborted or wrong-option download), and those must fall through
	# to the download path, which skips existing files and completes
	# the set instead of aborting on an empty scan.
	var dir := _remote_dir_now()
	if dir != "" and _remote_progress_now() >= 1.0:
		# Downloaded, maps still importing (a drop right after another
		# surface's download): the poll commits once they resolve —
		# a wait, not a repair, so no second download.
		if _awaiting_import(dir):
			_show_status("Importing A2G…")
			return
		if _remote_payload_ready(dir):
			_finish_remote()
			return
	if _ghost != null:
		_ghost_mat.set_shader_parameter("progress", 0.0)
	_show_status("Fetching files…")
	var opt_cb: Variant = _remote.get("remote_options")
	if opt_cb is Callable:
		opt_cb.call(func(options, default_idx): _start_download(options, default_idx))
	else:
		_start_download([], -1)


## FileSystem drops carry no scene state — options → download, the
## provider's own surfaces (card badge, downloads pane) show progress.
func _start_download_fs(data: Dictionary) -> void:
	var dl: Variant = data.get("remote_download")
	if not dl is Callable:
		return
	var opt_cb: Variant = data.get("remote_options")
	if opt_cb is Callable:
		opt_cb.call(func(options, default_idx):
			var opt: Variant = null
			if default_idx >= 0 and default_idx < options.size():
				opt = options[default_idx]
			elif not options.is_empty():
				opt = options[0]
			dl.call(opt.get("data") if opt is Dictionary else null))
	else:
		dl.call(null)


func _start_download(options: Array, default_idx: int) -> void:
	if _remote.is_empty():
		return
	var opt: Variant = null
	if default_idx >= 0 and default_idx < options.size():
		opt = options[default_idx]
	elif not options.is_empty():
		opt = options[0]
	var data: Variant = opt.get("data") if opt is Dictionary else null
	var dl: Variant = _remote.get("remote_download")
	if dl is Callable:
		dl.call(data)
	else:
		_abort_remote("asset has no download action")


func _poll_remote() -> void:
	var prog := _remote_progress_now()
	var dir := _remote_dir_now()
	# Ahead of the payload gate: that one loads the .tres — mid-import
	# it passes (the Material loads, slots null) and logs one load
	# error per map, every frame.
	if dir != "" and prog >= 1.0 and _awaiting_import(dir):
		_remote_wait = 0
		if _ghost_mat != null:
			_ghost_mat.set_shader_parameter("progress", 1.0)
		_show_status("Importing A2G…")
		var efs := EditorInterface.get_resource_filesystem()
		match _import_step(efs.is_scanning(), Time.get_ticks_msec()):
			"nudge":
				efs.scan()
			"abort":
				_abort_remote("the editor did not import the material's maps")
		return
	# remote_dir is a disk check on in-plugin providers — the dest
	# folder exists the moment the download STARTS, so dir != "" alone
	# fires mid-download and the place-scan sees an empty folder. And
	# progress 1.0 also covers old/partial folders, so the finish must
	# be gated on the payload being there, like the start gate.
	if dir != "" and prog >= 1.0 and _remote_payload_ready(dir):
		_finish_remote()
		return
	var state := _remote_state_now()
	_remote_wait += 1
	if prog >= 0.0 and _ghost_mat != null:
		_ghost_mat.set_shader_parameter("progress", prog)
	var label := str(state.get("label", "Downloading A2G"))
	if label.begins_with("Downloading"):
		label = "Downloading A2G"
	_show_status(label if prog < 0.0 else "%s %d%%" % [label, int(prog * 100.0)])
	# The provider refused the start (busy elsewhere, plan-gated, …):
	# its state reports disabled while progress stays indeterminate.
	if _remote_wait > ABORT_FRAMES and prog < 0.0 \
			and not bool(state.get("enabled", true)):
		_abort_remote("provider busy — drop aborted")
	# "Finished" progress with no payload and nothing running: a folder
	# that can't satisfy this drop — bail instead of polling forever.
	elif _remote_wait > ABORT_FRAMES and prog >= 1.0:
		_abort_remote("download produced no usable files")


func _finish_remote() -> void:
	var dir := _remote_dir_now()
	if dir == "":
		_abort_remote("download produced no files")
		return
	var point := _ghost_bottom()
	match _remote_kind:
		"remote":
			_commit_remote_place(dir, point)
		"remote_assign":
			_commit_remote_assign(dir)
		"remote_terrain":
			_commit_remote_terrain(dir, point)
		"remote_hdri":
			var file := _scan_for(dir, HDRI_EXTS)
			if file.is_empty():
				_abort_remote("no HDRI file in download")
			else:
				_commit_hdri(file)
	_reset_remote()


func _abort_remote(why: String) -> void:
	push_warning("Assets2Godot drop: %s." % why)
	_reset_remote()


func _reset_remote() -> void:
	_remote = {}
	_remote_kind = ""
	_remote_target = null
	_remote_wait = 0
	_import_idle_since = 0
	_import_nudged = false
	_show_status("")
	_clear_ghost()


func _remote_dir_now() -> String:
	var cb: Variant = _remote.get("remote_dir")
	return str(cb.call()) if cb is Callable else ""


func _remote_progress_now() -> float:
	var cb: Variant = _remote.get("remote_progress")
	return float(cb.call()) if cb is Callable else -1.0


## Would _finish_remote find what it places? — the same scan the
## commit paths run, per kind. Keeps the early-exit honest: folder
## exists + progress says done, but the asset file itself missing
## means the download path gets a chance to repair.
func _remote_payload_ready(dir: String) -> bool:
	match _remote_kind:
		"remote":
			return _scan_for(dir, PLACE_EXTS) != ""
		"remote_assign":
			return _scan_material(dir) != null
		"remote_terrain":
			# A real terrain places displaced geometry — a maps-only
			# folder is no usable terrain payload. Requiring the
			# heightmap sends the drop through the repair download
			# (the bundle's EXR) instead of committing the flat plane.
			if str(_remote.get("remote_kind", "")).to_lower() == "terrain":
				return AcgTerrain.find_heightmap(dir) != ""
			return _terrain_material(dir) != null
		"remote_hdri":
			return _scan_for(dir, HDRI_EXTS) != ""
	return false


## Commits bound to an importable resource wait for the editor's
## import: a .tres whose maps aren't imported yet still loads — as a
## Material with null texture slots — and that instance stays cached
## while the mesh or the undo history holds it, so every later load
## hands the broken copy back. HDRIs get the same wait for a different
## reason: the raw-Image fallback decodes fine, but embeds a copy of
## the panorama into every saved scene (~68 MB for a 2K EXR) where the
## imported CompressedTexture2D saves as a ~1 KB reference. A fresh
## download sits in exactly that window: the provider calls scan() as
## progress reaches 1.0, the import lands frames later.
func _awaiting_import(dir: String) -> bool:
	if _remote_kind == "remote_hdri":
		return _unimported(_scan_for(dir, HDRI_EXTS))
	if _remote_kind not in ["remote_assign", "remote_terrain"]:
		return false
	var file := _scan_for(dir, MAT_EXTS)
	if file.is_empty():
		return false
	var path := ProjectSettings.localize_path(file)
	if not path.begins_with("res://"):
		return false
	for dep in ResourceLoader.get_dependencies(path):
		# "uid://…::Type::res://…" or a bare path — the path is last.
		var p: String = dep.get_slice("::", dep.get_slice_count("::") - 1)
		if _unimported(p):
			return true
	return false


## On disk but not loadable = no .import yet (exists() turns true
## once the importer's remap lands). Files outside res:// never
## import — the raw-load fallback commits them right away.
func _unimported(path: String) -> bool:
	var p := path if path.begins_with("res://") \
		else ProjectSettings.localize_path(path)
	return p.begins_with("res://") and FileAccess.file_exists(p) \
			and not ResourceLoader.exists(p)


## The import wait's clock. A running scan is progress; an editor idle
## for IMPORT_IDLE_MS with the maps still unimported gets ONE rescan —
## the provider's scan() is a no-op while another scan runs, so its
## files can miss that pass — and idle again after that rescan means
## the maps will never import.
func _import_step(scanning: bool, now: int) -> String:
	if scanning:
		_import_idle_since = 0
		return "wait"
	if _import_idle_since == 0:
		_import_idle_since = now
	if now - _import_idle_since < IMPORT_IDLE_MS:
		return "wait"
	if _import_nudged:
		return "abort"
	_import_nudged = true
	_import_idle_since = 0
	return "nudge"


func _remote_state_now() -> Dictionary:
	var cb: Variant = _remote.get("remote_state")
	if cb is Callable:
		var r: Variant = cb.call(null)
		if r is Dictionary:
			return r
	return {}


# MARK: commits — undoable via the editor's own undo/redo manager

func _commit_remote_place(dir: String, point: Vector3) -> void:
	var file := _scan_for(dir, PLACE_EXTS)
	if file.is_empty():
		_abort_remote("no placeable file in download")
		return
	var node := A2GUI.instantiate_placeable(file)
	if node == null:
		_abort_remote("could not instantiate %s" % file.get_file())
		return
	node.name = str(_remote.get("remote_title",
		file.get_file().get_basename())).validate_node_name()
	var aabb := A2GUI.world_aabb(node)
	# world_aabb works pre-tree; global_position doesn't — it lands as a
	# do-method after add_child, when the node is inside the tree.
	var at := point - Vector3(aabb.get_center().x,
		aabb.position.y, aabb.get_center().z)
	var root := EditorInterface.get_edited_scene_root()
	_commit_add(node, root, "Drop %s" % node.name, at)


func _commit_remote_assign(dir: String) -> void:
	var mat := _scan_material(dir)
	if mat == null:
		_abort_remote("no material resource in download")
		return
	if _remote_target == null:
		_abort_remote("no mesh under the drop point")
		return
	_commit_assign(mat, _remote_target)


## Map-set drops place a textured plane — a shipped .tres when the
## download has one, otherwise an ad-hoc material bound from the maps.
## A real terrain (ambientCG's own type — the only provider carrying
## heightmap EXRs) takes the heightmap path when one landed instead:
## the flat plane is the fallback for decals/atlases and for terrain
## downloads that only carry maps.
func _commit_remote_terrain(dir: String, point: Vector3) -> void:
	if str(_remote.get("remote_kind", "")).to_lower() == "terrain":
		var heightmap := AcgTerrain.find_heightmap(dir)
		if not heightmap.is_empty():
			_commit_remote_heightmap(dir, heightmap, point)
			return
	var mat := _terrain_material(dir)
	if mat == null:
		_abort_remote("no usable material or maps in download")
		return
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4.0, 4.0)
	pm.subdivide_width = 63
	pm.subdivide_depth = 63
	mi.mesh = pm
	mi.material_override = mat
	mi.name = str(_remote.get("remote_title", "Terrain")).validate_node_name()
	var root := EditorInterface.get_edited_scene_root()
	_commit_add(mi, root, "Drop %s" % mi.name, point)


## A real terrain: the EXR heightmap becomes a displaced mesh in real
## meters (extent × relief — OBJ-derived when the download carries one,
## else the terrain_* editor settings) plus a HeightMapShape3D collision
## body. The build params ride as node metadata so the node can be
## re-baked or rescaled deliberately later.
func _commit_remote_heightmap(dir: String, heightmap: String, point: Vector3) -> void:
	var heights := AcgTerrain.load_heights(heightmap)
	if heights.is_empty():
		_abort_remote("heightmap unreadable: %s" % heightmap.get_file())
		return
	var extent := AcgTerrain.extent_for(dir)
	var relief := AcgTerrain.relief_for(dir)
	var mi := MeshInstance3D.new()
	mi.mesh = AcgTerrain.build_mesh(heights, extent, relief)
	var mat := _terrain_material(dir)
	if mat is StandardMaterial3D:
		# Real displacement carries the relief — a parallax heightmap on
		# top would double it. Duplicate: the loaded .tres is a shared
		# cached resource, mutating it would dirty the file on disk.
		mat = mat.duplicate()
		mat.heightmap_enabled = false
	mi.material_override = mat
	mi.add_child(AcgTerrain.build_collision(heights, extent, relief))
	mi.name = str(_remote.get("remote_title", "Terrain")).validate_node_name()
	mi.set_meta("terrain_heightmap", heightmap)
	mi.set_meta("terrain_extent_m", extent)
	mi.set_meta("terrain_relief_m", relief)
	var root := EditorInterface.get_edited_scene_root()
	_commit_add(mi, root, "Drop %s" % mi.name, point)


func _terrain_material(dir: String) -> Material:
	var mat := _scan_material(dir)
	return mat if mat != null else _assemble_material(dir)


## Bare map sets (ambientCG terrain zips ship Color/Protrusion/… jpgs,
## no .tres) get a StandardMaterial3D bound on the fly — the same slot
## map materialize_maps uses for .tres generation.
func _assemble_material(dir: String) -> StandardMaterial3D:
	var bound := {}
	var stack := [dir]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var da := DirAccess.open(d)
		if da == null:
			continue
		da.list_dir_begin()
		var f := da.get_next()
		while not f.is_empty():
			var p := d.path_join(f)
			if da.current_is_dir():
				stack.append(p)
			elif not f.ends_with(".import"):
				var m := Conversions._map_parts(f, dir.get_file())
				var token := str(m.get("token", "")).to_lower()
				if token.begins_with("opacity") or token.begins_with("mask") \
						or token.begins_with("alpha"):
					if not bound.has("_opacity"):
						bound["_opacity"] = p
				else:
					for slot in Conversions.MAP_BINDINGS:
						if token in Conversions.MAP_BINDINGS[slot] \
								and not bound.has(slot):
							bound[slot] = p
							break
			f = da.get_next()
		da.list_dir_end()
	if bound.is_empty():
		return null
	var mat := StandardMaterial3D.new()
	if bound.has("albedo"):
		mat.albedo_texture = _load_tex(bound["albedo"])
	if bound.has("normal"):
		mat.normal_enabled = true
		mat.normal_texture = _load_tex(bound["normal"])
	if bound.has("roughness"):
		mat.roughness_texture = _load_tex(bound["roughness"])
	if bound.has("ao"):
		mat.ao_enabled = true
		mat.ao_texture = _load_tex(bound["ao"])
	if bound.has("height"):
		mat.heightmap_enabled = true
		mat.heightmap_texture = _load_tex(bound["height"])
		mat.heightmap_deep_parallax = true
	if bound.has("metallic"):
		mat.metallic = 1.0
		mat.metallic_texture = _load_tex(bound["metallic"])
	if bound.has("detail"):
		mat.detail_enabled = true
		mat.detail_albedo = _load_tex(bound["detail"])
	_apply_alpha(mat, bound)
	return mat


## Sets that never went through apply_alpha (a bare map folder dropped
## before/without materialize) still deserve transparency: the albedo's
## own alpha wins, else the set's opacity map bakes in — in-memory, the
## fallback writes no files. Same mode rule as Conversions.apply_alpha.
func _apply_alpha(mat: StandardMaterial3D, bound: Dictionary) -> void:
	var img: Image = null
	if bound.has("albedo"):
		var p := str(bound["albedo"])
		img = Image.load_from_file(p if not p.begins_with("res://") \
			else ProjectSettings.globalize_path(p))
	var mask: Image = null
	if bound.has("_opacity"):
		var p := str(bound["_opacity"])
		mask = Image.load_from_file(p if not p.begins_with("res://") \
			else ProjectSettings.globalize_path(p))
	if img != null and img.detect_alpha() == Image.ALPHA_NONE and mask != null:
		Conversions._bake_alpha(img, mask)
		mat.albedo_texture = ImageTexture.create_from_image(img)
		_scissor_or_blend(mat, Conversions._mask_mid_frac(mask))
	elif img != null:
		match img.detect_alpha():
			Image.ALPHA_BIT:
				_scissor_or_blend(mat, 0.0)
			Image.ALPHA_BLEND:
				_scissor_or_blend(mat, Conversions._alpha_mid_frac(img))


## The Conversions.apply_alpha mode rule on the live material: mostly
## binary → scissor cutout (two-sided), graded → blend for glass.
func _scissor_or_blend(mat: StandardMaterial3D, mid_frac: float) -> void:
	if mid_frac < Conversions.ALPHA_BLEND_MIN_FRAC:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


## Textures bind res://-imported when the scan already ran, raw
## Image.load otherwise — the same dual-path _load_hdri uses.
func _load_tex(path: String) -> Texture2D:
	var p := path if path.begins_with("res://") \
		else ProjectSettings.localize_path(path)
	if ResourceLoader.exists(p):
		var res := ResourceLoader.load(p)
		if res is Texture2D:
			return res
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)


## Node add + owner = one undoable action — the same shape the editor
## uses for its own FileSystem → viewport drops.
func _commit_add(node: Node, parent: Node, action: String,
		global_pos: Variant = null) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	var root := EditorInterface.get_edited_scene_root()
	ur.create_action(action)
	ur.add_do_method(parent, "add_child", node)
	if global_pos != null:
		ur.add_do_method(node, "set_global_position", global_pos)
	ur.add_do_method(self, "_own_tree", node, root)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()


## Ownership recursively — the editor serializes only owned nodes.
## Instanced nodes (scene_file_path) own their children internally:
## re-owning them into the edited scene would flatten the instance
## into loose, individually-selectable nodes.
func _own_tree(node: Node, scene_root: Node) -> void:
	node.owner = scene_root
	if not node.scene_file_path.is_empty():
		return
	for c in node.get_children():
		_own_tree(c, scene_root)


## Material onto a mesh: every surface override when the mesh has
## surfaces, material_override otherwise — a drop on the object means
## the whole object.
func _commit_assign(mat: Material, mi: MeshInstance3D) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	var count := mi.get_surface_override_material_count()
	var mat_name := mat.resource_name if not mat.resource_name.is_empty() \
		else "Material"
	ur.create_action("Assign %s" % mat_name)
	if count > 0:
		for i in count:
			ur.add_do_method(mi, "set_surface_override_material", i, mat)
			ur.add_undo_method(mi, "set_surface_override_material", i,
				mi.get_surface_override_material(i))
	else:
		ur.add_do_property(mi, "material_override", mat)
		ur.add_undo_property(mi, "material_override", mi.material_override)
	ur.commit_action()


## HDRI → scene sky: an existing WorldEnvironment keeps its Environment
## (only the sky/panorama swaps, plus background_mode if it isn't SKY);
## without one a full WorldEnvironment+Environment+Sky is added — both
## as one undoable action.
func _commit_hdri(path: String) -> void:
	var tex := _load_hdri(path)
	if tex == null:
		push_warning("Assets2Godot drop: can't load %s as a texture." % path.get_file())
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Set HDRI sky")
	var psm := PanoramaSkyMaterial.new()
	psm.panorama = tex
	var we := _find_world_env(root)
	if we == null:
		var sky := Sky.new()
		sky.sky_material = psm
		var env := Environment.new()
		env.sky = sky
		env.background_mode = Environment.BG_SKY
		we = WorldEnvironment.new()
		we.name = "WorldEnvironment"
		we.environment = env
		ur.add_do_method(root, "add_child", we)
		ur.add_do_method(self, "_own_tree", we, root)
		ur.add_do_reference(we)
		ur.add_undo_method(root, "remove_child", we)
	else:
		var env := we.environment
		if env == null:
			var sky := Sky.new()
			sky.sky_material = psm
			env = Environment.new()
			env.sky = sky
			env.background_mode = Environment.BG_SKY
			ur.add_do_property(we, "environment", env)
			ur.add_do_reference(env)
			ur.add_undo_property(we, "environment", null)
		else:
			var sky := env.sky
			if sky == null:
				sky = Sky.new()
				sky.sky_material = psm
				ur.add_do_property(env, "sky", sky)
				ur.add_do_reference(sky)
				ur.add_undo_property(env, "sky", null)
			else:
				ur.add_do_property(sky, "sky_material", psm)
				ur.add_do_reference(psm)
				ur.add_undo_property(sky, "sky_material", sky.sky_material)
			if env.background_mode != Environment.BG_SKY:
				ur.add_do_property(env, "background_mode", Environment.BG_SKY)
				ur.add_undo_property(env, "background_mode", env.background_mode)
	ur.commit_action()


func _find_world_env(root: Node) -> WorldEnvironment:
	if root is WorldEnvironment:
		return root
	for c in root.find_children("*", "WorldEnvironment", true, false):
		return c
	return null


# MARK: files & resources

## The first file of a wanted kind inside a download dir — res:// paths
## preferred (the editor's importer works on them), absolute paths as
## fallback so a download that hasn't been scanned yet still places.
func _scan_for(dir: String, exts: Array) -> String:
	var found := {}
	var stack := [dir]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var da := DirAccess.open(d)
		if da == null:
			continue
		da.list_dir_begin()
		var f := da.get_next()
		while not f.is_empty():
			var p := d.path_join(f)
			if da.current_is_dir():
				stack.append(p)
			else:
				var ext := f.get_extension().to_lower()
				if ext in exts and not f.ends_with(".part"):
					found[p] = ext
			f = da.get_next()
		da.list_dir_end()
	for ext in exts:
		for p in found:
			if found[p] == ext and p.begins_with("res://"):
				return p
		for p in found:
			if found[p] == ext:
				return p
	return ""


func _scan_material(dir: String) -> Material:
	var file := _scan_for(dir, MAT_EXTS)
	return null if file.is_empty() else _load_material(file)


func _load_material(path: String) -> Material:
	var p := path if path.begins_with("res://") \
		else ProjectSettings.localize_path(path)
	var res := ResourceLoader.load(p)
	return res if res is Material else null


func _is_material_file(path: String) -> bool:
	if not _mat_cache.has(path):
		_mat_cache[path] = ResourceLoader.load(path) is Material
	return _mat_cache[path]


## res:// loads through the importer; a just-downloaded file may not be
## imported yet — Image covers .hdr/.exr directly.
func _load_hdri(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path)
		if res is Texture2D:
			return res
	var fs := path if not path.begins_with("res://") \
		else ProjectSettings.globalize_path(path)
	var img := Image.new()
	if img.load(fs) == OK:
		return ImageTexture.create_from_image(img)
	return null


# MARK: host discovery — editor internals, duck-typed on purpose

## The 3D viewport's input surface: in Godot 4.7 a full-rect Control
## SIBLING of the SubViewportContainer (not an ancestor of the
## SubViewport), wired to the editor's _sinput via gui_input — the
## connection list is the reliable tell.
static func find_3d_surface() -> Control:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return null
	var container := vp.get_parent() as Control
	var host := container.get_parent() as Control if container else null
	if host == null:
		return null
	for c in host.get_children():
		var cc := c as Control
		if cc != null and cc != container \
				and not cc.get_signal_connection_list(&"gui_input").is_empty():
			return cc
	return null


## The FileSystem dock's file list — a Tree in details view, an
## ItemList in grid view. A remote drop there starts the provider
## download so the asset lands under Assets2Godot/<provider>; anything
## else declines and the native file drop runs.
func _find_fs_target() -> Control:
	var dock := EditorInterface.get_file_system_dock()
	if dock == null:
		return null
	for t in dock.find_children("*", "Tree", true, false):
		return t
	for l in dock.find_children("*", "ItemList", true, false):
		return l
	return null


func _exit_tree() -> void:
	_clear_ghost()
