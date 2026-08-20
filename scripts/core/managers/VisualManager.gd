extends Node
## VisualManager - Singleton que controla efectos visuales reactivos
## Maneja el fondo, screen shake y feedback visual para eventos del juego

# =============================================================================
# SEÑALES
# =============================================================================
signal effect_started(effect_name: String)
signal effect_finished(effect_name: String)

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
## Umbral de coste para considerar una carta "de alto coste"
@export var high_cost_threshold: int = 5

## Intensidad base del shader de fondo
@export var base_shader_intensity: float = 0.5

## Intensidad aumentada para eventos dramáticos
@export var dramatic_shader_intensity: float = 0.8

## Velocidad base del shader
@export var base_shader_speed: float = 1.0

## Velocidad aumentada para eventos
@export var dramatic_shader_speed: float = 3.0

## Duración de las transiciones visuales
@export var transition_duration: float = 0.6

## Intensidad del screen shake
@export var shake_intensity: float = 8.0

## Duración del screen shake
@export var shake_duration: float = 0.3

# =============================================================================
# REFERENCIAS
# =============================================================================
var background: CanvasItem = null
var game_camera: Camera2D = null
var main_node: Control = null

# Estado interno
var _is_shaking: bool = false
var _original_camera_offset: Vector2 = Vector2.ZERO
var _active_tweens: Dictionary = {}

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	print("[VisualManager] Inicializado")


func setup(main: Control, bg: CanvasItem, camera: Camera2D = null) -> void:
	"""Configura las referencias necesarias para el VisualManager"""
	main_node = main
	background = bg
	game_camera = camera

	if background:
		_setup_background_shader()

	# Conectar señales del GameManager
	_connect_game_signals()

	print("[VisualManager] Configurado - Background: %s, Camera: %s" % [
		"OK" if background else "NO",
		"OK" if game_camera else "NO"
	])


func _setup_background_shader() -> void:
	"""Configura el shader del fondo - solo efectos sutiles sobre la textura"""
	# No aplicar shader si el fondo tiene textura (TextureRect)
	if background is TextureRect and background.texture:
		print("[VisualManager] Fondo con textura detectado, sin shader")
		return

	if not background.material:
		var shader_material = ShaderMaterial.new()
		shader_material.shader = _create_default_shader()
		background.material = shader_material

	# Establecer valores base
	_set_shader_param("intensity", base_shader_intensity)
	_set_shader_param("speed", base_shader_speed)


func _connect_game_signals() -> void:
	"""Conecta las señales del GameManager"""
	if GameManager:
		if not GameManager.card_played.is_connected(_on_card_played):
			GameManager.card_played.connect(_on_card_played)
		if not DamageManager.damage_dealt.is_connected(_on_damage_dealt):
			DamageManager.damage_dealt.connect(_on_damage_dealt)
		if not GameManager.phase_changed.is_connected(_on_phase_changed):
			GameManager.phase_changed.connect(_on_phase_changed)
		print("[VisualManager] Señales del GameManager conectadas")


# =============================================================================
# SHADER DEL FONDO
# =============================================================================
func _create_default_shader() -> Shader:
	"""Crea un shader por defecto para el fondo reactivo"""
	var shader = Shader.new()
	shader.code = """
shader_type canvas_item;

// Parámetros controlables desde GDScript
uniform float intensity : hint_range(0.0, 1.0) = 0.3;
uniform float speed : hint_range(0.0, 5.0) = 1.0;
uniform vec4 color_primary : source_color = vec4(0.08, 0.10, 0.18, 1.0);
uniform vec4 color_secondary : source_color = vec4(0.12, 0.18, 0.28, 1.0);
uniform vec4 color_accent : source_color = vec4(0.20, 0.35, 0.55, 1.0);
uniform float noise_scale : hint_range(1.0, 20.0) = 8.0;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.4;

// Función de ruido simple
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	vec2 uv = UV;
	float time = TIME * speed;

	// Ruido animado
	float n = fbm(uv * noise_scale + vec2(time * 0.1, time * 0.05));
	float n2 = fbm(uv * noise_scale * 0.5 - vec2(time * 0.08, time * 0.12));

	// Mezcla de colores basada en ruido e intensidad
	vec4 color = mix(color_primary, color_secondary, n * intensity);
	color = mix(color, color_accent, n2 * intensity * 0.5);

	// Efecto de viñeta
	vec2 center = uv - 0.5;
	float vignette = 1.0 - dot(center, center) * vignette_strength * 2.0;
	color.rgb *= vignette;

	// Pulso sutil basado en intensidad
	float pulse = sin(time * 2.0) * 0.02 * intensity;
	color.rgb += pulse;

	COLOR = color;
}
"""
	return shader


func _set_shader_param(param_name: String, value: Variant) -> void:
	"""Establece un parámetro del shader del fondo"""
	if background and background.material is ShaderMaterial:
		(background.material as ShaderMaterial).set_shader_parameter(param_name, value)


func _get_shader_param(param_name: String) -> Variant:
	"""Obtiene un parámetro del shader del fondo"""
	if background and background.material is ShaderMaterial:
		return (background.material as ShaderMaterial).get_shader_parameter(param_name)
	return null


# =============================================================================
# EFECTOS DE FONDO
# =============================================================================
func pulse_background(target_intensity: float = -1.0, duration: float = -1.0) -> void:
	"""Hace un pulso en el fondo aumentando la intensidad temporalmente"""
	if not background:
		return

	var _intensity = target_intensity if target_intensity >= 0 else dramatic_shader_intensity
	var _duration = duration if duration >= 0 else transition_duration

	_kill_tween("background_intensity")

	var current = _get_shader_param("intensity")
	if current == null:
		current = base_shader_intensity

	var tween = create_tween()
	_active_tweens["background_intensity"] = tween

	# Subir intensidad
	tween.tween_method(func(v): _set_shader_param("intensity", v), current, _intensity, _duration * 0.3)
	# Mantener un momento
	tween.tween_interval(_duration * 0.2)
	# Bajar intensidad
	tween.tween_method(func(v): _set_shader_param("intensity", v), _intensity, base_shader_intensity, _duration * 0.5)

	emit_signal("effect_started", "background_pulse")
	tween.finished.connect(func(): emit_signal("effect_finished", "background_pulse"))


func set_background_intensity(intensity: float, duration: float = 0.5) -> void:
	"""Cambia la intensidad del fondo con transición suave"""
	if not background:
		return

	_kill_tween("background_intensity")

	var current = _get_shader_param("intensity")
	if current == null:
		current = base_shader_intensity

	var tween = create_tween()
	_active_tweens["background_intensity"] = tween
	tween.tween_method(func(v): _set_shader_param("intensity", v), current, intensity, duration)


func set_background_speed(speed: float, duration: float = 0.5) -> void:
	"""Cambia la velocidad de animación del fondo"""
	if not background:
		return

	_kill_tween("background_speed")

	var current = _get_shader_param("speed")
	if current == null:
		current = base_shader_speed

	var tween = create_tween()
	_active_tweens["background_speed"] = tween
	tween.tween_method(func(v): _set_shader_param("speed", v), current, speed, duration)


func dramatic_background(duration: float = 1.0) -> void:
	"""Activa un efecto dramático en el fondo (alta intensidad y velocidad)"""
	if not background:
		return

	emit_signal("effect_started", "dramatic_background")

	# Aumentar intensidad y velocidad
	set_background_intensity(dramatic_shader_intensity, duration * 0.3)
	set_background_speed(dramatic_shader_speed, duration * 0.3)

	# Programar el retorno a valores normales
	var reset_tween = create_tween()
	reset_tween.tween_interval(duration * 0.5)
	reset_tween.tween_callback(func():
		set_background_intensity(base_shader_intensity, duration * 0.5)
		set_background_speed(base_shader_speed, duration * 0.5)
	)
	reset_tween.tween_interval(duration * 0.5)
	reset_tween.tween_callback(func(): emit_signal("effect_finished", "dramatic_background"))


func set_background_accent_color(color: Color, duration: float = 0.5) -> void:
	"""Cambia el color de acento del fondo"""
	if not background:
		return

	_kill_tween("background_color")

	var current = _get_shader_param("color_accent")
	if current == null:
		current = Color(0.15, 0.25, 0.4, 1.0)

	var tween = create_tween()
	_active_tweens["background_color"] = tween
	tween.tween_method(func(v): _set_shader_param("color_accent", v), current, color, duration)


# =============================================================================
# SCREEN SHAKE
# =============================================================================
func screen_shake(intensity: float = -1.0, duration: float = -1.0) -> void:
	"""Aplica un efecto de sacudida a la pantalla"""
	var _intensity = intensity if intensity >= 0 else shake_intensity
	var _duration = duration if duration >= 0 else shake_duration

	if _is_shaking:
		return

	_is_shaking = true
	emit_signal("effect_started", "screen_shake")

	# Si hay cámara, usarla
	if game_camera:
		_shake_camera(_intensity, _duration)
	# Si no, sacudir el nodo principal
	elif main_node:
		_shake_node(main_node, _intensity, _duration)


func _shake_camera(intensity: float, duration: float) -> void:
	"""Sacude la cámara"""
	_original_camera_offset = game_camera.offset

	var tween = create_tween()
	var shake_count = int(duration / 0.05)

	for i in range(shake_count):
		var progress = float(i) / float(shake_count)
		var current_intensity = intensity * (1.0 - progress)  # Decrece con el tiempo

		var offset = Vector2(
			randf_range(-current_intensity, current_intensity),
			randf_range(-current_intensity, current_intensity)
		)
		tween.tween_property(game_camera, "offset", _original_camera_offset + offset, 0.05)

	# Volver a la posición original
	tween.tween_property(game_camera, "offset", _original_camera_offset, 0.1)
	tween.tween_callback(func():
		_is_shaking = false
		emit_signal("effect_finished", "screen_shake")
	)


func _shake_node(node: Control, intensity: float, duration: float) -> void:
	"""Sacude un nodo Control"""
	var original_pos = node.position

	var tween = create_tween()
	var shake_count = int(duration / 0.05)

	for i in range(shake_count):
		var progress = float(i) / float(shake_count)
		var current_intensity = intensity * (1.0 - progress)

		var offset = Vector2(
			randf_range(-current_intensity, current_intensity),
			randf_range(-current_intensity, current_intensity)
		)
		tween.tween_property(node, "position", original_pos + offset, 0.05)

	tween.tween_property(node, "position", original_pos, 0.1)
	tween.tween_callback(func():
		_is_shaking = false
		emit_signal("effect_finished", "screen_shake")
	)


# =============================================================================
# EFECTOS COMPUESTOS
# =============================================================================
func play_card_effect(card_cost: int) -> void:
	"""Efecto visual cuando se juega una carta"""
	# Screen shake sutil
	screen_shake(4.0, 0.2)

	# Si es carta de alto coste, efecto dramático
	if card_cost >= high_cost_threshold:
		dramatic_background(1.2)
	else:
		pulse_background(base_shader_intensity + 0.2, 0.5)


func play_damage_effect(amount: int) -> void:
	"""Efecto visual cuando se recibe daño"""
	# Color rojizo temporal
	set_background_accent_color(Color(0.5, 0.1, 0.1, 1.0), 0.2)

	# Shake proporcional al daño
	var shake_power = clampf(float(amount) * 2.0, 4.0, 20.0)
	screen_shake(shake_power, 0.3)

	# Volver al color normal
	var tween = create_tween()
	tween.tween_interval(0.5)
	tween.tween_callback(func():
		set_background_accent_color(Color(0.15, 0.25, 0.4, 1.0), 0.8)
	)


func play_battle_start_effect() -> void:
	"""Efecto visual al inicio de la batalla"""
	# Color más intenso y cálido
	set_background_accent_color(Color(0.4, 0.2, 0.1, 1.0), 0.5)
	set_background_intensity(0.5, 0.5)
	set_background_speed(2.0, 0.5)


func play_battle_end_effect() -> void:
	"""Efecto visual al final de la batalla"""
	# Volver a valores normales
	set_background_accent_color(Color(0.15, 0.25, 0.4, 1.0), 0.8)
	set_background_intensity(base_shader_intensity, 0.8)
	set_background_speed(base_shader_speed, 0.8)


func play_victory_effect() -> void:
	"""Efecto visual de victoria"""
	# Dorado brillante
	set_background_accent_color(Color(0.8, 0.6, 0.2, 1.0), 0.5)
	dramatic_background(2.0)


func play_defeat_effect() -> void:
	"""Efecto visual de derrota"""
	# Oscuro y apagado
	set_background_accent_color(Color(0.2, 0.1, 0.1, 1.0), 0.5)
	set_background_intensity(0.1, 1.0)
	set_background_speed(0.3, 1.0)


# =============================================================================
# CALLBACKS DE SEÑALES
# =============================================================================
func _on_card_played(card: Node, player_id: int) -> void:
	"""Callback cuando se juega una carta"""
	if player_id == 0:  # Solo efectos para el jugador humano
		var cost = card.card_cost if card.has_method("get_strength") or "card_cost" in card else 0
		play_card_effect(cost)


func _on_damage_dealt(target_id: int, amount: int, _actual: int, _type: String) -> void:
	"""Callback cuando se hace daño (firma: DamageManager.damage_dealt)"""
	if target_id == 0:  # Daño al jugador humano
		play_damage_effect(amount)
	else:
		# Daño al oponente - efecto más sutil
		pulse_background(0.5, 0.4)


func _on_phase_changed(new_phase: Constants.Phase) -> void:
	"""Callback cuando cambia la fase"""
	match new_phase:
		Constants.Phase.ATAQUE:
			play_battle_start_effect()
		Constants.Phase.FINAL:
			play_battle_end_effect()


# =============================================================================
# UTILIDADES
# =============================================================================
func _kill_tween(tween_name: String) -> void:
	"""Detiene un tween activo por nombre"""
	if tween_name in _active_tweens:
		var tween = _active_tweens[tween_name]
		if tween and tween.is_valid():
			tween.kill()
		_active_tweens.erase(tween_name)


func reset_all_effects() -> void:
	"""Resetea todos los efectos a valores base"""
	# Matar todos los tweens activos
	for tween_name in _active_tweens.keys():
		_kill_tween(tween_name)

	# Restaurar valores base del shader
	if background:
		_set_shader_param("intensity", base_shader_intensity)
		_set_shader_param("speed", base_shader_speed)
		_set_shader_param("color_accent", Color(0.15, 0.25, 0.4, 1.0))

	_is_shaking = false

	# Restaurar posición de cámara/nodo
	if game_camera:
		game_camera.offset = _original_camera_offset
	elif main_node:
		main_node.position = Vector2.ZERO
