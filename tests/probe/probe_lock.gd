extends SceneTree

var _ran := false

func _process(_d: float) -> bool:
	if _ran: return true
	_ran = true
	SaveService.use_sandbox("user://test_sandbox/probe_lock")
	var svc := SaveService.new()
	svc.clear_all_for_test()
	var data: Dictionary = SaveValidator.make_default_wrapper(SaveValidator.utc_now())
	data["schema_version"] = 999
	var f := FileAccess.open(SaveService.main_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	var r: Dictionary = svc.load_snapshot()
	print("status=", r["status"], " locked=", svc.is_write_locked(), " reason=", svc.get_lock_reason())
	var err: int = svc.save_snapshot(SaveValidator.make_default_wrapper(SaveValidator.utc_now()))
	print("save err=", err, " last=", svc.get_last_error())
	quit(0)
	return false
