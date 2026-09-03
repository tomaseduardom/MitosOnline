extends CanvasLayer
## SelectionCanvas - UI para efectos de Buscar, Mirar y Mostrar (DAR Sección 8)
## Gestiona la selección de cartas con pausa de ejecución

class_name SelectionCanvas

# =============================================================================
# SIGNALS
# =============================================================================
# Señales de selección
signal selection_started(mode: SelectionMode, cards: Array)
signal card_selected(card: Node)
signal card_deselected(card: Node)
signal selection_confirmed(selected_cards: Array)
signal selection_cancelled
signal selection_failed  # Jugador eligió "no encontrar" en zona privada

# Señales para oponente (información pública)
signal cards_revealed_to_opponent(player_id: int, cards: Array, context: String)
signal card_shown_to_opponent(player_id: int, card: Node)
signal reveal_ended(player_id: int)

# =============================================================================
# MODOS DE SELECCIÓN
# =============================================================================
enum SelectionMode {
	SEARCH,    # Buscar: seleccionar de zona, puede fallar en privadas
	LOOK,      # Mirar: ver y reordenar, privado
	SHOW,      # Mostrar: revelar al oponente
	DISCARD,   # Descartar: seleccionar para descartar
	TARGET,    # Objetivo: seleccionar objetivo de efecto
	REORDER    # Reordenar: cambiar orden de cartas
}

# =============================================================================
# ESTADO
# =============================================================================
var current_mode: SelectionMode = SelectionMode.SEARCH
var available_cards: Array = []
var selected_cards: Array = []
var amount_to_select: int = 1
var min_to_select: int = 1
var max_to_select: int = 1
var can_fail: bool = false  # Puede elegir "no encontrar"
var is_public: bool = false  # Si es visible para el oponente

var is_active: bool = false
var selection_complete: bool = false
var player_id: int = 0

# Para reordenamiento
var is_reorder_mode: bool = false
var card_order: Array = []

## Módulos extraídos (Fase 4 de reestructuración)
var _filter_validator: CardFilterValidator
var _reorder: SelectionReorder
var _reveal: SelectionReveal

# =============================================================================
# FILTRO DE VALIDACIÓN DE REQUISITOS
# =============================================================================
## Filtro actual para validar selecciones
## Estructura: {card_type, card_race, card_class, max_cost, min_cost, custom: Callable, etc.}
var selection_filter: Dictionary = {}

## Cartas que cumplen el filtro (para visualización)
var valid_cards: Array = []

## Mensaje de error de validación
var validation_error: String = ""

# UI References (asignar desde el editor o buscar)
@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/TitleLabel
@onready var instruction_label: Label = $Panel/InstructionLabel
@onready var cards_container: Control = $Panel/CardsContainer
@onready var confirm_button: Button = $Panel/ButtonsContainer/ConfirmButton
@onready var cancel_button: Button = $Panel/ButtonsContainer/CancelButton
@onready var fail_button: Button = $Panel/ButtonsContainer/FailButton  # "No encontrar"
@onready var counter_label: Label = $Panel/CounterLabel


func _ready() -> void:
	# Inicializar módulos extraídos
	_filter_validator = CardFilterValidator.new()
	_filter_validator.setup(self)
	_reorder = SelectionReorder.new()
	_reorder.setup(self)
	_reveal = SelectionReveal.new()
	_reveal.setup(self)

	# Ocultar al inicio
	visible = false
	is_active = false

	# Conectar botones si existen
	if confirm_button:
		confirm_button.pressed.connect(_on_confirm_pressed)
	if cancel_button:
		cancel_button.pressed.connect(_on_cancel_pressed)
	if fail_button:
		fail_button.pressed.connect(_on_fail_pressed)


# =============================================================================
# FUNCIÓN PRINCIPAL - OPEN_SELECTION (con await)
# =============================================================================
func open_selection(cards: Array, amount: int = 1, can_fail_selection: bool = false, mode: SelectionMode = SelectionMode.SEARCH, filter: Dictionary = {}) -> Dictionary:
	"""Abre la UI de selección y espera la respuesta del jugador
	USA AWAIT - pausa la ejecución hasta que el jugador elija

	Args:
		cards: Array de cartas disponibles para seleccionar
		amount: Cantidad de cartas a seleccionar
		can_fail_selection: Si puede elegir "no encontrar" (zonas privadas)
		mode: Modo de selección (SEARCH, LOOK, SHOW, etc.)
		filter: Diccionario con requisitos que deben cumplir las cartas:
			- card_type: int (Constants.CardType.ALIADO, etc.)
			- card_race: String ("Humano", "Elfo", etc.)
			- card_class: String
			- max_cost: int
			- min_cost: int
			- min_attack: int
			- min_defense: int
			- has_keyword: String
			- custom: Callable que recibe carta y retorna bool

	Returns: {
		success: bool,
		selected: Array de cartas seleccionadas,
		failed: bool (eligió no encontrar),
		cancelled: bool
	}
	"""
	var result = {
		"success": false,
		"selected": [],
		"failed": false,
		"cancelled": false,
		"new_order": []  # Para modo REORDER
	}

	if cards.is_empty():
		print("[SelectionCanvas] No hay cartas para seleccionar")
		result.failed = true
		return result

	# Configurar estado
	current_mode = mode
	available_cards = cards.duplicate()
	selected_cards.clear()
	amount_to_select = amount
	min_to_select = 1 if not can_fail_selection else 0
	max_to_select = amount
	can_fail = can_fail_selection
	is_public = (mode == SelectionMode.SHOW)
	is_reorder_mode = (mode == SelectionMode.REORDER or mode == SelectionMode.LOOK)
	selection_complete = false
	selection_filter = filter
	validation_error = ""

	# Pre-calcular cartas válidas según filtro
	valid_cards = _filter_validator.get_valid_cards(cards, filter)

	if is_reorder_mode:
		card_order = cards.duplicate()

	# Configurar UI
	_setup_ui_for_mode(mode, amount)
	_display_cards(cards)

	# Mostrar panel
	visible = true
	is_active = true

	emit_signal("selection_started", mode, cards)
	print("[SelectionCanvas] Selección abierta: %d cartas, seleccionar %d" % [cards.size(), amount])

	# === ESPERAR HASTA QUE SE COMPLETE ===
	while is_active and not selection_complete:
		await get_tree().process_frame

	# Procesar resultado
	if selection_complete:
		result.success = true
		result.selected = selected_cards.duplicate()

		if is_reorder_mode:
			result.new_order = card_order.duplicate()

		# Si es modo SHOW, notificar al oponente
		if is_public and not selected_cards.is_empty():
			await _reveal.reveal_to_opponent(selected_cards)

	elif can_fail and selected_cards.is_empty():
		result.failed = true
		result.success = true  # "Fallar" es una acción válida

	else:
		result.cancelled = true

	# Ocultar y limpiar
	_close_selection()

	return result


# =============================================================================
# VERSIÓN CON SEÑALES (alternativa sin await)
# =============================================================================
func open_selection_async(cards: Array, amount: int = 1, can_fail_selection: bool = false, mode: SelectionMode = SelectionMode.SEARCH) -> void:
	"""Versión asíncrona que usa señales en lugar de await
	Escuchar: selection_confirmed, selection_cancelled, selection_failed
	"""
	if cards.is_empty():
		emit_signal("selection_failed")
		return

	current_mode = mode
	available_cards = cards.duplicate()
	selected_cards.clear()
	amount_to_select = amount
	min_to_select = 1 if not can_fail_selection else 0
	max_to_select = amount
	can_fail = can_fail_selection
	is_public = (mode == SelectionMode.SHOW)
	is_reorder_mode = (mode == SelectionMode.REORDER or mode == SelectionMode.LOOK)
	selection_complete = false

	if is_reorder_mode:
		card_order = cards.duplicate()

	_setup_ui_for_mode(mode, amount)
	_display_cards(cards)

	visible = true
	is_active = true

	emit_signal("selection_started", mode, cards)


# =============================================================================
# CONFIGURACIÓN DE UI
# =============================================================================
func _setup_ui_for_mode(mode: SelectionMode, amount: int) -> void:
	"""Configura la UI según el modo de selección

	DAR Sección 1.D: Muestra requisitos del filtro claramente
	"""
	var title = ""
	var instruction = ""

	# Generar descripción del filtro para el título/instrucción
	var filter_desc = _filter_validator.get_filter_description()
	var has_filter = not selection_filter.is_empty()

	match mode:
		SelectionMode.SEARCH:
			if has_filter:
				title = "Buscar: %s" % filter_desc
			else:
				title = "Buscar"
			instruction = "Selecciona %d carta(s)" % amount
			if has_filter:
				instruction += " que cumplan el requisito"
			if fail_button:
				fail_button.visible = can_fail
				fail_button.text = "No encontrar"

		SelectionMode.LOOK:
			title = "Mirar"
			instruction = "Mira las cartas. Puedes reordenarlas."
			if fail_button:
				fail_button.visible = false

		SelectionMode.SHOW:
			title = "Mostrar"
			instruction = "Estas cartas serán reveladas al oponente"
			if fail_button:
				fail_button.visible = false

		SelectionMode.DISCARD:
			if has_filter:
				title = "Descartar: %s" % filter_desc
			else:
				title = "Descartar"
			instruction = "Selecciona %d carta(s) para descartar" % amount
			if fail_button:
				fail_button.visible = false

		SelectionMode.TARGET:
			if has_filter:
				title = "Elegir: %s" % filter_desc
			else:
				title = "Elegir Objetivo"
			instruction = "Selecciona el objetivo del efecto"
			if has_filter:
				instruction = "Selecciona %s válido" % filter_desc
			if fail_button:
				fail_button.visible = can_fail
				fail_button.text = "Cancelar"

		SelectionMode.REORDER:
			title = "Reordenar"
			instruction = "Arrastra para cambiar el orden (arriba = tope)"
			if fail_button:
				fail_button.visible = false

	if title_label:
		title_label.text = title
	if instruction_label:
		instruction_label.text = instruction
		instruction_label.modulate = Color(1, 1, 1, 1)  # Reset color

	# Mostrar resumen de cartas válidas si hay filtro
	if has_filter and instruction_label:
		var valid_count = valid_cards.size()
		var total_count = available_cards.size()
		if valid_count < total_count:
			instruction_label.text += "\n(%d de %d cartas cumplen el requisito)" % [valid_count, total_count]

	_update_counter()
	_update_confirm_button()


func _display_cards(cards: Array) -> void:
	"""Muestra las cartas en el contenedor"""
	if not cards_container:
		push_warning("[SelectionCanvas] No hay contenedor de cartas")
		return

	# Limpiar contenedor
	for child in cards_container.get_children():
		child.queue_free()

	# Crear visualización para cada carta
	for card in cards:
		var card_display = _create_card_display(card)
		if card_display:
			cards_container.add_child(card_display)

	# Aplicar validación visual después de crear todas las cartas
	if not selection_filter.is_empty():
		_filter_validator.update_validation_display()


func _create_card_display(card: Node) -> Control:
	"""Crea un control visual para una carta en la selección

	DAR Sección 1.D: Muestra íconos de tipo para validación visual
	"""
	# Verificar si la carta es válida según el filtro
	var is_valid = _filter_validator.card_passes_filter(card, selection_filter)

	# Crear contenedor clickeable
	var display = Button.new()
	display.custom_minimum_size = Vector2(120, 180)
	display.toggle_mode = not is_reorder_mode  # Toggle para selección, no para reorder

	# Estilo según validez
	if is_valid or selection_filter.is_empty():
		display.add_theme_stylebox_override("normal", _create_card_style(false))
		display.add_theme_stylebox_override("pressed", _create_card_style(true))
		display.add_theme_stylebox_override("hover", _create_card_style(false, true))
	else:
		# Estilo para carta inválida
		display.add_theme_stylebox_override("normal", _create_invalid_card_style())
		display.add_theme_stylebox_override("pressed", _create_invalid_card_style())
		display.add_theme_stylebox_override("hover", _create_invalid_card_style())
		display.disabled = true
		display.mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN
		display.modulate = Color(0.6, 0.6, 0.6, 0.8)

	# Guardar referencia a la carta y estado de validez
	display.set_meta("card", card)
	display.set_meta("is_valid", is_valid)

	# Contenedor interno para layout vertical
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 2)
	display.add_child(vbox)

	# ===== ÍCONO DE TIPO (DAR Sección 1.D) =====
	var type_container = HBoxContainer.new()
	type_container.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(type_container)

	var type_icon = _create_type_icon(card)
	type_container.add_child(type_icon)

	# Indicador de validez junto al ícono de tipo
	if not selection_filter.is_empty():
		var validity_icon = Label.new()
		validity_icon.add_theme_font_size_override("font_size", 14)

		if is_valid:
			validity_icon.text = " ✓"
			validity_icon.modulate = Color(0.2, 0.9, 0.2, 1)  # Verde
		else:
			validity_icon.text = " ✗"
			validity_icon.modulate = Color(0.9, 0.2, 0.2, 1)  # Rojo

		type_container.add_child(validity_icon)

	# ===== IMAGEN DE CARTA =====
	if card.get("card_texture"):
		var tex_rect = TextureRect.new()
		tex_rect.texture = card.card_texture
		tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.custom_minimum_size = Vector2(100, 120)
		vbox.add_child(tex_rect)
	else:
		# Placeholder si no hay textura
		var placeholder = ColorRect.new()
		placeholder.color = Color(0.2, 0.2, 0.25, 0.8)
		placeholder.custom_minimum_size = Vector2(100, 120)
		vbox.add_child(placeholder)

	# ===== NOMBRE DE CARTA =====
	var name_label = Label.new()
	name_label.text = card.card_name if card.get("card_name") else "Carta"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.custom_minimum_size.y = 25
	vbox.add_child(name_label)

	# ===== INFO ADICIONAL (coste, stats) =====
	var info_label = Label.new()
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.add_theme_font_size_override("font_size", 9)
	info_label.modulate = Color(0.7, 0.7, 0.7, 1)

	var info_parts: Array = []
	if card.get("card_cost") != null:
		info_parts.append("⚜%d" % card.card_cost)
	if card.get("card_attack") != null and card.get("card_defense") != null:
		info_parts.append("⚔%d/%d" % [card.card_attack, card.card_defense])

	info_label.text = " ".join(info_parts)
	vbox.add_child(info_label)

	# Conectar señales (solo si es válida)
	if is_reorder_mode:
		display.gui_input.connect(_reorder.on_card_gui_input.bind(display, card))
	elif is_valid or selection_filter.is_empty():
		display.toggled.connect(_on_card_toggled.bind(card, display))

	return display


func _create_type_icon(card: Node) -> Control:
	"""Crea un ícono visual del tipo de carta (DAR Sección 1.D)

	Cada tipo de carta tiene un ícono distintivo para fácil identificación
	"""
	var container = HBoxContainer.new()
	container.alignment = BoxContainer.ALIGNMENT_CENTER

	var icon_label = Label.new()
	icon_label.add_theme_font_size_override("font_size", 14)

	var type_label = Label.new()
	type_label.add_theme_font_size_override("font_size", 10)

	var card_type = card.card_type if card.get("card_type") != null else -1

	# Asignar ícono y color según tipo (DAR Sección 1.D)
	match card_type:
		Constants.CardType.ALIADO:
			icon_label.text = "⚔"
			icon_label.modulate = Color(0.9, 0.7, 0.3, 1)  # Dorado
			type_label.text = "Aliado"
			type_label.modulate = Color(0.9, 0.7, 0.3, 1)

		Constants.CardType.TALISMAN:
			icon_label.text = "✦"
			icon_label.modulate = Color(0.5, 0.7, 1.0, 1)  # Azul
			type_label.text = "Talismán"
			type_label.modulate = Color(0.5, 0.7, 1.0, 1)

		Constants.CardType.TOTEM:
			icon_label.text = "◆"
			icon_label.modulate = Color(0.6, 0.9, 0.5, 1)  # Verde
			type_label.text = "Tótem"
			type_label.modulate = Color(0.6, 0.9, 0.5, 1)

		Constants.CardType.ARMA:
			icon_label.text = "⚔"
			icon_label.modulate = Color(0.8, 0.8, 0.8, 1)  # Gris metálico
			type_label.text = "Arma"
			type_label.modulate = Color(0.8, 0.8, 0.8, 1)

		Constants.CardType.ORO:
			icon_label.text = "●"
			icon_label.modulate = Color(1.0, 0.85, 0.0, 1)  # Oro brillante
			type_label.text = "Oro"
			type_label.modulate = Color(1.0, 0.85, 0.0, 1)

		_:
			icon_label.text = "?"
			icon_label.modulate = Color(0.5, 0.5, 0.5, 1)
			type_label.text = "Desconocido"
			type_label.modulate = Color(0.5, 0.5, 0.5, 1)

	container.add_child(icon_label)
	container.add_child(type_label)

	return container


func _create_card_style(selected: bool, hover: bool = false) -> StyleBoxFlat:
	"""Crea estilo visual para carta"""
	var style = StyleBoxFlat.new()

	if selected:
		style.bg_color = Color(0.2, 0.6, 0.9, 0.9)  # Azul seleccionado
		style.border_color = Color(1, 1, 0, 1)  # Borde amarillo
		style.border_width_bottom = 3
		style.border_width_top = 3
		style.border_width_left = 3
		style.border_width_right = 3
	elif hover:
		style.bg_color = Color(0.3, 0.3, 0.4, 0.8)
		style.border_color = Color(0.7, 0.7, 0.8, 1)
		style.border_width_bottom = 2
		style.border_width_top = 2
		style.border_width_left = 2
		style.border_width_right = 2
	else:
		style.bg_color = Color(0.2, 0.2, 0.3, 0.8)
		style.border_color = Color(0.5, 0.5, 0.6, 1)
		style.border_width_bottom = 1
		style.border_width_top = 1
		style.border_width_left = 1
		style.border_width_right = 1

	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8

	return style


func _create_invalid_card_style() -> StyleBoxFlat:
	"""Crea estilo visual para carta que NO cumple el filtro"""
	var style = StyleBoxFlat.new()

	style.bg_color = Color(0.15, 0.15, 0.15, 0.6)  # Gris oscuro
	style.border_color = Color(0.5, 0.2, 0.2, 0.8)  # Borde rojo apagado
	style.border_width_bottom = 2
	style.border_width_top = 2
	style.border_width_left = 2
	style.border_width_right = 2

	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8

	return style


# =============================================================================
# MANEJO DE SELECCIÓN
# =============================================================================
func _on_card_toggled(toggled: bool, card: Node, display: Button) -> void:
	"""Maneja toggle de carta (selección/deselección)"""
	if toggled:
		# VALIDACIÓN: Verificar que la carta cumple el filtro
		if not selection_filter.is_empty() and not _filter_validator.card_passes_filter(card, selection_filter):
			display.set_pressed_no_signal(false)
			_filter_validator.show_validation_error(card)
			return

		# Verificar límite
		if selected_cards.size() >= max_to_select:
			# Deseleccionar la más antigua si hay límite
			if max_to_select == 1 and selected_cards.size() == 1:
				var old_card = selected_cards[0]
				selected_cards.clear()
				_update_card_display_state(old_card, false)

			elif selected_cards.size() >= max_to_select:
				display.set_pressed_no_signal(false)
				return

		selected_cards.append(card)
		emit_signal("card_selected", card)
		validation_error = ""  # Limpiar error al seleccionar válida
		print("[SelectionCanvas] Carta seleccionada: %s" % (card.card_name if card.get("card_name") else "?"))

	else:
		selected_cards.erase(card)
		emit_signal("card_deselected", card)
		print("[SelectionCanvas] Carta deseleccionada")

	_update_counter()
	_update_confirm_button()
	_filter_validator.update_validation_display()


func _update_card_display_state(card: Node, selected: bool) -> void:
	"""Actualiza el estado visual de una carta"""
	if not cards_container:
		return

	for child in cards_container.get_children():
		if child.get_meta("card", null) == card:
			if child is Button:
				child.set_pressed_no_signal(selected)
			break


func _update_counter() -> void:
	"""Actualiza el contador de selección"""
	if counter_label:
		var valid_count = valid_cards.size() if not selection_filter.is_empty() else available_cards.size()
		counter_label.text = "%d / %d seleccionadas (%d válidas)" % [
			selected_cards.size(), amount_to_select, valid_count
		]


func _update_confirm_button() -> void:
	"""Actualiza estado del botón confirmar
	Solo permite confirmar si todas las cartas seleccionadas cumplen el filtro
	"""
	if confirm_button:
		var can_confirm = selected_cards.size() >= min_to_select

		# En modo reorder, siempre se puede confirmar
		if is_reorder_mode:
			can_confirm = true

		# VALIDACIÓN: Verificar que TODAS las seleccionadas cumplen el filtro
		if can_confirm and not selection_filter.is_empty():
			can_confirm = _filter_validator.all_selected_pass_filter()

		confirm_button.disabled = not can_confirm

		# Actualizar tooltip con razón si está deshabilitado
		if not can_confirm and not validation_error.is_empty():
			confirm_button.tooltip_text = validation_error
		else:
			confirm_button.tooltip_text = ""


# =============================================================================
# BOTONES
# =============================================================================
func _on_confirm_pressed() -> void:
	"""Confirma la selección"""
	print("[SelectionCanvas] Selección confirmada: %d cartas" % selected_cards.size())

	selection_complete = true
	is_active = false

	emit_signal("selection_confirmed", selected_cards.duplicate())


func _on_cancel_pressed() -> void:
	"""Cancela la selección"""
	print("[SelectionCanvas] Selección cancelada")

	selection_complete = false
	is_active = false
	selected_cards.clear()

	emit_signal("selection_cancelled")


func _on_fail_pressed() -> void:
	"""Elige "no encontrar" (solo en zonas privadas)"""
	if not can_fail:
		return

	print("[SelectionCanvas] Jugador eligió no encontrar")

	selection_complete = true  # Es una acción válida
	is_active = false
	selected_cards.clear()

	emit_signal("selection_failed")


func is_selection_active() -> bool:
	"""Verifica si hay una selección activa"""
	return is_active


func get_selected_cards() -> Array:
	"""Retorna las cartas actualmente seleccionadas"""
	return selected_cards.duplicate()


func get_card_order() -> Array:
	"""Retorna el orden actual de cartas (modo reordenar)"""
	return card_order.duplicate()


func force_close() -> void:
	"""Fuerza el cierre de la selección"""
	selection_complete = false
	is_active = false
	_close_selection()
	emit_signal("selection_cancelled")


func _close_selection() -> void:
	"""Cierra y limpia la UI de selección"""
	visible = false
	is_active = false

	# Limpiar contenedor
	if cards_container:
		for child in cards_container.get_children():
			child.queue_free()

	available_cards.clear()
	# No limpiar selected_cards aquí, se usa en el resultado


# =============================================================================
# API PÚBLICA (implementación en CardFilterValidator/SelectionReorder/SelectionReveal)
# =============================================================================
func get_filter_description() -> String:
	return _filter_validator.get_filter_description()


func move_card_up(card: Node) -> void:
	_reorder.move_card_up(card)


func move_card_down(card: Node) -> void:
	_reorder.move_card_down(card)


func move_card_to_top(card: Node) -> void:
	_reorder.move_card_to_top(card)


func move_card_to_bottom(card: Node) -> void:
	_reorder.move_card_to_bottom(card)


func show_cards_to_opponent(cards: Array, player: int, context: String = "mostrar") -> void:
	"""Función pública para mostrar cartas al oponente desde otros scripts
	Uso: await selection_canvas.show_cards_to_opponent(cards, 0, "efecto")
	"""
	await _reveal.show_cards_to_opponent(cards, player, context)


func reveal_hand_cards(cards: Array, player: int) -> void:
	"""Revela cartas de la mano al oponente (para efectos de "revelar mano")"""
	await _reveal.reveal_hand_cards(cards, player)


func reveal_deck_top(cards: Array, player: int, keep_order: bool = true) -> void:
	"""Revela las cartas del tope del mazo al oponente
	Para efectos como "Revela las 3 primeras cartas de tu Castillo"
	"""
	await _reveal.reveal_deck_top(cards, player, keep_order)


# =============================================================================
# INTERFAZ SIMPLIFICADA PARA BÚSQUEDA (DAR Sección 8)
# =============================================================================
func await_selection(cards: Array, count: int, is_private: bool, filter: Dictionary = {}) -> Array:
	"""Interfaz simplificada para búsqueda de cartas con await

	DAR Sección 8: En zonas privadas (Castillo, Mano propia), el jugador puede
	elegir "no encontrar" incluso si hay cartas que coincidan.

	Args:
		cards: Array de cartas entre las que buscar
		count: Cantidad de cartas a seleccionar
		is_private: Si la zona es privada (habilita botón "Fallar búsqueda")
		filter: Filtro opcional de requisitos

	Returns: Array de cartas seleccionadas (vacío si falló/canceló)

	Ejemplo:
		var selected = await selection_canvas.await_selection(deck_cards, 1, true, {"card_type": Constants.CardType.ALIADO})
		if selected.is_empty():
			print("No se encontró o el jugador eligió no encontrar")
	"""
	var result = await open_selection(
		cards,
		count,
		is_private,  # can_fail = is_private
		SelectionMode.SEARCH,
		filter
	)

	if result.success and not result.failed:
		return result.selected

	return []


func await_discard_selection(cards: Array, count: int, can_select_less: bool = false) -> Array:
	"""Interfaz simplificada para descarte de cartas

	Args:
		cards: Cartas disponibles para descartar (normalmente la mano)
		count: Cantidad de cartas a descartar
		can_select_less: Si puede descartar menos de count (para "en medida de lo posible")

	Returns: Array de cartas seleccionadas para descartar
	"""
	var result = await open_selection(
		cards,
		count,
		can_select_less,
		SelectionMode.DISCARD
	)

	if result.success:
		return result.selected

	return []


func await_target_selection(targets: Array, count: int = 1, can_cancel: bool = true, filter: Dictionary = {}) -> Array:
	"""Interfaz simplificada para selección de objetivos

	Args:
		targets: Posibles objetivos (cartas en juego)
		count: Cantidad de objetivos a seleccionar
		can_cancel: Si puede cancelar sin seleccionar
		filter: Filtro de requisitos para objetivos válidos

	Returns: Array de objetivos seleccionados
	"""
	var result = await open_selection(
		targets,
		count,
		can_cancel,
		SelectionMode.TARGET,
		filter
	)

	if result.success and not result.cancelled:
		return result.selected

	return []


func await_look_and_reorder(cards: Array) -> Array:
	"""Interfaz simplificada para mirar y reordenar cartas

	DAR Sección 8 - Mirar: El jugador ve las cartas y puede reordenarlas.

	Args:
		cards: Cartas a mirar (ej: tope del Castillo)

	Returns: Array con las cartas en el nuevo orden (índice 0 = tope)
	"""
	var result = await open_selection(
		cards,
		cards.size(),
		false,
		SelectionMode.LOOK
	)

	if result.success and not result.new_order.is_empty():
		return result.new_order

	return cards  # Retornar orden original si no se reordenó


func await_show_to_opponent(cards: Array, reveal_context: String = "") -> void:
	"""Interfaz simplificada para mostrar cartas al oponente

	DAR Sección 8 - Mostrar: Las cartas son información pública.

	Args:
		cards: Cartas a mostrar
		reveal_context: Contexto de la revelación (para OpponentUI)
	"""
	await _reveal.await_show_to_opponent(cards, reveal_context)


# INTEGRACIÓN CON CardEffectSystem — eliminada (2026-08-17): connect_to_
# effect_system() no la llamaba nadie, y las señales a las que se conectaba
# (search_selection_required/look_reorder_required) eran parte del pipeline
# de CardEffectSystem.gd eliminado por ser código muerto (cero llamadores
# en todo el proyecto). El camino real de búsqueda/mirar es TriggerSystem →
# UniversalCardParser → ActionModule → SelectionManager.
