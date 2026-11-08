@tool
extends RefCounted
## Conversions of downloads Godot can't use as they are. Before a download
## moves into the project, Blender converts it in its staging folder into
## a form Godot reads: an EXR it can't read is re-saved under the same name,
## and a material .blend becomes a Godot material with its textures. Without
## Blender, or when it fails, the file moves as it is.
##
## Conversions run whenever there's a Blender, so they have no setting: what
## they replace is of no use in Godot.

const BlenderImport = preload("res://addons/assets2godot/blender_import.gd")
const FileOps = preload("res://addons/assets2godot/file_ops.gd")

## Blender runs it with {input_path, output_path, alpha}.
const RESAVE_EXR_SCRIPT := "res://addons/assets2godot/blender/resave_exr.py"
## Blender runs it with {input_path, output_path, textures_dir}.
const MATERIAL_SCRIPT := "res://addons/assets2godot/blender/material_to_godot.py"
## The download folder of materials, see GalleryApi.plural_asset_type().
const MATERIALS_DIR := "materials"
const EXR_MAGIC := 20000630
## Version flags of multi-part and deep data files, which aren't converted.
const EXR_MULTIPART_OR_DEEP := 0x1800
## Compressions Godot's EXR loader (tinyexr) reads: none, RLE, ZIPS, ZIP and
## PIZ. It fails on the others, e.g. the lossy DWAA of Blendkit's HDRs.
const EXR_READABLE_COMPRESSIONS := [0, 1, 2, 3, 4]
## Header attributes are read up to this size, to bail out of broken files.
const EXR_MAX_ATTRIBUTE := 1 << 16
const MESSAGE := "Converting for Godot"
## A conversion still running after this long gives up on it — the file
## stays as it is, like a failed one. Downloads keeps its own budget too.
const CONVERSION_TIMEOUT_MS := 5 * 60 * 1000

## The Blender found on this computer, "" for none, null before looking.
static var _detected: Variant = null
static var _detecting := false


## How to make the file at [param path] of use in Godot: {script, params,
## file, dirs}, or {} when Godot imports it as it is. The script writes
## params.output_path, which becomes [code]file[/code]: the file the download
## is then, at [param path] when the conversion replaces it. [code]dirs[/code]
## are folders the script writes too.
static func plan(path: String) -> Dictionary:
	match path.get_extension().to_lower():
		"exr":
			var header := exr_header(path)
			if header.is_empty() or header.compression in EXR_READABLE_COMPRESSIONS:
				return {}
			return {"script": RESAVE_EXR_SCRIPT, "params": {"input_path": path,
				"output_path": output_path(path), "alpha": header.alpha}, "file": path, "dirs": []}
		"blend":
			if path.get_base_dir().get_base_dir().get_file() != MATERIALS_DIR:
				return {}
			# A .tres next to the .blend is already the converted material
			# — providers that ship Godot-ready files (ambientCG) keep theirs.
			if FileAccess.file_exists(path.get_basename() + ".tres"):
				return {}
			var material := path.get_basename() + ".tres"
			var textures := path.get_base_dir().path_join(textures_dir_name(path))
			return {"script": MATERIAL_SCRIPT, "params": {"input_path": path,
				"output_path": material, "textures_dir": textures}, "file": material, "dirs": [textures]}
	return {}


## The converted file next to [param path], e.g. sky.godot.exr for sky.exr.
static func output_path(path: String) -> String:
	return "%s.godot.%s" % [path.get_basename(), path.get_extension()]


## The folder for the textures of a material converted from the file at
## [param path], named after its resolution so that the materials of each
## stay apart in the asset folder: textures_2K for
## wood_2K_<file id>.blend, textures for wood_<file id>.blend.
static func textures_dir_name(path: String) -> String:
	var name := path.get_file().get_basename()
	var first := name.find("_")
	var last := name.rfind("_")
	if first < 0 or last <= first:
		return "textures"
	return "textures_" + name.substr(first + 1, last - first - 1)


## The compression code and whether there's an alpha channel, from the
## header of a single-part OpenEXR file. {} for other and broken files.
static func exr_header(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() < 8 or file.get_32() != EXR_MAGIC:
		return {}
	if file.get_32() & EXR_MULTIPART_OR_DEEP:
		return {}
	var result := {"compression": -1, "alpha": false}
	while true:
		var attribute := _read_name(file)
		if attribute.is_empty():
			break # end of the header, or broken
		_read_name(file) # type
		var size := file.get_32()
		if file.eof_reached() or size > EXR_MAX_ATTRIBUTE:
			return {}
		var end := file.get_position() + size
		match attribute:
			"compression":
				result.compression = file.get_8()
			"channels":
				# name, then pixel type, linear, reserved and sampling
				var channel := _read_name(file)
				while not channel.is_empty() and file.get_position() < end:
					if channel == "A":
						result.alpha = true
					file.get_buffer(16)
					channel = _read_name(file)
		file.seek(end)
	return result if result.compression >= 0 else {}


## A null-terminated name of at most 255 bytes, "" at its end or the file's.
static func _read_name(file: FileAccess) -> String:
	var bytes := PackedByteArray()
	while bytes.size() < 256:
		var byte := file.get_8()
		if byte == 0 or file.eof_reached():
			return bytes.get_string_from_utf8()
		bytes.append(byte)
	return ""


## The Blender to convert with: Godot's Blender for .blend import, else the
## newest one found on this computer, else "" to let the Client use one
## another plugin told it about. Finding one runs each candidate, so it's
## done once per editor session, on a thread.
static func blender_path() -> String:
	var path := BlenderImport.blender_path()
	if not path.is_empty() and FileAccess.file_exists(path):
		return path
	var tree := Engine.get_main_loop() as SceneTree
	while _detecting:
		await tree.process_frame
	if _detected == null:
		_detecting = true
		var found: Array[Dictionary] = []
		var task := WorkerThreadPool.add_task(func(): found.append_array(BlenderImport.detect()))
		while not WorkerThreadPool.is_task_completed(task):
			await tree.process_frame
		WorkerThreadPool.wait_for_task_completion(task)
		_detected = found[0].path if not found.is_empty() else ""
		_detecting = false
	return _detected


## Look for a Blender again next time, e.g. after one was installed. A
## detection running meanwhile still answers those waiting for it.
static func forget_detected() -> void:
	if not _detecting:
		_detected = null


# MARK: post-download pass — providers whose downloads land in place

## Every file under [param dir] that needs converting for Godot, as
## [{path, plan}] for each non-empty plan(). Cheap: only .exr files cost
## a header read. Skips dot-folders.
static func collect(dir: String) -> Array:
	var jobs := []
	if not DirAccess.dir_exists_absolute(dir):
		return jobs
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			jobs.append_array(collect(dir.path_join(sub)))
	for file in DirAccess.get_files_at(dir):
		var p := dir.path_join(file)
		var p_plan := plan(p)
		if not p_plan.is_empty():
			jobs.append({"path": p, "plan": p_plan})
	return jobs


## Run one plan() with the Blender at [param blender], like the Client's
## run_blender_script does — headless --factory-startup, params as the
## JSON file of the last arg, success measured by params.output_path
## existing. Then apply the result the way Downloads._convert() does: an
## output that replaces its input swaps in place (a resaved EXR keeps the
## name), a new file deletes the now-useless input (the .blend a .tres
## made of). Sync and blocking — caller picks the thread, see
## convert_dir(). Returns {ok, file?, error?, output}.
static func run(plan: Dictionary, blender: String) -> Dictionary:
	var source: String = plan.params.input_path
	var output: String = plan.params.output_path
	var replaces: bool = plan.file == source
	if blender.is_empty() or not FileAccess.file_exists(blender):
		return {"ok": false, "error": "Blender not found"}
	DirAccess.remove_absolute(output)
	for dir_path in plan.dirs:
		FileOps.remove_dir(dir_path)
	var params_path := OS.get_temp_dir().path_join(
		"a2g-convert-%d.json" % Time.get_ticks_usec())
	var pf := FileAccess.open(params_path, FileAccess.WRITE)
	if pf == null:
		return {"ok": false, "error": "could not write %s" % params_path}
	# The JSON feeds a subprocess — Blender can't read res://, so paths
	# globalize at this boundary (the Godot-side checks above still use
	# the caller's path form, res:// included).
	var sub_params: Dictionary = plan.params.duplicate()
	for key in ["input_path", "output_path", "textures_dir"]:
		var v := str(sub_params.get(key, ""))
		if not v.is_empty():
			sub_params[key] = ProjectSettings.globalize_path(v)
	pf.store_string(JSON.stringify(sub_params))
	pf.close()
	var stdout := []
	var code := OS.execute(blender, ["--background", "--factory-startup",
		"--python", ProjectSettings.globalize_path(plan.script),
		"--", params_path], stdout, true)
	DirAccess.remove_absolute(params_path)
	var size := -1
	var of := FileAccess.open(output, FileAccess.READ)
	if of != null:
		size = of.get_length()
		of = null
	var error := ""
	if code != 0:
		error = "Blender exited %d" % code
	elif size <= 0:
		error = "script produced no output"
	elif replaces and not FileOps.replace_file(output, source):
		error = "could not replace it with the converted file"
	if error.is_empty():
		if not replaces:
			DirAccess.remove_absolute(source)
		return {"ok": true, "file": plan.file}
	DirAccess.remove_absolute(output)
	for dir_path in plan.dirs:
		FileOps.remove_dir(dir_path)
	return {"ok": false, "error": error,
		"output": "\n".join(PackedStringArray(stdout)).right(-4000)}


## blender_path()'s sync half for callers that can't await, like the
## provider-download test suite: the configured Blender, else detect()
## on this very thread — it starts each candidate, so it takes a moment.
static func blender_path_now() -> String:
	var path := BlenderImport.blender_path()
	if not path.is_empty() and FileAccess.file_exists(path):
		return path
	if _detected == null:
		var found: Array[Dictionary] = BlenderImport.detect()
		_detected = found[0].path if not found.is_empty() else ""
	return str(_detected)


## Convert every file under [param dir] that needs it — the post-download
## pass for providers whose downloads land in place instead of staged
## through the Client. Each plan() runs sequentially on a worker thread
## (run() blocks), bounded at CONVERSION_TIMEOUT_MS per file. A second
## collect() pass catches files a conversion wrote that themselves need
## one, e.g. textures a material .tres conversion copies. Returns
## {converted, failed, reason}: reason is "no blender" when nothing ran.
static func convert_dir(dir: String) -> Dictionary:
	var result := {"converted": 0, "failed": [], "reason": ""}
	if collect(dir).is_empty():
		return result
	var blender := await blender_path()
	if blender.is_empty():
		result["reason"] = "no blender"
		return result
	var tree := Engine.get_main_loop() as SceneTree
	for _pass in 2:
		var jobs := collect(dir)
		if jobs.is_empty():
			break
		for job in jobs:
			var p: Dictionary = job.get("plan", {})
			var outcome := []
			var task := WorkerThreadPool.add_task(func(): outcome.append(run(p, blender)))
			var deadline := Time.get_ticks_msec() + CONVERSION_TIMEOUT_MS
			while not WorkerThreadPool.is_task_completed(task) \
					and Time.get_ticks_msec() < deadline:
				await tree.process_frame
			# A timed-out run keeps working orphaned — its output still
			# lands, a next collect() just sees the file as converted.
			var r: Dictionary = outcome[0] if not outcome.is_empty() \
				else {"ok": false, "error": "Blender took too long"}
			if r.get("ok", false):
				result["converted"] += 1
			else:
				result["failed"].append({"path": str(job.get("path", "")),
					"error": str(r.get("error", "failed"))})
	return result


## Write a keep-import marker for every .blend under [param dir] that has
## none: the file the provider delivered stays, but the editor must not
## feed it to the .blend import bridge on the next filesystem scan —
## BlendKit never ships a .blend into the project either (its conversion
## consumes it). Converted .blends are already gone by then, so only the
## survivors get marked: provider-shipped .blends that plan() left alone.
static func keep_unimported(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			keep_unimported(dir.path_join(sub))
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() != "blend":
			continue
		var marker := dir.path_join(file + ".import")
		if FileAccess.file_exists(marker):
			continue
		var f := FileAccess.open(marker, FileAccess.WRITE)
		if f:
			f.store_string("[remap]\n\nimporter=\"keep\"\ntype=\"keep\"\n")
			f = null


## Reorganize a provider material folder into BlendKit's download layout:
## each <stem>.tres stays at the top while its <stem>_* texture maps move
## into textures_<res>/, <res> being the stem's resolution tag — the part
## after the first "_", format suffix cut (Marble012_1K-PNG → textures_1K,
## matching BlendKit's textures_2K). The .tres's relative ext_resource
## paths are rewritten to the new locations, .import files move along.
## Providers ship flat folders; BlendKit separates maps, and the same
## layout keeps the providers' materials folders reading alike.
static func organize_materials(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for subdir in DirAccess.get_directories_at(dir):
		if not subdir.begins_with("."):
			organize_materials(dir.path_join(subdir))
	var stems := []
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() == "tres":
			stems.append(file.get_basename())
	var moved := {}
	for stem in stems:
		var tag: String = stem.substr(stem.find("_") + 1) if "_" in stem else ""
		var sub: String = "textures_" + tag.get_slice("-", 0) if tag else "textures"
		for file in DirAccess.get_files_at(dir):
			if file.begins_with(stem + "_") and _is_texture_file(file):
				moved[file] = sub
	if moved.is_empty():
		return
	for file in moved:
		var sub: String = moved[file]
		DirAccess.make_dir_recursive_absolute(dir.path_join(sub))
		DirAccess.rename_absolute(dir.path_join(file),
			dir.path_join(sub).path_join(file))
	for stem in stems:
		var tres := dir.path_join(stem + ".tres")
		var text := FileAccess.get_file_as_string(tres)
		if text.is_empty():
			continue
		for file in moved:
			var target: String = moved[file].path_join(file)
			text = text.replace("path=\"./%s\"" % file, "path=\"./%s\"" % target)
			text = text.replace("path=\"%s\"" % file, "path=\"%s\"" % target)
		var f := FileAccess.open(tres, FileAccess.WRITE)
		if f:
			f.store_string(text)
			f = null


## Whether [param file] is a texture map or its .import sidecar — the
## image extensions a material folder can carry.
static func _is_texture_file(file: String) -> bool:
	var ext := file.get_extension().to_lower()
	if ext == "import":
		ext = file.get_basename().get_extension().to_lower()
	return ext in ["png", "jpg", "jpeg", "exr", "hdr", "webp", "tga", "tif", "bmp"]


## Map-type suffix → the material slot it binds — providers suffix maps
## by type (plywood_diff_1k.png). nor_dx needs a Y-flip Godot can't do,
## so the GL variant binds and dx just moves along in the set.
const MAP_BINDINGS := {
	"albedo": ["diff", "diffuse", "basecolor", "col", "albedo"],
	"normal": ["nor_gl", "nor", "normal"],
	"roughness": ["rough", "roughness"],
	"ao": ["ao", "occlusion"],
	"height": ["disp", "displacement", "height"],
	"metallic": ["metal", "metallic"],
	"orm": ["arm", "orm"],
}


## Turn a bare map-set folder (what a "JPG 2K" Polyhaven download lands
## as) into BlendKit's material shape: every map moves into
## textures_<RES>/ and a StandardMaterial3D <slug>_<RES>.tres binds
## them — the same .tres ambientCG ships, built here. Dirs that already
## hold a .tres belong to organize_materials and are skipped, dirs with
## no bindable maps are left alone.
static func materialize_maps(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for subdir in DirAccess.get_directories_at(dir):
		if not subdir.begins_with("."):
			materialize_maps(dir.path_join(subdir))
	var slug := dir.get_file()
	var groups := {} # res → [{file, token}]
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() == "tres":
			return
		var m := _map_parts(file, slug)
		if m.is_empty():
			continue
		if not groups.has(m["res"]):
			groups[m["res"]] = []
		groups[m["res"]].append({"file": file, "token": m["token"]})
	for res in groups:
		var bound := {}
		for e in groups[res]:
			for slot in MAP_BINDINGS:
				if str(e["token"]).to_lower() in MAP_BINDINGS[slot]:
					if not bound.has(slot):
						bound[slot] = str(e["file"])
					break
		if not (bound.has("albedo") or bound.has("normal") or bound.has("orm")):
			continue
		var res_tag := str(res).to_upper()
		var sub := "textures_" + res_tag
		DirAccess.make_dir_recursive_absolute(dir.path_join(sub))
		for e in groups[res]:
			DirAccess.rename_absolute(dir.path_join(str(e["file"])),
				dir.path_join(sub).path_join(str(e["file"])))
		_write_material_tres(dir.path_join("%s_%s.tres" % [slug, res_tag]),
			sub, bound)


## "<slug>_<type>_<res>.<img>" → {res, token}: the trailing _<digits>k?
## is the resolution, what sits between slug_ and it is the map type.
## {} for anything that isn't a map — previews (<slug>.png) included.
static func _map_parts(file: String, slug: String) -> Dictionary:
	if not _is_texture_file(file):
		return {}
	var bn := file.get_basename()
	if bn.get_extension().to_lower() in ["png", "jpg", "jpeg", "exr", "hdr",
			"webp", "tga", "tif", "bmp"]:
		bn = bn.get_basename() # .import sidecar — peel twice
	var parts := bn.split("_")
	if parts.size() < 2:
		return {}
	var res := str(parts[parts.size() - 1])
	if not res.to_lower().trim_suffix("k").is_valid_int():
		return {}
	var rest := "_".join(parts.slice(0, parts.size() - 1))
	var token := rest.substr(slug.length() + 1) \
		if rest.begins_with(slug + "_") else rest
	if token.is_empty() or token == slug:
		return {}
	return {"res": res, "token": token}


## The material text — same shape ambientCG ships: relative ext_resource
## paths into textures_<RES>/, an ORM map replaces the ao/rough/metal
## slots it packs.
static func _write_material_tres(path: String, sub: String, bound: Dictionary) -> void:
	var ids := []
	for slot in MAP_BINDINGS:
		if bound.has(slot) and not (
				slot in ["ao", "roughness", "metallic"] and bound.has("orm")):
			ids.append(slot) # orm-packed slots stay undeclared
	var lines := PackedStringArray([
		"[gd_resource type=\"StandardMaterial3D\" load_steps=%d format=3]" \
			% (ids.size() + 1), ""])
	for slot in ids:
		lines.append("[ext_resource type=\"Texture2D\" id=\"%s\" path=\"./%s/%s\"]" \
			% [slot, sub, bound[slot]])
	lines.append("[resource]")
	var props := {
		"albedo": ["albedo_texture = ExtResource(\"albedo\")"],
		"normal": ["normal_enabled = true", "normal_texture = ExtResource(\"normal\")"],
		"roughness": ["roughness_texture = ExtResource(\"roughness\")",
			"roughness_texture_channel = 4"],
		"ao": ["ao_enabled = true", "ao_texture = ExtResource(\"ao\")"],
		"height": ["heightmap_enabled = true",
			"heightmap_texture = ExtResource(\"height\")", "heightmap_scale = 1.0"],
		"metallic": ["metallic_texture = ExtResource(\"metallic\")"],
		"orm": ["orm_texture = ExtResource(\"orm\")"],
	}
	for slot in ids:
		for p in props[slot]:
			lines.append(p)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines) + "\n")
		f = null

