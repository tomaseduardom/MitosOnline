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

# =============================================================================
# VINCULACIÓN DE EFECTO (Sección 8)
# =============================================================================
## Almacena las vinculaciones activas: {response_stack_id: LinkedEffect}
var _linked_effects: Dictionary = {}

## Estructura de efecto vinculado
class LinkedEffect:
	var response_stack_id: int = -1      # ID de la carta de respuesta en la pila
	var target_stack_id: int = -1        # ID del objetivo en la pila
	var effect_type: int = 0             # SelectionType (ANNUL/CANCEL)
	var source_card: Dictionary = {}     # Datos de la carta fuente
	var target_card: Dictionary = {}     # Datos del objetivo
	var created_at: int = 0              # Timestamp
	var is_pending: bool = true          # Aún no ejecutado

# =============================================================================
# ESTADO DE ARREPENTIMIENTO (antes de Paso B)
# =============================================================================
var _can_regret: bool = false           # Si el jugador puede arrepentirse
var _regret_card: Dictionary = {}       # Carta que se puede devolver
var _regret_player_id: int = -1         # Jugador que puede arrepentirse

# =============================================================================
# REFERENCIAS
# =============================================================================
var _action_pipeline: Node = null
var _stack_visualizer: Control = null
var _game_manager: Node = null

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
	call_deferred("_get_references")
	print("[TargetSelector] Inicializado")


func _get_references() -> void:
	_action_pipeline = get_node_or_null("/root/ActionPipeline")
	_stack_visualizer = get_node_or_null("/root/StackVisualizer")
	_game_manager = get_node_or_null("/root/GameManager")

	if _stack_visualizer:
		# Conectar señales del visualizador
		if _stack_visualizer.has_signal("annul_target_selected"):
			_stack_visualizer.annul_target_selected.connect(_on_visualizer_annul_selected)
		if _stack_visualizer.has_signal("cancel_target_selected"):
			_stack_visualizer.cancel_target_selected.connect(_on_visualizer_cancel_selected)
		if _stack_visualizer.has_signal("stack_item_hovered"):
			_stack_visualizer.stack_item_hovered.connect(_on_visualizer_item_hovered)

	if _action_pipeline:
		# Conectar para ejecutar efectos vinculados cuando se resuelven
		if _action_pipeline.has_signal("stack_object_resolving"):
			_action_pipeline.stack_object_resolving.connect(_on_stack_object_resolving)
		if _action_pipeline.has_signal("stack_object_resolved"):
			_action_pipeline.stack_object_resolved.connect(_on_stack_object_resolved)
		if _action_pipeline.has_signal("stack_object_removed"):
			_action_pipeline.stack_object_removed.connect(_on_stack_object_removed)


func _input(event: InputEvent) -> void:
	# ESC cancela la selección (con arrepentimiento si está disponible)
	if event.is_action_pressed("ui_cancel"):
		if _is_selecting:
			# Cancelar selección en curso (devuelve carta si aún no pagó)
			if _can_regret:
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
			if _can_regret:
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
	if not _action_pipeline:
		push_error("[TargetSelector] ActionPipeline no disponible")
		return []

	var stack = _action_pipeline.get_stack()
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
	_enable_regret(source_card)

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
	_enable_regret(source_card_copy)

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
	if not _can_regret:
		print("[TargetSelector] No se puede ejercer arrepentimiento en este momento")
		return

	if _regret_card.is_empty():
		print("[TargetSelector] No hay carta para devolver")
		return

	print("[TargetSelector] ═══ DERECHO DE ARREPENTIMIENTO ═══")
	print("[TargetSelector] Carta '%s' devuelta a mano del Jugador %d" % [
		_regret_card.get("nombre", _regret_card.get("name", "???")),
		_regret_player_id + 1
	])

	# Devolver carta a la mano
	_return_card_to_hand(_regret_card, _regret_player_id)

	# Emitir señales
	emit_signal("selection_regret", _regret_card)
	emit_signal("card_returned_to_hand", _regret_card, _regret_player_id)
	emit_signal("target_cancelled")

	# Limpiar estado de arrepentimiento
	_disable_regret()

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
# VINCULACIÓN DE EFECTO (Sección 8)
# =============================================================================
func link_effect(response_stack_id: int, target_stack_id: int,
				  effect_type: SelectionType, source_card: Dictionary) -> bool:
	"""Vincula una carta de respuesta con su objetivo en la pila

	Cuando la carta de respuesta se resuelva, ejecutará annul() o cancel()
	sobre el objetivo vinculado.

	Args:
		response_stack_id: ID de la carta de respuesta en la pila
		target_stack_id: ID del objetivo a afectar
		effect_type: ANNUL o CANCEL
		source_card: Datos de la carta de respuesta

	Returns:
		true si la vinculación fue exitosa
	"""
	if response_stack_id <= 0 or target_stack_id <= 0:
		push_error("[TargetSelector] IDs inválidos para vinculación")
		return false

	if effect_type not in [SelectionType.ANNUL, SelectionType.CANCEL]:
		push_error("[TargetSelector] Tipo de efecto inválido para vinculación")
		return false

	# Verificar que el objetivo existe y es válido
	if _action_pipeline:
		var target_obj = _action_pipeline.get_object_by_id(target_stack_id)
		if target_obj.is_empty():
			push_error("[TargetSelector] Objetivo #%d no encontrado en la pila" % target_stack_id)
			return false

		# Crear vinculación
		var link = LinkedEffect.new()
		link.response_stack_id = response_stack_id
		link.target_stack_id = target_stack_id
		link.effect_type = effect_type
		link.source_card = source_card.duplicate(true)
		link.target_card = target_obj.get("card_data", {}).duplicate(true)
		link.created_at = Time.get_ticks_msec()
		link.is_pending = true

		_linked_effects[response_stack_id] = link

		print("[TargetSelector] ═══ EFECTO VINCULADO ═══")
		print("[TargetSelector] Respuesta #%d → Objetivo #%d (%s)" % [
			response_stack_id,
			target_stack_id,
			"ANULAR" if effect_type == SelectionType.ANNUL else "CANCELAR"
		])

		emit_signal("effect_linked", response_stack_id, target_stack_id, effect_type)
		return true

	return false


func get_linked_effect(response_stack_id: int) -> LinkedEffect:
	"""Obtiene la vinculación de efecto para una carta de respuesta"""
	if _linked_effects.has(response_stack_id):
		return _linked_effects[response_stack_id]
	return null


func has_linked_effect(response_stack_id: int) -> bool:
	"""Verifica si una carta de respuesta tiene un efecto vinculado"""
	return _linked_effects.has(response_stack_id)


func execute_linked_effect(response_stack_id: int) -> bool:
	"""Ejecuta el efecto vinculado cuando la carta de respuesta se resuelve

	Llama a annul() o cancel() en el ActionPipeline sobre el objetivo.

	Returns:
		true si el efecto se ejecutó exitosamente
	"""
	if not _linked_effects.has(response_stack_id):
		print("[TargetSelector] No hay efecto vinculado para #%d" % response_stack_id)
		return false

	var link: LinkedEffect = _linked_effects[response_stack_id]

	if not link.is_pending:
		print("[TargetSelector] Efecto #%d ya fue ejecutado" % response_stack_id)
		return false

	if not _action_pipeline:
		push_error("[TargetSelector] ActionPipeline no disponible")
		return false

	var target_id = link.target_stack_id
	var success = false

	# Verificar que el objetivo sigue en la pila
	var target_obj = _action_pipeline.get_object_by_id(target_id)
	if target_obj.is_empty():
		print("[TargetSelector] Objetivo #%d ya no está en la pila (fizzle)" % target_id)
		link.is_pending = false
		emit_signal("effect_executed", response_stack_id, target_id, false)
		return false

	# Verificar que no fue ya procesado
	if target_obj.get("was_annulled", false) or target_obj.get("was_cancelled", false):
		print("[TargetSelector] Objetivo #%d ya fue anulado/cancelado" % target_id)
		link.is_pending = false
		emit_signal("effect_executed", response_stack_id, target_id, false)
		return false

	# Ejecutar según tipo
	match link.effect_type:
		SelectionType.ANNUL:
			success = _execute_annul(target_id, link.source_card)

		SelectionType.CANCEL:
			success = _execute_cancel(target_id, link.source_card)

	link.is_pending = false

	print("[TargetSelector] Efecto %s sobre #%d: %s" % [
		"ANULAR" if link.effect_type == SelectionType.ANNUL else "CANCELAR",
		target_id,
		"ÉXITO" if success else "FALLÓ"
	])

	emit_signal("effect_executed", response_stack_id, target_id, success)

	return success


func _execute_annul(target_stack_id: int, source_card: Dictionary) -> bool:
	"""Ejecuta ANULAR sobre un objetivo (Sección 8)

	La carta objetivo no se resuelve y va al Cementerio.
	"""
	if not _action_pipeline:
		return false

	# Llamar al ActionPipeline para marcar como anulado
	if _action_pipeline.has_method("apply_special_action"):
		_action_pipeline.apply_special_action({
			"type": "nullify",
			"target_stack_id": target_stack_id,
			"source_card": source_card
		})
		return true

	# Fallback: marcar directamente
	var target_obj = _action_pipeline.get_object_by_id(target_stack_id)
	if not target_obj.is_empty():
		target_obj.was_annulled = true
		target_obj.annuller = source_card
		if _action_pipeline.has_signal("object_annulled"):
			_action_pipeline.emit_signal("object_annulled", target_obj, source_card)
		return true

	return false


func _execute_cancel(target_stack_id: int, source_card: Dictionary) -> bool:
	"""Ejecuta CANCELAR sobre un objetivo (Sección 8)

	La habilidad objetivo no se resuelve.
	"""
	if not _action_pipeline:
		return false

	# Llamar al ActionPipeline
	if _action_pipeline.has_method("apply_special_action"):
		_action_pipeline.apply_special_action({
			"type": "cancel",
			"target_stack_id": target_stack_id,
			"source_card": source_card,
			"reason": "cancelled_by_effect"
		})
		return true

	# Fallback: marcar directamente
	var target_obj = _action_pipeline.get_object_by_id(target_stack_id)
	if not target_obj.is_empty():
		target_obj.was_cancelled = true
		target_obj.cancel_reason = "cancelled_by_%s" % source_card.get("nombre", "effect")
		if _action_pipeline.has_signal("object_cancelled"):
			_action_pipeline.emit_signal("object_cancelled", target_obj)
		return true

	return false


func remove_linked_effect(response_stack_id: int) -> void:
	"""Remueve una vinculación de efecto"""
	if _linked_effects.has(response_stack_id):
		_linked_effects.erase(response_stack_id)


func clear_all_linked_effects() -> void:
	"""Limpia todas las vinculaciones (para nuevo juego)"""
	_linked_effects.clear()


# =============================================================================
# CALLBACKS DE ACTIONPIPELINE - Ejecución automática de efectos vinculados
# =============================================================================
func _on_stack_object_resolving(stack_obj: Dictionary) -> void:
	"""Cuando un objeto comienza a resolver, ejecutar efecto vinculado si existe"""
	var stack_id = stack_obj.get("id", -1)

	# Si es una carta de respuesta con efecto vinculado, ejecutarlo
	if has_linked_effect(stack_id):
		print("[TargetSelector] Carta de respuesta #%d resolviendo - ejecutando efecto vinculado" % stack_id)
		execute_linked_effect(stack_id)


func _on_stack_object_resolved(stack_obj: Dictionary, _result: Dictionary) -> void:
	"""Cuando un objeto termina de resolver"""
	var stack_id = stack_obj.get("id", -1)

	# Limpiar vinculación usada
	remove_linked_effect(stack_id)


func _on_stack_object_removed(stack_obj: Dictionary, reason: String) -> void:
	"""Cuando un objeto es removido de la pila"""
	var stack_id = stack_obj.get("id", -1)

	# Si el objetivo de una vinculación fue removido, la vinculación hace fizzle
	for response_id in _linked_effects.keys():
		var link: LinkedEffect = _linked_effects[response_id]
		if link.target_stack_id == stack_id and link.is_pending:
			print("[TargetSelector] Objetivo #%d removido (%s) - vinculación #%d hace fizzle" % [
				stack_id, reason, response_id
			])
			link.is_pending = false

	# Limpiar vinculación si es la respuesta
	remove_linked_effect(stack_id)


# =============================================================================
# DERECHO DE ARREPENTIMIENTO (antes de Paso B)
# =============================================================================
func _enable_regret(card_data: Dictionary) -> void:
	"""Habilita el derecho de arrepentimiento para una carta"""
	_can_regret = true
	_regret_card = card_data.duplicate(true)
	_regret_player_id = card_data.get("controller_id", card_data.get("player_id", 0))

	print("[TargetSelector] Arrepentimiento habilitado para '%s'" %
		  card_data.get("nombre", card_data.get("name", "???")))


func _disable_regret() -> void:
	"""Deshabilita el derecho de arrepentimiento"""
	_can_regret = false
	_regret_card = {}
	_regret_player_id = -1


func can_regret() -> bool:
	"""Retorna si el jugador puede ejercer arrepentimiento"""
	return _can_regret


func get_regret_card() -> Dictionary:
	"""Retorna la carta que se puede devolver por arrepentimiento"""
	return _regret_card


func _return_card_to_hand(card_data: Dictionary, player_id: int) -> void:
	"""Devuelve una carta a la mano del jugador

	Esta función debe integrarse con el sistema de manos del juego.
	"""
	if not _game_manager:
		_game_manager = get_node_or_null("/root/GameManager")

	if _game_manager and _game_manager.has_method("return_card_to_hand"):
		_game_manager.return_card_to_hand(card_data, player_id)
	elif _game_manager and _game_manager.has_method("add_card_to_hand"):
		_game_manager.add_card_to_hand(player_id, card_data)
	else:
		# Fallback: emitir señal para que otro sistema lo maneje
		print("[TargetSelector] WARN: No se pudo devolver carta a mano - GameManager no disponible")
		# La señal card_returned_to_hand ya fue emitida


func notify_step_b_started() -> void:
	"""Notifica que el Paso B (pago) ha comenzado - ya no se puede arrepentir"""
	if _can_regret:
		print("[TargetSelector] Paso B iniciado - arrepentimiento ya no disponible")
		_disable_regret()


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
	_disable_regret()

	# Determinar tipo de efecto
	var effect_type = SelectionType.ANNUL
	if _action_pipeline:
		var target_obj = _action_pipeline.get_object_by_id(target_stack_id)
		var obj_type = target_obj.get("type", 0)
		# Si el objetivo es una habilidad, es CANCEL
		if obj_type in [1, 2]:  # TRIGGERED_ABILITY, ACTIVATED_ABILITY
			effect_type = SelectionType.CANCEL

	# Obtener datos de la carta de respuesta
	var response_obj = {}
	if _action_pipeline:
		response_obj = _action_pipeline.get_object_by_id(response_stack_id)

	var source_card = response_obj.get("card_data", {})

	return link_effect(response_stack_id, target_stack_id, effect_type, source_card)
