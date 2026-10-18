class_name FullPanel
extends Control
## 完整窗口的界面与诊断显示（架构 §6.2 / §8）：
## 不透明背景板、模式切换控件、只读诊断、存档恢复界面。
## 只发意图信号，不直接改 PetState、不直接写存档。

signal action_requested(action: StringName)
signal candidate_selected(path: String)

const ACTION_BACK_TO_FLOATING := &"BACK_TO_FLOATING"
const ACTION_HIDE := &"HIDE"
const ACTION_QUIT := &"QUIT"
const ACTION_TOGGLE_FOCUS := &"TOGGLE_FOCUS"
const ACTION_TOGGLE_PASSTHROUGH := &"TOGGLE_PASSTHROUGH"
const ACTION_CREATE_NEW_SAVE := &"CREATE_NEW_SAVE"

const BACKGROUND_COLOR := Color(0.11, 0.12, 0.14, 1.0)
const TEXT_COLOR := Color(0.92, 0.93, 0.95, 1.0)

var _diagnostics: Label
var _mode_error: Label
var _recovery_box: VBoxContainer
var _recovery_label: Label
var _recovery_buttons: VBoxContainer


func _ready() -> void:
	name = "FullPanel"
	_build_ui()
	visible = false
	# 布局说明（复验 §5）：本节点是纯 Node 的子节点，没有 Control 父级可提供矩形，
	# 因此尺寸由场景里的 full-rect 锚点 + 视口决定。前提是 project.godot 关闭了
	# canvas_items 拉伸（否则 UI 画布只有 384×256，按钮会被压行并裁掉）。
	# 锚点已是不等对角（0→1），引擎会在 _ready() 后自动覆盖 size，
	# 这里不再手动赋值（否则触发 "size overridden after _ready" 告警）。
	if size == Vector2.ZERO:
		push_warning("FullPanel: 尺寸为 0，检查锚点与 stretch 配置")


## 显示模式切换失败原因（P0-006：平台拒绝隐藏不能静默）
func show_mode_error(detail: String) -> void:
	if _mode_error == null:
		return
	_mode_error.text = "模式切换失败：%s" % detail
	_mode_error.visible = detail != ""


## 布局（P0-005 附带修复）：FULL 窗口 960×640，诊断文本为多行长句，
## 原先直接堆在 VBox 里会把按钮行挤出可视区（被裁切）。
## 现在：标题 + 可滚动的诊断区（占满剩余高度）+ 固定在底部的按钮行与恢复区。
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(PRESET_FULL_RECT)
	bg.color = BACKGROUND_COLOR
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 8)
	root_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(root_box)

	var title := Label.new()
	title.text = "MOTE（P0 原型）"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", TEXT_COLOR)
	root_box.add_child(title)

	# 模式切换失败提示（默认隐藏）：平台拒绝隐藏时用户必须看得见
	_mode_error = Label.new()
	_mode_error.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45, 1.0))
	_mode_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_error.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_error.text = ""
	_mode_error.visible = false
	root_box.add_child(_mode_error)

	# 诊断区：撑满剩余空间并允许滚动，长文本不再把下方控件顶出窗口
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 给一个最小高度，避免在空间不足时整块塌成 0（复验 §5 实测到 height=0）
	scroll.custom_minimum_size = Vector2(0, 120)
	root_box.add_child(scroll)

	_diagnostics = Label.new()
	_diagnostics.add_theme_color_override("font_color", TEXT_COLOR)
	_diagnostics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diagnostics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diagnostics.text = "诊断信息加载中……"
	scroll.add_child(_diagnostics)

	# 用 HFlowContainer 而非 HBoxContainer：窗口变窄时按钮自动换行，
	# 而不是把最右侧的“退出”挤出可视区（复验 §5 观察到的裁切）。
	var button_row := HFlowContainer.new()
	button_row.add_theme_constant_override("h_separation", 8)
	button_row.add_theme_constant_override("v_separation", 6)
	button_row.size_flags_vertical = Control.SIZE_SHRINK_END
	for entry: Array in [
		["返回悬浮", ACTION_BACK_TO_FLOATING],
		["隐藏宠物", ACTION_HIDE],
		["专注模式", ACTION_TOGGLE_FOCUS],
		["穿透开关", ACTION_TOGGLE_PASSTHROUGH],
		["保存", &"SAVE_NOW"],
		["退出", ACTION_QUIT],
	]:
		var button := Button.new()
		button.text = str(entry[0])
		var action := StringName(str(entry[1]))
		button.pressed.connect(func() -> void: action_requested.emit(action))
		button_row.add_child(button)
	root_box.add_child(button_row)

	_recovery_box = VBoxContainer.new()
	_recovery_box.add_theme_constant_override("separation", 6)
	_recovery_box.visible = false
	_recovery_box.size_flags_vertical = Control.SIZE_SHRINK_END
	_recovery_label = Label.new()
	_recovery_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.36, 1.0))
	_recovery_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_recovery_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recovery_label.text = ""
	_recovery_box.add_child(_recovery_label)
	_recovery_buttons = VBoxContainer.new()
	_recovery_box.add_child(_recovery_buttons)
	var new_button := Button.new()
	new_button.text = "明确新建存档（先隔离现有文件）"
	new_button.pressed.connect(func() -> void: action_requested.emit(ACTION_CREATE_NEW_SAVE))
	_recovery_box.add_child(new_button)
	root_box.add_child(_recovery_box)


## 由 AppController 在 tick 边界调用，展示只读诊断（架构 §8）。
func update_diagnostics(info: Dictionary) -> void:
	if _diagnostics == null:
		return
	var needs: Dictionary = info.get("needs", {}) as Dictionary
	_diagnostics.text = (
		"需求：energy %.2f｜hunger %.2f｜comfort %.2f｜social %.2f\n" % [
			float(needs.get("energy", 0.0)), float(needs.get("hunger", 0.0)),
			float(needs.get("comfort", 0.0)), float(needs.get("social_need", 0.0)),
		]
		+ "当前动作：%s（累计模拟 %.1f 秒）\n" % [info.get("current_action", ""), float(info.get("simulation_elapsed_seconds", 0.0))]
		+ "窗口：%s / 鼠标：%s\n" % [info.get("mode", ""), info.get("mouse_mode", "")]
		+ "恢复入口：%s（%s）\n" % [info.get("recovery_kind", ""), info.get("recovery_status", "")]
		+ "存档：revision %d｜%s\n" % [int(info.get("revision", 0)), info.get("save_path", "")]
		+ "保存状态：%s" % info.get("save_status", "")
	)


## 显示存档恢复界面（主档损坏/候选恢复/未知版本等），列出通过校验的候选。
func show_recovery(message: String, candidates: Array) -> void:
	if _recovery_box == null:
		return
	_recovery_box.visible = true
	_recovery_label.text = message
	for child: Node in _recovery_buttons.get_children():
		_recovery_buttons.remove_child(child)
		child.queue_free()
	for candidate: Dictionary in candidates:
		var path: String = str(candidate.get("path", ""))
		var button := Button.new()
		button.text = "恢复候选：%s（revision %d，%s）" % [
			path.get_file(), int(candidate.get("revision", 0)), str(candidate.get("saved_at", "")),
		]
		button.pressed.connect(func() -> void: candidate_selected.emit(path))
		_recovery_buttons.add_child(button)


func hide_recovery() -> void:
	if _recovery_box != null:
		_recovery_box.visible = false
