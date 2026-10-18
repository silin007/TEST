extends SceneTree

## 实测：Windows Mouse Passthrough GDExtension 能否在 Godot 4.7.2 加载并工作。
## 插件的预编译 DLL 是针对 godot-cpp 4.6-stable 构建的，ABI 兼容性必须实测，不能靠猜。

var _frames: int = 0


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false

	print("=== GDExtension 加载实测（Godot %s）===" % Engine.get_version_info()["string"])
	var has := Engine.has_singleton("MousePassthrough")
	print("Engine.has_singleton(\"MousePassthrough\") = ", has)

	if not has:
		print(">>> 结论：扩展未加载，4.7.2 上不可用（DLL 为 4.6 ABI 构建）")
		quit(0)
		return true

	var mp: Object = Engine.get_singleton("MousePassthrough")
	print("singleton = ", mp)
	var win := root
	print("window_id = ", win.get_window_id())
	# 注意：全静态类型（enable_all_warnings）下，GDExtension singleton 的方法
	# 无法通过静态推导（"not present on the inferred type Object"），必须动态调用。
	print("调用 set_passthrough(id, true) ...")
	mp.call("set_passthrough", win.get_window_id(), true)
	print("调用成功（未抛错）")
	print("调用 set_passthrough(id, false) 还原 ...")
	mp.call("set_passthrough", win.get_window_id(), false)
	print("还原成功")
	print(">>> 结论：扩展在 4.7.2 上可加载且 API 可调用")
	quit(0)
	return true
