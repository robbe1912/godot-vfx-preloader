# run_ab_test.gd - cross-platform A/B hitch test orchestrator (pure GDScript).
#
# Wipes Godot's on-disk shader pipeline cache (user://shader_cache), then
# launches the demo with --auto-test twice (preloaded / no-preload) and
# prints the comparison. Each run starts from cold, so the test is repeatable.
#
# Usage (from the project folder, or pass --path):
#   godot --headless --path . --script res://tests/run_ab_test.gd -- --mode=both
#   godot --headless --path . --script res://tests/run_ab_test.gd -- --mode=preload
#   godot --headless --path . --script res://tests/run_ab_test.gd -- --mode=nopreload
#
# Portability notes:
#   - Relaunches the SAME Godot binary it runs under (OS.get_executable_path()),
#     so no hardcoded editor paths.
#   - Results are exchanged via a file, not stdout: Windows Godot is a
#     GUI-subsystem binary whose output doesn't attach to the calling process.
extends SceneTree

const RESULT_FILE_NAME: String = ".hitchtest_result.txt"


func _initialize() -> void:
	var mode := "both"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			mode = arg.get_slice("=", 1)

	var project_dir: String = ProjectSettings.globalize_path("res://")
	var results: Array[String] = []

	if mode == "both" or mode == "preload":
		results.append(_run(project_dir, "preloaded", []))
	if mode == "both" or mode == "nopreload":
		results.append(_run(project_dir, "no-preload", ["--no-preload"]))

	print("")
	print("================ RESULTS ================")
	for r: String in results:
		print(r)
	print("=========================================")
	quit(0)


func _run(project_dir: String, label: String, extra_args: PackedStringArray) -> String:
	_clear_shader_cache()

	var result_path: String = project_dir.path_join(RESULT_FILE_NAME)
	if FileAccess.file_exists(result_path):
		DirAccess.remove_absolute(result_path)

	print("  running: %s ..." % label)
	# If we are headless (e.g. CI), the child run must be headless too -
	# otherwise it tries to open a window and fails on display-less machines.
	var args := PackedStringArray()
	if DisplayServer.get_name() == "headless":
		args.append("--headless")
	(
		args
		. append_array(
			PackedStringArray(
				[
					"--path",
					project_dir,
					"--",
					"--auto-test",
					"--result-file=" + result_path,
				]
			)
		)
	)
	args.append_array(extra_args)
	var output: Array = []
	OS.execute(OS.get_executable_path(), args, output, true)

	var result := ""
	if FileAccess.file_exists(result_path):
		result = FileAccess.get_file_as_string(result_path).strip_edges()
	if result.is_empty():
		push_warning("no HITCHTEST RESULT for '%s' - did the demo window run and quit?" % label)
		return "%s: (no result)" % label
	print("  %s" % result)
	return result


func _clear_shader_cache() -> void:
	var cache: String = ProjectSettings.globalize_path("user://shader_cache")
	if not DirAccess.dir_exists_absolute(cache):
		print("  (no shader cache found at %s)" % cache)
		return
	var err := _delete_dir_recursive(cache)
	if err == OK:
		print("  shader cache cleared: %s" % cache)
	else:
		push_warning("could not fully clear shader cache (%s): %s" % [cache, error_string(err)])


func _delete_dir_recursive(path: String) -> Error:
	var dir := DirAccess.open(path)
	if dir == null:
		return DirAccess.get_open_error()
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			if dir.current_is_dir():
				var sub_err := _delete_dir_recursive(path.path_join(entry))
				if sub_err != OK:
					return sub_err
			else:
				var rm_err := dir.remove(entry)
				if rm_err != OK:
					return rm_err
		entry = dir.get_next()
	dir.list_dir_end()
	return OK
