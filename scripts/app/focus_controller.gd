class_name FocusController
extends RefCounted
## 交互与免打扰策略（架构 §4）：根据模式返回策略字典。
## 纯规则，不持有窗口/模拟引用；WindowController 消费策略。

## 返回 {allow_focus, allow_popup, allow_sound, can_walk, mouse_mode}
func get_policy(mode: StringName) -> Dictionary:
	match mode:
		AppMode.FLOATING:
			return {
				"allow_focus": false,
				"allow_popup": true,
				"allow_sound": true,
				"can_walk": true,
				"mouse_mode": AppMode.MOUSE_INTERACTIVE,
			}
		AppMode.FULL:
			return {
				"allow_focus": true,
				"allow_popup": true,
				"allow_sound": true,
				"can_walk": false,  # 完整窗口内 walk 限制在宠物显示区域
				"mouse_mode": AppMode.MOUSE_INTERACTIVE,
			}
		AppMode.FOCUS:
			return {
				"allow_focus": false,
				"allow_popup": false,
				"allow_sound": false,
				"can_walk": false,  # 专注中暂停自主窗口位移
				"mouse_mode": AppMode.MOUSE_PASSTHROUGH,
			}
		AppMode.HIDDEN:
			return {
				"allow_focus": false,
				"allow_popup": false,
				"allow_sound": false,
				"can_walk": false,
				"mouse_mode": AppMode.MOUSE_PASSTHROUGH,
			}
		_:
			push_warning("FocusController: 未知模式 %s，返回 FLOATING 策略" % mode)
			return get_policy(AppMode.FLOATING)
