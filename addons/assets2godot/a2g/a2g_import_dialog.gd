@tool
extends ConfirmationDialog
## Batch "Import into project" — stages external files into
## res://imported_assets/<name>/ (the same staging the context menu
## uses), then writes each file's .import BEFORE Godot scans it — the
## exact mechanism the editor's Import dock uses (a [remap] importer
## line plus [params] rows; the engine fills in uid/path/deps on scan).
##
## Options are a curated, per-importer set shown when every selected
## file shares one importer — mirroring what the Import dock exposes
## for that importer rather than a parallel system. Mixed selections
## fall back to per-file defaults like staging each file by hand.

signal imported(dst_paths: Array)

const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")

## Extension → importer name as the engine's .import files record it.
const IMPORTER_BY_EXT := {
	"png": "texture", "jpg": "texture", "jpeg": "texture",
	"tga": "texture", "webp": "texture", "bmp": "texture",
	"exr": "texture", "hdr": "texture", "svg": "texture",
	"tif": "texture", "tiff": "texture",
	"wav": "wav", "ogg": "oggvorbis", "mp3": "mp3",
	"gltf": "scene", "glb": "scene", "fbx": "scene", "obj": "scene",
	"dae": "scene", "usd": "scene", "usda": "scene", "usdc": "scene",
	"usdz": "scene", "blend": "scene",
}

## The curated option set per importer — the rows the Import dock shows
## for the same file type, with the engine's builtin defaults. Enums
## keep Godot's index order so the written value is the raw int.
const PARAM_SPECS := {
	"texture": [
		{"key": "compress/mode", "label": "Compress Mode", "type": "enum",
			"options": ["Lossless", "Lossy", "VRAM Compressed",
				"VRAM Uncompressed", "Basis Universal"], "default": 0,
			"hint": "VRAM Compressed / Basis Universal = the small GPU format; Lossless keeps full data."},
		{"key": "compress/high_quality", "label": "High Quality (BPTC)", "type": "bool", "default": true,
			"hint": "Only with VRAM Compressed."},
		{"key": "compress/lossy_quality", "label": "Lossy Quality", "type": "float",
			"default": 0.7, "min": 0.0, "max": 1.0, "step": 0.01,
			"hint": "Only with Lossy."},
		{"key": "mipmaps/generate", "label": "Mipmaps", "type": "bool", "default": false},
		{"key": "detect_3d/compress_to", "label": "Detect 3D → Compress To", "type": "enum",
			"options": ["Disabled", "VRAM Compressed", "Basis Universal"], "default": 1,
			"hint": "Reimports 3D-used textures VRAM+mipmaps automatically, like the editor does."},
		{"key": "process/normal_map_invert_y", "label": "Invert Y (Normal Map)", "type": "bool", "default": false},
	],
	"wav": [
		{"key": "force/mono", "label": "Force Mono", "type": "bool", "default": false},
		{"key": "force/8bit", "label": "Force 8-bit", "type": "bool", "default": false},
		{"key": "force/max_rate", "label": "Force Max Rate", "type": "bool", "default": false},
	],
	"oggvorbis": [
		{"key": "loop", "label": "Loop", "type": "bool", "default": false},
		{"key": "loop_offset", "label": "Loop Offset (s)", "type": "float",
			"default": 0.0, "min": 0.0, "max": 10000.0, "step": 0.01},
	],
	"mp3": [
		{"key": "loop", "label": "Loop", "type": "bool", "default": false},
		{"key": "loop_offset", "label": "Loop Offset (s)", "type": "float",
			"default": 0.0, "min": 0.0, "max": 10000.0, "step": 0.01},
		{"key": "bpm", "label": "BPM (0 = none)", "type": "float",
			"default": 0.0, "min": 0.0, "max": 400.0, "step": 0.1},
		{"key": "beat_count", "label": "Beat Count (0 = none)", "type": "int",
			"default": 0, "min": 0, "max": 512, "step": 1},
	],
	# The scene importer's real options are per-file and heavy — v1 lets
	# Godot defaults stand instead of faking a subset.
	"scene": [],
}

var _entries: Array = []
var _importer := ""
var _file_list: ItemList
var _summary: Label
var _opts: GridContainer
var _opts_note: Label
var _result: RichTextLabel
var _controls: Array = []


func _ready() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(8 * edscale))
	add_child(vbox)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_summary)

	_file_list = ItemList.new()
	_file_list.custom_minimum_size.y = min(160 * edscale, 400)
	_file_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_file_list)

	_opts_note = Label.new()
	_opts_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_opts_note.add_theme_color_override("font_color",
		get_theme_color("font_disabled_color", "Editor"))
	vbox.add_child(_opts_note)

	_opts = GridContainer.new()
	_opts.columns = 2
	_opts.add_theme_constant_override("h_separation", int(16 * edscale))
	_opts.add_theme_constant_override("v_separation", int(4 * edscale))
	vbox.add_child(_opts)

	_result = RichTextLabel.new()
	_result.fit_content = true
	_result.visible = false
	_result.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	vbox.add_child(_result)

	confirmed.connect(_on_confirmed)


## Opens for external-file [param entries] (the browser's selection or
## a detail popup's single entry); entries without a real OS path are
## dropped up front. Nothing pops when nothing is importable.
func open_for(entries: Array) -> void:
	_entries = []
	for e in entries:
		var p := str(e.get("path", ""))
		if p != "" and not p.begins_with("res://") and FileAccess.file_exists(p):
			_entries.append(e)
	if _entries.is_empty():
		return
	_result.text = ""
	_result.visible = false
	get_ok_button().disabled = false
	get_ok_button().text = "Import"

	title = "Import %d asset%s" % [_entries.size(), "s" if _entries.size() != 1 else ""]
	_file_list.clear()
	for e in _entries:
		var p := str(e.get("path", ""))
		var i := _file_list.add_item(p.get_file())
		_file_list.set_item_tooltip(i, A2GUI.short_path(p, 80))
	_summary.text = "%d file%s → %s/<name>/" % [_entries.size(),
		"s" if _entries.size() != 1 else "", A2GUI.STAGING_DIR]

	_importer = _uniform_importer()
	_build_options()
	popup_centered_clamped(Vector2i(560, 0))


## The importer all entries share, "" when mixed or unrecognized.
func _uniform_importer() -> String:
	var found := ""
	for e in _entries:
		var ext := str(e.get("path", "")).get_extension().to_lower()
		var imp := str(IMPORTER_BY_EXT.get(ext, ""))
		if imp == "" or (found != "" and found != imp):
			return ""
		found = imp
	return found


## One option row per curated spec; a note explains the cases where the
## engine's own defaults carry the import instead.
func _build_options() -> void:
	_controls.clear()
	for c in _opts.get_children():
		_opts.remove_child(c)
		c.queue_free()
	if _importer == "":
		_opts_note.text = "Files use different importers (or none known) — each imports with Godot's defaults."
		return
	var spec: Array = PARAM_SPECS.get(_importer, [])
	if spec.is_empty():
		_opts_note.text = "Importer: %s — this importer's options are per-file in the Import dock; Godot defaults apply." % _importer
		return
	_opts_note.text = "Importer: %s — same rows the Import dock shows for this file type." % _importer
	for p in spec:
		var key := Label.new()
		key.text = str(p["label"])
		key.tooltip_text = "%s\n%s" % [str(p["key"]), str(p.get("hint", ""))]
		key.add_theme_color_override("font_color",
			get_theme_color("font_disabled_color", "Editor"))
		_opts.add_child(key)
		var ctrl := _option_control(p)
		_opts.add_child(ctrl)
		_controls.append({"spec": p, "ctrl": ctrl})


func _option_control(p: Dictionary) -> Control:
	match str(p["type"]):
		"enum":
			var dd := OptionButton.new()
			for o in p["options"]:
				dd.add_item(str(o))
			dd.select(int(p["default"]))
			dd.tooltip_text = str(p.get("hint", ""))
			dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			return dd
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(p["default"])
			cb.tooltip_text = str(p.get("hint", ""))
			return cb
		"int", "float":
			var sb := SpinBox.new()
			sb.min_value = float(p.get("min", 0.0))
			sb.max_value = float(p.get("max", 1000.0))
			sb.step = float(p.get("step", 1.0 if p["type"] == "int" else 0.01))
			sb.value = float(p["default"])
			sb.tooltip_text = str(p.get("hint", ""))
			sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			return sb
	return Control.new()


## Control → the value .import's [params] section expects.
func _option_value(spec: Dictionary, ctrl: Control) -> Variant:
	match str(spec["type"]):
		"enum":
			return (ctrl as OptionButton).selected
		"bool":
			return (ctrl as CheckBox).button_pressed
		"int":
			return int((ctrl as SpinBox).value)
		"float":
			return (ctrl as SpinBox).value
	return null


func _collect_params() -> Dictionary:
	var params := {}
	for c in _controls:
		params[str(c["spec"]["key"])] = _option_value(c["spec"], c["ctrl"])
	return params


## [remap] importer + [params] rows — the file the engine's own import
## writes for itself on scan, completed with uid/path/deps by the
## importer exactly like a hand-edited .import.
func _write_import_file(dst: String, params: Dictionary) -> String:
	var f := FileAccess.open(ProjectSettings.globalize_path(dst + ".import"), FileAccess.WRITE)
	if f == null:
		return error_string(FileAccess.get_open_error())
	f.store_line("[remap]")
	f.store_line("")
	f.store_line("importer=\"%s\"" % _importer)
	if not params.is_empty():
		f.store_line("")
		f.store_line("[params]")
		f.store_line("")
		for key in params:
			f.store_line("%s=%s" % [key, var_to_str(params[key])])
	f.close()
	return ""


func _on_confirmed() -> void:
	var params := _collect_params()
	var write_params := _importer != "" and not params.is_empty()
	var res := A2GUI.stage_files(_entries)
	var dsts := []
	var errors: Array = res["failed"]
	for s in res["staged"]:
		var dst := str(s["dst"])
		# The .import lands before the scan so the first import already
		# carries the chosen settings — no reimport pass needed.
		if _importer != "":
			var werr := _write_import_file(dst, params if write_params else {})
			if werr != "":
				errors.append({"entry": s["entry"], "error": "wrote %s but not its .import (%s)" % [dst.get_file(), werr]})
				continue
		dsts.append(dst)
	if not dsts.is_empty():
		EditorInterface.get_resource_filesystem().scan()
		EditorInterface.get_file_system_dock().navigate_to_path(dsts[0])
		imported.emit(dsts)
	if errors.is_empty():
		hide()
		return
	# Failures stay visible — OK relabels to reflect the partial run.
	var lines := ["[b]%d imported, %d failed:[/b]" % [dsts.size(), errors.size()]]
	for er in errors:
		lines.append("• %s — %s" % [str(er["entry"].get("path", "?")).get_file(), str(er["error"])])
	_result.text = "\n".join(lines)
	_result.visible = true
	reset_size()
	popup_centered_clamped(Vector2i(560, 0))
	# Let the dialog become a status report — second confirm closes.
	get_ok_button().text = "Close"
