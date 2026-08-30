# vfx_preloader.gd
# Two-phase VFX preloading to eliminate first-use hitches.
#
# Phase 1 — Resource caching:
#   Thread-loads each PackedScene into the resource cache via
#   ResourceLoader.load_threaded_request(). This pre-warms GLSL->SPIR-V
#   compilation and caches textures/meshes.
#
# Phase 2 — Pipeline warmup:
#   Instantiates each cached scene inside a hidden SubViewport for one
#   frame, triggering GPU pipeline (SPIR-V -> hardware) compilation.
#   This is the step most preloaders miss — loading a PackedScene without
#   adding it to the scene tree does NOT compile render pipelines. The
#   scene must actually be rendered at least once.
#   Scenes are batched (warmup_batch_size per frame) to spread GPU work.
#
# Usage:
#   var preloader := VFXPreloader.new()
#   preloader.scene_paths = VFXPreloader.collect_scene_paths("res://assets/vfx")
#   preloader.preloading_completed.connect(_start_game)
#   add_child(preloader)
#   preloader.preload_all()
#
# Requires Godot 4.2+ (typed iterators). Tested on 4.7, Forward+.
#
# Relationship to Godot's built-in mechanisms (see docs link below):
#   - Ubershaders / automatic pipeline precompilation (Godot 4.4+) only detect
#     pipelines for meshes and nodes present at load time. Scenes spawned
#     dynamically during gameplay (spell impacts, hit effects) are invisible
#     to that system until their first cast. There is also no API to gate
#     gameplay on "pipelines for these scenes are ready".
#   - The export-time shader baker (Godot 4.5+) only covers shader compilation
#     (GLSL -> SPIR-V/DXIL/MIL), NOT pipeline compilation (SPIR-V -> hardware).
#     The pipeline step is driver/GPU-dependent and can only run on the
#     player's machine - that step is the hitch this preloader absorbs.
#   - This script is the official docs' recommended workaround for dynamic
#     effects ("instantiate the scene at least once, even off-screen, e.g. in
#     a SubViewport"), packaged with batching, timeouts, progress and a
#     completion signal. It complements the built-in systems, not replaces.
#
# Reference:
#   https://docs.godotengine.org/en/stable/tutorials/performance/pipeline_compilations.html
class_name VFXPreloader
extends Node

signal preloading_started
signal preloading_completed

@export_group("Scenes")
## PackedScene paths to preload and warm up.
@export var scene_paths: PackedStringArray = PackedStringArray()

@export_group("Tuning")
## Phase 1: simultaneous threaded resource loads.
@export var max_concurrent_loads: int = 4
## Phase 2: scenes instantiated + rendered per frame.
@export var warmup_batch_size: int = 5
## Phase 1: give up on a single resource after this long (ms).
@export var per_resource_timeout_ms: int = 5000
## Phase 2: idle frames after the last batch, so async pipeline
## compilation drains before preloading_completed fires.
@export var compile_settle_frames: int = 10

const DEBUG: bool = false

var _wall_start_msec: float = 0.0
var _phase2_wall_start_msec: float = 0.0
var _compile_settle_remaining: int = 0

var _is_preloading: bool = false
var _queue: Array = []
var _active: Array = []
var _active_start_msec: Dictionary = {}
var _loaded_count: int = 0
var _total_count: int = 0

var _warmup_queue: Array = []
var _warmup_viewport: SubViewport = null
var _is_warming_up: bool = false
var _warmed_count: int = 0
var _timed_out_paths: PackedStringArray = []
# Instances kept alive for one frame so the viewport actually renders them.
# Previous batch is freed when the next batch is processed.
var _warmup_rendered_instances: Array[Node] = []


func _ready() -> void:
	_warmup_viewport = SubViewport.new()
	_warmup_viewport.size = Vector2i(64, 64)
	_warmup_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_warmup_viewport.transparent_bg = true
	add_child(_warmup_viewport)

	# 3D rendering requires a Camera3D and light so spatial shaders actually compile.
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0.0, 0.0, 3.0)
	_warmup_viewport.add_child(camera)

	var light := DirectionalLight3D.new()
	light.light_energy = 1.0
	_warmup_viewport.add_child(light)


## Starts the two-phase preload. Safe to call once; repeated calls while
## running are ignored.
func preload_all() -> void:
	if _is_preloading:
		_debug("Preloading already in progress")
		return

	_is_preloading = true
	_queue.clear()
	_active.clear()
	_active_start_msec.clear()
	_loaded_count = 0
	_timed_out_paths.clear()

	for path in scene_paths:
		if ResourceLoader.exists(path):
			_queue.append(path)

	_total_count = _queue.size()

	if _total_count == 0:
		_debug("No scenes to preload")
		_is_preloading = false
		set_process(false)
		_release_warmup_viewport()
		preloading_completed.emit()
		return

	preloading_started.emit()
	_wall_start_msec = Time.get_unix_time_from_system() * 1000.0
	set_process(true)
	_debug("Phase 1: thread-loading %d scenes (batch %d)" % [_total_count, max_concurrent_loads])
	_fill_active_slots()


## Recursively collects every .tscn path under a res:// folder.
static func collect_scene_paths(folder: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var dir := DirAccess.open(folder)
	if dir == null:
		push_warning("VFXPreloader: cannot open folder: " + folder)
		return paths
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := folder.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				paths.append_array(collect_scene_paths(full))
		elif entry.ends_with(".tscn"):
			paths.append(full)
		entry = dir.get_next()
	return paths


func _process(_delta: float) -> void:
	if _is_warming_up:
		_process_warmup_batch()
		return

	if _compile_settle_remaining > 0:
		_compile_settle_remaining -= 1
		if _compile_settle_remaining == 0:
			var wall_elapsed: float = (
				Time.get_unix_time_from_system() * 1000.0 - _phase2_wall_start_msec
			)
			print("VFX shader compilation complete: %.0fms" % wall_elapsed)
			set_process(false)
			_release_warmup_viewport()
			preloading_completed.emit()
		return

	if not _is_preloading:
		return

	var now_msec: int = Time.get_ticks_msec()
	var still_active: PackedStringArray = []

	for path in _active:
		var status := ResourceLoader.load_threaded_get_status(path)
		var elapsed: int = now_msec - _active_start_msec.get(path, now_msec)
		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				_loaded_count += 1
				_active_start_msec.erase(path)
			ResourceLoader.THREAD_LOAD_FAILED:
				_debug("Failed to load: " + path)
				_loaded_count += 1
				_active_start_msec.erase(path)
			_:
				if elapsed > per_resource_timeout_ms:
					_debug("Timed out (%dms): %s" % [elapsed, path])
					_timed_out_paths.append(path)
					_loaded_count += 1
					_active_start_msec.erase(path)
				else:
					still_active.append(path)

	_active = still_active
	_fill_active_slots()

	if _queue.is_empty() and _active.is_empty():
		_is_preloading = false
		_debug(
			(
				"Phase 1 complete: %d/%d cached in %.0fms"
				% [
					_loaded_count,
					_total_count,
					Time.get_unix_time_from_system() * 1000.0 - _wall_start_msec
				]
			)
		)
		_start_warmup()


func _fill_active_slots() -> void:
	while _active.size() < max_concurrent_loads and not _queue.is_empty():
		var path: String = _queue.pop_front()
		ResourceLoader.load_threaded_request(path)
		_active.append(path)
		_active_start_msec[path] = Time.get_ticks_msec()


func _start_warmup() -> void:
	_warmup_queue.clear()
	_warmed_count = 0

	for path in scene_paths:
		if ResourceLoader.exists(path) and path not in _timed_out_paths:
			_warmup_queue.append(path)

	if _warmup_queue.is_empty():
		_debug("Phase 2: nothing to warm up")
		set_process(false)
		_release_warmup_viewport()
		preloading_completed.emit()
		return

	_is_warming_up = true
	_phase2_wall_start_msec = Time.get_unix_time_from_system() * 1000.0
	_debug(
		(
			"Phase 2: pipeline warmup — %d scenes (%d skipped, batch %d/frame)"
			% [_warmup_queue.size(), _timed_out_paths.size(), warmup_batch_size]
		)
	)


func _process_warmup_batch() -> void:
	# Free previous batch — these were rendered last frame so shaders are compiled.
	for inst: Node in _warmup_rendered_instances:
		if is_instance_valid(inst):
			_warmup_viewport.remove_child(inst)
			inst.queue_free()
	_warmup_rendered_instances.clear()

	if _warmup_queue.is_empty():
		_is_warming_up = false
		print(
			(
				"VFX preload complete: %d scenes warmed in %.0fms (waiting for GPU...)"
				% [
					_warmed_count,
					Time.get_unix_time_from_system() * 1000.0 - _phase2_wall_start_msec
				]
			)
		)
		_compile_settle_remaining = compile_settle_frames
		_phase2_wall_start_msec = Time.get_unix_time_from_system() * 1000.0
		return

	# Add new batch to viewport — they stay until next frame's render.
	_warmup_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var batch_count: int = mini(warmup_batch_size, _warmup_queue.size())

	for i: int in range(batch_count):
		var path: String = _warmup_queue.pop_front()
		var scene: PackedScene = ResourceLoader.load_threaded_get(path) as PackedScene
		if not scene:
			continue
		var instance: Node = scene.instantiate()
		instance.process_mode = Node.PROCESS_MODE_DISABLED
		_warmup_viewport.add_child(instance)
		_warmup_rendered_instances.append(instance)
		_warmed_count += 1


func is_preloading() -> bool:
	return _is_preloading or _is_warming_up


## Frees the hidden warmup viewport. Called automatically when preloading
## completes; the preloader node itself can be queue_free()d after that.
func _release_warmup_viewport() -> void:
	if _warmup_viewport:
		_warmup_viewport.queue_free()
		_warmup_viewport = null


## 0.0 → 1.0. Phase 1 is the first half, Phase 2 the second.
func get_progress() -> float:
	if _total_count == 0:
		return 1.0
	if _is_preloading:
		return float(_loaded_count) / float(_total_count) * 0.5
	if _is_warming_up:
		var warmup_total: int = _warmed_count + _warmup_queue.size()
		if warmup_total == 0:
			return 0.75
		return 0.5 + (float(_warmed_count) / float(warmup_total) * 0.5)
	return 1.0


func get_phase_label() -> String:
	if _is_preloading:
		return "Loading resources..."
	if _is_warming_up:
		return "Compiling shaders..."
	return "Ready"


func _debug(msg: String) -> void:
	if DEBUG:
		print("VFXPreloader: ", msg)
