# demo.gd — showcase + A/B hitch test for the VFXPreloader addon.
#
# Modes (user args after "--"):
#   (default)      preload everything, click to spawn — no hitch
#   --no-preload   skip the preloader; the FIRST click pays the full cost
#                  (texture generation, GPU upload, pipeline compilation)
#   --auto-test    spawn the heavy effect automatically, print a HITCHTEST
#                  measurement line, then quit (used by run_ab_test.ps1)
extends Node3D

const VFX_FOLDER: String = "res://demo/vfx"
const HEAVY_SCENE_PATH: String = "res://demo/vfx/heavy_burst.tscn"
const TIMEOUT_SEC: float = 30.0

const AUTO_SKIP_FRAMES: int = 10
const AUTO_BASELINE_FRAMES: int = 45
const AUTO_MEASURE_FRAMES: int = 6

const BAR_WIDTH: int = 400
const BAR_HEIGHT: int = 12
const COLOR_BG: Color = Color(0.15, 0.15, 0.15, 0.6)
const COLOR_FILL: Color = Color(0.6, 0.4, 0.9, 0.9)
const COLOR_TEXT: Color = Color(0.9, 0.9, 0.9, 0.9)

var _preload_enabled: bool = true
var _auto_test: bool = false

var _preloader: VFXPreloader
var _ready_to_spawn: bool = false
var _heavy_pending: bool = true
var _elapsed: float = 0.0
var _progress_bar: ProgressBar
var _label: Label
var _rng := RandomNumberGenerator.new()

var _auto_stage: int = 0  # 0 = baseline, 1 = measuring, 2 = done
var _auto_frame_count: int = 0
var _baseline_sum: float = 0.0
var _baseline_ms: float = 0.0
var _peak_ms: float = 0.0
var _result_file: String = ""


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_preload_enabled = not args.has("--no-preload")
	_auto_test = args.has("--auto-test")
	for arg in args:
		if arg.begins_with("--result-file="):
			_result_file = arg.get_slice("=", 1)

	_build_stage()
	_build_ui()

	if _preload_enabled:
		_start_preload()
	else:
		_on_preload_completed()
		_label.text = "NO PRELOAD — first click pays the full cost"


func _start_preload() -> void:
	_preloader = VFXPreloader.new()
	_preloader.scene_paths = VFXPreloader.collect_scene_paths(VFX_FOLDER)
	_preloader.preloading_completed.connect(_on_preload_completed)
	add_child(_preloader)
	_preloader.preload_all()


func _process(delta: float) -> void:
	if _auto_test:
		_auto_tick(delta * 1000.0)
		return

	if _ready_to_spawn:
		return

	_elapsed += delta
	if _elapsed >= TIMEOUT_SEC:
		push_warning("Demo: VFX preload timed out after %.1fs" % TIMEOUT_SEC)
		_on_preload_completed()
		return

	_progress_bar.value = _preloader.get_progress() * 100.0
	_label.text = _preloader.get_phase_label()


func _unhandled_input(event: InputEvent) -> void:
	if not _ready_to_spawn or _auto_test:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_spawn_vfx()


func _on_preload_completed() -> void:
	if _ready_to_spawn:
		return
	_ready_to_spawn = true
	_progress_bar.value = 100.0
	_label.text = "Click anywhere to spawn VFX"


func _spawn_vfx() -> void:
	# First click always spawns the heavy effect — it is the one that hitches.
	var path: String = HEAVY_SCENE_PATH if _heavy_pending else _random_vfx_path()
	_heavy_pending = false
	var scene: PackedScene = load(path)
	var fx := scene.instantiate() as Node3D
	if not fx:
		return
	fx.position = Vector3(
		_rng.randf_range(-2.0, 2.0), _rng.randf_range(0.5, 2.5), _rng.randf_range(-2.0, 2.0)
	)
	add_child(fx)


func _random_vfx_path() -> String:
	var paths := (
		_preloader.scene_paths if _preloader else VFXPreloader.collect_scene_paths(VFX_FOLDER)
	)
	return paths[_rng.randi_range(0, paths.size() - 1)]


# --- Auto test -------------------------------------------------------------


func _auto_tick(ms: float) -> void:
	match _auto_stage:
		0:
			_auto_frame_count += 1
			if _auto_frame_count > AUTO_SKIP_FRAMES:
				_baseline_sum += ms
			if _auto_frame_count >= AUTO_SKIP_FRAMES + AUTO_BASELINE_FRAMES and _ready_to_spawn:
				_baseline_ms = _baseline_sum / float(AUTO_BASELINE_FRAMES)
				print(
					(
						"HITCHTEST: baseline %.2fms/frame — spawning heavy effect (mode=%s)..."
						% [_baseline_ms, "preloaded" if _preload_enabled else "no-preload"]
					)
				)
				_spawn_vfx()
				_peak_ms = 0.0
				_auto_frame_count = 0
				_auto_stage = 1
		1:
			_auto_frame_count += 1
			_peak_ms = maxf(_peak_ms, ms)
			if _auto_frame_count >= AUTO_MEASURE_FRAMES:
				var ratio: float = _peak_ms / maxf(_baseline_ms, 0.01)
				var line := (
					"HITCHTEST RESULT: peak=%.1fms baseline=%.2fms ratio=%.1fx mode=%s"
					% [
						_peak_ms,
						_baseline_ms,
						ratio,
						"preloaded" if _preload_enabled else "no-preload"
					]
				)
				print(line)
				if not _result_file.is_empty():
					var f := FileAccess.open(_result_file, FileAccess.WRITE)
					if f:
						f.store_string(line)
				_auto_stage = 2
				get_tree().quit()


# --- Stage / UI ------------------------------------------------------------


func _build_stage() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 1.5, 5.0)
	add_child(camera)
	camera.look_at(Vector3.ZERO)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	add_child(light)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.25, 0.25, 0.28)
	plane.material = floor_mat
	floor_mesh.mesh = plane
	add_child(floor_mesh)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var vp_size: Vector2i = get_viewport().get_visible_rect().size

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	_progress_bar.max_value = 100.0
	_progress_bar.show_percentage = false
	_progress_bar.position = Vector2((vp_size.x - BAR_WIDTH) / 2.0, vp_size.y / 2.0)

	var bg_style: StyleBoxFlat = StyleBoxFlat.new()
	bg_style.bg_color = COLOR_BG
	_progress_bar.add_theme_stylebox_override("background", bg_style)

	var fill_style: StyleBoxFlat = StyleBoxFlat.new()
	fill_style.bg_color = COLOR_FILL
	_progress_bar.add_theme_stylebox_override("fill", fill_style)

	layer.add_child(_progress_bar)

	_label = Label.new()
	_label.text = "Loading..."
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", COLOR_TEXT)
	_label.size = Vector2(vp_size.x, 20)
	_label.position = Vector2(0.0, vp_size.y / 2.0 + 24.0)
	layer.add_child(_label)
