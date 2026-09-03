extends CanvasLayer
## SelectionManager - Singleton para gestionar selección de cartas desde zonas
## Permite mostrar cartas del cementerio, mazo o reveladas para selección

# =============================================================================
# SEÑALES
# =============================================================================
signal card_selected(card_data: Dictionary)  # Emitida al seleccionar una carta (cierra automáticamente)
signal selection_completed(selected_cards: Array)  # Para modo multi-selección
signal selection_cancelled()

# =============================================================================
# CONSTANTES
# =============================================================================
enum SelectionMode {
	REVEAL,    # Solo mostrar cartas (sin selección)
	EXHUMAR,   # Seleccionar del cementerio para exhumar
	SEARCH,    # Buscar en el mazo
	DISCARD,   # Seleccionar para descartar
	TARGET,    # Seleccionar objetivo
	CUSTOM     # Modo personalizado con filtro
}

## Mapeo de strings a enum para API simplificada
const MODE_MAP: Dictionary = {
	"REVEAL": SelectionMode.REVEAL,
	"EXHUMAR": SelectionMode.EXHUMAR,
	"SEARCH": SelectionMode.SEARCH,
	"DISCARD": SelectionMode.DISCARD,
	"TARGET": SelectionMode.TARGET,
	"CUSTOM": SelectionMode.CUSTOM
}

const CardScene = preload("res://scenes/cards/Card.tscn")
const TEX_ALTAR_BG := preload("res://assets/backgrounds/pila_bautismal_altar.jpg")
const SHADER_VIGNETTE := preload("res://assets/shaders/zone_modal_vignette.gdshader")
const FONT_CINZEL_BOLD := preload("res://assets/fonts/Cinzel-Bold.ttf")

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
## Máximo de cartas seleccionables (0 = sin límite)
var max_selections: int = 1

## Mínimo de cartas que deben seleccionarse (0 = opcional)
var min_selections: int = 0

## Modo actual de selección
var current_mode: int = SelectionMode.REVEAL

## Filtro personalizado para determinar qué cartas son seleccionables
## Callable que recibe (card_data: Dictionary) -> bool
var selection_filter: Callable = Callable()

## Título mostrado en el overlay
var selection_title: String = "Seleccionar carta"

# =============================================================================
# ESTADO
# =============================================================================
var is_open: bool = false
var displayed_cards: Array[Node] = []
var selected_cards: Array[Node] = []
var _card_data_map: Dictionary = {}  # card_instance -> original_data

# =============================================================================
# REFERENCIAS UI (creadas dinámicamente)
# =============================================================================
var _overlay: ColorRect
var _panel: Panel
var _title_label: Label
var _cards_container: HBoxContainer
var _scroll_container: ScrollContainer
var _buttons_container: HBoxContainer
var _confirm_button: Button
var _cancel_button: Button
var _info_label: Label
var _drag_hint_label: Label  # Hint para arrastrar en modo EXHUMAR
var _exhume_drop_indicator: Panel  # Indicador visual de zona de drop

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	layer = 90  # Por encima del juego, debajo de pausa
	visible = false
	_build_ui()
	print("[SelectionManager] Inicializado")


func _build_ui() -> void:
	"""Construye la UI de selección dinámicamente con estética de Altar Catedralicio"""
	# Overlay oscuro
	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color(0, 0, 0, 0.70)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	# Panel central proporcionado
	_panel = Panel.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -525
	_panel.offset_top = -220
	_panel.offset_right = 525
	_panel.offset_bottom = 220
	_panel.clip_contents = false

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.02, 0.02, 0.04, 0.96)
	panel_style.set_corner_radius_all(22)
	panel_style.shadow_color = Color(0, 0, 0, 0.85)
	panel_style.shadow_size = 35
	_panel.add_theme_stylebox_override("panel", panel_style)
	_overlay.add_child(_panel)

	# Fondo con Pila Bautismal / Altar de Mármol y shader de viñeta suave
	var bg_rect = TextureRect.new()
	bg_rect.name = "AltarBackground"
	bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_rect.texture = TEX_ALTAR_BG
	bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var smat = ShaderMaterial.new()
	smat.shader = SHADER_VIGNETTE
	smat.set_shader_parameter("panel_size", Vector2(1050, 440))
	smat.set_shader_parameter("corner_radius", 22.0)
	smat.set_shader_parameter("vignette_amount", 0.65)
	smat.set_shader_parameter("tint_color", Color(0.02, 0.02, 0.03, 0.25))
	smat.set_shader_parameter("edge_shadow_color", Color(0.01, 0.01, 0.02, 0.95))
	bg_rect.material = smat
	_panel.add_child(bg_rect)

	# Contenedor vertical principal
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 18
	vbox.offset_top = 14
	vbox.offset_right = -18
	vbox.offset_bottom = -14
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	# Barra de encabezado
	var header_panel = PanelContainer.new()
	var hb_style = StyleBoxFlat.new()
	hb_style.bg_color = Color(0.02, 0.02, 0.03, 0.65)
	hb_style.set_corner_radius_all(10)
	header_panel.add_theme_stylebox_override("panel", hb_style)
	vbox.add_child(header_panel)

	_title_label = Label.new()
	_title_label.text = "SELECCIONAR CARTA"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_override("font", preload("res://assets/fonts/Cinzel-Bold.ttf"))
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85, 1.0))
	_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_title_label.add_theme_constant_override("shadow_offset_x", 1)
	_title_label.add_theme_constant_override("shadow_offset_y", 1)
	header_panel.add_child(_title_label)

	# Scroll container para las cartas
	_scroll_container = ScrollContainer.new()
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll_container)

	# Contenedor de cartas (horizontal centrado)
	var cards_center = CenterContainer.new()
	cards_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.add_child(cards_center)

	_cards_container = HBoxContainer.new()
	_cards_container.add_theme_constant_override("separation", 16)
	_cards_container.alignment = BoxContainer.ALIGNMENT_CENTER
	cards_center.add_child(_cards_container)

	# Info label (seleccionadas X de Y)
	_info_label = Label.new()
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color(0.88, 0.88, 0.90, 1.0))
	_info_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_info_label.add_theme_constant_override("shadow_offset_y", 1)
	vbox.add_child(_info_label)

	# Contenedor de botones
	_buttons_container = HBoxContainer.new()
	_buttons_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons_container.add_theme_constant_override("separation", 24)
	vbox.add_child(_buttons_container)

	# Botón Cancelar
	_cancel_button = _create_button("Cancelar", false)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_buttons_container.add_child(_cancel_button)

	# Botón Confirmar
	_confirm_button = _create_button("Confirmar", true)
	_confirm_button.pressed.connect(_on_confirm_pressed)
	_buttons_container.add_child(_confirm_button)

	# Hint de arrastre (para modo EXHUMAR)
	_drag_hint_label = Label.new()
	_drag_hint_label.text = "Arrastra una carta al campo para exhumarla"
	_drag_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_drag_hint_label.add_theme_font_size_override("font_size", 13)
	_drag_hint_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6, 0.9))
	_drag_hint_label.visible = false
	vbox.add_child(_drag_hint_label)

	# Indicador de zona de drop para exhumar
	_create_exhume_drop_indicator()


func _create_exhume_drop_indicator() -> void:
	"""Crea el indicador visual de zona de drop para exhumar"""
	_exhume_drop_indicator = Panel.new()
	_exhume_drop_indicator.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_exhume_drop_indicator.offset_left = -300
	_exhume_drop_indicator.offset_top = -180
	_exhume_drop_indicator.offset_right = 300
	_exhume_drop_indicator.offset_bottom = -20

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.25, 0.15, 0.4)
	style.border_color = Color(0.4, 0.7, 0.4, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0.3, 0.6, 0.3, 0.3)
	style.shadow_size = 8
	_exhume_drop_indicator.add_theme_stylebox_override("panel", style)

	var drop_label = Label.new()
	drop_label.text = "SOLTAR AQUÍ PARA EXHUMAR"
	drop_label.set_anchors_preset(Control.PRESET_CENTER)
	drop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drop_label.add_theme_font_size_override("font_size", 18)
	drop_label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5, 0.9))
	_exhume_drop_indicator.add_child(drop_label)

	_exhume_drop_indicator.visible = false
	_exhume_drop_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_exhume_drop_indicator)


func _create_button(text: String, is_confirm: bool) -> Button:
	"""Crea un botón estilizado TCG"""
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(160, 40)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_override("font", preload("res://assets/fonts/Cinzel-Bold.ttf"))
	btn.add_theme_font_size_override("font_size", 15)
	btn.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	btn.add_theme_constant_override("shadow_offset_y", 1)

	var style = StyleBoxFlat.new()
	style.set_corner_radius_all(8)
	style.shadow_size = 6

	if is_confirm:
		style.bg_color = Color(0.08, 0.22, 0.12, 0.90)
		style.border_color = Color(0.35, 0.85, 0.45, 0.9)
		style.set_border_width_all(1)
		style.shadow_color = Color(0.1, 0.6, 0.2, 0.3)
		btn.add_theme_color_override("font_color", Color(0.85, 1.0, 0.88))
	else:
		style.bg_color = Color(0.18, 0.12, 0.12, 0.90)
		style.border_color = Color(0.65, 0.35, 0.35, 0.9)
		style.set_border_width_all(1)
		style.shadow_color = Color(0.5, 0.1, 0.1, 0.3)
		btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.85))

	btn.add_theme_stylebox_override("normal", style)

	var hover_style = style.duplicate()
	hover_style.bg_color = style.bg_color.lightened(0.15)
	btn.add_theme_stylebox_override("hover", hover_style)

	var disabled_style = style.duplicate()
	disabled_style.bg_color = Color(0.1, 0.1, 0.12, 0.6)
	disabled_style.border_color = Color(0.3, 0.3, 0.35, 0.4)
	btn.add_theme_stylebox_override("disabled", disabled_style)

	return btn


# =============================================================================
# API PÚBLICA
# =============================================================================
func open(card_data_list: Array, mode_str: String, config: Dictionary = {}) -> void:
	"""API simplificada con modo como string

	Args:
		card_data_list: Array de diccionarios con datos de cartas
		mode_str: 'REVEAL', 'EXHUMAR', 'SEARCH', 'DISCARD', 'TARGET'
		config: Configuración opcional
	"""
	var mode = MODE_MAP.get(mode_str.to_upper(), SelectionMode.REVEAL)
	open_selection(card_data_list, mode, config)


func open_selection(card_data_list: Array, mode: int, config: Dictionary = {}) -> void:
	"""Abre el panel de selección con las cartas especificadas

	Args:
		card_data_list: Array de diccionarios con datos de cartas
		mode: SelectionMode (REVEAL, EXHUMAR, SEARCH, etc.) o int
		config: {
			title: String,
			max_selections: int,
			min_selections: int,
			filter: Callable,  # (card_data) -> bool
			can_cancel: bool
		}
	"""
	if is_open:
		push_warning("[SelectionManager] Ya hay una selección abierta")
		return

	if card_data_list.is_empty():
		push_warning("[SelectionManager] Lista de cartas vacía")
		emit_signal("selection_cancelled")
		return

	# Configurar
	current_mode = mode
	max_selections = config.get("max_selections", 1)
	min_selections = config.get("min_selections", 0)
	selection_title = config.get("title", _get_default_title(mode))
	selection_filter = config.get("filter", Callable())

	var can_cancel = config.get("can_cancel", true)
	_cancel_button.visible = can_cancel

	# Limpiar estado anterior
	_clear_cards()
	selected_cards.clear()

	# Actualizar UI
	_title_label.text = selection_title
	_update_confirm_button()

	# Instanciar cartas
	for card_data in card_data_list:
		_create_selection_card(card_data, mode)

	# Recién acá 'displayed_cards' ya tiene las cartas instanciadas — antes se
	# llamaba ANTES del loop de arriba y el label de modo REVEAL siempre
	# decía "Mostrando 0 carta(s)" sin importar cuántas se pasaran
	# (2026-08-26, visto con Tangata Manu mostrando 6 cartas).
	_update_info_label()

	# Mostrar hint de arrastre para modo EXHUMAR
	if _drag_hint_label:
		_drag_hint_label.visible = (mode == SelectionMode.EXHUMAR)
	if _exhume_drop_indicator:
		_exhume_drop_indicator.visible = (mode == SelectionMode.EXHUMAR)

	# Mostrar
	visible = true
	is_open = true

	print("[SelectionManager] Abierto en modo %s con %d cartas" % [
		SelectionMode.keys()[mode], card_data_list.size()
	])


func open_reveal(card_data_list: Array, title: String = "Cartas Reveladas") -> void:
	"""Atajo para mostrar cartas sin selección"""
	open_selection(card_data_list, SelectionMode.REVEAL, {
		"title": title,
		"max_selections": 0,
		"can_cancel": false
	})
	# En modo REVEAL, el botón confirmar cierra
	_confirm_button.text = "Cerrar"


func open_exhumar(cemetery_cards: Array, max_select: int = 1) -> void:
	"""Atajo para seleccionar cartas del cementerio para exhumar

	Solo permite seleccionar Aliados (tipo que puede ser exhumado)
	"""
	open_selection(cemetery_cards, SelectionMode.EXHUMAR, {
		"title": "Exhumar del Cementerio",
		"max_selections": max_select,
		"min_selections": 1,
		"filter": func(data): return data.get("tipo", -1) == Constants.CardType.ALIADO
	})


func open_search(deck_cards: Array, max_select: int = 1, filter: Callable = Callable()) -> void:
	"""Atajo para buscar cartas en el mazo"""
	open_selection(deck_cards, SelectionMode.SEARCH, {
		"title": "Buscar en el Mazo",
		"max_selections": max_select,
		"min_selections": 0,
		"filter": filter,
		"can_cancel": true
	})


func await_single_pick(candidates: Array, title: String, can_cancel: bool = true, min_selections: int = 1, filter: Callable = Callable()) -> Dictionary:
	"""Abre un panel CUSTOM de 1-sola-elección y espera la respuesta —
	extraído (2026-08-30) del mismo bloque de 15-20 líneas que se repetía
	copiado en Don de Amma, Tesoro de los Césares, Miguel, las dos de Tyet,
	Bernardo O'Higgins y varias más: open_selection() + Dictionary de
	estado (los lambdas de GDScript capturan variables locales por VALOR,
	así que 'var picked'/'var done' sueltos nunca se enteraban de la
	elección real — ver el resto de este archivo para más detalle de ese
	bug ya conocido) + conectar card_selected/selection_completed/
	selection_cancelled + esperar + desconectar.
	max_selections=1 siempre; min_selections=1 por defecto (con eso,
	SelectionManager emite 'card_selected' apenas se elige la primera, no
	hace falta escuchar 'selection_completed'). min_selections=0 (p.ej.
	costo opcional tipo Bernardo O'Higgins: 'Puedes Barajar...') SÍ puede
	terminar en 'selection_completed' con array vacío (confirmó sin elegir
	nada) — se escuchan las dos señales siempre, la de más no molesta.
	Returns: el card_data elegido, o {} si se canceló o confirmó vacío."""
	open_selection(candidates, SelectionMode.CUSTOM, {
		"title": title,
		"max_selections": 1,
		"min_selections": min_selections,
		"can_cancel": can_cancel,
		"filter": filter,
	})
	var state := {"resolved": false, "picked": {}}
	var on_single := func(d: Dictionary):
		state.picked = d
		state.resolved = true
	var on_completed := func(cards: Array):
		if not cards.is_empty():
			state.picked = cards[0]
		state.resolved = true
	var on_cancelled := func():
		state.resolved = true
	card_selected.connect(on_single, CONNECT_ONE_SHOT)
	selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
	selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
	while not state.resolved:
		await get_tree().process_frame
	if card_selected.is_connected(on_single):
		card_selected.disconnect(on_single)
	if selection_completed.is_connected(on_completed):
		selection_completed.disconnect(on_completed)
	if selection_cancelled.is_connected(on_cancelled):
		selection_cancelled.disconnect(on_cancelled)
	return state.picked


func await_two_choice(main: Node, title: String, option_a: String, option_b: String) -> bool:
	"""Popup de 2 botones estilizado con estética Fantasy TCG.
	Returns: true si se eligió option_a, false si option_b."""
	var picked_idx: int = await await_choice(main, title, [option_a, option_b])
	return picked_idx == 0


func await_choice(main: Node, title: String, options: Array) -> int:
	"""Modal de Elección estilizado Fantasy TCG con fondo de altar catedralicio,
	shader de viñeta suave y botones dorados de alta legibilidad (sin emojis).
	Returns: el índice (0-based) de la opción elegida."""
	var canvas := CanvasLayer.new()
	canvas.layer = 70
	main.add_child(canvas)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.size = main.get_viewport().get_visible_rect().size
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(bg)

	var num_opts: int = options.size()
	# Layout vertical si son 3+ opciones o si el texto es largo, u horizontal si son 2 cortas
	var has_long_text: bool = false
	for opt in options:
		if str(opt).length() > 28:
			has_long_text = true
			break
	var is_vertical: bool = num_opts >= 3 or has_long_text

	var panel_w: float = 720.0 if not is_vertical else 640.0
	var panel_h: float = 190.0 if not is_vertical else (110.0 + float(num_opts) * 54.0)

	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -panel_w / 2.0
	panel.offset_top = -panel_h / 2.0
	panel.offset_right = panel_w / 2.0
	panel.offset_bottom = panel_h / 2.0

	var p_style := StyleBoxFlat.new()
	p_style.bg_color = Color(0.03, 0.03, 0.05, 0.98)
	p_style.set_corner_radius_all(18)
	p_style.shadow_color = Color(0, 0, 0, 0.85)
	p_style.shadow_size = 30
	panel.add_theme_stylebox_override("panel", p_style)
	canvas.add_child(panel)

	# Fondo Altar Catedralicio con Viñeta Suave
	var bg_rect := TextureRect.new()
	bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_rect.texture = TEX_ALTAR_BG
	bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var smat := ShaderMaterial.new()
	smat.shader = SHADER_VIGNETTE
	smat.set_shader_parameter("panel_size", Vector2(panel_w, panel_h))
	smat.set_shader_parameter("corner_radius", 18.0)
	smat.set_shader_parameter("vignette_amount", 0.70)
	smat.set_shader_parameter("tint_color", Color(0.02, 0.02, 0.03, 0.30))
	smat.set_shader_parameter("edge_shadow_color", Color(0.01, 0.01, 0.02, 0.95))
	bg_rect.material = smat
	panel.add_child(bg_rect)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.offset_left = 24
	main_vbox.offset_top = 18
	main_vbox.offset_right = -24
	main_vbox.offset_bottom = -18
	main_vbox.add_theme_constant_override("separation", 12)
	panel.add_child(main_vbox)

	# Título en Cinzel-Bold
	var title_lbl := Label.new()
	title_lbl.text = title.to_upper()
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_override("font", FONT_CINZEL_BOLD)
	title_lbl.add_theme_font_size_override("font_size", 17)
	title_lbl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.60, 1.0))
	title_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title_lbl.add_theme_constant_override("shadow_offset_x", 1)
	title_lbl.add_theme_constant_override("shadow_offset_y", 2)
	main_vbox.add_child(title_lbl)

	# Línea separadora dorada
	var sep := ColorRect.new()
	sep.custom_minimum_size = Vector2(0, 1)
	sep.color = Color(0.75, 0.60, 0.35, 0.40)
	main_vbox.add_child(sep)

	# Contenedor de Opciones
	var opts_box: BoxContainer = VBoxContainer.new() if is_vertical else HBoxContainer.new()
	opts_box.alignment = BoxContainer.ALIGNMENT_CENTER
	opts_box.add_theme_constant_override("separation", 12)
	opts_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(opts_box)

	var state := {"done": false, "picked_index": 0}

	for i in range(num_opts):
		var btn := Button.new()
		btn.text = str(options[i])
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_font_override("font", FONT_CINZEL_BOLD)
		btn.add_theme_font_size_override("font_size", 14)
		if not is_vertical:
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(180, 42)

		# Estilo normal (borde dorado tenue y fondo oscuro elegante)
		var btn_normal := StyleBoxFlat.new()
		btn_normal.bg_color = Color(0.08, 0.09, 0.12, 0.88)
		btn_normal.set_border_width_all(1)
		btn_normal.border_color = Color(0.70, 0.58, 0.35, 0.75)
		btn_normal.set_corner_radius_all(8)
		btn_normal.content_margin_left = 18
		btn_normal.content_margin_right = 18
		btn_normal.content_margin_top = 8
		btn_normal.content_margin_bottom = 8
		btn.add_theme_stylebox_override("normal", btn_normal)
		btn.add_theme_color_override("font_color", Color(0.92, 0.88, 0.80, 1.0))

		# Estilo hover (brillo dorado y fondo iluminado)
		var btn_hover := StyleBoxFlat.new()
		btn_hover.bg_color = Color(0.16, 0.18, 0.24, 0.95)
		btn_hover.set_border_width_all(2)
		btn_hover.border_color = Color(1.0, 0.88, 0.50, 1.0)
		btn_hover.set_corner_radius_all(8)
		btn_hover.content_margin_left = 18
		btn_hover.content_margin_right = 18
		btn_hover.content_margin_top = 8
		btn_hover.content_margin_bottom = 8
		btn.add_theme_stylebox_override("hover", btn_hover)
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 0.95, 1.0))

		var btn_pressed := btn_hover.duplicate()
		btn_pressed.bg_color = Color(0.22, 0.24, 0.32, 1.0)
		btn.add_theme_stylebox_override("pressed", btn_pressed)

		var captured_idx: int = i
		btn.pressed.connect(func():
			state.picked_index = captured_idx
			state.done = true
		)
		opts_box.add_child(btn)

	# Animación de entrada suave
	panel.scale = Vector2(0.94, 0.94)
	panel.pivot_offset = Vector2(panel_w / 2.0, panel_h / 2.0)
	var tween := panel.create_tween()
	tween.tween_property(panel, "scale", Vector2.ONE, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	while not state.done:
		await main.get_tree().process_frame

	canvas.queue_free()
	return state.picked_index


func await_castillo_pick(main: Node, title: String) -> bool:
	"""Espera un click directo sobre el Panel del Castillo propio o del
	rival en el tablero — reemplaza el popup de 2 botones de texto para
	elegir 'tu Castillo o el del oponente' (2026-08-30, a pedido del
	usuario: 'estaría bueno poder hacer click al castillo para hacerlo más
	interactivo', p.ej. Infernum Vox, Aho, Espada del Juicio). Resalta
	ambos paneles con un borde celeste mientras espera. Sin cancelar —
	mismo criterio que await_two_choice(), es una elección obligatoria
	entre dos zonas, no un 'puedes'.
	Returns: true si se clickeó el Castillo propio, false si el rival."""
	var player_castillo: Panel = main.get_node_or_null("GameBoard/PlayerArea/PlayerCastillo")
	var opponent_castillo: Panel = main.get_node_or_null("GameBoard/OpponentArea/OpponentCastillo")
	if not player_castillo or not opponent_castillo:
		# No debería pasar (nodos fijos de Main.tscn) — fallback al popup viejo.
		return await await_two_choice(main, title, "Tu Castillo", "Castillo del oponente")

	if main.has_method("_update_debug"):
		main._update_debug("%s — clickea tu Castillo o el del rival" % title)

	var state := {"resolved": false, "picked_own": true}
	var on_player_input := func(ev: InputEvent) -> void:
		if state.resolved:
			return
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			state.picked_own = true
			state.resolved = true
	var on_opponent_input := func(ev: InputEvent) -> void:
		if state.resolved:
			return
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			state.picked_own = false
			state.resolved = true

	_set_castillo_pick_glow(player_castillo, true)
	_set_castillo_pick_glow(opponent_castillo, true)
	var prev_player_filter := player_castillo.mouse_filter
	var prev_opponent_filter := opponent_castillo.mouse_filter
	player_castillo.mouse_filter = Control.MOUSE_FILTER_STOP
	opponent_castillo.mouse_filter = Control.MOUSE_FILTER_STOP
	player_castillo.gui_input.connect(on_player_input)
	opponent_castillo.gui_input.connect(on_opponent_input)

	# Cursor de mano + pulso suave de brillo (2026-08-30, a pedido del
	# usuario: "también ponerle un efecto o hacerlo 'cliqueable' para mayor
	# visual" — el borde estático ya avisaba que había que elegir, pero no
	# se sentía interactivo hasta clickear). Se para al resolver, junto con
	# todo lo demás.
	var prev_player_cursor := player_castillo.mouse_default_cursor_shape
	var prev_opponent_cursor := opponent_castillo.mouse_default_cursor_shape
	player_castillo.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	opponent_castillo.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var pulse_player := player_castillo.create_tween()
	pulse_player.set_loops()
	pulse_player.tween_property(player_castillo, "modulate", Color(1.25, 1.25, 1.25, 1.0), 0.6).set_trans(Tween.TRANS_SINE)
	pulse_player.tween_property(player_castillo, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.6).set_trans(Tween.TRANS_SINE)
	var pulse_opponent := opponent_castillo.create_tween()
	pulse_opponent.set_loops()
	pulse_opponent.tween_property(opponent_castillo, "modulate", Color(1.25, 1.25, 1.25, 1.0), 0.6).set_trans(Tween.TRANS_SINE)
	pulse_opponent.tween_property(opponent_castillo, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.6).set_trans(Tween.TRANS_SINE)

	while not state.resolved:
		await main.get_tree().process_frame

	if player_castillo.gui_input.is_connected(on_player_input):
		player_castillo.gui_input.disconnect(on_player_input)
	if opponent_castillo.gui_input.is_connected(on_opponent_input):
		opponent_castillo.gui_input.disconnect(on_opponent_input)
	player_castillo.mouse_filter = prev_player_filter
	opponent_castillo.mouse_filter = prev_opponent_filter
	player_castillo.mouse_default_cursor_shape = prev_player_cursor
	opponent_castillo.mouse_default_cursor_shape = prev_opponent_cursor
	pulse_player.kill()
	pulse_opponent.kill()
	player_castillo.modulate = Color(1.0, 1.0, 1.0, 1.0)
	opponent_castillo.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_set_castillo_pick_glow(player_castillo, false)
	_set_castillo_pick_glow(opponent_castillo, false)

	return state.picked_own


func _set_castillo_pick_glow(panel: Panel, on: bool) -> void:
	if not on:
		panel.remove_theme_stylebox_override("panel")
		return
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(0.45, 0.85, 1.0, 1.0)
	style.set_border_width_all(4)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0.45, 0.85, 1.0, 0.6)
	style.shadow_size = 12
	panel.add_theme_stylebox_override("panel", style)


func await_multi_pick(candidates: Array, title: String, max_selections: int, min_selections: int = 0, can_cancel: bool = true, filter: Callable = Callable()) -> Dictionary:
	"""Selección múltiple (0 a max_selections) y espera la respuesta —
	extraído (2026-08-30) del mismo bloque repetido en
	_resolve_search_cemetery_to_hand()/_select_hand_cards_for_discard()
	(TargetedEffectExecutor.gd) y _resolve_reveal_cost_reduction()
	(GoldManager.gd). A diferencia de await_single_pick(), acá 'canceló
	del todo' y 'confirmó sin elegir nada' son resultados DISTINTOS a
	propósito (algunos llamadores necesitan diferenciarlos: declinar el
	'puedes' entero vs. aceptarlo pero no encontrar nada que valga la
	pena elegir) — por eso devuelve un Dictionary con las dos señales en
	vez de colapsarlas en un Array vacío como haría await_single_pick().
	Returns: {"cancelled": bool, "picked": Array[Dictionary]}."""
	open_selection(candidates, SelectionMode.CUSTOM, {
		"title": title,
		"max_selections": max_selections,
		"min_selections": min_selections,
		"can_cancel": can_cancel,
		"filter": filter,
	})
	var state := {"resolved": false, "picked": [], "cancelled": false}
	var on_single := func(d: Dictionary):
		state.picked = [d]
		state.resolved = true
	var on_completed := func(cards: Array):
		state.picked = cards
		state.resolved = true
	var on_cancelled := func():
		state.cancelled = true
		state.resolved = true
	card_selected.connect(on_single, CONNECT_ONE_SHOT)
	selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
	selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
	while not state.resolved:
		await get_tree().process_frame
	if card_selected.is_connected(on_single):
		card_selected.disconnect(on_single)
	if selection_completed.is_connected(on_completed):
		selection_completed.disconnect(on_completed)
	if selection_cancelled.is_connected(on_cancelled):
		selection_cancelled.disconnect(on_cancelled)
	return {"cancelled": state.cancelled, "picked": state.picked}


func close_selection() -> void:
	"""Cierra el panel de selección"""
	if not is_open:
		return

	_clear_cards()
	selected_cards.clear()

	# Ocultar indicadores de exhumar
	if _drag_hint_label:
		_drag_hint_label.visible = false
	if _exhume_drop_indicator:
		_exhume_drop_indicator.visible = false

	visible = false
	is_open = false

	print("[SelectionManager] Cerrado")


# =============================================================================
# GESTIÓN DE CARTAS
# =============================================================================
func _create_selection_card(card_data: Dictionary, mode: int) -> void:
	"""Crea una instancia de carta para la selección"""
	var card = CardScene.instantiate()
	card.load_from_data(card_data)

	# Escala para el panel de selección (tamaño completo y quieto sin encogerse)
	card.scale = Vector2.ONE
	card.base_scale = Vector2.ONE
	card.card_scale_hover = 1.0

	# Determinar si es seleccionable
	var is_selectable = _is_card_selectable(card_data, mode)
	card.can_interact = is_selectable

	# Visual para cartas no seleccionables
	if not is_selectable:
		card.modulate = Color(0.5, 0.5, 0.5, 0.7)

	# Conectar señales básicas
	card.card_clicked.connect(_on_card_clicked)
	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)

	# Inspección con click derecho (2026-08-30, a pedido del usuario: poder
	# leer de cerca las cartas de un pool de selección — p.ej. elegir cuáles
	# desterrar de los Cementerios con Espada de O'Higgins — antes no
	# conectaba nada, así que el click derecho no hacía nada acá). current_zone
	# por defecto es Constants.Zone.MANO (Card.gd) y esta instancia nunca pasa
	# por set_zone(): sin corregirlo, _build_ability_buttons() la trataría
	# como si estuviera en la mano y podría ofrecer botones de habilidades
	# 'usables desde la mano' (Ramón Freire/Tyet) que no deberían aparecer
	# para una carta que solo se está mostrando en un pool de elección.
	card.set_zone(Constants.Zone.CEMENTERIO)
	var main := get_node_or_null("/root/Main")
	if main and main.get("_card_inspector"):
		card.card_right_clicked.connect(main._card_inspector.on_card_right_clicked)

	# Agregar al contenedor primero para obtener posición
	_cards_container.add_child(card)
	displayed_cards.append(card)
	_card_data_map[card] = card_data

	# Habilitar arrastre para modo EXHUMAR
	if mode == SelectionMode.EXHUMAR and is_selectable:
		card.card_dropped.connect(_on_exhumar_card_dropped.bind(card_data))
		# Marcar la carta para que pueda ser arrastrada desde selección
		card.set_meta("from_selection", true)
		card.set_meta("selection_mode", mode)
		# Forzar estado IN_HAND para permitir arrastre
		card.current_state = card.CardState.IN_HAND
		# Guardar posición original después del layout
		_save_card_original_position.call_deferred(card)


func _save_card_original_position(card: Node) -> void:
	"""Guarda la posición original de una carta de selección (llamado deferred)"""
	if is_instance_valid(card):
		card.set_meta("original_selection_pos", card.global_position)
		card.original_position = card.global_position


func _is_card_selectable(card_data: Dictionary, mode: int) -> bool:
	"""Determina si una carta puede ser seleccionada según el modo"""
	# Modo REVEAL no permite selección
	if mode == SelectionMode.REVEAL:
		return false

	# Aplicar filtro personalizado si existe
	if selection_filter.is_valid():
		return selection_filter.call(card_data)

	# Filtros por defecto según modo
	match mode:
		SelectionMode.EXHUMAR:
			# Para EXHUMAR: solo Aliados pueden ser objetivo de exhumación
			# (cartas que pueden ser traídas del cementerio al campo)
			return _can_be_exhumed(card_data)
		SelectionMode.SEARCH:
			return true  # Todo es buscable por defecto
		SelectionMode.DISCARD:
			return true
		SelectionMode.TARGET:
			return true
		_:
			return true


func _can_be_exhumed(card_data: Dictionary) -> bool:
	"""Verifica si una carta puede ser exhumada del cementerio

	Criterios:
	- Debe ser un Aliado (tipo que puede entrar al campo)
	- Opcionalmente puede tener la habilidad 'Exhumar' en su texto
	"""
	var tipo = card_data.get("tipo", -1)

	# Solo Aliados pueden ser exhumados al campo
	if tipo != Constants.CardType.ALIADO:
		return false

	return true


func _has_exhumar_ability(card_data: Dictionary) -> bool:
	"""Verifica si una carta tiene la habilidad Exhumar en su texto"""
	var habilidad = card_data.get("habilidad", "").to_lower()
	var keywords = card_data.get("keywords", [])

	# Buscar en habilidad
	if "exhumar" in habilidad:
		return true

	# Buscar en keywords
	for kw in keywords:
		if typeof(kw) == TYPE_STRING and "exhumar" in kw.to_lower():
			return true

	return false


func _clear_cards() -> void:
	"""Limpia todas las cartas instanciadas"""
	for card in displayed_cards:
		if is_instance_valid(card):
			# Desconectar señales de interacción ANTES de liberar (2026-08-29,
			# mismo bug que CardManager.destroy_card()/exile_card()) — estas
			# cartas del panel se conectan a card_clicked/card_hovered/
			# card_unhovered (ver _display_card() más arriba) y sin
			# desconectar, un hover que sigue apuntando al nodo después de
			# queue_free() tira "Invalid access... on a base object of type
			# previously freed" al tocar .modulate en el próximo evento de
			# mouse (reportado: pasaba justo al elegir un Oro del Castillo
			# en la búsqueda de Don de Amma, que cierra este panel).
			CardManager._disconnect_card_interaction_signals(card)
			card.queue_free()
	displayed_cards.clear()
	_card_data_map.clear()


func _get_default_title(mode: int) -> String:
	"""Obtiene el título por defecto según el modo"""
	match mode:
		SelectionMode.REVEAL:
			return "Cartas Reveladas"
		SelectionMode.EXHUMAR:
			return "Exhumar del Cementerio"
		SelectionMode.SEARCH:
			return "Buscar en el Mazo"
		SelectionMode.DISCARD:
			return "Seleccionar para Descartar"
		SelectionMode.TARGET:
			return "Seleccionar Objetivo"
		_:
			return "Seleccionar Carta"


# =============================================================================
# MANEJO DE SELECCIÓN
# =============================================================================
func _on_card_clicked(card: Node) -> void:
	"""Maneja el click en una carta - selección inmediata"""
	if current_mode == SelectionMode.REVEAL:
		return

	if not card.can_interact:
		return

	# Obtener datos de la carta
	var card_data = _card_data_map.get(card, {})
	if card_data.is_empty():
		return

	# Selección única: emitir señal y cerrar inmediatamente
	if max_selections == 1:
		# Efecto visual rápido
		card.modulate = Color(1.3, 1.2, 0.8, 1)

		var card_name = card_data.get("nombre", "?")
		print("[SelectionManager] Carta seleccionada: %s" % card_name)

		# Cerrar y emitir señal con los datos
		close_selection()
		emit_signal("card_selected", card_data)
		return

	# Multi-selección: toggle
	if card in selected_cards:
		_deselect_card(card)
	else:
		if max_selections > 0 and selected_cards.size() >= max_selections:
			return  # Límite alcanzado
		_select_card(card)
		# Al llegar al máximo ya no queda ninguna elección posible (2026-08-28,
		# a pedido del usuario: clickear la carta que quiero elegir alcanza,
		# sin tener que apretar Confirmar aparte) — confirma solo. Si
		# min_selections < max_selections (p.ej. "hasta 2") el botón
		# Confirmar sigue disponible para cerrar con MENOS del máximo.
		if max_selections > 0 and selected_cards.size() >= max_selections:
			_on_confirm_pressed()
			return

	_update_info_label()
	_update_confirm_button()


func _select_card(card: Node) -> void:
	"""Selecciona una carta visualmente (modo multi-selección) — sin salto de
	posición (2026-08-28, a pedido del usuario: 'quitar el salto de
	cartas'), solo un tinte para marcar que está elegida."""
	selected_cards.append(card)
	card.modulate = Color(1.2, 1.1, 0.8, 1)


func _deselect_card(card: Node) -> void:
	"""Deselecciona una carta (modo multi-selección)"""
	selected_cards.erase(card)
	card.modulate = Color(1, 1, 1, 1)


func _on_card_hovered(card: Node) -> void:
	"""Hover sobre carta"""
	if not card.can_interact:
		return
	card.z_index = 10


func _on_card_unhovered(card: Node) -> void:
	"""Unhover de carta"""
	card.z_index = 0


func _on_exhumar_card_dropped(card: Node, drop_position: Vector2, card_data: Dictionary) -> void:
	"""Maneja cuando una carta del cementerio es arrastrada y soltada"""
	# Verificar si cayó en el indicador interno de exhumar
	var dropped_on_indicator = false
	if _exhume_drop_indicator and _exhume_drop_indicator.visible:
		var indicator_rect = _exhume_drop_indicator.get_global_rect()
		if indicator_rect.has_point(drop_position):
			dropped_on_indicator = true

	# O en una zona de drop externa (campo de batalla)
	var drop_zone = _get_field_drop_zone_at(drop_position)

	if dropped_on_indicator or drop_zone:
		print("[SelectionManager] Carta exhumada arrastrada al campo: %s" % card_data.get("nombre", "?"))

		# Cerrar selección y emitir señal de exhumar
		close_selection()
		emit_signal("card_selected", card_data)
	else:
		# No cayó en zona válida, regresar a su posición en la selección
		var original_pos = card.get_meta("original_selection_pos", card.global_position)
		card.current_state = card.CardState.IN_HAND

		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(card, "global_position", original_pos, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
		tween.tween_property(card, "scale", card.base_scale, 0.2)


func _get_field_drop_zone_at(global_pos: Vector2) -> Node:
	"""Busca una zona de drop válida en la posición dada"""
	var drop_zones = get_tree().get_nodes_in_group("drop_zones")
	for zone in drop_zones:
		if zone is Control:
			var rect = zone.get_global_rect()
			if rect.has_point(global_pos):
				# Verificar que sea zona de campo (no de oro)
				var zone_type = zone.get("zone_type") if zone.get("zone_type") != null else -1
				if zone_type == Constants.Zone.LINEA_DEFENSA:
					return zone
	return null


# =============================================================================
# BOTONES
# =============================================================================
func _on_confirm_pressed() -> void:
	"""Confirma la selección"""
	# En modo REVEAL, solo cerrar
	if current_mode == SelectionMode.REVEAL:
		close_selection()
		emit_signal("selection_completed", [])
		return

	# Verificar mínimo de selecciones
	if selected_cards.size() < min_selections:
		print("[SelectionManager] Selección insuficiente: %d/%d" % [
			selected_cards.size(), min_selections
		])
		return

	# Recopilar datos de cartas seleccionadas
	var selected_data: Array = []
	for card in selected_cards:
		if _card_data_map.has(card):
			selected_data.append(_card_data_map[card])

	close_selection()
	emit_signal("selection_completed", selected_data)

	print("[SelectionManager] Selección confirmada: %d cartas" % selected_data.size())


func _on_cancel_pressed() -> void:
	"""Cancela la selección"""
	close_selection()
	emit_signal("selection_cancelled")
	print("[SelectionManager] Selección cancelada")


# =============================================================================
# UI HELPERS
# =============================================================================
func _update_info_label() -> void:
	"""Actualiza el label de información"""
	if current_mode == SelectionMode.REVEAL:
		_info_label.text = "Mostrando %d carta(s)" % displayed_cards.size()
	elif max_selections > 0:
		_info_label.text = "Seleccionadas: %d / %d" % [selected_cards.size(), max_selections]
	else:
		_info_label.text = "Seleccionadas: %d" % selected_cards.size()

	if min_selections > 0 and selected_cards.size() < min_selections:
		_info_label.text += " (mínimo %d)" % min_selections


func _update_confirm_button() -> void:
	"""Actualiza el estado del botón confirmar"""
	if current_mode == SelectionMode.REVEAL:
		_confirm_button.text = "Cerrar"
		_confirm_button.disabled = false
	else:
		_confirm_button.text = "Confirmar"
		_confirm_button.disabled = selected_cards.size() < min_selections


# =============================================================================
# INPUT
# =============================================================================
func _input(event: InputEvent) -> void:
	if not is_open:
		return

	# ESC para cancelar (si está permitido)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _cancel_button.visible:
			_on_cancel_pressed()
		get_viewport().set_input_as_handled()
