extends Node
## KeywordManager - Gestiona palabras clave de cartas (DAR Sección 7-8)
## Mapea keywords a flags booleanos y provee verificación centralizada
## NOTA: Usa Constants.Keyword como enum centralizado

# =============================================================================
# ALIAS - Usar Constants.Keyword para todo
# =============================================================================
## Alias para acceso rápido (KeywordManager.Keyword → Constants.Keyword)
var Keyword = Constants.Keyword

## Mapeo de texto español → Constants.Keyword
var KEYWORD_MAP: Dictionary = {}

## Patrones de texto que indican keywords
var KEYWORD_PATTERNS: Dictionary = {}


func _init() -> void:
	# Inicializar mapeos usando Constants.Keyword
	_init_keyword_map()
	_init_keyword_patterns()


func _init_keyword_map() -> void:
	"""Inicializa el mapeo de texto → Constants.Keyword"""
	KEYWORD_MAP = {
		# Nombres exactos en español
		"furia": Constants.Keyword.FURIA,
		"imbloqueable": Constants.Keyword.IMBLOQUEABLE,
		"indestructible": Constants.Keyword.INDESTRUCTIBLE,
		"indesterrable": Constants.Keyword.INDESTERRABLE,
		"golpe primero": Constants.Keyword.GOLPE_PRIMERO,
		"doble golpe": Constants.Keyword.DOBLE_GOLPE,
		"vigilancia": Constants.Keyword.VIGILANCIA,
		"alcance": Constants.Keyword.ALCANCE,
		"arrollar": Constants.Keyword.ARROLLAR,
		"única": Constants.Keyword.UNICA,
		"unica": Constants.Keyword.UNICA,
		"exhumar": Constants.Keyword.EXHUMAR,
		"regenerar": Constants.Keyword.REGENERAR,
		"veloz": Constants.Keyword.VELOZ,
		"evasión": Constants.Keyword.EVASION,
		"evasion": Constants.Keyword.EVASION,
		"escudo": Constants.Keyword.ESCUDO,
		"anular": Constants.Keyword.ANULAR,
		"inmune a talismanes": Constants.Keyword.INMUNE_TALISMANES,
		"inmune a habilidades": Constants.Keyword.INMUNE_HABILIDADES,
		"portar múltiples armas": Constants.Keyword.PORTAR_MULTIPLE,
		# Variantes en inglés (compatibilidad)
		"haste": Constants.Keyword.FURIA,
		"unblockable": Constants.Keyword.IMBLOQUEABLE,
		"first strike": Constants.Keyword.GOLPE_PRIMERO,
		"double strike": Constants.Keyword.DOBLE_GOLPE,
		"trample": Constants.Keyword.ARROLLAR,
		"reach": Constants.Keyword.ALCANCE,
	}


func _init_keyword_patterns() -> void:
	"""Inicializa patrones de texto que indican keywords"""
	KEYWORD_PATTERNS = {
		Constants.Keyword.FURIA: ["puede atacar el turno que entra", "atacar inmediatamente"],
		Constants.Keyword.IMBLOQUEABLE: ["no puede ser bloqueado", "no puede ser bloquead"],
		Constants.Keyword.INDESTRUCTIBLE: ["no puede ser destruid", "no es destruid"],
		Constants.Keyword.INDESTERRABLE: ["no puede ser desterrad"],
		Constants.Keyword.ARROLLAR: ["daño excedente", "daño sobrante al castillo"],
		Constants.Keyword.REGENERAR: ["vuelve del cementerio", "regresa del cementerio"],
		Constants.Keyword.INMUNE_TALISMANES: ["no puede ser objetivo de talismanes"],
		Constants.Keyword.INMUNE_HABILIDADES: ["no puede ser objetivo de habilidades"],
		Constants.Keyword.ANULAR: ["anula", "contrarresta", "cancela"],
	}

# =============================================================================
# SIGNALS
# =============================================================================
signal keyword_granted(card: Node, keyword: int, source: Node)
signal keyword_removed(card: Node, keyword: int, source: Node)
signal keyword_check_performed(card: Node, keyword: int, result: bool)

# =============================================================================
# ESTADO
# =============================================================================
## Keywords temporales otorgados por efectos {card_instance_id: {keyword: [sources]}}
var _temporary_keywords: Dictionary = {}

## Keywords removidos temporalmente {card_instance_id: {keyword: [sources]}}
var _removed_keywords: Dictionary = {}

## Cartas silenciadas (pierden TODAS sus keywords y no disparan habilidades)
## {card_instance_id: [{source, duration}]}
var _silenced_cards: Dictionary = {}


## Cache de keywords parseados por carta {card_instance_id: Array}
var _parsed_cache: Dictionary = {}


func _ready() -> void:
	# Conectar a señales de fin de turno para limpiar temporales.
	# GameManager es el único conductor de turnos (ver consolidación 2026-08-19).
	if GameManager and GameManager.has_signal("turn_ended"):
		GameManager.turn_ended.connect(_on_turn_ended)


# =============================================================================
# PARSING DE KEYWORDS
# =============================================================================
func parse_keywords_from_text(ability_text: String) -> Array:
	"""Extrae keywords del texto de habilidad de una carta"""
	if ability_text.is_empty():
		return []

	var found: Array = []
	var text_lower = ability_text.to_lower()

	# Buscar keywords directos
	for keyword_str in KEYWORD_MAP:
		if keyword_str in text_lower:
			var kw = KEYWORD_MAP[keyword_str]
			if kw not in found:
				found.append(kw)

	# Buscar patrones
	for keyword in KEYWORD_PATTERNS:
		for pattern in KEYWORD_PATTERNS[keyword]:
			if pattern in text_lower:
				if keyword not in found:
					found.append(keyword)
				break

	return found


func parse_keywords_from_array(keywords_array: Array) -> Array:
	"""Convierte un array de strings a array de Keyword enum"""
	var result: Array = []

	for kw in keywords_array:
		if kw is String:
			var kw_lower = kw.to_lower()
			if kw_lower in KEYWORD_MAP:
				result.append(KEYWORD_MAP[kw_lower])
		elif kw is int and kw in Constants.Keyword.values():
			result.append(kw)

	return result


# =============================================================================
# PARSER AUTOMÁTICO - Escanea texto de habilidad y activa flags (DAR Sección 8)
# =============================================================================
func scan_and_apply_keywords(card: Node) -> Array:
	"""Escanea el texto de habilidad de la carta y activa los flags correspondientes

	Esta función debe llamarse cuando una carta entra en juego para que
	sus keywords sean reconocidos automáticamente sin intervención manual.

	Returns: Array de keywords encontrados y aplicados
	"""
	if not is_instance_valid(card):
		return []

	var card_id = card.get_instance_id()

	# Verificar cache
	if _parsed_cache.has(card_id):
		return _parsed_cache[card_id]

	var found_keywords: Array = []

	# Fuente 1: Texto de habilidad (card_ability)
	var ability_text = card.get("card_ability")
	if ability_text is String and not ability_text.is_empty():
		var from_text = parse_keywords_from_text(ability_text)
		for kw in from_text:
			if kw not in found_keywords:
				found_keywords.append(kw)

	# Fuente 2: Array de keywords existente
	var existing_keywords = card.get("card_keywords")
	if existing_keywords is Array:
		var from_array = parse_keywords_from_array(existing_keywords)
		for kw in from_array:
			if kw not in found_keywords:
				found_keywords.append(kw)

	# Aplicar flags booleanos a la carta
	_apply_keyword_flags(card, found_keywords)

	# Cachear resultado
	_parsed_cache[card_id] = found_keywords

	if not found_keywords.is_empty():
		var card_name = _get_card_name(card)
		var kw_names = found_keywords.map(func(k): return Constants.Keyword.keys()[k])
		print("[KeywordManager] %s → Keywords: %s" % [card_name, ", ".join(kw_names)])

	return found_keywords


func _apply_keyword_flags(card: Node, keywords: Array) -> void:
	"""Aplica flags booleanos a la carta basándose en los keywords detectados

	Esto permite que otras partes del código verifiquen card.has_furia, etc.
	"""
	for keyword in keywords:
		match keyword:
			Keyword.FURIA:
				_set_card_flag(card, "has_furia", true)
			Keyword.IMBLOQUEABLE:
				_set_card_flag(card, "is_unblockable", true)
			Keyword.INDESTRUCTIBLE:
				_set_card_flag(card, "is_indestructible", true)
			Keyword.INDESTERRABLE:
				_set_card_flag(card, "is_unbanishable", true)
			Keyword.GOLPE_PRIMERO:
				_set_card_flag(card, "has_first_strike", true)
			Keyword.DOBLE_GOLPE:
				_set_card_flag(card, "has_double_strike", true)
			Keyword.VIGILANCIA:
				_set_card_flag(card, "has_vigilance", true)
			Keyword.ALCANCE:
				_set_card_flag(card, "has_reach", true)
			Keyword.ARROLLAR:
				_set_card_flag(card, "has_trample", true)
			Keyword.UNICA:
				_set_card_flag(card, "is_unique", true)
			Keyword.EXHUMAR:
				_set_card_flag(card, "has_exhume", true)
			Keyword.REGENERAR:
				_set_card_flag(card, "has_regenerate", true)
			Keyword.VELOZ:
				_set_card_flag(card, "is_swift", true)
			Keyword.EVASION:
				_set_card_flag(card, "has_evasion", true)
			Keyword.ESCUDO:
				_set_card_flag(card, "has_shield", true)
			Keyword.INMUNE_TALISMANES:
				_set_card_flag(card, "immune_to_talismans", true)
			Keyword.INMUNE_HABILIDADES:
				_set_card_flag(card, "immune_to_abilities", true)
			Keyword.PORTAR_MULTIPLE:
				_set_card_flag(card, "can_wield_multiple", true)


func _set_card_flag(card: Node, flag_name: String, value: bool) -> void:
	"""Establece un flag en la carta si la propiedad existe o es un script"""
	if card.has_method("set"):
		card.set(flag_name, value)
	elif flag_name in card:
		card[flag_name] = value
	else:
		# Crear la propiedad dinámicamente si el script lo permite
		card.set_meta(flag_name, value)


func rescan_card(card: Node) -> Array:
	"""Fuerza un re-escaneo de keywords (útil si el texto cambió)"""
	var card_id = card.get_instance_id()
	_parsed_cache.erase(card_id)
	return scan_and_apply_keywords(card)


func get_cached_keywords(card: Node) -> Array:
	"""Obtiene keywords cacheados sin re-escanear"""
	var card_id = card.get_instance_id()
	return _parsed_cache.get(card_id, [] as Array)


# =============================================================================
# VERIFICACIÓN DE KEYWORDS (Usadas por BattleManager y otros)
# =============================================================================
func has_keyword(card: Node, keyword: int) -> bool:
	"""Verifica si una carta tiene un keyword específico

	Orden de verificación:
	1. Keywords removidos temporalmente (prioridad negativa)
	2. Keywords temporales otorgados
	3. Keywords inherentes de la carta
	"""
	if not is_instance_valid(card):
		return false

	var card_id = card.get_instance_id()

	# Verificar si fue removido temporalmente (Regla de Prioridad Negativa)
	if _removed_keywords.has(card_id):
		if _removed_keywords[card_id].has(keyword):
			emit_signal("keyword_check_performed", card, keyword, false)
			return false

	# Verificar keywords temporales
	if _temporary_keywords.has(card_id):
		if _temporary_keywords[card_id].has(keyword):
			emit_signal("keyword_check_performed", card, keyword, true)
			return true

	# Verificar keywords inherentes de la carta
	var result = _check_inherent_keyword(card, keyword)
	emit_signal("keyword_check_performed", card, keyword, result)
	return result


func _check_inherent_keyword(card: Node, keyword: int) -> bool:
	"""Verifica keywords inherentes de la carta

	Orden de verificación:
	1. Cache de keywords parseados (más eficiente)
	2. Método card.has_keyword() si existe
	3. Array de keywords en la carta
	4. Flags booleanos directos
	5. Parsing en tiempo real (fallback)
	"""
	var card_id = card.get_instance_id()

	# Método 1: Verificar cache (resultado de scan_and_apply_keywords)
	if _parsed_cache.has(card_id):
		return keyword in _parsed_cache[card_id]

	# Método 2: card.has_keyword()
	if card.has_method("has_keyword"):
		if card.has_keyword(keyword):
			return true

	# Método 3: Array de keywords en la carta
	if card.get("card_keywords") != null:
		var keywords = card.card_keywords
		if keywords is Array:
			for kw in keywords:
				if kw is int and kw == keyword:
					return true
				elif kw is String:
					var kw_lower = kw.to_lower()
					if KEYWORD_MAP.has(kw_lower) and KEYWORD_MAP[kw_lower] == keyword:
						return true

	# Método 4: Flags directos (compatibilidad)
	match keyword:
		Keyword.FURIA:
			if card.get("has_furia") == true or card.get("has_haste") == true:
				return true
			if card.get_meta("has_furia", false):
				return true
		Keyword.IMBLOQUEABLE:
			if card.get("is_unblockable") == true:
				return true
			if card.get_meta("is_unblockable", false):
				return true
		Keyword.INDESTRUCTIBLE:
			if card.get("is_indestructible") == true:
				return true
			if card.get_meta("is_indestructible", false):
				return true
		Keyword.INDESTERRABLE:
			if card.get("is_unbanishable") == true:
				return true
			if card.get_meta("is_unbanishable", false):
				return true
		Keyword.GOLPE_PRIMERO:
			if card.get("has_first_strike") == true:
				return true
			if card.get_meta("has_first_strike", false):
				return true
		Keyword.ARROLLAR:
			if card.get("has_trample") == true:
				return true
			if card.get_meta("has_trample", false):
				return true
		Keyword.ALCANCE:
			if card.get("has_reach") == true:
				return true
			if card.get_meta("has_reach", false):
				return true

	# Método 5: Parsing en tiempo real (fallback más lento)
	if card.get("card_ability") != null:
		var parsed = parse_keywords_from_text(card.card_ability)
		if keyword in parsed:
			# Cachear para futuras consultas
			_parsed_cache[card_id] = parsed
			return true

	return false


# =============================================================================
# FUNCIONES HELPER DE COMBATE (Sección 8)
# =============================================================================
func can_attack_immediately(card: Node) -> bool:
	"""DAR Sección 3.1: Aliados no pueden atacar el turno que entran, excepto con Furia"""
	return has_keyword(card, Keyword.FURIA)


func can_be_blocked(attacker: Node, blocker: Node = null) -> bool:
	"""DAR Sección 8: Verifica si un atacante puede ser bloqueado

	- Imbloqueable: No puede ser bloqueado
	- Alcance: Puede bloquear a Imbloqueables
	"""
	if not has_keyword(attacker, Keyword.IMBLOQUEABLE):
		return true  # Atacante normal, puede ser bloqueado

	# Atacante es Imbloqueable
	if blocker != null and has_keyword(blocker, Keyword.ALCANCE):
		return true  # Bloqueador con Alcance puede bloquearlo

	return false  # Imbloqueable y sin bloqueador con Alcance


func can_be_destroyed(card: Node) -> bool:
	"""DAR Sección 8: Verifica si una carta puede ser destruida"""
	return not has_keyword(card, Keyword.INDESTRUCTIBLE)


func silence_card(card: Node, source: Node = null, duration: String = "permanent") -> void:
	"""Silencia una carta: pierde todas sus keywords (vía remove_keyword, así
	respeta la misma limpieza por duración/salida de juego que cualquier otra
	remoción) y deja de disparar sus habilidades activadas/disparadas — eso lo
	filtra TriggerSystem._check_trigger_conditions() consultando is_silenced()."""
	if not is_instance_valid(card):
		return
	var card_id = card.get_instance_id()
	if not _silenced_cards.has(card_id):
		_silenced_cards[card_id] = []
	_silenced_cards[card_id].append({"source": source, "duration": duration})
	for keyword in Constants.Keyword.values():
		remove_keyword(card, keyword, source, duration)
	print("[KeywordManager] %s fue silenciada (fuente: %s)" % [
		_get_card_name(card), _get_card_name(source) if source else "efecto"
	])


func is_silenced(card: Node) -> bool:
	"""Verifica si una carta está silenciada (no debe disparar habilidades)."""
	if not is_instance_valid(card):
		return false
	var entries = _silenced_cards.get(card.get_instance_id(), [])
	return not entries.is_empty()


func can_be_exiled(card: Node) -> bool:
	"""DAR Sección 8: Verifica si una carta puede ser desterrada"""
	return not has_keyword(card, Keyword.INDESTERRABLE)


func has_first_strike(card: Node) -> bool:
	"""Verifica Golpe Primero para ordenamiento de daño"""
	return has_keyword(card, Keyword.GOLPE_PRIMERO)


func has_double_strike(card: Node) -> bool:
	"""Verifica Doble Golpe"""
	return has_keyword(card, Keyword.DOBLE_GOLPE)


func has_trample(card: Node) -> bool:
	"""Verifica Arrollar (daño excedente al Castillo)"""
	return has_keyword(card, Keyword.ARROLLAR)


func has_vigilance(card: Node) -> bool:
	"""Verifica Vigilancia (no va a Línea de Ataque)"""
	return has_keyword(card, Keyword.VIGILANCIA)


# =============================================================================
# MODIFICACIÓN TEMPORAL DE KEYWORDS
# =============================================================================
func grant_keyword(card: Node, keyword: int, source: Node = null, duration: String = "turn") -> void:
	"""Otorga un keyword temporalmente a una carta

	Args:
		card: Carta objetivo
		keyword: Keyword a otorgar
		source: Carta/efecto que otorga el keyword
		duration: "turn", "combat", "permanent"
	"""
	var card_id = card.get_instance_id()

	if not _temporary_keywords.has(card_id):
		_temporary_keywords[card_id] = {}

	if not _temporary_keywords[card_id].has(keyword):
		_temporary_keywords[card_id][keyword] = []

	_temporary_keywords[card_id][keyword].append({
		"source": source,
		"duration": duration
	})

	print("[KeywordManager] %s ganó %s (fuente: %s, duración: %s)" % [
		_get_card_name(card),
		Constants.Keyword.keys()[keyword],
		_get_card_name(source) if source else "efecto",
		duration
	])

	emit_signal("keyword_granted", card, keyword, source)


func remove_keyword(card: Node, keyword: int, source: Node = null, duration: String = "turn") -> void:
	"""Remueve temporalmente un keyword de una carta (Regla de Prioridad Negativa)"""
	var card_id = card.get_instance_id()

	if not _removed_keywords.has(card_id):
		_removed_keywords[card_id] = {}

	if not _removed_keywords[card_id].has(keyword):
		_removed_keywords[card_id][keyword] = []

	_removed_keywords[card_id][keyword].append({
		"source": source,
		"duration": duration
	})

	print("[KeywordManager] %s perdió %s (fuente: %s)" % [
		_get_card_name(card),
		Constants.Keyword.keys()[keyword],
		_get_card_name(source) if source else "efecto"
	])

	emit_signal("keyword_removed", card, keyword, source)


# =============================================================================
# LIMPIEZA
# =============================================================================
func _on_turn_ended(_player_id: int) -> void:
	"""Limpia keywords temporales al final del turno"""
	_cleanup_by_duration("turn")


func cleanup_combat_keywords() -> void:
	"""Limpia keywords que duran solo el combate"""
	_cleanup_by_duration("combat")


func _cleanup_by_duration(duration: String) -> void:
	"""Limpia keywords con duración específica"""
	# Limpiar temporales otorgados
	for card_id in _temporary_keywords.keys():
		var keywords_to_remove: Array = []
		for keyword in _temporary_keywords[card_id]:
			var sources = _temporary_keywords[card_id][keyword]
			sources = sources.filter(func(s): return s.duration != duration)
			if sources.is_empty():
				keywords_to_remove.append(keyword)
			else:
				_temporary_keywords[card_id][keyword] = sources

		for keyword in keywords_to_remove:
			_temporary_keywords[card_id].erase(keyword)

		if _temporary_keywords[card_id].is_empty():
			_temporary_keywords.erase(card_id)

	# Limpiar removidos temporales
	for card_id in _removed_keywords.keys():
		var keywords_to_restore: Array = []
		for keyword in _removed_keywords[card_id]:
			var sources = _removed_keywords[card_id][keyword]
			sources = sources.filter(func(s): return s.duration != duration)
			if sources.is_empty():
				keywords_to_restore.append(keyword)
			else:
				_removed_keywords[card_id][keyword] = sources

		for keyword in keywords_to_restore:
			_removed_keywords[card_id].erase(keyword)

		if _removed_keywords[card_id].is_empty():
			_removed_keywords.erase(card_id)

	# Limpiar silenciados con esta duración
	for card_id in _silenced_cards.keys():
		var entries = _silenced_cards[card_id]
		entries = entries.filter(func(e): return e.duration != duration)
		if entries.is_empty():
			_silenced_cards.erase(card_id)
		else:
			_silenced_cards[card_id] = entries


func clear_all_for_card(card: Node) -> void:
	"""Limpia todos los keywords temporales y cache de una carta (cuando sale del juego)"""
	var card_id = card.get_instance_id()
	_temporary_keywords.erase(card_id)
	_removed_keywords.erase(card_id)
	_silenced_cards.erase(card_id)
	_parsed_cache.erase(card_id)


# =============================================================================
# UTILIDADES
# =============================================================================
func get_keyword_name(keyword: int) -> String:
	"""Obtiene el nombre legible de un keyword"""
	return Constants.Keyword.keys()[keyword] if keyword in Constants.Keyword.values() else "UNKNOWN"


func get_keyword_description(keyword: int) -> String:
	"""Obtiene la descripción de un keyword"""
	return Constants.KEYWORD_DESCRIPTIONS.get(keyword, "Sin descripción")


func get_all_keywords(card: Node) -> Array:
	"""Obtiene todos los keywords activos de una carta"""
	var result: Array = []

	for keyword in Constants.Keyword.values():
		if has_keyword(card, keyword):
			result.append(keyword)

	return result


func _get_card_name(card) -> String:
	"""Helper para obtener nombre de carta"""
	if card == null:
		return "null"
	if card is Node and card.get("card_name") != null:
		return card.card_name
	return "Carta"
