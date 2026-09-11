extends RefCounted
## CombatLogSignalHandlers — Handlers de señales de ActionExecutor/ActionModule/
## GameManager/TurnManager/UniversalCardParser, más el broadcast de acciones
## del parser a ambos jugadores. Ninguna de estas funciones se llama por
## nombre desde fuera de CombatLog.gd — son callbacks internos conectados vía
## _connect_signals(), así que no necesitan forwarders en el archivo original.
## Opera sobre CombatLog via _main.
## Extraído de CombatLog.gd (Fase 4 de reestructuración, "módulos gordos").

var _main: Node


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# CONEXIÓN DE SEÑALES
# =============================================================================
func connect_signals() -> void:
	"""Conecta a todas las señales relevantes del sistema
	(2026-08-28, "módulos gordos" punto 1): ActionExecutor/ActionModule/
	GameManager/TurnManager/UniversalCardParser son autoloads garantizados —
	se saca el cacheo redundante vía get_node_or_null(). _safe_connect() ya
	valida has_signal() por su cuenta, así que esto no cambia el
	comportamiento: _connect_module_signals() y _connect_turn_manager_signals()
	seguían (y siguen) sin conectar nada real — ActionModule.gd no tiene
	señales 'card_drawn/discarded/destroyed/banished/milled' y TurnManager.gd
	no emite ninguna señal propia hoy."""
	_connect_executor_signals()
	_connect_module_signals()
	_connect_game_signals()
	_connect_turn_manager_signals()
	_connect_parser_signals()

	print("[CombatLog] Señales conectadas")


func _connect_executor_signals() -> void:
	"""Conecta señales del ActionExecutor"""
	# Habilidades
	_safe_connect(ActionExecutor, "ability_execution_started", _on_ability_started)
	_safe_connect(ActionExecutor, "ability_execution_completed", _on_ability_completed)

	# Acciones
	_safe_connect(ActionExecutor, "action_executed", _on_action_executed)
	_safe_connect(ActionExecutor, "action_draw_completed", _on_draw)
	_safe_connect(ActionExecutor, "action_discard_completed", _on_discard)
	_safe_connect(ActionExecutor, "action_destroy_completed", _on_destroy)
	_safe_connect(ActionExecutor, "action_banish_completed", _on_banish)
	_safe_connect(ActionExecutor, "action_mill_completed", _on_mill)
	_safe_connect(ActionExecutor, "action_search_completed", _on_search)
	_safe_connect(ActionExecutor, "action_damage_completed", _on_damage)
	_safe_connect(ActionExecutor, "action_buff_completed", _on_buff)
	_safe_connect(ActionExecutor, "action_heal_completed", _on_heal)

	# Costes
	_safe_connect(ActionExecutor, "cost_paid", _on_cost_paid)
	_safe_connect(ActionExecutor, "execution_failed", _on_execution_failed)

	# Respuesta
	_safe_connect(ActionExecutor, "waiting_for_opponent_response", _on_response_window)
	_safe_connect(ActionExecutor, "opponent_passed", _on_opponent_passed)
	_safe_connect(ActionExecutor, "opponent_responded", _on_opponent_responded)

	# Anulación
	_safe_connect(ActionExecutor, "spell_annulled", _on_spell_annulled)

	# Resolución
	_safe_connect(ActionExecutor, "resolution_started", _on_resolution_started)
	_safe_connect(ActionExecutor, "resolution_completed", _on_resolution_completed)
	_safe_connect(ActionExecutor, "post_resolution_condition", _on_post_resolution)


func _connect_module_signals() -> void:
	"""Conecta señales del ActionModule"""
	_safe_connect(ActionModule, "card_drawn", _on_module_draw)
	_safe_connect(ActionModule, "card_discarded", _on_module_discard)
	_safe_connect(ActionModule, "card_destroyed", _on_module_destroy)
	_safe_connect(ActionModule, "card_banished", _on_module_banish)
	_safe_connect(ActionModule, "card_milled", _on_module_mill)


func _connect_game_signals() -> void:
	"""Conecta señales del GameManager"""
	_safe_connect(GameManager, "phase_changed", _on_phase_changed)
	_safe_connect(GameManager, "turn_started", _on_turn_started)
	_safe_connect(GameManager, "turn_ended", _on_turn_ended)


func _connect_turn_manager_signals() -> void:
	"""Conecta señales del TurnManager para tracking de fases"""
	_safe_connect(TurnManager, "phase_changed", _on_turn_phase_changed)
	_safe_connect(TurnManager, "turn_started", _on_turn_manager_turn_started)
	_safe_connect(TurnManager, "turn_ended", _on_turn_manager_turn_ended)
	_safe_connect(TurnManager, "priority_window_opened", _on_priority_opened)
	_safe_connect(TurnManager, "priority_window_closed", _on_priority_closed)


func _connect_parser_signals() -> void:
	"""Conecta señales del UniversalCardParser"""
	_safe_connect(UniversalCardParser, "parsing_completed", _on_parsing_completed)
	_safe_connect(UniversalCardParser, "chain_resolution_started", _on_chain_started)
	_safe_connect(UniversalCardParser, "chain_resolution_completed", _on_chain_completed)
	_safe_connect(UniversalCardParser, "action_resolved", _on_parser_action_resolved)
	_safe_connect(UniversalCardParser, "response_window_requested", _on_parser_response_window)


func _safe_connect(source: Node, signal_name: String, callback: Callable) -> void:
	"""Conecta una señal de forma segura"""
	if source.has_signal(signal_name) and not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)


# =============================================================================
# HANDLERS DE SEÑALES - ActionExecutor
# =============================================================================
func _on_ability_started(card: Node, ability_block: Dictionary) -> void:
	var card_name = _main._formatters.get_card_name(card)
	_main.add_entry("ability", "Activando habilidad de %s" % [_main._formatters.format_card(card_name)], {
		"card": card_name,
		"trigger": ability_block.get("trigger", {})
	})


func _on_ability_completed(card: Node, result: Dictionary) -> void:
	var card_name = _main._formatters.get_card_name(card)
	var status = "success" if result.success else "failure"
	var effects_count = result.get("effects_resolved", []).size()

	_main.add_entry("ability", "Habilidad de %s %s (%d efectos)" % [
		_main._formatters.format_card(card_name),
		_main._formatters.format_status(status),
		effects_count
	], result)


func _on_action_executed(action: Dictionary, result: Dictionary) -> void:
	var action_type = action.get("type", "unknown")
	var status = "success" if result.success else "failure"

	_main.add_entry("action", "Acción %s: %s" % [
		_main._formatters.format_effect(action_type),
		_main._formatters.format_status(status)
	], {"action": action, "result": result})


func _on_draw(player_id: int, cards: Array, amount: int) -> void:
	var player = _main._formatters.format_player(player_id)
	var card_names = _main._formatters.get_card_names(cards)

	_main.add_entry("draw", "%s %s %d carta(s): %s" % [
		player,
		_main._formatters.format_effect("robó", "draw"),
		amount,
		_main._formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names})


func _on_discard(player_id: int, cards: Array) -> void:
	var player = _main._formatters.format_player(player_id)
	var card_names = _main._formatters.get_card_names(cards)

	_main.add_entry("discard", "%s %s: %s" % [
		player,
		_main._formatters.format_effect("descartó", "discard"),
		_main._formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names})


func _on_destroy(destroyed: Array, source: Node) -> void:
	var source_name = _main._formatters.get_card_name(source) if source else "efecto"
	var card_names = _main._formatters.get_card_names(destroyed)

	_main.add_entry("destroy", "%s %s: %s" % [
		_main._formatters.format_card(source_name),
		_main._formatters.format_effect("destruyó", "destroy"),
		_main._formatters.format_card_list(card_names)
	], {"source": source_name, "destroyed": card_names})


func _on_banish(banished: Array, source: Node) -> void:
	var source_name = _main._formatters.get_card_name(source) if source else "efecto"
	var card_names = _main._formatters.get_card_names(banished)

	_main.add_entry("banish", "%s %s: %s" % [
		_main._formatters.format_card(source_name),
		_main._formatters.format_effect("desterró", "banish"),
		_main._formatters.format_card_list(card_names)
	], {"source": source_name, "banished": card_names})


func _on_mill(player_id: int, cards: Array, to_exile: bool) -> void:
	var player = _main._formatters.format_player(player_id)
	var card_names = _main._formatters.get_card_names(cards)
	var destination = "destierro" if to_exile else "cementerio"

	_main.add_entry("mill", "%s %s %d carta(s) al %s: %s" % [
		player,
		_main._formatters.format_effect("botó", "mill"),
		cards.size(),
		_main._formatters.format_zone(destination),
		_main._formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names, "to_exile": to_exile})


func _on_search(player_id: int, selected: Array, zone: int) -> void:
	var player = _main._formatters.format_player(player_id)
	var card_names = _main._formatters.get_card_names(selected)
	var zone_name = _main._formatters.zone_to_string(zone)

	_main.add_entry("search", "%s %s en %s: %s" % [
		player,
		_main._formatters.format_effect("buscó", "search"),
		_main._formatters.format_zone(zone_name),
		_main._formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names, "zone": zone})


func _on_damage(targets: Array, amount: int, source: Node) -> void:
	var source_name = _main._formatters.get_card_name(source) if source else "efecto"
	var target_names = _main._formatters.get_card_names(targets)

	_main.add_entry("damage", "%s infligió %s de %s a: %s" % [
		_main._formatters.format_card(source_name),
		_main._formatters.format_number(amount, "damage"),
		_main._formatters.format_effect("daño", "damage"),
		_main._formatters.format_card_list(target_names)
	], {"source": source_name, "targets": target_names, "amount": amount})


func _on_buff(targets: Array, amount: int, is_buff: bool) -> void:
	var effect_type = "buff" if is_buff else "debuff"
	var effect_text = "fortaleció" if is_buff else "debilitó"
	var target_names = _main._formatters.get_card_names(targets)
	var sign = "+" if is_buff else ""

	_main.add_entry(effect_type, "%s a %s (%s%d)" % [
		_main._formatters.format_effect(effect_text, effect_type),
		_main._formatters.format_card_list(target_names),
		sign,
		amount
	], {"targets": target_names, "amount": amount, "is_buff": is_buff})


func _on_heal(player_id: int, amount: int) -> void:
	var player = _main._formatters.format_player(player_id)

	_main.add_entry("heal", "%s %s %s puntos de vida" % [
		player,
		_main._formatters.format_effect("recuperó", "heal"),
		_main._formatters.format_number(amount, "heal")
	], {"player": player_id, "amount": amount})


func _on_cost_paid(cost: Dictionary, success: bool) -> void:
	var cost_type = cost.get("type", "unknown")
	var amount = cost.get("amount", 1)
	var status = _main._formatters.format_status("success" if success else "failure")

	_main.add_entry("cost", "Coste pagado: %s x%d %s" % [
		_main._formatters.format_effect(cost_type, "gold"),
		amount,
		status
	], {"cost": cost, "success": success}, 1)


func _on_execution_failed(reason: String, context: Dictionary) -> void:
	_main.add_entry("error", "%s: %s" % [
		_main._formatters.format_status("failure"),
		reason
	], context)


func _on_response_window(card: Node, context: Dictionary) -> void:
	var card_name = context.get("card_name", _main._formatters.get_card_name(card))
	_main.add_entry("response", "⏳ Ventana de respuesta para %s" % [
		_main._formatters.format_card(card_name)
	], context)


func _on_opponent_passed() -> void:
	_main.add_entry("response", "%s %s" % [
		_main._formatters.format_player(1),
		_main._formatters.format_status("pasó", "info")
	])


func _on_opponent_responded(response_card: Node) -> void:
	var card_name = _main._formatters.get_card_name(response_card)
	_main.add_entry("response", "%s respondió con %s" % [
		_main._formatters.format_player(1),
		_main._formatters.format_card(card_name)
	])


func _on_spell_annulled(annulled_card: Node, annuller_card: Node) -> void:
	var annulled_name = _main._formatters.get_card_name(annulled_card)
	var annuller_name = _main._formatters.get_card_name(annuller_card)

	_main.add_entry("annul", "🚫 %s %s a %s" % [
		_main._formatters.format_card(annuller_name),
		_main._formatters.format_effect("ANULÓ", "annul"),
		_main._formatters.format_card(annulled_name)
	], {"annulled": annulled_name, "annuller": annuller_name})


func _on_resolution_started(card: Node, effects: Array) -> void:
	var card_name = _main._formatters.get_card_name(card)
	_main.add_entry("resolution", "▶ Resolviendo %s (%d efectos)" % [
		_main._formatters.format_card(card_name),
		effects.size()
	], {"card": card_name, "effects_count": effects.size()})


func _on_resolution_completed(card: Node, success: bool, effects_resolved: int) -> void:
	var card_name = _main._formatters.get_card_name(card)
	var status = _main._formatters.format_status("success" if success else "failure")

	_main.add_entry("resolution", "✓ Resolución de %s %s (%d efectos)" % [
		_main._formatters.format_card(card_name),
		status,
		effects_resolved
	], {"card": card_name, "success": success, "effects": effects_resolved})


func _on_post_resolution(card: Node, condition: String, destination: String) -> void:
	var card_name = _main._formatters.get_card_name(card)

	_main.add_entry("resolution", "→ %s: %s va a %s" % [
		_main._formatters.format_phase(condition),
		_main._formatters.format_card(card_name),
		_main._formatters.format_zone(destination)
	], {"card": card_name, "condition": condition, "destination": destination})


# =============================================================================
# HANDLERS DE SEÑALES - ActionModule
# =============================================================================
func _on_module_draw(player_id: int, card: Node) -> void:
	# Evitar duplicados si ActionExecutor ya lo registró
	pass


func _on_module_discard(player_id: int, card: Node, reason: String) -> void:
	pass


func _on_module_destroy(card: Node, source: Node) -> void:
	pass


func _on_module_banish(card: Node, source: Node) -> void:
	pass


func _on_module_mill(player_id: int, card: Node, to_exile: bool) -> void:
	pass


# =============================================================================
# HANDLERS DE SEÑALES - GameManager
# =============================================================================
func _on_phase_changed(new_phase: int) -> void:
	_main._add_phase_header(new_phase)


func _on_turn_started(player_id: int, turn_number: int) -> void:
	_main._current_turn = turn_number
	_main._active_player = player_id
	_main._add_turn_header(turn_number, player_id)


func _on_turn_ended(player_id: int) -> void:
	_main.add_entry("turn", "── Fin del turno de %s ──" % [
		_main._formatters.format_player(player_id)
	])


# =============================================================================
# HANDLERS DE SEÑALES - TurnManager
# =============================================================================
func _on_turn_phase_changed(new_phase) -> void:
	"""Handler para cambio de fase desde TurnManager"""
	var phase_int = new_phase if new_phase is int else int(new_phase)
	_main._add_phase_header(phase_int)


func _on_turn_manager_turn_started(player_id: int, turn_number: int) -> void:
	"""Handler para inicio de turno desde TurnManager"""
	_main._current_turn = turn_number
	_main._active_player = player_id
	_main._add_turn_header(turn_number, player_id)


func _on_turn_manager_turn_ended(player_id: int) -> void:
	"""Handler para fin de turno desde TurnManager"""
	_main.add_entry("turn", "━━━━━━ Fin del turno de %s ━━━━━━" % [
		_main._formatters.format_player(player_id)
	], {}, 1)


func _on_priority_opened(player_id: int, phase) -> void:
	"""Handler cuando se abre ventana de prioridad"""
	_main.add_entry("priority", "⏳ %s tiene prioridad" % _main._formatters.format_player(player_id), {
		"player": player_id,
		"phase": phase
	}, 1)


func _on_priority_closed(phase) -> void:
	"""Handler cuando se cierra ventana de prioridad"""
	pass  # No loguear para evitar spam


# =============================================================================
# HANDLERS DE SEÑALES - UniversalCardParser
# =============================================================================
func _on_parsing_completed(card_name: String, actions: Array) -> void:
	"""Handler cuando se completa el parsing de una carta"""
	if actions.is_empty():
		return

	_main.add_entry("parse", "📜 %s: %d acción(es) detectadas" % [
		_main._formatters.format_card(card_name),
		actions.size()
	], {"card": card_name, "actions_count": actions.size()}, 1)


func _on_chain_started(actions: Array) -> void:
	"""Handler cuando inicia la resolución de una cadena"""
	_main.add_entry("chain", "▶ Iniciando cadena de %d acción(es)..." % actions.size(), {
		"actions_count": actions.size()
	})

	# Broadcast a ambos jugadores
	_broadcast_chain_start(actions)


func _on_chain_completed(results: Array) -> void:
	"""Handler cuando termina la resolución de una cadena"""
	var success_count = 0
	var fail_count = 0

	for result in results:
		if result.get("success", false):
			success_count += 1
		else:
			fail_count += 1

	var status = "success" if fail_count == 0 else ("warning" if success_count > 0 else "failure")

	_main.add_entry("chain", "✓ Cadena completada: %s éxitos, %s fallos" % [
		_main._formatters.format_number(success_count, "success"),
		_main._formatters.format_number(fail_count, "failure")
	], {"success": success_count, "failed": fail_count})

	# Broadcast a ambos jugadores
	_broadcast_chain_complete(success_count, fail_count)


func _on_parser_action_resolved(action: Dictionary, result: Dictionary) -> void:
	"""Handler cuando se resuelve una acción del parser

	Esta es la función principal que logea cada acción ejecutada
	y la hace visible para ambos jugadores.
	"""
	var action_type = action.get("type", 0)
	var amount = action.get("amount", 1)
	var target = action.get("target", 0)
	var connector = action.get("connector", 0)
	var raw_text = action.get("raw_text", "")
	var success = result.get("success", false)
	var partial = result.get("partial", false)

	# Determinar tipo de acción como string
	var action_name = _action_type_to_string(action_type)
	var action_color = _get_action_color(action_name)

	# Determinar objetivo
	var target_str = _target_type_to_string(target)

	# Determinar estado
	var status_str = ""
	if success:
		status_str = _main._formatters.format_status("success")
	elif partial:
		status_str = "[color=#FFC107]parcial[/color]"
	else:
		status_str = _main._formatters.format_status("failure")

	# Construir mensaje
	var message = ""
	var connector_str = _connector_to_log_string(connector)

	if not connector_str.is_empty():
		message += "[color=#888888]%s[/color] " % connector_str

	message += "[color=%s]%s[/color]" % [action_color, action_name.to_upper()]

	if amount != 1 and amount > 0:
		message += " x%d" % amount
	elif amount == -1:
		message += " (todas)"

	message += " → %s %s" % [target_str, status_str]

	# Agregar texto original si existe
	if not raw_text.is_empty():
		message += "\n    [color=#666666]「%s」[/color]" % raw_text

	# Agregar entrada - SIEMPRE es pública (visible para ambos)
	_main.add_entry(action_name.to_lower(), message, {
		"action_type": action_name,
		"amount": amount,
		"target": target_str,
		"success": success,
		"partial": partial,
		"raw_text": raw_text
	})

	# Broadcast explícito a ambos jugadores
	_broadcast_action_to_all(action, result)


func _on_parser_response_window(card_data: Dictionary, pending_actions: Array) -> void:
	"""Handler cuando el parser solicita ventana de respuesta"""
	var card_name = card_data.get("name", card_data.get("nombre", "???"))

	_main.add_entry("response", "⏳ %s jugada - Ventana de respuesta abierta" % [
		_main._formatters.format_card(card_name)
	], {"card": card_name, "pending_actions": pending_actions.size()})

	# Listar acciones pendientes
	for i in range(pending_actions.size()):
		var action = pending_actions[i]
		var action_name = _action_type_to_string(action.get("type", 0))
		_main.add_entry("response", "   %d. %s" % [i + 1, action_name], {}, 1)

	# Broadcast a ambos jugadores
	_broadcast_response_window(card_data, pending_actions)


func _action_type_to_string(action_type: int) -> String:
	"""Convierte ActionType enum a string legible"""
	# Mapeo basado en UniversalCardParser.ActionType
	match action_type:
		0: return "Robar"        # DRAW
		1: return "Botar"        # MILL
		2: return "Descartar"    # DISCARD
		3: return "Destruir"     # DESTROY
		4: return "Desterrar"    # BANISH
		5: return "Buscar"       # SEARCH
		6: return "Daño"         # DAMAGE
		7: return "Fortalecer"   # BUFF
		8: return "Debilitar"    # DEBUFF
		9: return "Curar"        # HEAL
		10: return "Devolver a mano"  # RETURN_HAND
		11: return "Devolver a mazo"  # RETURN_DECK
		12: return "Revelar"     # REVEAL
		13: return "Mirar"       # LOOK
		14: return "Barajar"     # SHUFFLE
		15: return "Girar"       # TAP
		16: return "Enderezar"   # UNTAP
		17: return "Crear Token" # CREATE_TOKEN
		18: return "Copiar"      # COPY
		19: return "Anular"      # COUNTER
		20: return "Mover"       # MOVE
		21: return "Oro"         # GOLD
		_: return "Efecto"       # CUSTOM


func _get_action_color(action_name: String) -> String:
	"""Obtiene color para tipo de acción"""
	match action_name.to_lower():
		"robar": return _main.COLORS.draw
		"botar": return _main.COLORS.mill
		"descartar": return _main.COLORS.discard
		"destruir": return _main.COLORS.destroy
		"desterrar": return _main.COLORS.banish
		"buscar": return _main.COLORS.search
		"daño": return _main.COLORS.damage
		"fortalecer": return _main.COLORS.buff
		"debilitar": return _main.COLORS.debuff
		"curar": return _main.COLORS.heal
		"anular": return _main.COLORS.annul
		"oro": return _main.COLORS.gold
		_: return "#FFFFFF"


func _target_type_to_string(target_type: int) -> String:
	"""Convierte TargetType enum a string"""
	match target_type:
		0: return _main._formatters.format_player(0)  # SELF
		1: return _main._formatters.format_player(1)  # OPPONENT
		2: return "ambos jugadores"  # BOTH
		3: return "esta carta"       # CARD_SELF
		4: return "carta objetivo"   # CARD_TARGET
		5: return "todas las cartas" # CARD_ALL
		6: return "carta aleatoria"  # CARD_RANDOM
		_: return "objetivo"


func _connector_to_log_string(connector: int) -> String:
	"""Convierte Connector enum a string para log"""
	match connector:
		0: return ""           # NONE
		1: return "Y"          # Y
		2: return "LUEGO →"    # LUEGO
		3: return "O"          # O
		4: return "EN MEDIDA →" # EN_MEDIDA
		_: return ""


# =============================================================================
# BROADCASTING - ACCIONES DEL PARSER
# =============================================================================
func _broadcast_chain_start(actions: Array) -> void:
	"""Broadcast inicio de cadena a ambos jugadores"""
	var sync_data = {
		"type": "chain_start",
		"actions_count": actions.size(),
		"turn": _main._current_turn,
		"phase": _main._current_phase_name
	}

	_main.emit_signal("sync_to_opponent", "chain_start", sync_data)
	_main.emit_signal("public_action_occurred", sync_data)


func _broadcast_chain_complete(success_count: int, fail_count: int) -> void:
	"""Broadcast fin de cadena a ambos jugadores"""
	var sync_data = {
		"type": "chain_complete",
		"success_count": success_count,
		"fail_count": fail_count,
		"turn": _main._current_turn
	}

	_main.emit_signal("sync_to_opponent", "chain_complete", sync_data)
	_main.emit_signal("public_action_occurred", sync_data)


func _broadcast_action_to_all(action: Dictionary, result: Dictionary) -> void:
	"""Broadcast una acción ejecutada a ambos jugadores

	Esta es la función clave que asegura que ambos jugadores
	vean cada acción que se ejecuta.
	"""
	var action_type = _action_type_to_string(action.get("type", 0))

	var sync_data = {
		"type": "action_executed",
		"action_type": action_type,
		"amount": action.get("amount", 1),
		"target": _target_type_to_string(action.get("target", 0)),
		"success": result.get("success", false),
		"partial": result.get("partial", false),
		"raw_text": action.get("raw_text", ""),
		"turn": _main._current_turn,
		"phase": _main._current_phase_name,
		"timestamp": Time.get_unix_time_from_system()
	}

	# Emitir a todos los listeners
	_main.emit_signal("public_action_occurred", sync_data)
	_main.emit_signal("sync_to_opponent", "action_executed", sync_data)

	# TODO: Integrar con NetworkManager para multiplayer real
	# NetworkManager.broadcast_to_all_players(sync_data)


func _broadcast_response_window(card_data: Dictionary, pending_actions: Array) -> void:
	"""Broadcast ventana de respuesta a ambos jugadores"""
	var card_name = card_data.get("name", card_data.get("nombre", "???"))

	var actions_summary: Array = []
	for action in pending_actions:
		actions_summary.append({
			"type": _action_type_to_string(action.get("type", 0)),
			"amount": action.get("amount", 1)
		})

	var sync_data = {
		"type": "response_window",
		"card_name": card_name,
		"pending_actions": actions_summary,
		"turn": _main._current_turn,
		"phase": _main._current_phase_name
	}

	_main.emit_signal("public_action_occurred", sync_data)
	_main.emit_signal("sync_to_opponent", "response_window", sync_data)
