extends Control
## CombatLogUI - Interfaz visual para el CombatLog
## Muestra el historial de acciones con formato BBCode

# =============================================================================
# EXPORTABLES
# =============================================================================
@export var max_visible_lines: int = 4
@export var auto_scroll: bool = true
@export var show_timestamps: bool = false
@export var font_size: int = 11
@export var background_color: Color = Color(0.05, 0.05, 0.1, 0.75)
@export var border_color: Color = Color(0.3, 0.3, 0.4, 0.5)

# =============================================================================
# REFERENCIAS UI
# =============================================================================
var _rich_text: RichTextLabel
var _scroll_container: ScrollContainer
var _title_label: Label
var _filter_buttons: HBoxContainer
var _clear_button: Button
var _minimize_button: Button

var _is_minimized: bool = false
var _current_filter: String = ""


func _ready() -> void:
	_create_ui()
	_connect_combat_log()


func _create_ui() -> void:
	"""Crea la interfaz del log"""
	# Panel principal
	var panel = Panel.new()
	panel.name = "LogPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var style = StyleBoxFlat.new()
	style.bg_color = background_color
	style.border_color = border_color
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	# Layout: solo el texto, sin header ni filtros
	_scroll_container = ScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll_container)

	_rich_text = RichTextLabel.new()
	_rich_text.bbcode_enabled = true
	_rich_text.scroll_following = auto_scroll
	_rich_text.fit_content = false
	_rich_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rich_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rich_text.add_theme_font_size_override("normal_font_size", font_size)
	_rich_text.add_theme_font_size_override("bold_font_size", font_size)
	_scroll_container.add_child(_rich_text)


func _create_header() -> HBoxContainer:
	"""Crea el header con título y botones"""
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)

	# Título
	_title_label = Label.new()
	_title_label.text = "COMBAT LOG"
	_title_label.add_theme_font_size_override("font_size", 16)
	_title_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.5))
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)

	# Botón limpiar
	_clear_button = Button.new()
	_clear_button.text = "Limpiar"
	_clear_button.custom_minimum_size = Vector2(70, 28)
	_clear_button.pressed.connect(_on_clear_pressed)
	header.add_child(_clear_button)

	# Botón minimizar
	_minimize_button = Button.new()
	_minimize_button.text = "−"
	_minimize_button.custom_minimum_size = Vector2(28, 28)
	_minimize_button.pressed.connect(_on_minimize_pressed)
	header.add_child(_minimize_button)

	return header


func _create_filters() -> HBoxContainer:
	"""Crea los botones de filtro"""
	var filters = HBoxContainer.new()
	filters.add_theme_constant_override("separation", 5)

	var filter_types = [
		{"id": "", "text": "Todo", "color": Color.WHITE},
		{"id": "draw", "text": "Robar", "color": Color(0.3, 0.7, 0.3)},
		{"id": "destroy", "text": "Destruir", "color": Color(0.8, 0.2, 0.2)},
		{"id": "banish", "text": "Desterrar", "color": Color(0.6, 0.2, 0.7)},
		{"id": "damage", "text": "Daño", "color": Color(0.9, 0.4, 0.5)},
		{"id": "phase", "text": "Fases", "color": Color(0.8, 0.6, 0.9)},
	]

	for filter in filter_types:
		var btn = Button.new()
		btn.text = filter.text
		btn.custom_minimum_size = Vector2(60, 24)
		btn.add_theme_font_size_override("font_size", 11)
		btn.set_meta("filter_id", filter.id)
		btn.pressed.connect(_on_filter_pressed.bind(btn))

		if filter.id == _current_filter:
			btn.modulate = Color(1.2, 1.2, 0.8)

		filters.add_child(btn)

	return filters


func _connect_combat_log() -> void:
	"""Conecta al singleton CombatLog"""
	await get_tree().process_frame

	CombatLog.log_entry_added.connect(_on_log_entry_added)
	CombatLog.log_cleared.connect(_on_log_cleared)

	# Cargar entradas existentes
	_load_existing_entries(CombatLog)


func _load_existing_entries(combat_log: Node) -> void:
	"""Carga entradas existentes del log"""
	var entries = combat_log.get_entries(max_visible_lines)
	for entry in entries:
		_append_entry(entry)


func _on_log_entry_added(entry: Dictionary) -> void:
	"""Callback cuando se agrega una entrada"""
	if _current_filter.is_empty() or entry.type == _current_filter:
		_append_entry(entry)


func _on_log_cleared() -> void:
	"""Callback cuando se limpia el log"""
	if _rich_text:
		_rich_text.clear()


func _append_entry(entry: Dictionary) -> void:
	"""Agrega una entrada al RichTextLabel. Mantiene solo max_visible_lines recientes."""
	if not _rich_text:
		return

	var line = ""

	if show_timestamps:
		line += "[color=#666666][%s][/color] " % entry.time_string

	line += entry.message

	_rich_text.append_text(line + "\n")

	# Mantener solo las últimas max_visible_lines entradas para el panel compacto
	var line_count = _rich_text.get_paragraph_count()
	if line_count > max_visible_lines + 1:
		_refresh_log()


func _on_clear_pressed() -> void:
	"""Limpia el log"""
	CombatLog.clear()

	if _rich_text:
		_rich_text.clear()


func _on_minimize_pressed() -> void:
	"""Minimiza/maximiza el log"""
	_is_minimized = not _is_minimized

	if _scroll_container:
		_scroll_container.visible = not _is_minimized

	if _filter_buttons:
		_filter_buttons.visible = not _is_minimized

	_minimize_button.text = "+" if _is_minimized else "−"

	# Ajustar tamaño
	if _is_minimized:
		custom_minimum_size.y = 40
	else:
		custom_minimum_size.y = 200


func _on_filter_pressed(btn: Button) -> void:
	"""Aplica filtro"""
	_current_filter = btn.get_meta("filter_id", "")

	# Actualizar visual de botones
	for child in _filter_buttons.get_children():
		if child is Button:
			var is_selected = child.get_meta("filter_id", "") == _current_filter
			child.modulate = Color(1.2, 1.2, 0.8) if is_selected else Color.WHITE

	# Recargar log con filtro
	_refresh_log()


func _refresh_log() -> void:
	"""Recarga el log con el filtro actual"""
	if not _rich_text:
		return

	_rich_text.clear()

	var entries = CombatLog.get_entries(max_visible_lines, _current_filter)
	for entry in entries:
		_append_entry(entry)


# =============================================================================
# API PÚBLICA
# =============================================================================
func set_font_size(size: int) -> void:
	font_size = size
	if _rich_text:
		_rich_text.add_theme_font_size_override("normal_font_size", size)
		_rich_text.add_theme_font_size_override("bold_font_size", size)


func set_auto_scroll(enabled: bool) -> void:
	auto_scroll = enabled
	if _rich_text:
		_rich_text.scroll_following = enabled


func toggle_timestamps(show: bool) -> void:
	show_timestamps = show
	_refresh_log()
