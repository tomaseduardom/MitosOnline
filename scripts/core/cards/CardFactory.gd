extends Node
## CardFactory - Convierte datos JSON en recursos Card con bloques de habilidades
## Mapea datos de la base de datos a la estructura del juego

# =============================================================================
# CONSTANTES
# =============================================================================
const CARD_SCENE_PATH = "res://scenes/cards/Card.tscn"

## Palabras clave que indican triggers
const TRIGGER_PATTERNS: Dictionary = {
	"on_enter_play": ["cuando entre al juego", "al entrar al juego", "cuando entra al juego", "al ser jugado"],
	"on_leave_play": ["cuando deje el juego", "al dejar el juego", "cuando abandona el juego"],
	"on_destroyed": ["cuando sea destruido", "cuando muera", "al ser destruido", "al morir"],
	"on_discard": ["cuando descartes", "al descartar", "cuando sea descartado"],
	"on_draw": ["cuando robes", "al robar", "cada vez que robes"],
	"on_attack": ["cuando ataque", "al atacar", "cada vez que ataque"],
	"on_block": ["cuando bloquee", "al bloquear"],
	"on_damage_dealt": ["cuando inflija daño", "al infligir daño", "si hizo daño", "cuando haga daño", "si inflige daño"],
	"on_damage_received": ["cuando reciba daño", "al recibir daño"],
	"on_turn_start": ["al comienzo del turno", "al inicio del turno", "al comenzar tu turno"],
	"on_turn_end": ["al final del turno", "al terminar el turno", "al finalizar tu turno"],
	"on_ally_enters": ["cuando otro aliado entre", "cuando un aliado entre"],
	"on_ally_dies": ["cuando otro aliado muera", "cuando un aliado sea destruido"],
	"on_oro_placed": ["cuando pongas un oro", "al poner un oro", "cada vez que pongas un oro"],
	"on_card_played": ["cuando juegues", "al jugar una carta"],
	"on_activate": ["activa:", "activar:"],  # Habilidades activadas manualmente
}

## Palabras clave que indican costes
const COST_PATTERNS: Dictionary = {
	"pay_gold": ["paga %d oro", "paga %d de oro", "gasta %d oro"],
	"discard_cards": ["descarta %d carta", "descarta una carta", "descarta %d cartas"],
	"sacrifice": ["sacrifica", "sacrifica un aliado", "sacrifica una criatura"],
	"tap": ["gira", "gira esta carta", "gírala"],
	"exile_from_grave": ["destierra %d carta de tu cementerio", "exilia una carta de tu cementerio"],
	"life_cost": ["paga %d vida", "pierde %d vida"],
}

## Palabras clave que indican efectos/acciones
const EFFECT_PATTERNS: Dictionary = {
	"draw": ["roba %d carta", "roba una carta", "roba %d cartas"],
	"discard": ["descarta %d carta", "cada jugador descarta"],
	"destroy": ["destruye", "destruye un", "destruye una", "destruye todos"],
	"damage": ["inflige %d de daño", "hace %d de daño", "causa %d de daño"],
	"buff": ["+%d/+%d", "obtiene +%d", "gana +%d de fuerza"],
	"debuff": ["-%d/-%d", "pierde -%d", "tiene -%d"],
	"heal": ["gana %d vida", "recupera %d vida", "cura %d"],
	"mill": ["envía %d carta al cementerio", "muele %d carta"],
	"search": ["busca", "busca en tu mazo", "busca una carta"],
	"return_to_hand": ["devuelve a la mano", "regresa a tu mano"],
	"return_to_deck": ["devuelve al mazo", "pon en la parte superior", "pon en el fondo"],
	"banish": ["destierra", "exilia", "remueve del juego"],
	"counter": ["contrarresta", "cancela", "niega"],
	"copy": ["copia", "crea una copia"],
	"token": ["crea un token", "genera un token", "invoca un token"],
	"virtual_gold": ["genera %d oro", "obtiene %d oro virtual", "añade %d oro"],
	"look": ["mira las %d primeras", "mira el tope de tu mazo"],
	"reveal": ["revela", "muestra"],
	"shuffle": ["baraja", "mezcla tu mazo"],
}

## Conectores de pipeline (DAR 7.1)
const CONNECTOR_PATTERNS: Dictionary = {
	"LUEGO": ["luego", "después", "a continuación", "entonces"],
	"Y": [" y ", ", y "],
	"O": [" o ", "alternativamente"],
}

# =============================================================================
# REFERENCIAS
# =============================================================================
var _card_scene: PackedScene = null


func _ready() -> void:
	_card_scene = load(CARD_SCENE_PATH)
	print("[CardFactory] Inicializado")


# =============================================================================
# CREACIÓN DE CARTAS
# =============================================================================
func create_card_from_json(json_data: Dictionary) -> Node:
	"""Crea una instancia de Card desde datos JSON de la API

	Args:
		json_data: Diccionario con datos de la carta desde la API

	Returns: Nodo Card configurado
	"""
	if not _card_scene:
		_card_scene = load(CARD_SCENE_PATH)
		if not _card_scene:
			push_error("[CardFactory] No se pudo cargar la escena de carta")
			return null

	var card = _card_scene.instantiate()

	# Mapear datos JSON a propiedades de la carta
	_map_basic_properties(card, json_data)

	# Parsear y asignar bloques de habilidad
	var ability_blocks = parse_ability_to_blocks(json_data.get("habilidad", ""))
	card.set_meta("ability_blocks", ability_blocks)

	# Escanear keywords automáticamente y activar flags (DAR Sección 8)
	_scan_and_apply_keywords(card)

	return card


func _scan_and_apply_keywords(card: Node) -> void:
	"""Escanea el texto de habilidad y activa flags de keywords

	Usa KeywordManager si está disponible, sino aplica directamente
	"""
	var keyword_mgr = get_node_or_null("/root/KeywordManager")

	if keyword_mgr:
		# Usar KeywordManager para escaneo completo
		keyword_mgr.scan_and_apply_keywords(card)
	else:
		# Fallback: aplicar flags básicos directamente
		var keywords = card.get("card_keywords")
		if keywords is Array:
			for kw in keywords:
				_apply_keyword_flag_fallback(card, kw)


func _apply_keyword_flag_fallback(card: Node, keyword) -> void:
	"""Aplica flags directamente sin KeywordManager (fallback)"""
	var kw_val: int = keyword if keyword is int else -1

	# Si es string, mapear a Constants.Keyword
	if keyword is String:
		var kw_lower = keyword.to_lower()
		match kw_lower:
			"furia":
				kw_val = Constants.Keyword.FURIA
			"imbloqueable":
				kw_val = Constants.Keyword.IMBLOQUEABLE
			"indestructible":
				kw_val = Constants.Keyword.INDESTRUCTIBLE

	# Aplicar flag según keyword
	if kw_val == Constants.Keyword.FURIA:
		card.set_meta("has_furia", true)
	elif kw_val == Constants.Keyword.IMBLOQUEABLE:
		card.set_meta("is_unblockable", true)
	elif kw_val == Constants.Keyword.INDESTRUCTIBLE:
		card.set_meta("is_indestructible", true)


func create_card_resource(json_data: Dictionary) -> Dictionary:
	"""Crea un recurso de carta (datos parseados) sin instanciar nodo
	Útil para precargar datos o para el deck builder

	Args:
		json_data: Diccionario con datos de la carta

	Returns: Diccionario con datos mapeados y bloques parseados
	"""
	var resource = {
		# Datos básicos
		"id": str(json_data.get("id", "")),
		"nombre": json_data.get("nombre", json_data.get("name", "Sin nombre")),
		"coste": _parse_int(json_data.get("coste", json_data.get("cost", 0))),
		"fuerza": _parse_int(json_data.get("fuerza", json_data.get("strength", 0))),
		"tipo": _map_card_type(json_data.get("tipo", json_data.get("type", "aliado"))),
		"raza": json_data.get("raza", json_data.get("race", "")),
		"habilidad": json_data.get("habilidad", json_data.get("ability", "")),
		"imagen": json_data.get("imagen", json_data.get("image", "")),
		"edicion": json_data.get("edicion", json_data.get("edition", "")),
		"rareza": json_data.get("rareza", json_data.get("rarity", "comun")),

		# Keywords parseadas
		"keywords": _parse_keywords(json_data),

		# Bloques de habilidad parseados
		"ability_blocks": parse_ability_to_blocks(json_data.get("habilidad", json_data.get("ability", ""))),

		# Metadata original
		"raw_data": json_data,
	}

	return resource


func _map_basic_properties(card: Node, json_data: Dictionary) -> void:
	"""Mapea propiedades básicas del JSON a la carta"""
	# La API puede usar español o inglés
	card.card_id = str(json_data.get("id", ""))
	card.card_name = json_data.get("nombre", json_data.get("name", "Sin nombre"))
	card.card_cost = _parse_int(json_data.get("coste", json_data.get("cost", 0)))
	card.card_strength = _parse_int(json_data.get("fuerza", json_data.get("strength", 0)))
	card.card_type = _map_card_type(json_data.get("tipo", json_data.get("type", "aliado")))
	card.card_raza = json_data.get("raza", json_data.get("race", ""))
	card.card_ability = json_data.get("habilidad", json_data.get("ability", ""))
	card.card_image_path = json_data.get("imagen", json_data.get("image", ""))
	card.card_keywords = _parse_keywords(json_data)

	# Guardar datos completos
	card.card_data = json_data


func _map_card_type(type_value) -> int:
	"""Convierte el tipo de carta del JSON a Constants.CardType"""
	if type_value is int:
		return type_value

	var type_str = str(type_value).to_lower().strip_edges()

	match type_str:
		"oro", "gold", "0":
			return Constants.CardType.ORO
		"aliado", "ally", "creature", "1":
			return Constants.CardType.ALIADO
		"arma", "weapon", "2":
			return Constants.CardType.ARMA
		"talisman", "talismán", "spell", "3":
			return Constants.CardType.TALISMAN
		"totem", "tótem", "structure", "4":
			return Constants.CardType.TOTEM
		_:
			return Constants.CardType.ALIADO


func _parse_int(value) -> int:
	"""Convierte un valor a entero de forma segura"""
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String:
		return int(value) if value.is_valid_int() else 0
	return 0


func _parse_keywords(json_data: Dictionary) -> Array:
	"""Extrae keywords del JSON o del texto de habilidad"""
	var keywords: Array = []

	# Primero intentar obtener del campo directo
	if json_data.has("keywords"):
		var kw = json_data.get("keywords")
		if kw is Array:
			keywords = kw
		elif kw is String:
			keywords = kw.split(",")

	# Detectar keywords del texto de habilidad
	var ability = json_data.get("habilidad", json_data.get("ability", "")).to_lower()

	if ability.contains("indestructible") or ability.contains("no puede ser destruid"):
		keywords.append(Constants.Keyword.INDESTRUCTIBLE)
	if ability.contains("furia") or ability.contains("puede atacar"):
		keywords.append(Constants.Keyword.FURIA)
	if ability.contains("imbloqueable") or ability.contains("no puede ser bloqueado"):
		keywords.append(Constants.Keyword.IMBLOQUEABLE)
	if ability.contains("indesterrable") or ability.contains("no puede ser desterrad"):
		keywords.append(Constants.Keyword.INDESTERRABLE)
	if ability.contains("exhumar") or ability.contains("jugar desde el cementerio"):
		keywords.append(Constants.Keyword.EXHUMAR)
	if ability.contains("única") or ability.contains("solo 1 copia"):
		keywords.append(Constants.Keyword.UNICA)
	if ability.contains("primer golpe") or ability.contains("first strike") or ability.contains("golpe primero"):
		keywords.append(Constants.Keyword.GOLPE_PRIMERO)

	return keywords


# =============================================================================
# PARSEO DE HABILIDADES A BLOQUES
# =============================================================================
func parse_ability_to_blocks(ability_text: String) -> Array[Dictionary]:
	"""Parsea el texto de habilidad en bloques estructurados
	Cada bloque tiene: trigger, cost, effect, raw_text

	Args:
		ability_text: Texto completo de la habilidad

	Returns: Array de bloques de habilidad
	"""
	var blocks: Array[Dictionary] = []

	if ability_text.is_empty():
		return blocks

	var text_lower = ability_text.to_lower()

	# Dividir por separadores de habilidad (. o ;)
	var sentences = _split_ability_sentences(ability_text)

	for sentence in sentences:
		if sentence.strip_edges().is_empty():
			continue

		var block = _parse_single_block(sentence)
		if not block.is_empty():
			blocks.append(block)

	return blocks


func _split_ability_sentences(text: String) -> Array:
	"""Divide el texto en oraciones de habilidad"""
	var sentences: Array = []

	# Primero dividir por punto
	var parts = text.split(".")

	for part in parts:
		# Luego por punto y coma
		var subparts = part.split(";")
		for subpart in subparts:
			var cleaned = subpart.strip_edges()
			if not cleaned.is_empty():
				sentences.append(cleaned)

	return sentences


func _parse_single_block(sentence: String) -> Dictionary:
	"""Parsea una sola oración de habilidad en un bloque"""
	var block = {
		"trigger": {},      # {type, keyword, conditions}
		"cost": [],         # [{type, amount, target}]
		"effect": [],       # [{type, amount, target, filter}]
		"connector": "",    # LUEGO, Y, O (para pipeline)
		"raw_text": sentence
	}

	var text_lower = sentence.to_lower()

	# 1. Detectar trigger
	block.trigger = _detect_trigger(text_lower)

	# 2. Detectar costes
	block.cost = _detect_costs(text_lower)

	# 3. Detectar efectos
	block.effect = _detect_effects(text_lower, sentence)

	# 4. Detectar conector para el pipeline
	block.connector = _detect_connector(text_lower)

	# Si no tiene trigger ni efecto, bloque vacío
	if block.trigger.is_empty() and block.effect.is_empty():
		return {}

	return block


func _detect_trigger(text: String) -> Dictionary:
	"""Detecta el tipo de trigger en el texto"""
	for trigger_type in TRIGGER_PATTERNS:
		var patterns: Array = TRIGGER_PATTERNS[trigger_type]
		for pattern in patterns:
			if text.contains(pattern):
				return {
					"type": trigger_type,
					"keyword": pattern,
					"conditions": _extract_trigger_conditions(text, pattern)
				}

	# Sin trigger = efecto estático o activado
	return {}


func _extract_trigger_conditions(text: String, trigger_keyword: String) -> Dictionary:
	"""Extrae condiciones adicionales del trigger"""
	var conditions = {}

	# Verificar "tu" vs "oponente"
	if text.contains("tú ") or text.contains(" tu "):
		conditions["owner"] = "self"
	elif text.contains("oponente") or text.contains("rival"):
		conditions["owner"] = "opponent"

	# Verificar "otro"
	if text.contains("otro "):
		conditions["exclude_self"] = true

	return conditions


func _detect_costs(text: String) -> Array:
	"""Detecta los costes de activación en el texto"""
	var costs: Array = []

	for cost_type in COST_PATTERNS:
		var patterns: Array = COST_PATTERNS[cost_type]
		for pattern in patterns:
			# Buscar patrón con número
			if pattern.contains("%d"):
				var amount = _extract_number_near_pattern(text, pattern.replace("%d", ""))
				if amount > 0:
					costs.append({
						"type": cost_type,
						"amount": amount
					})
			elif text.contains(pattern):
				costs.append({
					"type": cost_type,
					"amount": 1
				})

	return costs


func _detect_effects(text_lower: String, original_text: String) -> Array:
	"""Detecta los efectos/acciones en el texto"""
	var effects: Array = []

	for effect_type in EFFECT_PATTERNS:
		var patterns: Array = EFFECT_PATTERNS[effect_type]
		for pattern in patterns:
			var pattern_lower = pattern.to_lower()

			# Buscar patrón con número
			if pattern.contains("%d"):
				var base_pattern = pattern_lower.replace("%d", "").strip_edges()
				if text_lower.contains(base_pattern):
					var amount = _extract_number_near_pattern(text_lower, base_pattern)
					var effect = {
						"type": effect_type,
						"amount": max(1, amount),
						"target": _extract_target(text_lower, effect_type),
						"filter": _extract_filter(text_lower, effect_type)
					}
					effects.append(effect)
					break  # Solo un efecto por tipo
			elif text_lower.contains(pattern_lower):
				var effect = {
					"type": effect_type,
					"amount": 1,
					"target": _extract_target(text_lower, effect_type),
					"filter": _extract_filter(text_lower, effect_type)
				}
				effects.append(effect)
				break

	return effects


func _extract_number_near_pattern(text: String, pattern: String) -> int:
	"""Extrae un número cercano a un patrón"""
	var pos = text.find(pattern)
	if pos == -1:
		return 0

	# Buscar en un rango alrededor del patrón
	var start = max(0, pos - 10)
	var end = min(text.length(), pos + pattern.length() + 10)
	var substring = text.substr(start, end - start)

	# Mapeo de palabras a números
	var word_numbers = {
		"una": 1, "un": 1, "1": 1,
		"dos": 2, "2": 2,
		"tres": 3, "3": 3,
		"cuatro": 4, "4": 4,
		"cinco": 5, "5": 5,
		"seis": 6, "6": 6,
		"siete": 7, "7": 7,
		"ocho": 8, "8": 8,
		"nueve": 9, "9": 9,
		"diez": 10, "10": 10,
	}

	for word in word_numbers:
		if substring.contains(word):
			return word_numbers[word]

	# Buscar dígitos
	var regex = RegEx.new()
	regex.compile("\\d+")
	var result = regex.search(substring)
	if result:
		return int(result.get_string())

	return 1


func _extract_target(text: String, effect_type: String) -> Dictionary:
	"""Extrae el objetivo del efecto"""
	var target = {
		"type": "any",  # any, self, opponent, card, player
		"zone": "",
		"count": 1
	}

	# Detectar a quién afecta
	if text.contains("objetivo") or text.contains("target"):
		target.type = "targeted"
	elif text.contains("a ti") or text.contains("tú"):
		target.type = "self"
	elif text.contains("oponente") or text.contains("rival"):
		target.type = "opponent"
	elif text.contains("todos") or text.contains("cada"):
		target.type = "all"

	# Detectar zona
	if text.contains("cementerio") or text.contains("graveyard"):
		target.zone = "cemetery"
	elif text.contains("mazo") or text.contains("castillo") or text.contains("deck"):
		target.zone = "deck"
	elif text.contains("mano"):
		target.zone = "hand"
	elif text.contains("juego") or text.contains("campo"):
		target.zone = "play"

	return target


func _extract_filter(text: String, effect_type: String) -> Dictionary:
	"""Extrae filtros para selección de cartas"""
	var filter = {}

	# Filtro por tipo de carta
	if text.contains("aliado") or text.contains("criatura"):
		filter["card_type"] = Constants.CardType.ALIADO
	elif text.contains("arma"):
		filter["card_type"] = Constants.CardType.ARMA
	elif text.contains("talisman") or text.contains("talismán"):
		filter["card_type"] = Constants.CardType.TALISMAN
	elif text.contains("totem") or text.contains("tótem"):
		filter["card_type"] = Constants.CardType.TOTEM
	elif text.contains("oro"):
		filter["card_type"] = Constants.CardType.ORO

	# Filtro por raza
	var razas = ["ángel", "demonio", "dragón", "humano", "elfo", "enano", "no-muerto", "bestia", "gólem"]
	for raza in razas:
		if text.contains(raza):
			filter["raza"] = raza
			break

	# Filtro por coste
	var cost_pattern = RegEx.new()
	cost_pattern.compile("coste? (\\d+) o menos")
	var cost_match = cost_pattern.search(text)
	if cost_match:
		filter["cost_max"] = int(cost_match.get_string(1))

	cost_pattern.compile("coste? (\\d+) o más")
	cost_match = cost_pattern.search(text)
	if cost_match:
		filter["cost_min"] = int(cost_match.get_string(1))

	return filter


func _detect_connector(text: String) -> String:
	"""Detecta el conector para el pipeline de acciones"""
	for connector in CONNECTOR_PATTERNS:
		var patterns: Array = CONNECTOR_PATTERNS[connector]
		for pattern in patterns:
			if text.contains(pattern):
				return connector
	return ""


# =============================================================================
# ON ENTER PLAY - Escaneo de keywords al entrar en juego
# =============================================================================
func on_card_enters_play(card: Node) -> void:
	"""Llamar cuando una carta entra en juego para escanear keywords

	Esta función debe invocarse desde GameBoard/EffectController cuando
	una carta se mueve a una zona de juego (Línea de Defensa, Línea de Apoyo, etc.)

	Esto asegura que cartas que entran por efectos (no por CardFactory)
	también tengan sus keywords escaneados.
	"""
	# Marcar que entró este turno (para verificación de Furia, DAR 3.1)
	card.entered_this_turn = true

	# Escanear keywords si no se hizo antes
	_scan_and_apply_keywords(card)

	# Emitir señal para que otros sistemas reaccionen
	var keyword_mgr = get_node_or_null("/root/KeywordManager")
	if keyword_mgr:
		var keywords = keyword_mgr.get_cached_keywords(card)
		if not keywords.is_empty():
			print("[CardFactory] %s entró en juego con keywords: %s" % [
				card.card_name if card.get("card_name") else "Carta",
				keywords.map(func(k): return keyword_mgr.Keyword.keys()[k])
			])


func on_turn_start_clear_summon_sickness(player_id: int) -> void:
	"""Limpia entered_this_turn de los Aliados del jugador que pasaron por su
	Agrupación (DAR 3.1) — a partir de ahí pueden atacar sin necesitar Furia.
	Llamar al inicio de cada Fase de Agrupación del dueño de las cartas.

	No depende de GameManager.game_board (GameBoard legacy huérfano, ver
	docs/audit) — usa directamente el campo real de Main."""
	var main = get_node_or_null("/root/Main")
	if not main:
		return
	var field = main.player_field if player_id == 0 else main.opponent_field
	if not field:
		return
	for card in field.get_children():
		if card.get("entered_this_turn") == true:
			card.entered_this_turn = false
			print("[CardFactory] %s ya puede atacar sin Furia (pasó por Agrupación)" % (
				card.card_name if card.get("card_name") else "Aliado"
			))


# =============================================================================
# BATCH PROCESSING
# =============================================================================
func create_cards_from_json_array(json_array: Array) -> Array:
	"""Crea múltiples cartas desde un array JSON

	Args:
		json_array: Array de diccionarios con datos de cartas

	Returns: Array de nodos Card
	"""
	var cards: Array = []

	for json_data in json_array:
		var card = create_card_from_json(json_data)
		if card:
			cards.append(card)

	return cards


func create_card_resources_from_json_array(json_array: Array) -> Array:
	"""Crea recursos de cartas (sin instanciar) desde un array JSON

	Args:
		json_array: Array de diccionarios con datos de cartas

	Returns: Array de recursos de carta
	"""
	var resources: Array = []

	for json_data in json_array:
		var resource = create_card_resource(json_data)
		resources.append(resource)

	return resources
