class_name SaveService
extends RefCounted
## JSON 存档、安全提交与恢复（架构 §7）。
## 位置 user://saves/：主档 save.json、备份 save.bak.json、临时档 save.tmp.json、
## 替换暂存 save.old.json、隔离区 quarantine/；日志 user://logs/。
##
## 提交协议（架构 §7.1）：候选写临时档 → 重新读取解析校验 → 主档有效才更新备份
## （旧备份在新副本写完并验证前不删除）→ 安全替换主档 → 重新读取确认 revision 与结构
## → 清理临时档。任一步失败立即停止，保留候选与已校验旧代，记录阶段/路径/错误码。
##
## P0 目标是可恢复的提交协议，不承诺仅凭 rename/flush 抵御所有断电或文件系统故障。

## 提交阶段（故障注入与错误诊断使用）
const STAGE_VALIDATE := &"VALIDATE"
const STAGE_TMP_WRITE := &"TMP_WRITE"
const STAGE_TMP_VERIFY := &"TMP_VERIFY"
const STAGE_BACKUP := &"BACKUP"
const STAGE_REPLACE := &"REPLACE"
const STAGE_FINAL_VERIFY := &"FINAL_VERIFY"
const STAGE_CLEANUP := &"CLEANUP"

const SAVE_DIR := "user://saves/"
const QUARANTINE_DIR := "user://saves/quarantine/"
const LOG_DIR := "user://logs/"
const LOG_FILE := "user://logs/mote.log"
const MAIN_FILE := "user://saves/save.json"
const BAK_FILE := "user://saves/save.bak.json"
const TMP_FILE := "user://saves/save.tmp.json"
const OLD_FILE := "user://saves/save.old.json"
const BAK_TMP_FILE := "user://saves/save.bak.tmp.json"
const LOG_MAX_BYTES := 2 * 1024 * 1024
const LOG_ROTATIONS := 3

## 沙箱根（测试隔离，报告 §4「测试隔离」风险项）。
## 非空时所有路径常量改由这里派发，绝不允许触碰真实 user://saves/ ——
## clear_all_for_test() 会清空目录，若指向真实存档就是删用户数据的操作。
static var _sandbox_root: String = ""


## 在测试入口调用一次：把存档/日志重定向到独立沙箱目录
static func use_sandbox(root: String) -> void:
	_sandbox_root = root


static func is_sandboxed() -> bool:
	return _sandbox_root != ""


## 路径解析：沙箱启用时按相同相对结构重写
static func _resolve(path: String) -> String:
	if _sandbox_root == "":
		return path
	if path.begins_with(SAVE_DIR):
		return _sandbox_root + "/saves/" + path.substr(SAVE_DIR.length())
	if path.begins_with(LOG_DIR):
		return _sandbox_root + "/logs/" + path.substr(LOG_DIR.length())
	return path


static func main_path() -> String:
	return _resolve(MAIN_FILE)


static func bak_path() -> String:
	return _resolve(BAK_FILE)


static func tmp_path() -> String:
	return _resolve(TMP_FILE)


static func old_path() -> String:
	return _resolve(OLD_FILE)


static func bak_tmp_path() -> String:
	return _resolve(BAK_TMP_FILE)


static func save_dir() -> String:
	return _resolve(SAVE_DIR)


static func quarantine_dir() -> String:
	return _resolve(QUARANTINE_DIR)


static func log_dir() -> String:
	return _resolve(LOG_DIR)


static func log_file() -> String:
	return _resolve(LOG_FILE)


var _save_id: String = ""
var _revision: int = 0
var _autosave_stopped: bool = false
## 写入锁（架构 §7.2 / P0-001）：加载状态为 UNSUPPORTED_VERSION / RECOVERABLE / INVALID 时
## 一律禁止任何自动或隐式写入，直到用户显式完成"恢复候选"或"隔离后新建"事务。
## 未知更高版本绝不能被默认 v1 覆盖——这是数据丢失级风险。
var _write_locked: bool = false
var _lock_reason: String = ""
var _last_error: Dictionary = {}
var _log_memory: Array[String] = []
var _log_failed: bool = false
var _faults: Dictionary = {}


## —— 状态与诊断 ——

func get_save_id() -> String:
	return _save_id


## 保证存在稳定的 save_id：首次提交时生成，此后保持不变（架构 §6.1）。
func ensure_save_id() -> String:
	if _save_id == "":
		_save_id = "local-save-%s" % SaveValidator.new_random_token()
	return _save_id


func get_revision() -> int:
	return _revision


func is_autosave_stopped() -> bool:
	return _autosave_stopped


func stop_autosave(reason: String) -> void:
	_autosave_stopped = true
	_log(&"AUTOSAVE_STOP", "", 0, reason)


## 锁定写入：任何保存请求都将被拒绝并返回明确错误（P0-001）
func lock_writes(reason: String) -> void:
	_write_locked = true
	_lock_reason = reason
	stop_autosave(reason)
	_log(&"WRITE_LOCK", "", 0, reason)


func is_write_locked() -> bool:
	return _write_locked


func get_lock_reason() -> String:
	return _lock_reason


## 仅由显式恢复/新建事务在成功后调用
func unlock_writes() -> void:
	_write_locked = false
	_lock_reason = ""


func resume_autosave() -> void:
	_autosave_stopped = false


func get_last_error() -> Dictionary:
	return _last_error.duplicate(true)


func get_diagnostics() -> Dictionary:
	return {
		"save_dir": ProjectSettings.globalize_path(save_dir()),
		"main_file": ProjectSettings.globalize_path(main_path()),
		"bak_file": ProjectSettings.globalize_path(bak_path()),
		"quarantine_dir": ProjectSettings.globalize_path(quarantine_dir()),
		"log_file": ProjectSettings.globalize_path(log_file()),
		"save_id": _save_id,
		"revision": _revision,
		"autosave_stopped": _autosave_stopped,
		"last_error": _last_error.duplicate(true),
		"log_write_failed": _log_failed,
		"log_memory_lines": _log_memory.size(),
	}


func has_save() -> bool:
	return FileAccess.file_exists(main_path()) or FileAccess.file_exists(bak_path())


## —— 故障注入（仅供验收测试；架构 §8 要求提供保存故障注入入口）——

func set_fault(stage: StringName, enabled: bool) -> void:
	_faults[stage] = enabled


func clear_faults() -> void:
	_faults.clear()


func _fault_enabled(stage: StringName) -> bool:
	return bool(_faults.get(stage, false))


## —— 保存 ——

## 提交一份封装快照。revision 仅在成功提交后递增；save_id 保持不变。
func save_snapshot(snapshot: Dictionary) -> Error:
	if _write_locked:
		# 拒绝并保留原档：未知版本/待选择恢复状态不得被隐式写入
		return _record_error(STAGE_VALIDATE, main_path(), ERR_UNAVAILABLE,
			"写入已锁定（%s）：需先完成显式恢复或隔离后新建" % _lock_reason)
	if _autosave_stopped:
		return _record_error(STAGE_VALIDATE, main_path(), ERR_UNAVAILABLE, "自动保存已停止（存档损坏需显式恢复）")
	return _commit(snapshot, true)


## 从候选档恢复（用户显式选择后调用）：不递增 revision，沿用候选自带的 revision。
func restore_from_candidate(path: String) -> Error:
	var parsed := _parse_file(path)
	if not bool(parsed["ok"]):
		return _record_error(STAGE_VALIDATE, path, ERR_PARSE_ERROR, str(parsed["error"]))
	var data: Dictionary = parsed["data"] as Dictionary
	var version_status: StringName = SaveValidator.classify_schema_version(data)
	if version_status == SaveValidator.STATUS_UNSUPPORTED_VERSION:
		return _record_error(STAGE_VALIDATE, path, ERR_INVALID_DATA, "候选为未知更高 schema，拒绝应用")
	if version_status == SaveValidator.STATUS_INVALID:
		return _record_error(STAGE_VALIDATE, path, ERR_INVALID_DATA, "候选 schema_version 非法")
	var err_msg := SaveValidator.validate_snapshot(data)
	if err_msg != "":
		return _record_error(STAGE_VALIDATE, path, ERR_INVALID_DATA, err_msg)
	var result := _commit(data, false)
	if result == OK:
		# 显式恢复事务成功：解除写入锁，恢复正常保存
		unlock_writes()
		resume_autosave()
		_log(&"RESTORE", path, 0, "已从候选恢复 revision=%d" % _revision)
	return result


## —— 加载 ——

## 返回 {status, source, snapshot, error, candidates}。
## status ∈ OK / MISSING / RECOVERABLE / INVALID / UNSUPPORTED_VERSION / IO_ERROR。
## 只有 MISSING 可以自动创建默认档；其他情况走明确恢复路径。
func load_snapshot() -> Dictionary:
	_ensure_dirs()
	if not FileAccess.file_exists(main_path()):
		var candidates := scan_candidates()
		if candidates.is_empty():
			return {
				"status": SaveValidator.STATUS_MISSING,
				"source": "",
				"snapshot": {},
				"error": "未发现存档（首次运行）",
				"candidates": [],
			}
		# 主档缺失但有候选：不能误判成首次运行（架构 §7.2）
		lock_writes("主档缺失但存在待确认候选，需显式选择恢复")
		return {
			"status": SaveValidator.STATUS_RECOVERABLE,
			"source": "",
			"snapshot": {},
			"error": "主档缺失，存在待确认候选",
			"candidates": candidates,
		}

	var parsed := _parse_file(main_path())
	if not bool(parsed["ok"]):
		# 主档损坏：隔离原字节，再看备份（架构 §7.2）
		var quarantined := _quarantine(main_path())
		var candidates := scan_candidates()
		var error_text := str(parsed["error"])
		if _has_valid_candidate(candidates):
			lock_writes("主档损坏，等待显式选择恢复候选")
			return {
				"status": SaveValidator.STATUS_RECOVERABLE,
				"source": "",
				"snapshot": {},
				"error": "主档损坏已隔离至 %s；备份可用，等待显式选择：%s" % [quarantined, error_text],
				"candidates": candidates,
				"quarantined": quarantined,
			}
		stop_autosave("主档与备份均不可用：%s" % error_text)
		lock_writes("主档损坏且无有效备份")
		return {
			"status": SaveValidator.STATUS_INVALID,
			"source": main_path(),
			"snapshot": {},
			"error": "主档损坏且无有效备份：%s" % error_text,
			"candidates": candidates,
			"quarantined": quarantined,
		}

	var data: Dictionary = parsed["data"] as Dictionary
	var version_status: StringName = SaveValidator.classify_schema_version(data)
	if version_status == SaveValidator.STATUS_UNSUPPORTED_VERSION:
		# 只读拒绝：保留原档及备份，禁止任何自动写回（P0-001）
		lock_writes("存档 schema 版本高于当前程序，只读拒绝")
		return {
			"status": SaveValidator.STATUS_UNSUPPORTED_VERSION,
			"source": main_path(),
			"snapshot": {},
			"error": "存档 schema 版本高于当前程序（%s），请使用兼容版本" % data.get("schema_version", "?"),
			"candidates": scan_candidates(),
		}
	if version_status == SaveValidator.STATUS_INVALID:
		lock_writes("存档 schema_version 非法")
		return {
			"status": SaveValidator.STATUS_INVALID,
			"source": main_path(),
			"snapshot": {},
			"error": "存档 schema_version 非法",
			"candidates": scan_candidates(),
		}

	var err_msg := SaveValidator.validate_snapshot(data)
	if err_msg != "":
		var quarantined := _quarantine(main_path())
		var candidates := scan_candidates()
		if _has_valid_candidate(candidates):
			lock_writes("主档结构非法，等待显式选择恢复候选")
			return {
				"status": SaveValidator.STATUS_RECOVERABLE,
				"source": "",
				"snapshot": {},
				"error": "主档结构非法（%s）已隔离至 %s；备份可用，等待显式选择" % [err_msg, quarantined],
				"candidates": candidates,
				"quarantined": quarantined,
			}
		stop_autosave("主档结构非法且无有效备份：%s" % err_msg)
		lock_writes("主档结构非法且无有效备份")
		return {
			"status": SaveValidator.STATUS_INVALID,
			"source": main_path(),
			"snapshot": {},
			"error": "主档结构非法且无有效备份：%s" % err_msg,
			"candidates": candidates,
			"quarantined": quarantined,
		}

	var loaded: Dictionary = SaveValidator.normalize_loaded_snapshot(data)
	_save_id = str(loaded.get("save_id", ""))
	_revision = SaveValidator.as_int(loaded.get("revision", 1))
	unlock_writes()
	resume_autosave()
	_log(&"LOAD", main_path(), 0, "加载成功 revision=%d" % _revision)
	return {
		"status": SaveValidator.STATUS_OK,
		"source": main_path(),
		"snapshot": loaded,
		"error": "",
		"candidates": scan_candidates(),
	}


## 扫描可用于恢复的候选（备份、临时档、替换暂存档）。仅返回通过校验的项。
func scan_candidates() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var paths: Array[String] = [bak_path(), tmp_path(), old_path()]
	for path: String in paths:
		if not FileAccess.file_exists(path):
			continue
		var parsed := _parse_file(path)
		if not bool(parsed["ok"]):
			continue
		var data: Dictionary = parsed["data"] as Dictionary
		if SaveValidator.classify_schema_version(data) != SaveValidator.STATUS_OK:
			continue
		if SaveValidator.validate_snapshot(data) != "":
			continue
		out.append({
			"path": path,
			"revision": SaveValidator.as_int(data.get("revision", 0)),
			"saved_at": str(data.get("saved_at", "")),
			"save_id": str(data.get("save_id", "")),
		})
	return out


func _has_valid_candidate(candidates: Array[Dictionary]) -> bool:
	return not candidates.is_empty()


## —— 提交事务 ——

func _commit(snapshot: Dictionary, bump_revision: bool) -> Error:
	# 二道防线：即使绕过 save_snapshot 直接调用，提交层也拒绝被锁定的写入
	if _write_locked:
		return _record_error(STAGE_VALIDATE, main_path(), ERR_UNAVAILABLE,
			"写入已锁定（%s）：拒绝提交" % _lock_reason)
	_ensure_dirs()
	# 先补齐身份与版本字段，再校验：新档首提交的 revision 由本服务赋为 1
	var candidate: Dictionary = snapshot.duplicate(true)
	var save_id: String = str(candidate.get("save_id", ""))
	if save_id == "":
		save_id = _save_id if _save_id != "" else ensure_save_id()
	candidate["save_id"] = save_id
	if bump_revision:
		candidate["revision"] = _revision + 1
	candidate["saved_at"] = SaveValidator.utc_now()
	var expected_revision: int = SaveValidator.as_int(candidate["revision"])

	var validation := SaveValidator.validate_snapshot(candidate)
	if validation != "":
		return _record_error(STAGE_VALIDATE, main_path(), ERR_INVALID_DATA, validation)

	# 1) 写入同目录临时档
	if _fault_enabled(STAGE_TMP_WRITE):
		return _record_error(STAGE_TMP_WRITE, tmp_path(), ERR_FILE_CANT_WRITE, "故障注入：临时档写入失败")
	var write_err := _write_text(tmp_path(), JSON.stringify(candidate, "\t"))
	if write_err != OK:
		return _record_error(STAGE_TMP_WRITE, tmp_path(), write_err, "临时档写入失败")

	# 2) 重新读取、解析并校验候选
	if _fault_enabled(STAGE_TMP_VERIFY):
		return _record_error(STAGE_TMP_VERIFY, tmp_path(), ERR_PARSE_ERROR, "故障注入：临时档复核失败")
	var tmp_parsed := _parse_file(tmp_path())
	if not bool(tmp_parsed["ok"]):
		return _record_error(STAGE_TMP_VERIFY, tmp_path(), ERR_PARSE_ERROR, str(tmp_parsed["error"]))
	if SaveValidator.validate_snapshot(tmp_parsed["data"] as Dictionary) != "":
		return _record_error(STAGE_TMP_VERIFY, tmp_path(), ERR_INVALID_DATA, "临时档复核未通过结构校验")

	# 3) 仅当当前主档通过校验时才更新备份；旧备份在新副本验证前不删除
	var main_valid := _is_valid_snapshot_file(main_path())
	if main_valid:
		if _fault_enabled(STAGE_BACKUP):
			return _record_error(STAGE_BACKUP, bak_path(), ERR_FILE_CANT_WRITE, "故障注入：备份写入失败")
		var bak_err := _update_backup()
		if bak_err != OK:
			return _record_error(STAGE_BACKUP, bak_path(), bak_err, "备份更新失败（主档未被触碰）")

	# 4) 安全替换主档：替换前、替换后至少保留一份已校验的旧代或新代
	if _fault_enabled(STAGE_REPLACE):
		return _record_error(STAGE_REPLACE, main_path(), ERR_FILE_CANT_WRITE, "故障注入：主档替换失败")
	var main_exists := FileAccess.file_exists(main_path())
	if main_exists:
		_remove_file(old_path())  # 清掉上一轮遗留的替换暂存，避免 Windows 下重命名目标已存在
		var move_err := _rename_file(main_path(), old_path())
		if move_err != OK:
			return _record_error(STAGE_REPLACE, main_path(), move_err, "主档暂存为 save.old.json 失败")
	var promote_err := _rename_file(tmp_path(), main_path())
	if promote_err != OK:
		if main_exists:
			_rename_file(old_path(), main_path())  # 回滚：至少保留已校验旧代
		return _record_error(STAGE_REPLACE, main_path(), promote_err, "临时档提升为主档失败（已尝试回滚）")

	# 5) 重新读取提交结果，确认 revision 与结构
	if _fault_enabled(STAGE_FINAL_VERIFY):
		# 故障注入也要保证不留半替换状态：回滚到已校验旧代
		_restore_old_main(main_exists)
		return _record_error(STAGE_FINAL_VERIFY, main_path(), ERR_INVALID_DATA, "故障注入：提交后复核失败（已回滚）")
	var final_parsed := _parse_file(main_path())
	if not bool(final_parsed["ok"]):
		_restore_old_main(main_exists)
		return _record_error(STAGE_FINAL_VERIFY, main_path(), ERR_PARSE_ERROR, str(final_parsed["error"]))
	var final_data: Dictionary = final_parsed["data"] as Dictionary
	if SaveValidator.validate_snapshot(final_data) != "" or SaveValidator.as_int(final_data.get("revision", -1)) != expected_revision:
		_restore_old_main(main_exists)
		return _record_error(STAGE_FINAL_VERIFY, main_path(), ERR_INVALID_DATA, "提交后复核 revision/结构不符（已尝试回滚）")

	# 6) 清理无用临时文件（失败只记录，不影响已成功提交）
	var cleanup_err := _remove_file(old_path())
	if cleanup_err != OK:
		_log(STAGE_CLEANUP, old_path(), cleanup_err, "替换暂存文件清理失败（已提交成功）")

	_save_id = save_id
	_revision = expected_revision
	_last_error = {}
	_log(&"SAVE", main_path(), 0, "提交成功 revision=%d" % _revision)
	return OK


func _update_backup() -> Error:
	var copy_err := _copy_file_bytes(main_path(), bak_tmp_path())
	if copy_err != OK:
		return copy_err
	if not _is_valid_snapshot_file(bak_tmp_path()):
		_remove_file(bak_tmp_path())
		return ERR_INVALID_DATA
	# 旧备份在新副本验证通过后才移除
	if FileAccess.file_exists(bak_path()):
		_remove_file(bak_path() + ".old")
		var swap_err := _rename_file(bak_path(), bak_path() + ".old")
		if swap_err != OK:
			return swap_err
	var promote_err := _rename_file(bak_tmp_path(), bak_path())
	if promote_err != OK:
		_rename_file(bak_path() + ".old", bak_path())
		return promote_err
	_remove_file(bak_path() + ".old")
	return OK


func _restore_old_main(main_existed: bool) -> void:
	if not main_existed:
		_remove_file(old_path())
		return
	_remove_file(main_path())
	_rename_file(old_path(), main_path())


## 新建前隔离现有文件（架构 §7.2）：隔离失败则停止写入、保留原文件。
## 返回 {ok: bool, quarantined: Array[String], error: String}
##
## 语义（P0-001）：隔离成功即代表"用户显式选择了放弃旧档并新建"，
## 因此本函数在成功时解除写入锁——否则新建后的首次提交会被自己的锁拦住。
## 隔离失败时**保持锁定**，绝不允许在旧档仍在原地的情况下开始写入。
func quarantine_all_for_reset() -> Dictionary:
	_ensure_dirs()
	var paths: Array[String] = []
	for path: String in [main_path(), bak_path(), tmp_path(), old_path()]:
		if FileAccess.file_exists(path):
			paths.append(path)
	if paths.is_empty():
		# 没有需要隔离的文件：新建路径畅通
		unlock_writes()
		resume_autosave()
		return {"ok": true, "quarantined": [], "error": ""}
	var moved: Array[String] = []
	for path: String in paths:
		var target: String = _quarantine(path)
		if target == "":
			return {"ok": false, "quarantined": moved, "error": "隔离 %s 失败，已保留原文件" % path}
		moved.append(target)
		_remove_file(path)
	unlock_writes()
	resume_autosave()
	_log(&"RESET", save_dir(), 0, "已隔离 %d 个文件，解除写入锁并可新建" % moved.size())
	return {"ok": true, "quarantined": moved, "error": ""}


## 显式新建事务的唯一入口：隔离 → 丢弃身份 → 首次提交。
## 返回 {ok: bool, quarantined: Array[String], error: String, write_error: Error}。
## 任一阶段失败都保留明确的失败信息，且不会留下"已解锁但旧档未隔离"的半状态。
func start_new_save(first_snapshot: Dictionary) -> Dictionary:
	var quarantine: Dictionary = quarantine_all_for_reset()
	if not bool(quarantine.get("ok", false)):
		return {
			"ok": false,
			"quarantined": quarantine.get("quarantined", []),
			"error": str(quarantine.get("error", "隔离失败")),
			"write_error": ERR_UNAVAILABLE,
		}
	reset_identity()
	var err: Error = save_snapshot(first_snapshot)
	return {
		"ok": err == OK,
		"quarantined": quarantine.get("quarantined", []),
		"error": "" if err == OK else str(get_last_error().get("message", "首次提交失败")),
		"write_error": err,
	}


## 丢弃当前身份，使下一次提交从 revision 1 开始（仅用于显式新建）
func reset_identity() -> void:
	_save_id = ""
	_revision = 0
	_last_error = {}
	unlock_writes()
	resume_autosave()


## 将损坏/非法主档原样复制到隔离区（架构 §7.2）。返回隔离路径，失败返回空串。
func _quarantine(path: String) -> String:
	_ensure_dirs()
	if not FileAccess.file_exists(path):
		return ""
	var stamp: String = SaveValidator.utc_now().replace(":", "").replace("-", "")
	var target: String = "%s%s.%s.json" % [quarantine_dir(), path.get_file().get_basename(), stamp]
	var err := _copy_file_bytes(path, target)
	if err != OK:
		_log(&"QUARANTINE", path, err, "隔离失败，保留原文件并停止写入")
		return ""
	_log(&"QUARANTINE", target, 0, "已隔离 %s" % path)
	return target


## —— 文件工具 ——

func _ensure_dirs() -> void:
	for dir: String in [save_dir(), quarantine_dir(), log_dir()]:
		if not DirAccess.dir_exists_absolute(dir):
			var err := DirAccess.make_dir_recursive_absolute(dir)
			if err != OK and err != ERR_ALREADY_EXISTS:
				_log(&"INIT", dir, err, "目录创建失败")


func _write_text(path: String, text: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.flush()
	var err: Error = file.get_error()
	file.close()
	if err != OK:
		return err
	return OK if FileAccess.file_exists(path) else ERR_FILE_CANT_WRITE


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "data": {}, "error": "文件不存在"}
	var text := _read_text(path)
	if text.is_empty():
		return {"ok": false, "data": {}, "error": "文件为空或不可读"}
	# 结构预检：存档必须是 JSON 对象。先做廉价判断，避免把明显不是 JSON 的内容
	# 交给解析器而产生引擎级 "Parse JSON failed" 噪声（损坏档是预期场景，不是故障）。
	if not text.strip_edges().begins_with("{"):
		return {"ok": false, "data": {}, "error": "文件不是 JSON 对象（首字符非 '{'）"}
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "data": {}, "error": "JSON 解析失败或不是对象"}
	return {"ok": true, "data": parsed as Dictionary, "error": ""}


func _is_valid_snapshot_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed := _parse_file(path)
	if not bool(parsed["ok"]):
		return false
	return SaveValidator.validate_snapshot(parsed["data"] as Dictionary) == ""


func _copy_file_bytes(from_path: String, to_path: String) -> Error:
	var src := FileAccess.open(from_path, FileAccess.READ)
	if src == null:
		return FileAccess.get_open_error()
	var bytes: PackedByteArray = src.get_buffer(src.get_length())
	src.close()
	var dst := FileAccess.open(to_path, FileAccess.WRITE)
	if dst == null:
		return FileAccess.get_open_error()
	dst.store_buffer(bytes)
	dst.flush()
	var err: Error = dst.get_error()
	dst.close()
	return err


func _rename_file(from_path: String, to_path: String) -> Error:
	var dir := DirAccess.open(from_path.get_base_dir())
	if dir == null:
		return ERR_FILE_NOT_FOUND
	var err: Error = dir.rename(from_path.get_file(), to_path.get_file())
	if err != OK:
		# Windows 上目标已存在时重命名会失败；此处不强行覆盖，交由调用方决策
		return err
	return OK


func _remove_file(path: String) -> Error:
	if not FileAccess.file_exists(path):
		return OK
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return ERR_FILE_NOT_FOUND
	return dir.remove(path.get_file())


func _record_error(stage: StringName, path: String, code: int, message: String) -> Error:
	_last_error = {"stage": String(stage), "path": path, "code": code, "message": message}
	_log(stage, path, code, message)
	return code as Error


## —— 日志（默认不逐帧写；写入失败回退内存，不递归记错）——

func _log(stage: StringName, path: String, code: int, message: String) -> void:
	var line: String = JSON.stringify({
		"t": SaveValidator.utc_now(),
		"stage": String(stage),
		"path": path,
		"code": code,
		"message": message,
	})
	if _log_failed:
		_append_log_memory(line)
		return
	var file := FileAccess.open(log_file(), FileAccess.READ_WRITE) if FileAccess.file_exists(log_file()) else FileAccess.open(log_file(), FileAccess.WRITE)
	if file == null:
		_log_failed = true
		_append_log_memory(line)
		return
	file.seek_end()
	file.store_line(line)
	file.close()
	_maybe_rotate_log()


func _append_log_memory(line: String) -> void:
	_log_memory.append(line)
	if _log_memory.size() > 200:
		_log_memory = _log_memory.slice(_log_memory.size() - 200)


func get_log_memory() -> Array[String]:
	return _log_memory.duplicate()


func _maybe_rotate_log() -> void:
	var size := FileAccess.get_size(log_file()) if FileAccess.file_exists(log_file()) else 0
	if size < LOG_MAX_BYTES:
		return
	for i: int in range(LOG_ROTATIONS - 1, 0, -1):
		var from_path := "%s.%d" % [log_file(), i]
		var to_path := "%s.%d" % [log_file(), i + 1]
		if FileAccess.file_exists(from_path):
			_remove_file(to_path)
			_rename_file(from_path, to_path)
	_remove_file("%s.1" % log_file())
	_rename_file(log_file(), "%s.1" % log_file())


## 测试夹具：清空本服务管理的目录，便于隔离测试。
func clear_all_for_test() -> Error:
	for path: String in [main_path(), bak_path(), tmp_path(), old_path(), bak_tmp_path(), "%s.old" % bak_path()]:
		_remove_file(path)
	var qdir := DirAccess.open(quarantine_dir())
	if qdir != null:
		qdir.list_dir_begin()
		var name: String = qdir.get_next()
		while name != "":
			if not name.begins_with("."):
				qdir.remove(name)
			name = qdir.get_next()
		qdir.list_dir_end()
	_save_id = ""
	_revision = 0
	_autosave_stopped = false
	_last_error = {}
	# 清档后必须一并解除写入锁与失败态：否则"先触发锁、再清档"的测试会一直处于锁定，
	# 后续写入被误判为失败（本会话实测到一次该形态的偶发失败）。
	_write_locked = false
	_lock_reason = ""
	return OK
