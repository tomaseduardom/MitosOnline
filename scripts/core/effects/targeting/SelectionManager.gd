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

## Módulo extraído (Fase 4 de reestructuración)
var _dialogs: RefCounted

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	layer = 90  # Por encima del juego, debajo de pausa
	visible = false
	_build_ui()
	_dialogs = preload("res://scripts/core/effects/targeting/SelectionDialogs.gd").new()
	_dialogs.setup(self)
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
	panel_style.bg_color = Color(0.04, 0.03, 0.06, 0.98)
	panel_style.border_color = Color(0.85, 0.72, 0.28, 0.95)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(18)
	panel_style.shadow_color = Color(0, 0, 0, 0.90)
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
	smat.set_shader_parameter("corner_radius", 18.0)
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


func open_selection(card_data_list: Array, mode: int, config: Dictionary = {}, chooser_id: int = 0) -> void:
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
		chooser_id: quién debe elegir (0 = jugador local/Anfitrión, el único
			caso que existía antes de esto; 1 = jugador 1). 2026-09-30, Fase 3
			del plan de paridad remota (docs/plans/2026-09-20-remote-
			multiplayer-parity.md) — default 0 a propósito: ningún llamador
			existente (~100 sitios reales) necesita cambiar, solo los que se
			conviertan a propósito para que el Remoto decida sus propias
			cartas pasan chooser_id=1 explícito.
	"""
	if is_open:
		push_warning("[SelectionManager] Ya hay una selección abierta")
		return

	if card_data_list.is_empty():
		push_warning("[SelectionManager] Lista de cartas vacía")
		emit_signal("selection_cancelled")
		return

	# Fase 3 del plan de paridad remota: si quien debe elegir es el jugador 1
	# Y ese jugador es un Remoto real conectado (sin sala de red activa esto
	# no aplica — sigue el camino local de siempre, el bot incluido, sin
	# cambios), la elección se manda por red en vez de abrir la UI local acá
	# — abrirla localmente le haría elegir al ANFITRIÓN por una carta que no
	# es suya. _delegate_selection_to_remote() termina emitiendo las MISMAS
	# señales (card_selected/selection_completed/selection_cancelled) que la
	# UI local emitiría, así que todo lo que ya escucha esas señales (las
	# funciones de SelectionDialogs.gd, open_search()/open_exhumar(), y
	# código que escucha directo como ActionSearch._select_search_results())
	# sigue funcionando sin que haga falta tocarlo.
	if chooser_id == 1 and NetworkClient.room_code != "" and NetworkClient.is_host:
		_delegate_selection_to_remote(card_data_list, mode, config)
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

	# Solo aquí 'displayed_cards' ya tiene las cartas instanciadas — antes se
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


func open_search(deck_cards: Array, max_select: int = 1, filter: Callable = Callable(), chooser_id: int = 0) -> void:
	"""Atajo para buscar cartas en el mazo"""
	open_selection(deck_cards, SelectionMode.SEARCH, {
		"title": "Buscar en el Mazo",
		"max_selections": max_select,
		"min_selections": 0,
		"filter": filter,
		"can_cancel": true
	}, chooser_id)


func _delegate_selection_to_remote(card_data_list: Array, mode: int, config: Dictionary) -> void:
	"""Contraparte en red de abrir la UI local — ver el comentario en
	open_selection() que llama acá. Construye el prompt con las cartas que
	de verdad pasan el filtro (las que no pasan ni se muestran — mismo
	criterio de bajo pulido ya usado para 'choose_wielder' en
	RemoteMirrorController.gd), espera la respuesta, y emite las señales
	normales de SelectionManager con los datos elegidos."""
	var max_sel: int = config.get("max_selections", 1)
	var min_sel: int = config.get("min_selections", 0)
	var can_cancel: bool = config.get("can_cancel", true)
	var title: String = config.get("title", _get_default_title(mode))
	var filter: Callable = config.get("filter", Callable())

	var candidates_payload: Array = []
	for data in card_data_list:
		if filter.is_valid() and not filter.call(data):
			continue
		candidates_payload.append(data)

	NetworkClient.send_message({
		"op": "prompt", "kind": "select_cards",
		"title": title,
		"candidates": candidates_payload,
		"max_selections": max_sel,
		"min_selections": min_sel,
		"can_cancel": can_cancel,
	})
	var intent: Dictionary = await NetworkClient.await_intent(["select_cards_choice"])

	if bool(intent.get("cancelled", false)):
		emit_signal("selection_cancelled")
		return

	var chosen_data: Array = []
	for pos in intent.get("indices", []):
		var p: int = int(pos)
		if p >= 0 and p < candidates_payload.size():
			chosen_data.append(candidates_payload[p])

	if max_sel == 1:
		if chosen_data.is_empty():
			emit_signal("selection_cancelled")
		else:
			emit_signal("card_selected", chosen_data[0])
	else:
		emit_signal("selection_completed", chosen_data)


## Los 5 diálogos modales (implementación en SelectionDialogs.gd) — la API
## externa dominante de este autoload (54x/52x/33x/4x/2x llamadas en todo
## el proyecto).
func await_single_pick(candidates: Array, title: String, can_cancel: bool = true, min_selections: int = 1, filter: Callable = Callable()) -> Dictionary:
	return await _dialogs.await_single_pick(candidates, title, can_cancel, min_selections, filter)


func await_two_choice(main: Node, title: String, option_a: String, option_b: String, chooser_id: int = 0) -> bool:
	return await _dialogs.await_two_choice(main, title, option_a, option_b, chooser_id)


func await_card_pair_choice(
	main: Node,
	title: String,
	card_data_a: Dictionary,
	card_data_b: Dictionary,
	label_a: String = "Tope del Castillo",
	label_b: String = "Fondo del Castillo",
	face_down_b: bool = true,
	face_down_a: bool = false
) -> bool:
	return await _dialogs.await_card_pair_choice(
		main, title, card_data_a, card_data_b, label_a, label_b, face_down_b, face_down_a
	)


func await_choice(main: Node, title: String, options: Array, chooser_id: int = 0) -> int:
	return await _dialogs.await_choice(main, title, options, chooser_id)


func await_castillo_pick(main: Node, title: String) -> bool:
	return await _dialogs.await_castillo_pick(main, title)


func start_castillo_pick(main: Node, title: String, callback: Callable) -> void:
	_dialogs.start_castillo_pick(main, title, callback)


func cancel_castillo_pick() -> void:
	_dialogs.cancel_castillo_pick()


func await_multi_pick(candidates: Array, title: String, max_selections: int, min_selections: int = 0, can_cancel: bool = true, filter: Callable = Callable()) -> Dictionary:
	return await _dialogs.await_multi_pick(candidates, title, max_selections, min_selections, can_cancel, filter)


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
	# conectaba nada, así que el click derecho no hacía nada aquí). current_zone
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
	"""Selecciona una carta visualmente con halo de selección noble"""
	selected_cards.append(card)
	card.modulate = Color(1.15, 1.15, 1.15, 1.0)
	var sel_effect = card.get_node_or_null("SelectionEffect")
	if sel_effect:
		sel_effect.visible = true
		var s_style = StyleBoxFlat.new()
		s_style.bg_color = Color(0.95, 0.75, 0.25, 0.12)
		s_style.border_color = Color(1.0, 0.88, 0.40, 1.0)
		s_style.set_border_width_all(3)
		s_style.set_corner_radius_all(8)
		s_style.shadow_color = Color(1.0, 0.80, 0.30, 0.60)
		s_style.shadow_size = 8
		sel_effect.add_theme_stylebox_override("panel", s_style)


func _deselect_card(card: Node) -> void:
	"""Deselecciona una carta (modo multi-selección)"""
	selected_cards.erase(card)
	card.modulate = Color(1.0, 1.0, 1.0, 1.0)
	var sel_effect = card.get_node_or_null("SelectionEffect")
	if sel_effect:
		sel_effect.visible = false


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
