extends SceneTree
## 探针：检查 SaveService 是否可实例化。


func _initialize() -> void:
	var script: Script = load("res://scripts/persistence/save_service.gd") as Script
	print("script=", script)
	print("can_instantiate=", script.can_instantiate() if script != null else "n/a")
	var svc = SaveService.new()
	print("svc=", svc)
	print("diag=", svc.get_diagnostics())
	quit(0)
