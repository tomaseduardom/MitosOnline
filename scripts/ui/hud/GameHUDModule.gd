extends Node
class_name GameHUDModule
## GameHUDModule — Gestiona el HUD de juego: anunciador de fases y botón ¿Paso?.
## Se instancia como hijo de Main en _ready().

var _main: Node = null
var _paso_button: Button = null
var _paso_glow_tween: Tween = null
var _phase_announcer_label: Label = null
var _phase_announcer_tween: Tween = null


func setup(main: Node) -> void:
	_main = main
	_setup_paso_button()
	_setup_phase_announcer()
	# Actualizar botón cuando cambia la prioridad
	var pm = get_node_or_null("/root/PriorityManager")
	if pm:
		pm.priority_changed.connect(func(_p): update_paso_button_state())


# =============================================================================
# ANUNCIADOR DE FASES
# =============================================================================
func _setup_phase_announcer() -> void:
	"""Crea el CanvasLayer y Label para los títulos de fase."""
	var canvas = CanvasLayer.new()
	canvas.layer = 50
	_main.add_child(canvas)

	var vp_size = _main.get_viewport().get_visible_rect().size
	var label_h: float = 110.0

	_phase_announcer_label = Label.new()
	_phase_announcer_label.size = Vector2(vp_size.x, label_h)
	_phase_announcer_label.position = Vector2(0.0, vp_size.y / 2.0 - label_h / 2.0)
	_phase_announcer_label.pivot_offset = Vector2(vp_size.x / 2.0, label_h / 2.0)
	_phase_announcer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phase_announcer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_phase_announcer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_phase_announcer_label.modulate.a = 0.0
	_phase_announcer_label.add_theme_font_size_override("font_size", 68)
	_phase_announcer_label.add_theme_color_override("font_color", Color(1.0, 0.87, 0.2, 1.0))
	_phase_announcer_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	_phase_announcer_label.add_theme_constant_override("outline_size", 6)
	_phase_announcer_label.add_theme_color_override("font_shadow_color", Color(0.55, 0.15, 0.0, 0.85))
	_phase_announcer_label.add_theme_constant_override("shadow_offset_x", 4)
	_phase_announcer_label.add_theme_constant_override("shadow_offset_y", 4)
	canvas.add_child(_phase_announcer_label)


func show_phase_title(text: String) -> void:
	"""Muestra un título de fase: aparece, se mantiene 1.2s y desvanece."""
	if not _phase_announcer_label:
		return
	if _phase_announcer_tween and _phase_announcer_tween.is_valid():
		_phase_announcer_tween.kill()

	_phase_announcer_label.text = text
	_phase_announcer_label.scale = Vector2(1.25, 1.25)
	_phase_announcer_label.modulate.a = 0.0

	_phase_announcer_tween = create_tween()
	_phase_announcer_tween.tween_property(_phase_announcer_label, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_phase_announcer_tween.parallel().tween_property(_phase_announcer_label, "scale", Vector2.ONE, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	_phase_announcer_tween.tween_interval(1.2)
	_phase_announcer_tween.tween_property(_phase_announcer_label, "modulate:a", 0.0, 0.35).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	_phase_announcer_tween.parallel().tween_property(_phase_announcer_label, "scale", Vector2(0.9, 0.9), 0.35).set_ease(Tween.EASE_IN)


# =============================================================================
# BOTÓN ¿PASO?
# =============================================================================
func _setup_paso_button() -> void:
	"""Crea el botón ¿Paso? a la izquierda del TurnTimer."""
	_paso_button = Button.new()
	_paso_button.text = "¿Paso?"
	_paso_button.name = "PasoButton"
	_paso_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var style_normal = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.10, 0.08, 0.18, 0.92)
	style_normal.border_color = Color(0.55, 0.45, 0.85, 0.85)
	style_normal.set_border_width_all(2)
	style_normal.set_corner_radius_all(10)

	var style_hover = StyleBoxFlat.new()
	style_hover.bg_color = Color(0.22, 0.16, 0.38, 1.0)
	style_hover.border_color = Color(0.8, 0.65, 1.0, 1.0)
	style_hover.set_border_width_all(2)
	style_hover.set_corner_radius_all(10)
	style_hover.shadow_color = Color(0.6, 0.45, 1.0, 0.55)
	style_hover.shadow_size = 10

	var style_pressed = StyleBoxFlat.new()
	style_pressed.bg_color = Color(0.32, 0.22, 0.50, 1.0)
	style_pressed.border_color = Color(1.0, 0.85, 1.0, 1.0)
	style_pressed.set_border_width_all(2)
	style_pressed.set_corner_radius_all(10)

	_paso_button.add_theme_stylebox_override("normal", style_normal)
	_paso_button.add_theme_stylebox_override("hover", style_hover)
	_paso_button.add_theme_stylebox_override("pressed", style_pressed)
	_paso_button.add_theme_color_override("font_color", Color(0.85, 0.78, 1.0, 1.0))
	_paso_button.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 1.0, 1.0))
	_paso_button.add_theme_font_size_override("font_size", 15)

	# Posición: justo a la izquierda del TurnTimer
	_paso_button.anchor_left = 1.0
	_paso_button.anchor_top = 0.5
	_paso_button.anchor_right = 1.0
	_paso_button.anchor_bottom = 0.5
	_paso_button.offset_right = -128
	_paso_button.offset_left = -248
	_paso_button.offset_top = -26
	_paso_button.offset_bottom = 26
	_paso_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_paso_button.visible = false

	_main.add_child(_paso_button)
	_paso_button.pressed.connect(func(): _main._on_paso_pressed())


func update_paso_button_state() -> void:
	"""Muestra/oculta el botón según si es el turno del jugador en una fase accionable."""
	if not _paso_button:
		return
	var phase = GameManager.current_phase
	var is_player_turn = (GameManager.active_player_id == 0)
	var relevant_phase = phase in [
		Constants.Phase.VIGILIA,
		Constants.Phase.ATAQUE,
		Constants.Phase.BLOQUEO,
		Constants.Phase.GUERRA_TALISMANES,
		Constants.Phase.FINAL
	]
	var pm = get_node_or_null("/root/PriorityManager")
	var force_show_ataque = (phase == Constants.Phase.ATAQUE and pm and pm.priority_window_active)
	_paso_button.visible = GameManager.is_game_active and (is_player_turn and relevant_phase or force_show_ataque)


func hide_paso_button() -> void:
	if _paso_button:
		_paso_button.visible = false


func start_paso_glow() -> void:
	"""Efecto de pulso/brillo en el botón ¿Paso? para indicar ventana de respuesta activa."""
	if not _paso_button:
		return
	if _paso_glow_tween and _paso_glow_tween.is_valid():
		_paso_glow_tween.kill()
	var style_glow = StyleBoxFlat.new()
	style_glow.bg_color = Color(0.22, 0.10, 0.08, 0.95)
	style_glow.border_color = Color(1.0, 0.55, 0.2, 1.0)
	style_glow.set_border_width_all(3)
	style_glow.set_corner_radius_all(10)
	style_glow.shadow_color = Color(1.0, 0.5, 0.1, 0.7)
	style_glow.shadow_size = 14
	_paso_button.add_theme_stylebox_override("normal", style_glow)
	_paso_button.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1.0))
	_paso_glow_tween = create_tween().set_loops()
	_paso_glow_tween.tween_property(_paso_button, "modulate", Color(1.2, 1.2, 0.9, 1.0), 0.5).set_ease(Tween.EASE_IN_OUT)
	_paso_glow_tween.tween_property(_paso_button, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.5).set_ease(Tween.EASE_IN_OUT)


func stop_paso_glow() -> void:
	"""Detiene el efecto de pulso y restaura el estilo normal del botón ¿Paso?."""
	if _paso_glow_tween and _paso_glow_tween.is_valid():
		_paso_glow_tween.kill()
	_paso_glow_tween = null
	if not _paso_button:
		return
	_paso_button.modulate = Color.WHITE
	var style_normal = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.10, 0.08, 0.18, 0.92)
	style_normal.border_color = Color(0.55, 0.45, 0.85, 0.85)
	style_normal.set_border_width_all(2)
	style_normal.set_corner_radius_all(10)
	_paso_button.add_theme_stylebox_override("normal", style_normal)
	_paso_button.add_theme_color_override("font_color", Color(0.85, 0.78, 1.0, 1.0))
