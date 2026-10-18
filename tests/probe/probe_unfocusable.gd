extends SceneTree

var _ran := false

func _process(_d: float) -> bool:
	if _ran: return true
	_ran = true
	var win := root
	var names: Array[String] = []
	for p: Dictionary in win.get_property_list():
		var n := str(p["name"])
		if n.contains("focus") or n.contains("flag"):
			names.append(n)
	print("focus-ish props: ", names)
	print("has unfocusable=", "unfocusable" in win)
	quit(0)
	return false
