extends SceneTree
## 探针：确认透明相关项目设置的真实键名与默认值（P0-004 依据）。


func _initialize() -> void:
	var keys: Array[String] = [
		"display/window/per_pixel_transparency/allowed",
		"display/window/size/transparent",
		"rendering/viewport/transparent_background",
		"display/window/energy_saving/keep_screen_on",
	]
	for k: String in keys:
		print("%-50s has=%s value=%s" % [k, ProjectSettings.has_setting(k), ProjectSettings.get_setting(k, "MISSING")])
	print("--- 所有含 transparency 的设置 ---")
	for p: Dictionary in ProjectSettings.get_property_list():
		var n: String = str(p["name"])
		if n.contains("transparen"):
			print("  ", n, " = ", ProjectSettings.get_setting(n, "?"))
	quit(0)
