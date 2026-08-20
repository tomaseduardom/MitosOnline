extends Node
## UniversalCardParser - Parsea textos de habilidades a objetos Action ejecutables
## Maneja conectores (Luego, Y, O), ventanas de respuesta, y resolución de cadenas

# =============================================================================
# SEÑALES
# =============================================================================
signal parsing_completed(card_name: String, actions: Array)
signal chain_resolution_started(actions: Array)
signal chain_resolution_completed(results: Array)
signal action_resolved(action: Dictionary, result: Dictionary)
signal response_window_requested(card_data: Dictionary, pending_actions: Array)

# =============================================================================
# ENUMS
# =============================================================================
enum ActionType {
	DRAW,           # Robar cartas
	MILL,           # Botar del mazo al cementerio
	DISCARD,        # Descartar de la mano
	DESTROY,        # Destruir carta en juego
	BANISH,         # Desterrar carta
	SEARCH,         # Buscar en zona
	DAMAGE,         # Infligir daño
	BUFF,           # Aumentar stats
	DEBUFF,         # Reducir stats
	HEAL,           # Curar/recuperar vida
	RETURN_HAND,    # Devolver a la mano
	RETURN_DECK,    # Devolver al mazo
	REVEAL,         # Revelar cartas
	LOOK,           # Mirar cartas (privado)
	SHUFFLE,        # Barajar mazo
	TAP,            # Girar carta
	UNTAP,          # Enderezar carta
	CREATE_TOKEN,   # Crear token
	COPY,           # Copiar carta/efecto
	COUNTER,        # Contrarrestar/anular
	MOVE,           # Mover carta de zona
	GOLD,           # Generar oro virtual
	SILENCE,        # Quitar todas las keywords/habilidades de una carta
	PREVENT_DAMAGE, # Prevenir daño futuro
	CUSTOM          # Efecto personalizado
}

enum Connector {
	NONE,           # Sin conector (primera acción)
	Y,              # Y - siempre continúa
	LUEGO,          # Luego - requiere éxito previo
	O,              # O - continúa si anterior falló
	EN_MEDIDA       # En medida de lo posible - ejecución parcial OK
}

## Tipo de coste de habilidad activada
enum CostType {
	NONE,           # Sin coste identificado (no es activada)
	ONCE_PER_TURN,  # Una vez por turno
	GOLD,           # Paga X Oro
	DISCARD,        # Descarta una carta
	TAP,            # Gira esta carta
}

enum TargetType {
	SELF,           # El jugador que controla la carta
	OPPONENT,       # El oponente
	BOTH,           # Ambos jugadores
	CARD_SELF,      # La carta misma
	CARD_TARGET,    # Carta objetivo (selección)
	CARD_ALL,       # Todas las cartas (de un tipo/zona)
	CARD_RANDOM,    # Carta aleatoria
	ZONE            # Una zona específica
}

# =============================================================================
# PATRONES DE TEXTO (Español)
# =============================================================================
const PATTERNS = {
	# Robar
	"draw": [
		"roba (\\d+) cartas?",
		"robas? (\\d+) cartas?",
		"roba una carta",
		"robar (\\d+) cartas?"
	],
	# Botar (Mill)
	"mill": [
		"bota (\\d+) cartas? del mazo",
		"bota las (\\d+) primeras cartas",
		"el oponente bota (\\d+)",
		"oponente bota (\\d+) cartas?"
	],
	# Descartar
	"discard": [
		"descarta (\\d+) cartas?",
		"descartas? (\\d+) cartas?",
		"descarta una carta",
		"descarta al azar"
	],
	# Destruir
	"destroy": [
		"destruye (\\d+|una?|todas?)",
		"destruir (\\d+|una?|todas?)",
		"es destruida"
	],
	# Desterrar
	"banish": [
		"destierra (\\d+|una?|todas?)",
		"desterrar (\\d+|una?|todas?)",
		"destiérrala",
		"al destierro"
	],
	# Buscar
	"search": [
		"busca (\\d+|una?) cartas?",
		"buscar en tu mazo",
		"busca en tu (?:mazo|castillo)"
	],
	# Daño
	"damage": [
		"inflige (\\d+) de daño",
		"hace (\\d+) de daño",
		"recibe (\\d+) de daño"
	],
	# Buff/Debuff
	"buff": [
		"obtiene \\+(\\d+)/\\+(\\d+)",
		"gana \\+(\\d+) de fuerza",
		"\\+(\\d+)/\\+(\\d+)"
	],
	"debuff": [
		"obtiene -(\\d+)/-(\\d+)",
		"pierde (\\d+) de fuerza",
		"-(\\d+)/-(\\d+)"
	],
	# Devolver
	"return_hand": [
		"devuelve a la mano",
		"regresa a la mano",
		"vuelve a tu mano"
	],
	"return_deck": [
		"devuelve al mazo",
		"pon en el fondo del mazo",
		"baraja en el mazo"
	],
	# Revelar
	"reveal": [
		"revela (\\d+|una?|las?) cartas?",
		"muestra (\\d+|una?|las?) cartas?"
	],
	# Mirar
	"look": [
		"mira las? (\\d+) primeras? cartas?",
		"mira el tope de"
	]
}

# Patrones de conectores
const CONNECTOR_PATTERNS = {
	"luego": ["luego,?", "después,?", "entonces,?", "a continuación,?"],
	"y": ["y ", ", y "],
	"o": [" o ", ", o "],
	"en_medida": ["en medida de lo posible", "si es posible", "hasta donde sea posible"]
}

# Patrones de objetivo
const TARGET_PATTERNS = {
	"opponent": ["el oponente", "tu oponente", "oponente", "rival"],
	"self": ["tú", "tu ", "robas", "buscas", "descartas"],
	"all": ["todas las", "todos los", "cada"],
	"random": ["al azar", "aleatoria", "aleatorio"]
}

# =============================================================================
# WORD_TO_INT — Conversión de números escritos a enteros
# Usado por extract_action() y _parse_amount() para cubrir las 2000 cartas.
# =============================================================================
const WORD_TO_INT: Dictionary = {
	"cero": 0,
	"un": 1,  "uno": 1,  "una": 1,
	"dos": 2,
	"tres": 3,
	"cuatro": 4,
	"cinco": 5,
	"seis": 6,
	"siete": 7,
	"ocho": 8,
	"nueve": 9,
	"diez": 10,
	"once": 11,
	"doce": 12,
	"todas": -1, "todos": -1, "all": -1,
}

# =============================================================================
# ABILITY_PATTERNS — Compilador Fase 1
# Mapa canónico: Regex → Función de Manager
# Cada entrada asocia un patrón de texto con el manager y método que lo ejecuta.
# Usado por parse_abilities() para compilar texto natural a GameAction ejecutables.
# =============================================================================
const ABILITY_PATTERNS: Dictionary = {
	"DRAW": {
		"regex":        "roba (\\d+) cartas?|roba una carta",
		"manager_path": "/root/ActionModule",
		"method":       "draw",
		"action_type":  ActionType.DRAW,
		"group_amount": 1,
	},
	"MILL": {
		"regex":        "bota (\\d+) cartas? del mazo|bota las (\\d+) primeras",
		"manager_path": "/root/ActionModule",
		"method":       "mill",
		"action_type":  ActionType.MILL,
		"group_amount": 1,
	},
	"DISCARD": {
		"regex":        "descarta (\\d+|una?) cartas?|descarta una carta|descarta al azar",
		"manager_path": "/root/ActionModule",
		"method":       "discard",
		"action_type":  ActionType.DISCARD,
		"group_amount": 1,
	},
	"DESTROY": {
		"regex":        "destruye (\\d+|una?|todas?)|destruir (\\d+|una?|todas?)",
		"manager_path": "/root/ActionModule",
		"method":       "destroy",
		"action_type":  ActionType.DESTROY,
		"group_amount": 1,
	},
	"BANISH": {
		"regex":        "destierra (\\d+|una?|todas?)|desterrar (\\d+|una?)",
		"manager_path": "/root/ActionModule",
		"method":       "banish",
		"action_type":  ActionType.BANISH,
		"group_amount": 1,
	},
	"SEARCH": {
		# Regex amplio solo para DETECTAR que hay una búsqueda — el detalle
		# (zona, tipo de carta, cantidad, si se puede jugar) lo extrae
		# TriggerSystem._execute_targeted_search() releyendo el texto
		# completo de la carta, no este único grupo de captura.
		"regex":        "busca (?:\\d+|una?|un) (?:cartas?|aliados?|talismanes?|talisman|tótems?|totems?|armas?|oros?)|busca en tu (?:mazo|castillo|cementerio)",
		"manager_path": "/root/ActionModule",
		"method":       "search",
		"action_type":  ActionType.SEARCH,
		"group_amount": 0,
	},
	"SHUFFLE": {
		"regex":        "baraja(?: el mazo| en el mazo)?",
		"manager_path": "/root/ActionModule",
		"method":       "shuffle_deck",
		"action_type":  ActionType.SHUFFLE,
		"group_amount": 0,
	},
	"DAMAGE": {
		"regex":        "inflige (\\d+) de daño|hace (\\d+) de daño|recibe (\\d+) de daño",
		"manager_path": "/root/DamageManager",
		"method":       "apply_damage",
		"action_type":  ActionType.DAMAGE,
		"group_amount": 1,
	},
	"BUFF": {
		# Los Aliados tienen un único indicador de Fuerza (que también es su
		# vida/resistencia) — no hay par ataque/defensa como en otros CCG.
		"regex":        "(?:obtiene|gana) \\+(\\d+)(?: de fuerza)?",
		"manager_path": "/root/ContinuousEffectManager",
		"method":       "register_modifier",
		"action_type":  ActionType.BUFF,
		"group_amount": 1,
	},
	"DEBUFF": {
		"regex":        "obtiene -(\\d+)(?: de fuerza)?",
		"manager_path": "/root/ContinuousEffectManager",
		"method":       "register_modifier",
		"action_type":  ActionType.DEBUFF,
		"group_amount": 1,
	},
	"RETURN_HAND": {
		"regex":        "devuelve a la mano|regresa a la mano|vuelve a tu mano",
		"manager_path": "/root/ActionModule",
		"method":       "return_to_hand",
		"action_type":  ActionType.RETURN_HAND,
		"group_amount": 0,
	},
	"RETURN_DECK": {
		"regex":        "devuelve al mazo|pon en el fondo del mazo",
		"manager_path": "/root/ActionModule",
		"method":       "return_to_deck",
		"action_type":  ActionType.RETURN_DECK,
		"group_amount": 0,
	},
	"GOLD": {
		"regex":        "genera (\\d+) oro virtual|añade (\\d+) oro",
		"manager_path": "/root/PaymentManager",
		"method":       "generar_oros_virtuales",
		"action_type":  ActionType.GOLD,
		"group_amount": 1,
	},
	"LOOK": {
		"regex":        "mira[s]? (\\d+|una|dos|tres|cuatro|cinco|seis|siete|ocho) cartas? del tope",
		"manager_path": "/root/CardManager",
		"method":       "get_deck",
		"action_type":  ActionType.LOOK,
		"group_amount": 1,
	},
	"REVEAL": {
		"regex":        "(?:revela|muestra)[s]? (\\d+|una|dos|tres|cuatro|cinco|seis|siete|ocho) cartas? del tope",
		"manager_path": "/root/CardManager",
		"method":       "get_deck",
		"action_type":  ActionType.REVEAL,
		"group_amount": 1,
	},
	"SILENCE": {
		"regex":        "pierde todas sus habilidades|no tiene habilidades ni palabras clave|es silenciad[oa]",
		"manager_path": "/root/KeywordManager",
		"method":       "silence_card",
		"action_type":  ActionType.SILENCE,
		"group_amount": 0,
	},
	"PREVENT_DAMAGE": {
		"regex":        "previene[s]? (\\d+) de daño",
		"manager_path": "/root/DamageManager",
		"method":       "add_damage_prevention",
		"action_type":  ActionType.PREVENT_DAMAGE,
		"group_amount": 1,
	},
	"ANNUL": {
		# Palabras reutilizadas de TargetSelector._text_contains_annul()/
		# _text_contains_cancel() (líneas ~272-287) — mismo vocabulario que ya
		# usa el sistema de contra-magia de bajo nivel, aquí conectado a una
		# resolución directa (sin ventana de respuesta, ver plan de alcance).
		# Destino por defecto: Cementerio (destroy) — solo va a Destierro
		# (banish) si el propio texto de la carta lo dice explícitamente.
		"regex":        "(?:anula|anular|cancela|cancelar|contrarresta) (?:a )?(?:un|el) aliado",
		"manager_path": "/root/ActionModule",
		"method":       "destroy",
		"action_type":  ActionType.COUNTER,
		"group_amount": 0,
	},
}

# Frases de Trigger canónicas → nombre de evento interno
const TRIGGER_EVENTS: Dictionary = {
	"cuando entra":      "ENTER",
	"al entrar":         "ENTER",
	"al salir":          "EXIT",
	"cuando sale":       "EXIT",
	"al atacar":         "ATTACK",
	"cuando ataca":      "ATTACK",
	"al bloquear":       "BLOCK",
	"al morir":          "DIE",
	"cuando es destruida": "DIE",
	"al comienzo de":    "TURN_START",
	"al inicio de":      "TURN_START",
	"al final del turno": "TURN_END",
}

# =============================================================================
# TURN REGISTRY — Registro de habilidades de "Una vez por turno"
# =============================================================================
class TurnRegistry:
	## Registra qué habilidades "Una vez por turno" ya se usaron.
	## Clave: "card_id|ability_index|turn_number"
	var _used: Dictionary = {}

	func register(card_id: String, ability_index: int, turn: int) -> void:
		_used["%s|%d|%d" % [card_id, ability_index, turn]] = true

	func was_used(card_id: String, ability_index: int, turn: int) -> bool:
		return _used.has("%s|%d|%d" % [card_id, ability_index, turn])

	func reset_for_turn(turn: int) -> void:
		"""Limpia las entradas del turno anterior al comenzar un turno nuevo."""
		var to_remove: Array = []
		for key: String in _used:
			if key.ends_with("|%d" % (turn - 1)):
				to_remove.append(key)
		for key in to_remove:
			_used.erase(key)

	func clear_all() -> void:
		_used.clear()


# =============================================================================
# REFERENCIAS
# =============================================================================
var _action_executor: Node = null
## Registro de usos "Una vez por turno" — compartido con ActionPipeline
var turn_registry: TurnRegistry = TurnRegistry.new()


func _ready() -> void:
	call_deferred("_get_references")


func _get_references() -> void:
	_action_executor = get_node_or_null("/root/ActionExecutor")
	# Resetear TurnRegistry al inicio de cada turno nuevo
	var gm := get_node_or_null("/root/GameManager")
	if gm and gm.has_signal("turn_started"):
		if not gm.turn_started.is_connected(_on_turn_started_reset_registry):
			gm.turn_started.connect(_on_turn_started_reset_registry)


func _on_turn_started_reset_registry(_player_id: int, turn_number: int) -> void:
	turn_registry.reset_for_turn(turn_number)


# =============================================================================
# PARSING PRINCIPAL
# =============================================================================
func parse_ability_text(ability_text: String, card_data: Dictionary = {}) -> Array[Dictionary]:
	"""Parsea el texto de una habilidad y retorna un array de acciones

	Args:
		ability_text: Texto de la habilidad (ej: "Roba 2 cartas. Luego, el oponente bota 3.")
		card_data: Datos opcionales de la carta para contexto

	Returns: Array de objetos Action [{type, amount, target, connector, raw_text}]
	"""
	var actions: Array[Dictionary] = []

	if ability_text.is_empty():
		return actions

	# Normalizar texto
	var text = ability_text.to_lower().strip_edges()

	# Dividir por oraciones/conectores
	var segments = _split_by_connectors(text)

	for i in range(segments.size()):
		var segment = segments[i]
		var action = _parse_segment(segment.text, segment.connector)

		if not action.is_empty():
			action["index"] = i
			action["raw_text"] = segment.text
			actions.append(action)

	emit_signal("parsing_completed", card_data.get("name", "???"), actions)
	return actions


func _split_by_connectors(text: String) -> Array[Dictionary]:
	"""Divide el texto en segmentos por conectores

	Returns: [{text, connector}]
	"""
	var segments: Array[Dictionary] = []
	var current_text = text
	var current_connector = Connector.NONE

	# Primero, marcar posiciones de conectores
	var connector_positions: Array[Dictionary] = []

	# Buscar "luego"
	for pattern in CONNECTOR_PATTERNS.luego:
		var regex = RegEx.new()
		regex.compile("(?i)" + pattern)
		var matches = regex.search_all(current_text)
		for m in matches:
			connector_positions.append({
				"pos": m.get_start(),
				"end": m.get_end(),
				"type": Connector.LUEGO
			})

	# Buscar "en medida de lo posible"
	for pattern in CONNECTOR_PATTERNS.en_medida:
		var regex = RegEx.new()
		regex.compile("(?i)" + pattern)
		var matches = regex.search_all(current_text)
		for m in matches:
			connector_positions.append({
				"pos": m.get_start(),
				"end": m.get_end(),
				"type": Connector.EN_MEDIDA
			})

	# Ordenar por posición
	connector_positions.sort_custom(func(a, b): return a.pos < b.pos)

	# Si no hay conectores, retornar todo como un segmento
	if connector_positions.is_empty():
		# Dividir por puntos
		var sentences = text.split(".")
		for sentence in sentences:
			var clean = sentence.strip_edges()
			if not clean.is_empty():
				segments.append({
					"text": clean,
					"connector": Connector.NONE if segments.is_empty() else Connector.Y
				})
		return segments

	# Extraer segmentos entre conectores
	var last_end = 0
	for conn in connector_positions:
		var before = current_text.substr(last_end, conn.pos - last_end).strip_edges()
		if not before.is_empty() and before != "." and before != ",":
			segments.append({
				"text": before.trim_suffix(".").trim_suffix(",").strip_edges(),
				"connector": current_connector
			})
		current_connector = conn.type
		last_end = conn.end

	# Agregar texto restante
	var remaining = current_text.substr(last_end).strip_edges()
	if not remaining.is_empty() and remaining != "." and remaining != ",":
		segments.append({
			"text": remaining.trim_suffix(".").trim_suffix(",").strip_edges(),
			"connector": current_connector
		})

	return segments


func _parse_segment(text: String, connector: Connector) -> Dictionary:
	"""Parsea un segmento individual de texto

	Returns: {type, amount, target, connector, filter, zone}
	"""
	var action: Dictionary = {
		"type": ActionType.CUSTOM,
		"amount": 1,
		"target": TargetType.SELF,
		"connector": connector,
		"filter": {},
		"zone": "FIELD"
	}

	# Detectar tipo de acción
	for action_type in PATTERNS:
		for pattern in PATTERNS[action_type]:
			var regex = RegEx.new()
			regex.compile("(?i)" + pattern)
			var result = regex.search(text)

			if result:
				action.type = _string_to_action_type(action_type)

				# Extraer cantidad si hay grupo de captura
				if result.get_group_count() > 0:
					var amount_str = result.get_string(1)
					action.amount = _parse_amount(amount_str)

				break

		if action.type != ActionType.CUSTOM:
			break

	# Detectar objetivo
	action.target = _detect_target(text)

	# Detectar filtros (tipo de carta, etc.)
	action.filter = _detect_filter(text)

	# Detectar zona
	action.zone = _detect_zone(text)

	return action


func _string_to_action_type(type_str: String) -> ActionType:
	"""Convierte string a ActionType enum"""
	match type_str:
		"draw": return ActionType.DRAW
		"mill": return ActionType.MILL
		"discard": return ActionType.DISCARD
		"destroy": return ActionType.DESTROY
		"banish": return ActionType.BANISH
		"search": return ActionType.SEARCH
		"damage": return ActionType.DAMAGE
		"buff": return ActionType.BUFF
		"debuff": return ActionType.DEBUFF
		"return_hand": return ActionType.RETURN_HAND
		"return_deck": return ActionType.RETURN_DECK
		"reveal": return ActionType.REVEAL
		"look": return ActionType.LOOK
		_: return ActionType.CUSTOM


func _parse_amount(amount_str: String) -> int:
	"""Parsea una cantidad del texto usando WORD_TO_INT.
	Soporta dígitos ('3'), palabras ('tres') y totales ('todas' → -1).
	"""
	if amount_str.is_valid_int():
		return int(amount_str)
	return WORD_TO_INT.get(amount_str.to_lower(), 1)


func _detect_target(text: String) -> TargetType:
	"""Detecta el objetivo de la acción"""
	var lower = text.to_lower()

	for pattern in TARGET_PATTERNS.opponent:
		if pattern in lower:
			return TargetType.OPPONENT

	for pattern in TARGET_PATTERNS.all:
		if pattern in lower:
			return TargetType.CARD_ALL

	for pattern in TARGET_PATTERNS.random:
		if pattern in lower:
			return TargetType.CARD_RANDOM

	return TargetType.SELF


func _detect_filter(text: String) -> Dictionary:
	"""Detecta filtros de tipo de carta"""
	var filter: Dictionary = {}
	var lower = text.to_lower()

	# Filtrar por tipo
	if "aliado" in lower:
		filter["type"] = "Aliado"
	elif "talismán" in lower or "talisman" in lower:
		filter["type"] = "Talisman"
	elif "arma" in lower:
		filter["type"] = "Arma"
	elif "tótem" in lower or "totem" in lower:
		filter["type"] = "Totem"
	elif "oro" in lower:
		filter["type"] = "Oro"

	# Excluir tipo
	if "que no sea" in lower:
		if "talismán" in lower or "talisman" in lower:
			filter["exclude_type"] = "Talisman"

	# Filtrar por coste
	var cost_regex = RegEx.new()
	cost_regex.compile("coste (\\d+) o menos")
	var cost_match = cost_regex.search(lower)
	if cost_match:
		filter["max_cost"] = int(cost_match.get_string(1))

	return filter


func _detect_zone(text: String) -> String:
	"""Detecta la zona objetivo"""
	var lower = text.to_lower()

	if "mazo" in lower or "castillo" in lower:
		return "DECK"
	elif "cementerio" in lower:
		return "CEMETERY"
	elif "mano" in lower:
		return "HAND"
	elif "destierro" in lower or "exilio" in lower:
		return "EXILE"
	elif "campo" in lower or "juego" in lower:
		return "FIELD"

	return "FIELD"


# =============================================================================
# RESOLUCIÓN DE CADENA DE ACCIONES
# =============================================================================
func resolve_chain(actions: Array, context: Dictionary = {}) -> Dictionary:
	"""Resuelve una cadena de acciones respetando conectores

	Conectores:
	- NONE/Y: Siempre ejecuta
	- LUEGO: Solo ejecuta si la anterior tuvo éxito completo
	- EN_MEDIDA: Ejecuta lo que se pueda, éxito parcial cuenta como éxito
	- O: Solo ejecuta si la anterior falló

	Args:
		actions: Array de acciones parseadas
		context: {controller_id, source_card, game_state}

	Returns: {success, results[], partial, stopped_at}
	"""
	var result = {
		"success": true,
		"results": [],
		"partial": false,
		"stopped_at": -1,
		"total_actions": actions.size(),
		"executed_actions": 0
	}

	if actions.is_empty():
		return result

	emit_signal("chain_resolution_started", actions)

	var previous_success = true
	var previous_partial = false

	for i in range(actions.size()):
		var action = actions[i]
		var connector = action.get("connector", Connector.NONE)

		# Evaluar si debemos ejecutar según el conector
		var should_execute = _should_execute_action(connector, previous_success, previous_partial)

		if not should_execute:
			print("[UniversalCardParser] Acción %d saltada por conector %s" % [i, _connector_to_string(connector)])
			result.stopped_at = i
			break

		# Ejecutar acción
		var action_result = await _execute_action(action, context)
		result.results.append(action_result)
		result.executed_actions += 1

		emit_signal("action_resolved", action, action_result)

		# Evaluar resultado según conector
		if connector == Connector.EN_MEDIDA:
			# En medida de lo posible: éxito parcial cuenta
			previous_success = action_result.get("success", false) or action_result.get("partial", false)
			previous_partial = action_result.get("partial", false)
			if previous_partial:
				result.partial = true
		else:
			previous_success = action_result.get("success", false)
			previous_partial = action_result.get("partial", false)

		# Si LUEGO y falló, marcar y detener
		if connector == Connector.LUEGO and not previous_success:
			result.success = false
			result.stopped_at = i
			break

	# Éxito general si todas las acciones necesarias se completaron
	if result.stopped_at == -1:
		result.success = previous_success or result.partial

	emit_signal("chain_resolution_completed", result.results)
	return result


func _should_execute_action(connector: Connector, prev_success: bool, prev_partial: bool) -> bool:
	"""Determina si una acción debe ejecutarse según su conector"""
	match connector:
		Connector.NONE, Connector.Y, Connector.EN_MEDIDA:
			# Siempre ejecutar
			return true
		Connector.LUEGO:
			# Solo si anterior tuvo éxito
			return prev_success
		Connector.O:
			# Solo si anterior falló
			return not prev_success
		_:
			return true


func _connector_to_string(connector: Connector) -> String:
	"""Convierte Connector a string para debug"""
	match connector:
		Connector.NONE: return "NONE"
		Connector.Y: return "Y"
		Connector.LUEGO: return "LUEGO"
		Connector.O: return "O"
		Connector.EN_MEDIDA: return "EN_MEDIDA"
		_: return "UNKNOWN"


func _execute_action(action: Dictionary, context: Dictionary) -> Dictionary:
	"""Ejecuta una acción individual

	Returns: {success, partial, data}
	"""
	var result = {
		"success": false,
		"partial": false,
		"data": {}
	}

	var action_type = action.get("type", ActionType.CUSTOM)
	var amount = action.get("amount", 1)
	var target = action.get("target", TargetType.SELF)
	var filter = action.get("filter", {})
	var zone = action.get("zone", "FIELD")

	var controller_id = context.get("controller_id", 0)
	var target_player = controller_id if target == TargetType.SELF else 1 - controller_id

	# Obtener ActionModule
	var action_module = get_node_or_null("/root/ActionModule")

	match action_type:
		ActionType.DRAW:
			if action_module:
				var draw_result = await action_module.draw(target_player, amount, "ability")
				result.success = draw_result.get("success", false)
				result.partial = draw_result.get("actual", 0) < amount and draw_result.get("actual", 0) > 0
				result.data = draw_result
			else:
				result.success = true  # Simulado
				result.data = {"simulated": true, "amount": amount}

		ActionType.MILL:
			if action_module:
				var mill_result = await action_module.mill(target_player, amount, false, "ability")
				result.success = mill_result.get("success", false)
				result.partial = mill_result.get("actual", 0) < amount and mill_result.get("actual", 0) > 0
				result.data = mill_result
			else:
				result.success = true
				result.data = {"simulated": true, "amount": amount}

		ActionType.DISCARD:
			if action_module:
				# Necesita selección de cartas
				var discard_result = await action_module.discard(target_player, [], "ability")
				result.success = discard_result.get("success", false)
				result.data = discard_result
			else:
				result.success = true
				result.data = {"simulated": true, "amount": amount}

		ActionType.DESTROY:
			if action_module:
				# Necesita targets
				var destroy_result = await action_module.destroy([], context.get("source_card", null))
				result.success = destroy_result.get("success", false)
				result.data = destroy_result
			else:
				result.success = true
				result.data = {"simulated": true}

		ActionType.BANISH:
			if action_module:
				var banish_result = await action_module.banish([], context.get("source_card", null))
				result.success = banish_result.get("success", false)
				result.data = banish_result
			else:
				result.success = true
				result.data = {"simulated": true}

		ActionType.SEARCH:
			if action_module:
				var zone_id = _zone_string_to_constant(zone)
				var search_result = await action_module.search(target_player, zone_id, filter, amount)
				result.success = search_result.get("success", false)
				result.data = search_result
			else:
				result.success = true
				result.data = {"simulated": true, "amount": amount}

		ActionType.DAMAGE:
			# TODO: Sistema de daño
			result.success = true
			result.data = {"simulated": true, "amount": amount}

		ActionType.BUFF, ActionType.DEBUFF:
			# TODO: Sistema de modificadores
			result.success = true
			result.data = {"simulated": true, "amount": amount}

		ActionType.RETURN_HAND, ActionType.RETURN_DECK:
			# TODO: Devolver cartas
			result.success = true
			result.data = {"simulated": true}

		ActionType.LOOK:
			var look_result = await _execute_look(target_player, amount)
			result.success = look_result.get("success", false)
			result.data = look_result

		ActionType.REVEAL:
			# TODO: Revelar públicamente al oponente (LOOK ya implementado abajo)
			result.success = true
			result.data = {"simulated": true, "amount": amount}

		ActionType.SHUFFLE:
			if action_module and action_module.has_method("shuffle_deck"):
				action_module.shuffle_deck(target_player)
			result.success = true
			result.data = {"player": target_player}

		_:
			print("[UniversalCardParser] Acción no implementada: %s" % action_type)
			result.success = true  # Asumir éxito para no bloquear
			result.data = {"unimplemented": true}

	return result


func _execute_look(player_id: int, amount: int) -> Dictionary:
	"""Muestra al jugador las N cartas del tope de su Castillo, sin
	modificar su orden — DAR: 'Mirar' es privado, informa pero no reordena
	ni mueve cartas. Primera implementación real de LOOK (antes era
	'simulated': no mostraba nada). Reordenar queda pendiente."""
	var cm = get_node_or_null("/root/CardManager")
	if not cm:
		return {"success": false, "error": "no_card_manager"}

	var deck: Array = cm.get_deck(player_id)
	var top_cards: Array = deck.slice(0, mini(amount, deck.size()))

	if top_cards.is_empty():
		return {"success": true, "cards": []}

	SelectionManager.open_reveal(top_cards, "Mirando %d carta(s) del tope de tu Castillo" % top_cards.size())
	return {"success": true, "cards": top_cards}


func _zone_string_to_constant(zone: String) -> int:
	"""Convierte string de zona a Constants.Zone"""
	match zone.to_upper():
		"DECK", "CASTILLO": return Constants.Zone.CASTILLO
		"CEMETERY", "CEMENTERIO": return Constants.Zone.CEMENTERIO
		"HAND", "MANO": return Constants.Zone.MANO
		"EXILE", "DESTIERRO": return Constants.Zone.DESTIERRO
		"FIELD": return Constants.Zone.LINEA_DEFENSA
		_: return Constants.Zone.CASTILLO


# =============================================================================
# VENTANA DE RESPUESTA (PASO D)
# =============================================================================
func play_card_with_response_window(card_data: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Juega una carta con ventana de respuesta para el oponente (Paso D)

	Flujo:
	1. Parsear habilidades de la carta
	2. Registrar carta en el pipeline
	3. Abrir ventana de respuesta
	4. Si no hay respuesta/anulación, resolver cadena
	5. Aplicar condición post-resolución

	Args:
		card_data: Datos de la carta a jugar
		context: {controller_id, played_from, etc.}

	Returns: {success, was_annulled, results, final_destination}
	"""
	var result = {
		"success": false,
		"was_annulled": false,
		"results": [],
		"final_destination": "CEMENTERIO"
	}

	var card_name = card_data.get("name", card_data.get("nombre", "???"))
	var controller_id = context.get("controller_id", 0)

	print("[UniversalCardParser] Jugando carta con ventana de respuesta: %s" % card_name)

	# 1. Parsear habilidades
	var ability_text = card_data.get("ability", card_data.get("habilidad", ""))
	var actions = parse_ability_text(ability_text, card_data)

	# Si tiene choice_config, usar eso en lugar de parsear
	var choice_config = card_data.get("choice_config", {})
	if not choice_config.is_empty():
		actions = _convert_choice_config_to_actions(choice_config, context)

	# Si tiene hability_blocks, usar eso
	var hability_blocks = card_data.get("hability_blocks", [])
	if not hability_blocks.is_empty():
		actions = _convert_hability_blocks_to_actions(hability_blocks, context)

	# 2. Registrar en pipeline
	if _action_executor:
		_action_executor.enter_pipeline(card_data, {
			"controller_id": controller_id,
			"pending_actions": actions,
			"phase": "waiting_response"
		})

	emit_signal("response_window_requested", card_data, actions)

	# 3. Abrir ventana de respuesta
	var response = await _open_response_window(card_data, actions, context)

	# 4. Verificar si fue anulada
	if response.get("was_annulled", false):
		result.was_annulled = true
		result.final_destination = _get_annulled_destination(card_data)

		if _action_executor:
			_action_executor.exit_pipeline()

		print("[UniversalCardParser] Carta anulada, destino: %s" % result.final_destination)
		return result

	# 5. Resolver cadena de acciones
	if not actions.is_empty():
		var chain_context = context.duplicate()
		chain_context["source_card"] = card_data

		var chain_result = await resolve_chain(actions, chain_context)
		result.results = chain_result.results
		result.success = chain_result.success
	else:
		result.success = true

	# 6. Determinar destino final
	result.final_destination = _get_final_destination(card_data, context)

	# 7. Salir del pipeline
	if _action_executor:
		_action_executor.exit_pipeline()

	print("[UniversalCardParser] Resolución completa, destino: %s" % result.final_destination)
	return result


func _open_response_window(card_data: Dictionary, actions: Array, context: Dictionary) -> Dictionary:
	"""Abre la ventana de respuesta y espera decisión del oponente

	Returns: {had_response, was_annulled, response_card}
	"""
	var result = {
		"had_response": false,
		"was_annulled": false,
		"response_card": null
	}

	if not _action_executor:
		_action_executor = get_node_or_null("/root/ActionExecutor")

	if _action_executor:
		var response = await _action_executor.open_response_window(null, {
			"card_data": card_data,
			"pending_actions": actions,
			"controller_id": context.get("controller_id", 0)
		})

		result.had_response = response.get("had_response", false)

		if result.had_response and response.get("response_card"):
			# Verificar si es anulación
			if _action_executor.check_annullment(response.response_card):
				result.was_annulled = true
				result.response_card = response.response_card
	else:
		# Sin ActionExecutor, simular pase automático
		print("[UniversalCardParser] Sin ActionExecutor, oponente pasa automáticamente")
		await get_tree().create_timer(0.5).timeout

	return result


func _get_annulled_destination(card_data: Dictionary) -> String:
	"""Determina el destino de una carta anulada

	Si la carta dice BANISH_SELF, va al destierro aunque sea anulada
	"""
	var on_resolution = card_data.get("on_resolution", "")
	if on_resolution == "BANISH_SELF":
		return "DESTIERRO"
	return "CEMENTERIO"


func _get_final_destination(card_data: Dictionary, context: Dictionary) -> String:
	"""Determina el destino final de una carta tras resolución"""
	# Si fue jugada via Exhumar
	if context.get("played_via_exhumar", false):
		return "DESTIERRO"

	# Verificar resolution_rules
	var resolution_rules = card_data.get("resolution_rules", {})
	if context.get("played_via_exhumar", false) and resolution_rules.has("on_exhumar_resolve"):
		return _normalize_destination(resolution_rules.on_exhumar_resolve)

	if resolution_rules.has("on_resolve"):
		return _normalize_destination(resolution_rules.on_resolve)

	# Verificar on_resolution
	var on_resolution = card_data.get("on_resolution", "GRAVEYARD")
	return _normalize_destination(on_resolution)


func _normalize_destination(dest: String) -> String:
	"""Normaliza strings de destino"""
	match dest.to_upper():
		"MOVE_TO_CEMENTERIO", "GRAVEYARD", "CEMENTERIO", "DESTROY_SELF":
			return "CEMENTERIO"
		"MOVE_TO_DESTIERRO", "BANISH_SELF", "EXILE", "DESTIERRO":
			return "DESTIERRO"
		"MOVE_TO_MANO", "RETURN_TO_HAND", "HAND", "MANO":
			return "MANO"
		"MOVE_TO_CASTILLO", "RETURN_TO_DECK", "DECK", "CASTILLO":
			return "CASTILLO"
		_:
			return "CEMENTERIO"


# =============================================================================
# CONVERSIÓN DE FORMATOS
# =============================================================================
func _convert_choice_config_to_actions(choice_config: Dictionary, context: Dictionary) -> Array:
	"""Convierte choice_config a array de acciones

	Usado cuando la carta tiene formato de selección de efectos
	"""
	var actions: Array = []
	var selected = context.get("selected_options", [])
	var options = choice_config.get("options", [])

	for opt in options:
		var opt_id = opt.get("id", "")
		if opt_id in selected or selected.is_empty():
			var action_data = opt.get("action", {})
			actions.append({
				"type": _action_string_to_type(action_data.get("type", "CUSTOM")),
				"amount": action_data.get("value", 1),
				"target": _target_string_to_type(action_data.get("target", "SELF")),
				"connector": Connector.Y,
				"filter": action_data.get("filter", {}),
				"zone": action_data.get("zone", "DECK"),
				"raw_text": opt.get("text", "")
			})

	return actions


func _convert_hability_blocks_to_actions(hability_blocks: Array, context: Dictionary) -> Array:
	"""Convierte hability_blocks a array de acciones"""
	var actions: Array = []

	for block in hability_blocks:
		var effect = block.get("effect", {})
		if effect.is_empty():
			continue

		actions.append({
			"type": _action_string_to_type(effect.get("action", effect.get("type", "CUSTOM"))),
			"amount": effect.get("value", effect.get("amount", 1)),
			"target": _target_string_to_type(effect.get("target", "SELF")),
			"connector": Connector.Y,
			"filter": effect.get("filter", {}),
			"zone": effect.get("zone", "FIELD"),
			"raw_text": block.get("raw_text", ""),
			"conditions": block.get("conditions", [])
		})

	return actions


func _action_string_to_type(type_str: String) -> ActionType:
	"""Convierte string de tipo de acción a enum"""
	match type_str.to_upper():
		"DRAW": return ActionType.DRAW
		"MILL": return ActionType.MILL
		"DISCARD": return ActionType.DISCARD
		"DESTROY": return ActionType.DESTROY
		"BANISH", "EXILE": return ActionType.BANISH
		"SEARCH": return ActionType.SEARCH
		"DAMAGE": return ActionType.DAMAGE
		"BUFF": return ActionType.BUFF
		"DEBUFF": return ActionType.DEBUFF
		"HEAL": return ActionType.HEAL
		"RETURN_HAND", "RETURN_TO_HAND": return ActionType.RETURN_HAND
		"RETURN_DECK", "RETURN_TO_DECK": return ActionType.RETURN_DECK
		"REVEAL": return ActionType.REVEAL
		"LOOK": return ActionType.LOOK
		"SHUFFLE": return ActionType.SHUFFLE
		"TAP": return ActionType.TAP
		"UNTAP": return ActionType.UNTAP
		"TOKEN", "CREATE_TOKEN": return ActionType.CREATE_TOKEN
		"COPY": return ActionType.COPY
		"COUNTER", "ANNUL": return ActionType.COUNTER
		"MOVE": return ActionType.MOVE
		"GOLD", "VIRTUAL_GOLD": return ActionType.GOLD
		_: return ActionType.CUSTOM


func _target_string_to_type(target_str: String) -> TargetType:
	"""Convierte string de target a enum"""
	match target_str.to_upper():
		"SELF", "CONTROLLER": return TargetType.SELF
		"OPPONENT", "ENEMY": return TargetType.OPPONENT
		"BOTH", "ALL_PLAYERS": return TargetType.BOTH
		"CARD", "TARGET", "TARGETED": return TargetType.CARD_TARGET
		"ALL", "ALL_CARDS": return TargetType.CARD_ALL
		"RANDOM": return TargetType.CARD_RANDOM
		_: return TargetType.SELF


# =============================================================================
# HABILIDADES ACTIVADAS
# =============================================================================
func get_activated_abilities(card_data: Dictionary) -> Array[Dictionary]:
	"""Identifica las habilidades activadas de una carta.

	Una habilidad activada tiene formato: [Costo]: [Efecto]
	Ejemplos:
	  "Paga 1 Oro para: roba 1 carta"
	  "Una vez por turno: +2/+2 a un aliado"
	  "Descarta una carta: destruye un aliado enemigo"

	Returns: Array[{cost_text, cost_type, cost_amount, effect_text, raw_text, ability_index}]
	"""
	var habilidad = card_data.get("habilidad", "")
	if habilidad.is_empty():
		return []

	var result: Array[Dictionary] = []
	var ability_index := 0

	# Dividir por puntos para procesar cada oración
	for raw_sentence in habilidad.split("."):
		var sentence = raw_sentence.strip_edges()
		if sentence.is_empty() or not ":" in sentence:
			continue

		# Separar en [costo] : [efecto]  (solo primer ':')
		var colon_pos = sentence.find(":")
		var cost_part    = sentence.substr(0, colon_pos).strip_edges()
		var effect_part  = sentence.substr(colon_pos + 1).strip_edges()

		if effect_part.is_empty():
			continue

		var lower_cost = cost_part.to_lower()
		var cost_type  = CostType.NONE
		var cost_amount := 0

		# ── Detectar tipo de costo ────────────────────────────────────────────
		if "una vez por turno" in lower_cost or "una vez al turno" in lower_cost:
			cost_type = CostType.ONCE_PER_TURN
		elif "paga" in lower_cost and ("oro" in lower_cost or "oros" in lower_cost):
			cost_type   = CostType.GOLD
			var rx = RegEx.new()
			rx.compile("(\\d+)")
			var m = rx.search(lower_cost)
			cost_amount = int(m.get_string(1)) if m else 1
		elif "descarta" in lower_cost:
			cost_type   = CostType.DISCARD
			cost_amount = 1
		elif "girar" in lower_cost or "tapa" in lower_cost or "gira" in lower_cost:
			cost_type = CostType.TAP

		if cost_type == CostType.NONE:
			continue  # No es habilidad activada reconocida

		result.append({
			"raw_text":     sentence,
			"cost_text":    cost_part,
			"cost_type":    cost_type,
			"cost_amount":  cost_amount,
			"effect_text":  effect_part,
			"ability_index": ability_index,
			"is_optional":  effect_part.to_lower().begins_with("puedes"),
		})
		ability_index += 1

	return result


# =============================================================================
# PARSE_ABILITIES — Compilador Fase 1 (entrada pública unificada)
# =============================================================================
func parse_abilities(text: String, card_id: String = "") -> Array[Dictionary]:
	"""Compilador Fase 1: analiza el texto de una carta y retorna habilidades estructuradas.

	Divide el texto por puntos y clasifica cada oración:
	  - TRIGGER   : Se activa automáticamente por un evento ("Cuando entra", "Al atacar"…)
	  - ACTIVATED : El jugador la activa desde el Zoom (tiene coste o "Una vez por turno")

	Flags especiales:
	  is_optional   — La oración contiene "Puedes". Obliga a ActionPipeline a pedir
	                  confirmación antes de resolver (señal puedes_confirm_requested).
	  once_per_turn — Contiene "Una vez por turno". Se registra en TurnRegistry para
	                  impedir múltiples usos por turno.

	Cada elemento retornado:
	  {raw_text, ability_type, trigger_event,
	   cost_text, cost_type, cost_amount,
	   effect_text, actions,
	   is_optional, once_per_turn,
	   ability_index, card_id,
	   manager_path, method}
	"""
	var result: Array[Dictionary] = []
	if text.is_empty():
		return result

	var ability_index := 0

	for raw_sentence: String in text.split("."):
		var sentence: String = raw_sentence.strip_edges()
		if sentence.is_empty():
			continue

		var lower_s: String = sentence.to_lower()

		# ── Flags globales de la oración ──────────────────────────────────────
		var is_optional:   bool = "puedes" in lower_s
		var once_per_turn: bool = ("una vez por turno" in lower_s
			or "una vez al turno" in lower_s)

		# ── Detectar Trigger ──────────────────────────────────────────────────
		var trigger_event: String = ""
		for phrase: String in TRIGGER_EVENTS:
			if phrase in lower_s:
				trigger_event = TRIGGER_EVENTS[phrase]
				break

		# ── Detectar Costo (para ACTIVATED) ───────────────────────────────────
		var cost_type:   int    = CostType.NONE
		var cost_amount: int    = 0
		var cost_text:   String = ""
		var effect_text: String = sentence

		if once_per_turn:
			cost_type = CostType.ONCE_PER_TURN
		elif ":" in sentence:
			var colon_pos: int = sentence.find(":")
			cost_text   = sentence.substr(0, colon_pos).strip_edges()
			effect_text = sentence.substr(colon_pos + 1).strip_edges()
			var lower_cost: String = cost_text.to_lower()
			if "paga" in lower_cost and ("oro" in lower_cost or "oros" in lower_cost):
				cost_type = CostType.GOLD
				var rx := RegEx.new()
				rx.compile("(\\d+)")
				var m := rx.search(lower_cost)
				cost_amount = int(m.get_string(1)) if m else 1
			elif "descarta" in lower_cost:
				cost_type   = CostType.DISCARD
				cost_amount = 1
			elif "girar" in lower_cost or "gira" in lower_cost or "tapa" in lower_cost:
				cost_type = CostType.TAP

		# ── Determinar tipo de habilidad ──────────────────────────────────────
		var ability_type: String
		if trigger_event != "":
			ability_type = "TRIGGER"
		elif cost_type != CostType.NONE:
			ability_type = "ACTIVATED"
		else:
			# Oración sin coste ni trigger → no es habilidad activada reconocida
			# (puede ser texto de reglas pasivo)
			ability_index += 1
			continue

		# ── Detectar acciones usando ABILITY_PATTERNS ─────────────────────────
		var actions: Array[Dictionary] = []
		var matched_manager_path: String = ""
		var matched_method:       String = ""
		var scan_text: String = effect_text.to_lower()

		for action_key: String in ABILITY_PATTERNS:
			var entry: Dictionary = ABILITY_PATTERNS[action_key]
			var rx := RegEx.new()
			rx.compile("(?i)" + entry["regex"])
			var m := rx.search(scan_text)
			if not m:
				continue

			var amount := 1
			var grp: int = entry["group_amount"]
			if grp > 0 and m.get_group_count() >= grp:
				var gs: String = m.get_string(grp)
				amount = _parse_amount(gs) if not gs.is_valid_int() else int(gs)

			if matched_manager_path.is_empty():
				matched_manager_path = entry["manager_path"]
				matched_method       = entry["method"]

			actions.append({
				"action_key":   action_key,
				"action_type":  entry["action_type"],
				"amount":       amount,
				"manager_path": entry["manager_path"],
				"method":       entry["method"],
				"target":       _detect_target(scan_text),
				"raw_text":     effect_text,
			})
			break  # una acción principal por oración

		result.append({
			"raw_text":      sentence,
			"ability_type":  ability_type,
			"trigger_event": trigger_event,
			"cost_text":     cost_text,
			"cost_type":     cost_type,
			"cost_amount":   cost_amount,
			"effect_text":   effect_text,
			"actions":       actions,
			"is_optional":   is_optional,
			"once_per_turn": once_per_turn,
			"ability_index": ability_index,
			"card_id":       card_id,
			"manager_path":  matched_manager_path,
			"method":        matched_method,
		})
		ability_index += 1

	return result


# =============================================================================
# EXTRACT_ACTION — Extractor de Acción (Compilador Fase 1)
# Punto de entrada rápido para obtener la primera acción ejecutable de un texto.
# Usado por TriggerSystem al resolver ETB y por debug en tiempo real.
# =============================================================================

## Regex de robo canónico — cubre "Roba dos cartas", "Robas 3 cartas", etc.
const DRAW_REGEX: String = "(?:Roba|Robas)\\s+(una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|\\d+)\\s+cartas?"


func extract_action(text: String) -> Dictionary:
	"""Extrae la primera acción reconocida del texto de una habilidad.

	Prioridad:
	  1. Patrón de robo canónico (DRAW_REGEX)
	  2. Resto de ABILITY_PATTERNS en orden de iteración

	Retorna un GameAction con: type, action_type, value, manager_path, method, params, raw_text.
	Si no detecta nada: {matched: false}.

	Ejemplo — Ciudad de los Césares 'Roba dos cartas':
	  → {matched: true, type: 'DRAW', value: 2, manager_path: '/root/ActionModule', method: 'draw'}
	"""
	if text.is_empty():
		return {"matched": false}

	# ── 1. Patrón de robo canónico ─────────────────────────────────────────────
	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)" + DRAW_REGEX)
	var m := draw_rx.search(text)
	if m:
		var amount: int = _parse_amount(m.get_string(1))
		print("[Parser] Acción detectada: ROBA | Cantidad: %d" % amount)
		return {
			"matched":      true,
			"type":         "DRAW",
			"action_type":  ActionType.DRAW,
			"value":        amount,
			"amount":       amount,
			"manager_path": "/root/ActionModule",
			"method":       "draw",
			"params":       {"target_player": 0, "amount": amount},
			"raw_text":     m.get_string(0),
		}

	# ── 2. Resto de ABILITY_PATTERNS ───────────────────────────────────────────
	for action_key: String in ABILITY_PATTERNS:
		var entry: Dictionary = ABILITY_PATTERNS[action_key]
		var rx := RegEx.new()
		rx.compile("(?i)" + entry["regex"])
		var m2 := rx.search(text)
		if not m2:
			continue
		var amount := 1
		var grp: int = entry["group_amount"]
		if grp > 0 and m2.get_group_count() >= grp:
			amount = _parse_amount(m2.get_string(grp))
		print("[Parser] Acción detectada: %s | Cantidad: %d" % [action_key, amount])
		return {
			"matched":      true,
			"type":         action_key,
			"action_type":  entry["action_type"],
			"value":        amount,
			"amount":       amount,
			"manager_path": entry["manager_path"],
			"method":       entry["method"],
			"params":       {"amount": amount, "target_player": 0},
			"raw_text":     m2.get_string(0),
		}

	return {"matched": false}


# =============================================================================
# PARSE_TEXT — Regex Pattern Matching (GameAction Objects)
# =============================================================================

## Triggers: frases de inicio que identifican efectos condicionales
const TRIGGER_RX: Array = [
	"cuando entra",
	"al salir",
	"al atacar",
	"al comienzo de",
]

## Costes: [{pattern, cost_type, group}]
## group = índice del grupo de captura con la cantidad (0 = sin captura)
const COST_RX: Array = [
	{"pattern": "paga (\\d+) oro",     "cost_type": CostType.GOLD,         "group": 1},
	{"pattern": "destierra una carta", "cost_type": CostType.DISCARD,       "group": 0},
	{"pattern": "una vez por turno",   "cost_type": CostType.ONCE_PER_TURN, "group": 0},
]

## Acciones: [{pattern, action_key, group, manager_path, method}]
const ACTION_RX: Array = [
	{"pattern": "roba (\\d+)",       "action_key": "DRAW",    "group": 1,
	 "manager_path": "/root/ActionModule", "method": "draw"},
	{"pattern": "destruye",          "action_key": "DESTROY", "group": 0,
	 "manager_path": "/root/ActionModule", "method": "destroy"},
	{"pattern": "baraja",            "action_key": "SHUFFLE", "group": 0,
	 "manager_path": "/root/ActionModule", "method": "shuffle_deck"},
	{"pattern": "busca en tu mazo",  "action_key": "SEARCH",  "group": 0,
	 "manager_path": "/root/ActionModule", "method": "search"},
]


func parse_text(text: String) -> Array[Dictionary]:
	"""Analiza texto libre de carta mediante Regex y retorna objetos GameAction.

	Detecta 3 categorías por oración:
	  - TRIGGER : "Cuando entra", "Al salir", "Al atacar", "Al comienzo de"
	  - COST    : "Paga N Oro", "Destierra una carta", "Una vez por turno"
	  - ACTION  : "Roba N", "Destruye", "Baraja", "Busca en tu mazo"

	Cada GameAction devuelto contiene:
	  {segment_type, action_key, action_type, amount,
	   manager_path, method, params,
	   raw_text, is_optional, has_cost, cost_type, cost_amount}

	Las oraciones con has_cost == true se usan en CardInspectionLayer
	para generar botones de activación automáticos.
	"""
	var results: Array[Dictionary] = []
	if text.is_empty():
		return results

	for raw_sentence in text.split("."):
		var sentence: String = raw_sentence.strip_edges()
		if sentence.is_empty():
			continue
		var lower_s: String = sentence.to_lower()

		var segment: Dictionary = {
			"raw_text":     sentence,
			"segment_type": "ACTION",
			"action_key":   "",
			"action_type":  ActionType.CUSTOM,
			"amount":       1,
			"manager_path": "",
			"method":       "",
			"params":       {},
			"is_optional":  "puedes" in lower_s,
			"has_cost":     false,
			"cost_type":    CostType.NONE,
			"cost_amount":  0,
		}

		var found := false

		# ── Trigger ──────────────────────────────────────────────────────────
		for trigger_pattern: String in TRIGGER_RX:
			if trigger_pattern in lower_s:
				segment.segment_type = "TRIGGER"
				segment.action_key   = trigger_pattern.replace(" ", "_").to_upper()
				found = true
				break

		# ── Costo ─────────────────────────────────────────────────────────────
		for cost_entry: Dictionary in COST_RX:
			var rx := RegEx.new()
			rx.compile("(?i)" + cost_entry["pattern"])
			var m := rx.search(sentence)
			if m:
				segment.has_cost     = true
				segment.cost_type    = cost_entry["cost_type"]
				var grp: int = cost_entry["group"]
				segment.cost_amount  = int(m.get_string(grp)) if grp > 0 and m.get_group_count() >= grp else 1
				found = true
				break

		# ── Acción ────────────────────────────────────────────────────────────
		for action_entry: Dictionary in ACTION_RX:
			var rx := RegEx.new()
			rx.compile("(?i)" + action_entry["pattern"])
			var m := rx.search(sentence)
			if m:
				segment.action_key   = action_entry["action_key"]
				segment.action_type  = _action_string_to_type(action_entry["action_key"])
				segment.manager_path = action_entry["manager_path"]
				segment.method       = action_entry["method"]
				var grp: int = action_entry["group"]
				if grp > 0 and m.get_group_count() >= grp:
					segment.amount = int(m.get_string(grp))
				segment.params = {"amount": segment.amount, "target_player": 0}
				found = true
				break

		if found:
			results.append(segment)

	return results


# =============================================================================
# UTILIDADES DE DEBUG
# =============================================================================
func debug_parse(ability_text: String) -> void:
	"""Parsea y muestra el resultado en consola"""
	print("=" .repeat(50))
	print("PARSING: %s" % ability_text)
	print("-" .repeat(50))

	var actions = parse_ability_text(ability_text)

	for i in range(actions.size()):
		var action = actions[i]
		print("Acción %d:" % i)
		print("  Tipo: %s" % ActionType.keys()[action.type])
		print("  Cantidad: %s" % action.amount)
		print("  Objetivo: %s" % TargetType.keys()[action.target])
		print("  Conector: %s" % _connector_to_string(action.connector))
		print("  Filtro: %s" % action.filter)
		print("  Zona: %s" % action.zone)
		print("  Texto: %s" % action.raw_text)
		print("")

	print("=" .repeat(50))
