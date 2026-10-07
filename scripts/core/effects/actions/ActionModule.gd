extends Node
## ActionModule - Funciones modulares para acciones de cartas (DAR Sección 8)
## Emite señales para AnimationQueue y maneja triggers simultáneos (DAR 7.4)
## Cada verbo (Draw/Search/Mill/Destroy/Banish/ReturnDeck+Discard) vive en su
## propio módulo extraído (Fase 4 de reestructuración, "módulos gordos") —
## ActionModule.gd se queda con las señales, las referencias compartidas
## (game board, validador, filtro de cartas, recolección de triggers) y
## forwarders finos con el nombre/firma exactos de antes, así que ningún
## llamador externo (65x draw, 36x search, 23x return_to_deck, 19x destroy,
## 18x discard, 15x banish, 12x mill en todo el proyecto) necesita cambiar.

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

## Módulos extraídos (Fase 4 de reestructuración)
var _validator: ActionValidator
var _action_draw: RefCounted
var _action_search: RefCounted
var _action_mill: RefCounted
var _action_destroy: RefCounted
var _action_banish: RefCounted
var _action_return_discard: RefCounted


func _ready() -> void:
	_validator = ActionValidator.new()
	_validator.setup(self)

	_action_draw = preload("res://scripts/core/effects/actions/ActionDraw.gd").new()
	_action_draw.setup(self)
	_action_search = preload("res://scripts/core/effects/actions/ActionSearch.gd").new()
	_action_search.setup(self)
	_action_mill = preload("res://scripts/core/effects/actions/ActionMill.gd").new()
	_action_mill.setup(self)
	_action_destroy = preload("res://scripts/core/effects/actions/ActionDestroy.gd").new()
	_action_destroy.setup(self)
	_action_banish = preload("res://scripts/core/effects/actions/ActionBanish.gd").new()
	_action_banish.setup(self)
	_action_return_discard = preload("res://scripts/core/effects/actions/ActionReturnDiscard.gd").new()
	_action_return_discard.setup(self)

	# Obtener referencias diferidas (por orden de autoloads)
	call_deferred("_get_references")
	print("[ActionModule] Inicializado")


func _get_references() -> void:
	# (2026-08-28, "módulos gordos" punto 1): TriggerSystem/AnimationQueue/
	# DamageManager son autoloads garantizados — se sacó el cacheo redundante
	# vía get_node_or_null() (EffectController se cacheaba pero nunca se
	# usaba en este archivo).
	if GameManager:
		_game_board = GameManager.game_board


func _get_game_board() -> Node:
	if _game_board and is_instance_valid(_game_board):
		return _game_board
	if GameManager and GameManager.game_board:
		_game_board = GameManager.game_board
	return _game_board


# =============================================================================
# VALIDACIÓN DE ESTADO DE JUEGO (implementación en ActionValidator.gd)
# =============================================================================
func validate_action(action_type: String, params: Dictionary, context: Dictionary = {}) -> Dictionary:
	return _validator.validate_action(action_type, params, context)


# =============================================================================
# DRAW - Robar cartas (implementación en ActionDraw.gd)
# =============================================================================
func draw(player_id: int, amount: int, source: String = "", skip_validation: bool = false) -> Dictionary:
	return await _action_draw.draw(player_id, amount, source, skip_validation)


# =============================================================================
# SEARCH - Buscar en zona (implementación en ActionSearch.gd)
# =============================================================================
func shuffle_deck(player_id: int) -> void:
	"""Baraja el Castillo (mazo) de un jugador — vía CardManager, sincronizado
	por referencia con Main.player_deck/opponent_deck (ver sync_from_main).
	Barajar no cambia el TAMAÑO del mazo, pero sí cambia qué carta queda en
	el tope (índice 0) — refresca ZoneManager._update_castillo_counts() aquí
	(2026-09-14, a pedido del usuario: La Ouija, 'del tope de tu Castillo',
	quedaba mostrando la carta vieja tras un barajado que pasaba por este
	wrapper genérico en vez del CardManager.shuffle_deck() + refresco manual
	que ya usa la mayoría de los archivos de triggers) — único punto de
	verdad para TODOS los llamadores de esta función, actuales y futuros."""
	CardManager.shuffle_deck(player_id)
	var main := get_node_or_null("/root/Main")
	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()


func search(player_id: int, zone: int, filter: Dictionary, amount: int = 1, can_fail: bool = true, skip_validation: bool = false, may_play: bool = false, source_card: Node = null, destination: int = Constants.Zone.MANO, distinct_names: bool = false, chooser_id: int = -1) -> Dictionary:
	return await _action_search.search(player_id, zone, filter, amount, can_fail, skip_validation, may_play, source_card, destination, distinct_names, chooser_id)


# =============================================================================
# MILL - Moler cartas (implementación en ActionMill.gd)
# =============================================================================
func mill(player_id: int, amount: int, to_exile: bool = false, source: String = "", skip_validation: bool = false) -> Dictionary:
	return await _action_mill.mill(player_id, amount, to_exile, source, skip_validation)


# =============================================================================
# DESTROY - Destruir cartas (implementación en ActionDestroy.gd)
# =============================================================================
func destroy(targets: Array, source: Node = null, can_be_prevented: bool = true, skip_validation: bool = false) -> Dictionary:
	return await _action_destroy.destroy(targets, source, can_be_prevented, skip_validation)


# =============================================================================
# BANISH - Desterrar cartas (implementación en ActionBanish.gd)
# =============================================================================
func banish(targets: Array, source: Node = null, skip_validation: bool = false, can_be_prevented: bool = true) -> Dictionary:
	return await _action_banish.banish(targets, source, skip_validation, can_be_prevented)


# =============================================================================
# RETURN TO DECK + DISCARD (implementación en ActionReturnDiscard.gd)
# =============================================================================
func return_to_deck(card: Node, player_id: int, to_top: bool = true, source: Node = null) -> bool:
	return await _action_return_discard.return_to_deck(card, player_id, to_top, source)


func discard(player_id: int, cards: Array, source: String = "", skip_validation: bool = false) -> Dictionary:
	return await _action_return_discard.discard(player_id, cards, source, skip_validation)


# =============================================================================
# SISTEMA DE TRIGGERS SIMULTÁNEOS (DAR 7.4)
# =============================================================================
## Se queda aquí (no extraído): dependencia interna compartida por los 6
## módulos de verbo de arriba — cada uno la llama vía _main._X().
var _collecting_triggers: bool = false
var _collected_triggers: Array[Dictionary] = []


func _begin_trigger_collection() -> void:
	"""Inicia la recolección de triggers para una acción"""
	_collecting_triggers = true
	_collected_triggers.clear()

	TriggerSystem.begin_collecting()


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

					TriggerSystem.register_trigger(card, trigger_type, event_data)


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
	await TriggerSystem.end_collecting_and_queue()

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
		await AnimationQueue.wait_until_empty()


# =============================================================================
# UTILIDADES
# =============================================================================
func _apply_card_filter(cards: Array, filter: Dictionary) -> Array:
	"""Aplica un filtro a un array de datos de carta (Dictionary, claves en
	español — 'tipo'/'coste'/'raza'/'fuerza'/'nombre'/'keywords'). El Castillo
	y el Cementerio se guardan como datos, no como nodos Card (ver CardManager),
	así que el filtro lee las mismas claves que usa CardFactory/GameBootstrap
	al construir esos diccionarios. Compartida por ActionSearch.gd y
	ActionValidator.gd — se queda aquí, no extraída."""
	if filter.is_empty():
		return cards.duplicate()

	var matching: Array = []

	for card_data in cards:
		var matches = true

		# Filtro por tipo — admite un tipo único o una lista ("busca un Arma
		# o un Oro", p.ej. Tyet, 2026-08-22)
		if filter.has("type"):
			var card_type = card_data.get("tipo", -1)
			if filter.type is Array:
				if card_type not in filter.type:
					matches = false
			elif card_type != filter.type:
				matches = false

		# Filtro por raza — admite una raza única o una lista ("busca... una
		# carta Ignis o Titán", p.ej. ignis desatado, 2026-09-04)
		if matches and filter.has("raza"):
			var card_raza: String = card_data.get("raza", "")
			if filter.raza is Array:
				var raza_list: Array = filter.raza
				if not raza_list.any(func(r): return card_raza.to_lower() == String(r).to_lower()):
					matches = false
			elif card_raza.to_lower() != String(filter.raza).to_lower():
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

		# Filtro de exclusión por nombre exacto (2026-09-04, p.ej. Aurora de
		# Chile: "busca... dos Oros que no sean Aurora de Chile" — evita que
		# la propia carta buscadora, si hay otra copia en el Castillo, se
		# encuentre a sí misma)
		if matches and filter.has("name_not"):
			var card_name_exact: String = card_data.get("nombre", "")
			if card_name_exact.to_lower() == String(filter.name_not).to_lower():
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
