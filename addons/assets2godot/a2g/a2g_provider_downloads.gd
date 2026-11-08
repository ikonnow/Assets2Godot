@tool
extends VBoxContainer
## The downloaded-to-project surface of an in-plugin remote provider —
## Polyhaven/ambientCG's equivalent of the gallery's project view: the
## provider's own cards for assets whose folders exist under its download
## dir, plus a "Browse <Provider>" jump to the catalog tab. Hosted inside
## the A2G browser's downloads chrome and swapped in for the Sources
## tree's "Downloaded to project" row of that provider (a2g_browser's
## show_view_mode("downloads", key)).
##
## The provider pane stays the single source of truth: downloaded_assets()
## reports what's on disk and make_download_card() builds the exact tile
## its own grid shows — same remote_* payload, same quick-download tile
## on right-click, same details popup on click. This view owns no card
## or fetch logic of its own.

const A2GUI = preload("res://addons/assets2godot/a2g/a2g_ui.gd")

var plugin: EditorPlugin

var message: Label
var grid: GridContainer
var browse: Button

var _provider_key := ""
var _dirty := true
var _refresh_queued := false


## Called once by the browser — wires the children like the upstream
## project view's scene does (ProjectMessage / ProjectGrid / Browse).
func setup(new_plugin: EditorPlugin) -> void:
	plugin = new_plugin
	var edscale := EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(20 * edscale))
	message = Label.new()
	message.name = "ProjectMessage"
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(message)
	grid = A2GUI.make_grid()
	grid.name = "ProjectGrid"
	add_child(grid)
	browse = Button.new()
	browse.name = "BrowseButton"
	browse.theme_type_variation = "PanelBackgroundButton"
	browse.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	browse.pressed.connect(_on_browse)
	add_child(browse)
	visibility_changed.connect(_on_visibility_changed)
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.filesystem_changed.connect(refresh_if_shown)


## Points the view at provider [param key]'s downloads and refreshes —
## show_view_mode calls this on every swap-in, so a new download between
## visits always lands.
func show_provider(key: String) -> void:
	if key != _provider_key:
		_provider_key = key
		_dirty = true
	refresh_if_shown()


## Same deferred-refresh contract as project_view: rescan on show, never
## while hidden.
func refresh_if_shown() -> void:
	_dirty = true
	if is_visible_in_tree() and not _refresh_queued:
		_refresh_queued = true
		_refresh_if_dirty.call_deferred()


func _refresh_if_dirty() -> void:
	_refresh_queued = false
	if _dirty and is_visible_in_tree():
		refresh()


func _on_visibility_changed() -> void:
	if _dirty:
		refresh_if_shown()


func refresh() -> void:
	_refresh_queued = false
	_dirty = false
	for c in grid.get_children():
		# Remove-then-free: queue_free()d cards still count in the
		# sizing pass this frame (the spec's ghost-children rule).
		grid.remove_child(c)
		c.queue_free()
	var pane: Control = plugin.provider_pane(_provider_key) if plugin else null
	var assets: Array = []
	if pane != null and pane.has_method("downloaded_assets"):
		assets = pane.downloaded_assets()
	if pane != null and pane.has_method("make_download_card"):
		for a in assets:
			grid.add_child(pane.make_download_card(a))
	var shown := assets.size()
	message.visible = shown == 0
	grid.visible = shown > 0
	# The message and Browse button sit in the middle, otherwise the
	# button follows the tiles — project_view.filter()'s own rule.
	alignment = BoxContainer.ALIGNMENT_CENTER if shown == 0 else BoxContainer.ALIGNMENT_BEGIN
	if shown == 0 and pane != null:
		var dir := str(pane.call("_target_dir")) if pane.has_method("_target_dir") else ""
		message.text = "No assets downloaded yet to %s" % A2GUI.short_path(dir)
	browse.visible = pane != null
	if pane != null:
		browse.text = "Browse %s" % pane.name


## "Browse <Provider>" — back to the catalog surface, like the project
## view's "Browse Blendkit" returning to the BlendKit tab. A provider
## switched off in the A2G menu re-enables first — its tab can't be
## selected while hidden.
func _on_browse() -> void:
	var pane: Control = plugin.provider_pane(_provider_key) if plugin else null
	if pane == null:
		return
	if not plugin.provider_enabled(_provider_key):
		plugin.set_provider_enabled(_provider_key, true)
	plugin.select_provider(pane)
