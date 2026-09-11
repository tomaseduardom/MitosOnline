class_name DiceDuel3D
extends CanvasLayer
## DiceDuel3D — Duelo de dados D20 en 3D en tiempo real con SubViewport, física cinemática y PBR.
## Vista cenital estilo mesa de juego y simulación de rodado dinámico multiciclo.

signal duel_completed(winner_id: int)

const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_BODY := preload("res://assets/fonts/Marcellus-Regular.ttf")

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _die1: Node3D = null
var _die2: Node3D = null
var _shadow1: MeshInstance3D = null
var _shadow2: MeshInstance3D = null
var _shadow_mat1: StandardMaterial3D = null
var _shadow_mat2: StandardMaterial3D = null
var _light_winner: OmniLight3D = null

var _p1_score_box: PanelContainer = null
var _p1_score_label: Label = null
var _p1_badge_label: Label = null

var _p2_score_box: PanelContainer = null
var _p2_score_label: Label = null
var _p2_badge_label: Label = null

var _winner_banner: PanelContainer = null
var _winner_title_label: Label = null
var _wrapper: Control = null

var _result1: int = 20
var _result2: int = 12
var _winner_id: int = 0
var _roll_tween: Tween = null
var _is_settled: bool = false
var _is_finishing: bool = false

# Configuración cinemática de lanzamiento y reposo
var _start_pos1 := Vector3(-1.30, 1.20, -0.20)
var _target_pos1 := Vector3(-1.15, 0.15, 0.0)
var _start_pos2 := Vector3(1.30, 1.20, -0.20)
var _target_pos2 := Vector3(1.15, 0.15, 0.0)

var _target_quat1 := Quaternion.IDENTITY
var _target_quat2 := Quaternion.IDENTITY

var _spin_axis1_p: Vector3 = Vector3(0.85, 0.35, -0.40)
var _spin_axis1_s: Vector3 = Vector3(-0.25, 0.90, 0.35)
var _spin_axis2_p: Vector3 = Vector3(-0.80, 0.40, 0.45)
var _spin_axis2_s: Vector3 = Vector3(0.30, 0.85, -0.42)

const TOTAL_ROLL_TIME: float = 2.60


func _init() -> void:
	layer = 65
	_spin_axis1_p = _spin_axis1_p.normalized()
	_spin_axis1_s = _spin_axis1_s.normalized()
	_spin_axis2_p = _spin_axis2_p.normalized()
	_spin_axis2_s = _spin_axis2_s.normalized()


func _ready() -> void:
	_build_ui()
	_build_3d_world()
	get_tree().create_timer(0.20).timeout.connect(start_roll)


# =============================================================================
# CONSTRUCCIÓN DE LA INTERFAZ 2D
# =============================================================================
func _build_ui() -> void:
	_wrapper = Control.new()
	_wrapper.name = "DiceDuelWrapper"
	_wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_wrapper)

	# Fondo oscuro traslúcido suave
	var bg = ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.01, 0.01, 0.03, 0.60)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_wrapper.add_child(bg)

	# Panel de encabezado superior limpio: solo "¿QUIÉN PARTE?"
	var header_panel = PanelContainer.new()
	header_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	header_panel.offset_top = 35
	header_panel.offset_left = -220
	header_panel.offset_right = 220
	header_panel.offset_bottom = 85

	var h_style = StyleBoxFlat.new()
	h_style.bg_color = Color(0.06, 0.05, 0.09, 0.94)
	h_style.border_color = Color(0.85, 0.72, 0.28, 0.9)
	h_style.set_border_width_all(2)
	h_style.set_corner_radius_all(10)
	h_style.shadow_color = Color(0, 0, 0, 0.75)
	h_style.shadow_size = 10
	header_panel.add_theme_stylebox_override("panel", h_style)
	_wrapper.add_child(header_panel)

	var title = Label.new()
	title.text = "¿QUIÉN PARTE?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", FONT_TITLE)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.45, 1.0))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	title.add_theme_constant_override("shadow_offset_x", 1)
	title.add_theme_constant_override("shadow_offset_y", 1)
	header_panel.add_child(title)

	# -------------------------------------------------------------------------
	# Score Box Jugador 1 (Izquierda / Oro - justo debajo del dado)
	# -------------------------------------------------------------------------
	_p1_score_box = PanelContainer.new()
	_p1_score_box.set_anchors_preset(Control.PRESET_CENTER)
	_p1_score_box.offset_left = -360
	_p1_score_box.offset_top = 180
	_p1_score_box.offset_right = -200
	_p1_score_box.offset_bottom = 265
	_p1_score_box.modulate.a = 0.0
	_p1_score_box.scale = Vector2(0.85, 0.85)
	_p1_score_box.pivot_offset = Vector2(80, 42)

	var p1_style = StyleBoxFlat.new()
	p1_style.bg_color = Color(0.10, 0.08, 0.04, 0.95)
	p1_style.border_color = Color(1.0, 0.85, 0.35, 1.0)
	p1_style.set_border_width_all(2)
	p1_style.set_corner_radius_all(10)
	p1_style.shadow_color = Color(1.0, 0.8, 0.2, 0.35)
	p1_style.shadow_size = 12
	_p1_score_box.add_theme_stylebox_override("panel", p1_style)
	_wrapper.add_child(_p1_score_box)

	var p1_vbox = VBoxContainer.new()
	p1_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_p1_score_box.add_child(p1_vbox)

	_p1_badge_label = Label.new()
	_p1_badge_label.text = "JUGADOR 1"
	_p1_badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_p1_badge_label.add_theme_font_override("font", FONT_TITLE)
	_p1_badge_label.add_theme_font_size_override("font_size", 13)
	_p1_badge_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.45, 1.0))
	p1_vbox.add_child(_p1_badge_label)

	_p1_score_label = Label.new()
	_p1_score_label.text = "20"
	_p1_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_p1_score_label.add_theme_font_override("font", FONT_TITLE)
	_p1_score_label.add_theme_font_size_override("font_size", 34)
	_p1_score_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.65, 1.0))
	_p1_score_label.add_theme_color_override("font_shadow_color", Color(0.8, 0.6, 0.1, 0.9))
	_p1_score_label.add_theme_constant_override("shadow_offset_x", 1)
	_p1_score_label.add_theme_constant_override("shadow_offset_y", 1)
	p1_vbox.add_child(_p1_score_label)

	# -------------------------------------------------------------------------
	# Score Box Jugador 2 (Derecha / Plata - justo debajo del dado)
	# -------------------------------------------------------------------------
	_p2_score_box = PanelContainer.new()
	_p2_score_box.set_anchors_preset(Control.PRESET_CENTER)
	_p2_score_box.offset_left = 200
	_p2_score_box.offset_top = 180
	_p2_score_box.offset_right = 360
	_p2_score_box.offset_bottom = 265
	_p2_score_box.modulate.a = 0.0
	_p2_score_box.scale = Vector2(0.85, 0.85)
	_p2_score_box.pivot_offset = Vector2(80, 42)

	var p2_style = StyleBoxFlat.new()
	p2_style.bg_color = Color(0.06, 0.08, 0.11, 0.95)
	p2_style.border_color = Color(0.65, 0.75, 0.85, 0.9)
	p2_style.set_border_width_all(2)
	p2_style.set_corner_radius_all(10)
	_p2_score_box.add_theme_stylebox_override("panel", p2_style)
	_wrapper.add_child(_p2_score_box)

	var p2_vbox = VBoxContainer.new()
	p2_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_p2_score_box.add_child(p2_vbox)

	_p2_badge_label = Label.new()
	_p2_badge_label.text = "OPONENTE"
	_p2_badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_p2_badge_label.add_theme_font_override("font", FONT_TITLE)
	_p2_badge_label.add_theme_font_size_override("font_size", 13)
	_p2_badge_label.add_theme_color_override("font_color", Color(0.75, 0.88, 1.0, 1.0))
	p2_vbox.add_child(_p2_badge_label)

	_p2_score_label = Label.new()
	_p2_score_label.text = "12"
	_p2_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_p2_score_label.add_theme_font_override("font", FONT_TITLE)
	_p2_score_label.add_theme_font_size_override("font_size", 34)
	_p2_score_label.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0, 1.0))
	p2_vbox.add_child(_p2_score_label)

	# -------------------------------------------------------------------------
	# Gran Banner Central de Victoria
	# -------------------------------------------------------------------------
	_winner_banner = PanelContainer.new()
	_winner_banner.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_winner_banner.offset_left = -250
	_winner_banner.offset_top = -115
	_winner_banner.offset_right = 250
	_winner_banner.offset_bottom = -50

	var w_style = StyleBoxFlat.new()
	w_style.bg_color = Color(0.08, 0.14, 0.08, 0.97)
	w_style.border_color = Color(1.0, 0.85, 0.35, 1.0)
	w_style.set_border_width_all(2)
	w_style.set_corner_radius_all(12)
	w_style.shadow_color = Color(1.0, 0.8, 0.2, 0.45)
	w_style.shadow_size = 16
	_winner_banner.add_theme_stylebox_override("panel", w_style)
	_winner_banner.modulate.a = 0.0
	_winner_banner.scale = Vector2(0.85, 0.85)
	_winner_banner.pivot_offset = Vector2(250, 32)
	_wrapper.add_child(_winner_banner)

	_winner_title_label = Label.new()
	_winner_title_label.text = "¡TÚ PARTES!"
	_winner_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_winner_title_label.add_theme_font_override("font", FONT_TITLE)
	_winner_title_label.add_theme_font_size_override("font_size", 22)
	_winner_title_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.50, 1.0))
	_winner_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_winner_title_label.add_theme_constant_override("shadow_offset_x", 1)
	_winner_title_label.add_theme_constant_override("shadow_offset_y", 1)
	_winner_banner.add_child(_winner_title_label)


# =============================================================================
# CONSTRUCCIÓN DEL MUNDO 3D (VISTA CENITAL DESDE ARRIBA)
# =============================================================================
func _build_3d_world() -> void:
	var sv_container = SubViewportContainer.new()
	sv_container.name = "SubViewportContainer"
	sv_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv_container.stretch = true
	sv_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wrapper.add_child(sv_container)
	_wrapper.move_child(sv_container, 1)

	_viewport = SubViewport.new()
	_viewport.name = "SubViewport"
	_viewport.size = Vector2i(1920, 1080)
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	sv_container.add_child(_viewport)

	var world_root = Node3D.new()
	world_root.name = "WorldRoot"
	_viewport.add_child(world_root)

	var env_node = WorldEnvironment.new()
	var env = Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.92, 0.94, 0.98)
	env.ambient_light_energy = 1.8
	env_node.environment = env
	world_root.add_child(env_node)

	# Cámara cenital elevada perfectamente enfocada en los dados en el centro
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.current = true
	world_root.add_child(_camera)
	_camera.position = Vector3(0.0, 3.2, 4.4)
	_camera.look_at(Vector3(0.0, 0.15, 0.0), Vector3.UP)
	_camera.fov = 30.0

	# Luz cenital clave (luz cálida solar)
	var key_light = DirectionalLight3D.new()
	world_root.add_child(key_light)
	key_light.position = Vector3(1.0, 6.0, 3.5)
	key_light.look_at(Vector3.ZERO, Vector3.UP)
	key_light.light_color = Color(1.0, 0.96, 0.88)
	key_light.light_energy = 2.6

	# Luz de contraste y brillo lateral
	var warm_light = DirectionalLight3D.new()
	world_root.add_child(warm_light)
	warm_light.position = Vector3(4.0, 5.0, 2.0)
	warm_light.look_at(Vector3.ZERO, Vector3.UP)
	warm_light.light_color = Color(1.0, 0.92, 0.75)
	warm_light.light_energy = 1.8

	# Luz de contorno azulada
	var cool_light = DirectionalLight3D.new()
	world_root.add_child(cool_light)
	cool_light.position = Vector3(-4.0, 4.0, -2.5)
	cool_light.look_at(Vector3.ZERO, Vector3.UP)
	cool_light.light_color = Color(0.70, 0.85, 1.0)
	cool_light.light_energy = 1.6

	# Luz de foco al vencedor
	_light_winner = OmniLight3D.new()
	_light_winner.position = Vector3(0.0, 2.0, 1.0)
	_light_winner.light_color = Color(1.0, 0.90, 0.40)
	_light_winner.light_energy = 0.0
	_light_winner.omni_range = 5.0
	world_root.add_child(_light_winner)

	# Sombras de suelo proyectadas
	var sh1_data = _create_ground_shadow()
	_shadow1 = sh1_data["mesh"]
	_shadow_mat1 = sh1_data["mat"]
	_shadow1.position = Vector3(_start_pos1.x, -0.68, _start_pos1.z)
	world_root.add_child(_shadow1)

	var sh2_data = _create_ground_shadow()
	_shadow2 = sh2_data["mesh"]
	_shadow_mat2 = sh2_data["mat"]
	_shadow2.position = Vector3(_start_pos2.x, -0.68, _start_pos2.z)
	world_root.add_child(_shadow2)

	_die1 = D20MeshGenerator.create_d20_node(0.85, true)
	_die1.position = _start_pos1
	world_root.add_child(_die1)

	_die2 = D20MeshGenerator.create_d20_node(0.85, false)
	_die2.position = _start_pos2
	world_root.add_child(_die2)


func _create_ground_shadow() -> Dictionary:
	var shadow = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 0.70
	cyl.bottom_radius = 0.70
	cyl.height = 0.01
	shadow.mesh = cyl

	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.50)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = mat
	return {"mesh": shadow, "mat": mat}


# =============================================================================
# CINEMÁTICA Y SIMULACIÓN DE TIRADA D20 (MULTIVUELTAS Y REBOTES)
# =============================================================================
func start_roll() -> void:
	"""Lanza ambos dados D20 con simulación multiciclo de rodado, giros 3D y asentamiento exacto."""
	_result1 = randi_range(1, 20)
	_result2 = randi_range(1, 20)
	if _result1 == _result2:
		_result1 = 20 if _result1 < 20 else 19
	_winner_id = 0 if _result1 > _result2 else 1

	# Normal orientada directamente hacia la cámara cenital desde la posición final de reposo
	var facing_dir1 = (_camera.global_position - _target_pos1).normalized()
	var facing_dir2 = (_camera.global_position - _target_pos2).normalized()

	_target_quat1 = D20MeshGenerator.get_quaternion_for_value(_die1, _result1, facing_dir1, Vector3.UP)
	_target_quat2 = D20MeshGenerator.get_quaternion_for_value(_die2, _result2, facing_dir2, Vector3.UP)

	# Animación frame a frame para rodado continuo con física de rebotes
	_roll_tween = create_tween()
	_roll_tween.tween_method(_animate_roll_step, 0.0, 1.0, TOTAL_ROLL_TIME).set_trans(Tween.TRANS_LINEAR)
	await _roll_tween.finished

	_on_dice_settled()


func _unhandled_input(event: InputEvent) -> void:
	if _is_finishing:
		return
	if (event is InputEventMouseButton and event.pressed) or (event is InputEventKey and event.pressed and not event.is_echo()):
		_skip()


func _skip() -> void:
	if _is_finishing:
		return
	if not _is_settled:
		if _roll_tween and _roll_tween.is_valid():
			_roll_tween.kill()
		_die1.position = _target_pos1
		_die2.position = _target_pos2
		_die1.quaternion = _target_quat1
		_die2.quaternion = _target_quat2
		if _shadow1:
			_shadow1.position = Vector3(_target_pos1.x, -0.68, _target_pos1.z)
		if _shadow2:
			_shadow2.position = Vector3(_target_pos2.x, -0.68, _target_pos2.z)
		_on_dice_settled()
	else:
		_finish_duel()


func _animate_roll_step(progress: float) -> void:
	var t_cur = progress * TOTAL_ROLL_TIME
	var p_ease = 1.0 - pow(1.0 - progress, 3.0)  # Desaceleración en X/Z

	# -------------------------------------------------------------------------
	# 1. Posiciones X / Z / Y
	# -------------------------------------------------------------------------
	var y1 = _calc_bounce_y(t_cur, _start_pos1.y - _target_pos1.y) + _target_pos1.y
	var x1 = lerp(_start_pos1.x, _target_pos1.x, p_ease)
	var z1 = lerp(_start_pos1.z, _target_pos1.z, p_ease)
	_die1.position = Vector3(x1, y1, z1)

	var y2 = _calc_bounce_y(t_cur, _start_pos2.y - _target_pos2.y) + _target_pos2.y
	var x2 = lerp(_start_pos2.x, _target_pos2.x, p_ease)
	var z2 = lerp(_start_pos2.z, _target_pos2.z, p_ease)
	_die2.position = Vector3(x2, y2, z2)

	# -------------------------------------------------------------------------
	# 2. Rotación 3D Multieje Dinámica (Tumbling realista que converge exactamente)
	# -------------------------------------------------------------------------
	# Total de giros: 5.5 vueltas decrecientes
	var spin_angle1 = (TAU * 5.5) * pow(1.0 - progress, 2.6)
	var rot_spin1 = Quaternion(_spin_axis1_p, spin_angle1) * Quaternion(_spin_axis1_s, spin_angle1 * 0.5)
	_die1.quaternion = (_target_quat1 * rot_spin1).normalized()

	var spin_angle2 = (TAU * 6.0) * pow(1.0 - progress, 2.6)
	var rot_spin2 = Quaternion(_spin_axis2_p, spin_angle2) * Quaternion(_spin_axis2_s, spin_angle2 * 0.55)
	_die2.quaternion = (_target_quat2 * rot_spin2).normalized()

	# -------------------------------------------------------------------------
	# 3. Sombras de suelo sincronizadas
	# -------------------------------------------------------------------------
	if _shadow1 and _shadow_mat1:
		_shadow1.position = Vector3(x1, -0.68, z1)
		var sc1 = clamp(1.0 - (y1 - _target_pos1.y) * 0.20, 0.30, 1.0)
		_shadow1.scale = Vector3(sc1, 1.0, sc1)
		_shadow_mat1.albedo_color.a = clamp(0.50 - (y1 - _target_pos1.y) * 0.10, 0.10, 0.50)

	if _shadow2 and _shadow_mat2:
		_shadow2.position = Vector3(x2, -0.68, z2)
		var sc2 = clamp(1.0 - (y2 - _target_pos2.y) * 0.20, 0.30, 1.0)
		_shadow2.scale = Vector3(sc2, 1.0, sc2)
		_shadow_mat2.albedo_color.a = clamp(0.50 - (y2 - _target_pos2.y) * 0.10, 0.10, 0.50)


func _calc_bounce_y(t: float, start_y: float) -> float:
	# Curva de 5 fases de rebote con micro-impactos contenidos
	if t <= 0.70:
		var p = t / 0.70
		return start_y * (1.0 - p * p)
	elif t <= 1.30:
		var p = (t - 0.70) / 0.60
		return 0.45 * sin(p * PI)
	elif t <= 1.80:
		var p = (t - 1.30) / 0.50
		return 0.18 * sin(p * PI)
	elif t <= 2.20:
		var p = (t - 1.80) / 0.40
		return 0.06 * sin(p * PI)
	elif t <= 2.45:
		var p = (t - 2.20) / 0.25
		return 0.02 * sin(p * PI)
	else:
		return 0.0


func _on_dice_settled() -> void:
	"""Se ejecuta al detenerse los dados para iluminar al ganador y anunciar la iniciativa de forma concisa."""
	if _is_settled:
		return
	_is_settled = true

	var win_die = _die1 if _winner_id == 0 else _die2
	_light_winner.position = win_die.position + Vector3(0.0, 1.2, 0.6)
	var glow_tween = create_tween()
	glow_tween.tween_property(_light_winner, "light_energy", 4.5, 0.4).set_ease(Tween.EASE_OUT)

	# Actualizar valores reales en los paneles de puntuación
	_p1_score_label.text = str(_result1)
	_p2_score_label.text = str(_result2)

	if _winner_id == 0:
		_winner_title_label.text = "¡TÚ PARTES!"
	else:
		_winner_title_label.text = "¡OPONENTE PARTE!"

	# Animar paneles de puntuación
	var p_tween = create_tween()
	p_tween.set_parallel(true)
	p_tween.tween_property(_p1_score_box, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT)
	p_tween.tween_property(_p1_score_box, "scale", Vector2.ONE, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	p_tween.tween_property(_p2_score_box, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT)
	p_tween.tween_property(_p2_score_box, "scale", Vector2.ONE, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	# Animar Banner de Victoria
	var banner_tween = create_tween()
	banner_tween.set_parallel(true)
	banner_tween.tween_property(_winner_banner, "modulate:a", 1.0, 0.30).set_ease(Tween.EASE_OUT)
	banner_tween.tween_property(_winner_banner, "scale", Vector2.ONE, 0.30).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	await get_tree().create_timer(1.8).timeout
	_finish_duel()


func _finish_duel() -> void:
	if _is_finishing:
		return
	_is_finishing = true

	var exit_tween = create_tween()
	exit_tween.set_parallel(true)
	exit_tween.tween_property(_wrapper, "modulate:a", 0.0, 0.3).set_ease(Tween.EASE_IN)
	exit_tween.tween_property(_wrapper, "scale", Vector2(0.9, 0.9), 0.3).set_ease(Tween.EASE_IN)

	exit_tween.finished.connect(func():
		duel_completed.emit(_winner_id)
		queue_free()
	)
