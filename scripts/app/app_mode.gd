class_name AppMode
extends RefCounted
## 应用模式枚举（架构 §4）。注意：AppMode 不等同于 Godot Window.Mode；
## 本文 FULL 指完整功能的普通窗口，不表示独占全屏。

const FLOATING := &"FLOATING"
const FULL := &"FULL"
const FOCUS := &"FOCUS"
const HIDDEN := &"HIDDEN"

const ALL: Array[StringName] = [FLOATING, FULL, FOCUS, HIDDEN]


## 鼠标模式（架构 §4）：INTERACTIVE 整窗交互；PASSTHROUGH 整窗穿透
const MOUSE_INTERACTIVE := &"INTERACTIVE"
const MOUSE_PASSTHROUGH := &"PASSTHROUGH"


static func is_valid_mode(mode: StringName) -> bool:
	return ALL.has(mode)


static func is_valid_mouse(mouse: StringName) -> bool:
	return mouse == MOUSE_INTERACTIVE or mouse == MOUSE_PASSTHROUGH


## FLOATING/FULL 是可见模式；FOCUS 也是可见的（安静桌宠）；HIDDEN 不可见
static func is_visible(mode: StringName) -> bool:
	return mode == FLOATING or mode == FULL or mode == FOCUS
