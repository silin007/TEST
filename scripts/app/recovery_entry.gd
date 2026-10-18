class_name RecoveryEntry
extends Node
## 独立于桌宠窗口的恢复入口（架构 §4.1 / O-04）。
## 候选一：原生系统托盘 StatusIndicator + PopupMenu。
## 候选二（托盘不可用时的等效常驻入口）：一个独立的常驻小窗口，不依赖桌宠窗口可见，
## 也不依赖桌宠窗口是否获得焦点。仅窗口内按钮或有焦点才生效的按键不构成等效入口。
##
## 注意：4.7.2 的 StatusIndicator 没有 is_system_tray_available()，自检只能间接进行；
## 托盘是否真正可用必须在导出的 Windows 构建上实机验证（WIN-06）。

signal action_requested(action: StringName)
signal availability_changed(ready: bool, reason: String)

enum Kind { NONE, TRAY, MINI_WINDOW }

const ACTION_RESTORE_INTERACT := &"RESTORE_INTERACT"
const ACTION_SHOW_PET := &"SHOW_PET"
const ACTION_OPEN_FULL := &"OPEN_FULL"
const ACTION_TOGGLE_FOCUS := &"TOGGLE_FOCUS"
const ACTION_QUIT := &"QUIT"

const TRAY_ICON_PATH := "res://icon.svg"
## 自检与失效检测周期（秒）
const REFRESH_INTERVAL := 5.0

var _kind: int = Kind.NONE
var _ready := false
var _reason: String = "尚未初始化"
var _indicator: StatusIndicator = null
var _menu: PopupMenu = null
var _mini: Window = null
var _refresh_timer: float = 0.0


func _process(delta: float) -> void:
	_refresh_timer += delta
	if _refresh_timer >= REFRESH_INTERVAL:
		_refresh_timer = 0.0
		refresh()


## 建立恢复入口：优先托盘，失败则建立独立常驻小窗口。返回是否就绪。
func setup() -> bool:
	_release_all()
	if _setup_tray():
		_kind = Kind.TRAY
		_ready = true
		_reason = "系统托盘入口已建立（实机须复验）"
		availability_changed.emit(true, _reason)
		return true
	if _setup_mini_window():
		_kind = Kind.MINI_WINDOW
		_ready = true
		_reason = "托盘不可用，已建立独立常驻小窗口入口"
		availability_changed.emit(true, _reason)
		return true
	_kind = Kind.NONE
	_ready = false
	_reason = "托盘与独立入口均不可用"
	availability_changed.emit(false, _reason)
	return false


## 周期性自检：入口失效时撤销就绪状态（架构 §4.1），由 AppController 撤销穿透/隐藏。
func refresh() -> bool:
	if not _ready:
		return false
	if _kind == Kind.TRAY:
		if _indicator == null or not is_instance_valid(_indicator) or not _indicator.is_visible():
			_ready = false
			_reason = "托盘入口失效"
			availability_changed.emit(false, _reason)
			return false
	elif _kind == Kind.MINI_WINDOW:
		if _mini == null or not is_instance_valid(_mini):
			_ready = false
			_reason = "独立入口窗口失效"
			availability_changed.emit(false, _reason)
			return false
	return true


func is_ready() -> bool:
	return _ready


func get_reason() -> String:
	return _reason


func get_kind() -> String:
	match _kind:
		Kind.TRAY:
			return "TRAY"
		Kind.MINI_WINDOW:
			return "MINI_WINDOW"
		_:
			return "NONE"


func get_report() -> Dictionary:
	return {
		"kind": get_kind(),
		"ready": _ready,
		"reason": _reason,
		"tray_api_present": ClassDB.can_instantiate("StatusIndicator"),
	}


## 更新提示文本（托盘 tooltip / 小窗口标题）
func set_status(text: String) -> void:
	if _indicator != null and is_instance_valid(_indicator):
		_indicator.tooltip = text
	if _mini != null and is_instance_valid(_mini):
		_mini.title = "MOTE｜%s" % text


func release() -> void:
	_release_all()
	_kind = Kind.NONE
	_ready = false
	_reason = "已释放"


## —— 候选一：系统托盘 ——

func _setup_tray() -> bool:
	if not ClassDB.can_instantiate("StatusIndicator"):
		_reason = "平台无 StatusIndicator"
		return false
	var indicator := StatusIndicator.new()
	if indicator == null:
		_reason = "StatusIndicator 实例化失败"
		return false
	var icon: Texture2D = load(TRAY_ICON_PATH) as Texture2D if FileAccess.file_exists(TRAY_ICON_PATH) else null
	if icon != null:
		indicator.icon = icon
	indicator.tooltip = "MOTE 桌宠"
	var menu := PopupMenu.new()
	menu.add_item("恢复交互", 0)
	menu.add_item("显示宠物", 1)
	menu.add_item("打开完整窗口", 2)
	menu.add_item("专注模式开关", 3)
	menu.add_separator()
	menu.add_item("退出", 4)
	menu.id_pressed.connect(_on_menu_id_pressed)
	add_child(indicator)
	indicator.add_child(menu)
	# 4.7.2：StatusIndicator.set_menu() 接受 NodePath，不是节点引用
	indicator.set_menu(menu.get_path())
	indicator.visible = true
	# 间接自检：可见性成立才认为入口存在；真实可用仍须实机验证
	if not indicator.is_visible():
		indicator.free()
		_reason = "托盘入口自检失败（不可见）"
		return false
	_indicator = indicator
	_menu = menu
	return true


## —— 候选二：独立常驻小窗口 ——

func _setup_mini_window() -> bool:
	var win := Window.new()
	win.title = "MOTE｜恢复入口"
	win.size = Vector2i(200, 240)
	win.always_on_top = true
	win.transparent = false
	win.unresizable = false
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 6)
	var hint := Label.new()
	hint.text = "恢复入口（托盘不可用）"
	box.add_child(hint)
	for entry: Array in [
		["恢复交互", ACTION_RESTORE_INTERACT],
		["显示宠物", ACTION_SHOW_PET],
		["打开完整窗口", ACTION_OPEN_FULL],
		["专注模式开关", ACTION_TOGGLE_FOCUS],
		["退出", ACTION_QUIT],
	]:
		var button := Button.new()
		button.text = str(entry[0])
		var action := StringName(str(entry[1]))
		button.pressed.connect(func() -> void: _emit_action(action))
		box.add_child(button)
	win.add_child(box)
	# 关闭该窗口等于销毁恢复入口，因此拦截关闭请求
	win.close_requested.connect(func() -> void: win.visible = true)
	add_child(win)
	win.visible = true
	if not win.visible:
		win.free()
		_reason = "独立入口窗口自检失败"
		return false
	_mini = win
	return true


func _emit_action(action: StringName) -> void:
	action_requested.emit(action)


func _on_menu_id_pressed(id: int) -> void:
	match id:
		0:
			_emit_action(ACTION_RESTORE_INTERACT)
		1:
			_emit_action(ACTION_SHOW_PET)
		2:
			_emit_action(ACTION_OPEN_FULL)
		3:
			_emit_action(ACTION_TOGGLE_FOCUS)
		4:
			_emit_action(ACTION_QUIT)
		_:
			push_warning("RecoveryEntry: 未知菜单项 %d" % id)


func _release_all() -> void:
	if _indicator != null and is_instance_valid(_indicator):
		_indicator.free()
	_indicator = null
	_menu = null
	if _mini != null and is_instance_valid(_mini):
		_mini.free()
	_mini = null
