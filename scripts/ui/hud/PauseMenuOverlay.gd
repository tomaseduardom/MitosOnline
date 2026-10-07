extends CanvasLayer
class_name PauseMenuOverlay
## PauseMenuOverlay — Menú cinemático de pausa y configuración en juego.
## Permite ajustar volúmenes (Master, Música, SFX), velocidad de animaciones (1.0x, 1.5x, 2.0x),
## conceder la partida con confirmación y regresar al menú principal.

const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_TEXT := preload("res://assets/fonts/Marcellus-Regular.ttf")

signal resume_requested
signal conceded
signal main_menu_requested

var _main: Node = null
var _is_open: bool = false

# Nodos principales
var _backdrop: ColorRect = null
var _modal_panel: PanelContainer = null
var _master_slider: HSlider = null
var _master_val_label: Label = null
var _music_slider: HSlider = null
var _music_val_label: Label = null
var _sfx_slider: HSlider = null
var _sfx_val_label: Label = null
var _speed_buttons: Dictionary = {}

var _btn_resume: Button = null
var _btn_concede: Button = null
var _btn_menu: Button = null
var _btn_quit: Button = null

# Diálogo de confirmación
var _confirm_overlay: Control = null
var _confirm_title: Label = null
var _confirm_msg: Label = null
var _confirm_btn_yes: Button = null
var _confirm_btn_no: Button = null
var _pending_action: Callable = Callable()


func _init() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(main: Node) -> void:
	_main = main
	_build_ui()
	_sync_settings_to_ui()
	visible = false


func is_open() -> bool:
	return _is_open


func toggle_menu() -> void:
	if _is_open:
		close_menu()
	else:
		open_menu()


func open_menu() -> void:
	if _is_open:
		return
	_is_open = true
	visible = true
	get_tree().paused = true
	Engine.time_scale = 1.0  # Menú de pausa opera a velocidad natural

	_sync_settings_to_ui()
	_hide_confirm()

	# Animación de entrada
	_backdrop.modulate.a = 0.0
	_modal_panel.scale = Vector2(0.9, 0.9)
	_modal_panel.modulate.a = 0.0

	var tween = create_tween().set_parallel(true)
	tween.tween_property(_backdrop, "modulate:a", 1.0, 0.18).set_ease(Tween.EASE_OUT)
	tween.tween_property(_modal_panel, "modulate:a", 1.0, 0.20)
	tween.tween_property(_modal_panel, "scale", Vector2.ONE, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	call_deferred("_focus_resume_button")


func close_menu() -> void:
	if not _is_open:
		return
	_is_open = false

	var tween = create_tween().set_parallel(true)
	tween.tween_property(_backdrop, "modulate:a", 0.0, 0.16).set_ease(Tween.EASE_IN)
	tween.tween_property(_modal_panel, "modulate:a", 0.0, 0.16)
	tween.tween_property(_modal_panel, "scale", Vector2(0.92, 0.92), 0.16).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(func():
		visible = false
		get_tree().paused = false
		Engine.time_scale = GameSettings.animation_speed
		resume_requested.emit()
	)


func _focus_resume_button() -> void:
	if _btn_resume and is_instance_valid(_btn_resume):
		_btn_resume.grab_focus()


# =============================================================================
# CONSTRUCCIÓN DE LA INTERFAZ
# =============================================================================
func _build_ui() -> void:
	# 1. Telón semitransparente con viñeta
	_backdrop = ColorRect.new()
	_backdrop.name = "PauseBackdrop"
	_backdrop.color = Color(0.02, 0.03, 0.05, 0.88)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)

	# 2. Panel central
	_modal_panel = PanelContainer.new()
	_modal_panel.name = "PauseModalPanel"
	_modal_panel.custom_minimum_size = Vector2(490, 580)
	_modal_panel.anchors_preset = Control.PRESET_CENTER
	_modal_panel.anchor_left = 0.5
	_modal_panel.anchor_top = 0.5
	_modal_panel.anchor_right = 0.5
	_modal_panel.anchor_bottom = 0.5
	_modal_panel.offset_left = -245
	_modal_panel.offset_top = -290
	_modal_panel.offset_right = 245
	_modal_panel.offset_bottom = 290
	_modal_panel.pivot_offset = Vector2(245, 290)

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.07, 0.09, 0.13, 0.98)
	panel_style.border_color = Color(0.78, 0.65, 0.32, 0.90)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(12)
	panel_style.shadow_color = Color(0, 0, 0, 0.85)
	panel_style.shadow_size = 28
	_modal_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_modal_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 18)
	_modal_panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# Encabezado
	var title = Label.new()
	title.text = "PAUSA Y AJUSTES"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", FONT_TITLE)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.88, 0.74, 0.28, 1.0))
	vbox.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "El combate aguarda por tu orden"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_override("font", FONT_TEXT)
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color(0.60, 0.65, 0.75, 1.0))
	vbox.add_child(subtitle)

	vbox.add_child(_create_separator())

	# Sección de Audio
	var audio_header = Label.new()
	audio_header.text = "SONIDO Y MÚSICA"
	audio_header.add_theme_font_override("font", FONT_TITLE)
	audio_header.add_theme_font_size_override("font_size", 13)
	audio_header.add_theme_color_override("font_color", Color(0.78, 0.65, 0.32, 1.0))
	vbox.add_child(audio_header)

	var audio_rows = _create_audio_rows()
	_master_slider = audio_rows.master_slider
	_master_val_label = audio_rows.master_label
	_music_slider = audio_rows.music_slider
	_music_val_label = audio_rows.music_label
	_sfx_slider = audio_rows.sfx_slider
	_sfx_val_label = audio_rows.sfx_label
	vbox.add_child(audio_rows.container)

	vbox.add_child(_create_separator())

	# Sección de Velocidad de Juego
	var speed_header = Label.new()
	speed_header.text = "VELOCIDAD DE ANIMACIONES"
	speed_header.add_theme_font_override("font", FONT_TITLE)
	speed_header.add_theme_font_size_override("font_size", 13)
	speed_header.add_theme_color_override("font_color", Color(0.78, 0.65, 0.32, 1.0))
	vbox.add_child(speed_header)

	var speed_hbox = HBoxContainer.new()
	speed_hbox.add_theme_constant_override("separation", 8)
	speed_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(speed_hbox)

	var speeds = [
		{"speed": 1.0, "label": "1.0× Normal"},
		{"speed": 1.5, "label": "1.5× Rápida"},
		{"speed": 2.0, "label": "2.0× Turbo"}
	]

	for s in speeds:
		var btn = Button.new()
		btn.text = s.label
		btn.custom_minimum_size = Vector2(130, 32)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_font_override("font", FONT_TEXT)
		btn.add_theme_font_size_override("font_size", 13)
		btn.pressed.connect(_on_speed_selected.bind(s.speed))
		speed_hbox.add_child(btn)
		_speed_buttons[s.speed] = btn

	vbox.add_child(_create_separator())

	# Botones de Acción
	var btn_vbox = VBoxContainer.new()
	btn_vbox.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_vbox)

	_btn_resume = _create_action_button("REANUDAR PARTIDA", _on_resume_pressed, Color(1.0, 0.92, 0.65, 1.0), true)
	btn_vbox.add_child(_btn_resume)

	_btn_concede = _create_action_button("CONCEDER PARTIDA", _on_concede_pressed, Color(1.0, 0.70, 0.50, 1.0))
	btn_vbox.add_child(_btn_concede)

	_btn_menu = _create_action_button("VOLVER AL MENÚ", _on_menu_pressed, Color(0.85, 0.88, 0.95, 1.0))
	btn_vbox.add_child(_btn_menu)

	_btn_quit = _create_action_button("SALIR DEL JUEGO", _on_quit_pressed, Color(0.75, 0.75, 0.80, 0.85))
	btn_vbox.add_child(_btn_quit)

	# 3. Sub-modal de Confirmación
	_create_confirm_overlay()


func _create_separator() -> HSeparator:
	var sep = HSeparator.new()
	var sep_style = StyleBoxLine.new()
	sep_style.color = Color(0.78, 0.65, 0.32, 0.35)
	sep_style.thickness = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	return sep


func _create_audio_rows() -> Dictionary:
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)

	var master_row = _create_slider_row("Master:", 1.0, _on_master_slider_changed)
	vbox.add_child(master_row.row)

	var music_row = _create_slider_row("Música:", 0.8, _on_music_slider_changed)
	vbox.add_child(music_row.row)

	var sfx_row = _create_slider_row("Efectos SFX:", 1.0, _on_sfx_slider_changed)
	vbox.add_child(sfx_row.row)

	return {
		"container": vbox,
		"master_slider": master_row.slider,
		"master_label": master_row.label,
		"music_slider": music_row.slider,
		"music_label": music_row.label,
		"sfx_slider": sfx_row.slider,
		"sfx_label": sfx_row.label
	}


func _create_slider_row(label_text: String, default_val: float, callback: Callable) -> Dictionary:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(95, 0)
	lbl.add_theme_font_override("font", FONT_TEXT)
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95, 1.0))
	hbox.add_child(lbl)

	var slider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = default_val * 100.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	slider.value_changed.connect(callback)
	hbox.add_child(slider)

	var val_lbl = Label.new()
	val_lbl.text = "%d%%" % int(slider.value)
	val_lbl.custom_minimum_size = Vector2(45, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_font_override("font", FONT_TEXT)
	val_lbl.add_theme_font_size_override("font_size", 13)
	val_lbl.add_theme_color_override("font_color", Color(0.70, 0.75, 0.85, 1.0))
	hbox.add_child(val_lbl)

	return {"row": hbox, "slider": slider, "label": val_lbl}


func _create_action_button(text: String, callback: Callable, font_color: Color, is_primary: bool = false) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 38 if not is_primary else 42)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_override("font", FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 14 if not is_primary else 15)
	btn.add_theme_color_override("font_color", font_color)

	var normal = StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.15, 0.20, 0.95) if not is_primary else Color(0.18, 0.15, 0.10, 0.95)
	normal.border_color = Color(0.50, 0.45, 0.35, 0.80) if not is_primary else Color(0.88, 0.74, 0.28, 0.90)
	normal.set_border_width_all(1 if not is_primary else 2)
	normal.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal", normal)

	var hover = StyleBoxFlat.new()
	hover.bg_color = Color(0.18, 0.22, 0.30, 1.0) if not is_primary else Color(0.26, 0.22, 0.12, 1.0)
	hover.border_color = Color(1.0, 0.88, 0.50, 1.0)
	hover.set_border_width_all(2)
	hover.set_corner_radius_all(6)
	hover.shadow_color = Color(0.88, 0.74, 0.28, 0.40)
	hover.shadow_size = 6
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)

	btn.pressed.connect(callback)
	return btn


# =============================================================================
# SUB-MODAL DE CONFIRMACIÓN
# =============================================================================
func _create_confirm_overlay() -> void:
	_confirm_overlay = ColorRect.new()
	_confirm_overlay.name = "ConfirmOverlay"
	_confirm_overlay.color = Color(0.0, 0.0, 0.0, 0.75)
	_confirm_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirm_overlay.visible = false
	_confirm_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_panel.add_child(_confirm_overlay)

	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 200)
	panel.anchors_preset = Control.PRESET_CENTER
	panel.anchor_left = 0.5; panel.anchor_top = 0.5
	panel.anchor_right = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -190; panel.offset_top = -100
	panel.offset_right = 190; panel.offset_bottom = 100

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.12, 0.16, 0.98)
	style.border_color = Color(0.88, 0.74, 0.28, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(0, 0, 0, 0.9)
	style.shadow_size = 20
	panel.add_theme_stylebox_override("panel", style)
	_confirm_overlay.add_child(panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	_confirm_title = Label.new()
	_confirm_title.text = "¿Estás seguro?"
	_confirm_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_title.add_theme_font_override("font", FONT_TITLE)
	_confirm_title.add_theme_font_size_override("font_size", 18)
	_confirm_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.40, 1.0))
	vbox.add_child(_confirm_title)

	_confirm_msg = Label.new()
	_confirm_msg.text = "¿Deseas realizar esta acción?"
	_confirm_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_msg.add_theme_font_override("font", FONT_TEXT)
	_confirm_msg.add_theme_font_size_override("font_size", 14)
	_confirm_msg.add_theme_color_override("font_color", Color(0.80, 0.85, 0.92, 1.0))
	vbox.add_child(_confirm_msg)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	_confirm_btn_no = Button.new()
	_confirm_btn_no.text = "Cancelar"
	_confirm_btn_no.custom_minimum_size = Vector2(130, 36)
	_confirm_btn_no.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_confirm_btn_no.add_theme_font_override("font", FONT_TITLE)
	_confirm_btn_no.add_theme_font_size_override("font_size", 14)
	_confirm_btn_no.pressed.connect(_hide_confirm)
	hbox.add_child(_confirm_btn_no)

	_confirm_btn_yes = Button.new()
	_confirm_btn_yes.text = "Confirmar"
	_confirm_btn_yes.custom_minimum_size = Vector2(130, 36)
	_confirm_btn_yes.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_confirm_btn_yes.add_theme_font_override("font", FONT_TITLE)
	_confirm_btn_yes.add_theme_font_size_override("font_size", 14)
	_confirm_btn_yes.add_theme_color_override("font_color", Color(1.0, 0.60, 0.60, 1.0))
	_confirm_btn_yes.pressed.connect(_on_confirm_yes)
	hbox.add_child(_confirm_btn_yes)


func _show_confirm(title_text: String, msg_text: String, action: Callable) -> void:
	_confirm_title.text = title_text
	_confirm_msg.text = msg_text
	_pending_action = action
	_confirm_overlay.visible = true
	_confirm_btn_no.grab_focus()


func _hide_confirm() -> void:
	_confirm_overlay.visible = false
	_pending_action = Callable()


func _on_confirm_yes() -> void:
	var act = _pending_action
	_hide_confirm()
	if act.is_valid():
		act.call()


# =============================================================================
# MANEJADORES DE ENTRADA Y EVENTOS
# =============================================================================
func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _confirm_overlay.visible:
			close_menu()


func handle_escape() -> void:
	"""Procesa la tecla Escape de forma segura cerrando confirmación o el menú de pausa."""
	if _confirm_overlay and _confirm_overlay.visible:
		_hide_confirm()
	else:
		close_menu()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			handle_escape()
			get_viewport().set_input_as_handled()


func _on_master_slider_changed(val: float) -> void:
	_master_val_label.text = "%d%%" % int(val)
	GameSettings.set_master_volume(val / 100.0)


func _on_music_slider_changed(val: float) -> void:
	_music_val_label.text = "%d%%" % int(val)
	GameSettings.set_music_volume(val / 100.0)


func _on_sfx_slider_changed(val: float) -> void:
	_sfx_val_label.text = "%d%%" % int(val)
	GameSettings.set_sfx_volume(val / 100.0)


func _on_speed_selected(speed: float) -> void:
	GameSettings.set_animation_speed(speed)
	_update_speed_button_styles()


func _on_resume_pressed() -> void:
	close_menu()


func _on_concede_pressed() -> void:
	_show_confirm(
		"¿Conceder Partida?",
		"Tu Castillo será derrotado y el combate concluirá en victoria para el oponente.",
		_execute_concede
	)


func _execute_concede() -> void:
	close_menu()
	conceded.emit()
	if GameManager:
		GameManager.player_loses(0, "Concesión de la partida")


func _on_menu_pressed() -> void:
	_show_confirm(
		"¿Volver al Menú?",
		"Se abandonará el combate actual y regresarás a la pantalla principal.",
		_execute_main_menu
	)


func _execute_main_menu() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	main_menu_requested.emit()
	get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")


func _on_quit_pressed() -> void:
	_show_confirm(
		"¿Salir al Escritorio?",
		"El juego se cerrará inmediatamente.",
		func(): get_tree().quit()
	)


# =============================================================================
# SINCRONIZACIÓN DE AJUSTES CON LA UI
# =============================================================================
func _sync_settings_to_ui() -> void:
	if _master_slider:
		_master_slider.value = GameSettings.master_volume * 100.0
		_master_val_label.text = "%d%%" % int(_master_slider.value)
	if _music_slider:
		_music_slider.value = GameSettings.music_volume * 100.0
		_music_val_label.text = "%d%%" % int(_music_slider.value)
	if _sfx_slider:
		_sfx_slider.value = GameSettings.sfx_volume * 100.0
		_sfx_val_label.text = "%d%%" % int(_sfx_slider.value)
	_update_speed_button_styles()


func _update_speed_button_styles() -> void:
	var current_spd = GameSettings.animation_speed
	for spd in _speed_buttons:
		var btn: Button = _speed_buttons[spd]
		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(6)
		style.set_border_width_all(1)
		if is_equal_approx(spd, current_spd):
			style.bg_color = Color(0.24, 0.20, 0.10, 0.95)
			style.border_color = Color(1.0, 0.85, 0.35, 1.0)
			btn.add_theme_color_override("font_color", Color(1.0, 0.92, 0.50, 1.0))
		else:
			style.bg_color = Color(0.08, 0.10, 0.13, 0.80)
			style.border_color = Color(0.30, 0.34, 0.42, 0.60)
			btn.add_theme_color_override("font_color", Color(0.70, 0.75, 0.82, 1.0))
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)

