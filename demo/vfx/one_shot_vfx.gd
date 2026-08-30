# Frees the effect once its one-shot emission finishes.
# Attach to a GPUParticles3D with one_shot = true.
extends GPUParticles3D


func _ready() -> void:
	finished.connect(queue_free)
