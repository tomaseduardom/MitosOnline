extends Node
## CombatLog - Sistema de registro de acciones del ActionPipeline
## Escucha señales globales y formatea mensajes con BBCode
## Los handlers de esas señales (~25 funciones _on_*, nunca llamadas por
## nombre desde fuera de este archivo) y el broadcast de acciones del parser
## viven en CombatLogSignalHandlers.gd (Fase 4 de reestructuración).

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
var _signal_handlers: RefCounted

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
	_signal_handlers = preload("res://scripts/core/logging/CombatLogSignalHandlers.gd").new()
	_signal_handlers.setup(self)

	call_deferred("_connect_signals")
	print("[CombatLog] Inicializado")


func _connect_signals() -> void:
	_signal_handlers.connect_signals()


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
