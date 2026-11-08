@tool
extends RefCounted
## Pure ambientCG API helpers: endpoint URLs, response parsing, filter/
## sort, download-list flattening. The view does the HTTP itself — every
## function here is static and network-free.
##
## Recon notes (docs.ambientcg.com/api/v3, verified live):
## - GET https://ambientcg.com/api/v3/assets — offset-paginated catalog
##   ({totalResults, nextPageHttp, assets:[...]}, limit ≤ 500). Params
##   mirror the site's /list page: type, category, technique, q, sort,
##   id, date, include. `category` filters server-side — assets carry no
##   per-asset category field, so the category dropdown must refetch.
## - /api/v3/categories → [{id, title, type, numberOfAssets}], all types.
## - Downloads ride inside the asset as `downloads` — the per-asset
##   "files" fetch is `?id=<id>&include=downloads`.
## - Download URLs (ambientcg.com/get?file=) answer 302 → the
##   acg-download CDN; Godot's HTTPRequest does not follow redirects.
## - `extension` "zip" entries are flat archives (PBR maps + .tres/.blend/
##   .usdc + preview png) — they need an extract step; sbsar/obj/exr are
##   plain files.
## - Every asset is CC0 (docs.ambientcg.com/license); the logo may be used
##   to reference ambientCG without implying endorsement (docs /brand).
## - No User-Agent is required by the API docs, but every request still
##   carries the plugin's identifying UA as good API citizenship.

const API_BASE := "https://ambientcg.com/api/v3"
const UA_HEADER := "User-Agent: Assets2Godot/0.7.2 (Godot editor plugin)"
## The include list the catalog pages fetch — everything the grid and the
## details popup need; `downloads` stays lazy (per-asset ?id= fetch).
const CATALOG_INCLUDE := "type,title,url,releaseDate,shortDescription,longDescription," \
	+ "tags,colors,dimensions,downloadStatistics,maps,technique,collections,thumbnails"
## API limit cap — pages of this size until offset reaches totalResults.
const PAGE_SIZE := 500
## OptionButton order: [label, type_slug] — the site's own vocabulary,
## "" fetches every type.
const TYPE_OPTIONS := [["All", ""], ["Materials", "material"], ["HDRIs", "hdri"],
	["Substances", "substance"], ["Decals", "decal"], ["Atlases", "atlas"],
	["3D Models", "3d-model"], ["Plain Images", "plain-image"], ["Brushes", "brush"],
	["Terrains", "terrain"], ["HDRI Elements", "hdri-element"]]
## Display names per type (the site's own casing: "ambientCG", "HDRI").
const TYPE_LABELS := {"material": "Material", "hdri": "HDRI", "substance": "Substance",
	"decal": "Decal", "atlas": "Atlas", "3d-model": "3D Model",
	"plain-image": "Plain Image", "brush": "Brush", "terrain": "Terrain",
	"hdri-element": "HDRI Element"}
## Folder names per type under the download root — pluralized from the
## provider's taxonomy slugs.
const TYPE_DIRS := {"material": "materials", "hdri": "hdris", "substance": "substances",
	"decal": "decals", "atlas": "atlases", "3d-model": "3d-models",
	"plain-image": "plain-images", "brush": "brushes", "terrain": "terrains",
	"hdri-element": "hdri-elements"}
## Kind → EditorIcons name shown on cards until a thumbnail arrives.
const TYPE_ICONS := {"3d-model": "MeshInstance3D", "terrain": "MeshInstance3D",
	"hdri": "WorldEnvironment", "hdri-element": "WorldEnvironment"}
## Download-format preference for the picker order and default: jpg map
## packs first (smaller, complete PBR set), then png, then the raw files
## (sbsar/exr/obj — the only formats of their types anyway), bare zips
## last. Within a format: ascending resolution, SQ before LQ, stills
## before ANIMATED decal variants.
const FMT_ORDER := ["jpg", "png", "sbsar", "exr", "obj", "zip"]
const RES_ORDER := ["512", "1k", "2k", "4k", "8k", "12k", "16k", "24k"]
const QUAL_ORDER := ["SQ", "LQ"]
## Sort options like the site's own /list dropdown: [label, key]. The API
## sorts server-side; we mirror client-side over the fetched subset —
## "popular" is the site's weighted blend, downloadStatistics.lastMonth
## is its honest client proxy.
const SORT_OPTIONS := [["Popular", "popular"], ["Downloads", "downloads"],
	["Latest", "latest"], ["Oldest", "oldest"], ["Alphabet", "alphabet"],
	["Random", "random"]]
const THUMB_KEY := "256-WEBP"   # grid card thumb (webp, smallest)
const PREVIEW_KEY := "1024-PNG" # details popup render
const THUMB_PX := 256


## One catalog page: assets + the include set above. `type`/`category`
## are the API's own slugs ("" = unfiltered); paging is offset-based —
## nextPageHttp is just limit+offset arithmetic.
static func assets_url(type_slug: String, category := "", offset := 0, limit := PAGE_SIZE) -> String:
	var q := "sort=popular&limit=%d&offset=%d&include=%s" % [limit, offset, CATALOG_INCLUDE.uri_encode()]
	if type_slug != "":
		q += "&type=%s" % type_slug.uri_encode()
	if category != "":
		q += "&category=%s" % category.uri_encode()
	return "%s/assets?%s" % [API_BASE, q]


static func categories_url() -> String:
	return "%s/categories" % API_BASE


## The per-asset downloads fetch — `?id=` selects by the asset's own id.
static func files_url(slug: String) -> String:
	return "%s/assets?id=%s&include=downloads" % [API_BASE, slug.uri_encode()]


## The site's canonical short URL — same as the payload's `url` field.
static func web_url(slug: String) -> String:
	return "https://ambientcg.com/a/%s" % slug.uri_encode()


## Filename for a download URL: the real name lives in the `?file=` query
## param (ambientcg.com/get?file=<name>.zip), so url.get_file() alone
## would wrongly answer "get".
static func file_basename(url: String) -> String:
	var clean := url.split("#")[0]
	var query := clean.get_slice("?", 1)
	for p in query.split("&"):
		if p.get_slice("=", 0) == "file":
			return p.get_slice("=", 1).uri_decode().get_file()
	return clean.split("?")[0].get_file()


## Card thumbnail: the 256px webp, with the site's png/jpg fallbacks.
static func thumb_url(thumbs: Variant) -> String:
	return _pick_thumb(thumbs, ["256-WEBP", "256-PNG", "256-JPG-FFFFFF"])


## Big still for the details popup: the 1024px png, else the largest
## png/webp the asset offers.
static func preview_url(thumbs: Variant) -> String:
	return _pick_thumb(thumbs, ["1024-PNG", "2048-PNG", "512-PNG", "1024-WEBP", "2048-WEBP"])


static func _pick_thumb(thumbs: Variant, wanted: Array) -> String:
	if not thumbs is Dictionary:
		return ""
	for k in wanted:
		var v: Variant = thumbs.get(k, "")
		if v is String and not v.is_empty():
			return v
	# Any "N-FMT" key as a last resort — thumbnails is {size-fmt[-bg]: url}.
	var keys: Array = thumbs.keys()
	keys.sort()
	return str(thumbs[keys[0]]) if not keys.is_empty() else ""


## An /assets page response ({totalResults, assets:[...]}) or a bare
## asset array → normalized asset dicts. Type keeps the API's own slugs
## ("material", "hdri", "3d-model"…) — the documented vocabulary every
## comparison uses.
static func parse_assets(raw: Variant) -> Array:
	var list: Variant = raw
	if raw is Dictionary:
		list = raw.get("assets", [])
	var out := []
	if not list is Array:
		return out
	for a: Variant in list:
		if not a is Dictionary:
			continue
		# _s() not `or ""` — GDScript `or` returns a bool, and .get() only
		# defaults on MISSING keys, not the explicit nulls APIs send.
		var slug := _s(a.get("id"))
		var thumbs: Dictionary = a.get("thumbnails", {}) if a.get("thumbnails") is Dictionary else {}
		var dims: Dictionary = a.get("dimensions", {}) if a.get("dimensions") is Dictionary else {}
		var stats: Dictionary = a.get("downloadStatistics", {}) if a.get("downloadStatistics") is Dictionary else {}
		out.append({
			"slug": slug,
			"name": _s(a.get("title"), slug),
			"type": _s(a.get("type"), "material"),
			"url": _s(a.get("url")),
			"release_date": _s(a.get("releaseDate")),
			"short_description": _s(a.get("shortDescription")),
			"long_description": _s(a.get("longDescription")),
			"tags": a.get("tags", []) if a.get("tags") is Array else [],
			"colors": a.get("colors", []) if a.get("colors") is Array else [],
			"maps": a.get("maps", []) if a.get("maps") is Array else [],
			"collections": a.get("collections", []) if a.get("collections") is Array else [],
			"technique": _s(a.get("technique")),
			# Physical size in centimeters; {0,0,0} where it doesn't apply
			# (models, HDRIs).
			"dim_w": float(dims.get("width", 0.0)),
			"dim_h": float(dims.get("height", 0.0)),
			"dim_d": float(dims.get("depth", 0.0)),
			"downloads_total": int(stats.get("total", 0)),
			"downloads_month": int(stats.get("lastMonth", 0)),
			"downloads_week": int(stats.get("lastWeek", 0)),
			"downloads_day": int(stats.get("lastDay", 0)),
			"thumbnails": thumbs,
			"thumbnail_url": thumb_url(thumbs),
			"preview_url": preview_url(thumbs),
		})
	return out


## totalResults from a page response — the tab pages until offset ≥ this.
static func parse_total(raw: Variant) -> int:
	return int(raw.get("totalResults", 0)) if raw is Dictionary else 0


## /categories → [{id, title, type, numberOfAssets}] normalized.
static func parse_categories(raw: Variant) -> Array:
	var out := []
	if not raw is Array:
		return out
	for c: Variant in raw:
		if not c is Dictionary:
			continue
		out.append({"id": _s(c.get("id")), "title": _s(c.get("title"), _s(c.get("id"))),
			"type": _s(c.get("type")), "count": int(c.get("numberOfAssets", 0))})
	return out


## The ?id=<slug>&include=downloads response → the downloads array
## (flatten_files also accepts the bare array or a whole asset dict).
static func parse_downloads(raw: Variant) -> Array:
	var list: Variant = raw
	if raw is Dictionary:
		if raw.has("downloads"):
			list = raw.get("downloads")
		else:
			var assets: Variant = raw.get("assets", [])
			list = []
			if assets is Array and not assets.is_empty() and assets[0] is Dictionary:
				list = assets[0].get("downloads", [])
	return list if list is Array else []


## Free-text match over the loaded subset — the site's `q` is server-side,
## but the tab holds the full facet result so name/id/tags/maps/technique/
## collections filter instantly like the site's search box.
static func matches(asset: Dictionary, text: String) -> bool:
	var t := text.strip_edges().to_lower()
	if t.is_empty():
		return true
	var hay := PackedStringArray([str(asset.get("name", "")), str(asset.get("slug", "")),
		str(asset.get("technique", "")), str(asset.get("type", ""))])
	for v in asset.get("tags", []):
		hay.append(str(v))
	for v in asset.get("maps", []):
		hay.append(str(v))
	for v in asset.get("collections", []):
		hay.append(str(v))
	return " ".join(hay).to_lower().contains(t)


## Client mirror of the site's sorts over the fetched subset: "popular"
## → lastMonth downloads (the site's blend is opaque; recent downloads is
## the honest proxy), "downloads" → total, "latest"/"oldest" → release
## date (ISO strings compare correctly), "alphabet", "random".
static func sort_assets(assets: Array, mode := "popular") -> void:
	match mode:
		"downloads":
			assets.sort_custom(func(a, b):
				var ca := int(a.get("downloads_total", 0))
				var cb := int(b.get("downloads_total", 0))
				return str(a.get("name", "")) < str(b.get("name", "")) if ca == cb else ca > cb)
		"latest":
			assets.sort_custom(func(a, b):
				return str(a.get("release_date", "")) > str(b.get("release_date", "")))
		"oldest":
			assets.sort_custom(func(a, b):
				return str(a.get("release_date", "")) < str(b.get("release_date", "")))
		"alphabet":
			assets.sort_custom(func(a, b):
				return str(a.get("name", "")) < str(b.get("name", "")))
		"random":
			assets.shuffle()
		_: # popular — recent downloads desc, name tiebreak
			assets.sort_custom(func(a, b):
				var ca := int(a.get("downloads_month", 0))
				var cb := int(b.get("downloads_month", 0))
				return str(a.get("name", "")) < str(b.get("name", "")) if ca == cb else ca > cb)


static func _res_rank(res: String) -> int:
	var i := RES_ORDER.find(res.to_lower())
	return i if i >= 0 else 50


## A download entry's attributes string → {res, fmt, qual, animated}.
## Shapes seen live: "<res>-<fmt>" ("1K-JPG"), "<res>-<fmt>-ANIMATED",
## "<qual>-<res>-<fmt>" ("LQ-1K-JPG"/"SQ-2K-PNG"), bare "<res>" ("4K" on
## HDRIs), and "<variant>" ("COMPILED"/"COMPILED-XL" on sbsar).
static func parse_attributes(attr: String) -> Dictionary:
	var parts := attr.split("-", false)
	var out := {"res": "", "fmt": "", "qual": "", "variant": ""}
	if parts.is_empty():
		return out
	var i := 0
	if QUAL_ORDER.has(parts[0].to_upper()):
		out["qual"] = parts[0].to_upper()
		i += 1
	if i < parts.size() and _is_res(parts[i]):
		out["res"] = parts[i].to_upper()
		i += 1
	var rest := PackedStringArray(parts.slice(i))
	if not rest.is_empty() and rest[rest.size() - 1].to_upper() == "ANIMATED":
		out["variant"] = "animated"
		rest.remove_at(rest.size() - 1)
	out["fmt"] = "-".join(rest).to_lower()
	return out


## "1K"/"12K"/"512" look like resolutions; "COMPILED"/"JPG" don't.
static func _is_res(part: String) -> bool:
	return (part.to_lower().ends_with("k") and part.length() <= 3) or part.is_valid_int()


## A download row's label — the site's own wording: "JPG 1K", "PNG 8K",
## "ZIP 4K" (bare res on HDRIs), "LQ JPG 1K", "JPG 1K (animated)",
## "SBSAR COMPILED", "OBJ 2K", "EXR 8K".
static func option_label(entry: Dictionary) -> String:
	var bits := PackedStringArray()
	var ext := str(entry.get("ext", "")).to_lower()
	var pa: Dictionary = entry.get("parsed", {})
	if ext == "zip":
		var fmt := str(pa.get("fmt", "")).to_upper()
		var res := str(pa.get("res", ""))
		var qual := str(pa.get("qual", ""))
		if not qual.is_empty():
			bits.append(qual)
		bits.append(fmt if not fmt.is_empty() else "ZIP")
		if not res.is_empty():
			bits.append(res)
		if str(pa.get("variant", "")) == "animated":
			bits.append("(animated)")
	else:
		bits.append(ext.to_upper())
		var attr := str(entry.get("attr", ""))
		if not attr.is_empty():
			bits.append(attr)
	return " ".join(bits)


## The asset's downloads array → flat option rows
## [{key,label,url,size,total_size,ext,res,attr,includes:{}}] sorted
## FMT_ORDER → resolution → quality → stills-before-animated. Companion
## files don't exist here (zips are self-contained), includes stays {}.
static func flatten_files(raw: Variant) -> Array:
	var out := []
	for e: Variant in parse_downloads(raw):
		if not e is Dictionary or not e.has("url"):
			continue
		var attr := _s(e.get("attributes"))
		var ext := _s(e.get("extension"), "zip").to_lower()
		var pa := parse_attributes(attr)
		var entry := {
			"key": "%s|%s" % [ext, attr],
			"url": _s(e.get("url")),
			"size": int(e.get("size", 0)),
			"total_size": int(e.get("size", 0)),
			"ext": ext, "attr": attr, "parsed": pa,
			"includes": {},
		}
		entry["label"] = "%s (%s)" % [option_label(entry), short_size(entry["total_size"])]
		var fi := FMT_ORDER.find(_fmt_of(entry))
		var qi := QUAL_ORDER.find(str(pa.get("qual", "")))
		# fmt → res → stills before ANIMATED → SQ before LQ: an animated
		# decal variant never wedges itself between plain-quality options.
		entry["_rank"] = [fi if fi >= 0 else 90, _res_rank(str(pa.get("res", ""))),
			1 if str(pa.get("variant", "")) == "animated" else 0,
			qi if qi >= 0 else 0]
		out.append(entry)
	out.sort_custom(func(a, b): return a._rank < b._rank)
	for o in out:
		o.erase("_rank")
	return out


## Index of the suggested option: the top-ranked format nearest
## [param res_hint], else the first option. -1 on an empty list.
static func pick_default(options: Array, res_hint := "2K") -> int:
	if options.is_empty():
		return -1
	# Options arrive pre-sorted — the first entry's format block is the
	# preferred one; pick its row nearest the hint (like PH's 2k gltf).
	var top_fmt := _fmt_of(options[0])
	var best := -1
	var best_d := 1 << 30
	for i in options.size():
		if _fmt_of(options[i]) != top_fmt:
			break # past the preferred format's block
		var res := str((options[i].get("parsed", {}) as Dictionary).get("res", ""))
		var d := 50 if res.is_empty() else absi(_res_rank(res) - _res_rank(res_hint))
		if d < best_d:
			best_d = d
			best = i
	return best if best >= 0 else 0


## The format token a download option sorts by — the zip's inner map
## format (jpg/png/"" for bare-res) or the file's own extension.
static func _fmt_of(entry: Dictionary) -> String:
	if str(entry.get("ext", "")) == "zip":
		return str((entry.get("parsed", {}) as Dictionary).get("fmt", ""))
	return str(entry.get("ext", ""))


## Display name for a type slug: TYPE_LABELS first, else capitalize.
static func type_label(slug: String) -> String:
	return str(TYPE_LABELS.get(slug, slug.capitalize()))


## "surface-photogrammetry" → "Surface Photogrammetry"; "hdri-*" keeps
## the site's HDRI casing.
static func technique_label(slug: String) -> String:
	if slug.is_empty():
		return ""
	var words := slug.split("-", false)
	var out := PackedStringArray()
	for w in words:
		out.append(w.to_upper() if w.to_lower() in ["hdri", "3d", "pbr", "usd"] else w.capitalize())
	return " ".join(out)


## A map slug → display name ("ambient-occlusion" → "Ambient Occlusion").
static func map_label(slug: String) -> String:
	return technique_label(slug)


## Physical size for the popup — the API's centimeters → the site's
## meters ("1.30 × 1.30 m", depth appended when nonzero).
static func dimensions_text(asset: Dictionary) -> String:
	var w := float(asset.get("dim_w", 0.0)) / 100.0
	var h := float(asset.get("dim_h", 0.0)) / 100.0
	var d := float(asset.get("dim_d", 0.0)) / 100.0
	if w <= 0.0 and h <= 0.0 and d <= 0.0:
		return ""
	return "%.2f × %.2f m" % [w, h] if d <= 0.0 else "%.2f × %.2f × %.2f m" % [w, h, d]


## String guard for API fields that arrive as explicit null — str(v)
## for present values, [param fallback] otherwise.
static func _s(v: Variant, fallback := "") -> String:
	return fallback if v == null else str(v)


static func short_size(bytes: int) -> String:
	for unit in [[1073741824, "GB"], [1048576, "MB"], [1024, "kB"]]:
		if bytes >= unit[0]:
			return "%.*f %s" % [1, bytes / float(unit[0]), unit[1]]
	return "%d B" % bytes
