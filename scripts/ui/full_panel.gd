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
var _recovery_box: VBoxContainer
var _recovery_label: Label
var _recovery_buttons: VBoxContainer


func _ready() -> void:
	name = "FullPanel"
	_build_ui()
	visible = false


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(PRESET_FULL_RECT)
	bg.color = BACKGROUND_COLOR
	add_child(bg)

	var root_box := VBoxContainer.new()
	root_box.set_anchors_preset(PRESET_FULL_RECT)
	root_box.add_theme_constant_override("separation", 8)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.add_child(root_box)
	add_child(margin)

	var title := Label.new()
	title.text = "MOTE（P0 原型）"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", TEXT_COLOR)
	root_box.add_child(title)

	_diagnostics = Label.new()
	_diagnostics.add_theme_color_override("font_color", TEXT_COLOR)
	_diagnostics.text = "诊断信息加载中……"
	root_box.add_child(_diagnostics)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 8)
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
	_recovery_label = Label.new()
	_recovery_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.36, 1.0))
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
