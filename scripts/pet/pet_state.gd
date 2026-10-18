class_name PetState
extends RefCounted
## 宠物的核心数据载体（架构 §6.1）。
## 仅作为数据存储：不访问 Node、时钟、磁盘或网络；修改只能通过 PetSimulation。

# —— 常量：允许的动作与固定需求基线（架构 §5.2）——
const ACTION_IDLE := &"idle"
const ACTION_WALK := &"walk"
const ACTION_REST := &"rest"
const ACTION_LOOK_AROUND := &"look_around"
const ACTION_REACT_HAPPY := &"react_happy"
const ALLOWED_ACTIONS: Array[StringName] = [
	ACTION_IDLE, ACTION_WALK, ACTION_REST, ACTION_LOOK_AROUND, ACTION_REACT_HAPPY,
]

const NEED_MIN := 0.0
const NEED_MAX := 100.0
const PERSONALITY_MIN := 0.0
const PERSONALITY_MAX := 1.0

## 结构版本；v1 与封装 schema_version 相同（架构 §6.1）
const SCHEMA_VERSION := 1

var schema_version: int = SCHEMA_VERSION
var pet_id: String = ""
var display_name: String = "MOTE"
var created_at: String = ""
var updated_at: String = ""
var needs: Dictionary = {}
var personality: Dictionary = {}
var attributes: Dictionary = {}
var current_action: StringName = ACTION_IDLE
var simulation_elapsed_seconds: float = 0.0
var last_simulated_at: String = ""


func _init() -> void:
	reset_defaults()


## 重置为默认状态（架构 §6.1：needs 80/20/80/20，personality 四项 0.5）
func reset_defaults() -> void:
	schema_version = SCHEMA_VERSION
	pet_id = ""
	display_name = "MOTE"
	created_at = ""
	updated_at = ""
	needs = {
		"energy": 80.0,
		"hunger": 20.0,
		"comfort": 80.0,
		"social_need": 20.0,
	}
	personality = {
		"curiosity": 0.5,
		"activity": 0.5,
		"sociability": 0.5,
		"courage": 0.5,
	}
	attributes = {
		"knowledge": 0,
		"stamina": 0,
		"creativity": 0,
		"charm": 0,
	}
	current_action = ACTION_IDLE
	simulation_elapsed_seconds = 0.0
	last_simulated_at = ""


## 返回一个与内部状态无关的深拷贝（后续快照序列化用）。
## 注意：只拷贝 JSON 原生类型，供 PetSimulation.get_snapshot() 使用。
func to_dictionary() -> Dictionary:
	return {
		"schema_version": schema_version,
		"pet_id": pet_id,
		"display_name": display_name,
		"created_at": created_at,
		"updated_at": updated_at,
		"needs": needs.duplicate(true),
		"personality": personality.duplicate(true),
		"attributes": attributes.duplicate(true),
		"current_action": String(current_action),
		"simulation_elapsed_seconds": simulation_elapsed_seconds,
		"last_simulated_at": last_simulated_at,
	}


## 从合法 Dictionary 恢复（仅用于测试/存档加载；调用方负责校验）。
func from_dictionary(data: Dictionary) -> void:
	schema_version = int(data.get("schema_version", SCHEMA_VERSION))
	pet_id = str(data.get("pet_id", ""))
	display_name = str(data.get("display_name", "MOTE"))
	created_at = str(data.get("created_at", ""))
	updated_at = str(data.get("updated_at", ""))
	needs = (data.get("needs", {}) as Dictionary).duplicate(true)
	personality = (data.get("personality", {}) as Dictionary).duplicate(true)
	attributes = (data.get("attributes", {}) as Dictionary).duplicate(true)
	var act: String = str(data.get("current_action", "idle"))
	current_action = StringName(act)
	simulation_elapsed_seconds = float(data.get("simulation_elapsed_seconds", 0.0))
	last_simulated_at = str(data.get("last_simulated_at", ""))


## 验证是否构成一个合法 PetState（不夹取、不静默修复，返回错误原因）。
## 供 SaveService v1 校验与单元测试使用。
static func validate_state(state: PetState) -> String:
	if state.pet_id.is_empty():
		return "pet_id 为空"
	if not state.needs.has_all(["energy", "hunger", "comfort", "social_need"]):
		return "needs 缺少必需键"
	for key: String in ["energy", "hunger", "comfort", "social_need"]:
		var value: Variant = state.needs[key]
		if not value is float and not value is int:
			return "needs.%s 非数值" % key
		var num: float = float(value)
		if not is_finite(num) or num < NEED_MIN or num > NEED_MAX:
			return "needs.%s 越界或非有限" % key
	for key: String in ["curiosity", "activity", "sociability", "courage"]:
		if not state.personality.has(key):
			return "personality 缺少键 %s" % key
		var num: float = float(state.personality[key])
		if not is_finite(num) or num < PERSONALITY_MIN or num > PERSONALITY_MAX:
			return "personality.%s 越界或非有限" % key
	if not state.attributes.has_all(["knowledge", "stamina", "creativity", "charm"]):
		return "attributes 缺少必需键"
	if not ALLOWED_ACTIONS.has(state.current_action):
		return "current_action 不在允许列表"
	if state.simulation_elapsed_seconds < 0.0 or not is_finite(state.simulation_elapsed_seconds):
		return "simulation_elapsed_seconds 非法"
	return ""
