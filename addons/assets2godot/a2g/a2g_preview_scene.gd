@tool
extends Node3D
## Root of the opt-in A2G preview stage — the settings menu's
## "Preview scene" instance and the repo's run/main_scene. Controls:
## the same two toggles live in the inspector (edited scenes don't
## run Control input) and in the runtime overlay (F5).

## Sky backdrop on/off. Ambient + reflections stay SKY-sourced, so
## hiding the panorama changes only the backdrop, not the light —
## the lookdev trick for judging a dropped HDRI's contribution.
@export var hdri_visible := true:
	set(v):
		hdri_visible = v
		_apply_sky()
## UV1 scale applied to every drop target's current material — a
## freshly dropped .tres is duplicated first so the on-disk resource
## keeps its own scale.
@export_range(0.25, 8.0, 0.25) var tiling := 1.0:
	set(v):
		tiling = v
		_apply_tiling()

## MeshInstance3D -> the duplicate we put on it (lets a later drop's
## material get its own duplicate instead of editing the shared one).
var _tiled := {}


func _ready() -> void:
	_apply_sky()
	_apply_tiling()
	if Engine.is_editor_hint():
		$PreviewUI.hide()
		return
	var ui := $PreviewUI
	ui.get_node("Panel/Margin/VBox/HdriCheck").toggled.connect(
		func(on: bool) -> void: hdri_visible = on)
	var slider: HSlider = ui.get_node(
		"Panel/Margin/VBox/TilingRow/TilingSlider")
	var val: Label = ui.get_node("Panel/Margin/VBox/TilingRow/TilingVal")
	slider.value_changed.connect(
		func(v: float) -> void:
			tiling = v
			val.text = "×%.2f" % v)


func _apply_sky() -> void:
	if not is_inside_tree():
		return
	var env: Environment = $WorldEnvironment.environment
	if env == null:
		return
	env.background_mode = Environment.BG_SKY if hdri_visible \
		else Environment.BG_COLOR
	env.background_color = Color(0.2, 0.2, 0.22)


func _apply_tiling() -> void:
	if not is_inside_tree():
		return
	_tile($Ground)
	for c in $DropTargets.get_children():
		if c is MeshInstance3D:
			_tile(c)


## Reads whichever override the node actually uses — targets carry a
## per-surface override, drops assign per-surface too, and
## material_override covers the no-surface case.
func _tile(mi: MeshInstance3D) -> void:
	var mat := mi.get_surface_override_material(0) as StandardMaterial3D
	var per_surface := mat != null
	if mat == null:
		mat = mi.material_override as StandardMaterial3D
	if mat == null:
		return
	if _tiled.get(mi) != mat:
		mat = mat.duplicate()
		if per_surface:
			mi.set_surface_override_material(0, mat)
		else:
			mi.material_override = mat
		_tiled[mi] = mat
	mat.uv1_scale = Vector3(tiling, tiling, tiling)
