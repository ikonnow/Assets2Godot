@tool
extends PanelContainer

## Emitted after a scan finished — lets the unified browser refresh its
## results so new assets show up without a manual search.
signal scanned
## The Assets2Godot dock: lists the Client's providers, their configured scan
## roots and index search. Directories are only ever scanned when the user
## adds them here — everything goes through the Client's /providers/*
## endpoints and its settings store.

var plugin: EditorPlugin

var _status: Label
var _tree: Tree
var _refresh: Button
var _scan: Button
var _add: Button
var _remove: Button
var _dir_dialog: EditorFileDialog


func _ready() -> void:
	# Keep a pre-assigned name (e.g. "Local Assets" as a main-screen tab);
	# only the auto-generated node name is replaced.
	if name == "" or name.begins_with("@"):
		name = "Assets2Godot"
	var vbox := VBoxContainer.new()
	add_child(vbox)

	var head := HBoxContainer.new()
	vbox.add_child(head)
	var title := Label.new()
	title.text = "Sources"
	title.theme_type_variation = "HeaderSmall"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_add = _head_button(head, "", "Add a directory to the local_dir provider's scan roots.")
	_add.icon = _icon("Add")
	_add.flat = true
	_add.pressed.connect(_on_add)
	_remove = _head_button(head, "", "Remove the selected scan root, or adopt a detected one.")
	_remove.icon = _icon("Remove")
	_remove.flat = true
	_remove.pressed.connect(_on_remove)
	_remove.disabled = true
	_refresh = _head_button(head, "", "Reload providers and their roots.")
	_refresh.icon = _icon("Reload")
	_refresh.flat = true
	_refresh.pressed.connect(_on_refresh)
	_scan = _head_button(head, "", "Walk the configured roots and index their assets.")
	_scan.icon = _icon("Play")
	_scan.flat = true
	_scan.pressed.connect(_on_scan)

	_status = Label.new()
	_status.text = "Client: …"
	vbox.add_child(_status)

	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_update_state)
	vbox.add_child(_tree)

	_dir_dialog = EditorFileDialog.new()
	_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_dir_dialog.dir_selected.connect(_on_dir_selected)
	add_child(_dir_dialog)

	if plugin.connection:
		plugin.connection.connected.connect(_on_connected)
		plugin.connection.stopped.connect(_on_stopped)
	_update_state()


func _head_button(parent: Control, label: String, tip: String) -> Button:
	var b := Button.new()
	b.text = label
	b.tooltip_text = tip
	b.theme_type_variation = "EditorInspectorButton"
	parent.add_child(b)
	return b


func _on_connected() -> void:
	_update_state()
	_on_refresh()


func _on_stopped() -> void:
	_update_state()
	_tree.clear()


func _update_state() -> void:
	var connected: bool = plugin.connection != null and plugin.connection.is_client_connected()
	_status.text = "Client: %s (port %s)" % [plugin.connection.status_text(), plugin.connection.port] if plugin.connection else "Client: unavailable"
	_refresh.disabled = not connected
	_scan.disabled = not connected
	_add.disabled = not connected
	var sel = _selected_root()
	_remove.disabled = not connected or sel == null
	var adopt: bool = sel != null and sel.get("candidate", false)
	_remove.icon = _icon("Add" if adopt else "Remove")
	_remove.tooltip_text = ("Adopt the detected folder as a scan root."
		if adopt else "Remove the selected scan root from its provider.")


## The selected tree row's {"provider","root"} metadata, or null when the
## selection is not a removable root row.
func _selected_root() -> Variant:
	var item := _tree.get_selected()
	if item == null:
		return null
	if item.get_meta("provider") == null or item.get_meta("root") == null:
		return null
	return {"provider": item.get_meta("provider"), "root": item.get_meta("root"),
		"candidate": item.get_meta("candidate") == true}


## Fires a GET for [param endpoint] and calls [param cb] with the decoded JSON
## (or null on failure). (Named _fetch, not _get — _get is Object's.)
func _fetch(endpoint: String, cb: Callable) -> void:
	_request(endpoint, HTTPClient.METHOD_GET, null, cb)


## Fires a POST with a JSON body for [param endpoint].
func _post(endpoint: String, body: Dictionary, cb: Callable) -> void:
	_request(endpoint, HTTPClient.METHOD_POST, body, cb)


func _request(endpoint: String, method: int, body, cb: Callable) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result, code, _h, resp_body):
		req.queue_free()
		var data = JSON.parse_string(resp_body.get_string_from_utf8()) if code == 200 else null
		cb.call(data))
	var url: String = plugin.connection.client_url(endpoint)
	var err := req.request(url, ["Content-Type: application/json"], method,
		JSON.stringify(body) if body != null else "")
	if err != OK:
		req.queue_free()
		plugin.log_warning("Assets2Godot request failed to start: %s (%s)" % [url, err])


func _on_refresh() -> void:
	_refresh.disabled = true
	_tree.clear()
	var root := _tree.create_item()
	_fetch("providers/list", func(list):
		if list == null:
			_status.text = "Client: providers/list failed"
			_update_state()
			return
		var items := {}
		for p in list:
			var item := _tree.create_item(root)
			item.set_text(0, "%s (%s)" % [p.get("name", "?"), p.get("kind", "?")])
			item.set_icon(0, _icon("HTTPRequest" if str(p.get("kind", "")) == "remote" else "Folder"))
			item.set_icon_max_width(0, _icon_size())
			items[p.get("name", "")] = item
		# blenderkit is remote; its endpoints are the client's own /assets/*.
		for pname in ["fab_vault", "local_dir"]:
			if items.has(pname):
				_fetch("providers/%s/status" % pname, func(st):
					_fill_status(items.get(pname), pname, st))
		_update_state())


func _fill_status(item: TreeItem, pname: String, st) -> void:
	if item == null or not (st is Dictionary):
		return
	var src := _tree.create_item(item)
	src.set_text(0, "roots: " + str(st.get("roots_source", "?")))
	src.set_icon(0, _icon("Tools"))
	src.set_icon_max_width(0, _icon_size())
	for r in st.get("roots", []):
		var child := _tree.create_item(item)
		child.set_text(0, str(r.get("path", "")))
		child.set_icon(0, _icon("StatusSuccess" if r.get("exists", false) else "StatusError"))
		child.set_icon_max_width(0, _icon_size())
		child.set_tooltip_text(0, "reachable" if r.get("exists", false) else "not found")
		child.set_meta("provider", pname)
		child.set_meta("root", str(r.get("path", "")))
	# fab_vault: show detected candidates that are not configured yet.
	for r in st.get("candidate_roots", []):
		var in_roots := false
		for rr in st.get("roots", []):
			if rr.get("path", "") == r.get("path", ""):
				in_roots = true
		if r.get("exists", false) and not in_roots:
			var child := _tree.create_item(item)
			child.set_text(0, str(r.get("path", "")))
			child.set_icon(0, _icon("StatusWarning"))
			child.set_icon_max_width(0, _icon_size())
			child.set_tooltip_text(0, "detected, not configured — select and Adopt to scan it")
			child.set_meta("provider", pname)
			child.set_meta("root", str(r.get("path", "")))
			child.set_meta("candidate", true)
	if st.get("index_available") == false:
		var child := _tree.create_item(item)
		child.set_text(0, "index unavailable")
		child.set_icon(0, _icon("NodeWarning"))
		child.set_icon_max_width(0, _icon_size())


## Editor icon by name, null-safe — tree items just show text when a name
## is missing in this Godot version.
func _icon(icon_name: StringName) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


func _icon_size() -> int:
	return int(16 * EditorInterface.get_editor_scale())


func _on_scan() -> void:
	_scan.disabled = true
	var root := _tree.get_root()
	if root == null:
		root = _tree.create_item()
	# Lambdas capture locals by value; an Array keeps the counter shared.
	var pending := [0]
	for pname in ["fab_vault", "local_dir"]:
		pending[0] += 1
		_fetch("providers/%s/scan" % pname, func(st):
			if st is Dictionary:
				var item := _tree.create_item(root)
				var sum: Dictionary = st.get("scanned", {})
				item.set_text(0, "scan: %s — %d files indexed" % [pname, int(sum.get("files", 0))])
				item.set_icon(0, _icon("Search"))
				item.set_icon_max_width(0, _icon_size())
				for r in sum.get("roots", []):
					var c := _tree.create_item(item)
					if r.get("skipped", false):
						c.set_text(0, str(r.get("path", "")))
						c.set_icon(0, _icon("StatusError"))
					else:
						c.set_text(0, "%s — %d indexed" % [r.get("path", ""), int(r.get("indexed", 0))])
						c.set_icon(0, _icon("Folder"))
					c.set_icon_max_width(0, _icon_size())
			pending[0] -= 1
			if pending[0] == 0:
				_scan.disabled = not (plugin.connection and plugin.connection.is_client_connected())
				scanned.emit())


func _on_add() -> void:
	_dir_dialog.popup_centered_ratio(0.5)


## Public entry point for the FileSystem context menu's "A2G: Scan folder
## as root" — same flow as picking the directory in the Add dialog.
func add_scan_root(dir: String) -> void:
	_on_dir_selected(dir)


func _on_dir_selected(dir: String) -> void:
	_fetch("providers/local_dir/roots", func(st):
		if not (st is Dictionary):
			return
		var roots := []
		for r in st.get("roots", []):
			roots.append(r.get("path", ""))
		if not roots.has(dir):
			roots.append(dir)
		_post("providers/local_dir/roots", {"roots": roots}, func(_st):
			_on_refresh()))


func _on_remove() -> void:
	var sel = _selected_root()
	if sel == null:
		return
	var pname: String = sel["provider"]
	_fetch("providers/%s/roots" % pname, func(st):
		if not (st is Dictionary):
			return
		var roots := []
		for r in st.get("roots", []):
			if r.get("path", "") != sel["root"]:
				roots.append(r.get("path", ""))
		if sel.get("candidate", false) and not roots.has(sel["root"]):
			roots.append(sel["root"])
		_post("providers/%s/roots" % pname, {"roots": roots}, func(_st):
			_on_refresh()))


