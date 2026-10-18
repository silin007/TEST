extends SceneTree
## 存档自动测试：SAVE-01（往返/身份/设置）、SAVE-03（主档损坏＋备份恢复）、
## SAVE-04（全部候选损坏）、SAVE-05（提交中断）、SAVE-06（故障注入）、
## SAVE-07（结构/范围/未知版本）。
## 运行：Godot --headless --path . --script res://tests/unit/test_save.gd
##
## 测试隔离（报告 §4）：入口即把存档重定向到 user://test_sandbox/save/，
## 本套件会清空目录，绝不允许作用在真实 user://saves/ 上。

const MAIN_FILE := "user://test_sandbox/save/saves/save.json"
const BAK_FILE := "user://test_sandbox/save/saves/save.bak.json"
const TMP_FILE := "user://test_sandbox/save/saves/save.tmp.json"

var _failures: Array[String] = []
var _ran: bool = false


func _initialize() -> void:
	SaveService.use_sandbox("user://test_sandbox/save")


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_all()
	if _failures.is_empty():
		print("ALL SAVE TESTS PASSED")
		quit(0)
	else:
		print("FAILURES (%d):" % _failures.size())
		for f: String in _failures:
			print("  - ", f)
		quit(1)
	return false


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS ", label)
	else:
		print("FAIL ", label)
		_failures.append(label)


func _note(expected: String) -> void:
	print("  [注] 接下来若出现 ERROR / WARNING 属预期：", expected)


func _run_all() -> void:
	test_roundtrip_and_identity()
	test_missing_is_first_run()
	test_validator_rejects_invalid()
	test_invalid_snapshot_not_written()
	test_unsupported_version_readonly()
	test_main_corrupt_with_valid_backup()
	test_all_candidates_corrupt()
	test_unsupported_version_survives_autosave_chain()
	test_missing_main_with_candidate_not_first_run()
	test_fault_injection_stages()
	test_migrate_dispatch()
	var svc := SaveService.new()
	svc.clear_all_for_test()


## —— SAVE-01 ——

func test_roundtrip_and_identity() -> void:
	var svc := SaveService.new()
	svc.clear_all_for_test()
	var snapshot := _make_snapshot()
	var pet_id: String = str((snapshot["pet"] as Dictionary)["pet_id"])
	var created_at: String = str((snapshot["pet"] as Dictionary)["created_at"])

	_check(svc.save_snapshot(snapshot) == OK, "SAVE-01 首次保存成功")
	_check(svc.get_revision() == 1, "SAVE-01 首次 revision=1，实际=%d" % svc.get_revision())
	var save_id: String = svc.get_save_id()

	var second: Dictionary = _make_snapshot()
	second["save_id"] = save_id
	# 同一只宠物：第二次提交沿用同一 pet_id（ID 首次创建后稳定）
	(second["pet"] as Dictionary)["pet_id"] = pet_id
	_check(svc.save_snapshot(second) == OK, "SAVE-01 第二次保存成功")
	_check(svc.get_revision() == 2, "SAVE-01 每次提交 revision+1，实际=%d" % svc.get_revision())
	_check(svc.get_save_id() == save_id, "SAVE-01 save_id 保持不变")

	var result: Dictionary = SaveService.new().load_snapshot()
	_check(result["status"] == SaveValidator.STATUS_OK, "SAVE-01 加载状态 OK，实际=%s" % result["status"])
	var loaded: Dictionary = result["snapshot"] as Dictionary
	var loaded_pet: Dictionary = loaded["pet"] as Dictionary
	_check(str(loaded_pet["pet_id"]) == pet_id, "SAVE-01 pet_id 恢复")
	_check(str(loaded_pet["created_at"]) == created_at,
		"SAVE-01 created_at 不因加载改变（期望 %s 实际 %s）" % [created_at, str(loaded_pet["created_at"])])
	_check(is_equal_approx(float((loaded_pet["needs"] as Dictionary)["energy"]), 62.5),
		"SAVE-01 needs.energy 往返一致")
	_check(is_equal_approx(float((loaded_pet["needs"] as Dictionary)["hunger"]), 33.25),
		"SAVE-01 needs.hunger 往返一致")
	_check(is_equal_approx(float((loaded_pet["personality"] as Dictionary)["curiosity"]), 0.75),
		"SAVE-01 personality 往返一致")
	_check(str(loaded_pet["current_action"]) == "idle", "SAVE-01 current_action 重启为 idle")
	_check((loaded["memory"] as Dictionary).is_empty(), "SAVE-01 memory={}")
	_check(bool((loaded["sync"] as Dictionary).get("enabled", true)) == false, "SAVE-01 sync.enabled=false")

	var settings: Dictionary = loaded["settings"] as Dictionary
	_check(str(settings["mode"]) == "FLOATING", "SAVE-01 settings.mode 恢复")
	var rect: Dictionary = settings["floating_rect"] as Dictionary
	_check(SaveValidator.as_int(rect["x"]) == -300 and SaveValidator.as_int(rect["w"]) == 256,
		"SAVE-01 负坐标矩形被接受且往返一致")
	_check(FileAccess.file_exists(BAK_FILE), "SAVE-01 提交后备份存在")
	_check(FileAccess.file_exists(MAIN_FILE), "SAVE-01 主档存在")


## —— SAVE-02 相关：只有真正缺档才是首次运行 ——

func test_missing_is_first_run() -> void:
	var svc := SaveService.new()
	svc.clear_all_for_test()
	var result: Dictionary = svc.load_snapshot()
	_check(result["status"] == SaveValidator.STATUS_MISSING,
		"SAVE-02 空目录返回 MISSING，实际=%s" % result["status"])
	_check((result["candidates"] as Array).is_empty(), "SAVE-02 无候选")


## —— SAVE-07：结构、范围、未知版本 ——

func test_validator_rejects_invalid() -> void:
	_check(SaveValidator.validate_pet(_pet_with("")) != "", "SAVE-07 拒绝缺少 pet_id")
	var needs_string := _valid_pet()
	(needs_string["needs"] as Dictionary)["energy"] = "80"
	_check(SaveValidator.validate_pet(needs_string) != "", "SAVE-07 拒绝 needs 为字符串")
	var out_of_range := _valid_pet()
	(out_of_range["needs"] as Dictionary)["comfort"] = 120.0
	_check(SaveValidator.validate_pet(out_of_range) != "", "SAVE-07 拒绝 needs 越界")
	var bad_action := _valid_pet()
	bad_action["current_action"] = "dance"
	_check(SaveValidator.validate_pet(bad_action) != "", "SAVE-07 拒绝非法动作枚举")
	var non_finite := _valid_pet()
	(non_finite["needs"] as Dictionary)["hunger"] = NAN
	_check(SaveValidator.validate_pet(non_finite) != "", "SAVE-07 拒绝非有限数值")
	_check(SaveValidator.validate_pet(_valid_pet()) == "", "SAVE-07 合法 pet 通过")

	var negative_rev := SaveValidator.make_default_wrapper(SaveValidator.utc_now())
	negative_rev["revision"] = 0
	_check(SaveValidator.validate_wrapper(negative_rev) != "", "SAVE-07 拒绝 revision<1")

	var zero_size := SaveValidator.make_default_settings()
	(zero_size["floating_rect"] as Dictionary)["w"] = 0
	_check(SaveValidator.validate_settings(zero_size) != "", "SAVE-07 拒绝宽高非正")

	var hidden_prev := SaveValidator.make_default_settings()
	hidden_prev["previous_visible_mode"] = "HIDDEN"
	_check(SaveValidator.validate_settings(hidden_prev) != "", "SAVE-07 拒绝 previous_visible_mode=HIDDEN")

	var bad_focus := SaveValidator.make_default_settings()
	bad_focus["focus_return_mode"] = "FOCUS"
	_check(SaveValidator.validate_settings(bad_focus) != "", "SAVE-07 拒绝 focus_return_mode=FOCUS")
	_check(SaveValidator.validate_settings(SaveValidator.make_default_settings()) == "",
		"SAVE-07 合法 settings 通过")


func test_invalid_snapshot_not_written() -> void:
	var svc := SaveService.new()
	svc.clear_all_for_test()
	var bad := _make_snapshot()
	(bad["pet"] as Dictionary)["needs"] = {"energy": 200.0, "hunger": 20.0, "comfort": 80.0, "social_need": 20.0}
	var err: Error = svc.save_snapshot(bad)
	_check(err != OK, "SAVE-07 非法快照写入被拒绝")
	_check(not FileAccess.file_exists(MAIN_FILE), "SAVE-07 非法快照未落盘")
	_check(str(svc.get_last_error()["stage"]) == "VALIDATE", "SAVE-07 错误阶段为 VALIDATE")


func test_unsupported_version_readonly() -> void:
	var svc := SaveService.new()
	svc.clear_all_for_test()
	var data := _make_snapshot()
	data["schema_version"] = 999
	var text := JSON.stringify(data, "\t")
	var file := FileAccess.open(MAIN_FILE, FileAccess.WRITE)
	file.store_string(text)
	file.close()

	var result: Dictionary = svc.load_snapshot()
	_check(result["status"] == SaveValidator.STATUS_UNSUPPORTED_VERSION,
		"SAVE-07 未知更高 schema 返回 UNSUPPORTED_VERSION，实际=%s" % result["status"])
	_check(FileAccess.file_exists(MAIN_FILE), "SAVE-07 保留原档")
	_check(_read(MAIN_FILE) == text, "SAVE-07 不降级写回（字节未变）")

	# P0-001 回归：未知更高版本必须锁死隐式写入，否则会被默认 v1 静默覆盖
	_check(svc.is_write_locked(), "SAVE-07 未知版本后写入被锁定")
	var implicit_err: Error = svc.save_snapshot(_make_snapshot())
	_check(implicit_err != OK, "SAVE-07 未知版本后隐式覆盖被拒绝")
	_check(_read(MAIN_FILE) == text, "SAVE-07 被拒绝后原档字节仍未变")

	# 只有"显式新建事务"（隔离旧档）才允许重建
	var rebuilt: Dictionary = svc.start_new_save(_make_snapshot())
	_check(bool(rebuilt.get("ok", false)), "SAVE-07 版本拒绝后可显式重建（隔离旧档后新建）")
	_check(not svc.is_write_locked(), "SAVE-07 显式新建后解除写入锁")
	_check(svc.get_revision() == 1, "SAVE-07 重建后 revision 从 1 开始，实际=%d" % svc.get_revision())
	_check((rebuilt.get("quarantined", []) as Array).size() >= 1, "SAVE-07 重建前已隔离未知版本原档")
	_check(_read(MAIN_FILE) != text, "SAVE-07 重建后主档已换成新内容")


## —— SAVE-03：主档损坏 + 有效备份 ——

func test_main_corrupt_with_valid_backup() -> void:
	_note("主档被故意写成非法 JSON，隔离与候选恢复路径会打印解析错误")
	var svc := SaveService.new()
	svc.clear_all_for_test()
	_check(svc.save_snapshot(_make_snapshot()) == OK, "SAVE-03 建立主档（revision 1：energy 62.5）")
	var newer := _make_snapshot()
	(newer["pet"] as Dictionary)["needs"] = {"energy": 11.0, "hunger": 22.0, "comfort": 33.0, "social_need": 44.0}
	_check(svc.save_snapshot(newer) == OK, "SAVE-03 第二次提交（revision 2：energy 11.0；备份保留上一代）")

	# 截断主档为非法 JSON
	var broken := "{ this is not json"
	var file := FileAccess.open(MAIN_FILE, FileAccess.WRITE)
	file.store_string(broken)
	file.close()

	var result: Dictionary = SaveService.new().load_snapshot()
	_check(result["status"] == SaveValidator.STATUS_RECOVERABLE,
		"SAVE-03 主档损坏返回 RECOVERABLE，实际=%s" % result["status"])
	var candidates: Array = result["candidates"] as Array
	_check(candidates.size() >= 1, "SAVE-03 列出可恢复候选")
	var quarantined: String = str(result.get("quarantined", ""))
	_check(quarantined != "", "SAVE-03 已隔离损坏原件")
	_check(_read(quarantined) == broken, "SAVE-03 隔离副本与损坏原字节一致")

	var bak_revision: int = 0
	var bak_path: String = ""
	for c: Dictionary in candidates:
		if str(c["path"]) == BAK_FILE:
			bak_revision = int(c["revision"])
			bak_path = str(c["path"])
	_check(bak_revision == 1, "SAVE-03 备份候选为上一代 revision=1，实际=%d" % bak_revision)
	_check(bak_path != "", "SAVE-03 候选路径可用")

	# 显式选择从备份恢复：恢复值应来自有效备份（上一代），不来自损坏主档
	var restore_err: Error = svc.restore_from_candidate(bak_path)
	_check(restore_err == OK, "SAVE-03 从备份恢复成功")
	var svc_after := SaveService.new()
	var after: Dictionary = svc_after.load_snapshot()
	_check(after["status"] == SaveValidator.STATUS_OK, "SAVE-03 恢复后加载 OK")
	var restored_pet: Dictionary = (after["snapshot"] as Dictionary)["pet"] as Dictionary
	_check(is_equal_approx(float((restored_pet["needs"] as Dictionary)["energy"]), 62.5),
		"SAVE-03 恢复值来自有效备份（energy 62.5）")
	_check(svc_after.get_revision() == bak_revision,
		"SAVE-03 沿用备份 revision，实际=%d 期望=%d" % [svc_after.get_revision(), bak_revision])


## —— SAVE-04：所有候选损坏 ——

func test_all_candidates_corrupt() -> void:
	_note("主档/备份/临时档全部被故意损坏，解析错误与自动保存停止均为预期")
	var svc := SaveService.new()
	svc.clear_all_for_test()
	_check(svc.save_snapshot(_make_snapshot()) == OK, "SAVE-04 建立夹具")
	_check(svc.save_snapshot(_make_snapshot()) == OK, "SAVE-04 建立备份")
	_write(MAIN_FILE, "}{ broken")
	_write(BAK_FILE, "!! broken")
	_write(TMP_FILE, "?? broken")

	var result: Dictionary = SaveService.new().load_snapshot()
	_check(result["status"] == SaveValidator.STATUS_INVALID,
		"SAVE-04 全部损坏返回 INVALID，实际=%s" % result["status"])
	_check(_read(MAIN_FILE) == "}{ broken", "SAVE-04 不覆盖损坏原件")

	var svc2 := SaveService.new()
	svc2.load_snapshot()
	_check(svc2.is_autosave_stopped(), "SAVE-04 停止自动保存")
	_check(svc2.save_snapshot(_make_snapshot()) != OK, "SAVE-04 停止后拒绝自动写入")
	svc2.clear_all_for_test()


## —— SAVE-05 / SAVE-06：各阶段故障注入 ——

## P0-001 回归：启动 + 防抖/周期自动保存的完整链路中，未知版本存档的字节必须保持不变。
## 缺陷原状：load 返回 UNSUPPORTED_VERSION 后自动保存照常运行，
## 一次 60 秒周期保存就把用户的高版本存档用默认 v1 覆盖 —— 数据丢失级。
func test_unsupported_version_survives_autosave_chain() -> void:
	var svc := SaveService.new()
	svc.clear_all_for_test()
	var future := _make_snapshot()
	future["schema_version"] = 999
	future["revision"] = 500
	var original := JSON.stringify(future, "\t")
	_write(MAIN_FILE, original)

	var result: Dictionary = svc.load_snapshot()
	_check(result["status"] == SaveValidator.STATUS_UNSUPPORTED_VERSION,
		"P0-001 启动加载识别为 UNSUPPORTED_VERSION")

	# 模拟 AppController：加载失败后仍会调度保存（启动时 _schedule_save 无条件调用）
	# 这里连续尝试多次，等价于防抖提交 + 多个 60 秒周期保存
	var attempts: int = 5
	var all_rejected := true
	for i: int in range(attempts):
		if svc.save_snapshot(_make_snapshot()) == OK:
			all_rejected = false
	_check(all_rejected, "P0-001 连续 %d 次自动保存全部被拒绝" % attempts)
	_check(_read(MAIN_FILE) == original, "P0-001 未知版本原档字节未被改动")
	_check(svc.is_write_locked(), "P0-001 写入锁保持有效")
	_check(str(svc.get_last_error()["stage"]) == "VALIDATE", "P0-001 错误阶段为 VALIDATE")
	_check(not svc.get_last_error().is_empty(), "P0-001 记录可诊断的错误信息")

	# 备份文件中不应出现被降级的副本
	_check(not FileAccess.file_exists(BAK_FILE), "P0-001 未生成降级备份")

	svc.clear_all_for_test()


## P0-001：主档缺失但存在候选时，不得当作首次运行而自动建新档
func test_missing_main_with_candidate_not_first_run() -> void:
	var svc := SaveService.new()
	svc.clear_all_for_test()
	_check(svc.save_snapshot(_make_snapshot()) == OK, "P0-001 夹具：建立主档")
	_check(svc.save_snapshot(_make_snapshot()) == OK, "P0-001 夹具：建立备份")
	# 主档被外部删除，只剩备份
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MAIN_FILE))

	var fresh := SaveService.new()
	var result: Dictionary = fresh.load_snapshot()
	_check(result["status"] == SaveValidator.STATUS_RECOVERABLE,
		"P0-001 主档缺失但有候选 → RECOVERABLE（非 MISSING），实际=%s" % result["status"])
	_check(fresh.is_write_locked(), "P0-001 该状态下写入被锁定")
	_check(fresh.save_snapshot(_make_snapshot()) != OK, "P0-001 拒绝把它当首次运行建新档")
	_check(not FileAccess.file_exists(MAIN_FILE), "P0-001 未静默重建主档")
	fresh.clear_all_for_test()


func test_fault_injection_stages() -> void:
	_note("逐阶段注入保存故障，ERROR 是注入点被触发的证据")
	var stages: Array[StringName] = [
		SaveService.STAGE_TMP_WRITE,
		SaveService.STAGE_TMP_VERIFY,
		SaveService.STAGE_BACKUP,
		SaveService.STAGE_REPLACE,
		SaveService.STAGE_FINAL_VERIFY,
	]
	for stage: StringName in stages:
		var svc := SaveService.new()
		svc.clear_all_for_test()
		_check(svc.save_snapshot(_make_snapshot()) == OK, "SAVE-05[%s] 建立有效旧代" % stage)
		_check(svc.save_snapshot(_make_snapshot()) == OK, "SAVE-05[%s] 建立第二有效代" % stage)
		var before_revision: int = svc.get_revision()
		var before_main: String = _read(MAIN_FILE)

		svc.set_fault(stage, true)
		var err: Error = svc.save_snapshot(_make_snapshot())
		svc.clear_faults()
		_check(err != OK, "SAVE-06[%s] 注入故障后保存失败" % stage)
		_check(str(svc.get_last_error()["stage"]) == String(stage),
			"SAVE-06[%s] 错误阶段记录正确，实际=%s" % [stage, svc.get_last_error()["stage"]])
		_check(svc.get_revision() == before_revision, "SAVE-06[%s] 失败不递增 revision" % stage)
		_check(FileAccess.file_exists(MAIN_FILE) and _read(MAIN_FILE) == before_main,
			"SAVE-06[%s] 至少保留一份完整有效旧代" % stage)

		# 解除故障后重试：仅递增一次
		var err2: Error = svc.save_snapshot(_make_snapshot())
		_check(err2 == OK, "SAVE-06[%s] 解除故障后重试成功" % stage)
		_check(svc.get_revision() == before_revision + 1,
			"SAVE-06[%s] 重试仅递增一次，实际=%d" % [stage, svc.get_revision()])
		svc.clear_all_for_test()


func test_migrate_dispatch() -> void:
	var data := _make_snapshot()
	var same: Dictionary = SaveValidator.migrate(SaveValidator.SCHEMA_VERSION, data)
	_check(bool(same["ok"]), "SAVE-07 migrate v1→v1 直接通过")
	var from_future: Dictionary = SaveValidator.migrate(2, data)
	_check(not bool(from_future["ok"]), "SAVE-07 migrate 未知更高版本明确拒绝")
	var from_old: Dictionary = SaveValidator.migrate(0, data)
	_check(not bool(from_old["ok"]), "SAVE-07 migrate v0 明确拒绝（P0 不提供虚构转换器）")


## —— 夹具工具 ——

func _make_snapshot() -> Dictionary:
	var wrapper := SaveValidator.make_default_wrapper(SaveValidator.utc_now())
	var pet: Dictionary = wrapper["pet"] as Dictionary
	pet["needs"] = {"energy": 62.5, "hunger": 33.25, "comfort": 71.0, "social_need": 44.5}
	pet["personality"] = {"curiosity": 0.75, "activity": 0.25, "sociability": 0.6, "courage": 0.4}
	pet["attributes"] = {"knowledge": 3, "stamina": 1, "creativity": 2, "charm": 4}
	pet["simulation_elapsed_seconds"] = 12.5
	var settings: Dictionary = wrapper["settings"] as Dictionary
	settings["floating_rect"] = {"x": -300, "y": 100, "w": 256, "h": 256}
	settings["full_rect"] = {"x": -800, "y": 60, "w": 960, "h": 640}
	return wrapper


func _valid_pet() -> Dictionary:
	return SaveValidator.make_default_pet(SaveValidator.utc_now())


func _pet_with(pet_id: String) -> Dictionary:
	var pet := _valid_pet()
	pet["pet_id"] = pet_id
	return pet


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text
