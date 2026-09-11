extends Node
## TargetSelector - Sistema de Selección de Objetivos para la Pila (DAR Sección 6/8)
##
## Gestiona la selección de objetivos válidos en la pila de efectos.
## Filtra por legalidad según las condiciones de la carta fuente.
##
## Ejemplo: "Hacer el Bien" solo puede anular cartas con Coste <= 3

# =============================================================================
# SEÑALES
# =============================================================================
signal selection_mode_entered(source_card: Dictionary, valid_targets: Array)
signal selection_mode_exited
signal target_selected(target_stack_id: int, source_card: Dictionary)
signal target_confirmed(target_stack_id: int, source_card: Dictionary)
signal target_cancelled

## Vinculación de efecto (Sección 8)
signal effect_linked(response_stack_id: int, target_stack_id: int, effect_type: int)
signal effect_executed(response_stack_id: int, target_stack_id: int, success: bool)

## Derecho de arrepentimiento (antes del Paso B)
signal selection_regret(source_card: Dictionary)  # Carta devuelta a mano
signal card_returned_to_hand(card_data: Dictionary, player_id: int)

# =============================================================================
# ENUMS
# =============================================================================
enum SelectionType {
	NONE,
	ANNUL,           # Anular - Evitar que carta se resuelva
	CANCEL,          # Cancelar - Evitar que habilidad se resuelva
	GENERIC_STACK,   # Objetivo genérico en la pila
	REDIRECT         # Redirigir objetivo de otro efecto
}

enum TargetFilter {
	ANY,             # Cualquier objetivo válido
	CARD_ONLY,       # Solo cartas (no habilidades)
	ABILITY_ONLY,    # Solo habilidades
	ALLY_CARD,       # Solo cartas de Aliado
	TALISMAN_CARD,   # Solo Talismanes
	BY_COST,         # Filtrar por coste
	BY_TYPE,         # Filtrar por tipo de carta
	BY_CONTROLLER,   # Filtrar por controlador
	BY_NAME          # Filtrar por nombre específico
}

# =============================================================================
# ESTADO DE SELECCIÓN
# =============================================================================
var _is_selecting: bool = false
var _selection_type: SelectionType = SelectionType.NONE
var _source_card: Dictionary = {}
var _valid_targets: Array[int] = []  # Stack IDs válidos
var _current_hover_id: int = -1
var _selected_target_id: int = -1

## Filtros activos para la selección actual
var _active_filters: Array[Dictionary] = []

## Módulos extraídos (Fase 4 de reestructuración)
var _linked_registry: LinkedEffectRegistry
var _regret: RegretSystem

# =============================================================================
# REFERENCIAS
# =============================================================================
var _stack_visualizer: Control = null

# =============================================================================
# CONFIGURACIÓN VISUAL
# =============================================================================
const VALID_TARGET_COLOR: Color = Color(0.2, 1.0, 0.4, 0.8)
const INVALID_TARGET_COLOR: Color = Color(0.5, 0.5, 0.5, 0.4)
const HOVER_COLOR: Color = Color(1.0, 1.0, 0.3, 1.0)
const SELECTED_COLOR: Color = Color(0.0, 0.8, 1.0, 1.0)

## Cursor personalizado para modo selección
var _selection_cursor: Resource = null
var _default_cursor: Resource = null


func _ready() -> void:
	_linked_registry = LinkedEffectRegistry.new()
	_linked_registry.setup(self)
	_regret = RegretSystem.new()
	_regret.setup(self)

	call_deferred("_get_references")
	print("[TargetSelector] Inicializado")


func _get_references() -> void:
	# (2026-08-28, "módulos gordos" punto 1): ActionPipeline es autoload
	# garantizado — se saca el cacheo redundante. GameManager se cacheaba
	# pero no se usaba en este archivo. StackVisualizer NO es autoload
	# (nodo opcional de escena), se mantiene su lookup.
	_stack_visualizer = get_node_or_null("/root/StackVisualizer")

	ActionPipeline.stack_object_resolving.connect(_linked_registry._on_stack_object_resolving)
	ActionPipeline.stack_object_resolved.connect(_linked_registry._on_stack_object_resolved)
	ActionPipeline.stack_object_removed.connect(_linked_registry._on_stack_object_removed)

	if _stack_visualizer:
		# Conectar señales del visualizador
		if _stack_visualizer.has_signal("annul_target_selected"):
			_stack_visualizer.annul_target_selected.connect(_on_visualizer_annul_selected)
		if _stack_visualizer.has_signal("cancel_target_selected"):
			_stack_visualizer.cancel_target_selected.connect(_on_visualizer_cancel_selected)
		if _stack_visualizer.has_signal("stack_item_hovered"):
			_stack_visualizer.stack_item_hovered.connect(_on_visualizer_item_hovered)


func _input(event: InputEvent) -> void:
	# ESC cancela la selección (con arrepentimiento si está disponible)
	if event.is_action_pressed("ui_cancel"):
		if _is_selecting:
			# Cancelar selección en curso (devuelve carta si aún no pagó)
			if _regret.can_regret():
				cancel_selection_with_regret()
			else:
				cancel_selection()
			get_viewport().set_input_as_handled()
			return

	if not _is_selecting:
		return

	# Click izquierdo confirma selección si hay hover válido
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _current_hover_id >= 0 and _current_hover_id in _valid_targets:
				confirm_selection(_current_hover_id)
				get_viewport().set_input_as_handled()

		# Click derecho también puede cancelar con arrepentimiento
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if _regret.can_regret():
				cancel_selection_with_regret()
			else:
				cancel_selection()
			get_viewport().set_input_as_handled()


# =============================================================================
# API PRINCIPAL - OBTENER OBJETIVOS LEGALES
# =============================================================================
func get_legal_targets(source_card: Dictionary) -> Array[Dictionary]:
	"""Retorna los objetos de la pila que son objetivos válidos para source_card

	Analiza las condiciones de la carta (coste, tipo, etc.) y filtra la pila.

	Args:
		source_card: Datos de la carta que busca objetivo

	Returns:
		Array de stack_objects que cumplen las condiciones
	"""
	var stack = ActionPipeline.get_stack()
	if stack.is_empty():
		return []

	# Determinar tipo de selección según la carta
	var selection_info = _analyze_source_card(source_card)
	var sel_type = selection_info.type
	var filters = selection_info.filters

	var legal_targets: Array[Dictionary] = []

	for stack_obj in stack:
		if _is_valid_target(stack_obj, sel_type, filters, source_card):
			legal_targets.append(stack_obj)

	print("[TargetSelector] Objetivos legales para '%s': %d de %d en pila" % [
		source_card.get("nombre", source_card.get("name", "???")),
		legal_targets.size(),
		stack.size()
	])

	return legal_targets


func get_legal_target_ids(source_card: Dictionary) -> Array[int]:
	"""Versión que retorna solo los IDs para eficiencia"""
	var targets = get_legal_targets(source_card)
	var ids: Array[int] = []
	for t in targets:
		ids.append(t.get("id", -1))
	return ids


# =============================================================================
# ANÁLISIS DE CARTA FUENTE
# =============================================================================
func _analyze_source_card(card_data: Dictionary) -> Dictionary:
	"""Analiza la carta para determinar tipo de selección y filtros

	Returns:
		{type: SelectionType, filters: Array[Dictionary]}
	"""
	var result = {
		"type": SelectionType.GENERIC_STACK,
		"filters": []
	}

	# Obtener tipo de carta y efecto
	var card_type = card_data.get("tipo", -1)
	var effect_text = str(card_data.get("habilidad", card_data.get("effect_text", ""))).to_lower()
	var card_name = str(card_data.get("nombre", card_data.get("name", ""))).to_lower()

	# ─────────────────────────────────────────────────────────────────────────
	# Detectar ANULAR (para cartas)
	# ─────────────────────────────────────────────────────────────────────────
	if _text_contains_annul(effect_text):
		result.type = SelectionType.ANNUL
		result.filters.append({"filter": TargetFilter.CARD_ONLY})

		# Buscar restricciones de coste
		var cost_limit = _extract_cost_limit(effect_text)
		if cost_limit >= 0:
			result.filters.append({
				"filter": TargetFilter.BY_COST,
				"operator": "<=",
				"value": cost_limit
			})

		# Buscar restricciones de tipo
		if "aliado" in effect_text:
			result.filters.append({"filter": TargetFilter.ALLY_CARD})
		elif "talismán" in effect_text or "talisman" in effect_text:
			result.filters.append({"filter": TargetFilter.TALISMAN_CARD})

	# ─────────────────────────────────────────────────────────────────────────
	# Detectar CANCELAR (para habilidades)
	# ─────────────────────────────────────────────────────────────────────────
	elif _text_contains_cancel(effect_text):
		result.type = SelectionType.CANCEL
		result.filters.append({"filter": TargetFilter.ABILITY_ONLY})

	# ─────────────────────────────────────────────────────────────────────────
	# Cartas específicas conocidas
	# ─────────────────────────────────────────────────────────────────────────
	result = _apply_known_card_rules(card_name, result)

	return result


func _text_contains_annul(text: String) -> bool:
	"""Detecta si el texto indica anulación"""
	var annul_keywords = ["anula", "anular", "anulado", "no se resuelve", "evita que"]
	for kw in annul_keywords:
		if kw in text:
			return true
	return false


func _text_contains_cancel(text: String) -> bool:
	"""Detecta si el texto indica cancelación"""
	var cancel_keywords = ["cancela", "cancelar", "cancelado", "interrumpe"]
	for kw in cancel_keywords:
		if kw in text:
			return true
	return false


func _extract_cost_limit(text: String) -> int:
	"""Extrae límite de coste del texto (ej: 'coste 3 o menos' -> 3)

	Patrones reconocidos:
	- 'coste X o menos'
	- 'coste menor a X'
	- 'coste igual o menor a X'
	- 'coste <= X'
	"""
	# Patrón: coste X o menos / coste de X o menos
	var regex = RegEx.new()
	regex.compile("coste(?:\\s+de)?\\s+(\\d+)\\s+o\\s+menos")
	var result = regex.search(text)
	if result:
		return int(result.get_string(1))

	# Patrón: coste menor a X / coste igual o menor a X
	regex.compile("coste\\s+(?:igual\\s+o\\s+)?menor\\s+(?:a|que)\\s+(\\d+)")
	result = regex.search(text)
	if result:
		return int(result.get_string(1)) - 1  # "menor a 4" = <= 3

	# Patrón: coste <= X
	regex.compile("coste\\s*<=\\s*(\\d+)")
	result = regex.search(text)
	if result:
		return int(result.get_string(1))

	return -1  # Sin límite de coste


func _apply_known_card_rules(card_name: String, current: Dictionary) -> Dictionary:
	"""Aplica reglas especiales para cartas conocidas"""

	# ─────────────────────────────────────────────────────────────────────────
	# HACER EL BIEN - Anula carta de coste 3 o menos
	# ─────────────────────────────────────────────────────────────────────────
	if "hacer el bien" in card_name:
		current.type = SelectionType.ANNUL
		current.filters = [
			{"filter": TargetFilter.CARD_ONLY},
			{"filter": TargetFilter.BY_COST, "operator": "<=", "value": 3}
		]

	# ─────────────────────────────────────────────────────────────────────────
	# ESCUDO DIVINO - Anula talismán
	# ─────────────────────────────────────────────────────────────────────────
	elif "escudo divino" in card_name:
		current.type = SelectionType.ANNUL
		current.filters = [
			{"filter": TargetFilter.CARD_ONLY},
			{"filter": TargetFilter.TALISMAN_CARD}
		]

	# ─────────────────────────────────────────────────────────────────────────
	# CONTRAATAQUE MÍSTICO - Cancela habilidad activada
	# ─────────────────────────────────────────────────────────────────────────
	elif "contraataque" in card_name or "contra ataque" in card_name:
		current.type = SelectionType.CANCEL
		current.filters = [
			{"filter": TargetFilter.ABILITY_ONLY}
		]

	return current


# =============================================================================
# VALIDACIÓN DE OBJETIVOS
# =============================================================================
func _is_valid_target(stack_obj: Dictionary, sel_type: SelectionType,
					   filters: Array, source_card: Dictionary) -> bool:
	"""Verifica si un objeto de la pila es un objetivo válido"""

	# No puede apuntarse a sí mismo (si la fuente está en la pila)
	var source_id = source_card.get("stack_id", source_card.get("id", -999))
	if stack_obj.get("id", -1) == source_id:
		return false

	# Debe estar activo en la pila (ON_STACK o STEP_D)
	var step = stack_obj.get("step", -1)
	if step not in [4, 5]:  # ON_STACK=4, STEP_D=5
		return false

	# No debe estar ya procesado
	if stack_obj.get("was_annulled", false):
		return false
	if stack_obj.get("was_cancelled", false):
		return false
	if stack_obj.get("was_fizzled", false):
		return false

	# Verificar tipo de selección
	var obj_type = stack_obj.get("type", -1)

	match sel_type:
		SelectionType.ANNUL:
			# Solo cartas pueden ser anuladas (type 0 o 3)
			if obj_type not in [0, 3]:  # CARD_PLAYED, RESPONSE_CARD
				return false

		SelectionType.CANCEL:
			# Solo habilidades pueden ser canceladas (type 1 o 2)
			if obj_type not in [1, 2]:  # TRIGGERED_ABILITY, ACTIVATED_ABILITY
				return false

	# Aplicar filtros adicionales
	for filter_data in filters:
		if not _apply_filter(stack_obj, filter_data, source_card):
			return false

	return true


func _apply_filter(stack_obj: Dictionary, filter_data: Dictionary,
				   source_card: Dictionary) -> bool:
	"""Aplica un filtro específico a un objeto de la pila"""

	var filter_type = filter_data.get("filter", TargetFilter.ANY)
	var card_data = stack_obj.get("card_data", {})

	match filter_type:
		TargetFilter.ANY:
			return true

		TargetFilter.CARD_ONLY:
			# Solo cartas (no habilidades sueltas)
			var obj_type = stack_obj.get("type", -1)
			return obj_type in [0, 3]  # CARD_PLAYED, RESPONSE_CARD

		TargetFilter.ABILITY_ONLY:
			# Solo habilidades
			var obj_type = stack_obj.get("type", -1)
			return obj_type in [1, 2]  # TRIGGERED, ACTIVATED

		TargetFilter.ALLY_CARD:
			# Solo cartas de tipo Aliado
			var tipo = card_data.get("tipo", -1)
			return tipo == Constants.CardType.ALIADO

		TargetFilter.TALISMAN_CARD:
			# Solo Talismanes
			var tipo = card_data.get("tipo", -1)
			return tipo == Constants.CardType.TALISMAN

		TargetFilter.BY_COST:
			# Filtrar por coste
			var cost = card_data.get("coste", 0)
			var operator = filter_data.get("operator", "<=")
			var value = filter_data.get("value", 0)

			match operator:
				"<=": return cost <= value
				"<": return cost < value
				">=": return cost >= value
				">": return cost > value
				"==", "=": return cost == value
				"!=": return cost != value
			return false

		TargetFilter.BY_TYPE:
			# Filtrar por tipo de carta específico
			var required_type = filter_data.get("card_type", -1)
			var actual_type = card_data.get("tipo", -1)
			return actual_type == required_type

		TargetFilter.BY_CONTROLLER:
			# Filtrar por controlador
			var context = stack_obj.get("context", {})
			var required_controller = filter_data.get("controller", -1)
			var actual_controller = context.get("controller_id", context.get("player_id", -1))

			if filter_data.get("opponent_only", false):
				var source_controller = source_card.get("controller_id", -1)
				return actual_controller != source_controller and actual_controller >= 0

			return actual_controller == required_controller

		TargetFilter.BY_NAME:
			# Filtrar por nombre específico
			var required_name = str(filter_data.get("name", "")).to_lower()
			var actual_name = str(card_data.get("nombre", card_data.get("name", ""))).to_lower()
			return required_name in actual_name

	return true


# =============================================================================
# MODO DE SELECCIÓN
# =============================================================================
func enter_selection_mode(source_card: Dictionary, selection_type: SelectionType = SelectionType.GENERIC_STACK) -> void:
	"""Entra en modo de selección de objetivo

	Cambia el cursor y resalta los objetivos válidos en el StackVisualizer.
	El jugador puede cancelar con ESC (derecho de arrepentimiento antes de Paso B).
	"""
	if _is_selecting:
		print("[TargetSelector] Ya estaba en modo selección, reiniciando...")
		exit_selection_mode()

	_source_card = source_card
	_selection_type = selection_type

	# Obtener objetivos válidos
	_valid_targets = get_legal_target_ids(source_card)

	if _valid_targets.is_empty():
		print("[TargetSelector] No hay objetivos válidos para seleccionar")
		emit_signal("selection_mode_exited")
		return

	_is_selecting = true
	_selected_target_id = -1
	_current_hover_id = -1

	# Habilitar arrepentimiento desde el inicio de la selección
	_regret._enable_regret(source_card)

	# Cambiar cursor
	_set_selection_cursor(true)

	# Notificar al visualizador para resaltar objetivos
	_update_visualizer_highlights()

	# Emitir señal con objetivos válidos
	var valid_objs = get_legal_targets(source_card)
	emit_signal("selection_mode_entered", source_card, valid_objs)

	print("[TargetSelector] ═══ MODO SELECCIÓN ACTIVADO ═══")
	print("[TargetSelector] Tipo: %s | Objetivos válidos: %d" % [
		SelectionType.keys()[selection_type],
		_valid_targets.size()
	])
	print("[TargetSelector] (ESC para cancelar - Derecho de Arrepentimiento)")


func exit_selection_mode() -> void:
	"""Sale del modo de selección

	Nota: No deshabilita arrepentimiento aquí porque el jugador aún puede
	arrepentirse hasta que empiece el Paso B (pago de costes).
	"""
	if not _is_selecting:
		return

	_is_selecting = false
	_source_card = {}
	_valid_targets.clear()
	_selected_target_id = -1
	_current_hover_id = -1
	_selection_type = SelectionType.NONE

	# Restaurar cursor
	_set_selection_cursor(false)

	# Limpiar resaltados del visualizador
	_clear_visualizer_highlights()

	emit_signal("selection_mode_exited")
	print("[TargetSelector] Modo selección desactivado")


func confirm_selection(stack_id: int) -> void:
	"""Confirma la selección del objetivo y crea la vinculación de efecto"""
	if not _is_selecting:
		return

	if stack_id not in _valid_targets:
		print("[TargetSelector] ERROR: Objetivo #%d no es válido" % stack_id)
		return

	_selected_target_id = stack_id

	# Guardar datos para vinculación (antes de limpiar estado)
	var source_card_copy = _source_card.duplicate(true)
	var selection_type_copy = _selection_type

	print("[TargetSelector] ✓ Objetivo confirmado: #%d" % stack_id)
	emit_signal("target_confirmed", stack_id, _source_card)

	# Habilitar arrepentimiento antes de Paso B
	_regret._enable_regret(source_card_copy)

	# Salir del modo selección (pero mantener datos para vinculación)
	exit_selection_mode()

	# La vinculación se completa cuando la carta de respuesta entre a la pila
	# El caller debe llamar a link_effect() después de añadir la carta a la pila


func cancel_selection() -> void:
	"""Cancela la selección actual"""
	print("[TargetSelector] Selección cancelada por usuario")
	emit_signal("target_cancelled")
	exit_selection_mode()


func cancel_selection_with_regret() -> void:
	"""Cancela la selección y devuelve la carta a la mano (Derecho de Arrepentimiento)

	Solo válido antes del Paso B (pago de costes).
	DAR Sección 6: El jugador puede arrepentirse antes de pagar.
	"""
	if not _regret.can_regret():
		print("[TargetSelector] No se puede ejercer arrepentimiento en este momento")
		return

	var regret_card = _regret.get_regret_card()
	if regret_card.is_empty():
		print("[TargetSelector] No hay carta para devolver")
		return

	var regret_player_id = _regret.get_regret_player_id()

	print("[TargetSelector] ═══ DERECHO DE ARREPENTIMIENTO ═══")
	print("[TargetSelector] Carta '%s' devuelta a mano del Jugador %d" % [
		regret_card.get("nombre", regret_card.get("name", "???")),
		regret_player_id + 1
	])

	# Devolver carta a la mano
	_regret._return_card_to_hand(regret_card, regret_player_id)

	# Emitir señales
	emit_signal("selection_regret", regret_card)
	emit_signal("card_returned_to_hand", regret_card, regret_player_id)
	emit_signal("target_cancelled")

	# Limpiar estado de arrepentimiento
	_regret._disable_regret()

	# Salir del modo selección
	exit_selection_mode()


# =============================================================================
# GESTIÓN DE CURSOR
# =============================================================================
func _set_selection_cursor(selecting: bool) -> void:
	"""Cambia el cursor del mouse para indicar modo selección"""
	if selecting:
		# Cursor de crosshair/target
		Input.set_default_cursor_shape(Input.CURSOR_CROSS)
	else:
		# Restaurar cursor normal
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)


# =============================================================================
# INTEGRACIÓN CON STACKVISUALIZER
# =============================================================================
func _update_visualizer_highlights() -> void:
	"""Actualiza los resaltados en el StackVisualizer"""
	if not _stack_visualizer:
		_stack_visualizer = get_node_or_null("/root/StackVisualizer")

	if not _stack_visualizer:
		return

	# Obtener todos los items del visualizador
	if _stack_visualizer.has_method("get_all_item_ids"):
		var all_ids = _stack_visualizer.get_all_item_ids()
		for stack_id in all_ids:
			var is_valid = stack_id in _valid_targets
			_highlight_visualizer_item(stack_id, is_valid)
	else:
		# Fallback: Resaltar solo los válidos
		for stack_id in _valid_targets:
			_highlight_visualizer_item(stack_id, true)


func _highlight_visualizer_item(stack_id: int, is_valid: bool) -> void:
	"""Resalta un item específico en el visualizador"""
	if not _stack_visualizer:
		return

	if _stack_visualizer.has_method("highlight_target"):
		var color = VALID_TARGET_COLOR if is_valid else INVALID_TARGET_COLOR
		_stack_visualizer.highlight_target(stack_id, color, is_valid)
	elif _stack_visualizer.has_method("_highlight_item"):
		# Fallback al método interno
		var items = _stack_visualizer.get("_stack_items")
		if items and items.has(stack_id):
			var item = items[stack_id]
			if is_instance_valid(item):
				_apply_highlight_style(item, is_valid)


func _apply_highlight_style(item: Control, is_valid: bool) -> void:
	"""Aplica estilo de resaltado a un item"""
	var style = item.get_theme_stylebox("panel") as StyleBoxFlat
	if not style:
		return

	if is_valid:
		# Objetivo válido: borde verde brillante + pulso
		style.border_color = VALID_TARGET_COLOR
		style.border_width_left = 4
		style.border_width_right = 4
		style.border_width_top = 4
		style.border_width_bottom = 4

		# Animación de pulso
		var tween = item.create_tween()
		tween.set_loops()
		tween.tween_property(item, "modulate", Color(1.2, 1.2, 1.0), 0.5)
		tween.tween_property(item, "modulate", Color.WHITE, 0.5)
	else:
		# Objetivo inválido: atenuado
		style.border_color = INVALID_TARGET_COLOR
		item.modulate = Color(0.6, 0.6, 0.6, 0.7)


func _clear_visualizer_highlights() -> void:
	"""Limpia todos los resaltados del visualizador"""
	if not _stack_visualizer:
		return

	if _stack_visualizer.has_method("clear_all_highlights"):
		_stack_visualizer.clear_all_highlights()
	elif _stack_visualizer.has_method("refresh"):
		_stack_visualizer.refresh()


func _on_visualizer_item_hovered(stack_id: int, is_hovered: bool) -> void:
	"""Callback cuando el mouse entra/sale de un item del visualizador"""
	if not _is_selecting:
		return

	if is_hovered:
		_current_hover_id = stack_id

		# Resaltar más si es válido
		if stack_id in _valid_targets:
			_highlight_visualizer_item(stack_id, true)
			if _stack_visualizer:
				var items = _stack_visualizer.get("_stack_items")
				if items and items.has(stack_id):
					var item = items[stack_id]
					if is_instance_valid(item):
						var style = item.get_theme_stylebox("panel") as StyleBoxFlat
						if style:
							style.border_color = HOVER_COLOR
	else:
		if _current_hover_id == stack_id:
			_current_hover_id = -1
		# Restaurar resaltado normal
		if stack_id in _valid_targets:
			_highlight_visualizer_item(stack_id, true)


func _on_visualizer_annul_selected(stack_id: int) -> void:
	"""Callback cuando se selecciona un objetivo para anular desde el visualizador"""
	if _is_selecting and _selection_type == SelectionType.ANNUL:
		if stack_id in _valid_targets:
			confirm_selection(stack_id)
		else:
			print("[TargetSelector] Objetivo #%d no es válido para anular" % stack_id)


func _on_visualizer_cancel_selected(stack_id: int) -> void:
	"""Callback cuando se selecciona un objetivo para cancelar desde el visualizador"""
	if _is_selecting and _selection_type == SelectionType.CANCEL:
		if stack_id in _valid_targets:
			confirm_selection(stack_id)
		else:
			print("[TargetSelector] Objetivo #%d no es válido para cancelar" % stack_id)


# =============================================================================
# API PÚBLICA
# =============================================================================
func is_selecting() -> bool:
	"""Retorna si está en modo selección"""
	return _is_selecting


func get_selection_type() -> SelectionType:
	"""Retorna el tipo de selección actual"""
	return _selection_type


func get_source_card() -> Dictionary:
	"""Retorna la carta fuente de la selección"""
	return _source_card


func get_valid_target_count() -> int:
	"""Retorna cantidad de objetivos válidos"""
	return _valid_targets.size()


func has_valid_targets() -> bool:
	"""Retorna si hay al menos un objetivo válido"""
	return not _valid_targets.is_empty()


func is_valid_target(stack_id: int) -> bool:
	"""Verifica si un stack_id es un objetivo válido actual"""
	return stack_id in _valid_targets


# =============================================================================
# UTILIDADES
# =============================================================================
func create_custom_filter(card_data: Dictionary, extra_filters: Array[Dictionary] = []) -> Array[Dictionary]:
	"""Crea un conjunto de filtros personalizados para una carta

	Útil para cartas con condiciones complejas no detectadas automáticamente.
	"""
	var base_info = _analyze_source_card(card_data)
	var filters: Array[Dictionary] = []

	# Añadir filtros base
	for f in base_info.filters:
		filters.append(f)

	# Añadir filtros extra
	for f in extra_filters:
		filters.append(f)

	return filters


func validate_target_manually(source_card: Dictionary, stack_obj: Dictionary,
							   custom_filters: Array[Dictionary] = []) -> bool:
	"""Valida manualmente si un objetivo es legal para una carta

	Útil para validaciones complejas fuera del flujo normal.
	"""
	var info = _analyze_source_card(source_card)
	var filters = info.filters

	# Combinar con filtros custom
	for f in custom_filters:
		filters.append(f)

	return _is_valid_target(stack_obj, info.type, filters, source_card)


# =============================================================================
# VINCULACIÓN DE EFECTO (implementación en LinkedEffectRegistry.gd)
# =============================================================================
func link_effect(response_stack_id: int, target_stack_id: int,
				  effect_type: SelectionType, source_card: Dictionary) -> bool:
	return _linked_registry.link_effect(response_stack_id, target_stack_id, effect_type, source_card)


func get_linked_effect(response_stack_id: int) -> LinkedEffect:
	return _linked_registry.get_linked_effect(response_stack_id)


func has_linked_effect(response_stack_id: int) -> bool:
	return _linked_registry.has_linked_effect(response_stack_id)


func execute_linked_effect(response_stack_id: int) -> bool:
	return await _linked_registry.execute_linked_effect(response_stack_id)


func remove_linked_effect(response_stack_id: int) -> void:
	_linked_registry.remove_linked_effect(response_stack_id)


func clear_all_linked_effects() -> void:
	_linked_registry.clear_all_linked_effects()


# =============================================================================
# DERECHO DE ARREPENTIMIENTO (implementación en RegretSystem.gd)
# =============================================================================
func can_regret() -> bool:
	return _regret.can_regret()


func get_regret_card() -> Dictionary:
	return _regret.get_regret_card()


func notify_step_b_started() -> void:
	_regret.notify_step_b_started()


# =============================================================================
# CONVENIENCIA - Flujo completo de selección y vinculación
# =============================================================================
func begin_response_targeting(response_card: Dictionary, effect_type: SelectionType) -> void:
	"""Inicia el flujo completo de selección de objetivo para una carta de respuesta

	1. Entra en modo selección
	2. El jugador selecciona objetivo
	3. Al confirmar, se habilita arrepentimiento
	4. Cuando la carta entre a la pila, llamar a complete_response_targeting()
	"""
	enter_selection_mode(response_card, effect_type)


func complete_response_targeting(response_stack_id: int, target_stack_id: int) -> bool:
	"""Completa el flujo vinculando el efecto después de que la carta entró a la pila

	Args:
		response_stack_id: ID asignado a la carta de respuesta en la pila
		target_stack_id: ID del objetivo seleccionado

	Returns:
		true si la vinculación fue exitosa
	"""
	# Deshabilitar arrepentimiento (ya se pagó el coste)
	_regret._disable_regret()

	# Determinar tipo de efecto
	var effect_type = SelectionType.ANNUL
	var target_obj = ActionPipeline.get_object_by_id(target_stack_id)
	var obj_type = target_obj.get("type", 0)
	# Si el objetivo es una habilidad, es CANCEL
	if obj_type in [1, 2]:  # TRIGGERED_ABILITY, ACTIVATED_ABILITY
		effect_type = SelectionType.CANCEL

	# Obtener datos de la carta de respuesta
	var response_obj = ActionPipeline.get_object_by_id(response_stack_id)

	var source_card = response_obj.get("card_data", {})

	return _linked_registry.link_effect(response_stack_id, target_stack_id, effect_type, source_card)
