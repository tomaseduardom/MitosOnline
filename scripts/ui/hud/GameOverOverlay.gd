extends Control
class_name GameOverOverlay
## GameOverOverlay — Pantalla cinemática de fin de partida (Victoria / Derrota).
## Exhibe el resultado, estadísticas de combate y botones de acción (Jugar de nuevo, Menú, Ver Mesa).

signal rematch_requested
signal menu_requested

const FONT_TITLE = preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_REGULAR = preload("res://assets/fonts/Marcellus-Regular.ttf")

var _backdrop: ColorRect = null
var _modal_panel: PanelContainer = null
var _inspect_bar: Button = null
var _particles: CPUParticles2D = null

var _btn_rematch: Button = null
var _btn_menu: Button = null
var _btn_inspect: Button = null

var _is_inspecting: bool = false
var _last_stats: Dictionary = {}


func _init() -> void:
	z_index = 500
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		if _particles:
			_particles.position = size / 2.0


func _ready() -> void:
	_ensure_ui()
	if _last_stats.is_empty():
		visible = false


func _ensure_ui() -> void:
	if _backdrop != null:
		return
	_build_ui()



func _build_ui() -> void:
	# 1. Telón oscuro con viñeta
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.02, 0.02, 0.04, 0.86)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	# 2. Partículas ambientales cinemáticas
	_particles = CPUParticles2D.new()
	_particles.position = size / 2.0 if size != Vector2.ZERO else Vector2(960, 540)
	_particles.amount = 36
	_particles.lifetime = 3.0
	_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_particles.emission_rect_extents = Vector2(380, 240)
	_particles.direction = Vector2(0, -1)
	_particles.spread = 35.0
	_particles.gravity = Vector2(0, -12)
	_particles.initial_velocity_min = 20.0
	_particles.initial_velocity_max = 45.0
	_particles.scale_amount_min = 2.0
	_particles.scale_amount_max = 4.5
	_particles.color = Color(1.0, 0.85, 0.35, 0.70)
	add_child(_particles)

	# 3. Panel central modal
	_modal_panel = PanelContainer.new()
	_modal_panel.custom_minimum_size = Vector2(700, 0)
	_modal_panel.set_anchors_preset(Control.PRESET_CENTER)
	_modal_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_modal_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_modal_panel)

	# 4. Barra flotante superior para modo "Inspeccionar Tablero"
	_inspect_bar = Button.new()
	_inspect_bar.text = "Modo Inspección de Mesa — Clic aquí o presiona [Enter] / [ESC] para volver al resultado"
	_inspect_bar.custom_minimum_size = Vector2(620, 42)
	_inspect_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_inspect_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_inspect_bar.offset_top = 16
	_inspect_bar.add_theme_font_override("font", FONT_REGULAR)
	_inspect_bar.add_theme_font_size_override("font_size", 14)
	_inspect_bar.add_theme_color_override("font_color", Color(1.0, 0.92, 0.75))
	
	var bar_style = StyleBoxFlat.new()
	bar_style.bg_color = Color(0.08, 0.08, 0.12, 0.92)
	bar_style.border_width_bottom = 2
	bar_style.border_width_left = 2
	bar_style.border_width_right = 2
	bar_style.border_width_top = 2
	bar_style.border_color = Color(0.85, 0.72, 0.30, 0.90)
	bar_style.corner_radius_bottom_left = 20
	bar_style.corner_radius_bottom_right = 20
	bar_style.corner_radius_top_left = 20
	bar_style.corner_radius_top_right = 20
	bar_style.shadow_size = 10
	bar_style.shadow_color = Color(0, 0, 0, 0.8)
	_inspect_bar.add_theme_stylebox_override("normal", bar_style)
	_inspect_bar.add_theme_stylebox_override("hover", bar_style)
	_inspect_bar.add_theme_stylebox_override("pressed", bar_style)
	_inspect_bar.pressed.connect(_on_restore_from_inspect)
	_inspect_bar.visible = false
	add_child(_inspect_bar)


func show_game_over(stats: Dictionary, animate: bool = true) -> void:
	"""Muestra la pantalla de fin de partida con animaciones y datos cinemáticos."""
	_ensure_ui()
	_last_stats = stats
	_is_inspecting = false
	visible = true
	_inspect_bar.visible = false
	_backdrop.visible = true
	_modal_panel.visible = true

	var is_victory: bool = stats.get("is_victory", stats.get("winner", 0) == 0)

	# 1. Estilizar panel modal según resultado
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.11, 0.97)
	style.border_width_bottom = 2
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.corner_radius_bottom_left = 16
	style.corner_radius_bottom_right = 16
	style.corner_radius_top_left = 16
	style.corner_radius_top_right = 16
	style.shadow_size = 32
	style.shadow_color = Color(0, 0, 0, 0.92)
	style.content_margin_left = 32
	style.content_margin_right = 32
	style.content_margin_top = 26
	style.content_margin_bottom = 26

	if is_victory:
		style.border_color = Color(0.88, 0.74, 0.28, 1.0) # Oro mítico
		_particles.color = Color(1.0, 0.88, 0.38, 0.75)
		_particles.gravity = Vector2(0, -14)
	else:
		style.border_color = Color(0.84, 0.22, 0.22, 1.0) # Carmesí cenizo
		_particles.color = Color(0.88, 0.25, 0.20, 0.55)
		_particles.gravity = Vector2(0, 10) # Cenizas descendentes

	_modal_panel.add_theme_stylebox_override("panel", style)

	# Limpiar contenido anterior
	for child in _modal_panel.get_children():
		child.queue_free()

	# 2. Contenedor vertical principal
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	_modal_panel.add_child(vbox)

	# --- Encabezado ---
	var header_box = VBoxContainer.new()
	header_box.add_theme_constant_override("separation", 4)
	vbox.add_child(header_box)

	var title_label = Label.new()
	title_label.text = "¡VICTORIA ILUSTRE!" if is_victory else "DERROTA"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_override("font", FONT_TITLE)
	title_label.add_theme_font_size_override("font_size", 38)
	var title_color = Color(1.0, 0.92, 0.65) if is_victory else Color(0.96, 0.35, 0.35)
	title_label.add_theme_color_override("font_color", title_color)
	title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	title_label.add_theme_constant_override("shadow_offset_x", 0)
	title_label.add_theme_constant_override("shadow_offset_y", 3)
	header_box.add_child(title_label)

	var subtitle_label = Label.new()
	if is_victory:
		subtitle_label.text = "El Castillo rival ha sucumbido. La victoria mitológica es tuya."
	else:
		subtitle_label.text = "Tu Castillo ha sido arrasado. Reagrupa a tus guardianes para la próxima batalla."
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_label.add_theme_font_override("font", FONT_REGULAR)
	subtitle_label.add_theme_font_size_override("font_size", 15)
	subtitle_label.add_theme_color_override("font_color", Color(0.82, 0.78, 0.70))
	header_box.add_child(subtitle_label)

	# Separador dorado
	vbox.add_child(_create_divider(style.border_color))

	# --- Crónica de Batalla / Estadísticas ---
	var stats_frame = PanelContainer.new()
	var stats_style = StyleBoxFlat.new()
	stats_style.bg_color = Color(0.05, 0.05, 0.07, 0.85)
	stats_style.border_width_bottom = 1
	stats_style.border_width_left = 1
	stats_style.border_width_right = 1
	stats_style.border_width_top = 1
	stats_style.border_color = Color(0.35, 0.35, 0.42, 0.5)
	stats_style.corner_radius_bottom_left = 10
	stats_style.corner_radius_bottom_right = 10
	stats_style.corner_radius_top_left = 10
	stats_style.corner_radius_top_right = 10
	stats_style.content_margin_left = 18
	stats_style.content_margin_right = 18
	stats_style.content_margin_top = 12
	stats_style.content_margin_bottom = 12
	stats_frame.add_theme_stylebox_override("panel", stats_style)
	vbox.add_child(stats_frame)

	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 8)
	stats_frame.add_child(grid)

	var turns_val: int = stats.get("turns", 1)
	var p_deck: int = stats.get("player_deck", 0)
	var o_deck: int = stats.get("opponent_deck", 0)
	var p_cem: int = stats.get("player_cemetery", 0)
	var o_cem: int = stats.get("opponent_cemetery", 0)
	var p_exile: int = stats.get("player_exile", 0)
	var o_exile: int = stats.get("opponent_exile", 0)

	grid.add_child(_create_stat_item("Duración:", "Turno %d" % turns_val))
	grid.add_child(_create_stat_item("Castillos:", "Tú: %d | Rival: %d" % [p_deck, o_deck]))
	grid.add_child(_create_stat_item("Cementerios:", "Tú: %d | Rival: %d" % [p_cem, o_cem]))
	grid.add_child(_create_stat_item("Destierros:", "Tú: %d | Rival: %d" % [p_exile, o_exile]))

	# Separador
	vbox.add_child(_create_divider(Color(style.border_color.r, style.border_color.g, style.border_color.b, 0.4)))

	# --- Botones de Acción ---
	var btn_hbox = HBoxContainer.new()
	btn_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_hbox.add_theme_constant_override("separation", 14)
	vbox.add_child(btn_hbox)

	_btn_rematch = _create_button("Jugar de Nuevo", true, is_victory)
	_btn_rematch.pressed.connect(_on_rematch_pressed)
	btn_hbox.add_child(_btn_rematch)

	_btn_menu = _create_button("Menú Principal", false, is_victory)
	_btn_menu.pressed.connect(_on_menu_pressed)
	btn_hbox.add_child(_btn_menu)

	_btn_inspect = _create_ghost_button("Ver Tablero")
	_btn_inspect.pressed.connect(_on_inspect_pressed)
	btn_hbox.add_child(_btn_inspect)

	# 3. Animación cinemática de entrada con Tween
	if animate:
		_backdrop.modulate.a = 0.0
		_modal_panel.scale = Vector2(0.84, 0.84)
		_modal_panel.modulate.a = 0.0

		var tw = create_tween()
		if tw:
			tw.set_parallel(true)
			tw.tween_property(_backdrop, "modulate:a", 1.0, 0.35).set_ease(Tween.EASE_OUT)
			tw.tween_property(_modal_panel, "modulate:a", 1.0, 0.30).set_ease(Tween.EASE_OUT)
			tw.tween_property(_modal_panel, "scale", Vector2.ONE, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			await tw.finished
	else:
		_backdrop.modulate.a = 1.0
		_modal_panel.scale = Vector2.ONE
		_modal_panel.modulate.a = 1.0

	if is_instance_valid(_btn_rematch) and _btn_rematch.is_inside_tree():
		_btn_rematch.grab_focus()


func _create_stat_item(title: String, value: String) -> Control:
	var box = HBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl_title = Label.new()
	lbl_title.text = title
	lbl_title.add_theme_font_override("font", FONT_REGULAR)
	lbl_title.add_theme_font_size_override("font_size", 14)
	lbl_title.add_theme_color_override("font_color", Color(0.70, 0.68, 0.64))
	box.add_child(lbl_title)

	var lbl_val = Label.new()
	lbl_val.text = value
	lbl_val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl_val.add_theme_font_override("font", FONT_TITLE)
	lbl_val.add_theme_font_size_override("font_size", 14)
	lbl_val.add_theme_color_override("font_color", Color(0.96, 0.92, 0.82))
	box.add_child(lbl_val)

	return box


func _create_divider(color: Color) -> Control:
	var sep = HBoxContainer.new()
	sep.alignment = BoxContainer.ALIGNMENT_CENTER
	sep.custom_minimum_size = Vector2(0, 8)

	var line1 = ColorRect.new()
	line1.color = Color(color.r, color.g, color.b, 0.4)
	line1.custom_minimum_size = Vector2(240, 1)
	line1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sep.add_child(line1)

	var diamond = Label.new()
	diamond.text = "◆"
	diamond.add_theme_font_size_override("font_size", 10)
	diamond.add_theme_color_override("font_color", color)
	sep.add_child(diamond)

	var line2 = ColorRect.new()
	line2.color = Color(color.r, color.g, color.b, 0.4)
	line2.custom_minimum_size = Vector2(240, 1)
	line2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sep.add_child(line2)

	return sep


func _create_button(text: String, primary: bool, is_victory: bool) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(190, 48)
	btn.focus_mode = Control.FOCUS_ALL
	btn.add_theme_font_override("font", FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 15)

	var normal = StyleBoxFlat.new()
	normal.corner_radius_bottom_left = 8
	normal.corner_radius_bottom_right = 8
	normal.corner_radius_top_left = 8
	normal.corner_radius_top_right = 8
	normal.border_width_bottom = 2
	normal.border_width_left = 2
	normal.border_width_right = 2
	normal.border_width_top = 2

	if primary:
		var accent_col = Color(0.88, 0.74, 0.28, 1.0) if is_victory else Color(0.85, 0.30, 0.30, 1.0)
		normal.bg_color = Color(0.20, 0.15, 0.05, 0.95) if is_victory else Color(0.22, 0.06, 0.06, 0.95)
		normal.border_color = accent_col
		btn.add_theme_color_override("font_color", Color(1.0, 0.92, 0.70) if is_victory else Color(1.0, 0.85, 0.85))
	else:
		normal.bg_color = Color(0.12, 0.12, 0.16, 0.95)
		normal.border_color = Color(0.45, 0.45, 0.52, 0.85)
		btn.add_theme_color_override("font_color", Color(0.85, 0.85, 0.88))

	var hover = normal.duplicate()
	hover.bg_color = normal.bg_color.lightened(0.12)
	hover.border_color = normal.border_color.lightened(0.2)
	hover.shadow_size = 6
	hover.shadow_color = Color(0, 0, 0, 0.7)

	var pressed = normal.duplicate()
	pressed.bg_color = normal.bg_color.darkened(0.1)

	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("focus", hover)

	return btn


func _create_ghost_button(text: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(150, 48)
	btn.focus_mode = Control.FOCUS_ALL
	btn.add_theme_font_override("font", FONT_REGULAR)
	btn.add_theme_font_size_override("font_size", 14)
	btn.add_theme_color_override("font_color", Color(0.75, 0.75, 0.80))

	var normal = StyleBoxFlat.new()
	normal.bg_color = Color(0.08, 0.08, 0.11, 0.70)
	normal.border_width_bottom = 1
	normal.border_width_left = 1
	normal.border_width_right = 1
	normal.border_width_top = 1
	normal.border_color = Color(0.35, 0.35, 0.42, 0.6)
	normal.corner_radius_bottom_left = 8
	normal.corner_radius_bottom_right = 8
	normal.corner_radius_top_left = 8
	normal.corner_radius_top_right = 8

	var hover = normal.duplicate()
	hover.border_color = Color(0.65, 0.65, 0.75, 1.0)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)

	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", normal)
	btn.add_theme_stylebox_override("focus", hover)

	return btn


# =============================================================================
# MANEJADORES DE EVENTOS
# =============================================================================
func _on_rematch_pressed() -> void:
	emit_signal("rematch_requested")
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/game/Main.tscn")


func _on_menu_pressed() -> void:
	emit_signal("menu_requested")
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")


func _on_inspect_pressed() -> void:
	_is_inspecting = true
	_backdrop.visible = false
	_modal_panel.visible = false
	_particles.emitting = false
	_inspect_bar.visible = true


func _on_restore_from_inspect() -> void:
	_is_inspecting = false
	_inspect_bar.visible = false
	_backdrop.visible = true
	_modal_panel.visible = true
	_particles.emitting = true
	if is_instance_valid(_btn_rematch) and _btn_rematch.is_inside_tree():
		_btn_rematch.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return

	if _is_inspecting:
		# Cualquier tecla restaura el panel desde el modo inspección
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE, KEY_SPACE]:
			get_viewport().set_input_as_handled()
			_on_restore_from_inspect()
			return

	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			var focus_owner = get_viewport().gui_get_focus_owner() if get_viewport() else null
			if focus_owner and focus_owner is BaseButton and focus_owner.is_visible_in_tree():
				get_viewport().set_input_as_handled()
				focus_owner.emit_signal("pressed")
			else:
				get_viewport().set_input_as_handled()
				_on_rematch_pressed()
		KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_on_menu_pressed()
