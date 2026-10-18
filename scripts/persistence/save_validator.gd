class_name SaveValidator
extends RefCounted
## 存档 v1 结构与取值校验（架构 §6.1 / §7.2）。
## 纯函数模块：不访问磁盘、时钟、Node 或网络，便于隔离测试与故障注入。
##
## 重要原则（架构 §7.2）：校验失败一律拒绝该候选，不得静默夹取后覆盖；
## 运行时公式夹取与外部数据验证是两件事。未知更高 schema 必须整档拒绝。

const SCHEMA_VERSION := 1

const STATUS_OK := &"OK"
const STATUS_MISSING := &"MISSING"
const STATUS_RECOVERABLE := &"RECOVERABLE"
const STATUS_INVALID := &"INVALID"
const STATUS_UNSUPPORTED_VERSION := &"UNSUPPORTED_VERSION"
const STATUS_IO_ERROR := &"IO_ERROR"

const KEY_SCHEMA_VERSION := "schema_version"
const KEY_SAVE_ID := "save_id"
const KEY_REVISION := "revision"
const KEY_SAVED_AT := "saved_at"
const KEY_PET := "pet"
const KEY_SETTINGS := "settings"
const KEY_MEMORY := "memory"
const KEY_SYNC := "sync"

const NEED_KEYS: Array[String] = ["energy", "hunger", "comfort", "social_need"]
const PERSONALITY_KEYS: Array[String] = ["curiosity", "activity", "sociability", "courage"]
const ATTRIBUTE_KEYS: Array[String] = ["knowledge", "stamina", "creativity", "charm"]


## UTC ISO 8601 字符串（秒精度，Z 后缀）
static func utc_now() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"


static func is_integer(value: Variant) -> bool:
	if value is int:
		return true
	if value is float:
		return is_equal_approx(value as float, roundf(value as float))
	return false


static func as_int(value: Variant) -> int:
	return int(roundf(float(value)))


static func is_number(value: Variant) -> bool:
	return value is int or value is float


static func is_finite_number(value: Variant) -> bool:
	if not is_number(value):
		return false
	return is_finite(float(value))


## 顶层 schema 判定。返回 OK / UNSUPPORTED_VERSION / INVALID。
## 未知更高版本必须整档拒绝，不能按 v1 强行解析后覆盖。
static func classify_schema_version(data: Dictionary) -> StringName:
	if not data.has(KEY_SCHEMA_VERSION):
		return STATUS_INVALID
	var raw: Variant = data[KEY_SCHEMA_VERSION]
	if not is_integer(raw):
		return STATUS_INVALID
	var version := as_int(raw)
	if version < 1:
		return STATUS_INVALID
	if version > SCHEMA_VERSION:
		return STATUS_UNSUPPORTED_VERSION
	return STATUS_OK


## 校验封装层（不含 pet/settings 内部）
static func validate_wrapper(data: Dictionary) -> String:
	if not data.has_all([KEY_SCHEMA_VERSION, KEY_SAVE_ID, KEY_REVISION, KEY_SAVED_AT, KEY_PET, KEY_SETTINGS]):
		return "封装缺少必填字段"
	if not is_integer(data[KEY_SCHEMA_VERSION]) or as_int(data[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION:
		return "封装 schema_version 非法"
	if not data[KEY_SAVE_ID] is String or str(data[KEY_SAVE_ID]).is_empty():
		return "save_id 必须为非空字符串"
	if not is_integer(data[KEY_REVISION]) or as_int(data[KEY_REVISION]) < 1:
		return "revision 必须为从 1 开始的正整数"
	if not data[KEY_SAVED_AT] is String or str(data[KEY_SAVED_AT]).is_empty():
		return "saved_at 必须为非空字符串"
	if not data[KEY_PET] is Dictionary:
		return "pet 必须为对象"
	if not data[KEY_SETTINGS] is Dictionary:
		return "settings 必须为对象"
	if data.has(KEY_MEMORY) and not data[KEY_MEMORY] is Dictionary:
		return "memory 必须为对象"
	if data.has(KEY_SYNC) and not data[KEY_SYNC] is Dictionary:
		return "sync 必须为对象"
	return ""


static func validate_pet(data: Dictionary) -> String:
	if not is_integer(data.get(KEY_SCHEMA_VERSION, -1)) or as_int(data.get(KEY_SCHEMA_VERSION, -1)) != SCHEMA_VERSION:
		return "pet.schema_version 非法"
	if not data.get("pet_id", "") is String or str(data.get("pet_id", "")).is_empty():
		return "pet_id 必须为非空字符串"
	if not data.get("display_name", "") is String:
		return "display_name 必须为字符串"
	for key: String in ["created_at", "updated_at", "last_simulated_at"]:
		if data.has(key) and not data[key] is String:
			return "%s 必须为字符串" % key

	var needs: Variant = data.get("needs")
	if not needs is Dictionary:
		return "needs 必须为对象"
	var needs_dict := needs as Dictionary
	for key: String in NEED_KEYS:
		if not needs_dict.has(key) or not is_finite_number(needs_dict[key]):
			return "needs.%s 缺失或非有限数值" % key
		var value: float = float(needs_dict[key])
		if value < PetState.NEED_MIN or value > PetState.NEED_MAX:
			return "needs.%s 越界: %f" % [key, value]

	var personality: Variant = data.get("personality")
	if not personality is Dictionary:
		return "personality 必须为对象"
	var personality_dict := personality as Dictionary
	for key: String in PERSONALITY_KEYS:
		if not personality_dict.has(key) or not is_finite_number(personality_dict[key]):
			return "personality.%s 缺失或非有限数值" % key
		var pvalue: float = float(personality_dict[key])
		if pvalue < PetState.PERSONALITY_MIN or pvalue > PetState.PERSONALITY_MAX:
			return "personality.%s 越界: %f" % [key, pvalue]

	var attributes: Variant = data.get("attributes")
	if not attributes is Dictionary:
		return "attributes 必须为对象"
	var attributes_dict := attributes as Dictionary
	for key: String in ATTRIBUTE_KEYS:
		if not attributes_dict.has(key) or not is_finite_number(attributes_dict[key]):
			return "attributes.%s 缺失或非有限数值" % key
		if float(attributes_dict[key]) < 0.0:
			return "attributes.%s 为负数" % key

	var action := StringName(str(data.get("current_action", "")))
	if not PetState.ALLOWED_ACTIONS.has(action):
		return "current_action 不在允许列表: %s" % data.get("current_action", "")

	var elapsed: Variant = data.get("simulation_elapsed_seconds", 0.0)
	if not is_finite_number(elapsed) or float(elapsed) < 0.0:
		return "simulation_elapsed_seconds 必须为有限非负数"
	return ""


static func validate_settings(data: Dictionary) -> String:
	var mode := StringName(str(data.get("mode", "")))
	if not AppMode.is_valid_mode(mode):
		return "settings.mode 非法: %s" % data.get("mode", "")
	var mouse := StringName(str(data.get("mouse_preference", "")))
	if not AppMode.is_valid_mouse(mouse):
		return "settings.mouse_preference 非法: %s" % data.get("mouse_preference", "")

	var previous := StringName(str(data.get("previous_visible_mode", "")))
	if not AppMode.is_valid_mode(previous) or previous == AppMode.HIDDEN:
		return "settings.previous_visible_mode 必须为可见模式: %s" % data.get("previous_visible_mode", "")

	var focus_return := StringName(str(data.get("focus_return_mode", "")))
	if focus_return != AppMode.FLOATING and focus_return != AppMode.FULL:
		return "settings.focus_return_mode 仅允许 FLOATING/FULL: %s" % data.get("focus_return_mode", "")

	var focus_mouse := StringName(str(data.get("focus_return_mouse", "")))
	if not AppMode.is_valid_mouse(focus_mouse):
		return "settings.focus_return_mouse 非法: %s" % data.get("focus_return_mouse", "")

	var notifications: Variant = data.get("notifications_enabled", false)
	if not notifications is bool:
		return "settings.notifications_enabled 必须为布尔"

	for key: String in ["floating_rect", "full_rect"]:
		var rect_err := _validate_rect(data.get(key), key)
		if rect_err != "":
			return rect_err

	var hint: Variant = data.get("screen_hint")
	if hint != null and not hint is Dictionary:
		return "settings.screen_hint 必须为对象或 null"
	if hint is Dictionary:
		var hint_dict := hint as Dictionary
		if not is_integer(hint_dict.get("index", -1)) or as_int(hint_dict.get("index", -1)) < 0:
			return "screen_hint.index 必须为非负整数"
		var usable_err := _validate_rect(hint_dict.get("usable_rect"), "screen_hint.usable_rect")
		if usable_err != "":
			return usable_err
		var resolution: Variant = hint_dict.get("resolution")
		if resolution is Dictionary:
			var res_dict := resolution as Dictionary
			for rkey: String in ["w", "h"]:
				if not is_integer(res_dict.get(rkey, 0)) or as_int(res_dict.get(rkey, 0)) <= 0:
					return "screen_hint.resolution.%s 必须为正整数" % rkey
		var scale: Variant = hint_dict.get("scale")
		if scale != null and not is_finite_number(scale):
			return "screen_hint.scale 必须为有限数值或 null"
	return ""


## 窗口矩形：宽高必须为正整数；位置允许负整数（架构 §6.1：不得强行限制非负）
static func _validate_rect(value: Variant, label: String) -> String:
	if not value is Dictionary:
		return "%s 必须为对象" % label
	var rect := value as Dictionary
	for key: String in ["x", "y", "w", "h"]:
		if not rect.has(key) or not is_integer(rect[key]):
			return "%s.%s 必须为整数" % [label, key]
	if as_int(rect["w"]) <= 0 or as_int(rect["h"]) <= 0:
		return "%s 宽高必须为正整数" % label
	return ""


## 整档校验（封装 + pet + settings）。返回空串表示通过。
static func validate_snapshot(data: Dictionary) -> String:
	var version_status: StringName = classify_schema_version(data)
	if version_status == STATUS_UNSUPPORTED_VERSION:
		return "未知更高 schema_version: %s" % data.get(KEY_SCHEMA_VERSION, "?")
	if version_status == STATUS_INVALID:
		return "schema_version 非法"
	var wrapper_err := validate_wrapper(data)
	if wrapper_err != "":
		return wrapper_err
	var pet_err := validate_pet(data[KEY_PET] as Dictionary)
	if pet_err != "":
		return pet_err
	var settings_err := validate_settings(data[KEY_SETTINGS] as Dictionary)
	if settings_err != "":
		return settings_err
	return ""


## —— 默认档构造 ——

static func make_default_pet(now_utc: String) -> Dictionary:
	var state := PetState.new()
	state.pet_id = _new_pet_id()
	state.created_at = now_utc
	state.updated_at = now_utc
	state.last_simulated_at = now_utc
	state.current_action = PetState.ACTION_IDLE
	return state.to_dictionary()


static func make_default_settings() -> Dictionary:
	return {
		"mode": String(AppMode.FLOATING),
		"mouse_preference": String(AppMode.MOUSE_INTERACTIVE),
		"previous_visible_mode": String(AppMode.FLOATING),
		"focus_return_mode": String(AppMode.FLOATING),
		"focus_return_mouse": String(AppMode.MOUSE_INTERACTIVE),
		"notifications_enabled": false,
		"floating_rect": {"x": 100, "y": 100, "w": 256, "h": 256},
		"full_rect": {"x": 100, "y": 100, "w": 960, "h": 640},
		"screen_hint": {
			"index": 0,
			"usable_rect": {"x": 0, "y": 0, "w": 1920, "h": 1040},
			"resolution": {"w": 1920, "h": 1080},
			"scale": null,
		},
	}


static func make_default_wrapper(now_utc: String) -> Dictionary:
	return {
		KEY_SCHEMA_VERSION: SCHEMA_VERSION,
		KEY_SAVE_ID: _new_save_id(),
		KEY_REVISION: 1,
		KEY_SAVED_AT: now_utc,
		KEY_PET: make_default_pet(now_utc),
		KEY_SETTINGS: make_default_settings(),
		KEY_MEMORY: {},
		KEY_SYNC: {"enabled": false},
	}


static func _new_pet_id() -> String:
	return "pet-%s" % _random_token()


static func _new_save_id() -> String:
	return "local-save-%s" % _random_token()


## 生成新标识用的随机片段（pet_id / save_id 共用）
static func new_random_token() -> String:
	var raw := "%d-%d" % [Time.get_unix_time_from_system(), randi() % 1000000]
	return raw.sha256_text().substr(0, 12)


static func _random_token() -> String:
	return new_random_token()


## 版本迁移分派（架构 §7.2）：P0 只有 v1，不支持的版本明确拒绝。
## 返回 {ok: bool, data: Dictionary, error: String}
static func migrate(from_version: int, data: Dictionary) -> Dictionary:
	if from_version == SCHEMA_VERSION:
		return {"ok": true, "data": data, "error": ""}
	return {
		"ok": false,
		"data": {},
		"error": "不支持从 schema v%d 迁移到 v%d（P0 仅支持 v%d）" % [from_version, SCHEMA_VERSION, SCHEMA_VERSION],
	}


## 恢复成功后统一处理：current_action 回到 idle（架构 §7.2）；
## 不恢复鼠标按下、位移动量、动画位置与奖励待发队列（这些本就不入档）。
static func normalize_loaded_snapshot(data: Dictionary) -> Dictionary:
	var copy: Dictionary = data.duplicate(true)
	var pet: Dictionary = (copy[KEY_PET] as Dictionary).duplicate(true)
	pet["current_action"] = String(PetState.ACTION_IDLE)
	copy[KEY_PET] = pet
	return copy
