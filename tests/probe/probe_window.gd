extends SceneTree
## 探针：Window 与穿透相关属性的真实签名（WIN-02 依据）。


func _initialize() -> void:
	var win := Window.new()
	print("--- Window 属性（含 passthrough/transparent/always）---")
	for p: Dictionary in win.get_property_list():
		var name: String = str(p["name"])
		if name.contains("passthrough") or name.contains("transparent") or name.contains("always") or name.contains("borderless"):
			print("  %s : type=%s class=%s" % [name, p["type"], p["class_name"]])
	print("--- DisplayServer 相关方法 ---")
	for m: Dictionary in DisplayServer.get_method_list():
		var mname: String = str(m["name"])
		if mname.contains("passthrough") or mname.contains("window_set"):
			print("  ", mname)
	win.free()
	quit(0)
