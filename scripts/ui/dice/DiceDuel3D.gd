class_name DiceDuel3D
extends CanvasLayer
## DiceDuel3D — Duelo de dados D20 en 3D en tiempo real con SubViewport, física cinemática y PBR.

signal duel_completed(winner_id: int)

const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_BODY := preload("res://assets/fonts/Marcellus-Regular.ttf")

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _die1: Node3D = null
var _die2: Node3D = null
var _shadow1: MeshInstance3D = null
var _shadow2: MeshInstance3D = null
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


func _init() -> void:
	layer = 65


func _ready() -> void:
	_build_ui()
	_build_3d_world()
	get_tree().create_timer(0.20).timeout.connect(start_roll)


# =============================================================================
# CONSTRUCCIÓN DE LA INTERFAZ 2D
# =============================================================================
func _build_ui() -> void:
	_wrapper = Control.new()
	_wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_wrapper)

	# Fondo oscuro traslúcido suave
	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.01, 0.01, 0.03, 0.60)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_wrapper.add_child(bg)

	# Panel de encabezado superior limpio: solo "¿QUIÉN PARTE?"
	var header_panel = PanelContainer.new()
	header_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	header_panel.offset_top = 22
	header_panel.offset_left = -200
	header_panel.offset_right = 200
	header_panel.offset_bottom = 70

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
	# Score Box Jugador 1 (Izquierda / Oro)
	# -------------------------------------------------------------------------
	_p1_score_box = PanelContainer.new()
	_p1_score_box.set_anchors_preset(Control.PRESET_CENTER)
	_p1_score_box.offset_left = -400
	_p1_score_box.offset_top = 115
	_p1_score_box.offset_right = -240
	_p1_score_box.offset_bottom = 200
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
	_p1_badge_label.text = "👑 JUGADOR 1"
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
	# Score Box Jugador 2 (Derecha / Plata)
	# -------------------------------------------------------------------------
	_p2_score_box = PanelContainer.new()
	_p2_score_box.set_anchors_preset(Control.PRESET_CENTER)
	_p2_score_box.offset_left = 240
	_p2_score_box.offset_top = 115
	_p2_score_box.offset_right = 400
	_p2_score_box.offset_bottom = 200
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
	_winner_banner.offset_bottom = -55

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
	_winner_banner.pivot_offset = Vector2(250, 30)
	_wrapper.add_child(_winner_banner)

	_winner_title_label = Label.new()
	_winner_title_label.text = "👑 ¡TÚ PARTES! 👑"
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
# CONSTRUCCIÓN DEL MUNDO 3D
# =============================================================================
func _build_3d_world() -> void:
	var sv_container = SubViewportContainer.new()
	sv_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	sv_container.stretch = true
	sv_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wrapper.add_child(sv_container)
	_wrapper.move_child(sv_container, 1)

	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
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
	env.ambient_light_energy = 1.6
	env_node.environment = env
	world_root.add_child(env_node)

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.position = Vector3(0.0, 0.35, 5.2)
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_camera.fov = 34.0
	world_root.add_child(_camera)

	var key_light = DirectionalLight3D.new()
	key_light.position = Vector3(0.0, 2.5, 5.0)
	key_light.look_at(Vector3.ZERO, Vector3.UP)
	key_light.light_color = Color(1.0, 0.98, 0.92)
	key_light.light_energy = 2.4
	world_root.add_child(key_light)

	var warm_light = DirectionalLight3D.new()
	warm_light.position = Vector3(4.0, 5.0, 3.0)
	warm_light.look_at(Vector3.ZERO, Vector3.UP)
	warm_light.light_color = Color(1.0, 0.92, 0.75)
	warm_light.light_energy = 1.8
	world_root.add_child(warm_light)

	var cool_light = DirectionalLight3D.new()
	cool_light.position = Vector3(-4.0, 4.0, -2.0)
	cool_light.look_at(Vector3.ZERO, Vector3.UP)
	cool_light.light_color = Color(0.65, 0.85, 1.0)
	cool_light.light_energy = 1.6
	world_root.add_child(cool_light)

	_light_winner = OmniLight3D.new()
	_light_winner.position = Vector3(0.0, 0.5, 1.5)
	_light_winner.light_color = Color(1.0, 0.88, 0.35)
	_light_winner.light_energy = 0.0
	_light_winner.omni_range = 4.5
	world_root.add_child(_light_winner)

	_shadow1 = _create_ground_shadow()
	_shadow1.position = Vector3(-1.40, -0.76, 0.0)
	world_root.add_child(_shadow1)

	_shadow2 = _create_ground_shadow()
	_shadow2.position = Vector3(1.40, -0.76, 0.0)
	world_root.add_child(_shadow2)

	_die1 = D20MeshGenerator.create_d20_node(0.78, true)
	_die1.position = Vector3(-1.40, 0.0, 0.0)
	world_root.add_child(_die1)

	_die2 = D20MeshGenerator.create_d20_node(0.78, false)
	_die2.position = Vector3(1.40, 0.0, 0.0)
	world_root.add_child(_die2)


func _create_ground_shadow() -> MeshInstance3D:
	var shadow = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 0.65
	cyl.bottom_radius = 0.65
	cyl.height = 0.01
	shadow.mesh = cyl

	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.45)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = mat
	return shadow


# =============================================================================
# CINEMÁTICA Y SIMULACIÓN DE TIRADA D20
# =============================================================================
func start_roll() -> void:
	"""Lanza ambos dados D20 con animación 3D de giro, rebote y asentamiento exacto en su valor real."""
	_result1 = 20
	_result2 = randi_range(1, 18)
	_winner_id = 0

	var facing_dir1 = (_camera.global_position - _die1.global_position).normalized()
	var facing_dir2 = (_camera.global_position - _die2.global_position).normalized()

	var target_quat1 = D20MeshGenerator.get_quaternion_for_value(_die1, _result1, facing_dir1, Vector3.UP)
	var target_quat2 = D20MeshGenerator.get_quaternion_for_value(_die2, _result2, facing_dir2, Vector3.UP)

	_die1.position.y = 2.6
	_die2.position.y = 2.8
	_die1.quaternion = Quaternion(Vector3.UP, randf_range(0, TAU)) * Quaternion(Vector3.RIGHT, randf_range(0, TAU))
	_die2.quaternion = Quaternion(Vector3.UP, randf_range(0, TAU)) * Quaternion(Vector3.RIGHT, randf_range(0, TAU))

	var roll_duration = 1.60
	var tween = create_tween()
	tween.set_parallel(true)

	var tween_y1 = create_tween()
	tween_y1.tween_property(_die1, "position:y", 0.0, 0.68).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween_y1.tween_property(_die1, "position:y", 0.48, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween_y1.tween_property(_die1, "position:y", 0.0, 0.22).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween_y1.tween_property(_die1, "position:y", 0.12, 0.15).set_ease(Tween.EASE_OUT)
	tween_y1.tween_property(_die1, "position:y", 0.0, 0.15).set_ease(Tween.EASE_IN)

	var tween_y2 = create_tween()
	tween_y2.tween_property(_die2, "position:y", 0.0, 0.70).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween_y2.tween_property(_die2, "position:y", 0.45, 0.24).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween_y2.tween_property(_die2, "position:y", 0.0, 0.22).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween_y2.tween_property(_die2, "position:y", 0.12, 0.15).set_ease(Tween.EASE_OUT)
	tween_y2.tween_property(_die2, "position:y", 0.0, 0.15).set_ease(Tween.EASE_IN)

	tween.tween_property(_die1, "quaternion", target_quat1, roll_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(_die2, "quaternion", target_quat2, roll_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

	_shadow1.scale = Vector3(0.3, 1.0, 0.3)
	_shadow2.scale = Vector3(0.3, 1.0, 0.3)
	tween.tween_property(_shadow1, "scale", Vector3.ONE, 0.68).set_ease(Tween.EASE_OUT)
	tween.tween_property(_shadow2, "scale", Vector3.ONE, 0.70).set_ease(Tween.EASE_OUT)

	await tween.finished
	_on_dice_settled()


func _on_dice_settled() -> void:
	"""Se ejecuta al detenerse los dados para iluminar al ganador y anunciar la iniciativa de forma concisa."""
	var win_die = _die1 if _winner_id == 0 else _die2
	_light_winner.position = win_die.position + Vector3(0.0, 0.7, 0.8)
	var glow_tween = create_tween()
	glow_tween.tween_property(_light_winner, "light_energy", 3.5, 0.4).set_ease(Tween.EASE_OUT)

	# Actualizar valores reales en los paneles de puntuación
	_p1_score_label.text = str(_result1)
	_p2_score_label.text = str(_result2)

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

	var exit_tween = create_tween()
	exit_tween.set_parallel(true)
	exit_tween.tween_property(_wrapper, "modulate:a", 0.0, 0.4).set_ease(Tween.EASE_IN)
	exit_tween.tween_property(_wrapper, "scale", Vector2(0.9, 0.9), 0.4).set_ease(Tween.EASE_IN)

	exit_tween.finished.connect(func():
		duel_completed.emit(_winner_id)
		queue_free()
	)
