extends Node
## CombatLog - Sistema de registro de acciones del ActionPipeline
## Escucha señales globales y formatea mensajes con BBCode

# =============================================================================
# SEÑALES
# =============================================================================
signal log_entry_added(entry: Dictionary)
signal log_cleared()

## Señales para sincronización multiplayer (acciones públicas)
signal public_action_occurred(action_data: Dictionary)
signal sync_to_opponent(action_type: String, data: Dictionary)

# =============================================================================
# CONFIGURACIÓN DE COLORES (BBCode)
# =============================================================================
const COLORS = {
	# Tipos de efecto
	"draw": "#4CAF50",       # Verde - Robar
	"robar": "#4CAF50",      # Verde - Robar (español)
	"discard": "#F44336",    # Rojo - Descartar
	"descartar": "#F44336",  # Rojo - Descartar (español)
	"destroy": "#D32F2F",    # Rojo oscuro - Destruir
	"destruir": "#D32F2F",   # Rojo oscuro - Destruir (español)
	"banish": "#9C27B0",     # Púrpura - Desterrar
	"desterrar": "#9C27B0",  # Púrpura - Desterrar (español)
	"mill": "#FF9800",       # Naranja - Botar
	"botar": "#FF9800",      # Naranja - Botar (español)
	"search": "#2196F3",     # Azul - Buscar
	"buscar": "#2196F3",     # Azul - Buscar (español)
	"damage": "#E91E63",     # Rosa - Daño
	"daño": "#E91E63",       # Rosa - Daño (español)
	"heal": "#8BC34A",       # Verde claro - Curar
	"curar": "#8BC34A",      # Verde claro - Curar (español)
	"buff": "#CDDC39",       # Lima - Buff
	"fortalecer": "#CDDC39", # Lima - Buff (español)
	"debuff": "#795548",     # Marrón - Debuff
	"debilitar": "#795548",  # Marrón - Debuff (español)
	"counter": "#607D8B",    # Gris azulado - Contrarrestar
	"annul": "#FF5722",      # Naranja rojizo - Anular
	"anular": "#FF5722",     # Naranja rojizo - Anular (español)
	"chain": "#00BCD4",      # Cyan - Cadena de acciones
	"parse": "#9E9E9E",      # Gris - Parsing
	"revelar": "#03A9F4",    # Azul claro - Revelar
	"mirar": "#81D4FA",      # Azul muy claro - Mirar

	# Recursos
	"gold": "#FFD700",       # Dorado - Oro
	"mana": "#03A9F4",       # Azul claro - Maná

	# Tipos de carta
	"ally": "#4FC3F7",       # Azul claro - Aliado
	"talisman": "#BA68C8",   # Púrpura claro - Talismán
	"weapon": "#90A4AE",     # Gris - Arma
	"totem": "#A1887F",      # Marrón claro - Tótem
	"gold_card": "#FFD700",  # Dorado - Oro

	# Jugadores
	"player1": "#64B5F6",    # Azul - Jugador 1
	"player2": "#EF5350",    # Rojo - Jugador 2
	"opponent": "#EF5350",   # Rojo - Oponente

	# Estados
	"success": "#4CAF50",    # Verde
	"failure": "#F44336",    # Rojo
	"warning": "#FFC107",    # Amarillo
	"info": "#9E9E9E",       # Gris

	# Fases
	"phase": "#CE93D8",      # Púrpura claro
	"step": "#80DEEA",       # Cyan claro

	# Zonas
	"deck": "#5D4037",       # Marrón - Castillo/Mazo
	"hand": "#1976D2",       # Azul - Mano
	"field": "#388E3C",      # Verde - Campo
	"graveyard": "#424242",  # Gris oscuro - Cementerio
	"exile": "#7B1FA2",      # Púrpura - Destierro
}

# =============================================================================
# ESTADO
# =============================================================================
var _log_entries: Array[Dictionary] = []
var _max_entries: int = 500
var _auto_scroll: bool = true
var _show_timestamps: bool = true
var _log_level: int = 0  # 0=all, 1=important, 2=critical

## Tracking de fase actual
var _current_phase: int = -1
var _current_phase_name: String = ""
var _current_turn: int = 0
var _active_player: int = 0

## Acciones públicas (visibles para ambos jugadores)
const PUBLIC_ACTIONS: Array[String] = [
	"mill",      # Botar - cartas van al cementerio público
	"reveal",    # Mostrar - revelar cartas
	"search",    # Buscar - el oponente ve qué se buscó
	"destroy",   # Destruir - cartas destruidas son públicas
	"banish",    # Desterrar - cartas desterradas son públicas
	"discard",   # Descartar - cementerio es público
	"play",      # Jugar carta - acción pública
	"attack",    # Atacar - acción pública
	"block",     # Bloquear - acción pública
	"chain",     # Cadena de acciones - visible para ambos
	"robar",     # Robar - cantidad visible (no las cartas)
	"botar",     # Botar/Mill - público
	"desterrar", # Desterrar - público
	"buscar",    # Buscar - público
	"daño",      # Daño - público
	"anular",    # Anular - público
]

# Referencias
var _action_executor: Node = null
var _action_module: Node = null
var _game_manager: Node = null
var _turn_manager: Node = null
var _card_parser: Node = null


func _ready() -> void:
	call_deferred("_connect_signals")
	print("[CombatLog] Inicializado")


func _connect_signals() -> void:
	"""Conecta a todas las señales relevantes del sistema"""
	# ActionExecutor
	_action_executor = get_node_or_null("/root/ActionExecutor")
	if _action_executor:
		_connect_executor_signals()

	# ActionModule
	_action_module = get_node_or_null("/root/ActionModule")
	if _action_module:
		_connect_module_signals()

	# GameManager
	_game_manager = get_node_or_null("/root/GameManager")
	if _game_manager:
		_connect_game_signals()

	# TurnManager - Para headers de fase
	_turn_manager = get_node_or_null("/root/TurnManager")
	if _turn_manager:
		_connect_turn_manager_signals()

	# UniversalCardParser - Para acciones parseadas
	_card_parser = get_node_or_null("/root/UniversalCardParser")
	if _card_parser:
		_connect_parser_signals()

	print("[CombatLog] Señales conectadas")


func _connect_executor_signals() -> void:
	"""Conecta señales del ActionExecutor"""
	if not _action_executor:
		return

	# Habilidades
	_safe_connect(_action_executor, "ability_execution_started", _on_ability_started)
	_safe_connect(_action_executor, "ability_execution_completed", _on_ability_completed)

	# Acciones
	_safe_connect(_action_executor, "action_executed", _on_action_executed)
	_safe_connect(_action_executor, "action_draw_completed", _on_draw)
	_safe_connect(_action_executor, "action_discard_completed", _on_discard)
	_safe_connect(_action_executor, "action_destroy_completed", _on_destroy)
	_safe_connect(_action_executor, "action_banish_completed", _on_banish)
	_safe_connect(_action_executor, "action_mill_completed", _on_mill)
	_safe_connect(_action_executor, "action_search_completed", _on_search)
	_safe_connect(_action_executor, "action_damage_completed", _on_damage)
	_safe_connect(_action_executor, "action_buff_completed", _on_buff)
	_safe_connect(_action_executor, "action_heal_completed", _on_heal)

	# Costes
	_safe_connect(_action_executor, "cost_paid", _on_cost_paid)
	_safe_connect(_action_executor, "execution_failed", _on_execution_failed)

	# Respuesta
	_safe_connect(_action_executor, "waiting_for_opponent_response", _on_response_window)
	_safe_connect(_action_executor, "opponent_passed", _on_opponent_passed)
	_safe_connect(_action_executor, "opponent_responded", _on_opponent_responded)

	# Anulación
	_safe_connect(_action_executor, "spell_annulled", _on_spell_annulled)

	# Resolución
	_safe_connect(_action_executor, "resolution_started", _on_resolution_started)
	_safe_connect(_action_executor, "resolution_completed", _on_resolution_completed)
	_safe_connect(_action_executor, "post_resolution_condition", _on_post_resolution)


func _connect_module_signals() -> void:
	"""Conecta señales del ActionModule"""
	if not _action_module:
		return

	_safe_connect(_action_module, "card_drawn", _on_module_draw)
	_safe_connect(_action_module, "card_discarded", _on_module_discard)
	_safe_connect(_action_module, "card_destroyed", _on_module_destroy)
	_safe_connect(_action_module, "card_banished", _on_module_banish)
	_safe_connect(_action_module, "card_milled", _on_module_mill)


func _connect_game_signals() -> void:
	"""Conecta señales del GameManager"""
	if not _game_manager:
		return

	_safe_connect(_game_manager, "phase_changed", _on_phase_changed)
	_safe_connect(_game_manager, "turn_started", _on_turn_started)
	_safe_connect(_game_manager, "turn_ended", _on_turn_ended)


func _connect_turn_manager_signals() -> void:
	"""Conecta señales del TurnManager para tracking de fases"""
	if not _turn_manager:
		return

	_safe_connect(_turn_manager, "phase_changed", _on_turn_phase_changed)
	_safe_connect(_turn_manager, "turn_started", _on_turn_manager_turn_started)
	_safe_connect(_turn_manager, "turn_ended", _on_turn_manager_turn_ended)
	_safe_connect(_turn_manager, "priority_window_opened", _on_priority_opened)
	_safe_connect(_turn_manager, "priority_window_closed", _on_priority_closed)


func _connect_parser_signals() -> void:
	"""Conecta señales del UniversalCardParser"""
	if not _card_parser:
		return

	_safe_connect(_card_parser, "parsing_completed", _on_parsing_completed)
	_safe_connect(_card_parser, "chain_resolution_started", _on_chain_started)
	_safe_connect(_card_parser, "chain_resolution_completed", _on_chain_completed)
	_safe_connect(_card_parser, "action_resolved", _on_parser_action_resolved)
	_safe_connect(_card_parser, "response_window_requested", _on_parser_response_window)


func _safe_connect(source: Node, signal_name: String, callback: Callable) -> void:
	"""Conecta una señal de forma segura"""
	if source.has_signal(signal_name) and not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)


# =============================================================================
# HANDLERS DE SEÑALES - ActionExecutor
# =============================================================================
func _on_ability_started(card: Node, ability_block: Dictionary) -> void:
	var card_name = _get_card_name(card)
	add_entry("ability", "Activando habilidad de %s" % [format_card(card_name)], {
		"card": card_name,
		"trigger": ability_block.get("trigger", {})
	})


func _on_ability_completed(card: Node, result: Dictionary) -> void:
	var card_name = _get_card_name(card)
	var status = "success" if result.success else "failure"
	var effects_count = result.get("effects_resolved", []).size()

	add_entry("ability", "Habilidad de %s %s (%d efectos)" % [
		format_card(card_name),
		format_status(status),
		effects_count
	], result)


func _on_action_executed(action: Dictionary, result: Dictionary) -> void:
	var action_type = action.get("type", "unknown")
	var status = "success" if result.success else "failure"

	add_entry("action", "Acción %s: %s" % [
		format_effect(action_type),
		format_status(status)
	], {"action": action, "result": result})


func _on_draw(player_id: int, cards: Array, amount: int) -> void:
	var player = format_player(player_id)
	var card_names = _get_card_names(cards)

	add_entry("draw", "%s %s %d carta(s): %s" % [
		player,
		format_effect("robó", "draw"),
		amount,
		_format_card_list(card_names)
	], {"player": player_id, "cards": card_names})


func _on_discard(player_id: int, cards: Array) -> void:
	var player = format_player(player_id)
	var card_names = _get_card_names(cards)

	add_entry("discard", "%s %s: %s" % [
		player,
		format_effect("descartó", "discard"),
		_format_card_list(card_names)
	], {"player": player_id, "cards": card_names})


func _on_destroy(destroyed: Array, source: Node) -> void:
	var source_name = _get_card_name(source) if source else "efecto"
	var card_names = _get_card_names(destroyed)

	add_entry("destroy", "%s %s: %s" % [
		format_card(source_name),
		format_effect("destruyó", "destroy"),
		_format_card_list(card_names)
	], {"source": source_name, "destroyed": card_names})


func _on_banish(banished: Array, source: Node) -> void:
	var source_name = _get_card_name(source) if source else "efecto"
	var card_names = _get_card_names(banished)

	add_entry("banish", "%s %s: %s" % [
		format_card(source_name),
		format_effect("desterró", "banish"),
		_format_card_list(card_names)
	], {"source": source_name, "banished": card_names})


func _on_mill(player_id: int, cards: Array, to_exile: bool) -> void:
	var player = format_player(player_id)
	var card_names = _get_card_names(cards)
	var destination = "destierro" if to_exile else "cementerio"

	add_entry("mill", "%s %s %d carta(s) al %s: %s" % [
		player,
		format_effect("botó", "mill"),
		cards.size(),
		format_zone(destination),
		_format_card_list(card_names)
	], {"player": player_id, "cards": card_names, "to_exile": to_exile})


func _on_search(player_id: int, selected: Array, zone: int) -> void:
	var player = format_player(player_id)
	var card_names = _get_card_names(selected)
	var zone_name = _zone_to_string(zone)

	add_entry("search", "%s %s en %s: %s" % [
		player,
		format_effect("buscó", "search"),
		format_zone(zone_name),
		_format_card_list(card_names)
	], {"player": player_id, "cards": card_names, "zone": zone})


func _on_damage(targets: Array, amount: int, source: Node) -> void:
	var source_name = _get_card_name(source) if source else "efecto"
	var target_names = _get_card_names(targets)

	add_entry("damage", "%s infligió %s de %s a: %s" % [
		format_card(source_name),
		format_number(amount, "damage"),
		format_effect("daño", "damage"),
		_format_card_list(target_names)
	], {"source": source_name, "targets": target_names, "amount": amount})


func _on_buff(targets: Array, amount: int, is_buff: bool) -> void:
	var effect_type = "buff" if is_buff else "debuff"
	var effect_text = "fortaleció" if is_buff else "debilitó"
	var target_names = _get_card_names(targets)
	var sign = "+" if is_buff else ""

	add_entry(effect_type, "%s a %s (%s%d)" % [
		format_effect(effect_text, effect_type),
		_format_card_list(target_names),
		sign,
		amount
	], {"targets": target_names, "amount": amount, "is_buff": is_buff})


func _on_heal(player_id: int, amount: int) -> void:
	var player = format_player(player_id)

	add_entry("heal", "%s %s %s puntos de vida" % [
		player,
		format_effect("recuperó", "heal"),
		format_number(amount, "heal")
	], {"player": player_id, "amount": amount})


func _on_cost_paid(cost: Dictionary, success: bool) -> void:
	var cost_type = cost.get("type", "unknown")
	var amount = cost.get("amount", 1)
	var status = format_status("success" if success else "failure")

	add_entry("cost", "Coste pagado: %s x%d %s" % [
		format_effect(cost_type, "gold"),
		amount,
		status
	], {"cost": cost, "success": success}, 1)


func _on_execution_failed(reason: String, context: Dictionary) -> void:
	add_entry("error", "%s: %s" % [
		format_status("failure"),
		reason
	], context)


func _on_response_window(card: Node, context: Dictionary) -> void:
	var card_name = context.get("card_name", _get_card_name(card))
	add_entry("response", "⏳ Ventana de respuesta para %s" % [
		format_card(card_name)
	], context)


func _on_opponent_passed() -> void:
	add_entry("response", "%s %s" % [
		format_player(1),
		format_status("pasó", "info")
	])


func _on_opponent_responded(response_card: Node) -> void:
	var card_name = _get_card_name(response_card)
	add_entry("response", "%s respondió con %s" % [
		format_player(1),
		format_card(card_name)
	])


func _on_spell_annulled(annulled_card: Node, annuller_card: Node) -> void:
	var annulled_name = _get_card_name(annulled_card)
	var annuller_name = _get_card_name(annuller_card)

	add_entry("annul", "🚫 %s %s a %s" % [
		format_card(annuller_name),
		format_effect("ANULÓ", "annul"),
		format_card(annulled_name)
	], {"annulled": annulled_name, "annuller": annuller_name})


func _on_resolution_started(card: Node, effects: Array) -> void:
	var card_name = _get_card_name(card)
	add_entry("resolution", "▶ Resolviendo %s (%d efectos)" % [
		format_card(card_name),
		effects.size()
	], {"card": card_name, "effects_count": effects.size()})


func _on_resolution_completed(card: Node, success: bool, effects_resolved: int) -> void:
	var card_name = _get_card_name(card)
	var status = format_status("success" if success else "failure")

	add_entry("resolution", "✓ Resolución de %s %s (%d efectos)" % [
		format_card(card_name),
		status,
		effects_resolved
	], {"card": card_name, "success": success, "effects": effects_resolved})


func _on_post_resolution(card: Node, condition: String, destination: String) -> void:
	var card_name = _get_card_name(card)

	add_entry("resolution", "→ %s: %s va a %s" % [
		format_phase(condition),
		format_card(card_name),
		format_zone(destination)
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
	_add_phase_header(new_phase)


func _on_turn_started(player_id: int, turn_number: int) -> void:
	_current_turn = turn_number
	_active_player = player_id
	_add_turn_header(turn_number, player_id)


func _on_turn_ended(player_id: int) -> void:
	add_entry("turn", "── Fin del turno de %s ──" % [
		format_player(player_id)
	])


# =============================================================================
# HANDLERS DE SEÑALES - TurnManager
# =============================================================================
func _on_turn_phase_changed(new_phase) -> void:
	"""Handler para cambio de fase desde TurnManager"""
	var phase_int = new_phase if new_phase is int else int(new_phase)
	_add_phase_header(phase_int)


func _on_turn_manager_turn_started(player_id: int, turn_number: int) -> void:
	"""Handler para inicio de turno desde TurnManager"""
	_current_turn = turn_number
	_active_player = player_id
	_add_turn_header(turn_number, player_id)


func _on_turn_manager_turn_ended(player_id: int) -> void:
	"""Handler para fin de turno desde TurnManager"""
	add_entry("turn", "━━━━━━ Fin del turno de %s ━━━━━━" % [
		format_player(player_id)
	], {}, 1)


func _on_priority_opened(player_id: int, phase) -> void:
	"""Handler cuando se abre ventana de prioridad"""
	add_entry("priority", "⏳ %s tiene prioridad" % format_player(player_id), {
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

	add_entry("parse", "📜 %s: %d acción(es) detectadas" % [
		format_card(card_name),
		actions.size()
	], {"card": card_name, "actions_count": actions.size()}, 1)


func _on_chain_started(actions: Array) -> void:
	"""Handler cuando inicia la resolución de una cadena"""
	add_entry("chain", "▶ Iniciando cadena de %d acción(es)..." % actions.size(), {
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

	add_entry("chain", "✓ Cadena completada: %s éxitos, %s fallos" % [
		format_number(success_count, "success"),
		format_number(fail_count, "failure")
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
		status_str = format_status("success")
	elif partial:
		status_str = "[color=#FFC107]parcial[/color]"
	else:
		status_str = format_status("failure")

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
	add_entry(action_name.to_lower(), message, {
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

	add_entry("response", "⏳ %s jugada - Ventana de respuesta abierta" % [
		format_card(card_name)
	], {"card": card_name, "pending_actions": pending_actions.size()})

	# Listar acciones pendientes
	for i in range(pending_actions.size()):
		var action = pending_actions[i]
		var action_name = _action_type_to_string(action.get("type", 0))
		add_entry("response", "   %d. %s" % [i + 1, action_name], {}, 1)

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
		"robar": return COLORS.draw
		"botar": return COLORS.mill
		"descartar": return COLORS.discard
		"destruir": return COLORS.destroy
		"desterrar": return COLORS.banish
		"buscar": return COLORS.search
		"daño": return COLORS.damage
		"fortalecer": return COLORS.buff
		"debilitar": return COLORS.debuff
		"curar": return COLORS.heal
		"anular": return COLORS.annul
		"oro": return COLORS.gold
		_: return "#FFFFFF"


func _target_type_to_string(target_type: int) -> String:
	"""Convierte TargetType enum a string"""
	match target_type:
		0: return format_player(0)  # SELF
		1: return format_player(1)  # OPPONENT
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
		"turn": _current_turn,
		"phase": _current_phase_name
	}

	emit_signal("sync_to_opponent", "chain_start", sync_data)
	emit_signal("public_action_occurred", sync_data)


func _broadcast_chain_complete(success_count: int, fail_count: int) -> void:
	"""Broadcast fin de cadena a ambos jugadores"""
	var sync_data = {
		"type": "chain_complete",
		"success_count": success_count,
		"fail_count": fail_count,
		"turn": _current_turn
	}

	emit_signal("sync_to_opponent", "chain_complete", sync_data)
	emit_signal("public_action_occurred", sync_data)


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
		"turn": _current_turn,
		"phase": _current_phase_name,
		"timestamp": Time.get_unix_time_from_system()
	}

	# Emitir a todos los listeners
	emit_signal("public_action_occurred", sync_data)
	emit_signal("sync_to_opponent", "action_executed", sync_data)

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
		"turn": _current_turn,
		"phase": _current_phase_name
	}

	emit_signal("public_action_occurred", sync_data)
	emit_signal("sync_to_opponent", "response_window", sync_data)


# =============================================================================
# HEADERS DE FASE Y TURNO
# =============================================================================
func _add_phase_header(phase: int) -> void:
	"""Agrega un header de fase al log"""
	if phase == _current_phase:
		return  # Evitar duplicados

	_current_phase = phase
	_current_phase_name = _phase_to_string(phase)

	# Header visual de fase
	var header = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	var phase_line = "       ⚔ FASE DE %s ⚔" % _current_phase_name.to_upper()

	add_entry("phase_header", header, {"phase": phase}, 1)
	add_entry("phase_header", phase_line, {"phase": phase}, 1)
	add_entry("phase_header", header, {"phase": phase}, 1)

	# Broadcast a ambos clientes
	_broadcast_phase_change(phase)


func _add_turn_header(turn_number: int, player_id: int) -> void:
	"""Agrega un header de turno al log"""
	var border = "╔══════════════════════════════════════════════╗"
	var content = "║           TURNO %d - %s            ║" % [turn_number, "JUGADOR %d" % (player_id + 1)]
	var bottom = "╚══════════════════════════════════════════════╝"

	add_entry("turn_header", "")  # Línea vacía
	add_entry("turn_header", border, {"turn": turn_number}, 1)
	add_entry("turn_header", content, {"turn": turn_number, "player": player_id}, 1)
	add_entry("turn_header", bottom, {"turn": turn_number}, 1)

	# Broadcast a ambos clientes
	_broadcast_turn_start(turn_number, player_id)


# =============================================================================
# SISTEMA DE FORMATO BBCode
# =============================================================================
func format_card(card_name: String) -> String:
	"""Formatea nombre de carta con color dorado y negrita"""
	if card_name.is_empty() or card_name == "???":
		return "[color=#888888]carta desconocida[/color]"
	return "[b][color=#FFD700]%s[/color][/b]" % card_name


func format_effect(text: String, effect_type: String = "") -> String:
	"""Formatea tipo de efecto con su color correspondiente"""
	var color = COLORS.get(effect_type.to_lower(), "#FFFFFF")
	return "[color=%s]%s[/color]" % [color, text]


func format_player(player_id: int) -> String:
	"""Formatea nombre de jugador con color"""
	var color = COLORS.player1 if player_id == 0 else COLORS.player2
	var name = "Jugador 1" if player_id == 0 else "Jugador 2"
	return "[color=%s]%s[/color]" % [color, name]


func format_zone(zone_name: String) -> String:
	"""Formatea nombre de zona con color"""
	var zone_lower = zone_name.to_lower()
	var color = COLORS.get(zone_lower, "#AAAAAA")

	var display_name = zone_name
	match zone_lower:
		"deck", "castillo": display_name = "Castillo"
		"hand", "mano": display_name = "Mano"
		"field", "campo": display_name = "Campo"
		"graveyard", "cemetery", "cementerio": display_name = "Cementerio"
		"exile", "destierro": display_name = "Destierro"

	return "[color=%s]%s[/color]" % [color, display_name]


func format_status(status: String, override_type: String = "") -> String:
	"""Formatea estado con color y símbolo"""
	var type_key = override_type if not override_type.is_empty() else status
	var color = COLORS.get(type_key, "#FFFFFF")

	var symbol = ""
	match status.to_lower():
		"success": symbol = "✓"
		"failure": symbol = "✗"
		"warning": symbol = "⚠"
		"pasó": symbol = "⏭"

	var text = symbol + " " + status if not symbol.is_empty() else status
	return "[color=%s]%s[/color]" % [color, text]


func format_phase(phase_name: String) -> String:
	"""Formatea nombre de fase"""
	return "[color=%s][b]%s[/b][/color]" % [COLORS.phase, phase_name.to_upper()]


func format_number(value: int, context: String = "") -> String:
	"""Formatea número con color según contexto"""
	var color = COLORS.get(context, "#FFFFFF")
	return "[color=%s][b]%d[/b][/color]" % [color, value]


func format_timestamp() -> String:
	"""Formatea timestamp actual"""
	var time = Time.get_time_string_from_system()
	return "[color=#666666][%s][/color]" % time.substr(0, 5)


# =============================================================================
# GESTIÓN DE ENTRADAS
# =============================================================================
func add_entry(type: String, message: String, data: Dictionary = {}, level: int = 0) -> void:
	"""Agrega una entrada al log

	Args:
		type: Tipo de entrada (draw, destroy, phase, etc.)
		message: Mensaje formateado con BBCode
		data: Datos adicionales para referencia
		level: Nivel de importancia (0=all, 1=important, 2=critical)
	"""
	if level < _log_level:
		return

	var entry = {
		"timestamp": Time.get_unix_time_from_system(),
		"time_string": Time.get_time_string_from_system().substr(0, 8),
		"type": type,
		"message": message,
		"data": data,
		"level": level,
		"phase": _current_phase_name,
		"turn": _current_turn,
		"is_public": type in PUBLIC_ACTIONS
	}

	_log_entries.append(entry)

	# Limitar tamaño del log
	while _log_entries.size() > _max_entries:
		_log_entries.pop_front()

	emit_signal("log_entry_added", entry)

	# Si es acción pública, broadcast a ambos clientes
	if entry.is_public:
		_broadcast_public_action(entry)

	# Debug print
	var plain_text = _strip_bbcode(message)
	print("[CombatLog] %s" % plain_text)


# =============================================================================
# BROADCASTING - VISIBILIDAD MULTIPLAYER
# =============================================================================
func _broadcast_public_action(entry: Dictionary) -> void:
	"""Emite señal para sincronizar acción pública con ambos clientes

	Acciones públicas son visibles para ambos jugadores:
	- Botar (mill): Las cartas van al cementerio visible
	- Mostrar (reveal): Cartas reveladas
	- Buscar (search): El resultado de la búsqueda
	- Destruir/Desterrar: Cartas que cambian de zona públicamente
	"""
	var sync_data = {
		"type": entry.type,
		"message": entry.message,
		"data": entry.data,
		"timestamp": entry.timestamp,
		"phase": entry.phase,
		"turn": entry.turn
	}

	emit_signal("public_action_occurred", sync_data)
	emit_signal("sync_to_opponent", entry.type, sync_data)

	# TODO: Aquí se conectaría con el sistema de networking
	# NetworkManager.broadcast_to_all(sync_data)


func _broadcast_phase_change(phase: int) -> void:
	"""Sincroniza cambio de fase con ambos clientes"""
	var sync_data = {
		"type": "phase_change",
		"phase": phase,
		"phase_name": _phase_to_string(phase),
		"turn": _current_turn
	}

	emit_signal("sync_to_opponent", "phase_change", sync_data)


func _broadcast_turn_start(turn_number: int, player_id: int) -> void:
	"""Sincroniza inicio de turno con ambos clientes"""
	var sync_data = {
		"type": "turn_start",
		"turn": turn_number,
		"active_player": player_id
	}

	emit_signal("sync_to_opponent", "turn_start", sync_data)


func receive_remote_entry(entry_data: Dictionary) -> void:
	"""Recibe una entrada de log desde el cliente remoto

	Usado para sincronizar el log entre clientes en multiplayer.

	Args:
		entry_data: Datos de la entrada recibida
	"""
	var entry = {
		"timestamp": entry_data.get("timestamp", Time.get_unix_time_from_system()),
		"time_string": Time.get_time_string_from_system().substr(0, 8),
		"type": entry_data.get("type", "remote"),
		"message": entry_data.get("message", ""),
		"data": entry_data.get("data", {}),
		"level": entry_data.get("level", 0),
		"phase": entry_data.get("phase", ""),
		"turn": entry_data.get("turn", 0),
		"is_public": true,
		"is_remote": true
	}

	_log_entries.append(entry)
	emit_signal("log_entry_added", entry)


func get_public_entries_since(timestamp: float) -> Array[Dictionary]:
	"""Obtiene entradas públicas desde un timestamp

	Útil para sincronización cuando un cliente se reconecta.

	Args:
		timestamp: Timestamp desde el cual obtener entradas

	Returns: Array de entradas públicas
	"""
	var result: Array[Dictionary] = []

	for entry in _log_entries:
		if entry.timestamp > timestamp and entry.get("is_public", false):
			result.append(entry)

	return result


func get_entries(count: int = -1, type_filter: String = "") -> Array[Dictionary]:
	"""Obtiene entradas del log

	Args:
		count: Número de entradas (-1 para todas)
		type_filter: Filtrar por tipo (vacío para todos)
	"""
	var result: Array[Dictionary] = []

	for entry in _log_entries:
		if type_filter.is_empty() or entry.type == type_filter:
			result.append(entry)

	if count > 0 and result.size() > count:
		return result.slice(-count)

	return result


func get_formatted_log(count: int = -1, include_timestamp: bool = true) -> String:
	"""Obtiene el log formateado como string BBCode"""
	var entries = get_entries(count)
	var lines: Array[String] = []

	for entry in entries:
		var line = ""
		if include_timestamp and _show_timestamps:
			line = "[color=#666666][%s][/color] " % entry.time_string
		line += entry.message
		lines.append(line)

	return "\n".join(lines)


func clear() -> void:
	"""Limpia el log"""
	_log_entries.clear()
	emit_signal("log_cleared")


# =============================================================================
# UTILIDADES
# =============================================================================
func _get_card_name(card) -> String:
	"""Obtiene el nombre de una carta (Node o Dictionary)"""
	if card == null:
		return "???"

	if card is Dictionary:
		return card.get("name", card.get("nombre", "???"))

	if card is Node:
		if card.get("card_name"):
			return card.card_name
		if card.has_method("get_card_name"):
			return card.get_card_name()

	return "???"


func _get_card_names(cards: Array) -> Array[String]:
	"""Obtiene nombres de múltiples cartas"""
	var names: Array[String] = []
	for card in cards:
		names.append(_get_card_name(card))
	return names


func _format_card_list(names: Array) -> String:
	"""Formatea lista de cartas"""
	if names.is_empty():
		return "[color=#888888]ninguna[/color]"

	var formatted: Array[String] = []
	for name in names:
		formatted.append(format_card(name))

	return ", ".join(formatted)


func _zone_to_string(zone: int) -> String:
	"""Convierte enum de zona a string"""
	match zone:
		Constants.Zone.CASTILLO: return "castillo"
		Constants.Zone.MANO: return "mano"
		Constants.Zone.CEMENTERIO: return "cementerio"
		Constants.Zone.DESTIERRO: return "destierro"
		Constants.Zone.LINEA_ATAQUE: return "línea de ataque"
		Constants.Zone.LINEA_DEFENSA: return "línea de defensa"
		Constants.Zone.LINEA_APOYO: return "línea de apoyo"
		Constants.Zone.RESERVA_ORO: return "reserva de oro"
		Constants.Zone.ORO_PAGADO: return "oro pagado"
		_: return "zona desconocida"


func _phase_to_string(phase: int) -> String:
	"""Convierte enum de fase a string usando Constants.PHASE_NAMES"""
	# Intentar usar Constants.PHASE_NAMES
	if Constants and Constants.get("PHASE_NAMES"):
		return Constants.PHASE_NAMES.get(phase, "Fase %d" % phase)

	# Fallback usando Constants.Phase enum
	match phase:
		Constants.Phase.AGRUPACION: return "Agrupación"
		Constants.Phase.VIGILIA: return "Vigilia"
		Constants.Phase.ATAQUE: return "Ataque"
		Constants.Phase.BLOQUEO: return "Bloqueo"
		Constants.Phase.GUERRA_TALISMANES: return "Guerra de Talismanes"
		Constants.Phase.ASIGNACION_DANIO: return "Asignación de Daño"
		Constants.Phase.FINAL: return "Final"
		_: return "Fase %d" % phase


func _strip_bbcode(text: String) -> String:
	"""Remueve tags BBCode para texto plano"""
	var regex = RegEx.new()
	regex.compile("\\[.*?\\]")
	return regex.sub(text, "", true)


# =============================================================================
# BLOQUES DE ACCIÓN - Contenedores Colapsables (DAR Sección 18)
# =============================================================================
## Bloques activos: {block_id: ActionBlock}
var _active_blocks: Dictionary = {}
var _block_id_counter: int = 0

class ActionBlock:
	var id: int = 0
	var card_name: String = ""
	var display_name: String = ""     # Nombre con prefijos ([EXHUMAR], etc.)
	var card_data: Dictionary = {}
	var player_id: int = 0
	var started_at: float = 0.0
	var steps: Array[Dictionary] = []
	var is_collapsed: bool = false
	var cost_breakdown: Dictionary = {}
	var has_x_cost: bool = false
	var instance_x: int = -1
	var total_cost: int = 0
	var was_annulled: bool = false
	var annuller_name: String = ""
	# Trazabilidad de origen
	var via_exhumar: bool = false     # Jugada desde Cementerio → Destino: Destierro
	var source_zone: int = -1         # Zona de origen

signal action_block_started(block: ActionBlock)
signal action_block_step_added(block: ActionBlock, step: Dictionary)
signal action_block_completed(block: ActionBlock)
signal action_block_annulled(block: ActionBlock, annuller: String)


func log_detailed_play(card_instance: Dictionary, player_id: int = 0) -> int:
	"""Inicia un bloque de acción detallado para una carta

	Agrupa todos los pasos de una carta en un contenedor visual colapsable.
	Muestra el cálculo transparente de coste para verificación de anulaciones.

	Args:
		card_instance: Datos de la carta (debe incluir instance_x si aplica)
		player_id: ID del jugador que juega la carta

	Returns:
		block_id para agregar pasos adicionales
	"""
	_block_id_counter += 1
	var block_id = _block_id_counter

	var block = ActionBlock.new()
	block.id = block_id
	block.card_name = card_instance.get("nombre", card_instance.get("name", "???"))
	block.card_data = card_instance.duplicate(true)
	block.player_id = player_id
	block.started_at = Time.get_unix_time_from_system()

	# ─────────────────────────────────────────────────────────────────────────
	# CÁLCULO TRANSPARENTE DE COSTE (DAR Sección 18 - Hacer el Bien)
	# ─────────────────────────────────────────────────────────────────────────
	var base_cost = card_instance.get("coste", 0)
	if base_cost is String:
		base_cost = 0  # Será calculado con X

	block.instance_x = card_instance.get("instance_x", card_instance.get("x_value", -1))
	block.has_x_cost = block.instance_x >= 0

	if block.has_x_cost:
		var x_total = card_instance.get("x_total_cost", -1)
		if x_total >= 0:
			block.total_cost = x_total
		else:
			# Calcular desde fórmula
			var x_base = card_instance.get("x_base_cost", 0)
			var x_mult = card_instance.get("x_multiplier", 1)
			block.total_cost = x_base + (block.instance_x * x_mult)

		block.cost_breakdown = {
			"formula": card_instance.get("cost_formula", "X"),
			"base_cost": card_instance.get("x_base_cost", 0),
			"x_value": block.instance_x,
			"x_multiplier": card_instance.get("x_multiplier", 1),
			"total": block.total_cost
		}
	else:
		block.total_cost = base_cost if base_cost is int else 0
		block.cost_breakdown = {
			"base_cost": block.total_cost,
			"total": block.total_cost
		}

	# ─────────────────────────────────────────────────────────────────────────
	# TRAZABILIDAD DE EXHUMAR (DAR Sección 6)
	# Si viene del Cementerio, indicar que destino final = Destierro
	# ─────────────────────────────────────────────────────────────────────────
	block.via_exhumar = card_instance.get("via_exhumar", false) or \
						card_instance.get("_exhumar_flag", false)
	block.source_zone = card_instance.get("source_zone", -1)

	# Construir nombre de display con prefijos
	block.display_name = block.card_name
	if block.via_exhumar:
		block.display_name = "[EXHUMAR] " + block.card_name

	_active_blocks[block_id] = block

	# ─────────────────────────────────────────────────────────────────────────
	# LOG INICIAL DEL BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var player_str = format_player(player_id)
	var card_str = format_card(block.display_name)

	# Header del bloque
	add_entry("block_start", "╔══════════════════════════════════════════════╗", {
		"block_id": block_id
	})

	# Mensaje de jugar con indicador de Exhumar
	if block.via_exhumar:
		add_entry("block_start", "║ %s juega %s" % [player_str, card_str], {
			"block_id": block_id,
			"card": block.card_name,
			"player": player_id,
			"via_exhumar": true
		})
		add_entry("block_start", "║ [color=#9C27B0]💀 Desde CEMENTERIO → Destino: DESTIERRO[/color]", {
			"block_id": block_id,
			"source": "cemetery",
			"destination": "exile"
		})
	else:
		add_entry("block_start", "║ %s juega %s" % [player_str, card_str], {
			"block_id": block_id,
			"card": block.card_name,
			"player": player_id
		})

	# Mostrar cálculo de coste TRANSPARENTE
	_log_cost_breakdown(block)

	add_entry("block_start", "╠══════════════════════════════════════════════╣", {
		"block_id": block_id
	})

	emit_signal("action_block_started", block)

	# Broadcast para oponente
	_broadcast_detailed_play(block)

	return block_id


func _log_cost_breakdown(block: ActionBlock) -> void:
	"""Loguea el desglose de coste de forma transparente

	CRÍTICO: El oponente debe ver el coste total para saber si
	'Hacer el Bien' (anula coste ≤3) puede aplicarse.
	"""
	var breakdown = block.cost_breakdown
	var block_id = block.id

	if block.has_x_cost:
		# Coste variable X - mostrar cálculo completo
		var formula = breakdown.get("formula", "X")
		var base = breakdown.get("base_cost", 0)
		var x_val = breakdown.get("x_value", 0)
		var mult = breakdown.get("x_multiplier", 1)
		var total = breakdown.get("total", 0)

		add_entry("block_cost", "║ [color=#FFD700]💰 COSTE VARIABLE[/color]", {
			"block_id": block_id
		})

		# Mostrar fórmula
		add_entry("block_cost", "║    Fórmula: [color=#FFA500]%s[/color]" % formula, {
			"block_id": block_id
		})

		# Mostrar cálculo paso a paso
		if mult > 1:
			add_entry("block_cost", "║    X elegido: [color=#4CAF50]%d[/color] × %d = %d" % [
				x_val, mult, x_val * mult
			], {"block_id": block_id})
		else:
			add_entry("block_cost", "║    X elegido: [color=#4CAF50]%d[/color]" % x_val, {
				"block_id": block_id
			})

		if base > 0:
			add_entry("block_cost", "║    Coste base: +%d" % base, {"block_id": block_id})

		# COSTE TOTAL - VISIBLE PARA AMBOS JUGADORES
		var total_color = "#4CAF50" if total <= 3 else "#FFD700"
		var annul_warning = ""
		if total <= 3:
			annul_warning = " [color=#FF5722](⚠ Anulable por 'Hacer el Bien')[/color]"

		add_entry("block_cost", "║ ═══════════════════════════════════════════", {
			"block_id": block_id
		})
		add_entry("block_cost", "║    [b]COSTE TOTAL: [color=%s]%d ORO[/color][/b]%s" % [
			total_color, total, annul_warning
		], {
			"block_id": block_id,
			"total_cost": total,
			"can_hacer_el_bien": total <= 3
		})
	else:
		# Coste fijo normal
		var total = breakdown.get("total", 0)
		var total_color = "#4CAF50" if total <= 3 else "#FFD700"
		var annul_warning = ""
		if total <= 3:
			annul_warning = " [color=#FF5722](⚠ Anulable por 'Hacer el Bien')[/color]"

		add_entry("block_cost", "║ [color=#FFD700]💰 COSTE:[/color] [color=%s][b]%d ORO[/b][/color]%s" % [
			total_color, total, annul_warning
		], {
			"block_id": block_id,
			"total_cost": total,
			"can_hacer_el_bien": total <= 3
		})


func add_block_step(block_id: int, step_type: String, message: String, data: Dictionary = {}) -> void:
	"""Agrega un paso al bloque de acción

	Args:
		block_id: ID del bloque
		step_type: Tipo de paso (A, B, C, D, E, resolution, etc.)
		message: Mensaje del paso
		data: Datos adicionales
	"""
	if not _active_blocks.has(block_id):
		# Si no hay bloque, loguear normalmente
		add_entry(step_type, message, data)
		return

	var block = _active_blocks[block_id] as ActionBlock

	var step = {
		"type": step_type,
		"message": message,
		"data": data,
		"timestamp": Time.get_unix_time_from_system()
	}

	block.steps.append(step)

	# Formatear según tipo de paso
	var step_prefix = _get_step_prefix(step_type)
	add_entry("block_step", "║ %s %s" % [step_prefix, message], {
		"block_id": block_id,
		"step_type": step_type,
		"data": data
	})

	emit_signal("action_block_step_added", block, step)


func _get_step_prefix(step_type: String) -> String:
	"""Obtiene prefijo visual para tipo de paso"""
	match step_type.to_upper():
		"A", "STEP_A", "DECLARATION":
			return "[color=#64B5F6]A →[/color]"
		"B", "STEP_B", "PAYMENT":
			return "[color=#FFD700]B →[/color]"
		"C", "STEP_C", "TRIGGERS":
			return "[color=#BA68C8]C →[/color]"
		"D", "STEP_D", "RESPONSE":
			return "[color=#FF9800]D →[/color]"
		"E", "STEP_E", "RESOLUTION":
			return "[color=#4CAF50]E →[/color]"
		"TARGET":
			return "[color=#03A9F4]🎯[/color]"
		"EFFECT":
			return "[color=#E91E63]⚡[/color]"
		"ANNUL":
			return "[color=#FF5722]🚫[/color]"
		_:
			return "[color=#9E9E9E]•[/color]"


func complete_block(block_id: int, success: bool = true, result: Dictionary = {}) -> void:
	"""Completa un bloque de acción

	Args:
		block_id: ID del bloque
		success: Si la carta se resolvió exitosamente
		result: Resultados de la resolución
	"""
	if not _active_blocks.has(block_id):
		return

	var block = _active_blocks[block_id] as ActionBlock

	# Footer del bloque
	if block.was_annulled:
		add_entry("block_end", "║ [color=#FF5722]🚫 ANULADO por %s[/color]" % format_card(block.annuller_name), {
			"block_id": block_id
		})
	elif success:
		add_entry("block_end", "║ [color=#4CAF50]✓ RESUELTO[/color]", {
			"block_id": block_id,
			"result": result
		})
		# Indicar destino final si es Exhumar
		if block.via_exhumar:
			add_entry("block_end", "║ [color=#9C27B0]→ Destino: DESTIERRO (vía Exhumar)[/color]", {
				"block_id": block_id,
				"destination": "destierro",
				"via_exhumar": true
			})
	else:
		add_entry("block_end", "║ [color=#F44336]✗ FALLÓ[/color]", {
			"block_id": block_id,
			"result": result
		})

	add_entry("block_end", "╚══════════════════════════════════════════════╝", {
		"block_id": block_id
	})

	emit_signal("action_block_completed", block)

	# Broadcast resultado
	_broadcast_block_complete(block, success, result)

	# Limpiar
	_active_blocks.erase(block_id)


func annul_block(block_id: int, annuller_name: String, reason: String = "") -> void:
	"""Marca un bloque como anulado

	Args:
		block_id: ID del bloque
		annuller_name: Nombre de la carta que anula
		reason: Razón de la anulación
	"""
	if not _active_blocks.has(block_id):
		return

	var block = _active_blocks[block_id] as ActionBlock
	block.was_annulled = true
	block.annuller_name = annuller_name

	var reason_text = ""
	if not reason.is_empty():
		reason_text = " (%s)" % reason

	add_block_step(block_id, "ANNUL", "[color=#FF5722]%s ANULA a %s%s[/color]" % [
		format_card(annuller_name),
		format_card(block.card_name),
		reason_text
	], {
		"annuller": annuller_name,
		"target": block.card_name,
		"reason": reason
	})

	emit_signal("action_block_annulled", block, annuller_name)

	# Broadcast anulación
	_broadcast_block_annulled(block, annuller_name, reason)


func get_active_block(block_id: int) -> ActionBlock:
	"""Obtiene un bloque activo por ID"""
	return _active_blocks.get(block_id)


func get_block_cost(block_id: int) -> int:
	"""Obtiene el coste total de un bloque (para verificar 'Hacer el Bien')"""
	if not _active_blocks.has(block_id):
		return -1

	var block = _active_blocks[block_id] as ActionBlock
	return block.total_cost


func can_hacer_el_bien(block_id: int) -> bool:
	"""Verifica si 'Hacer el Bien' puede anular este bloque

	Hacer el Bien anula cartas con coste ≤ 3.
	"""
	var cost = get_block_cost(block_id)
	return cost >= 0 and cost <= 3


# =============================================================================
# EFECTOS PARCIALES - "En medida de lo posible" (DAR Sección 6)
# =============================================================================
func log_partial_effect(effect_type: String, requested: int, actual: int, target_name: String = "", context: Dictionary = {}) -> void:
	"""Loguea un efecto que se resolvió parcialmente

	Según DAR Sección 6: Los efectos se resuelven "en medida de lo posible".
	Si el oponente tiene menos cartas que X, se botan las disponibles.

	Args:
		effect_type: Tipo de efecto (mill, draw, damage, etc.)
		requested: Cantidad solicitada (valor de X)
		actual: Cantidad real ejecutada
		target_name: Nombre del objetivo (jugador, carta, etc.)
		context: Datos adicionales
	"""
	if actual >= requested:
		# Efecto completo, no es parcial
		return

	var effect_name = _effect_type_to_spanish(effect_type)
	var target_str = target_name if not target_name.is_empty() else "objetivo"

	# ─────────────────────────────────────────────────────────────────────────
	# Formato: "Botando [Actual] de X (en medida de lo posible)"
	# ─────────────────────────────────────────────────────────────────────────
	var message = "[color=#FFC107]⚠ %s [%d] de %d a %s[/color] [color=#888888](en medida de lo posible)[/color]" % [
		effect_name,
		actual,
		requested,
		target_str
	]

	add_entry("partial_effect", message, {
		"effect_type": effect_type,
		"requested": requested,
		"actual": actual,
		"target": target_name,
		"partial": true,
		"context": context
	})

	# Broadcast a ambos jugadores
	_broadcast_partial_effect(effect_type, requested, actual, target_name)


func log_partial_mill(requested: int, actual: int, player_id: int, cards_milled: Array = []) -> void:
	"""Log específico para Botar/Mill parcial

	Ejemplo: "Botando [3] de 5 (en medida de lo posible)"
	"""
	var player_str = format_player(player_id)
	var card_names = _get_card_names(cards_milled) if not cards_milled.is_empty() else []

	var message = "[color=#FFC107]⚠ Botando [%d] de %d cartas de %s[/color] [color=#888888](en medida de lo posible)[/color]" % [
		actual, requested, player_str
	]

	if not card_names.is_empty():
		message += "\n    → %s" % _format_card_list(card_names)

	add_entry("partial_mill", message, {
		"effect_type": "mill",
		"requested": requested,
		"actual": actual,
		"player": player_id,
		"cards": card_names,
		"partial": true
	})

	_broadcast_partial_effect("mill", requested, actual, "Jugador %d" % (player_id + 1))


func log_partial_draw(requested: int, actual: int, player_id: int) -> void:
	"""Log específico para Robar parcial (mazo vacío)"""
	var player_str = format_player(player_id)

	var message = "[color=#FFC107]⚠ Robando [%d] de %d cartas para %s[/color] [color=#888888](mazo agotado)[/color]" % [
		actual, requested, player_str
	]

	add_entry("partial_draw", message, {
		"effect_type": "draw",
		"requested": requested,
		"actual": actual,
		"player": player_id,
		"partial": true
	})

	_broadcast_partial_effect("draw", requested, actual, "Jugador %d" % (player_id + 1))


func log_partial_damage(requested: int, actual: int, target_name: String, reason: String = "") -> void:
	"""Log específico para Daño parcial"""
	var reason_str = ""
	if not reason.is_empty():
		reason_str = " [color=#888888](%s)[/color]" % reason

	var message = "[color=#FFC107]⚠ Infligiendo [%d] de %d daño a %s%s[/color]" % [
		actual, requested, format_card(target_name), reason_str
	]

	add_entry("partial_damage", message, {
		"effect_type": "damage",
		"requested": requested,
		"actual": actual,
		"target": target_name,
		"reason": reason,
		"partial": true
	})

	_broadcast_partial_effect("damage", requested, actual, target_name)


func log_x_effect_result(effect_type: String, x_value: int, actual: int, target_name: String, success: bool = true) -> void:
	"""Log del resultado de un efecto con X

	Muestra claramente cuánto del efecto X se resolvió.
	"""
	var effect_name = _effect_type_to_spanish(effect_type)

	if actual >= x_value:
		# Efecto completo
		var message = "[color=#4CAF50]✓ %s %d a %s (X=%d)[/color]" % [
			effect_name, actual, target_name, x_value
		]
		add_entry("x_effect", message, {
			"effect_type": effect_type,
			"x_value": x_value,
			"actual": actual,
			"target": target_name,
			"complete": true
		})
	else:
		# Efecto parcial
		var message = "[color=#FFC107]⚠ %s [%d] de X=%d a %s[/color] [color=#888888](en medida de lo posible)[/color]" % [
			effect_name, actual, x_value, target_name
		]
		add_entry("x_effect_partial", message, {
			"effect_type": effect_type,
			"x_value": x_value,
			"actual": actual,
			"target": target_name,
			"complete": false,
			"partial": true
		})


func _effect_type_to_spanish(effect_type: String) -> String:
	"""Convierte tipo de efecto a verbo en español (gerundio)"""
	match effect_type.to_lower():
		"mill", "botar": return "Botando"
		"draw", "robar": return "Robando"
		"discard", "descartar": return "Descartando"
		"damage", "daño": return "Infligiendo"
		"destroy", "destruir": return "Destruyendo"
		"banish", "desterrar": return "Desterrando"
		"heal", "curar": return "Curando"
		"buff", "fortalecer": return "Fortaleciendo"
		"debuff", "debilitar": return "Debilitando"
		_: return "Aplicando"


func _broadcast_partial_effect(effect_type: String, requested: int, actual: int, target: String) -> void:
	"""Broadcast efecto parcial a ambos jugadores"""
	var sync_data = {
		"type": "partial_effect",
		"effect_type": effect_type,
		"requested": requested,
		"actual": actual,
		"target": target,
		"turn": _current_turn,
		"phase": _current_phase_name
	}

	emit_signal("public_action_occurred", sync_data)
	emit_signal("sync_to_opponent", "partial_effect", sync_data)


# =============================================================================
# FORMATO DE CARTA CON PREFIJOS
# =============================================================================
func format_card_with_origin(card_name: String, via_exhumar: bool = false) -> String:
	"""Formatea nombre de carta con prefijo de origen si aplica"""
	var display_name = card_name
	if via_exhumar:
		display_name = "[EXHUMAR] " + card_name

	return format_card(display_name)


# =============================================================================
# BROADCASTING - BLOQUES DE ACCIÓN
# =============================================================================
func _broadcast_detailed_play(block: ActionBlock) -> void:
	"""Broadcast inicio de jugada detallada"""
	var sync_data = {
		"type": "detailed_play_start",
		"block_id": block.id,
		"card_name": block.card_name,
		"display_name": block.display_name,
		"player_id": block.player_id,
		"has_x_cost": block.has_x_cost,
		"instance_x": block.instance_x,
		"total_cost": block.total_cost,
		"cost_breakdown": block.cost_breakdown,
		"can_hacer_el_bien": block.total_cost <= 3,
		"via_exhumar": block.via_exhumar,
		"destination_if_exhumar": "destierro" if block.via_exhumar else "cementerio",
		"turn": _current_turn,
		"phase": _current_phase_name
	}

	emit_signal("public_action_occurred", sync_data)
	emit_signal("sync_to_opponent", "detailed_play_start", sync_data)


func _broadcast_block_complete(block: ActionBlock, success: bool, result: Dictionary) -> void:
	"""Broadcast finalización de bloque"""
	var sync_data = {
		"type": "detailed_play_complete",
		"block_id": block.id,
		"card_name": block.card_name,
		"success": success,
		"was_annulled": block.was_annulled,
		"annuller": block.annuller_name,
		"result": result,
		"steps_count": block.steps.size()
	}

	emit_signal("public_action_occurred", sync_data)
	emit_signal("sync_to_opponent", "detailed_play_complete", sync_data)


func _broadcast_block_annulled(block: ActionBlock, annuller: String, reason: String) -> void:
	"""Broadcast anulación de bloque"""
	var sync_data = {
		"type": "detailed_play_annulled",
		"block_id": block.id,
		"card_name": block.card_name,
		"total_cost": block.total_cost,
		"annuller": annuller,
		"reason": reason
	}

	emit_signal("public_action_occurred", sync_data)
	emit_signal("sync_to_opponent", "detailed_play_annulled", sync_data)


# =============================================================================
# LOG DE COSTE X SIMPLIFICADO (Para uso externo)
# =============================================================================
func log_x_cost_selection(card_name: String, player_id: int, x_value: int, total_cost: int, formula: String = "X") -> void:
	"""Loguea la selección de valor X de forma transparente

	Llamar desde PaymentManager cuando se confirma el valor de X.
	"""
	var player_str = format_player(player_id)
	var card_str = format_card(card_name)

	var annul_warning = ""
	if total_cost <= 3:
		annul_warning = " [color=#FF5722](⚠ Anulable)[/color]"

	add_entry("cost", "%s elige [color=#4CAF50]X = %d[/color] para %s" % [
		player_str, x_value, card_str
	], {
		"player": player_id,
		"card": card_name,
		"x_value": x_value
	})

	add_entry("cost", "   [color=#FFD700]Coste:[/color] %s → [b]%d Oro[/b]%s" % [
		formula, total_cost, annul_warning
	], {
		"formula": formula,
		"total_cost": total_cost,
		"can_annul": total_cost <= 3
	})


# =============================================================================
# CONFIGURACIÓN
# =============================================================================
func set_max_entries(max_count: int) -> void:
	_max_entries = max(100, max_count)


func set_log_level(level: int) -> void:
	_log_level = clamp(level, 0, 2)


func set_show_timestamps(show: bool) -> void:
	_show_timestamps = show


func set_auto_scroll(enabled: bool) -> void:
	_auto_scroll = enabled
