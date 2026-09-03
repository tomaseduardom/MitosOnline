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
	valid_cards = _get_valid_cards(cards, filter)

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
			_reveal_to_opponent(selected_cards)

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
	var filter_desc = get_filter_description()
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
		_update_validation_display()


func _create_card_display(card: Node) -> Control:
	"""Crea un control visual para una carta en la selección

	DAR Sección 1.D: Muestra íconos de tipo para validación visual
	"""
	# Verificar si la carta es válida según el filtro
	var is_valid = _card_passes_filter(card, selection_filter)

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
		display.gui_input.connect(_on_card_gui_input.bind(display, card))
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


func _matches_required_type(card: Node) -> bool:
	"""Verifica si la carta coincide con el tipo requerido por el filtro

	DAR Sección 1.D: Solo cartas del tipo correcto pueden ser seleccionadas
	"""
	if not selection_filter.has("card_type"):
		return true  # Sin filtro de tipo, todas coinciden

	var required_type = selection_filter.card_type
	var card_type = card.card_type if card.get("card_type") != null else -1

	return card_type == required_type


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
		if not selection_filter.is_empty() and not _card_passes_filter(card, selection_filter):
			display.set_pressed_no_signal(false)
			_show_validation_error(card)
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
	_update_validation_display()


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
			can_confirm = _all_selected_pass_filter()

		confirm_button.disabled = not can_confirm

		# Actualizar tooltip con razón si está deshabilitado
		if not can_confirm and not validation_error.is_empty():
			confirm_button.tooltip_text = validation_error
		else:
			confirm_button.tooltip_text = ""


# =============================================================================
# VALIDACIÓN DE REQUISITOS DE FILTRO
# =============================================================================
func _get_valid_cards(cards: Array, filter: Dictionary) -> Array:
	"""Retorna solo las cartas que cumplen el filtro"""
	if filter.is_empty():
		return cards.duplicate()

	var valid: Array = []
	for card in cards:
		if _card_passes_filter(card, filter):
			valid.append(card)

	return valid


func _card_passes_filter(card: Node, filter: Dictionary) -> bool:
	"""Verifica si una carta cumple todos los requisitos del filtro

	Filtros soportados:
	- card_type: int (Constants.CardType)
	- card_race: String
	- card_class: String
	- max_cost: int
	- min_cost: int
	- cost: int (exacto)
	- min_attack: int
	- max_attack: int
	- min_defense: int
	- max_defense: int
	- has_keyword: String o Array[String]
	- name_contains: String
	- in_zone: int (Constants.Zone)
	- controller: int (player_id)
	- custom: Callable(card) -> bool
	"""
	if filter.is_empty():
		return true

	# Tipo de carta (ej: solo Aliados)
	if filter.has("card_type"):
		var ct = card.card_type if card.get("card_type") != null else -1
		if ct != filter.card_type:
			return false

	# Raza (ej: solo Humanos)
	if filter.has("card_race"):
		var race = card.card_race if card.get("card_race") != null else ""
		if race.to_lower() != filter.card_race.to_lower():
			return false

	# Clase (ej: solo Guerreros)
	if filter.has("card_class"):
		var cls = card.card_class if card.get("card_class") != null else ""
		if cls.to_lower() != filter.card_class.to_lower():
			return false

	# Coste máximo
	if filter.has("max_cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost > filter.max_cost:
			return false

	# Coste mínimo
	if filter.has("min_cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost < filter.min_cost:
			return false

	# Coste exacto
	if filter.has("cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost != filter.cost:
			return false

	# Ataque mínimo
	if filter.has("min_attack"):
		var atk = card.card_attack if card.get("card_attack") != null else 0
		if atk < filter.min_attack:
			return false

	# Ataque máximo
	if filter.has("max_attack"):
		var atk = card.card_attack if card.get("card_attack") != null else 0
		if atk > filter.max_attack:
			return false

	# Defensa mínima
	if filter.has("min_defense"):
		var def = card.card_defense if card.get("card_defense") != null else 0
		if def < filter.min_defense:
			return false

	# Defensa máxima
	if filter.has("max_defense"):
		var def = card.card_defense if card.get("card_defense") != null else 0
		if def > filter.max_defense:
			return false

	# Tiene keyword específica
	if filter.has("has_keyword"):
		var required_keywords = filter.has_keyword
		if required_keywords is String:
			required_keywords = [required_keywords]

		var has_all = true
		for kw in required_keywords:
			if card.has_method("has_keyword"):
				if not card.has_keyword(kw):
					has_all = false
					break
			elif card.get("keywords"):
				if kw not in card.keywords:
					has_all = false
					break
			else:
				has_all = false
				break

		if not has_all:
			return false

	# Nombre contiene texto
	if filter.has("name_contains"):
		var card_name = card.card_name if card.get("card_name") else ""
		if filter.name_contains.to_lower() not in card_name.to_lower():
			return false

	# Está en zona específica
	if filter.has("in_zone"):
		var zone = card.current_zone if card.get("current_zone") != null else -1
		if zone != filter.in_zone:
			return false

	# Controlada por jugador específico
	if filter.has("controller"):
		var ctrl = card.controller_id if card.get("controller_id") != null else -1
		if ctrl != filter.controller:
			return false

	# Filtro personalizado (Callable)
	if filter.has("custom"):
		var custom_fn: Callable = filter.custom
		if custom_fn.is_valid():
			if not custom_fn.call(card):
				return false

	return true


func _all_selected_pass_filter() -> bool:
	"""Verifica que todas las cartas seleccionadas cumplan el filtro"""
	if selection_filter.is_empty():
		return true

	for card in selected_cards:
		if not _card_passes_filter(card, selection_filter):
			return false

	return true


func _show_validation_error(card: Node) -> void:
	"""Muestra mensaje de error cuando una carta no cumple el filtro"""
	var card_name = card.card_name if card.get("card_name") else "Esta carta"
	validation_error = _generate_filter_error_message(card)

	print("[SelectionCanvas] Validación fallida: %s" % validation_error)

	# Mostrar en UI si hay label de instrucciones
	if instruction_label:
		instruction_label.text = validation_error
		instruction_label.modulate = Color(1, 0.5, 0.5, 1)  # Rojo suave

		# Restaurar después de un tiempo
		await get_tree().create_timer(2.0).timeout
		if instruction_label:
			instruction_label.modulate = Color(1, 1, 1, 1)
			_setup_ui_for_mode(current_mode, amount_to_select)


func _generate_filter_error_message(card: Node) -> String:
	"""Genera mensaje descriptivo de por qué la carta no cumple el filtro"""
	var reasons: Array = []

	if selection_filter.has("card_type"):
		var required_type = Constants.CARD_TYPE_NAMES.get(selection_filter.card_type, "tipo requerido")
		var actual_type = Constants.CARD_TYPE_NAMES.get(card.card_type, "desconocido") if card.get("card_type") != null else "desconocido"
		if card.get("card_type") != selection_filter.card_type:
			reasons.append("Debe ser %s (es %s)" % [required_type, actual_type])

	if selection_filter.has("card_race"):
		var actual_race = card.card_race if card.get("card_race") else "ninguna"
		if actual_race.to_lower() != selection_filter.card_race.to_lower():
			reasons.append("Debe ser raza %s" % selection_filter.card_race)

	if selection_filter.has("max_cost"):
		var cost = card.card_cost if card.get("card_cost") != null else 0
		if cost > selection_filter.max_cost:
			reasons.append("Coste máximo %d (tiene %d)" % [selection_filter.max_cost, cost])

	if selection_filter.has("min_attack"):
		var atk = card.card_attack if card.get("card_attack") != null else 0
		if atk < selection_filter.min_attack:
			reasons.append("Ataque mínimo %d" % selection_filter.min_attack)

	if reasons.is_empty():
		return "Esta carta no cumple los requisitos"

	return "No válida: " + ", ".join(reasons)


func _update_validation_display() -> void:
	"""Actualiza la visualización de validación en las cartas"""
	if not cards_container:
		return

	for child in cards_container.get_children():
		var card = child.get_meta("card", null)
		if not card:
			continue

		var is_valid = _card_passes_filter(card, selection_filter)

		# Actualizar apariencia según validez
		if child is Button:
			if not is_valid and not selection_filter.is_empty():
				# Carta inválida - atenuar
				child.modulate = Color(0.5, 0.5, 0.5, 0.7)
				child.disabled = true
				child.mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN
			else:
				# Carta válida
				child.modulate = Color(1, 1, 1, 1)
				child.disabled = false
				child.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func get_filter_description() -> String:
	"""Genera descripción legible del filtro actual"""
	if selection_filter.is_empty():
		return "Cualquier carta"

	var parts: Array = []

	if selection_filter.has("card_type"):
		parts.append(Constants.CARD_TYPE_NAMES.get(selection_filter.card_type, ""))

	if selection_filter.has("card_race"):
		parts.append("raza " + selection_filter.card_race)

	if selection_filter.has("max_cost"):
		parts.append("coste ≤%d" % selection_filter.max_cost)

	if selection_filter.has("min_attack"):
		parts.append("ataque ≥%d" % selection_filter.min_attack)

	if selection_filter.has("has_keyword"):
		var kws = selection_filter.has_keyword
		if kws is String:
			parts.append("con " + kws)
		else:
			parts.append("con " + ", ".join(kws))

	if parts.is_empty():
		return "Carta específica"

	return " ".join(parts)


# =============================================================================
# MANEJO DE REORDENAMIENTO (DRAG & DROP + BOTONES)
# =============================================================================
var dragging_card: Control = null
var drag_start_index: int = -1
var drag_offset: Vector2 = Vector2.ZERO
var selected_for_reorder: int = -1  # Índice de carta seleccionada para mover


func _on_card_gui_input(event: InputEvent, display: Control, card: Node) -> void:
	"""Maneja input para drag & drop en modo reordenar"""
	if not is_reorder_mode:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Iniciar drag
				dragging_card = display
				drag_start_index = card_order.find(card)
				drag_offset = display.global_position - event.global_position
				display.z_index = 100

				# Marcar visualmente
				_highlight_card_for_reorder(drag_start_index)

			else:
				# Soltar
				if dragging_card:
					_finalize_drag()

	elif event is InputEventMouseMotion and dragging_card:
		# Mover visualmente mientras arrastra
		dragging_card.global_position = event.global_position + drag_offset

		# Calcular nueva posición basada en posición del mouse
		var container_pos = cards_container.get_local_mouse_position()
		var card_width = 130  # Ancho aproximado de carta + separación
		var new_index = int(container_pos.x / card_width)
		new_index = clampi(new_index, 0, card_order.size() - 1)

		# Mostrar indicador de posición
		_show_drop_indicator(new_index)

		if new_index != drag_start_index:
			# Reordenar en el array
			var card_to_move = card_order[drag_start_index]
			card_order.remove_at(drag_start_index)
			card_order.insert(new_index, card_to_move)
			drag_start_index = new_index


func _finalize_drag() -> void:
	"""Finaliza el drag y actualiza posiciones"""
	if dragging_card:
		dragging_card.z_index = 0
		dragging_card = null

	drag_start_index = -1
	_hide_drop_indicator()
	_reorder_card_displays()
	_update_position_labels()


func _highlight_card_for_reorder(index: int) -> void:
	"""Resalta una carta seleccionada para reordenar"""
	selected_for_reorder = index

	if not cards_container:
		return

	for i in range(cards_container.get_child_count()):
		var child = cards_container.get_child(i)
		if child is Button:
			if i == index:
				child.modulate = Color(1.2, 1.2, 0.8, 1)  # Amarillo suave
			else:
				child.modulate = Color(1, 1, 1, 1)


func _show_drop_indicator(index: int) -> void:
	"""Muestra indicador visual de dónde se soltará la carta"""
	# TODO: Implementar indicador visual (línea o espacio)
	pass


func _hide_drop_indicator() -> void:
	"""Oculta el indicador de drop"""
	pass


func _reorder_card_displays() -> void:
	"""Reordena los displays de cartas según card_order"""
	if not cards_container:
		return

	for i in range(card_order.size()):
		var card = card_order[i]
		for child in cards_container.get_children():
			if child.get_meta("card", null) == card:
				cards_container.move_child(child, i)
				# Resetear posición (por si fue arrastrada)
				child.position = Vector2.ZERO
				break


func _update_position_labels() -> void:
	"""Actualiza etiquetas de posición (1=tope, N=fondo)"""
	if not cards_container:
		return

	for i in range(cards_container.get_child_count()):
		var child = cards_container.get_child(i)
		var pos_label = child.get_node_or_null("PositionLabel")
		if pos_label:
			if i == 0:
				pos_label.text = "TOPE"
			elif i == card_order.size() - 1:
				pos_label.text = "FONDO"
			else:
				pos_label.text = str(i + 1)


# --- Botones de reordenamiento (alternativa a drag & drop) ---
func move_card_up(card: Node) -> void:
	"""Mueve una carta hacia arriba (hacia el tope)"""
	var index = card_order.find(card)
	if index > 0:
		card_order.remove_at(index)
		card_order.insert(index - 1, card)
		_reorder_card_displays()
		_update_position_labels()
		print("[SelectionCanvas] Carta movida al índice %d" % (index - 1))


func move_card_down(card: Node) -> void:
	"""Mueve una carta hacia abajo (hacia el fondo)"""
	var index = card_order.find(card)
	if index < card_order.size() - 1:
		card_order.remove_at(index)
		card_order.insert(index + 1, card)
		_reorder_card_displays()
		_update_position_labels()
		print("[SelectionCanvas] Carta movida al índice %d" % (index + 1))


func move_card_to_top(card: Node) -> void:
	"""Mueve una carta al tope del mazo"""
	var index = card_order.find(card)
	if index > 0:
		card_order.remove_at(index)
		card_order.insert(0, card)
		_reorder_card_displays()
		_update_position_labels()
		print("[SelectionCanvas] Carta movida al TOPE")


func move_card_to_bottom(card: Node) -> void:
	"""Mueve una carta al fondo del mazo"""
	var index = card_order.find(card)
	if index < card_order.size() - 1:
		card_order.remove_at(index)
		card_order.append(card)
		_reorder_card_displays()
		_update_position_labels()
		print("[SelectionCanvas] Carta movida al FONDO")


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


# =============================================================================
# LÓGICA DE MOSTRAR (PUBLIC INFO) - DAR Sección 8
# =============================================================================
func _reveal_to_opponent(cards: Array) -> void:
	"""Revela las cartas seleccionadas al oponente
	Emite señales para que OpponentUI las muestre
	"""
	var opponent_id = 1 - player_id
	var context = _get_reveal_context()

	print("[SelectionCanvas] Revelando %d cartas al oponente (contexto: %s)" % [cards.size(), context])

	# Preparar datos de revelación
	var reveal_data = {
		"player_id": player_id,
		"opponent_id": opponent_id,
		"cards": cards,
		"context": context,
		"card_names": [],
		"timestamp": Time.get_ticks_msec()
	}

	for card in cards:
		reveal_data.card_names.append(card.card_name if card.get("card_name") else "Carta")

	# Emitir señal global para OpponentUI
	emit_signal("cards_revealed_to_opponent", player_id, cards, context)

	# Notificar a GameManager para logging/historial
	if GameManager and GameManager.has_method("log_card_reveal"):
		GameManager.log_card_reveal(reveal_data)

	# Revelar cada carta con pausa dramática
	for i in range(cards.size()):
		var card = cards[i]

		# Emitir señal individual
		emit_signal("card_shown_to_opponent", player_id, card)

		# Llamar al OpponentUI directamente si existe
		var opponent_ui = _get_opponent_ui()
		if opponent_ui and opponent_ui.has_method("show_revealed_card"):
			opponent_ui.show_revealed_card(card, context, i, cards.size())

		# Pausa dramática entre revelaciones
		await get_tree().create_timer(0.4).timeout

	# Mantener cartas visibles un momento
	await get_tree().create_timer(1.0).timeout

	emit_signal("reveal_ended", player_id)

	# Notificar fin de revelación al OpponentUI
	var opponent_ui = _get_opponent_ui()
	if opponent_ui and opponent_ui.has_method("hide_revealed_cards"):
		opponent_ui.hide_revealed_cards()


func _get_opponent_ui() -> Node:
	"""Obtiene referencia al OpponentUI"""
	# Intentar obtener desde el árbol de escena
	var ui = get_tree().get_first_node_in_group("opponent_ui")
	if ui:
		return ui

	# Intentar ruta conocida
	return get_node_or_null("/root/Main/OpponentUI")


func _get_reveal_context() -> String:
	"""Genera contexto para la revelación"""
	match current_mode:
		SelectionMode.SHOW:
			return "mostrar_efecto"
		SelectionMode.SEARCH:
			return "buscar_resultado"
		SelectionMode.DISCARD:
			return "descarte"
		_:
			return "revelado"


# =============================================================================
# FUNCIONES PÚBLICAS PARA MOSTRAR
# =============================================================================
func show_cards_to_opponent(cards: Array, player: int, context: String = "mostrar") -> void:
	"""Función pública para mostrar cartas al oponente desde otros scripts
	Uso: await selection_canvas.show_cards_to_opponent(cards, 0, "efecto")
	"""
	player_id = player
	await _reveal_to_opponent(cards)


func reveal_hand_cards(cards: Array, player: int) -> void:
	"""Revela cartas de la mano al oponente (para efectos de "revelar mano")"""
	player_id = player
	is_public = true

	emit_signal("cards_revealed_to_opponent", player, cards, "mano_revelada")

	var opponent_ui = _get_opponent_ui()
	if opponent_ui and opponent_ui.has_method("show_opponent_hand"):
		opponent_ui.show_opponent_hand(cards)

	# Las cartas de mano permanecen visibles hasta que el efecto termine
	await get_tree().create_timer(2.0).timeout

	emit_signal("reveal_ended", player)


func reveal_deck_top(cards: Array, player: int, keep_order: bool = true) -> void:
	"""Revela las cartas del tope del mazo al oponente
	Para efectos como "Revela las 3 primeras cartas de tu Castillo"
	"""
	player_id = player
	is_public = true

	var context = "tope_castillo"
	emit_signal("cards_revealed_to_opponent", player, cards, context)

	var opponent_ui = _get_opponent_ui()
	if opponent_ui and opponent_ui.has_method("show_deck_reveal"):
		opponent_ui.show_deck_reveal(cards, keep_order)

	# Revelar cada carta
	for card in cards:
		emit_signal("card_shown_to_opponent", player, card)
		await get_tree().create_timer(0.3).timeout

	await get_tree().create_timer(1.5).timeout
	emit_signal("reveal_ended", player)


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
	if reveal_context.is_empty():
		reveal_context = "mostrar_efecto"

	# No necesita selección del usuario, solo mostrar
	await _reveal_to_opponent(cards)


# INTEGRACIÓN CON CardEffectSystem — eliminada (2026-08-17): connect_to_
# effect_system() no la llamaba nadie, y las señales a las que se conectaba
# (search_selection_required/look_reorder_required) eran parte del pipeline
# de CardEffectSystem.gd eliminado por ser código muerto (cero llamadores
# en todo el proyecto). El camino real de búsqueda/mirar es TriggerSystem →
# UniversalCardParser → ActionModule → SelectionManager.
