class_name WindowController
extends Node
## 原生窗口属性、拖动、坐标、恢复入口状态、显示器有效性（架构 §4.2 / §6.2）。
## 只处理窗口与桌面几何：不修改宠物需求、不决定行为、不读写存档。
##
## 重要：窗口始终保持 transparent=true。FULL 模式通过绘制不透明背景板呈现
## 普通窗口外观（在运行时切换 transparent 可能导致窗口重建，属高风险操作）。

signal drag_started()
signal drag_ended()
signal mode_applied(mode: StringName, mouse_mode: StringName, error: int)
signal geometry_corrected(old_rect: Rect2i, new_rect: Rect2i, reason: String)

## 悬浮窗与完整窗口尺寸（架构 §6.1 默认矩形）
const FLOATING_SIZE := Vector2i(256, 256)
const FULL_SIZE := Vector2i(960, 640)
## 校验周期：每 2 秒检查显示器/工作区变化（架构 §4.2）
const VALIDATE_INTERVAL := 2.0

var _mode: StringName = AppMode.FLOATING
var _mouse_mode: StringName = AppMode.MOUSE_INTERACTIVE
## 恢复入口就绪状态（架构 §4.1）：未就绪时拒绝隐藏与穿透
var _recovery_ready: bool = false
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _floating_rect: Rect2i = Rect2i(100, 100, FLOATING_SIZE.x, FLOATING_SIZE.y)
var _full_rect: Rect2i = Rect2i(100, 100, FULL_SIZE.x, FULL_SIZE.y)
var _screen_hint: int = 0
var _validate_timer: float = 0.0
var _can_walk: bool = true


func _ready() -> void:
	_apply_native_attributes()


func _process(delta: float) -> void:
	_validate_timer += delta
	if _validate_timer >= VALIDATE_INTERVAL:
		_validate_timer = 0.0
		validate_geometry()


## —— 恢复入口 ——

func set_recovery_ready(ready: bool) -> void:
	_recovery_ready = ready


func is_recovery_ready() -> bool:
	return _recovery_ready


## —— 模式与鼠标 ——

func get_mode() -> StringName:
	return _mode


func get_mouse_mode() -> StringName:
	return _mouse_mode


## 应用模式与策略。恢复入口未就绪时拒绝隐藏与穿透（架构 §4.1）。
func apply_mode(mode: StringName, policy: Dictionary) -> Error:
	if not AppMode.is_valid_mode(mode):
		return ERR_INVALID_PARAMETER
	if (mode == AppMode.HIDDEN or mode == AppMode.FOCUS) and not _recovery_ready:
		push_error("WindowController: 恢复入口未就绪，拒绝进入 %s" % mode)
		return ERR_UNAVAILABLE
	# 模式切换前取消拖动，避免遗留按下状态（WIN-03）
	if _dragging:
		_end_drag("mode_switch")
	_mode = mode
	var err := _apply_native_attributes()
	var mouse_mode: StringName = policy.get("mouse_mode", AppMode.MOUSE_INTERACTIVE) as StringName
	err = set_mouse_mode_internal(mouse_mode) if err == OK else err
	_can_walk = bool(policy.get("can_walk", true))
	validate_geometry()
	mode_applied.emit(mode, _mouse_mode, err)
	return err


func set_mouse_mode(mouse_mode: StringName) -> Error:
	if not AppMode.is_valid_mouse(mouse_mode):
		return ERR_INVALID_PARAMETER
	if mouse_mode == AppMode.MOUSE_PASSTHROUGH and not _recovery_ready:
		push_error("WindowController: 恢复入口未就绪，拒绝穿透")
		return ERR_UNAVAILABLE
	return set_mouse_mode_internal(mouse_mode)


func set_mouse_mode_internal(mouse_mode: StringName) -> Error:
	_mouse_mode = mouse_mode
	var win := get_window()
	if win == null:
		return ERR_UNAVAILABLE
	match mouse_mode:
		AppMode.MOUSE_PASSTHROUGH:
			# 4.7.2：Window.mouse_passthrough 为布尔值（整窗穿透），
			# 局部多边形另在 mouse_passthrough_polygon（P0 不使用，架构 §4 不把局部穿透当替代）。
			# 注意：官方描述不保证跨应用命中，跨应用穿透必须在独立导出构建上实测（WIN-02）。
			win.mouse_passthrough_polygon = PackedVector2Array()
			win.mouse_passthrough = true
		_:
			win.mouse_passthrough = false
			win.mouse_passthrough_polygon = PackedVector2Array()
	return OK


func _apply_native_attributes() -> Error:
	var win := get_window()
	if win == null:
		return ERR_UNAVAILABLE
	# 透明 / 无边框 / 置顶：桌面外壳的基础属性
	win.transparent = true
	win.borderless = true
	win.unresizable = true
	win.always_on_top = (_mode == AppMode.FLOATING or _mode == AppMode.FOCUS)
	match _mode:
		AppMode.FULL:
			win.size = Vector2i(_full_rect.size)
			win.position = Vector2i(_full_rect.position)
		AppMode.HIDDEN:
			win.visible = false
		_:
			win.visible = true
			win.size = Vector2i(_floating_rect.size)
			win.position = Vector2i(_floating_rect.position)
	return OK


## 恢复可见（架构 §4.1：从 HIDDEN 恢复为隐藏前的可见模式）
func restore_visible() -> Error:
	var win := get_window()
	if win == null:
		return ERR_UNAVAILABLE
	win.visible = true
	if _mode == AppMode.HIDDEN:
		_mode = AppMode.FLOATING
	return _apply_native_attributes()


## —— 拖动 ——

func is_dragging() -> bool:
	return _dragging


func _input(event: InputEvent) -> void:
	if _mode != AppMode.FLOATING and _mode != AppMode.FOCUS:
		return
	if _mouse_mode == AppMode.MOUSE_PASSTHROUGH:
		return  # 穿透时不接收输入
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_drag()
			elif _dragging:
				_end_drag("released")
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var win := get_window()
		if win != null:
			win.position = Vector2i(Vector2(win.position) + mm.relative)


func _begin_drag() -> void:
	if _dragging:
		return
	_dragging = true
	drag_started.emit()


func _end_drag(reason: String) -> void:
	if not _dragging:
		return
	_dragging = false
	_sync_rect_from_window()
	validate_geometry()
	drag_ended.emit()
	if reason != "":
		push_warning("WindowController: 拖动结束（%s）" % reason)


func _sync_rect_from_window() -> void:
	var win := get_window()
	if win == null:
		return
	if _mode == AppMode.FULL:
		_full_rect = Rect2i(win.position, win.size)
	else:
		_floating_rect = Rect2i(win.position, win.size)


## —— 几何校验与环境 ——

## 校验窗口是否位于有效工作区；不在则修正（架构 §4.2：5 秒内回到有效工作区）
func validate_geometry() -> void:
	var win := get_window()
	if win == null or not win.visible:
		return
	var screen := _resolve_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	var rect := Rect2i(win.position, win.size)
	# 窗口过大则先收缩至可容纳尺寸
	var size := rect.size
	if size.x > usable.size.x or size.y > usable.size.y:
		size = Vector2i(mini(size.x, usable.size.x), mini(size.y, usable.size.y))
		win.size = size
	# 允许负坐标（副屏在主屏左侧），但必须完整落在工作区内
	var pos := rect.position
	var corrected := Vector2i(
		clampi(pos.x, usable.position.x, usable.position.x + maxi(0, usable.size.x - size.x)),
		clampi(pos.y, usable.position.y, usable.position.y + maxi(0, usable.size.y - size.y))
	)
	if corrected != pos or size != rect.size:
		win.position = corrected
		win.size = size
		_sync_rect_from_window()
		geometry_corrected.emit(rect, Rect2i(corrected, size), "outside_usable_rect")
	_screen_hint = screen


func _resolve_screen() -> int:
	var screen_count := DisplayServer.get_screen_count()
	if screen_count <= 0:
		return 0
	var win := get_window()
	if win == null:
		return mini(_screen_hint, screen_count - 1)
	# 优先选择与旧矩形重叠最大的屏幕，否则回到主屏
	var best_index := 0
	var best_overlap := -1
	var rect := Rect2i(win.position, win.size)
	for i: int in range(screen_count):
		var usable: Rect2i = DisplayServer.screen_get_usable_rect(i)
		var overlap: Rect2i = usable.intersection(rect)
		var area: int = overlap.size.x * overlap.size.y
		if area > best_overlap:
			best_overlap = area
			best_index = i
	return best_index


## 提供给模拟的只读环境（架构 §3 数据流：Win → Sim）
func get_environment() -> Dictionary:
	return {
		"can_walk": _can_walk and not _dragging,
		"dragging": _dragging,
		"screen_hint": _screen_hint,
	}


func get_floating_rect() -> Rect2i:
	return _floating_rect


func get_full_rect() -> Rect2i:
	return _full_rect


func get_screen_hint() -> int:
	return _screen_hint


## 从存档设置恢复矩形（架构 §6.1 settings）
func apply_settings(floating_rect: Rect2i, full_rect: Rect2i, screen_hint: int) -> void:
	_floating_rect = floating_rect
	_full_rect = full_rect
	_screen_hint = screen_hint
	_apply_native_attributes()
	validate_geometry()
