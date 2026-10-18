extends SceneTree
## 探针：恢复入口候选 StatusIndicator 的真实 API 与可用性（WIN-06/O-04）。
## 注意：headless 下结论不代表 Windows 实机，实机仍须复验。


func _initialize() -> void:
	print("DisplayServer=", DisplayServer.get_name())
	print("can_instantiate StatusIndicator=", ClassDB.can_instantiate("StatusIndicator"))
	var si := StatusIndicator.new()
	print("instance=", si)
	if si == null:
		quit(0)
		return
	print("methods:")
	for m: Dictionary in si.get_method_list():
		var name: String = str(m["name"])
		if name.begins_with("get_") or name.begins_with("set_") or name.begins_with("is_"):
			print("  ", name)
	print("has is_system_tray_available=", si.has_method("is_system_tray_available"))
	print("available_call=", si.call("is_system_tray_available") if si.has_method("is_system_tray_available") else "n/a")
	si.free()
	quit(0)
