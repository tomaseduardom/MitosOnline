extends CanvasLayer
class_name ActionLogDrawer
## ActionLogDrawer — Cajón lateral desplegable con el historial de jugadas de la partida.
## Conecta con CombatLog, permite filtrar eventos, auto-scroll y hacer clic en nombres
## de cartas para inspeccionarlas en grande vía CardInspectionLayer.

const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_TEXT := preload("res://assets/fonts/Marcellus-Regular.ttf")

const DRAWER_WIDTH: float = 460.0
const TOP_OFFSET: float = 50.0  # Justo debajo del TopBar

var _main: Node = null
var _is_open: bool = false
var _current_filter: String = "all"
var _unread_count: int = 0
var _all_entries: Array[Dictionary] = []

# Nodos de UI
var _toggle_button: Button = null
var _root_control: Control = null
var _backdrop: ColorRect = null
var _drawer_panel: PanelContainer = null
var _header_title: Label = null
var _header_count: Label = null
var _close_button: Button = null
var _filter_buttons: Dictionary = {}
var _rich_text: RichTextLabel = null
var _scroll_bottom_button: Button = null
var _clear_button: Button = null
var _tween: Tween = null


func _init() -> void:
	layer = 30  # Por encima del tablero y HUD, pero por debajo de CardInspectionLayer (layer 100)


func setup(main: Node) -> void:
	_main = main
	_build_ui()
	_setup_toggle_button()
	_connect_combat_log()
	_populate_existing_entries()


func is_open() -> bool:
	return _is_open


# =============================================================================
# CONSTRUCCIÓN DE LA INTERFAZ
# =============================================================================
func _build_ui() -> void:
	_root_control = Control.new()
	_root_control.name = "DrawerRoot"
	_root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root_control)

	# 1. Telón semitransparente (Backdrop)
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.anchor_left = 0.0
	_backdrop.anchor_top = 0.0
	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0
	_backdrop.offset_top = TOP_OFFSET
	_backdrop.offset_left = 0.0
	_backdrop.offset_right = 0.0
	_backdrop.offset_bottom = 0.0
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.45)
	_backdrop.modulate.a = 0.0
	_backdrop.visible = false
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.gui_input.connect(_on_backdrop_input)
	_root_control.add_child(_backdrop)

	# 2. Panel lateral deslizante (anclado al borde derecho de la pantalla)
	_drawer_panel = PanelContainer.new()
	_drawer_panel.name = "DrawerPanel"
	_drawer_panel.anchor_left = 1.0
	_drawer_panel.anchor_top = 0.0
	_drawer_panel.anchor_right = 1.0
	_drawer_panel.anchor_bottom = 1.0
	_drawer_panel.offset_left = 0.0
	_drawer_panel.offset_top = TOP_OFFSET
	_drawer_panel.offset_right = DRAWER_WIDTH
	_drawer_panel.offset_bottom = 0.0

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.06, 0.08, 0.11, 0.97)
	panel_style.border_color = Color(0.78, 0.65, 0.32, 0.85)
	panel_style.border_width_left = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_bottom_left = 10
	panel_style.shadow_color = Color(0, 0, 0, 0.8)
	panel_style.shadow_size = 22
	_drawer_panel.add_theme_stylebox_override("panel", panel_style)
	_root_control.add_child(_drawer_panel)

	# 3. Contenedor con márgenes interiores
	var margin_container = MarginContainer.new()
	margin_container.add_theme_constant_override("margin_top", 14)
	margin_container.add_theme_constant_override("margin_left", 16)
	margin_container.add_theme_constant_override("margin_right", 16)
	margin_container.add_theme_constant_override("margin_bottom", 14)
	_drawer_panel.add_child(margin_container)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin_container.add_child(vbox)

	# 4. Header Bar
	var header_hbox = HBoxContainer.new()
	header_hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	vbox.add_child(header_hbox)

	_header_title = Label.new()
	_header_title.text = "HISTORIAL"
	_header_title.add_theme_font_override("font", FONT_TITLE)
	_header_title.add_theme_font_size_override("font_size", 18)
	_header_title.add_theme_color_override("font_color", Color(0.88, 0.74, 0.28, 1.0))
	header_hbox.add_child(_header_title)

	_header_count = Label.new()
	_header_count.text = " (0)"
	_header_count.add_theme_font_override("font", FONT_TEXT)
	_header_count.add_theme_font_size_override("font_size", 14)
	_header_count.add_theme_color_override("font_color", Color(0.60, 0.65, 0.75, 1.0))
	header_hbox.add_child(_header_count)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(spacer)

	_close_button = Button.new()
	_close_button.text = " ✕ "
	_close_button.flat = true
	_close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_close_button.add_theme_font_override("font", FONT_TITLE)
	_close_button.add_theme_font_size_override("font_size", 18)
	_close_button.add_theme_color_override("font_color", Color(0.70, 0.75, 0.82, 1.0))
	_close_button.add_theme_color_override("font_hover_color", Color(1.0, 0.40, 0.40, 1.0))
	_close_button.pressed.connect(close_drawer)
	header_hbox.add_child(_close_button)

	# Separador sutil
	var sep = HSeparator.new()
	var sep_style = StyleBoxLine.new()
	sep_style.color = Color(0.78, 0.65, 0.32, 0.35)
	sep_style.thickness = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# 5. Barra de Filtros
	var filter_hbox = HBoxContainer.new()
	filter_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(filter_hbox)

	var filters = [
		{"id": "all", "label": "Todos"},
		{"id": "combat", "label": "Combate"},
		{"id": "effects", "label": "Efectos"},
		{"id": "cards", "label": "Jugadas"}
	]

	for f in filters:
		var btn = Button.new()
		btn.text = f.label
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_font_override("font", FONT_TEXT)
		btn.add_theme_font_size_override("font_size", 13)
		btn.pressed.connect(_on_filter_button_pressed.bind(f.id))
		filter_hbox.add_child(btn)
		_filter_buttons[f.id] = btn

	_update_filter_button_styles()

	# 6. Contenedor de Texto del Feed (RichTextLabel)
	var text_panel = PanelContainer.new()
	text_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var inner_style = StyleBoxFlat.new()
	inner_style.bg_color = Color(0.03, 0.04, 0.06, 0.88)
	inner_style.border_color = Color(0.25, 0.28, 0.35, 0.40)
	inner_style.set_border_width_all(1)
	inner_style.set_corner_radius_all(6)
	text_panel.add_theme_stylebox_override("panel", inner_style)
	vbox.add_child(text_panel)

	var text_margin = MarginContainer.new()
	text_margin.add_theme_constant_override("margin_top", 10)
	text_margin.add_theme_constant_override("margin_left", 12)
	text_margin.add_theme_constant_override("margin_right", 12)
	text_margin.add_theme_constant_override("margin_bottom", 10)
	text_panel.add_child(text_margin)

	_rich_text = RichTextLabel.new()
	_rich_text.name = "FeedRichText"
	_rich_text.bbcode_enabled = true
	_rich_text.scroll_active = true
	_rich_text.scroll_following = true
	_rich_text.selection_enabled = true
	_rich_text.context_menu_enabled = false
	_rich_text.add_theme_font_override("normal_font", FONT_TEXT)
	_rich_text.add_theme_font_override("bold_font", FONT_TITLE)
	_rich_text.add_theme_font_size_override("normal_font_size", 14)
	_rich_text.add_theme_font_size_override("bold_font_size", 14)
	_rich_text.add_theme_constant_override("line_separation", 4)
	_rich_text.meta_clicked.connect(_on_meta_clicked)
	_rich_text.meta_hover_started.connect(_on_meta_hover_started)
	_rich_text.meta_hover_ended.connect(_on_meta_hover_ended)
	text_margin.add_child(_rich_text)

	# 7. Footer Bar
	var footer_hbox = HBoxContainer.new()
	vbox.add_child(footer_hbox)

	var hint_label = Label.new()
	hint_label.text = "Clic en carta para inspeccionar"
	hint_label.add_theme_font_override("font", FONT_TEXT)
	hint_label.add_theme_font_size_override("font_size", 12)
	hint_label.add_theme_color_override("font_color", Color(0.50, 0.55, 0.65, 1.0))
	footer_hbox.add_child(hint_label)

	var footer_spacer = Control.new()
	footer_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_hbox.add_child(footer_spacer)

	_scroll_bottom_button = Button.new()
	_scroll_bottom_button.text = "Al final"
	_scroll_bottom_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_scroll_bottom_button.add_theme_font_override("font", FONT_TEXT)
	_scroll_bottom_button.add_theme_font_size_override("font_size", 12)
	_scroll_bottom_button.pressed.connect(_scroll_to_bottom)
	footer_hbox.add_child(_scroll_bottom_button)

	_clear_button = Button.new()
	_clear_button.text = "Limpiar"
	_clear_button.tooltip_text = "Limpiar visualmente el historial"
	_clear_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_clear_button.add_theme_font_override("font", FONT_TEXT)
	_clear_button.add_theme_font_size_override("font_size", 12)
	_clear_button.pressed.connect(_clear_feed)
	footer_hbox.add_child(_clear_button)


# =============================================================================
# BOTÓN DE ACCESO EN TOPBAR
# =============================================================================
func _setup_toggle_button() -> void:
	if not _main:
		return
	var top_bar = _main.get_node_or_null("TopBar")
	if not top_bar:
		return

	_toggle_button = Button.new()
	_toggle_button.name = "ActionLogButton"
	_toggle_button.text = "HISTORIAL [L]"
	_toggle_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_toggle_button.add_theme_font_override("font", FONT_TITLE)
	_toggle_button.add_theme_font_size_override("font_size", 13)

	# Ubicación entre PlayerInfo (X: 20..200) y TurnLabel (X: 810..1110)
	_toggle_button.offset_left = 220.0
	_toggle_button.offset_top = 8.0
	_toggle_button.offset_right = 380.0
	_toggle_button.offset_bottom = 42.0

	var normal_style = StyleBoxFlat.new()
	normal_style.bg_color = Color(0.08, 0.10, 0.14, 0.95)
	normal_style.border_color = Color(0.78, 0.65, 0.32, 0.80)
	normal_style.set_border_width_all(1)
	normal_style.set_corner_radius_all(6)
	normal_style.shadow_color = Color(0, 0, 0, 0.6)
	normal_style.shadow_size = 4
	_toggle_button.add_theme_stylebox_override("normal", normal_style)

	var hover_style = StyleBoxFlat.new()
	hover_style.bg_color = Color(0.12, 0.16, 0.22, 1.0)
	hover_style.border_color = Color(1.0, 0.88, 0.45, 1.0)
	hover_style.set_border_width_all(1)
	hover_style.set_corner_radius_all(6)
	hover_style.shadow_color = Color(0.88, 0.74, 0.28, 0.4)
	hover_style.shadow_size = 8
	_toggle_button.add_theme_stylebox_override("hover", hover_style)

	var pressed_style = StyleBoxFlat.new()
	pressed_style.bg_color = Color(0.05, 0.07, 0.09, 1.0)
	pressed_style.border_color = Color(0.60, 0.50, 0.25, 1.0)
	pressed_style.set_border_width_all(1)
	pressed_style.set_corner_radius_all(6)
	_toggle_button.add_theme_stylebox_override("pressed", pressed_style)

	_toggle_button.pressed.connect(toggle_drawer)
	top_bar.add_child(_toggle_button)


func _get_combat_log() -> Node:
	if is_inside_tree() and get_tree().root.has_node("CombatLog"):
		return get_tree().root.get_node("CombatLog")
	return null


# =============================================================================
# INTEGRACIÓN CON COMBATLOG
# =============================================================================
func _connect_combat_log() -> void:
	var combat_log = _get_combat_log()
	if combat_log:
		if not combat_log.log_entry_added.is_connected(_on_log_entry_added):
			combat_log.log_entry_added.connect(_on_log_entry_added)
		if not combat_log.log_cleared.is_connected(_on_log_cleared):
			combat_log.log_cleared.connect(_on_log_cleared)


func _populate_existing_entries() -> void:
	var combat_log = _get_combat_log()
	if not combat_log:
		return
	var existing = combat_log.get_entries()
	for entry in existing:
		_all_entries.append(entry)
	_refresh_feed()


func _on_log_entry_added(entry: Dictionary) -> void:
	_all_entries.append(entry)

	# Actualizar contador
	_header_count.text = " (%d)" % _all_entries.size()

	# Si está cerrado, incrementar contador no leído
	if not _is_open and not _is_decorative_header(entry):
		_unread_count += 1
		_update_toggle_button_text()

	# Si coincide con el filtro actual, añadir línea directamente
	if _matches_filter(entry, _current_filter):
		var formatted = _format_entry_bbcode(entry)
		if not formatted.is_empty():
			_rich_text.append_text(formatted + "\n")


func _on_log_cleared() -> void:
	_all_entries.clear()
	_unread_count = 0
	_header_count.text = " (0)"
	_update_toggle_button_text()
	_rich_text.clear()


func _update_toggle_button_text() -> void:
	if not _toggle_button:
		return
	if _unread_count > 0:
		_toggle_button.text = "HISTORIAL [L] (%d)" % _unread_count
		_toggle_button.add_theme_color_override("font_color", Color(1.0, 0.90, 0.40, 1.0))
	else:
		_toggle_button.text = "HISTORIAL [L]"
		_toggle_button.remove_theme_color_override("font_color")


# =============================================================================
# APERTURA Y CIERRE (ANIMACIÓN)
# =============================================================================
func toggle_drawer() -> void:
	if _is_open:
		close_drawer()
	else:
		open_drawer()


func open_drawer() -> void:
	if _is_open:
		return
	_is_open = true
	_unread_count = 0
	_update_toggle_button_text()

	_backdrop.visible = true
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP

	if _tween and _tween.is_valid():
		_tween.kill()

	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_backdrop, "modulate:a", 1.0, 0.20)
	_tween.tween_property(_drawer_panel, "offset_left", -DRAWER_WIDTH, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_drawer_panel, "offset_right", 0.0, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

	call_deferred("_scroll_to_bottom")


func close_drawer() -> void:
	if not _is_open:
		return
	_is_open = false
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if _tween and _tween.is_valid():
		_tween.kill()

	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_backdrop, "modulate:a", 0.0, 0.18)
	_tween.tween_property(_drawer_panel, "offset_left", 0.0, 0.18).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_drawer_panel, "offset_right", DRAWER_WIDTH, 0.18).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_tween.chain().tween_callback(func():
		if not _is_open:
			_backdrop.visible = false
	)



func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close_drawer()


# =============================================================================
# FILTRADO Y FORMATEO
# =============================================================================
func _on_filter_button_pressed(filter_id: String) -> void:
	_current_filter = filter_id
	_update_filter_button_styles()
	_refresh_feed()


func _update_filter_button_styles() -> void:
	for id in _filter_buttons:
		var btn: Button = _filter_buttons[id]
		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(4)
		style.set_border_width_all(1)
		if id == _current_filter:
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


func _matches_filter(entry: Dictionary, filter_id: String) -> bool:
	var t = entry.get("type", "").to_lower()

	# Los encabezados de turno y fase siempre se muestran para mantener el contexto
	if t in ["turn_header", "phase_header"]:
		return true

	match filter_id:
		"all":
			return true
		"combat":
			return t in ["attack", "atacar", "block", "bloquear", "damage", "daño", "destroy", "destruir"]
		"effects":
			return t in [
				"trigger", "buff", "fortalecer", "debuff", "debilitar", "search", "buscar",
				"heal", "curar", "counter", "annul", "anular", "banish", "desterrar",
				"mill", "botar", "draw", "robar"
			]
		"cards":
			return t in ["play", "jugar", "gold", "oro", "discard", "descartar"]
		_:
			return true


func _is_decorative_header(entry: Dictionary) -> bool:
	var t = entry.get("type", "")
	var m = entry.get("message", "")
	if t == "turn_header" and ("╔" in m or "╚" in m or m.is_empty()):
		return true
	if t == "phase_header" and ("━" in m or m.is_empty()):
		return true
	return false


func _format_entry_bbcode(entry: Dictionary) -> String:
	var t = entry.get("type", "")
	var m = entry.get("message", "")
	var time_str = entry.get("time_string", "")

	# 1. Encabezado de Turno
	if t == "turn_header":
		if "TURNO" in m:
			var clean = m.replace("║", "").replace("╔", "").replace("╗", "").replace("╚", "").replace("╝", "").replace("═", "").strip_edges()
			return "\n[center][color=#E0BC47]═══════ [b]%s[/b] ═══════[/color][/center]" % clean
		return ""  # Omitir líneas decorativas de borde

	# 2. Encabezado de Fase
	if t == "phase_header":
		if "FASE DE" in m:
			var clean = m.replace("━", "").strip_edges()
			return "[center][color=#90A4CE]── [b]%s[/b] ──[/color][/center]" % clean
		return ""  # Omitir líneas decorativas de borde

	# 3. Entrada estándar
	if m.is_empty():
		return ""

	if not time_str.is_empty():
		return "[color=#566275][%s][/color] %s" % [time_str, m]
	return m


func _refresh_feed() -> void:
	if not _rich_text:
		return
	_rich_text.clear()
	_header_count.text = " (%d)" % _all_entries.size()

	var lines: Array[String] = []
	for entry in _all_entries:
		if _matches_filter(entry, _current_filter):
			var formatted = _format_entry_bbcode(entry)
			if not formatted.is_empty():
				lines.append(formatted)

	_rich_text.text = "\n".join(lines)
	call_deferred("_scroll_to_bottom")


func _scroll_to_bottom() -> void:
	if not _rich_text:
		return
	_rich_text.scroll_following = true
	var vbar = _rich_text.get_v_scroll_bar()
	if vbar:
		vbar.value = vbar.max_value


func _clear_feed() -> void:
	_all_entries.clear()
	_header_count.text = " (0)"
	_rich_text.clear()


# =============================================================================
# INTERACCIÓN CON HIPERVÍNCULOS DE CARTAS (META CLICKED)
# =============================================================================
func _on_meta_clicked(meta: Variant) -> void:
	var meta_str = str(meta)
	if meta_str.begins_with("card:"):
		var card_name = meta_str.substr(5).strip_edges()
		_inspect_card_from_log(card_name)


func _inspect_card_from_log(card_name: String) -> void:
	if not _main:
		return
	if "_card_inspector" in _main and _main._card_inspector:
		_main._card_inspector.inspect_card_by_name(card_name)


func _on_meta_hover_started(_meta: Variant) -> void:
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)


func _on_meta_hover_ended(_meta: Variant) -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
