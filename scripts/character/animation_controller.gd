class_name AnimationController
extends Node2D
## 行为到动画映射、朝向、骨骼表现与播放完成通知（架构 §6.2）。
## 不修改 PetState、不发放奖励；表情可为无操作实现。
##
## 说明：Godot 4.x 已无 Animation.TYPE_ROTATION（改名 TYPE_ROTATION_3D，仅适用 Node3D）。
## 2D 骨骼动画使用 TYPE_VALUE 属性轨道，路径为 "<节点路径>:rotation"，键值单位为弧度。
## 四种动画在 _ready() 中以代码构建，便于版本控制与自动化校验；若后续改为编辑器手工动画，
## 只需保留同名 idle/walk/rest/happy 动画即可，映射表无需改动。

signal animation_completed(anim_name: StringName)

## 行为 → 动画映射（架构 §5.2 表：look_around 复用 idle，无第五动画硬要求）
const ACTION_TO_ANIM: Dictionary = {
	PetState.ACTION_IDLE: &"idle",
	PetState.ACTION_WALK: &"walk",
	PetState.ACTION_REST: &"rest",
	PetState.ACTION_LOOK_AROUND: &"idle",
	PetState.ACTION_REACT_HAPPY: &"happy",
}

const BONE_BODY := "Skeleton2D/Root/Body"
const BONE_HEAD := "Skeleton2D/Root/Body/Head"
const BONE_ARM_L := "Skeleton2D/Root/Body/ArmLeft"
const BONE_ARM_R := "Skeleton2D/Root/Body/ArmRight"

@onready var _player: AnimationPlayer = $AnimationPlayer
@onready var _skeleton: Skeleton2D = $Skeleton2D

var _current_anim: StringName = &""
var _finished: bool = false
var _facing: int = 1
var _library: AnimationLibrary


func _ready() -> void:
	if _player == null:
		push_error("AnimationController: 缺少 AnimationPlayer 子节点")
		return
	_ensure_default_library()
	_build_animations()
	_player.animation_finished.connect(_on_animation_finished)
	play_action(PetState.ACTION_IDLE)


func get_current_anim() -> StringName:
	return _current_anim


## 播放行为对应动画。返回是否成功（资源缺失/无动画时返回 false）。
func play_action(action: StringName) -> bool:
	if _player == null:
		return false
	var anim_name: StringName = ACTION_TO_ANIM.get(action, &"idle") as StringName
	if not _player.has_animation(anim_name):
		push_warning("AnimationController: 缺少动画 %s" % anim_name)
		return false
	_finished = false
	_player.play(anim_name)
	_current_anim = anim_name
	return true


## 设置朝向（1 右 / -1 左）
func set_facing(direction: int) -> void:
	_facing = 1 if direction >= 0 else -1
	if _skeleton != null:
		_skeleton.scale = Vector2(float(_facing), 1.0)


func get_facing() -> int:
	return _facing


## 表情：P0 可为无操作实现（架构 §6.2）
func set_expression(_id: StringName) -> void:
	pass


## 单次动画是否播放完成（循环动画恒为 false 时由模拟侧决定结束）
func is_action_finished() -> bool:
	return _finished


func _on_animation_finished(anim_name: StringName) -> void:
	_finished = true
	animation_completed.emit(anim_name)


func _ensure_default_library() -> void:
	# Godot 4：动画归属于 AnimationLibrary，AnimationPlayer 不再有 add_animation()
	if not _player.has_animation_library(""):
		_player.add_animation_library("", AnimationLibrary.new())
	_library = _player.get_animation_library("")


func _build_animations() -> void:
	if _library == null:
		push_error("AnimationController: 默认动画库不可用")
		return
	# idle：轻微呼吸起伏（循环）
	_library.add_animation(&"idle", _make_anim(&"idle", 2.0, true, {
		BONE_BODY: [0.0, 0.0, 1.0, 0.05, 2.0, 0.0],
		BONE_HEAD: [0.0, 0.0, 1.0, -0.04, 2.0, 0.0],
		BONE_ARM_L: [0.0, 0.0, 1.0, 0.08, 2.0, 0.0],
		BONE_ARM_R: [0.0, 0.0, 1.0, -0.08, 2.0, 0.0],
	}))
	# walk：手臂与身体摆动（循环）
	_library.add_animation(&"walk", _make_anim(&"walk", 0.8, true, {
		BONE_BODY: [0.0, -0.06, 0.4, 0.06, 0.8, -0.06],
		BONE_ARM_L: [0.0, 0.5, 0.4, -0.5, 0.8, 0.5],
		BONE_ARM_R: [0.0, -0.5, 0.4, 0.5, 0.8, -0.5],
		BONE_HEAD: [0.0, 0.02, 0.4, -0.02, 0.8, 0.02],
	}))
	# rest：蹲伏静止（循环）
	_library.add_animation(&"rest", _make_anim(&"rest", 3.0, true, {
		BONE_BODY: [0.0, 0.18, 3.0, 0.18],
		BONE_HEAD: [0.0, 0.12, 3.0, 0.12],
		BONE_ARM_L: [0.0, -0.25, 3.0, -0.25],
		BONE_ARM_R: [0.0, 0.25, 3.0, 0.25],
	}))
	# happy：跳跃一次（单次播放）
	_library.add_animation(&"happy", _make_anim(&"happy", 1.0, false, {
		BONE_BODY: [0.0, 0.0, 0.3, -0.25, 0.6, 0.1, 1.0, 0.0],
		BONE_HEAD: [0.0, 0.0, 0.3, -0.15, 0.6, 0.08, 1.0, 0.0],
		BONE_ARM_L: [0.0, 0.0, 0.3, -0.9, 0.6, 0.2, 1.0, 0.0],
		BONE_ARM_R: [0.0, 0.0, 0.3, 0.9, 0.6, -0.2, 1.0, 0.0],
	}))


## keys: 骨骼节点路径 -> [time, radians, time, radians, ...]（弧度）
func _make_anim(anim_name: StringName, length: float, loop: bool, keys: Dictionary) -> Animation:
	var anim := Animation.new()
	anim.resource_name = String(anim_name)
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	for path: String in keys:
		var track: int = anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track, NodePath("%s:rotation" % path))
		var values: Array = keys[path] as Array
		for i: int in range(0, values.size(), 2):
			anim.track_insert_key(track, float(values[i]), float(values[i + 1]))
	return anim
