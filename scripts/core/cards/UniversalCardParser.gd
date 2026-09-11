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
	SELF_AS_GOLD,   # "Pagar este Oro" — la propia carta se gasta como Oro (2026-08-29, p.ej. Tyet)
	SELF_BANISH,    # "Puedes Desterrarlo" — la propia carta se destierra como costo (2026-08-30, p.ej. Legión Paladín, Ramón Freire)
	SELF_TO_DECK_BOTTOM, # "Puedes poner esta ... carta(s) en el fondo de tu Castillo" — la propia carta (+ otra) al fondo del mazo como costo (2026-08-30, p.ej. Tyet)
	SELF_SHUFFLE,   # "Barajar esta carta desde tu mano/Barajarla" — la propia carta se baraja de vuelta al Castillo como costo (2026-09-06, p.ej. Sacrificio Solar, skofnung)
	SELF_CONVERT,   # "Puedes convertirlo/la en un Oro sin habilidad" — la propia carta se convierte como costo (2026-09-07, p.ej. Perla de Sangre)
	SELF_DISCARD,   # "Puedes Descartarlo/Descartarla" — la propia carta se descarta como costo (2026-09-07, p.ej. Sumi)
	SELF_DESTROY,   # "Puedes Destruir esta Arma" — la propia carta se destruye como costo (2026-09-07, p.ej. Lanza Argenta)
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
		"regex":        "busca (?:\\d+|una?|un) (?:cartas?|aliados?|talismanes?|talisman|tótems?|totems?|armas?|oros?)|busca en (?:tu|un|el) (?:mazo|castillo|cementerio)",
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
		# Cubre dígito o palabra ('un', 'dos'...) y el calificador opcional
		# 'por el turno'/'virtual(es)' (2026-08-28, p.ej. Lobo Sagrado:
		# 'Cuando ataques, genera un Oro por el turno') — antes exigía la
		# palabra literal 'virtual' y solo dígitos, así que nunca matcheaba
		# el texto real de ninguna carta. Ejecución real en
		# TargetedEffectExecutor.execute_parsed_action() (case "GOLD"), no
		# via manager_path/method (GoldManager no es autoload de /root).
		"regex":        "(?:genera|añade) (\\w+) oros?(?: virtuales?)?(?: por el turno)?",
		"manager_path": "",
		"method":       "",
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
		# "Silenciar" no es un término de Mitos y Leyendas — es solo el nombre
		# interno (KeywordManager.silence_card/is_silenced). El texto real de
		# carta dice "pierde su habilidad" (DAR), no "es silenciada".
		"regex":        "pierde su habilidad|pierde todas sus habilidades|no tiene habilidades ni palabras clave",
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
	# "al morir" no es terminología real del juego (2026-08-28, a pedido
	# del usuario) — se sacó, queda "cuando es destruida" para DIE.
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

	func register_ability_use(source_card: Node, ability: Dictionary) -> void:
		"""Envoltorio de register() que extrae ability_index/turno y usa el
		instance_id de source_card como clave — extraído (2026-08-30) de las
		mismas 4 líneas que se repetían copiadas en prácticamente todas las
		funciones _activate_* de CardInspectionLayer.gd (Don de Amma, Tesoro
		de los Césares, Miguel, las dos de Tyet, Ramón Freire).
		instance_id, NO card_data.id (2026-08-30, corrección: card_data.id es
		el ID de la CARTA/impresión, compartido por TODAS las copias en juego
		— con 2 Aho en juego, usar uno marcaba el cupo de 'una vez por turno'
		también para el otro, un bug real reportado por el usuario. Cada copia
		física necesita su propio cupo)."""
		var card_id: String = str(source_card.get_instance_id())
		var ability_index: int = ability.get("ability_index", 0)
		register(card_id, ability_index, GameManager.current_turn)

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
## Registro de usos "Una vez por turno" — compartido con ActionPipeline
var turn_registry: TurnRegistry = TurnRegistry.new()


func _ready() -> void:
	call_deferred("_connect_signals")


func _connect_signals() -> void:
	# Resetear TurnRegistry al inicio de cada turno nuevo
	if not GameManager.turn_started.is_connected(_on_turn_started_reset_registry):
		GameManager.turn_started.connect(_on_turn_started_reset_registry)


func _on_turn_started_reset_registry(_player_id: int, turn_number: int) -> void:
	turn_registry.reset_for_turn(turn_number)


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



# resolve_chain()/play_card_with_response_window() (ActionChainResolver.gd/
# AbilityRegistry.gd) se eliminaron acá (2026-08-27, limpieza — sin ningún
# llamador real, ver ActionPipeline.gd para el detalle completo).


# =============================================================================
# PARSE_ABILITIES — Compilador Fase 1 (entrada pública unificada)
# =============================================================================
# get_activated_abilities() se eliminó acá (2026-08-28, "módulos gordos"):
# cero llamadores reales — solo aparecía nombrada en un comentario de
# ActionPipeline.gd, nunca invocada. parse_abilities() de abajo es la que de
# verdad usa CardInspectionLayer para los botones de habilidad activada.
func parse_abilities(text: String, card_id: String = "") -> Array[Dictionary]:
	"""Compilador Fase 1: analiza el texto de una carta y retorna habilidades estructuradas.

	Divide el texto por puntos y clasifica cada oración:
	  - TRIGGER   : Se activa automáticamente por un evento ("Cuando entra", "Al atacar"…)
	  - ACTIVATED : El jugador la activa desde el Zoom (tiene coste o "Una vez por turno")

	Flags especiales:
	  is_optional   — La oración contiene "Puedes". Para ACTIVATED no pide
	                  confirmación aparte (clickear el botón ya es la
	                  confirmación, 2026-08-28); para TRIGGER, el "declinar"
	                  lo ofrece el propio can_cancel del SelectionManager que
	                  abre TriggerResolution/LookAndPlayResolver.
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

		# ── Continuación encadenada ("Luego, busca...") ────────────────────────
		# Una oración que empieza con un conector de encadenamiento (Luego/
		# Después/A continuación/Entonces) no es una habilidad nueva — es la
		# continuación de la anterior (2026-08-29, p.ej. Don de Amma: "...puedes
		# Desterrar un Oro con habilidad de tu Reserva. Luego, busca un Oro en
		# tu Castillo y ponlo en tu Reserva."). Antes cada oración se evaluaba
		# aislada y ésta, sin trigger ni coste propio, se descartaba en
		# silencio — ni el raw_text que usa CardInspectionLayer para detectar
		# patrones especiales por botón, ni el effect_text que llega a
		# ActionPipeline.activate_ability(), veían nunca el "Luego...". Se
		# concatena a la última entrada agregada en vez de perderse.
		var is_luego_continuation: bool = false
		for connector_word: String in ["luego,", "después,", "a continuación,", "entonces,"]:
			if lower_s.begins_with(connector_word):
				is_luego_continuation = true
				break
		if is_luego_continuation and not result.is_empty():
			var prev: Dictionary = result[result.size() - 1]
			prev["raw_text"]    = "%s. %s" % [prev.get("raw_text", ""), sentence]
			prev["effect_text"] = "%s. %s" % [prev.get("effect_text", ""), sentence]
			continue

		# ── Flags globales de la oración ──────────────────────────────────────
		var is_optional:   bool = "puedes" in lower_s
		# "una vez EN tu/su turno" (p.ej. Padre de la Patria, 2026-08-28) es
		# una tercera variante real de esta cláusula que no matcheaba antes.
		var once_per_turn: bool = ("una vez por turno" in lower_s
			or "una vez al turno" in lower_s
			or "una vez en tu turno" in lower_s
			or "una vez en su turno" in lower_s)

		# "Sólo puedes utilizar la habilidad de X una vez por turno" (2026-08-30,
		# p.ej. Ramón Freire) — oración de CIERRE que solo reafirma la
		# restricción de la habilidad ACTIVADA anterior, no una habilidad
		# nueva. Sin este chequeo, 'una vez por turno' la clasificaba como su
		# propia entrada ACTIVATED separada y espuria, sin ninguna acción
		# real asociada (un botón que no hacía nada con sentido al clickear).
		var is_once_per_turn_qualifier_only: bool = once_per_turn and (
			"solo puedes utilizar la habilidad" in lower_s
			or "sólo puedes utilizar la habilidad" in lower_s
			or "solo puedes usar esta habilidad" in lower_s
			or "sólo puedes usar esta habilidad" in lower_s
			# "Sólo puedes utilizar ESTA habilidad de X una vez por turno"
			# (2026-09-06, p.ej. Cuervo Nocturno) — variante con "utilizar" +
			# "esta" que faltaba: ninguna de las 4 combinaciones de arriba la
			# cubría ("utilizar" solo se chequeaba con "la", "esta" solo con
			# "usar"), así que esta oración de cierre quedaba como su propia
			# entrada ACTIVATED espuria en vez de fusionarse con la anterior.
			or "solo puedes utilizar esta habilidad" in lower_s
			or "sólo puedes utilizar esta habilidad" in lower_s
		)
		if is_once_per_turn_qualifier_only and not result.is_empty():
			var prev_qual: Dictionary = result[result.size() - 1]
			prev_qual["once_per_turn"] = true
			continue

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

		# "Puedes pagarlo..." (2026-08-30, corrección: el texto real de Tyet en
		# caché/API es "Puedes pagarlo para que..." con pronombre, no "pagar
		# este Oro" — el chequeo original nunca matcheaba el texto real de la
		# carta, así que esta oración (y por lo tanto también la siguiente,
		# que dependía de que ÉSTA llegara a ACTIVATED para poder encadenarse)
		# quedaban fuera de 'result' por completo, sin ningún botón.
		var pays_self_as_gold: bool = ("pagar este oro" in lower_s or "pagar esta carta" in lower_s
			or "puedes pagarlo" in lower_s)
		# "Puedes Desterrarlo/Desterrarla..." (2026-08-30, p.ej. Legión
		# Paladín, Ramón Freire — masculino; Estaca: 'Puedes Desterrarla
		# para prevenir...' — femenino, "la Estaca") — coste de
		# autodesterrarse, tampoco tiene 'una vez por turno' ni ':'. Sin
		# este chequeo la oración quedaba fuera de 'result' igual que el
		# caso de arriba — Legión Paladín parece no haber disparado nunca
		# su botón real hasta este fix (el patrón especial que lo maneja en
		# CardInspectionLayer nunca era alcanzable porque esta oración
		# jamás llegaba a ability_type ACTIVATED).
		var pays_self_banish: bool = "puedes desterrarlo" in lower_s or "puedes desterrarla" in lower_s
		# "Puedes poner esta y otra carta de tu mano en el fondo de tu
		# Castillo..." (2026-08-30, p.ej. Tyet) — coste de mandar esta carta
		# (+ otra) al fondo del mazo, tampoco tiene 'una vez por turno' ni
		# ':'. Sin este chequeo caía en la rama de "sin coste ni trigger", y
		# como la oración ANTERIOR (la de pagarlo como Oro) no es ACTIVATED
		# hasta el fix de arriba, tampoco encadenaba como continuación —
		# quedaba fuera de 'result' por completo, sin botón.
		var pays_self_to_deck_bottom: bool = "poner esta" in lower_s and "fondo de tu castillo" in lower_s
		# "Barajar esta carta desde tu mano"/"Barajarla de tu mano"/
		# "Barajarla" a secas (2026-09-06, bug real reportado por el
		# usuario: Sacrificio Solar — 'Puedes pagar un Oro y Barajar esta
		# carta desde tu mano para...' — no matcheaba NINGÚN cost_type,
		# así que la oración entera quedaba fuera de 'result' sin
		# ability_type ACTIVATED, y _build_ability_buttons() nunca le
		# mostraba botón al jugador: la habilidad, literal, no se podía
		# usar. skofnung tiene el mismo patrón ('Puedes Barajarla de tu
		# mano para...') y compartía el mismo problema.
		var pays_self_shuffle: bool = ("barajar esta carta" in lower_s and "mano" in lower_s) \
			or "barajarla de tu mano" in lower_s or "puedes barajarla" in lower_s
		# "Puedes convertirlo/la en un Oro sin habilidad para..." (2026-09-07,
		# bug real reportado por el usuario: Perla de Sangre — dos habilidades
		# ACTIVADAS separadas, pero la segunda no tiene 'una vez por turno' ni
		# ':' ni ningún otro cost_type reconocido, así que caía en la rama de
		# 'oración sin coste que sigue a una ACTIVATED abierta' y se fusionaba
		# como continuación de la PRIMERA habilidad en vez de ser su propia
		# entrada — solo se mostraba/podía usar el primer botón).
		var pays_self_convert: bool = "convertirlo en un oro sin habilidad" in lower_s \
			or "convertirla en un oro sin habilidad" in lower_s
		# "Puedes Barajarlo..." (2026-09-07, bug real encontrado en auditoría:
		# Tótem del Dragón Ancestral — variante MASCULINA de pays_self_shuffle,
		# que solo cubría "barajarla"/"barajar esta carta...mano").
		var pays_self_shuffle_masc: bool = "puedes barajarlo" in lower_s
		# "Puedes Descartarlo/Descartarla..." (2026-09-07, bug real encontrado
		# en auditoría: Sumi — coste de autodescartarse, mismo molde que
		# pays_self_banish pero con Descartar).
		var pays_self_discard_self: bool = "puedes descartarlo" in lower_s or "puedes descartarla" in lower_s
		# "Puedes Destruir esta Arma..." (2026-09-07, bug real encontrado en
		# auditoría: Lanza Argenta — coste de autodestruirse).
		var pays_self_destroy: bool = "puedes destruir esta arma" in lower_s
		# "Puedes pagar un/N Oro(s) para..." SIN ':' (2026-09-07, bug real
		# encontrado en auditoría: Sandraudiga, Visión Heroica — distinto de
		# pays_self_as_gold ('puedes pagarlo', la carta SE PAGA A SÍ MISMA
		# como Oro): acá se paga Oro GENÉRICO de la Reserva como costo de un
		# efecto, la carta de texto no es un Oro. El formato con ':' ya cubre
		# esto cuando la carta lo imprime así; esta es la variante en prosa.
		var pay_gold_rx := RegEx.new()
		pay_gold_rx.compile("puedes pagar (\\w+) oros? para")
		var m_pay_gold := pay_gold_rx.search(lower_s)

		if once_per_turn:
			cost_type = CostType.ONCE_PER_TURN
		elif pays_self_as_gold:
			cost_type = CostType.SELF_AS_GOLD
		elif pays_self_banish:
			cost_type = CostType.SELF_BANISH
		elif pays_self_to_deck_bottom:
			cost_type = CostType.SELF_TO_DECK_BOTTOM
		elif pays_self_shuffle:
			cost_type = CostType.SELF_SHUFFLE
		elif pays_self_convert:
			cost_type = CostType.SELF_CONVERT
		elif pays_self_shuffle_masc:
			cost_type = CostType.SELF_SHUFFLE
		elif pays_self_discard_self:
			cost_type = CostType.SELF_DISCARD
		elif pays_self_destroy:
			cost_type = CostType.SELF_DESTROY
		elif m_pay_gold:
			cost_type = CostType.GOLD
			cost_amount = _parse_amount(m_pay_gold.get_string(1))
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
			# Oración sin coste ni trigger propio: si no es una regla estática/pasiva
			# y viene justo después de una habilidad ACTIVADA abierta, es su continuación
			# (p.ej. Tesoro de los Césares: "Una vez por turno... nombrar una carta. Esa carta cuesta...").
			var is_static_rule := lower_s.begins_with("no se puede") or lower_s.begins_with("los aliados") \
				or lower_s.begins_with("tus aliados") or lower_s.begins_with("los talismán") \
				or lower_s.begins_with("las armas") or lower_s.begins_with("los tótem") \
				or lower_s.begins_with("juega mostrando") or lower_s.begins_with("mientras controles") \
				or lower_s.begins_with("mientras esté en juego") or lower_s.begins_with("gana ") \
				or lower_s.begins_with("pierde ") or lower_s.begins_with("no puede ser ")

			if not is_static_rule and not result.is_empty() and result[result.size() - 1].get("ability_type", "") == "ACTIVATED":
				var prev_open: Dictionary = result[result.size() - 1]
				prev_open["raw_text"]    = "%s. %s" % [prev_open.get("raw_text", ""), sentence]
				prev_open["effect_text"] = "%s. %s" % [prev_open.get("effect_text", ""), sentence]
				continue
			# Oración sin coste ni trigger → no es habilidad activada reconocida
			# (puede ser texto de reglas pasivo o palabra clave)
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
## "(?:hasta\s+)?" agregado (2026-09-06, p.ej. Mecha-Daikaiju: "Roba hasta
## tres cartas") — "hasta N" no reduce el robo real (nunca hay motivo para
## robar menos de lo permitido), así que tratarlo igual que "Roba N cartas"
## a secas es una simplificación segura.
const DRAW_REGEX: String = "(?:Roba|Robas)\\s+(?:hasta\\s+)?(una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|\\d+)\\s+cartas?"


func extract_action(text: String) -> Dictionary:
	"""Extrae la primera acción reconocida del texto de una habilidad.

	Prioridad:
	  0. Patrones compuestos "puedes [costo] y Roba N" (SHUFFLE_FOR_DRAW,
	     PLAY_WEAPON_DISCOUNT_DRAW) — deben ir antes del robo canónico o
	     éste los captura primero (ver sección 0 abajo)
	  1. Patrón de robo canónico (DRAW_REGEX)
	  2. Resto de ABILITY_PATTERNS en orden de iteración

	Retorna un GameAction con: type, action_type, value, manager_path, method, params, raw_text.
	Si no detecta nada: {matched: false}.

	Ejemplo — Ciudad de los Césares 'Roba dos cartas':
	  → {matched: true, type: 'DRAW', value: 2, manager_path: '/root/ActionModule', method: 'draw'}
	"""
	if text.is_empty():
		return {"matched": false}

	# ── 0. Patrones compuestos "puedes [costo] y Roba N cartas" (2026-08-22) ──
	# Van ANTES que todo lo demás, incluido el robo canónico (sección 1): si
	# no, 'puedes barajar... y Roba dos cartas' se adelanta y ejecuta 'Roba
	# dos cartas' suelto, ignorando el 'puedes' y el costo que lo condiciona
	# — bug real visto con Bernardo O'Higgins y Lobo Sagrado. extract_action()
	# solo soporta UN grupo de cantidad genérico y estos casos necesitan
	# varios números a la vez, así que se resuelven aparte.
	var shuffle_draw_rx := RegEx.new()
	shuffle_draw_rx.compile("(?i)puedes barajar cartas? cuyos? costes? sum(?:en|an) hasta (\\w+)[^.]*?y robar? (\\w+) cartas?")
	var m_sd := shuffle_draw_rx.search(text)
	if m_sd:
		var max_sum: int = _parse_amount(m_sd.get_string(1))
		var draw_amt: int = _parse_amount(m_sd.get_string(2))
		print("[Parser] Acción detectada: SHUFFLE_FOR_DRAW | Suma máx: %d | Roba: %d" % [max_sum, draw_amt])
		return {
			"matched":      true,
			"type":         "SHUFFLE_FOR_DRAW",
			"action_type":  ActionType.CUSTOM,
			"value":        draw_amt,
			"params":       {"max_cost_sum": max_sum, "draw_amount": draw_amt},
			"raw_text":     m_sd.get_string(0),
		}

	var weapon_draw_rx := RegEx.new()
	weapon_draw_rx.compile("(?i)puedes jugar un arma desde tu mano o cementerio reduciendo su coste en (\\w+) oros?, hasta un m[ií]nimo de (\\w+)[^.]*?y robar? (\\w+) cartas?")
	var m_wd := weapon_draw_rx.search(text)
	if m_wd:
		var discount: int = _parse_amount(m_wd.get_string(1))
		var floor_val: int = _parse_amount(m_wd.get_string(2))
		var draw_amt2: int = _parse_amount(m_wd.get_string(3))
		print("[Parser] Acción detectada: PLAY_WEAPON_DISCOUNT_DRAW | Descuento: %d | Mínimo: %d | Roba: %d" % [discount, floor_val, draw_amt2])
		return {
			"matched":      true,
			"type":         "PLAY_WEAPON_DISCOUNT_DRAW",
			"action_type":  ActionType.CUSTOM,
			"value":        draw_amt2,
			"params":       {"discount": discount, "floor": floor_val, "draw_amount": draw_amt2},
			"raw_text":     m_wd.get_string(0),
		}

	# Variante sin robo, solo desde la mano (p.ej. Hanta: "puedes jugar un
	# Arma de tu mano reduciendo su coste en 1 Oro, hasta un mínimo de 0").
	var weapon_hand_rx := RegEx.new()
	weapon_hand_rx.compile("(?i)puedes jugar un arma de tu mano reduciendo su coste en (\\w+) oros?,?\\s*hasta un m[ií]nimo de (\\w+)")
	var m_wh := weapon_hand_rx.search(text)
	if m_wh:
		var discount2: int = _parse_amount(m_wh.get_string(1))
		var floor_val2: int = _parse_amount(m_wh.get_string(2))
		print("[Parser] Acción detectada: PLAY_WEAPON_DISCOUNT | Descuento: %d | Mínimo: %d" % [discount2, floor_val2])
		return {
			"matched":      true,
			"type":         "PLAY_WEAPON_DISCOUNT",
			"action_type":  ActionType.CUSTOM,
			"value":        discount2,
			"params":       {"discount": discount2, "floor": floor_val2, "hand_only": true, "draw_amount": 0},
			"raw_text":     m_wh.get_string(0),
		}

	# Patrón "sube un Arma que controles a la mano de su dueño para jugar un
	# Arma del mismo o menor coste desde tu mano sin pagar su coste" (p.ej.
	# Padre de la Patria, 2026-08-28) — swap de Armas, no descuento fijo
	# como Lobo Sagrado/Hanta, por eso no reusa weapon_draw_rx/weapon_hand_rx.
	var weapon_swap_rx := RegEx.new()
	weapon_swap_rx.compile("(?i)subir un arma que controles a la mano de su due[ñn]o para jugar un arma del mismo o menor coste desde tu mano sin pagar su coste")
	var m_ws := weapon_swap_rx.search(text)
	if m_ws:
		print("[Parser] Acción detectada: RETURN_WEAPON_SWAP_FREE")
		return {
			"matched":      true,
			"type":         "RETURN_WEAPON_SWAP_FREE",
			"action_type":  ActionType.CUSTOM,
			"value":        0,
			"params":       {},
			"raw_text":     m_ws.get_string(0),
		}

	# Patrón "convertir un Oro o una carta de coste N o menos en una carta
	# del mismo tipo sin habilidad" (DAR Sección 8 - Convertir, p.ej.
	# Capitán O'Brien, 2026-08-28) — misma carta física, misma
	# tipo/coste/Fuerza, solo pierde la habilidad. Objetivo: dentro del
	# juego (propio o enemigo), salvo que el texto diga lo contrario.
	var convert_rx := RegEx.new()
	convert_rx.compile("(?i)convertir un oro o una carta de coste (\\w+) o menos en una carta del mismo tipo sin habilidad")
	var m_cv := convert_rx.search(text)
	if m_cv:
		var max_cost: int = _parse_amount(m_cv.get_string(1))
		print("[Parser] Acción detectada: CONVERT_ORO_OR_LOW_COST | Coste máx: %d" % max_cost)
		return {
			"matched":      true,
			"type":         "CONVERT_ORO_OR_LOW_COST",
			"action_type":  ActionType.CUSTOM,
			"value":        max_cost,
			"params":       {"max_cost": max_cost},
			"raw_text":     m_cv.get_string(0),
		}

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


# parse_text()/TRIGGER_RX/COST_RX/ACTION_RX/debug_parse() se eliminaron acá
# (2026-08-27, limpieza a pedido del usuario): sin ningún llamador real —
# era una implementación paralela y más vieja de lo que parse_abilities()
# hace hoy (que es lo que CardInspectionLayer usa de verdad para los
# botones de habilidad activada, pese a que el docstring de parse_text()
# decía que ERA esa fuente).
