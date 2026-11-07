@tool
extends RefCounted
## Pure Polyhaven API helpers: endpoint URLs, response parsing, filter/
## sort, files-tree flattening. The view does the HTTP itself — every
## function here is static and network-free.

const API_BASE := "https://api.polyhaven.com"
## OptionButton order: [label, type_slug]. "" fetches all three types.
const TYPE_OPTIONS := [["All", ""], ["Models", "models"], ["Textures", "textures"], ["HDRIs", "hdris"]]
## Polyhaven's numeric asset types.
const TYPE_IDS := {0: "hdri", 1: "texture", 2: "model"}
## Kind → EditorIcons name shown on cards until a thumbnail arrives.
const TYPE_ICONS := {"model": "MeshInstance3D", "texture": "ImageTexture", "hdri": "ImageTexture"}
## Folder names per type under the download dir — the daemon's own plural
## type dirs, so Polyhaven files sit next to BlendKit's.
const TYPE_DIRS := {"model": "models", "texture": "textures", "hdri": "hdris"}
## Preferred formats for the download dialog — the top-ranked one offers
## the suggested option. gltf imports natively, hdr for skyboxes.
const PREFERRED_FORMATS := ["gltf", "hdr", "zip", "blend", "fbx", "usd", "exr"]
## Resolution keys low→high for option ordering and the default pick.
const RES_ORDER := ["512", "1k", "2k", "4k", "8k", "16k", "24k"]
## Sort options like the site's own list: [id, label]. "hot" is the
## site's popularity sort — download_count is its honest client proxy.
const SORT_OPTIONS := [["hot", "Top Downloads"], ["latest", "Latest"], ["name", "Name"], ["random", "Random"]]
const THUMB_PX := 256


static func assets_url(type_slug: String) -> String:
	return "%s/assets?t=%s" % [API_BASE, type_slug]


static func categories_url(type_slug: String) -> String:
	return "%s/categories/%s" % [API_BASE, type_slug]


static func files_url(slug: String) -> String:
	return "%s/files/%s" % [API_BASE, slug.uri_encode()]


static func web_url(slug: String) -> String:
	return "https://polyhaven.com/a/%s" % slug


## Filename for a dl.polyhaven.org URL.
static func file_basename(url: String) -> String:
	return url.get_file()


## The /assets response {slug: {...}} → a normalized asset list.
static func parse_assets(raw: Variant) -> Array:
	var out := []
	if not raw is Dictionary:
		return out
	for slug in raw:
		var a: Variant = raw[slug]
		if not a is Dictionary:
			continue
		out.append({
			"slug": str(slug),
			"name": str(a.get("name", slug)),
			"type": str(TYPE_IDS.get(int(a.get("type", -1)), "model")),
			"categories": a.get("categories", []),
			"tags": a.get("tags", []),
			"thumbnail_url": str(a.get("thumbnail_url", "")),
			"download_count": int(a.get("download_count", 0)),
			"date_published": int(a.get("date_published", 0)),
		})
	return out


## Free-text match against name, slug, categories and tags.
static func matches(asset: Dictionary, text: String) -> bool:
	var t := text.strip_edges().to_lower()
	if t.is_empty():
		return true
	var hay := PackedStringArray([str(asset.get("name", "")), str(asset.get("slug", ""))])
	for v in asset.get("categories", []):
		hay.append(str(v))
	for v in asset.get("tags", []):
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
						if ie is Dictionary and ie.has("url"):
							includes[str(rel)] = str(ie["url"])
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


static func short_size(bytes: int) -> String:
	for unit in [[1073741824, "GB"], [1048576, "MB"], [1024, "kB"]]:
		if bytes >= unit[0]:
			return "%.*f %s" % [1, bytes / float(unit[0]), unit[1]]
	return "%d B" % bytes
