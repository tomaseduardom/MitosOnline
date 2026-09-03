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

## Señales de bloques de acción (implementados en DetailedPlayLog.gd)
signal action_block_started(block: ActionBlock)
signal action_block_step_added(block: ActionBlock, step: Dictionary)
signal action_block_completed(block: ActionBlock)
signal action_block_annulled(block: ActionBlock, annuller: String)

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

## Módulos extraídos (Fase 4 de reestructuración)
var _formatters: LogFormatters
var _detailed_play: DetailedPlayLog

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

func _ready() -> void:
	_formatters = LogFormatters.new()
	_formatters.setup(self)
	_detailed_play = DetailedPlayLog.new()
	_detailed_play.setup(self)

	call_deferred("_connect_signals")
	print("[CombatLog] Inicializado")


func _connect_signals() -> void:
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
	var card_name = _formatters.get_card_name(card)
	add_entry("ability", "Activando habilidad de %s" % [_formatters.format_card(card_name)], {
		"card": card_name,
		"trigger": ability_block.get("trigger", {})
	})


func _on_ability_completed(card: Node, result: Dictionary) -> void:
	var card_name = _formatters.get_card_name(card)
	var status = "success" if result.success else "failure"
	var effects_count = result.get("effects_resolved", []).size()

	add_entry("ability", "Habilidad de %s %s (%d efectos)" % [
		_formatters.format_card(card_name),
		_formatters.format_status(status),
		effects_count
	], result)


func _on_action_executed(action: Dictionary, result: Dictionary) -> void:
	var action_type = action.get("type", "unknown")
	var status = "success" if result.success else "failure"

	add_entry("action", "Acción %s: %s" % [
		_formatters.format_effect(action_type),
		_formatters.format_status(status)
	], {"action": action, "result": result})


func _on_draw(player_id: int, cards: Array, amount: int) -> void:
	var player = _formatters.format_player(player_id)
	var card_names = _formatters.get_card_names(cards)

	add_entry("draw", "%s %s %d carta(s): %s" % [
		player,
		_formatters.format_effect("robó", "draw"),
		amount,
		_formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names})


func _on_discard(player_id: int, cards: Array) -> void:
	var player = _formatters.format_player(player_id)
	var card_names = _formatters.get_card_names(cards)

	add_entry("discard", "%s %s: %s" % [
		player,
		_formatters.format_effect("descartó", "discard"),
		_formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names})


func _on_destroy(destroyed: Array, source: Node) -> void:
	var source_name = _formatters.get_card_name(source) if source else "efecto"
	var card_names = _formatters.get_card_names(destroyed)

	add_entry("destroy", "%s %s: %s" % [
		_formatters.format_card(source_name),
		_formatters.format_effect("destruyó", "destroy"),
		_formatters.format_card_list(card_names)
	], {"source": source_name, "destroyed": card_names})


func _on_banish(banished: Array, source: Node) -> void:
	var source_name = _formatters.get_card_name(source) if source else "efecto"
	var card_names = _formatters.get_card_names(banished)

	add_entry("banish", "%s %s: %s" % [
		_formatters.format_card(source_name),
		_formatters.format_effect("desterró", "banish"),
		_formatters.format_card_list(card_names)
	], {"source": source_name, "banished": card_names})


func _on_mill(player_id: int, cards: Array, to_exile: bool) -> void:
	var player = _formatters.format_player(player_id)
	var card_names = _formatters.get_card_names(cards)
	var destination = "destierro" if to_exile else "cementerio"

	add_entry("mill", "%s %s %d carta(s) al %s: %s" % [
		player,
		_formatters.format_effect("botó", "mill"),
		cards.size(),
		_formatters.format_zone(destination),
		_formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names, "to_exile": to_exile})


func _on_search(player_id: int, selected: Array, zone: int) -> void:
	var player = _formatters.format_player(player_id)
	var card_names = _formatters.get_card_names(selected)
	var zone_name = _formatters.zone_to_string(zone)

	add_entry("search", "%s %s en %s: %s" % [
		player,
		_formatters.format_effect("buscó", "search"),
		_formatters.format_zone(zone_name),
		_formatters.format_card_list(card_names)
	], {"player": player_id, "cards": card_names, "zone": zone})


func _on_damage(targets: Array, amount: int, source: Node) -> void:
	var source_name = _formatters.get_card_name(source) if source else "efecto"
	var target_names = _formatters.get_card_names(targets)

	add_entry("damage", "%s infligió %s de %s a: %s" % [
		_formatters.format_card(source_name),
		_formatters.format_number(amount, "damage"),
		_formatters.format_effect("daño", "damage"),
		_formatters.format_card_list(target_names)
	], {"source": source_name, "targets": target_names, "amount": amount})


func _on_buff(targets: Array, amount: int, is_buff: bool) -> void:
	var effect_type = "buff" if is_buff else "debuff"
	var effect_text = "fortaleció" if is_buff else "debilitó"
	var target_names = _formatters.get_card_names(targets)
	var sign = "+" if is_buff else ""

	add_entry(effect_type, "%s a %s (%s%d)" % [
		_formatters.format_effect(effect_text, effect_type),
		_formatters.format_card_list(target_names),
		sign,
		amount
	], {"targets": target_names, "amount": amount, "is_buff": is_buff})


func _on_heal(player_id: int, amount: int) -> void:
	var player = _formatters.format_player(player_id)

	add_entry("heal", "%s %s %s puntos de vida" % [
		player,
		_formatters.format_effect("recuperó", "heal"),
		_formatters.format_number(amount, "heal")
	], {"player": player_id, "amount": amount})


func _on_cost_paid(cost: Dictionary, success: bool) -> void:
	var cost_type = cost.get("type", "unknown")
	var amount = cost.get("amount", 1)
	var status = _formatters.format_status("success" if success else "failure")

	add_entry("cost", "Coste pagado: %s x%d %s" % [
		_formatters.format_effect(cost_type, "gold"),
		amount,
		status
	], {"cost": cost, "success": success}, 1)


func _on_execution_failed(reason: String, context: Dictionary) -> void:
	add_entry("error", "%s: %s" % [
		_formatters.format_status("failure"),
		reason
	], context)


func _on_response_window(card: Node, context: Dictionary) -> void:
	var card_name = context.get("card_name", _formatters.get_card_name(card))
	add_entry("response", "⏳ Ventana de respuesta para %s" % [
		_formatters.format_card(card_name)
	], context)


func _on_opponent_passed() -> void:
	add_entry("response", "%s %s" % [
		_formatters.format_player(1),
		_formatters.format_status("pasó", "info")
	])


func _on_opponent_responded(response_card: Node) -> void:
	var card_name = _formatters.get_card_name(response_card)
	add_entry("response", "%s respondió con %s" % [
		_formatters.format_player(1),
		_formatters.format_card(card_name)
	])


func _on_spell_annulled(annulled_card: Node, annuller_card: Node) -> void:
	var annulled_name = _formatters.get_card_name(annulled_card)
	var annuller_name = _formatters.get_card_name(annuller_card)

	add_entry("annul", "🚫 %s %s a %s" % [
		_formatters.format_card(annuller_name),
		_formatters.format_effect("ANULÓ", "annul"),
		_formatters.format_card(annulled_name)
	], {"annulled": annulled_name, "annuller": annuller_name})


func _on_resolution_started(card: Node, effects: Array) -> void:
	var card_name = _formatters.get_card_name(card)
	add_entry("resolution", "▶ Resolviendo %s (%d efectos)" % [
		_formatters.format_card(card_name),
		effects.size()
	], {"card": card_name, "effects_count": effects.size()})


func _on_resolution_completed(card: Node, success: bool, effects_resolved: int) -> void:
	var card_name = _formatters.get_card_name(card)
	var status = _formatters.format_status("success" if success else "failure")

	add_entry("resolution", "✓ Resolución de %s %s (%d efectos)" % [
		_formatters.format_card(card_name),
		status,
		effects_resolved
	], {"card": card_name, "success": success, "effects": effects_resolved})


func _on_post_resolution(card: Node, condition: String, destination: String) -> void:
	var card_name = _formatters.get_card_name(card)

	add_entry("resolution", "→ %s: %s va a %s" % [
		_formatters.format_phase(condition),
		_formatters.format_card(card_name),
		_formatters.format_zone(destination)
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
		_formatters.format_player(player_id)
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
		_formatters.format_player(player_id)
	], {}, 1)


func _on_priority_opened(player_id: int, phase) -> void:
	"""Handler cuando se abre ventana de prioridad"""
	add_entry("priority", "⏳ %s tiene prioridad" % _formatters.format_player(player_id), {
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
		_formatters.format_card(card_name),
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
		_formatters.format_number(success_count, "success"),
		_formatters.format_number(fail_count, "failure")
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
		status_str = _formatters.format_status("success")
	elif partial:
		status_str = "[color=#FFC107]parcial[/color]"
	else:
		status_str = _formatters.format_status("failure")

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
		_formatters.format_card(card_name)
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
		0: return _formatters.format_player(0)  # SELF
		1: return _formatters.format_player(1)  # OPPONENT
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
	_current_phase_name = _formatters.phase_to_string(phase)

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
# SISTEMA DE FORMATO BBCode (implementación en LogFormatters.gd)
# =============================================================================
func format_card(card_name: String) -> String:
	return _formatters.format_card(card_name)


func format_card_with_origin(card_name: String, via_exhumar: bool = false) -> String:
	return _formatters.format_card_with_origin(card_name, via_exhumar)


func format_effect(text: String, effect_type: String = "") -> String:
	return _formatters.format_effect(text, effect_type)


func format_player(player_id: int) -> String:
	return _formatters.format_player(player_id)


func format_zone(zone_name: String) -> String:
	return _formatters.format_zone(zone_name)


func format_status(status: String, override_type: String = "") -> String:
	return _formatters.format_status(status, override_type)


func format_phase(phase_name: String) -> String:
	return _formatters.format_phase(phase_name)


func format_number(value: int, context: String = "") -> String:
	return _formatters.format_number(value, context)


func format_timestamp() -> String:
	return _formatters.format_timestamp()


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
	var plain_text = _formatters.strip_bbcode(message)
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
		"phase_name": _formatters.phase_to_string(phase),
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
# BLOQUES DE ACCIÓN Y LOGS ESPECIALES (implementación en DetailedPlayLog.gd)
# =============================================================================
func log_detailed_play(card_instance: Dictionary, player_id: int = 0) -> int:
	return _detailed_play.log_detailed_play(card_instance, player_id)


func add_block_step(block_id: int, step_type: String, message: String, data: Dictionary = {}) -> void:
	_detailed_play.add_block_step(block_id, step_type, message, data)


func complete_block(block_id: int, success: bool = true, result: Dictionary = {}) -> void:
	_detailed_play.complete_block(block_id, success, result)


func annul_block(block_id: int, annuller_name: String, reason: String = "") -> void:
	_detailed_play.annul_block(block_id, annuller_name, reason)


func get_active_block(block_id: int) -> ActionBlock:
	return _detailed_play.get_active_block(block_id)


func get_block_cost(block_id: int) -> int:
	return _detailed_play.get_block_cost(block_id)


func can_hacer_el_bien(block_id: int) -> bool:
	return _detailed_play.can_hacer_el_bien(block_id)


func log_partial_effect(effect_type: String, requested: int, actual: int, target_name: String = "", context: Dictionary = {}) -> void:
	_detailed_play.log_partial_effect(effect_type, requested, actual, target_name, context)


func log_partial_mill(requested: int, actual: int, player_id: int, cards_milled: Array = []) -> void:
	_detailed_play.log_partial_mill(requested, actual, player_id, cards_milled)


func log_partial_draw(requested: int, actual: int, player_id: int) -> void:
	_detailed_play.log_partial_draw(requested, actual, player_id)


func log_partial_damage(requested: int, actual: int, target_name: String, reason: String = "") -> void:
	_detailed_play.log_partial_damage(requested, actual, target_name, reason)


func log_x_effect_result(effect_type: String, x_value: int, actual: int, target_name: String, success: bool = true) -> void:
	_detailed_play.log_x_effect_result(effect_type, x_value, actual, target_name, success)


func log_x_cost_selection(card_name: String, player_id: int, x_value: int, total_cost: int, formula: String = "X") -> void:
	_detailed_play.log_x_cost_selection(card_name, player_id, x_value, total_cost, formula)


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
