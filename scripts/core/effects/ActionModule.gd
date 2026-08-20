extends Node
## ActionModule - Funciones modulares para acciones de cartas (DAR Sección 8)
## Emite señales para AnimationQueue y maneja triggers simultáneos (DAR 7.4)

# =============================================================================
# SEÑALES PARA ANIMATIONQUEUE
# =============================================================================
## Robar
signal action_draw_started(player_id: int, amount: int, source: String)
signal action_draw_card(player_id: int, card: Node, index: int, total: int)
signal action_draw_completed(player_id: int, cards: Array, actual: int)

## Buscar
signal action_search_started(player_id: int, zone: int, filter: Dictionary)
signal action_search_revealed(player_id: int, matching_cards: Array)
signal action_search_selected(player_id: int, selected: Array)
signal action_search_completed(player_id: int, result: Dictionary)

## Moler (Mill)
signal action_mill_started(player_id: int, amount: int, to_exile: bool)
signal action_mill_card(player_id: int, card: Node, destination: int, index: int)
signal action_mill_completed(player_id: int, cards: Array)

## Destruir
signal action_destroy_started(targets: Array, source: Node)
signal action_destroy_card(card: Node, by_source: Node)
signal action_destroy_completed(destroyed: Array, survived: Array)

## Desterrar (Banish/Exile)
signal action_banish_started(targets: Array, source: Node)
signal action_banish_card(card: Node, from_zone: int)
signal action_banish_completed(banished: Array)

## Descartar
signal action_discard_started(player_id: int, cards: Array)
signal action_discard_card(player_id: int, card: Node, index: int)
signal action_discard_completed(player_id: int, discarded: Array)

## Triggers
signal triggers_collected(active_triggers: Array, opponent_triggers: Array)
signal trigger_resolution_started(trigger: Dictionary)
signal trigger_resolution_completed(trigger: Dictionary, result: Dictionary)

## Validación (DAR Sección 6)
signal action_validation_failed(action_type: String, reason: String, context: Dictionary)
signal action_validation_passed(action_type: String, can_resolve_percent: float)

# =============================================================================
# REFERENCIAS
# =============================================================================
var _game_board: Node = null
var _trigger_system: Node = null
var _anim_queue: Node = null
var _effect_controller: Node = null


func _ready() -> void:
	# Obtener referencias diferidas (por orden de autoloads)
	call_deferred("_get_references")
	print("[ActionModule] Inicializado")


var _damage_manager: Node = null

func _get_references() -> void:
	_trigger_system = get_node_or_null("/root/TriggerSystem")
	_anim_queue = get_node_or_null("/root/AnimationQueue")
	_effect_controller = get_node_or_null("/root/EffectController")
	_damage_manager = get_node_or_null("/root/DamageManager")

	if GameManager:
		_game_board = GameManager.game_board


func _get_game_board() -> Node:
	if _game_board and is_instance_valid(_game_board):
		return _game_board
	if GameManager and GameManager.game_board:
		_game_board = GameManager.game_board
	return _game_board


# =============================================================================
# VALIDACIÓN DE ESTADO DE JUEGO (DAR Sección 6)
# "La acción debe poder resolverse en alguna medida mayor a 0%"
# =============================================================================

func validate_action(action_type: String, params: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Valida si una acción puede resolverse en alguna medida > 0%
	DAR Sección 6: Verificar estado del juego antes de ejecutar

	Args:
		action_type: Tipo de acción (draw, search, mill, destroy, banish, discard)
		params: Parámetros de la acción
		context: Contexto adicional (player_id, source_card, etc.)

	Returns: {
		valid: bool,           # Si la acción puede ejecutarse
		can_resolve: float,    # Porcentaje estimado de resolución (0.0 - 1.0)
		reason: String,        # Razón si no es válida
		warnings: Array        # Advertencias (ejecución parcial probable)
	}
	"""
	var player_id = context.get("player_id", params.get("player_id", 0))

	match action_type:
		"draw":
			return _validate_draw(player_id, params.get("amount", 1))
		"search":
			return _validate_search(player_id, params.get("zone", Constants.Zone.CASTILLO), params.get("filter", {}), params.get("amount", 1))
		"mill":
			return _validate_mill(player_id, params.get("amount", 1))
		"destroy":
			return _validate_destroy(params.get("targets", []), context)
		"banish", "exile":
			return _validate_banish(params.get("targets", []))
		"discard":
			return _validate_discard(player_id, params.get("cards", []), params.get("amount", 0))
		"look":
			return _validate_look(player_id, params.get("amount", 1))
		"return_to_deck":
			return _validate_return_to_deck(params.get("cards", []))
		"damage":
			return _validate_damage(params.get("targets", []), params.get("amount", 1))
		"buff":
			return _validate_buff(params.get("targets", []))
		"shuffle":
			return _validate_shuffle(player_id)
		"virtual_gold":
			return {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}
		_:
			return {"valid": false, "can_resolve": 0.0, "reason": "unknown_action_type", "warnings": []}


func _validate_draw(player_id: int, amount: int) -> Dictionary:
	"""Valida si se puede robar al menos 1 carta"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	var deck_size = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id).size()

	if deck_size == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "deck_empty"
		emit_signal("action_validation_failed", "draw", result.reason, {"player_id": player_id})
		return result

	if deck_size < amount:
		result.can_resolve = float(deck_size) / float(amount)
		result.warnings.append("partial_draw: only %d of %d available" % [deck_size, amount])

	emit_signal("action_validation_passed", "draw", result.can_resolve)
	return result


func _validate_search(player_id: int, zone: int, filter: Dictionary, amount: int) -> Dictionary:
	"""Valida si hay cartas que cumplan el filtro en la zona"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var zone_cards = _get_searchable_zone_data(player_id, zone)
	if zone_cards == null:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "unsupported_zone"
		return result

	if zone_cards.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "zone_empty"
		emit_signal("action_validation_failed", "search", result.reason, {"player_id": player_id, "zone": zone})
		return result

	# Aplicar filtro para ver cuántas coinciden
	var matching = _apply_card_filter(zone_cards, filter)

	if matching.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_matching_cards"
		emit_signal("action_validation_failed", "search", result.reason, {"player_id": player_id, "filter": filter})
		return result

	if matching.size() < amount:
		result.can_resolve = float(matching.size()) / float(amount)
		result.warnings.append("partial_search: only %d of %d matching" % [matching.size(), amount])

	emit_signal("action_validation_passed", "search", result.can_resolve)
	return result


func _validate_mill(player_id: int, amount: int) -> Dictionary:
	"""Valida si hay cartas para moler"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	var deck_size = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id).size()

	if deck_size == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "deck_empty"
		emit_signal("action_validation_failed", "mill", result.reason, {"player_id": player_id})
		return result

	if deck_size < amount:
		result.can_resolve = float(deck_size) / float(amount)
		result.warnings.append("partial_mill: only %d of %d available" % [deck_size, amount])

	emit_signal("action_validation_passed", "mill", result.can_resolve)
	return result


func _validate_destroy(targets: Array, context: Dictionary) -> Dictionary:
	"""Valida si hay objetivos válidos para destruir"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if targets.is_empty():
		# Sin objetivos predefinidos, verificar si hay cartas destruibles en juego
		var board = _get_game_board()
		if board:
			var has_destroyable = false
			for player_id in [0, 1]:
				for zone in Constants.ZONES_IN_PLAY:
					var cards = board.get_cards_in_zone(zone, player_id)
					for card in cards:
						if _can_be_destroyed(card, context.get("source_card", null)):
							has_destroyable = true
							break
					if has_destroyable:
						break
				if has_destroyable:
					break

			if not has_destroyable:
				result.valid = false
				result.can_resolve = 0.0
				result.reason = "no_valid_targets"
				emit_signal("action_validation_failed", "destroy", result.reason, {})
				return result
		else:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "no_game_board"
			return result
	else:
		# Verificar objetivos específicos
		var valid_targets = 0
		for target in targets:
			if is_instance_valid(target) and _can_be_destroyed(target, context.get("source_card", null)):
				valid_targets += 1

		if valid_targets == 0:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "no_valid_targets"
			emit_signal("action_validation_failed", "destroy", result.reason, {"targets": targets})
			return result

		result.can_resolve = float(valid_targets) / float(targets.size())
		if valid_targets < targets.size():
			result.warnings.append("partial_destroy: only %d of %d valid" % [valid_targets, targets.size()])

	emit_signal("action_validation_passed", "destroy", result.can_resolve)
	return result


func _validate_banish(targets: Array) -> Dictionary:
	"""Valida si hay objetivos válidos para desterrar"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if targets.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_targets_specified"
		emit_signal("action_validation_failed", "banish", result.reason, {})
		return result

	var valid_targets = 0
	for target in targets:
		if is_instance_valid(target):
			valid_targets += 1

	if valid_targets == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_targets"
		emit_signal("action_validation_failed", "banish", result.reason, {"targets": targets})
		return result

	result.can_resolve = float(valid_targets) / float(targets.size())
	if valid_targets < targets.size():
		result.warnings.append("partial_banish: only %d of %d valid" % [valid_targets, targets.size()])

	emit_signal("action_validation_passed", "banish", result.can_resolve)
	return result


func _validate_discard(player_id: int, cards: Array, amount: int) -> Dictionary:
	"""Valida si hay cartas para descartar"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	if not cards.is_empty():
		# Cartas específicas
		var valid_cards = 0
		for card in cards:
			if is_instance_valid(card):
				valid_cards += 1

		if valid_cards == 0:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "no_valid_cards"
			emit_signal("action_validation_failed", "discard", result.reason, {})
			return result

		result.can_resolve = float(valid_cards) / float(cards.size())
	elif amount > 0:
		# Cantidad a descartar - verificar mano
		var hand_size = board.get_cards_in_zone(Constants.Zone.MANO, player_id).size()

		if hand_size == 0:
			result.valid = false
			result.can_resolve = 0.0
			result.reason = "hand_empty"
			emit_signal("action_validation_failed", "discard", result.reason, {"player_id": player_id})
			return result

		if hand_size < amount:
			result.can_resolve = float(hand_size) / float(amount)
			result.warnings.append("partial_discard: only %d of %d in hand" % [hand_size, amount])

	emit_signal("action_validation_passed", "discard", result.can_resolve)
	return result


func _validate_look(player_id: int, amount: int) -> Dictionary:
	"""Valida si hay cartas para mirar"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	var deck_size = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id).size()

	if deck_size == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "deck_empty"
		emit_signal("action_validation_failed", "look", result.reason, {"player_id": player_id})
		return result

	if deck_size < amount:
		result.can_resolve = float(deck_size) / float(amount)
		result.warnings.append("partial_look: only %d of %d available" % [deck_size, amount])

	emit_signal("action_validation_passed", "look", result.can_resolve)
	return result


func _validate_return_to_deck(cards: Array) -> Dictionary:
	"""Valida si hay cartas para devolver al mazo"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if cards.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_cards_specified"
		emit_signal("action_validation_failed", "return_to_deck", result.reason, {})
		return result

	var valid_cards = 0
	for card in cards:
		if is_instance_valid(card):
			valid_cards += 1

	if valid_cards == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_cards"
		emit_signal("action_validation_failed", "return_to_deck", result.reason, {})
		return result

	result.can_resolve = float(valid_cards) / float(cards.size())
	emit_signal("action_validation_passed", "return_to_deck", result.can_resolve)
	return result


func _validate_damage(targets: Array, amount: int) -> Dictionary:
	"""Valida si hay objetivos para recibir daño"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if amount <= 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "invalid_damage_amount"
		return result

	if targets.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_targets_specified"
		emit_signal("action_validation_failed", "damage", result.reason, {})
		return result

	var valid_targets = 0
	for target in targets:
		if is_instance_valid(target):
			valid_targets += 1

	if valid_targets == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_targets"
		emit_signal("action_validation_failed", "damage", result.reason, {})
		return result

	result.can_resolve = float(valid_targets) / float(targets.size())
	emit_signal("action_validation_passed", "damage", result.can_resolve)
	return result


func _validate_buff(targets: Array) -> Dictionary:
	"""Valida si hay objetivos para buff/debuff"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	if targets.is_empty():
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_targets_specified"
		emit_signal("action_validation_failed", "buff", result.reason, {})
		return result

	var valid_targets = 0
	for target in targets:
		if is_instance_valid(target):
			valid_targets += 1

	if valid_targets == 0:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_valid_targets"
		emit_signal("action_validation_failed", "buff", result.reason, {})
		return result

	result.can_resolve = float(valid_targets) / float(targets.size())
	emit_signal("action_validation_passed", "buff", result.can_resolve)
	return result


func _validate_shuffle(player_id: int) -> Dictionary:
	"""Valida si se puede barajar (siempre válido si hay mazo)"""
	var result = {"valid": true, "can_resolve": 1.0, "reason": "", "warnings": []}

	var board = _get_game_board()
	if not board:
		result.valid = false
		result.can_resolve = 0.0
		result.reason = "no_game_board"
		return result

	# Barajar siempre es válido, incluso con 0 cartas (no hace nada pero es válido)
	emit_signal("action_validation_passed", "shuffle", result.can_resolve)
	return result


func _can_be_destroyed(card: Node, source: Node) -> bool:
	"""Verifica si una carta puede ser destruida.
	Pasa por KeywordManager.can_be_destroyed() (igual que BattleManager) en vez
	de leer card.has_keyword() directo — si no, un silenciado que le quite
	Indestructible vía KeywordManager no se respetaría acá."""
	if not is_instance_valid(card):
		return false

	var kw_mgr = get_node_or_null("/root/KeywordManager")
	if kw_mgr and kw_mgr.has_method("can_be_destroyed"):
		if not kw_mgr.can_be_destroyed(card):
			return false
	elif card.has_method("has_keyword") and card.has_keyword(Constants.Keyword.INDESTRUCTIBLE):
		return false

	# Verificar protección contra la fuente
	if source and card.has_method("has_protection_from"):
		if card.has_protection_from(source):
			return false

	return true


# =============================================================================
# DRAW - Robar cartas (DAR Sección 8)
# =============================================================================
func draw(player_id: int, amount: int, source: String = "", skip_validation: bool = false) -> Dictionary:
	"""Roba cartas del Castillo a la Mano, una a una
	DAR: 'En medida de lo posible' - roba hasta que el mazo se vacíe
	DAR 2.1: Si intenta robar con mazo vacío, PIERDE
	DAR Sección 6: Valida que puede resolverse en alguna medida > 0%

	Args:
		player_id: ID del jugador que roba
		amount: Cantidad de cartas a robar
		source: Origen del robo (para triggers)
		skip_validation: Si omitir validación previa

	Returns: {success, cards, actual, deck_empty, triggered_loss}
	"""
	var result = {
		"success": true,
		"cards": [],
		"requested": amount,
		"actual": 0,
		"deck_empty": false,
		"triggered_loss": false
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _validate_draw(player_id, amount)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] DRAW rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _get_game_board()
	if not board:
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) — usar el
		# camino real del juego en vez de fallar en silencio.
		return await _draw_fallback(player_id, amount, source)

	# Iniciar recolección de triggers
	_begin_trigger_collection()

	emit_signal("action_draw_started", player_id, amount, source)

	# Añadir comando a AnimationQueue
	if _anim_queue:
		_anim_queue.add_command(AnimationQueue.CommandType.SHOW_MESSAGE, {
			"text": "Robando %d carta(s)..." % amount,
			"duration": 0.5
		})

	var deck_cards = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

	for i in range(amount):
		if deck_cards.is_empty():
			result.deck_empty = true
			# DAR 2.1: Intentar robar con mazo vacío = PERDER
			if i == 0 and amount > 0:
				result.triggered_loss = true
				result.success = false
				print("[ActionModule] DERROTA: Jugador %d intentó robar con mazo vacío" % player_id)
				# Usar DamageManager si existe, fallback a GameManager
				if _damage_manager and _damage_manager.has_method("check_defeat_condition"):
					_damage_manager.check_defeat_condition(player_id)
				elif GameManager:
					GameManager.trigger_loss(player_id, "deck_empty")
			break

		# Tomar carta del tope
		var card = deck_cards.pop_front()

		# Emitir señal individual para animación
		emit_signal("action_draw_card", player_id, card, i, amount)

		# Añadir animación
		if _anim_queue:
			_anim_queue.add_command(AnimationQueue.CommandType.DRAW_CARD, {
				"card": card,
				"player_id": player_id,
				"from_zone": Constants.Zone.CASTILLO,
				"to_zone": Constants.Zone.MANO
			})

		# Mover carta
		board.move_card(card, Constants.Zone.MANO, player_id)
		card.esta_oculta = false

		result.cards.append(card)
		result.actual += 1

		# Notificar trigger on_draw
		_notify_trigger("on_draw", {
			"player_id": player_id,
			"card": card,
			"source": source
		})

	emit_signal("action_draw_completed", player_id, result.cards, result.actual)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE EFECTO PARCIAL (DAR Sección 6 - "en medida de lo posible")
	# ─────────────────────────────────────────────────────────────────────────
	if result.actual < result.requested and result.actual > 0:
		var combat_log = get_node_or_null("/root/CombatLog")
		if combat_log and combat_log.has_method("log_partial_draw"):
			combat_log.log_partial_draw(result.requested, result.actual, player_id)
		result.partial = true

	# Finalizar y procesar triggers
	await _end_trigger_collection_and_resolve()

	return result


func _draw_fallback(player_id: int, amount: int, source: String) -> Dictionary:
	"""GameBoard legacy no disponible — usa Main.draw_card(), el camino que
	realmente mueve cartas en la escena actual (ver docs/audit, hallazgo 2/4).
	Limitación conocida: sin nodos de Card trackeados por zona no hay
	animación de robo individual ni 'cards' poblado, pero el conteo y la
	derrota por Castillo vacío (DAR 2.1) sí se aplican de verdad."""
	var result = {
		"success": true, "cards": [], "requested": amount, "actual": 0,
		"deck_empty": false, "triggered_loss": false
	}
	var main = get_node_or_null("/root/Main")
	if not main or not main.has_method("draw_card"):
		result.success = false
		result.error = "no_main"
		return result

	for i in range(amount):
		var drew: bool = await main.draw_card(player_id)
		if not drew:
			result.deck_empty = true
			if i == 0:
				result.triggered_loss = true
				result.success = false
			break
		result.actual += 1

	if result.actual < result.requested and result.actual > 0:
		result.partial = true

	return result


# =============================================================================
# SEARCH - Buscar en zona (DAR Sección 8)
# =============================================================================
func _get_searchable_zone_data(player_id: int, zone: int) -> Variant:
	"""Devuelve el Array de datos (Dictionary) de la zona buscable, o null si
	la zona no es buscable. El Castillo y el Cementerio son las únicas zonas
	con datos de carta reales (no nodos) — Mano/Campo son nodos Card, y
	buscar ahí no tiene sentido en DAR (ya están a la vista).
	Se lee vía CardManager, que está sincronizado por referencia con
	Main.player_deck/player_cemetery (ver CardManager.sync_from_main) — así
	que remover una entrada acá remueve la carta de verdad."""
	var cm := get_node_or_null("/root/CardManager")
	if not cm:
		return null
	match zone:
		Constants.Zone.CASTILLO:
			return cm.get_deck(player_id)
		Constants.Zone.CEMENTERIO:
			return cm.get_cemetery(player_id)
		_:
			return null


func shuffle_deck(player_id: int) -> void:
	"""Baraja el Castillo (mazo) de un jugador — vía CardManager, sincronizado
	por referencia con Main.player_deck/opponent_deck (ver sync_from_main)."""
	var cm := get_node_or_null("/root/CardManager")
	if cm and cm.has_method("shuffle_deck"):
		cm.shuffle_deck(player_id)
	else:
		push_warning("[ActionModule] No se pudo barajar: CardManager no disponible")


func search(player_id: int, zone: int, filter: Dictionary, amount: int = 1, can_fail: bool = true, skip_validation: bool = false, may_play: bool = false, source_card: Node = null) -> Dictionary:
	"""Busca cartas en el Castillo o Cementerio que cumplan el filtro (DAR
	Sección 8). El jugador elige cuáles llevarse (o todas, si hay menos que
	amount). Si may_play es true, cada carta encontrada se juega de inmediato
	pagando su coste normal en vez de ir a la mano (si no se puede pagar,
	queda en la mano igual — nunca se pierde la carta encontrada).

	Args:
		player_id: ID del jugador
		zone: Zona donde buscar (CASTILLO o CEMENTERIO — únicas zonas con datos)
		filter: Filtro de cartas {type, raza, cost_max, cost_min, strength_min,
			name_contains, keyword}
		amount: Cantidad máxima a seleccionar
		can_fail: Si puede fallar sin encontrar (false = obligatorio)
		skip_validation: Si omitir validación previa
		may_play: Si true, intenta jugar cada carta encontrada en vez de solo
			guardarla en mano (DAR: 'puedes ponerla en juego pagando su coste')
		source_card: Carta que causa la búsqueda (para triggers/log)

	Returns: {success, selected, matching, searched_zone}
	"""
	var result = {
		"success": true,
		"selected": [],
		"matching": [],
		"searched_zone": zone,
		"must_shuffle": zone == Constants.Zone.CASTILLO
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _validate_search(player_id, zone, filter, amount)
		if not validation.valid:
			result.success = can_fail
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] SEARCH rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var zone_data = _get_searchable_zone_data(player_id, zone)
	if zone_data == null:
		push_warning("[ActionModule] SEARCH: zona no buscable (%s)" % zone)
		result.success = false
		result.error = "unsupported_zone"
		return result

	_begin_trigger_collection()

	emit_signal("action_search_started", player_id, zone, filter)

	# Aplicar filtro sobre los datos de la zona
	var matching: Array = _apply_card_filter(zone_data, filter)
	result.matching = matching

	emit_signal("action_search_revealed", player_id, matching)

	if matching.is_empty():
		result.success = can_fail
		if not can_fail:
			result.error = "no_matching_cards"
		emit_signal("action_search_completed", player_id, result)
		await _end_trigger_collection_and_resolve()
		return result

	# Si hay cartas, el jugador debe elegir (o se toman todas si hay ≤ amount)
	var to_select = mini(amount, matching.size())
	var selected_data: Array = await _select_search_results(matching, to_select)
	result.selected = selected_data

	emit_signal("action_search_selected", player_id, selected_data)

	var main := get_node_or_null("/root/Main")
	for card_data in selected_data:
		# Remover de la zona de origen (misma referencia que Main.player_deck/
		# player_cemetery — ver _get_searchable_zone_data).
		zone_data.erase(card_data)
		card_data["esta_oculta"] = false

		if main:
			var card_node = await _put_found_card_into_play(main, player_id, card_data, may_play)
			_notify_trigger("on_search_found", {
				"player_id": player_id, "card": card_node, "from_zone": zone
			})

	# Barajar si buscó en el Castillo (DAR: siempre se baraja tras buscar en el mazo)
	if result.must_shuffle:
		zone_data.shuffle()
		if _anim_queue:
			_anim_queue.add_command(AnimationQueue.CommandType.CUSTOM, {
				"callable": Callable(_anim_queue, "animate_shuffle").bind(player_id),
				"description": "Barajar mazo"
			})

	emit_signal("action_search_completed", player_id, result)

	await _end_trigger_collection_and_resolve()

	return result


func _select_search_results(matching: Array, to_select: int) -> Array:
	"""Abre el overlay de selección (SelectionManager) y espera a que el
	jugador elija. Si hay ≤ to_select coincidencias, se toman todas sin
	abrir UI. Si el jugador cancela, no se toma ninguna.

	IMPORTANTE: con max_selections == 1, SelectionManager cierra en el
	primer clic y emite 'card_selected' (un solo Dictionary) en vez de
	'selection_completed' (un Array) — hay que escuchar ambas señales o el
	await se queda colgado para siempre (mismo caso ya resuelto en
	SelectionModule.open_discard_selection())."""
	if to_select >= matching.size():
		return matching.duplicate()

	var sel_mgr = get_node_or_null("/root/SelectionManager")
	if not sel_mgr or not sel_mgr.has_method("open_search"):
		return matching.slice(0, to_select)

	var picked: Array = []
	var resolved := false
	var on_completed := func(cards: Array):
		picked = cards
		resolved = true
	var on_single_selected := func(card_data: Dictionary):
		picked = [card_data]
		resolved = true
	var on_cancelled := func():
		resolved = true

	sel_mgr.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
	sel_mgr.card_selected.connect(on_single_selected, CONNECT_ONE_SHOT)
	sel_mgr.selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
	sel_mgr.open_search(matching, to_select)

	while not resolved:
		await get_tree().process_frame

	if sel_mgr.selection_completed.is_connected(on_completed):
		sel_mgr.selection_completed.disconnect(on_completed)
	if sel_mgr.card_selected.is_connected(on_single_selected):
		sel_mgr.card_selected.disconnect(on_single_selected)
	if sel_mgr.selection_cancelled.is_connected(on_cancelled):
		sel_mgr.selection_cancelled.disconnect(on_cancelled)

	return picked


func _put_found_card_into_play(main: Node, player_id: int, card_data: Dictionary, may_play: bool) -> Node:
	"""Instancia la carta encontrada y la mete en juego: a la mano, o jugada
	de inmediato (pagando su coste normal) si may_play lo pide y se puede
	pagar. Mismo patrón que ZoneManager.draw_card()/MulliganController — la
	única forma real de que una carta aparezca en la mano/campo de verdad."""
	var is_hidden := player_id != 0
	var card_node = main._create_card(card_data, is_hidden)

	if player_id == 0:
		main.player_hand.add_card(card_node)
		main._connect_card_signals(card_node)
	else:
		main._opponent_fan.add_card(card_node)

	if may_play and player_id == 0:
		await get_tree().create_timer(0.3).timeout
		if PaymentManager.puede_jugar_carta(card_node, player_id):
			await main.play_card(card_node)
		# Si no puede pagarla, se queda en la mano — nunca se pierde.

	return card_node


# =============================================================================
# MILL - Moler cartas (DAR Sección 8)
# =============================================================================
func mill(player_id: int, amount: int, to_exile: bool = false, source: String = "", skip_validation: bool = false) -> Dictionary:
	"""Envía cartas del tope del Castillo al Cementerio/Destierro

	Args:
		player_id: ID del jugador afectado
		amount: Cantidad de cartas a moler
		to_exile: Si true, van al Destierro en vez del Cementerio
		source: Origen del efecto
		skip_validation: Si omitir validación previa

	Returns: {success, cards, actual, destination}
	"""
	var destination = Constants.Zone.DESTIERRO if to_exile else Constants.Zone.CEMENTERIO
	var result = {
		"success": true,
		"cards": [],
		"requested": amount,
		"actual": 0,
		"destination": destination
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _validate_mill(player_id, amount)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] MILL rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _get_game_board()
	if not board:
		# GameBoard legacy no disponible — delegar en el fallback de
		# EffectController.mill_cards() (ver docs/audit, hallazgo 2/4).
		var effect_ctrl = get_node_or_null("/root/EffectController")
		if effect_ctrl:
			var ec_result: Dictionary = await effect_ctrl.mill_cards(player_id, amount, destination)
			result.success = ec_result.get("success", false)
			result.actual = ec_result.get("actual", 0)
			if result.actual < result.requested and result.actual > 0:
				result.partial = true
		else:
			result.success = false
		return result

	_begin_trigger_collection()

	emit_signal("action_mill_started", player_id, amount, to_exile)

	var deck_cards = board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

	for i in range(amount):
		if deck_cards.is_empty():
			break

		var card = deck_cards.pop_front()

		emit_signal("action_mill_card", player_id, card, destination, i)

		if _anim_queue:
			_anim_queue.add_command(AnimationQueue.CommandType.MILL_CARD, {
				"card": card,
				"player_id": player_id,
				"to_exile": to_exile,
				"index": i
			})

		# Revelar la carta antes de enviarla
		card.esta_oculta = false

		board.move_card(card, destination, player_id)
		result.cards.append(card)
		result.actual += 1

		# Trigger según destino
		var trigger_type = "on_exiled" if to_exile else "on_milled"
		_notify_trigger(trigger_type, {
			"player_id": player_id,
			"card": card,
			"from_zone": Constants.Zone.CASTILLO,
			"source": source
		})

	emit_signal("action_mill_completed", player_id, result.cards)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE EFECTO PARCIAL (DAR Sección 6 - "en medida de lo posible")
	# ─────────────────────────────────────────────────────────────────────────
	if result.actual < result.requested and result.actual > 0:
		var combat_log = get_node_or_null("/root/CombatLog")
		if combat_log and combat_log.has_method("log_partial_mill"):
			combat_log.log_partial_mill(result.requested, result.actual, player_id, result.cards)
		result.partial = true

	# ─────────────────────────────────────────────────────────────────────────
	# DETECCIÓN DE DERROTA: Verificar si el mazo quedó vacío
	# ─────────────────────────────────────────────────────────────────────────
	if _damage_manager and _damage_manager.has_method("check_defeat_condition"):
		result.defeated = _damage_manager.check_defeat_condition(player_id)

	await _end_trigger_collection_and_resolve()

	return result


# =============================================================================
# DESTROY - Destruir cartas (DAR Sección 8)
# =============================================================================
func destroy(targets: Array, source: Node = null, can_be_prevented: bool = true, skip_validation: bool = false) -> Dictionary:
	"""Destruye cartas, enviándolas al Cementerio

	Args:
		targets: Array de cartas a destruir
		source: Carta/efecto que causa la destrucción
		can_be_prevented: Si puede ser prevenida por efectos
		skip_validation: Si omitir validación previa

	Returns: {success, destroyed, survived, prevented}
	"""
	var result = {
		"success": true,
		"destroyed": [],
		"survived": [],
		"prevented": []
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _validate_destroy(targets, {"source_card": source})
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] DESTROY rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _get_game_board()

	_begin_trigger_collection()

	emit_signal("action_destroy_started", targets, source)

	for target in targets:
		if not is_instance_valid(target):
			continue

		var can_destroy = true
		var prevented_by = null

		# Verificar si puede ser prevenida
		if can_be_prevented:
			var prevention = _check_destruction_prevention(target, source)
			if prevention.prevented:
				can_destroy = false
				prevented_by = prevention.prevented_by
				result.prevented.append({"card": target, "by": prevented_by})

		if can_destroy:
			var from_zone = target.current_zone if target.get("current_zone") != null else Constants.Zone.LINEA_DEFENSA
			var owner_id = target.owner_id if target.get("owner_id") != null else 0

			# Trigger antes de destruir
			_notify_trigger("on_about_to_die", {
				"card": target,
				"source": source,
				"from_zone": from_zone
			})

			emit_signal("action_destroy_card", target, source)

			if _anim_queue:
				_anim_queue.add_command(AnimationQueue.CommandType.DESTROY_CARD, {
					"card": target,
					"source": source,
					"from_zone": from_zone
				})

			# ─────────────────────────────────────────────────────────────────
			# FLAG EXHUMAR: Cartas jugadas via Exhumar van a DESTIERRO
			# ─────────────────────────────────────────────────────────────────
			var destination = Constants.Zone.CEMENTERIO
			var card_data = target.get("card_data") if target.has_method("get") else target
			if card_data is Dictionary:
				if card_data.get("_exhumar_flag", false):
					destination = Constants.Zone.DESTIERRO
					print("[ActionModule] 💀 Carta con Exhumar destruida → DESTIERRO")
				elif card_data.get("_force_destination", -1) == Constants.Zone.DESTIERRO:
					destination = Constants.Zone.DESTIERRO

			if board:
				board.move_card(target, destination, owner_id)
			else:
				# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) —
				# EffectController.destroy_card()/exile_card() ya respetan la
				# regla de exhumación (is_exhumed) y mantienen los contadores
				# de UI sincronizados vía CardManager.
				var effect_ctrl = get_node_or_null("/root/EffectController")
				if effect_ctrl:
					if destination == Constants.Zone.DESTIERRO:
						await effect_ctrl.exile_card(owner_id, target)
					else:
						await effect_ctrl.destroy_card(owner_id, target)
			result.destroyed.append(target)

			# Trigger después de destruir
			_notify_trigger("on_destroyed", {
				"card": target,
				"source": source,
				"owner_id": owner_id
			})
		else:
			result.survived.append(target)

	emit_signal("action_destroy_completed", result.destroyed, result.survived)

	await _end_trigger_collection_and_resolve()

	return result


# =============================================================================
# BANISH - Desterrar cartas (DAR Sección 8)
# =============================================================================
func banish(targets: Array, source: Node = null, skip_validation: bool = false) -> Dictionary:
	"""Destierra cartas, enviándolas al Destierro (zona de exilio)
	Las cartas desterradas no pueden ser recuperadas por medios normales

	Args:
		targets: Array de cartas a desterrar
		source: Carta/efecto que causa el destierro
		skip_validation: Si omitir validación previa

	Returns: {success, banished, failed}
	"""
	var result = {
		"success": true,
		"banished": [],
		"failed": []
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _validate_banish(targets)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] BANISH rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _get_game_board()

	_begin_trigger_collection()

	emit_signal("action_banish_started", targets, source)

	for target in targets:
		if not is_instance_valid(target):
			result.failed.append({"card": target, "reason": "invalid"})
			continue

		var from_zone = target.current_zone if target.get("current_zone") != null else -1
		var owner_id = target.owner_id if target.get("owner_id") != null else 0

		emit_signal("action_banish_card", target, from_zone)

		if _anim_queue:
			_anim_queue.add_command(AnimationQueue.CommandType.EXILE_CARD, {
				"card": target,
				"source": source,
				"from_zone": from_zone
			})

		if board:
			board.move_card(target, Constants.Zone.DESTIERRO, owner_id)
		else:
			# GameBoard legacy no disponible (docs/audit, hallazgo 2/4)
			var effect_ctrl = get_node_or_null("/root/EffectController")
			if effect_ctrl:
				await effect_ctrl.exile_card(owner_id, target)
		result.banished.append(target)

		_notify_trigger("on_exiled", {
			"card": target,
			"source": source,
			"owner_id": owner_id,
			"from_zone": from_zone
		})

	emit_signal("action_banish_completed", result.banished)

	await _end_trigger_collection_and_resolve()

	return result


# =============================================================================
# DISCARD - Descartar cartas (DAR Sección 8)
# =============================================================================
func discard(player_id: int, cards: Array, source: String = "", skip_validation: bool = false) -> Dictionary:
	"""Descarta cartas de la mano al cementerio

	Args:
		player_id: ID del jugador que descarta
		cards: Array de cartas a descartar
		source: Origen del descarte
		skip_validation: Si omitir validación previa

	Returns: {success, discarded, actual}
	"""
	var result = {
		"success": true,
		"discarded": [],
		"actual": 0
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _validate_discard(player_id, cards, 0)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] DISCARD rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _get_game_board()

	_begin_trigger_collection()

	emit_signal("action_discard_started", player_id, cards)

	for i in range(cards.size()):
		var card = cards[i]
		if not is_instance_valid(card):
			continue

		emit_signal("action_discard_card", player_id, card, i)

		if _anim_queue:
			_anim_queue.add_command(AnimationQueue.CommandType.DISCARD_CARD, {
				"card": card,
				"player_id": player_id,
				"index": i
			})

		card.esta_oculta = false
		if not board:
			# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) —
			# mismo camino que PhaseFlowController._opponent_auto_discard()/
			# SelectionModule.open_discard_selection(): sacar la carta de la
			# mano real y mandar sus datos al cementerio vía CardManager.
			_discard_card_fallback(player_id, card)
			result.discarded.append(card)
			result.actual += 1
			_notify_trigger("on_discard", {"player_id": player_id, "card": card, "source": source})
			continue
		board.move_card(card, Constants.Zone.CEMENTERIO, player_id)
		result.discarded.append(card)
		result.actual += 1

		_notify_trigger("on_discard", {
			"player_id": player_id,
			"card": card,
			"source": source
		})

	emit_signal("action_discard_completed", player_id, result.discarded)

	await _end_trigger_collection_and_resolve()

	return result


func _discard_card_fallback(player_id: int, card: Node) -> void:
	"""Descarta una carta de la mano real al Cementerio sin pasar por el
	GameBoard legacy (siempre null) — mismo camino usado por
	PhaseFlowController._opponent_auto_discard()/SelectionModule.
	open_discard_selection()."""
	var data: Dictionary = card.card_data.duplicate() if card.get("card_data") else {}
	data["esta_oculta"] = false
	var cm := get_node_or_null("/root/CardManager")
	if cm:
		cm.add_to_cemetery(player_id, data)
	var main := get_node_or_null("/root/Main")
	if player_id == 0 and main and main.player_hand and main.player_hand.has_method("remove_card"):
		main.player_hand.remove_card(card, true)
	elif main and main.get("_opponent_fan") and main._opponent_fan.has_method("remove_card"):
		main._opponent_fan.remove_card(card, true)
	if not cm and main:
		if player_id == 0:
			main.player_cemetery.append(data)
			UIManager.update_cementerio_count(0, main.player_cemetery.size())
		else:
			main.opponent_cemetery.append(data)
			UIManager.update_cementerio_count(1, main.opponent_cemetery.size())


# =============================================================================
# SISTEMA DE TRIGGERS SIMULTÁNEOS (DAR 7.4)
# =============================================================================
var _collecting_triggers: bool = false
var _collected_triggers: Array[Dictionary] = []


func _begin_trigger_collection() -> void:
	"""Inicia la recolección de triggers para una acción"""
	_collecting_triggers = true
	_collected_triggers.clear()

	if _trigger_system:
		_trigger_system.begin_collecting()


func _notify_trigger(trigger_type: String, event_data: Dictionary) -> void:
	"""Notifica un trigger al sistema"""
	if not _collecting_triggers:
		return

	# Buscar cartas que reaccionen a este trigger
	var board = _get_game_board()
	if not board:
		return

	# Revisar cartas en juego de ambos jugadores
	for player_id in [0, 1]:
		for zone in Constants.ZONES_IN_PLAY:
			var cards = board.get_cards_in_zone(zone, player_id)
			for card in cards:
				if card.has_method("has_trigger") and card.has_trigger(trigger_type):
					# Verificar condiciones del trigger
					if card.has_method("_trigger_conditions_met"):
						if not card._trigger_conditions_met(trigger_type, event_data):
							continue

					var trigger_data = {
						"card": card,
						"trigger_type": trigger_type,
						"event_data": event_data,
						"controller_id": card.controller_id if card.get("controller_id") != null else player_id
					}

					_collected_triggers.append(trigger_data)

					if _trigger_system:
						_trigger_system.register_trigger(card, trigger_type, event_data)


func _end_trigger_collection_and_resolve() -> void:
	"""Finaliza recolección y resuelve triggers en orden (DAR 7.4)"""
	_collecting_triggers = false

	if _collected_triggers.is_empty():
		return

	# Ordenar triggers: primero jugador activo, luego oponente
	var active_player = 0
	if GameManager:
		active_player = GameManager.active_player_id

	var active_triggers: Array = []
	var opponent_triggers: Array = []

	for trigger in _collected_triggers:
		if trigger.controller_id == active_player:
			active_triggers.append(trigger)
		else:
			opponent_triggers.append(trigger)

	emit_signal("triggers_collected", active_triggers, opponent_triggers)

	# Finalizar recolección en TriggerSystem
	if _trigger_system:
		_trigger_system.end_collecting_and_queue()

	# Resolver triggers
	await _resolve_collected_triggers(active_triggers + opponent_triggers)

	_collected_triggers.clear()


func _resolve_collected_triggers(triggers: Array) -> void:
	"""Resuelve la cola de triggers recolectados"""
	for trigger in triggers:
		emit_signal("trigger_resolution_started", trigger)

		var result = {"success": true}
		var card = trigger.get("card")

		if is_instance_valid(card) and card.has_method("_on_trigger_event"):
			result = await card._on_trigger_event(trigger.trigger_type, trigger.event_data)

		emit_signal("trigger_resolution_completed", trigger, result)

		# Pequeña pausa entre triggers para animaciones
		if _anim_queue:
			await _anim_queue.wait_until_empty()


# =============================================================================
# UTILIDADES
# =============================================================================
func _apply_card_filter(cards: Array, filter: Dictionary) -> Array:
	"""Aplica un filtro a un array de datos de carta (Dictionary, claves en
	español — 'tipo'/'coste'/'raza'/'fuerza'/'nombre'/'keywords'). El Castillo
	y el Cementerio se guardan como datos, no como nodos Card (ver CardManager),
	así que el filtro lee las mismas claves que usa CardFactory/GameBootstrap
	al construir esos diccionarios."""
	if filter.is_empty():
		return cards.duplicate()

	var matching: Array = []

	for card_data in cards:
		var matches = true

		# Filtro por tipo
		if filter.has("type"):
			var card_type = card_data.get("tipo", -1)
			if card_type != filter.type:
				matches = false

		# Filtro por raza
		if matches and filter.has("raza"):
			var card_raza: String = card_data.get("raza", "")
			if card_raza.to_lower() != String(filter.raza).to_lower():
				matches = false

		# Filtro por coste máximo
		if matches and filter.has("cost_max"):
			var card_cost = card_data.get("coste", 0)
			if card_cost > filter.cost_max:
				matches = false

		# Filtro por coste mínimo
		if matches and filter.has("cost_min"):
			var card_cost = card_data.get("coste", 0)
			if card_cost < filter.cost_min:
				matches = false

		# Filtro por fuerza
		if matches and filter.has("strength_min"):
			var strength = card_data.get("fuerza", 0)
			if strength < filter.strength_min:
				matches = false

		# Filtro por nombre (contiene)
		if matches and filter.has("name_contains"):
			var card_name: String = card_data.get("nombre", "")
			if not String(filter.name_contains).to_lower() in card_name.to_lower():
				matches = false

		# Filtro por keyword (lista cruda del dato — sin instanciar la carta
		# no hay acceso a KeywordManager, así que solo se ve lo impreso)
		if matches and filter.has("keyword"):
			var keywords: Array = card_data.get("keywords", [])
			if filter.keyword not in keywords:
				matches = false

		if matches:
			matching.append(card_data)

	return matching


func _check_destruction_prevention(target: Node, source: Node) -> Dictionary:
	"""Verifica si la destrucción puede ser prevenida"""
	var result = {"prevented": false, "prevented_by": null}

	# Verificar indestructible
	if target.has_method("has_keyword") and target.has_keyword(Constants.Keyword.INDESTRUCTIBLE):
		result.prevented = true
		result.prevented_by = target
		return result

	# Verificar protección
	if target.has_method("has_protection_from"):
		if source and target.has_protection_from(source):
			result.prevented = true
			result.prevented_by = target
			return result

	# TODO: Verificar efectos de otras cartas que prevengan destrucción

	return result
