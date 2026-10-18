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
		print(">>> 扩展未加载：singleton 不存在")
		print(">>> 注意：若未先执行 --import 让引擎扫描 .gdextension，也会得到 false")
		# 复评 §3.2：单例不存在时以非 0 退出，避免探针"假通过"
		quit(1)
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
	print("还原调用已发出")
	# 复评 §3.2：上游返回 void 且不检查 Windows API 结果，
	# 因此这里只证明"调用已发出"，不能据此宣称样式生效或跨应用点击命中。
	print(">>> 结论：扩展可加载、API 可调用；**未验证** Win32 样式与跨应用效果")
	quit(0)
	return true
