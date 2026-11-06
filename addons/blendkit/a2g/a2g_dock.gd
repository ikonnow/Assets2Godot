@tool
extends PanelContainer
## The Assets2Godot dock: lists the Client's providers and shows what the
## Epic/Fab vault probing and configured local directories find. Read-only;
## the Client does the work, this panel only renders its /providers/* answers.

var plugin: EditorPlugin

var _status: Label
var _tree: Tree
var _refresh: Button
var _scan: Button
var _hint: Label


func _ready() -> void:
	name = "Assets2Godot"
	var vbox := VBoxContainer.new()
	add_child(vbox)

	var head := HBoxContainer.new()
	vbox.add_child(head)
	var title := Label.new()
	title.text = "Assets2Godot"
	title.theme_type_variation = "HeaderSmall"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_refresh = _head_button(head, "Refresh", "Reload providers and their roots.")
	_refresh.pressed.connect(_on_refresh)
	_scan = _head_button(head, "Scan", "Probe vault caches and local directories.")
	_scan.pressed.connect(_on_scan)

	_status = Label.new()
	_status.text = "Client: …"
	vbox.add_child(_status)

	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tree)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.text = "Local directories come from A2G_LOCAL_DIRS (';' separated)."
	vbox.add_child(_hint)

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


## Fires a GET for [param endpoint] and calls [param cb] with the decoded JSON
## (or null on failure). One throwaway HTTPRequest per call — the dock's
## traffic is rare and small. (Named _fetch, not _get — _get is Object's.)
func _fetch(endpoint: String, cb: Callable) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result, code, _h, body):
		req.queue_free()
		var data = JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null
		cb.call(data))
	var url: String = plugin.connection.client_url(endpoint)
	var err := req.request(url)
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
			items[p.get("name", "")] = item
		# blenderkit is remote; its endpoints are the client's own /assets/*.
		for name in ["fab_vault", "local_dir"]:
			if items.has(name):
				_fetch("providers/%s/status" % name, func(st):
					_fill_status(items.get(name), st))
		_update_state())


func _fill_status(item: TreeItem, st) -> void:
	if item == null or not (st is Dictionary):
		return
	for key in ["candidate_roots", "configured_roots"]:
		for r in st.get(key, []):
			var child := _tree.create_item(item)
			var mark := "[+] " if r.get("exists", false) else "[-] "
			child.set_text(0, mark + str(r.get("path", "")))
			child.set_tooltip_text(0, "reachable" if r.get("exists", false) else "not found")
	if st.get("index_available") == false:
		var child := _tree.create_item(item)
		child.set_text(0, "index unavailable")


func _on_scan() -> void:
	_scan.disabled = true
	var root := _tree.get_root()
	if root == null:
		root = _tree.create_item()
	# Lambdas capture locals by value; an Array keeps the counter shared.
	var pending := [0]
	for name in ["fab_vault", "local_dir"]:
		pending[0] += 1
		_fetch("providers/%s/scan" % name, func(st):
			if st is Dictionary:
				var item := _tree.create_item(root)
				item.set_text(0, "scan: %s" % name)
				for r in st.get("scanned_roots", []):
					var c := _tree.create_item(item)
					c.set_text(0, "%s — %d entries" % [r.get("path", ""), int(r.get("entries", 0))])
				for r in st.get("skipped_roots", []):
					var c := _tree.create_item(item)
					c.set_text(0, "[-] " + str(r))
			pending[0] -= 1
			if pending[0] == 0:
				_scan.disabled = not (plugin.connection and plugin.connection.is_client_connected()))
