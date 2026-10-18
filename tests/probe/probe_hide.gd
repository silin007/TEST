extends SceneTree
## 探针：主窗口隐藏能力（P0-006）。
## 必须在**有显示驱动**的情况下运行（不要加 --headless），否则拿不到真实窗口状态。
## 运行：Godot.exe --path . --script res://tests/probe/probe_hide.gd
##
## 逐个尝试隐藏手段并记录：调用是否报错、调用后 Window.visible 与 DisplayServer 模式。

var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_probe()
	quit(0)
	return false


func _probe() -> void:
	var win: Window = root
	print("=== 窗口身份 ===")
	print("root 的父节点=", win.get_parent(), "（null 说明它就是树根/主窗口）")
	print("visible=", win.visible)
	print("mode(DisplayServer)=", DisplayServer.window_get_mode(0))

	print("=== 手段 1：win.visible = false ===")
	win.visible = false
	print("调用后 win.visible=", win.visible, "  mode=", DisplayServer.window_get_mode(0))
	print("  → 若上面出现 \"Can't change visibility of main window\" 且 visible 仍为 true，则不可用")

	# 复位
	win.visible = true
	print("复位后 visible=", win.visible)

	print("=== 手段 2：window_set_mode(MINIMIZED) ===")
	var modes: Dictionary = {
		"WINDOW_MODE_WINDOWED": DisplayServer.WINDOW_MODE_WINDOWED,
		"WINDOW_MODE_MINIMIZED": DisplayServer.WINDOW_MODE_MINIMIZED,
		"WINDOW_MODE_MAXIMIZED": DisplayServer.WINDOW_MODE_MAXIMIZED,
		"WINDOW_MODE_FULLSCREEN": DisplayServer.WINDOW_MODE_FULLSCREEN,
		"WINDOW_MODE_EXCLUSIVE_FULLSCREEN": DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
	}
	print("常量表=", modes)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	print("设为 MINIMIZED 后：get_mode=", DisplayServer.window_get_mode(0), "  win.visible=", win.visible)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	print("恢复 WINDOWED 后：get_mode=", DisplayServer.window_get_mode(0), "  win.visible=", win.visible)

	print("=== 手段 3：原生句柄 ===")
	print("WINDOW_HANDLE 常量存在=", "WINDOW_HANDLE" in DisplayServer)
	if "WINDOW_HANDLE" in DisplayServer:
		var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, 0)
		print("HWND=", handle, "（非 0 即可用于 Win32 ShowWindow）")

	print("=== 手段 4：Window.focusable / flag 相关属性 ===")
	var props: Array[String] = []
	for p: Dictionary in win.get_property_list():
		var n: String = str(p["name"])
		if n.contains("visible") or n.contains("mode") or n.contains("focus") or n.contains("flag"):
			props.append(n)
	print("相关属性=", props)

	print("=== 手段 5：size 归零（仅探测引擎是否接受，不作为正式方案）===")
	var old_size: Vector2i = win.size
	win.size = Vector2i(1, 1)
	print("设为 1x1 后 size=", win.size)
	win.size = old_size
	print("复位 size=", win.size)

	print("=== 结束 ===")
