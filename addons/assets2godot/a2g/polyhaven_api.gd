@tool
extends RefCounted
## Pure Polyhaven API helpers: endpoint URLs, response parsing, filter/
## sort, files-tree flattening. The view does the HTTP itself — every
## function here is static and network-free.

const API_BASE := "https://api.polyhaven.com"
## Polyhaven's API terms require a unique User-Agent on EVERY request
## (https://polyhaven.com/our-api) — passed as the request headers arg.
const UA_HEADER := "User-Agent: Assets2Godot/0.7.2 (Godot editor plugin)"
## OptionButton order: [label, type_slug]. "" fetches all three types.
const TYPE_OPTIONS := [["All", ""], ["Models", "models"], ["Textures", "textures"], ["HDRIs", "hdris"]]
## Polyhaven's numeric asset types.
const TYPE_IDS := {0: "hdri", 1: "texture", 2: "model"}
## Kind → EditorIcons name shown on cards until a thumbnail arrives.
const TYPE_ICONS := {"model": "MeshInstance3D", "texture": "ImageTexture", "hdri": "ImageTexture"}
## Folder names per type under the download root — the provider's own
## taxonomy names (its /categories endpoints), not the daemon's BlendKit
## dirs (models/materials/hdrs under res://bk_assets).
const TYPE_DIRS := {"model": "models", "texture": "textures", "hdri": "hdris"}
## Preferred formats for the download dialog — the top-ranked one offers
## the suggested option. gltf imports natively, hdr for skyboxes.
const PREFERRED_FORMATS := ["gltf", "hdr", "zip", "blend", "fbx", "usd", "exr"]
## Single-map file types the /files tree lists as their own formats —
## the site's pick-one-map rows. For texture assets they regroup into
## set options ("JPG 2K" = every map at that res+ext in one download),
## like ambientCG's whole-set zips: the plugin's download is always the
## whole asset.
const MAP_FORMATS := ["diffuse", "nor_gl", "nor_dx", "rough", "ao", "disp",
	"displacement", "arm", "metal", "opacity", "bump", "nor", "spec",
	"scol", "mask", "roughmetal", "ao_rough_metal"]
## Source-material files Godot can't use — the same call ambientCG's
## extractor makes for .mtlx inside its zips.
const SKIP_FORMATS := ["mtlx"]
## Ext order inside the synthesized set rows — jpg first like ambientCG.
const SET_EXT_ORDER := ["jpg", "jpeg", "png", "exr", "hdr", "webp", "tga"]
## Resolution keys low→high for option ordering and the default pick.
const RES_ORDER := ["512", "1k", "2k", "4k", "8k", "16k", "24k"]
## Sort options like the site's own list: [id, label]. "hot" is the
## site's popularity sort — download_count is its honest client proxy.
const SORT_OPTIONS := [["Top Downloads", "hot"], ["Latest", "latest"], ["Name", "name"], ["Random", "random"]]
const THUMB_PX := 256


static func assets_url(type_slug: String) -> String:
	return "%s/assets?t=%s" % [API_BASE, type_slug]


static func categories_url(type_slug: String) -> String:
	return "%s/categories/%s" % [API_BASE, type_slug]


## The big render the site shows on the asset page — asset_img/primary,
## vs the grid's asset_img/thumbs. height=780 is the site's own size.
static func preview_url(slug: String) -> String:
	return "https://cdn.polyhaven.com/asset_img/primary/%s.png?height=780" % slug.uri_encode()


## "Greg Zaal, Jarod Guest (Sky edits)" from the {author: role} map —
## the site shows the role only when it isn't the generic "All".
static func authors_text(authors: Dictionary) -> String:
	var names := PackedStringArray()
	for name in authors:
		var role := str(authors[name])
		names.append(str(name) if role == "All" else "%s (%s)" % [name, role])
	return ", ".join(names)


## Markdown link syntax in info texts → bbcode for the RichTextLabel.
static func md_to_bbcode(text: String) -> String:
	var out := text
	var re := RegEx.create_from_string("\\[([^\\]]+)\\]\\(([^)]+)\\)")
	for m in re.search_all(out):
		out = out.replace(m.get_string(), "[url=%s]%s[/url]" % [m.get_string(2), m.get_string(1)])
	return out


static func files_url(slug: String) -> String:
	return "%s/files/%s" % [API_BASE, slug.uri_encode()]


static func web_url(slug: String) -> String:
	return "https://polyhaven.com/a/%s" % slug


## Filename for a dl.polyhaven.org URL — query/fragment stripped: a
## "?token=…" suffix is not a legal filename character on Windows.
static func file_basename(url: String) -> String:
	return url.get_file().split("?")[0].split("#")[0]


## The /assets response {slug: {...}} → a normalized asset list.
static func parse_assets(raw: Variant) -> Array:
	var out := []
	if not raw is Dictionary:
		return out
	for slug in raw:
		var a: Variant = raw[slug]
		if not a is Dictionary:
			continue
		# `_s()` not `or ""` — GDScript's `or` returns a bool, not the
		# operand, so "https://x" or "" would yield "true". And `a.get("x","y")`
		# only defaults on MISSING keys, not explicit `"x": null` the API sends.
		out.append({
			"slug": str(slug),
			"name": _s(a.get("name"), str(slug)),
			"type": str(TYPE_IDS.get(int(a.get("type", -1)), "model")),
			"categories": a.get("categories", []) if a.get("categories") is Array else [],
			"tags": a.get("tags", []) if a.get("tags") is Array else [],
			"thumbnail_url": _s(a.get("thumbnail_url")),
			"download_count": int(a.get("download_count", 0)),
			"date_published": int(a.get("date_published", 0)),
			# Detail popup fields — the /assets payload carries the site's
			# whole asset page: description, authors {name: role}, the
			# display category path, model stats and per-type attributes.
			"description": _s(a.get("description")),
			"authors": a.get("authors", {}) if a.get("authors") is Dictionary else {},
			"category": _s(a.get("category")),
			"polycount": int(a.get("polycount", 0)),
			"dimensions": a.get("dimensions", []) if a.get("dimensions") is Array else [],
			"texel_density": float(a.get("texel_density", 0.0)),
			"max_resolution": a.get("max_resolution", []) if a.get("max_resolution") is Array else [],
			"attributes": a.get("attributes", {}) if a.get("attributes") is Dictionary else {},
			# HDRI-only stats the site lists: dynamic range, white balance,
			# capture date and the shoot location on their world map.
			"evs_cap": int(a.get("evs_cap", 0)),
			"whitebalance": int(a.get("whitebalance", 0)),
			"coords": a.get("coords", []) if a.get("coords") is Array else [],
			"date_taken": int(a.get("date_taken", 0)),
			# Optional markdown note ("Edited version of [X](url)").
			"info": _s(a.get("info")),
		})
	return out


## Free-text match against name, slug, categories, tags and authors —
## the details popup's author link searches through this too.
static func matches(asset: Dictionary, text: String) -> bool:
	var t := text.strip_edges().to_lower()
	if t.is_empty():
		return true
	var hay := PackedStringArray([str(asset.get("name", "")), str(asset.get("slug", ""))])
	for v in asset.get("categories", []):
		hay.append(str(v))
	for v in asset.get("tags", []):
		hay.append(str(v))
	for v in asset.get("authors", {}):
		hay.append(str(v))
	return " ".join(hay).to_lower().contains(t)


## Site sorts: "hot" (downloads desc, name tiebreak), "latest"
## (date_published desc), "name" (A-Z), "random" (shuffled).
static func sort_assets(assets: Array, mode := "hot") -> void:
	match mode:
		"latest":
			assets.sort_custom(func(a, b):
				return int(a.get("date_published", 0)) > int(b.get("date_published", 0)))
		"name":
			assets.sort_custom(func(a, b):
				return str(a.get("name", "")) < str(b.get("name", "")))
		"random":
			assets.shuffle()
		_:
			assets.sort_custom(func(a, b):
				var ca := int(a.get("download_count", 0))
				var cb := int(b.get("download_count", 0))
				return str(a.get("name", "")) < str(b.get("name", "")) if ca == cb else ca > cb)


## Whether the asset belongs to [param cat] ("" = no filter).
static func in_category(asset: Dictionary, cat: String) -> bool:
	if cat.is_empty():
		return true
	for c in asset.get("categories", []):
		if str(c) == cat:
			return true
	return false


## Merge per-type /categories responses ({slug: count}) into one
## count-desc-sorted [[slug, count], ...] list for the dropdown.
static func merge_categories(dicts: Array) -> Array:
	var counts := {}
	for d in dicts:
		if d is Dictionary:
			for k in d:
				if str(k) == "all":
					continue
				counts[str(k)] = int(counts.get(k, 0)) + int(d[k])
	var out := []
	for k in counts:
		out.append([str(k), counts[k]])
	out.sort_custom(func(a, b): return a[0] < b[0] if a[1] == b[1] else a[1] > b[1])
	return out


## Display name for a category slug: the "collection: " prefix becomes a
## "(collection)" suffix — the site shows those in Vaults, not Categories.
static func category_label(slug: String) -> String:
	var s := slug
	var suffix := ""
	if s.begins_with("collection: "):
		s = s.substr(12)
		suffix = " (collection)"
	return s.capitalize() + suffix


static func _res_rank(res: String) -> int:
	var i := RES_ORDER.find(res.to_lower())
	return i if i >= 0 else 50


## The /files tree {format: {res: {ext: {url,size,include?}}}} → a flat
## option list [{key,label,url,size,total_size,includes:{relpath:url}}],
## sorted by preferred format then ascending resolution. `include` holds
## the companion files an entry needs (gltf's .bin + textures/, blend's
## textures/) — each maps its relative path to a dl.polyhaven.org URL.
static func flatten_files(tree: Variant) -> Array:
	var out := []
	if not tree is Dictionary:
		return out
	for fmt in tree:
		if not tree[fmt] is Dictionary:
			continue
		for res in tree[fmt]:
			if not tree[fmt][res] is Dictionary:
				continue
			for ext in tree[fmt][res]:
				var e: Variant = tree[fmt][res][ext]
				if not e is Dictionary or not e.has("url"):
					continue
				var includes := {}
				var total := int(e.get("size", 0))
				var inc: Variant = e.get("include", {})
				if inc is Dictionary:
					for rel in inc:
						var ie: Variant = inc[rel]
						if not ie is Dictionary or not ie.has("url"):
							continue
						# The relative path is remote data that becomes a
						# local path — refuse anything escaping the folder.
						var relpath := str(rel).replace("\\", "/")
						if relpath.begins_with("/") or ".." in relpath.split("/"):
							continue
						includes[relpath] = str(ie["url"])
						total += int(ie.get("size", 0))
				var fi := PREFERRED_FORMATS.find(str(fmt).to_lower())
				out.append({
					"key": "%s/%s/%s" % [fmt, res, ext],
					"label": "%s %s (%s)" % [str(fmt).to_upper(), res, short_size(total)],
					"url": str(e["url"]),
					"size": int(e.get("size", 0)),
					"total_size": total,
					"includes": includes,
					"_rank": [fi if fi >= 0 else 99, _res_rank(str(res))],
				})
	# Single maps regroup into whole-set options like ambientCG's zips:
	# "JPG 2K" downloads every map at that res+ext (primary + includes).
	var sets := {}
	for o in out:
		var parts := str(o.get("key", "")).split("/")
		if parts.size() < 3 or parts[0].to_lower() not in MAP_FORMATS:
			continue
		var k := "%s/%s" % [parts[1], parts[2].to_lower()]
		if not sets.has(k):
			sets[k] = []
		sets[k].append(o)
	out = out.filter(func(o):
		var fmt := str(o.get("key", "")).split("/")[0].to_lower()
		return fmt not in MAP_FORMATS and fmt not in SKIP_FORMATS)
	for k in sets:
		var group: Array = sets[k]
		var first: Dictionary = group[0]
		var inc := {}
		var total := int(first.get("size", 0))
		for o in group.slice(1):
			var rel := file_basename(str(o.get("url", "")))
			if rel.is_empty() or inc.has(rel):
				continue
			inc[rel] = str(o.get("url", ""))
			total += int(o.get("size", 0))
		var parts := str(k).split("/")
		out.append({
			"key": "set/%s" % k,
			"label": "%s %s (%s)" % [parts[1].to_upper(), parts[0].to_upper(),
				short_size(total)],
			"url": str(first.get("url", "")),
			"size": int(first.get("size", 0)),
			"total_size": total,
			"includes": inc,
			"_rank": [-1, _res_rank(parts[0]), SET_EXT_ORDER.find(parts[1])],
		})
	out.sort_custom(func(a, b): return a._rank < b._rank)
	for o in out:
		o.erase("_rank")
	return out


## Index of the suggested download option: the top-ranked format nearest
## [param res_hint], else the first option. -1 on an empty list.
static func pick_default(options: Array, res_hint := "2k") -> int:
	if options.is_empty():
		return -1
	var fmt := str(options[0].get("key", "")).split("/")[0]
	var hint_rank := RES_ORDER.find(res_hint)
	var best := -1
	var best_d := 1 << 30
	for i in options.size():
		var parts := str(options[i].get("key", "")).split("/")
		if parts.size() < 2 or parts[0] != fmt:
			break # past the preferred format's block
		var d := 50
		if RES_ORDER.has(parts[1]) and hint_rank >= 0:
			d = absi(RES_ORDER.find(parts[1]) - hint_rank)
		if d < best_d:
			best_d = d
			best = i
	return best if best >= 0 else 0


## String guard for API fields that arrive as explicit null — str(v)
## for present values, [param fallback] otherwise.
static func _s(v: Variant, fallback := "") -> String:
	return fallback if v == null else str(v)


static func short_size(bytes: int) -> String:
	for unit in [[1073741824, "GB"], [1048576, "MB"], [1024, "kB"]]:
		if bytes >= unit[0]:
			return "%.*f %s" % [1, bytes / float(unit[0]), unit[1]]
	return "%d B" % bytes
