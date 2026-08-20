extends Node
## PaymentManager - Gestión de Costes y Pagos (DAR Sección 6.B)
##
## Maneja:
## - Cálculo de costes (base + modificadores)
## - Costes alternativos (Exhumar, sacrificio, etc.)
## - Scanner de Cementerio para cartas con Exhumar
## - Interfaz de selección de pago

# =============================================================================
# SEÑALES
# =============================================================================
signal payment_requested(card_data: Dictionary, cost_info: Dictionary)
signal payment_completed(card_data: Dictionary, method: String, amount_paid: int)
signal payment_cancelled(card_data: Dictionary, reason: String)
signal payment_failed(card_data: Dictionary, reason: String)

## Exhumar
signal exhumar_cards_available(player_id: int, cards: Array)
signal exhumar_card_selected(card_data: Dictionary, player_id: int)
signal exhumar_payment_confirmed(card_data: Dictionary, player_id: int)

## Coste Variable X
signal x_value_requested(card_data: Dictionary, max_value: int)
signal x_value_selected(card_data: Dictionary, x_value: int)
signal x_value_cancelled(card_data: Dictionary)

## UI
signal payment_ui_opened(options: Array)
signal payment_ui_closed

# =============================================================================
# ENUMS
# =============================================================================
enum PaymentMethod {
	NORMAL,           # Pago normal con Oros
	EXHUMAR,          # Desde Cementerio
	SACRIFICE,        # Sacrificar carta
	DISCARD,          # Descartar cartas
	LIFE,             # Pagar vida/daño a Castillo
	FREE,             # Sin coste
	ALTERNATIVE,      # Coste alternativo definido en carta
	VARIABLE_X        # Coste variable (X)
}

enum PaymentState {
	IDLE,
	AWAITING_SELECTION,    # Esperando que jugador elija método
	AWAITING_X_INPUT,      # Esperando valor de X
	AWAITING_PAYMENT,      # Esperando que pague
	PROCESSING,            # Procesando pago
	COMPLETED,
	CANCELLED
}

# =============================================================================
# ESTADO
# =============================================================================
var _state: PaymentState = PaymentState.IDLE
var _current_card: Dictionary = {}
var _current_player_id: int = -1
var _current_cost_info: Dictionary = {}
var _selected_method: PaymentMethod = PaymentMethod.NORMAL

# =============================================================================
# ESTADO DE COSTE VARIABLE X
# =============================================================================
var _x_value: int = 0                  # Valor seleccionado para X
var _x_max_value: int = 0              # Máximo permitido (Oros disponibles)
var _x_base_cost: int = 0              # Coste base además de X
var _has_x_cost: bool = false          # Si la carta actual tiene coste X
var _x_callback: Callable = Callable() # Callback tras seleccionar X

# =============================================================================
# CACHE DE EXHUMAR
# =============================================================================
## Cartas con Exhumar detectadas por jugador: {player_id: [card_data, ...]}
var _exhumar_cache: Dictionary = {}
var _cache_dirty: bool = true

# =============================================================================
# REFERENCIAS
# =============================================================================
var _game_manager: Node = null
var _action_pipeline: Node = null
var _action_executor: Node = null
var _priority_manager: Node = null

# =============================================================================
# UI REFERENCES
# =============================================================================
var _payment_popup: Window = null
var _exhumar_popup: Window = null
var _x_value_popup: Window = null  # Fallback programático
var _x_value_selector: Control = null  # Escena XValueSelector.tscn

## Escena del selector de X
const X_VALUE_SELECTOR_SCENE = preload("res://scenes/ui/XValueSelector.tscn")

var _combat_log: Node = null

# =============================================================================
# MODIFICADORES DE COSTE (DAR Sección 6.B)
# =============================================================================
## Modificadores de coste activos [{source, modifier, condition}]
var cost_modifiers: Array = []
## Reducciones "Oros menos" activas [{source, reduction, condition}]
var oros_menos_modifiers: Array = []

# =============================================================================
# TRACKING DE ORO GASTADO EN EL TURNO
# =============================================================================
## Acumulado de oro pagado en el turno actual (se resetea en cada nuevo turno)
var oro_gastado_este_turno: int = 0


func _ready() -> void:
	call_deferred("_get_references")
	call_deferred("_connect_signals")
	call_deferred("_setup_x_selector")
	print("[PaymentManager] Inicializado")


func _on_turn_started_clear_modifiers(_player_id: int, _turn_num: int) -> void:
	cost_modifiers.clear()
	oros_menos_modifiers.clear()
	oro_gastado_este_turno = 0


func puede_jugar_carta(card: Node, player_id: int = 0) -> bool:
	"""Valida si el jugador puede pagar la carta considerando lo ya gastado este turno.
	Cartas de coste 0 siempre se permiten si hay prioridad.
	Returns: true si puede jugarla, false si no tiene oro suficiente."""
	var coste = calcular_coste_real(card)

	# Coste 0 → siempre jugable (Talismanes sin coste, etc.)
	if coste <= 0:
		return true

	var main = get_node_or_null("/root/Main")
	if not main:
		return false

	# Oro físico disponible en reserva ahora mismo
	var game_state = get_node_or_null("/root/GameState")
	var oro_reserva: int = 0
	if game_state and game_state.has_method("get_oro_reserva"):
		oro_reserva = game_state.get_oro_reserva(player_id)
	elif main.has_method("get_oro_disponible"):
		oro_reserva = main.get_oro_disponible()

	# Oros virtuales del jugador
	var oros_virtuales: int = main.get("oros_virtuales") if main.get("oros_virtuales") != null else 0

	var disponible = oro_reserva + oros_virtuales
	return coste <= disponible


func registrar_pago(amount: int) -> void:
	"""Registra un pago completado en el tracker del turno."""
	if amount > 0:
		oro_gastado_este_turno += amount


func calcular_coste_real(card: Node) -> int:
	if not is_instance_valid(card):
		return 0
	"""Calcula el coste real de una carta aplicando DAR 6.B.
	1. Coste base
	2. Modificadores (mínimo 1 si tenía coste)
	3. Reducciones 'Oros menos'
	4. Resultado <= 0 → coste 0
	"""
	var coste_base: int = 0
	if card.get("card_cost") != null:
		coste_base = int(card.get("card_cost"))
	var coste_mod = coste_base
	for mod in cost_modifiers:
		if _modifier_applies(mod, card):
			coste_mod += mod.modifier
	if coste_base > 0:
		coste_mod = maxi(coste_mod, 1)
	var oros_menos_total = 0
	for red in oros_menos_modifiers:
		if _modifier_applies(red, card):
			oros_menos_total += red.reduction
	return maxi(coste_mod - oros_menos_total, 0)


func _modifier_applies(mod: Dictionary, card: Node) -> bool:
	if not mod.has("condition") or mod.condition == null:
		return true
	if mod.condition is Callable and mod.condition.is_valid():
		return mod.condition.call(card)
	return false  # Tipo de condición desconocido — no aplicar


func agregar_modificador_coste(source: Node, modifier: int, condition: Callable = Callable()) -> void:
	cost_modifiers.append({
		"source": source,
		"modifier": modifier,
		"condition": condition if condition.is_valid() else null
	})


func remover_modificador_coste(source: Node) -> void:
	cost_modifiers = cost_modifiers.filter(func(m): return m.source != source)


func agregar_oros_menos(source: Node, reduction: int, condition: Callable = Callable()) -> void:
	oros_menos_modifiers.append({
		"source": source,
		"reduction": reduction,
		"condition": condition if condition.is_valid() else null
	})


func remover_oros_menos(source: Node) -> void:
	oros_menos_modifiers = oros_menos_modifiers.filter(func(m): return m.source != source)


func puede_pagar_carta(card: Node) -> bool:
	"""Verifica si el jugador (player 0) puede pagar el coste real de una carta"""
	var main = get_node_or_null("/root/Main")
	if main and main.has_method("puede_pagar"):
		return main.puede_pagar(calcular_coste_real(card))
	return false


## NOTA: Esta función es una coroutine. Siempre llamar con: await pagar_carta(card)
func pagar_carta(card: Node) -> bool:
	"""Paga el coste real de una carta delegando el pago físico a Main
	Returns: true si se pudo pagar
	"""
	var coste_real = calcular_coste_real(card)
	var main = get_node_or_null("/root/Main")
	if not main:
		return false
	if coste_real <= 0:
		return true
	return await main.pagar_coste(coste_real)


func _setup_x_selector() -> void:
	"""Instancia la escena XValueSelector"""
	if X_VALUE_SELECTOR_SCENE:
		_x_value_selector = X_VALUE_SELECTOR_SCENE.instantiate()
		_x_value_selector.name = "XValueSelector"
		add_child(_x_value_selector)

		# Conectar señales
		_x_value_selector.x_confirmed.connect(_on_x_selector_confirmed)
		_x_value_selector.x_cancelled.connect(_on_x_selector_cancelled)
		_x_value_selector.x_changed.connect(_on_x_selector_changed)

		print("[PaymentManager] XValueSelector instanciado desde escena")


func _get_references() -> void:
	_game_manager = get_node_or_null("/root/GameManager")
	_action_pipeline = get_node_or_null("/root/ActionPipeline")
	_action_executor = get_node_or_null("/root/ActionExecutor")
	_priority_manager = get_node_or_null("/root/PriorityManager")
	_combat_log = get_node_or_null("/root/CombatLog")


func _connect_signals() -> void:
	# Invalidar cache cuando cambia el cementerio
	if _game_manager:
		if _game_manager.has_signal("card_moved_to_zone"):
			_game_manager.card_moved_to_zone.connect(_on_card_moved_to_zone)
		if _game_manager.has_signal("zone_changed"):
			_game_manager.zone_changed.connect(_on_zone_changed)

	# Conectar con PriorityManager para saber cuándo mostrar opciones
	if _priority_manager:
		if _priority_manager.has_signal("priority_given"):
			_priority_manager.priority_given.connect(_on_priority_given)

	# Limpiar modificadores al inicio de cada turno.
	# GameManager es el único conductor de turnos (ver consolidación 2026-08-19).
	if GameManager and GameManager.has_signal("turn_started"):
		if not GameManager.turn_started.is_connected(_on_turn_started_clear_modifiers):
			GameManager.turn_started.connect(_on_turn_started_clear_modifiers)


# =============================================================================
# SCANNER DE CEMENTERIO - Detecta cartas con Exhumar
# =============================================================================
func scan_cemetery_for_exhumar(player_id: int) -> Array[Dictionary]:
	"""Escanea el cementerio del jugador buscando cartas con Exhumar

	Identifica cartas con el trait has_exhumar o keyword EXHUMAR
	y las marca como 'Jugables' si el jugador puede pagarlas.

	Args:
		player_id: ID del jugador cuyo cementerio escanear

	Returns:
		Array de cartas jugables via Exhumar con info de coste
	"""
	# Usar cache si está disponible
	if not _cache_dirty and _exhumar_cache.has(player_id):
		return _exhumar_cache[player_id]

	var playable_cards: Array[Dictionary] = []
	var cemetery = _get_player_cemetery(player_id)

	for card in cemetery:
		if _card_has_exhumar(card):
			var card_info = _create_exhumar_card_info(card, player_id)
			if card_info.can_play:
				playable_cards.append(card_info)

	# Guardar en cache
	_exhumar_cache[player_id] = playable_cards
	_cache_dirty = false

	print("[PaymentManager] Cementerio J%d: %d cartas con Exhumar disponibles" % [
		player_id + 1, playable_cards.size()
	])

	return playable_cards


func get_all_exhumar_cards() -> Dictionary:
	"""Obtiene cartas con Exhumar de todos los jugadores

	Returns:
		{player_id: [card_info, ...]}
	"""
	var result: Dictionary = {}

	for player_id in range(2):  # 2 jugadores
		result[player_id] = scan_cemetery_for_exhumar(player_id)

	return result


func _card_has_exhumar(card_data: Dictionary) -> bool:
	"""Verifica si una carta tiene la habilidad Exhumar"""
	# Verificar trait directo
	var traits = card_data.get("traits", {})
	if traits.get("has_exhumar", false):
		return true

	# Verificar keywords
	var keywords = card_data.get("keywords", [])
	for kw in keywords:
		if kw is String and kw.to_upper() == "EXHUMAR":
			return true
		if kw is int and kw == Constants.Keyword.EXHUMAR:
			return true

	# Verificar texto de habilidad
	var ability = str(card_data.get("habilidad", card_data.get("ability", "")))
	if "exhumar" in ability.to_lower():
		return true

	return false


func _create_exhumar_card_info(card_data: Dictionary, player_id: int) -> Dictionary:
	"""Crea estructura de info para carta con Exhumar"""
	var base_cost = card_data.get("coste", 0)
	var exhumar_cost = _calculate_exhumar_cost(card_data, base_cost)
	var can_afford = _can_player_afford(player_id, exhumar_cost)

	# ─────────────────────────────────────────────────────────────────────────
	# VALIDACIÓN ÚNICA: Bloquear si ya existe copia en juego o pila
	# ─────────────────────────────────────────────────────────────────────────
	var is_unique = _card_is_unique(card_data)
	var unique_blocked = false
	var block_reason = ""

	if is_unique:
		var unique_check = _validate_unique_card(card_data, player_id)
		if not unique_check.can_play:
			unique_blocked = true
			block_reason = unique_check.reason

	# Determinar si se puede jugar
	var can_play = can_afford and not unique_blocked
	var playable_reason = ""

	if unique_blocked:
		playable_reason = block_reason
	elif not can_afford:
		playable_reason = "Oro insuficiente"
	else:
		playable_reason = "Exhumar disponible"

	return {
		"card_data": card_data,
		"card_id": card_data.get("id", card_data.get("card_id", -1)),
		"name": card_data.get("nombre", card_data.get("name", "???")),
		"base_cost": base_cost,
		"exhumar_cost": exhumar_cost,
		"can_play": can_play,
		"can_afford": can_afford,
		"is_unique": is_unique,
		"unique_blocked": unique_blocked,
		"player_id": player_id,
		"source_zone": Constants.Zone.CEMENTERIO,
		"payment_method": PaymentMethod.EXHUMAR,
		"is_playable": can_play,
		"playable_reason": playable_reason
	}


func _calculate_exhumar_cost(card_data: Dictionary, base_cost: int) -> int:
	"""Calcula el coste de Exhumar (puede ser diferente al base)

	Por defecto Exhumar usa el mismo coste, pero algunas cartas
	pueden tener costes alternativos definidos.
	"""
	# Verificar si hay coste de Exhumar específico
	var exhumar_data = card_data.get("exhumar", {})
	if exhumar_data.has("cost"):
		return int(exhumar_data.cost)

	var traits = card_data.get("traits", {})
	if traits.has("exhumar_cost"):
		return int(traits.exhumar_cost)

	# Usar coste base por defecto
	return base_cost


func _can_player_afford(player_id: int, cost: int) -> bool:
	"""Verifica si el jugador tiene suficiente Oro"""
	if cost <= 0:
		return true

	var available_gold = _get_player_available_gold(player_id)
	return available_gold >= cost


# =============================================================================
# VALIDACIÓN DE CARTAS ÚNICAS (DAR Sección 4.1)
# =============================================================================
func _card_is_unique(card_data: Dictionary) -> bool:
	"""Verifica si una carta tiene el trait 'Única'"""
	# Verificar trait directo
	var traits = card_data.get("traits", {})
	if traits.get("is_unique", false):
		return true

	# Verificar keywords
	var keywords = card_data.get("keywords", [])
	for kw in keywords:
		if kw is String and kw.to_upper() == "UNICA":
			return true
		if kw is String and kw.to_upper() == "ÚNICA":
			return true
		if kw is int and kw == Constants.Keyword.UNICA:
			return true

	# Verificar texto de habilidad
	var ability = str(card_data.get("habilidad", card_data.get("ability", "")))
	if "única" in ability.to_lower():
		return true

	return false


func _validate_unique_card(card_data: Dictionary, player_id: int) -> Dictionary:
	"""Valida si una carta Única puede ser jugada

	Bloquea el pago si ya existe una copia en:
	- Campo de Juego (Línea de Defensa, Ataque, Apoyo)
	- Pila de resolución

	Returns:
		{can_play: bool, reason: String}
	"""
	var card_name = card_data.get("nombre", card_data.get("name", ""))

	# Verificar en Campo de Juego
	var in_play = _check_unique_in_play(card_name, player_id)
	if in_play.found:
		return {
			"can_play": false,
			"reason": "ÚNICA: Ya hay una copia en %s" % in_play.zone_name
		}

	# Verificar en Pila de Resolución
	var in_stack = _check_unique_in_stack(card_name)
	if in_stack.found:
		return {
			"can_play": false,
			"reason": "ÚNICA: Ya hay una copia en la Pila de Efectos"
		}

	return {"can_play": true, "reason": ""}


func _check_unique_in_play(card_name: String, player_id: int) -> Dictionary:
	"""Busca si existe una copia de la carta en el campo de juego. El campo
	real es un único contenedor por jugador (no hay zonas separadas de
	Defensa/Ataque/Apoyo), así que se revisa una sola vez."""
	var result = {"found": false, "zone_name": "", "card": null}

	for card in _get_cards_in_zone(player_id, -1):
		var existing_name = card.get("card_name") if card.get("card_name") != null else ""
		if existing_name.to_lower() == card_name.to_lower():
			result.found = true
			result.zone_name = "el campo de juego"
			result.card = card
			return result

	return result


func _check_unique_in_stack(card_name: String) -> Dictionary:
	"""Busca si existe una copia de la carta en la pila de resolución"""
	var result = {"found": false, "stack_id": -1}

	if not _action_pipeline:
		return result

	if not _action_pipeline.has_method("get_stack"):
		return result

	var stack = _action_pipeline.get_stack()
	for stack_obj in stack:
		var obj_name = stack_obj.get("name", "")
		var card_data = stack_obj.get("card_data", {})
		var card_nombre = card_data.get("nombre", card_data.get("name", ""))

		if obj_name.to_lower() == card_name.to_lower() or card_nombre.to_lower() == card_name.to_lower():
			result.found = true
			result.stack_id = stack_obj.get("id", -1)
			return result

	return result


func _get_cards_in_zone(player_id: int, _zone: int) -> Array:
	"""Obtiene las cartas en juego (campo) de un jugador. Antes buscaba
	métodos que no existen en GameManager (get_zone_cards/get_cards_in_zone)
	y como fallback un '_game_board' que tampoco existe — siempre devolvía
	[], así que la validación de la palabra clave Única jamás encontraba
	una copia ya en juego. El campo real es un único contenedor por
	jugador (no hay contenedores separados por Línea de Defensa/Ataque/
	Apoyo), así que se ignora el parámetro de zona."""
	var main = get_node_or_null("/root/Main")
	if not main:
		return []
	var field = main.player_field if player_id == 0 else main.opponent_field
	if not field:
		return []
	return field.get_children()


func _get_player_cemetery(player_id: int) -> Array:
	"""Obtiene las cartas en el cementerio del jugador"""
	if _game_manager and _game_manager.has_method("get_zone_cards"):
		return _game_manager.get_zone_cards(player_id, Constants.Zone.CEMENTERIO)

	if _game_manager and _game_manager.has_method("get_cemetery"):
		return _game_manager.get_cemetery(player_id)

	# Fallback: buscar en estructura de zonas
	if _game_manager:
		var zones = _game_manager.get("_zones")
		if zones and zones.has(player_id):
			var player_zones = zones[player_id]
			if player_zones.has(Constants.Zone.CEMENTERIO):
				return player_zones[Constants.Zone.CEMENTERIO]

	return []


func _get_player_available_gold(player_id: int) -> int:
	"""Obtiene el Oro disponible del jugador"""
	if _game_manager and _game_manager.has_method("get_available_gold"):
		return _game_manager.get_available_gold(player_id)

	if _game_manager and _game_manager.has_method("get_player_gold"):
		return _game_manager.get_player_gold(player_id)

	# Fallback
	if _game_manager:
		var gold_reserve = _game_manager.get("_gold_reserves")
		if gold_reserve and gold_reserve.has(player_id):
			return gold_reserve[player_id]

	return 0


# =============================================================================
# MARCADO DE CARTAS JUGABLES
# =============================================================================
func mark_playable_exhumar_cards(player_id: int) -> void:
	"""Marca las cartas con Exhumar como jugables en la UI

	Llamar durante ventanas de prioridad legales.
	"""
	var exhumar_cards = scan_cemetery_for_exhumar(player_id)

	if exhumar_cards.is_empty():
		return

	emit_signal("exhumar_cards_available", player_id, exhumar_cards)

	print("[PaymentManager] 💀 %d cartas con EXHUMAR disponibles para J%d" % [
		exhumar_cards.size(), player_id + 1
	])


func _on_priority_given(player_id: int) -> void:
	"""Callback cuando un jugador recibe prioridad"""
	# Verificar cartas con Exhumar disponibles
	mark_playable_exhumar_cards(player_id)


# =============================================================================
# INTERFAZ DE PAGO - Menú emergente
# =============================================================================
func show_payment_options(card_data: Dictionary, player_id: int, options: Array = []) -> void:
	"""Muestra menú de opciones de pago para una carta

	Args:
		card_data: Datos de la carta a jugar
		options: Métodos de pago disponibles (auto-detecta si vacío)
	"""
	# ─────────────────────────────────────────────────────────────────────────
	# VALIDACIÓN ÚNICA: Bloquear si carta Única ya existe en juego/pila
	# ─────────────────────────────────────────────────────────────────────────
	if _card_is_unique(card_data):
		var unique_check = _validate_unique_card(card_data, player_id)
		if not unique_check.can_play:
			print("[PaymentManager] ⛔ BLOQUEADO: %s" % unique_check.reason)
			emit_signal("payment_failed", card_data, unique_check.reason)
			_show_unique_blocked_message(card_data, unique_check.reason)
			return

	_current_card = card_data
	_current_player_id = player_id
	_state = PaymentState.AWAITING_SELECTION

	# Auto-detectar opciones si no se proporcionan
	if options.is_empty():
		options = _detect_payment_options(card_data, player_id)

	_current_cost_info = {
		"base_cost": card_data.get("coste", 0),
		"options": options,
		"player_id": player_id,
		"is_unique": _card_is_unique(card_data)
	}

	# Crear y mostrar popup
	_create_payment_popup(card_data, options)

	emit_signal("payment_ui_opened", options)
	emit_signal("payment_requested", card_data, _current_cost_info)


func _show_unique_blocked_message(card_data: Dictionary, reason: String) -> void:
	"""Muestra mensaje cuando una carta Única está bloqueada"""
	var card_name = card_data.get("nombre", card_data.get("name", "???"))

	# Crear popup de error
	var popup = AcceptDialog.new()
	popup.title = "⛔ Carta Única Bloqueada"
	popup.dialog_text = "%s\n\n%s" % [card_name, reason]
	popup.confirmed.connect(popup.queue_free)
	add_child(popup)
	popup.popup_centered()

	print("[PaymentManager] Carta Única '%s' bloqueada: %s" % [card_name, reason])


func _detect_payment_options(card_data: Dictionary, player_id: int) -> Array:
	"""Detecta métodos de pago disponibles para una carta"""
	var options: Array = []
	var available_gold = _get_player_available_gold(player_id)

	# ─────────────────────────────────────────────────────────────────────────
	# Detectar Coste Variable X
	# ─────────────────────────────────────────────────────────────────────────
	if has_variable_x_cost(card_data):
		var x_info = parse_x_cost(card_data)
		var can_afford_min = available_gold >= x_info.base_cost

		options.append({
			"method": PaymentMethod.VARIABLE_X,
			"label": "Pagar %s (Variable)" % x_info.formula,
			"cost": x_info.base_cost,
			"available": can_afford_min,
			"has_x": true,
			"x_info": x_info,
			"description": "Coste variable - elige cuánto pagar"
		})

		# Si tiene coste X, esta es la única opción válida
		return options

	# ─────────────────────────────────────────────────────────────────────────
	# Coste Normal (no variable)
	# ─────────────────────────────────────────────────────────────────────────
	var base_cost = card_data.get("coste", 0)
	if base_cost is String:
		base_cost = 0  # Fallback si es string sin X

	# Opción 1: Pago normal
	if available_gold >= base_cost:
		options.append({
			"method": PaymentMethod.NORMAL,
			"label": "Pagar %d Oro" % base_cost,
			"cost": base_cost,
			"available": true,
			"description": "Pago estándar con Oros de la Reserva"
		})
	else:
		options.append({
			"method": PaymentMethod.NORMAL,
			"label": "Pagar %d Oro (Insuficiente)" % base_cost,
			"cost": base_cost,
			"available": false,
			"description": "Necesitas %d Oros más" % (base_cost - available_gold)
		})

	# Opción 2: Coste alternativo (si existe)
	var alt_cost = card_data.get("alternative_cost", card_data.get("coste_alternativo", {}))
	if not alt_cost.is_empty():
		var alt_option = _parse_alternative_cost(alt_cost, player_id)
		if alt_option:
			options.append(alt_option)

	# Opción 3: Costes especiales de keywords
	options.append_array(_get_keyword_payment_options(card_data, player_id))

	return options


func _parse_alternative_cost(alt_cost: Dictionary, player_id: int) -> Dictionary:
	"""Parsea un coste alternativo"""
	var cost_type = alt_cost.get("type", "gold")
	var amount = alt_cost.get("amount", alt_cost.get("value", 0))
	var available = false
	var label = ""
	var description = ""

	match cost_type:
		"gold", "oro":
			available = _get_player_available_gold(player_id) >= amount
			label = "Coste Alternativo: %d Oro" % amount
			description = "Pagar coste reducido/aumentado"

		"sacrifice", "sacrificio":
			# TODO: Verificar si tiene cartas para sacrificar
			available = true
			label = "Sacrificar %d carta(s)" % amount
			description = "Sacrificar cartas en lugar de pagar Oro"

		"discard", "descartar":
			# TODO: Verificar cartas en mano
			available = true
			label = "Descartar %d carta(s)" % amount
			description = "Descartar cartas de la mano"

		"life", "vida":
			available = true
			label = "Pagar %d de daño al Castillo" % amount
			description = "Infligirte daño en lugar de pagar Oro"

	return {
		"method": PaymentMethod.ALTERNATIVE,
		"label": label,
		"cost": amount,
		"cost_type": cost_type,
		"available": available,
		"description": description
	}


func _get_keyword_payment_options(card_data: Dictionary, player_id: int) -> Array:
	"""Obtiene opciones de pago basadas en keywords de la carta"""
	var options: Array = []
	var keywords = card_data.get("keywords", [])

	for kw in keywords:
		var kw_int = kw if kw is int else -1

		# Detectar keywords que afectan pago
		if kw_int == Constants.Keyword.EXHUMAR or (kw is String and kw.to_upper() == "EXHUMAR"):
			# Exhumar ya se maneja por separado desde cementerio
			pass

		# Agregar más keywords que afecten costes aquí

	return options


# =============================================================================
# COSTE VARIABLE X - Detector e Interfaz
# =============================================================================
func has_variable_x_cost(card_data: Dictionary) -> bool:
	"""Detecta si una carta tiene coste variable X

	Busca en:
	- coste: "X", "X+1", "2+X", etc.
	- coste_x: true
	- has_x_cost: true en traits
	- Texto de habilidad que mencione "paga X"
	"""
	# Verificar coste directo
	var cost = card_data.get("coste", card_data.get("cost", 0))
	if cost is String:
		var cost_str = cost.to_upper()
		if "X" in cost_str:
			return true

	# Verificar flag explícito
	if card_data.get("coste_x", false):
		return true
	if card_data.get("has_x_cost", false):
		return true

	# Verificar traits
	var traits = card_data.get("traits", {})
	if traits.get("has_x_cost", false):
		return true
	if traits.get("coste_variable", false):
		return true

	# Verificar texto de habilidad
	var ability = str(card_data.get("habilidad", card_data.get("ability", ""))).to_lower()
	if "paga x" in ability or "pagar x" in ability or "coste x" in ability:
		return true

	return false


func parse_x_cost(card_data: Dictionary) -> Dictionary:
	"""Parsea el coste X de una carta

	Returns:
		{
			has_x: bool,
			base_cost: int,      # Coste fijo adicional (ej: "2+X" = 2)
			x_multiplier: int,   # Multiplicador de X (ej: "2X" = 2)
			formula: String      # Fórmula original
		}
	"""
	var result = {
		"has_x": false,
		"base_cost": 0,
		"x_multiplier": 1,
		"formula": ""
	}

	var cost = card_data.get("coste", card_data.get("cost", 0))

	# Si es número directo, no hay X
	if cost is int or cost is float:
		return result

	if cost is String:
		var cost_str = cost.to_upper().strip_edges()
		result.formula = cost_str

		if "X" in cost_str:
			result.has_x = true

			# Parsear fórmulas comunes
			# "X" puro
			if cost_str == "X":
				result.base_cost = 0
				result.x_multiplier = 1

			# "X+N" o "N+X"
			elif "+" in cost_str:
				var parts = cost_str.split("+")
				for part in parts:
					part = part.strip_edges()
					if part == "X":
						result.x_multiplier = 1
					elif part.is_valid_int():
						result.base_cost = int(part)
					elif part.ends_with("X"):
						# "2X" = 2 * X
						var mult = part.replace("X", "").strip_edges()
						if mult.is_valid_int():
							result.x_multiplier = int(mult)

			# "2X" (sin +)
			elif cost_str.ends_with("X") and cost_str.length() > 1:
				var mult = cost_str.replace("X", "").strip_edges()
				if mult.is_valid_int():
					result.x_multiplier = int(mult)

	return result


func request_x_value_input(card_data: Dictionary, player_id: int, callback: Callable = Callable()) -> void:
	"""Solicita al jugador que seleccione el valor de X

	Args:
		card_data: Datos de la carta con coste X
		player_id: Jugador que paga
		callback: Función a llamar con el valor seleccionado
	"""
	_current_card = card_data
	_current_player_id = player_id
	_state = PaymentState.AWAITING_X_INPUT
	_x_callback = callback

	# Calcular límites
	var x_info = parse_x_cost(card_data)
	var available_gold = _get_player_available_gold(player_id)

	_x_base_cost = x_info.base_cost
	_has_x_cost = true

	# Máximo X = (Oro disponible - coste base) / multiplicador
	if x_info.x_multiplier > 0:
		_x_max_value = (available_gold - x_info.base_cost) / x_info.x_multiplier
	else:
		_x_max_value = available_gold - x_info.base_cost

	_x_max_value = maxi(0, _x_max_value)
	_x_value = 0

	print("[PaymentManager] ═══ COSTE VARIABLE X ═══")
	print("[PaymentManager] Carta: %s" % card_data.get("nombre", card_data.get("name", "???")))
	print("[PaymentManager] Fórmula: %s | Base: %d | Máx X: %d" % [
		x_info.formula, x_info.base_cost, _x_max_value
	])

	emit_signal("x_value_requested", card_data, _x_max_value)

	# ─────────────────────────────────────────────────────────────────────────
	# USAR ESCENA XValueSelector.tscn SI ESTÁ DISPONIBLE
	# ─────────────────────────────────────────────────────────────────────────
	if _x_value_selector and is_instance_valid(_x_value_selector):
		_x_value_selector.show_selector(card_data, player_id, available_gold, x_info)
	else:
		# Fallback: popup programático
		_create_x_value_popup(card_data, x_info)


func _create_x_value_popup(card_data: Dictionary, x_info: Dictionary) -> void:
	"""Crea popup para seleccionar valor de X"""
	if _x_value_popup and is_instance_valid(_x_value_popup):
		_x_value_popup.queue_free()

	_x_value_popup = Window.new()
	_x_value_popup.name = "XValuePopup"
	_x_value_popup.title = "Seleccionar Valor de X"
	_x_value_popup.size = Vector2i(320, 280)
	_x_value_popup.unresizable = true
	_x_value_popup.close_requested.connect(_on_x_value_cancelled)
	add_child(_x_value_popup)

	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_x_value_popup.add_child(panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 15)
	margin.add_child(vbox)

	# Título de la carta
	var title = Label.new()
	title.text = card_data.get("nombre", card_data.get("name", "???"))
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Fórmula del coste
	var formula_label = Label.new()
	formula_label.text = "Coste: %s" % x_info.formula
	formula_label.add_theme_font_size_override("font_size", 14)
	formula_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	formula_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	vbox.add_child(formula_label)

	# Oro disponible
	var gold_label = Label.new()
	gold_label.text = "💰 Oro disponible: %d" % _get_player_available_gold(_current_player_id)
	gold_label.add_theme_font_size_override("font_size", 12)
	gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(gold_label)

	# Separador
	vbox.add_child(HSeparator.new())

	# Contenedor del contador
	var counter_hbox = HBoxContainer.new()
	counter_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	counter_hbox.add_theme_constant_override("separation", 15)
	vbox.add_child(counter_hbox)

	# Botón -
	var minus_btn = Button.new()
	minus_btn.text = "-"
	minus_btn.custom_minimum_size = Vector2(40, 40)
	minus_btn.pressed.connect(_on_x_decrement)
	counter_hbox.add_child(minus_btn)

	# Display del valor
	var value_label = Label.new()
	value_label.name = "XValueLabel"
	value_label.text = "X = 0"
	value_label.add_theme_font_size_override("font_size", 24)
	value_label.custom_minimum_size.x = 80
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	counter_hbox.add_child(value_label)

	# Botón +
	var plus_btn = Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(40, 40)
	plus_btn.pressed.connect(_on_x_increment)
	counter_hbox.add_child(plus_btn)

	# Coste total calculado
	var total_label = Label.new()
	total_label.name = "TotalCostLabel"
	total_label.text = "Coste total: %d Oro" % x_info.base_cost
	total_label.add_theme_font_size_override("font_size", 14)
	total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	total_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	vbox.add_child(total_label)

	# Slider para selección rápida (si el máximo es > 5)
	if _x_max_value > 5:
		var slider = HSlider.new()
		slider.name = "XSlider"
		slider.min_value = 0
		slider.max_value = _x_max_value
		slider.value = 0
		slider.step = 1
		slider.value_changed.connect(_on_x_slider_changed)
		vbox.add_child(slider)

	# Separador
	vbox.add_child(HSeparator.new())

	# Botones de acción
	var btn_hbox = HBoxContainer.new()
	btn_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_hbox.add_theme_constant_override("separation", 20)
	vbox.add_child(btn_hbox)

	var confirm_btn = Button.new()
	confirm_btn.text = "✓ Confirmar"
	confirm_btn.pressed.connect(_on_x_value_confirmed)
	btn_hbox.add_child(confirm_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "✗ Cancelar"
	cancel_btn.pressed.connect(_on_x_value_cancelled)
	btn_hbox.add_child(cancel_btn)

	_x_value_popup.popup_centered()


func _on_x_increment() -> void:
	"""Incrementa el valor de X"""
	if _x_value < _x_max_value:
		_x_value += 1
		_update_x_display()


func _on_x_decrement() -> void:
	"""Decrementa el valor de X"""
	if _x_value > 0:
		_x_value -= 1
		_update_x_display()


func _on_x_slider_changed(value: float) -> void:
	"""Callback cuando cambia el slider"""
	_x_value = int(value)
	_update_x_display()


func _update_x_display() -> void:
	"""Actualiza la UI con el valor actual de X"""
	if not _x_value_popup or not is_instance_valid(_x_value_popup):
		return

	var x_info = parse_x_cost(_current_card)
	var total_cost = x_info.base_cost + (_x_value * x_info.x_multiplier)

	# Actualizar label de valor
	var value_label = _x_value_popup.find_child("XValueLabel", true, false)
	if value_label:
		value_label.text = "X = %d" % _x_value

	# Actualizar coste total
	var total_label = _x_value_popup.find_child("TotalCostLabel", true, false)
	if total_label:
		total_label.text = "Coste total: %d Oro" % total_cost

	# Actualizar slider si existe
	var slider = _x_value_popup.find_child("XSlider", true, false)
	if slider and slider.value != _x_value:
		slider.value = _x_value


func _on_x_value_confirmed() -> void:
	"""Callback cuando se confirma el valor de X"""
	var x_info = parse_x_cost(_current_card)
	var total_cost = x_info.base_cost + (_x_value * x_info.x_multiplier)
	var card_name = _current_card.get("nombre", _current_card.get("name", "???"))
	var player_name = _get_player_name(_current_player_id)

	print("[PaymentManager] ✓ X = %d confirmado (Coste total: %d)" % [_x_value, total_cost])

	# Guardar valor de X en la carta para uso posterior
	_current_card["x_value"] = _x_value
	_current_card["x_total_cost"] = total_cost

	# ─────────────────────────────────────────────────────────────────────────
	# LOG: Registrar valor de X seleccionado
	# ─────────────────────────────────────────────────────────────────────────
	_log_action("cost", "%s elige X = %d para [%s] (Coste: %d)" % [
		player_name, _x_value, card_name, total_cost
	], {
		"player_id": _current_player_id,
		"card_name": card_name,
		"x_value": _x_value,
		"total_cost": total_cost,
		"formula": x_info.formula
	})

	emit_signal("x_value_selected", _current_card, _x_value)

	_close_x_value_popup()

	# Ejecutar callback si existe
	if _x_callback.is_valid():
		_x_callback.call(_x_value, total_cost)

	# Continuar con el pago normal
	_state = PaymentState.AWAITING_PAYMENT
	var payment_option = {
		"method": PaymentMethod.VARIABLE_X,
		"cost": total_cost,
		"x_value": _x_value
	}
	_process_payment(payment_option)


func _on_x_value_cancelled() -> void:
	"""Callback cuando se cancela la selección de X"""
	print("[PaymentManager] Selección de X cancelada")
	emit_signal("x_value_cancelled", _current_card)
	_close_x_value_popup()
	_state = PaymentState.CANCELLED
	emit_signal("payment_cancelled", _current_card, "Selección de X cancelada")


func _close_x_value_popup() -> void:
	"""Cierra el popup de selección de X"""
	if _x_value_popup and is_instance_valid(_x_value_popup):
		_x_value_popup.queue_free()
		_x_value_popup = null

	_has_x_cost = false


# =============================================================================
# CALLBACKS DE XValueSelector.tscn (Escena)
# =============================================================================
func _on_x_selector_confirmed(x_value: int, total_cost: int) -> void:
	"""Callback cuando XValueSelector confirma el valor"""
	var card_name = _current_card.get("nombre", _current_card.get("name", "???"))
	var player_name = _get_player_name(_current_player_id)

	_x_value = x_value
	print("[PaymentManager] ✓ XValueSelector: X = %d (Total: %d)" % [x_value, total_cost])

	# ─────────────────────────────────────────────────────────────────────────
	# INYECCIÓN DE DATOS: instance_x en card_data para la Pila
	# ─────────────────────────────────────────────────────────────────────────
	_current_card["instance_x"] = x_value
	_current_card["x_value"] = x_value
	_current_card["x_total_cost"] = total_cost

	# Log
	_log_action("cost", "%s elige X = %d para [%s] (Coste: %d)" % [
		player_name, x_value, card_name, total_cost
	], {
		"player_id": _current_player_id,
		"card_name": card_name,
		"instance_x": x_value,
		"total_cost": total_cost
	})

	emit_signal("x_value_selected", _current_card, x_value)

	# Ejecutar callback si existe
	if _x_callback.is_valid():
		_x_callback.call(x_value, total_cost)

	# Continuar con el pago
	_state = PaymentState.AWAITING_PAYMENT
	var payment_option = {
		"method": PaymentMethod.VARIABLE_X,
		"cost": total_cost,
		"x_value": x_value,
		"instance_x": x_value
	}
	_process_payment(payment_option)


func _on_x_selector_cancelled() -> void:
	"""Callback cuando XValueSelector cancela"""
	print("[PaymentManager] XValueSelector cancelado")
	emit_signal("x_value_cancelled", _current_card)
	_state = PaymentState.CANCELLED
	_has_x_cost = false
	emit_signal("payment_cancelled", _current_card, "Selección de X cancelada")


func _on_x_selector_changed(x_value: int) -> void:
	"""Callback cuando cambia el valor en XValueSelector (preview)"""
	_x_value = x_value
	# Opcional: emitir señal para preview en UI


func get_x_value() -> int:
	"""Retorna el valor actual de X"""
	return _x_value


func get_x_total_cost() -> int:
	"""Retorna el coste total con X incluido"""
	var x_info = parse_x_cost(_current_card)
	return x_info.base_cost + (_x_value * x_info.x_multiplier)


# =============================================================================
# HELPER FUNCTIONS - Log y Player Name
# =============================================================================
func _log_action(action_type: String, message: String, data: Dictionary = {}) -> void:
	"""Registra una acción en el CombatLog"""
	if _combat_log and _combat_log.has_method("add_entry"):
		_combat_log.add_entry(action_type, message, data)
	else:
		# Fallback: print al console
		print("[PaymentManager:Log] %s: %s" % [action_type, message])


func _get_player_name(player_id: int) -> String:
	"""Obtiene el nombre del jugador para logs"""
	if _game_manager and _game_manager.has_method("get_player_name"):
		return _game_manager.get_player_name(player_id)

	# Fallback: buscar en datos de jugador
	if _game_manager:
		var players = _game_manager.get("_players")
		if players and players.has(player_id):
			var player = players[player_id]
			if player is Dictionary:
				return player.get("name", player.get("nombre", "Jugador %d" % (player_id + 1)))
			elif player.has_method("get"):
				return player.get("name", "Jugador %d" % (player_id + 1))

	return "Jugador %d" % (player_id + 1)


func _create_payment_popup(card_data: Dictionary, options: Array) -> void:
	"""Crea el popup de selección de pago"""
	# Limpiar popup anterior
	if _payment_popup and is_instance_valid(_payment_popup):
		_payment_popup.queue_free()

	_payment_popup = Window.new()
	_payment_popup.name = "PaymentPopup"
	_payment_popup.title = "Seleccionar Método de Pago"
	_payment_popup.size = Vector2i(350, 300)
	_payment_popup.unresizable = true
	_payment_popup.close_requested.connect(_on_payment_cancelled)
	add_child(_payment_popup)

	# Contenido
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_payment_popup.add_child(panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# Título de la carta
	var title = Label.new()
	title.text = "💰 %s" % card_data.get("nombre", card_data.get("name", "???"))
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Separador
	vbox.add_child(HSeparator.new())

	# Info de coste base
	var cost_label = Label.new()
	cost_label.text = "Coste base: %d Oro" % card_data.get("coste", 0)
	cost_label.add_theme_font_size_override("font_size", 12)
	cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(cost_label)

	# Opciones de pago
	for i in range(options.size()):
		var option = options[i]
		var btn = Button.new()
		btn.text = option.label
		btn.disabled = not option.available
		btn.tooltip_text = option.description
		btn.pressed.connect(_on_payment_option_selected.bind(i))

		if option.available:
			btn.add_theme_color_override("font_color", Color.WHITE)
		else:
			btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))

		vbox.add_child(btn)

	# Separador
	vbox.add_child(HSeparator.new())

	# Botón cancelar
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancelar"
	cancel_btn.pressed.connect(_on_payment_cancelled)
	vbox.add_child(cancel_btn)

	_payment_popup.popup_centered()


func _on_payment_option_selected(option_index: int) -> void:
	"""Callback cuando el jugador selecciona una opción de pago"""
	var options = _current_cost_info.get("options", [])

	if option_index < 0 or option_index >= options.size():
		return

	var selected = options[option_index]

	if not selected.available:
		print("[PaymentManager] Opción no disponible")
		return

	_selected_method = selected.method

	# Cerrar popup de pago
	if _payment_popup:
		_payment_popup.hide()

	# ─────────────────────────────────────────────────────────────────────────
	# Si es coste variable X, redirigir a selección de X
	# ─────────────────────────────────────────────────────────────────────────
	if selected.method == PaymentMethod.VARIABLE_X:
		request_x_value_input(_current_card, _current_player_id)
		return

	_state = PaymentState.AWAITING_PAYMENT

	# Procesar pago según método
	_process_payment(selected)


func _process_payment(payment_option: Dictionary) -> void:
	"""Procesa el pago según el método seleccionado"""
	_state = PaymentState.PROCESSING

	var method = payment_option.method
	var cost = payment_option.cost
	var success = false

	match method:
		PaymentMethod.NORMAL:
			success = _pay_with_gold(cost)

		PaymentMethod.EXHUMAR:
			success = _pay_for_exhumar(cost)

		PaymentMethod.SACRIFICE:
			success = await _pay_with_sacrifice_async(payment_option)

		PaymentMethod.DISCARD:
			success = await _pay_with_discard_async(payment_option)

		PaymentMethod.LIFE:
			success = _pay_with_life(cost)

		PaymentMethod.ALTERNATIVE:
			success = await _pay_alternative_async(payment_option)

		PaymentMethod.VARIABLE_X:
			# El coste ya fue calculado en _on_x_value_confirmed
			var x_value = payment_option.get("x_value", 0)
			success = _pay_with_gold(cost)
			if success:
				print("[PaymentManager] 💰 Pago X=%d completado (Total: %d)" % [x_value, cost])

		PaymentMethod.FREE:
			success = true

	if success:
		_state = PaymentState.COMPLETED
		emit_signal("payment_completed", _current_card, PaymentMethod.keys()[method], cost)
		print("[PaymentManager] ✓ Pago completado: %s (%d)" % [PaymentMethod.keys()[method], cost])
	else:
		_state = PaymentState.IDLE
		emit_signal("payment_failed", _current_card, "Pago fallido")
		print("[PaymentManager] ✗ Pago fallido")

	_close_payment_ui()


func _pay_with_gold(amount: int) -> bool:
	"""Paga con Oro de la Reserva"""
	if not _game_manager:
		return false

	if _game_manager.has_method("spend_gold"):
		return _game_manager.spend_gold(_current_player_id, amount)

	if _game_manager.has_method("pay_gold"):
		return _game_manager.pay_gold(_current_player_id, amount)

	# Fallback: modificar directamente
	var gold_reserve = _game_manager.get("_gold_reserves")
	if gold_reserve and gold_reserve.has(_current_player_id):
		if gold_reserve[_current_player_id] >= amount:
			gold_reserve[_current_player_id] -= amount
			return true

	return false


func _pay_for_exhumar(cost: int) -> bool:
	"""Pago específico para Exhumar

	Marca la carta con flags necesarios para:
	- _exhumar_flag: Indica que fue jugada via Exhumar
	- _force_destination: DESTIERRO tras resolver/destruir
	"""
	var paid = _pay_with_gold(cost)

	if paid:
		# Asegurar que la carta tiene los flags de Exhumar
		_current_card["via_exhumar"] = true
		_current_card["_exhumar_flag"] = true
		_current_card["_force_destination"] = Constants.Zone.DESTIERRO

		print("[PaymentManager] 💀 Pago Exhumar completado - Destino forzado: DESTIERRO")

		# Notificar al ActionExecutor si existe
		if _action_executor and _action_executor.has_method("set_exhumar_flag"):
			_action_executor.set_exhumar_flag(true)

	return paid


func _pay_with_sacrifice_async(payment_option: Dictionary) -> bool:
	"""Pago mediante sacrificio de cartas (async para UI de selección)"""
	# TODO: Implementar selección de cartas a sacrificar
	print("[PaymentManager] Pago por sacrificio no implementado aún")
	await get_tree().process_frame  # Placeholder para async
	return false


func _pay_with_discard_async(payment_option: Dictionary) -> bool:
	"""Pago mediante descarte de cartas (async para UI de selección)"""
	# TODO: Implementar selección de cartas a descartar
	print("[PaymentManager] Pago por descarte no implementado aún")
	await get_tree().process_frame  # Placeholder para async
	return false


func _pay_with_life(amount: int) -> bool:
	"""Pago mediante daño al propio Castillo"""
	if not _game_manager:
		return false

	if _game_manager.has_method("deal_damage_to_castle"):
		_game_manager.deal_damage_to_castle(_current_player_id, amount)
		return true

	return false


func _pay_alternative_async(payment_option: Dictionary) -> bool:
	"""Procesa pago alternativo según tipo (async para métodos que requieren UI)"""
	var cost_type = payment_option.get("cost_type", "gold")

	match cost_type:
		"gold", "oro":
			return _pay_with_gold(payment_option.cost)
		"sacrifice", "sacrificio":
			return await _pay_with_sacrifice_async(payment_option)
		"discard", "descartar":
			return await _pay_with_discard_async(payment_option)
		"life", "vida":
			return _pay_with_life(payment_option.cost)

	return false


func _on_payment_cancelled() -> void:
	"""Callback cuando el jugador cancela el pago"""
	_state = PaymentState.CANCELLED
	emit_signal("payment_cancelled", _current_card, "Cancelado por jugador")
	_close_payment_ui()
	print("[PaymentManager] Pago cancelado")


func _close_payment_ui() -> void:
	"""Cierra la UI de pago"""
	if _payment_popup and is_instance_valid(_payment_popup):
		_payment_popup.queue_free()
		_payment_popup = null

	emit_signal("payment_ui_closed")


# =============================================================================
# INTERFAZ DE EXHUMAR - Popup específico
# =============================================================================
func show_exhumar_options(player_id: int) -> void:
	"""Muestra popup con cartas disponibles para Exhumar"""
	var exhumar_cards = scan_cemetery_for_exhumar(player_id)

	if exhumar_cards.is_empty():
		print("[PaymentManager] No hay cartas con Exhumar disponibles")
		return

	_current_player_id = player_id
	_create_exhumar_popup(exhumar_cards)


func _create_exhumar_popup(cards: Array) -> void:
	"""Crea popup de selección de carta Exhumar"""
	if _exhumar_popup and is_instance_valid(_exhumar_popup):
		_exhumar_popup.queue_free()

	_exhumar_popup = Window.new()
	_exhumar_popup.name = "ExhumarPopup"
	_exhumar_popup.title = "💀 EXHUMAR - Jugar desde Cementerio"
	_exhumar_popup.size = Vector2i(400, 350)
	_exhumar_popup.close_requested.connect(_close_exhumar_popup)
	add_child(_exhumar_popup)

	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exhumar_popup.add_child(panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Título
	var title = Label.new()
	title.text = "Cartas jugables desde el Cementerio:"
	title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title)

	# Scroll para cartas
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size.y = 200
	vbox.add_child(scroll)

	var cards_vbox = VBoxContainer.new()
	cards_vbox.add_theme_constant_override("separation", 5)
	scroll.add_child(cards_vbox)

	# Listar cartas
	for i in range(cards.size()):
		var card_info = cards[i]
		var card_btn = _create_exhumar_card_button(card_info, i)
		cards_vbox.add_child(card_btn)

	# Separador y botón cerrar
	vbox.add_child(HSeparator.new())

	var close_btn = Button.new()
	close_btn.text = "Cerrar"
	close_btn.pressed.connect(_close_exhumar_popup)
	vbox.add_child(close_btn)

	_exhumar_popup.popup_centered()


func _create_exhumar_card_button(card_info: Dictionary, index: int) -> Button:
	"""Crea botón para una carta con Exhumar"""
	var btn = Button.new()
	btn.custom_minimum_size.y = 50

	var name = card_info.get("name", "???")
	var cost = card_info.get("exhumar_cost", 0)
	var can_play = card_info.get("can_play", false)

	btn.text = "%s  |  Coste: %d 💰" % [name, cost]
	btn.disabled = not can_play

	if can_play:
		btn.tooltip_text = "Click para jugar via Exhumar"
		btn.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	else:
		btn.tooltip_text = card_info.get("playable_reason", "No se puede jugar")
		btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

	btn.pressed.connect(_on_exhumar_card_selected.bind(index))

	return btn


func _on_exhumar_card_selected(index: int) -> void:
	"""Callback cuando se selecciona una carta para Exhumar"""
	var cards = _exhumar_cache.get(_current_player_id, [])

	if index < 0 or index >= cards.size():
		return

	var card_info = cards[index]

	if not card_info.can_play:
		return

	print("[PaymentManager] 💀 Carta seleccionada para Exhumar: %s" % card_info.name)

	emit_signal("exhumar_card_selected", card_info.card_data, _current_player_id)

	# Mostrar confirmación de pago
	_close_exhumar_popup()
	_show_exhumar_confirmation(card_info)


func _show_exhumar_confirmation(card_info: Dictionary) -> void:
	"""Muestra confirmación final para jugar via Exhumar"""
	var card_data = card_info.card_data
	var cost = card_info.exhumar_cost

	# Crear opciones específicas de Exhumar
	var options = [{
		"method": PaymentMethod.EXHUMAR,
		"label": "💀 Exhumar por %d Oro" % cost,
		"cost": cost,
		"available": card_info.can_afford,
		"description": "Jugar desde el Cementerio. Irá al DESTIERRO tras resolver."
	}]

	_current_card = card_data
	_current_card["via_exhumar"] = true

	show_payment_options(card_data, _current_player_id, options)


func _close_exhumar_popup() -> void:
	"""Cierra el popup de Exhumar"""
	if _exhumar_popup and is_instance_valid(_exhumar_popup):
		_exhumar_popup.queue_free()
		_exhumar_popup = null


# =============================================================================
# CACHE MANAGEMENT
# =============================================================================
func invalidate_cache() -> void:
	"""Invalida el cache de Exhumar (llamar cuando cambia el cementerio)"""
	_cache_dirty = true
	_exhumar_cache.clear()


func _on_card_moved_to_zone(card: Dictionary, from_zone: int, to_zone: int, player_id: int) -> void:
	"""Callback cuando una carta cambia de zona"""
	# Invalidar si involucra el cementerio
	if from_zone == Constants.Zone.CEMENTERIO or to_zone == Constants.Zone.CEMENTERIO:
		invalidate_cache()


func _on_zone_changed(zone: int, player_id: int) -> void:
	"""Callback cuando una zona cambia"""
	if zone == Constants.Zone.CEMENTERIO:
		invalidate_cache()


# =============================================================================
# API PÚBLICA
# =============================================================================
func get_state() -> PaymentState:
	"""Retorna el estado actual del PaymentManager"""
	return _state


func is_awaiting_payment() -> bool:
	"""Retorna si está esperando un pago"""
	return _state in [PaymentState.AWAITING_SELECTION, PaymentState.AWAITING_PAYMENT]


func get_current_card() -> Dictionary:
	"""Retorna la carta actual en proceso de pago"""
	return _current_card


func cancel_current_payment() -> void:
	"""Cancela el pago actual"""
	_on_payment_cancelled()


func has_exhumar_available(player_id: int) -> bool:
	"""Verifica si hay cartas con Exhumar disponibles"""
	var cards = scan_cemetery_for_exhumar(player_id)
	return not cards.is_empty()
