# Generates a 1024x1024 noise texture ONCE per session (static cache) and
# feeds it to the draw-pass shader. The FIRST instantiation pays:
#   - CPU: ~1M per-pixel noise generation
#   - GPU: texture upload + shader pipeline compilation
# ...which is exactly the cost the VFXPreloader absorbs during warmup.
# The static cache means later spawns in --no-preload mode are cheap too,
# proving the hitch was first-use cost.
extends GPUParticles3D

const TEX_SIZE: int = 1024

static var _shared_tex: ImageTexture = null


func _ready() -> void:
	if _shared_tex == null:
		_shared_tex = _generate_noise_texture()
	var prim := draw_pass_1 as PrimitiveMesh
	if prim:
		var mat := prim.material as ShaderMaterial
		if mat:
			mat.set_shader_parameter("noise_tex", _shared_tex)
	finished.connect(queue_free)


func _generate_noise_texture() -> ImageTexture:
	var img := Image.create_empty(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 1337
	noise.fractal_octaves = 5
	noise.frequency = 0.004
	for y: int in range(TEX_SIZE):
		for x: int in range(TEX_SIZE):
			var v: float = noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			img.set_pixel(x, y, Color(v, v, v))
	return ImageTexture.create_from_image(img)
