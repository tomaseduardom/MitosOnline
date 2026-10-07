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
	"""Inicializa el mapeo de texto → Constants.Keyword.
	Solo keywords reales de Mitos y Leyendas (corrección 2026-08-20) —
	"Inmune a X"/"portar múltiples armas" son texto libre, no keywords."""
	KEYWORD_MAP = {
		"furia": Constants.Keyword.FURIA,
		"imbloqueable": Constants.Keyword.IMBLOQUEABLE,
		"indestructible": Constants.Keyword.INDESTRUCTIBLE,
		"indesterrable": Constants.Keyword.INDESTERRABLE,
		"única": Constants.Keyword.UNICA,
		"unica": Constants.Keyword.UNICA,
		"exhumar": Constants.Keyword.EXHUMAR,
		"errante": Constants.Keyword.ERRANTE,
		"retador": Constants.Keyword.RETADOR,
	}


func _init_keyword_patterns() -> void:
	"""Inicializa patrones de texto que indican keywords"""
	KEYWORD_PATTERNS = {
		Constants.Keyword.FURIA: ["puede atacar el turno que entra", "atacar inmediatamente"],
		Constants.Keyword.IMBLOQUEABLE: ["no puede ser bloqueado", "no puede ser bloquead"],
		Constants.Keyword.INDESTRUCTIBLE: ["no puede ser destruid", "no es destruid"],
		Constants.Keyword.INDESTERRABLE: ["no puede ser desterrad"],
		Constants.Keyword.ERRANTE: ["errante"],
		Constants.Keyword.RETADOR: ["retador"],
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

## Bloqueo de habilidad POR NOMBRE, no por instancia — DAR "nombra una
## carta para que pierda su habilidad" (2026-08-29, p.ej. Alicia en
## Wonderland: "en todas las Zonas mientras este Aliado esté en juego").
## A diferencia de _silenced_cards (una carta puntual ya en juego), esto
## afecta CUALQUIER copia del nombre, en cualquier zona, incluso una que
## todavía no exista como Node (una copia en el mazo que se robe después).
## {nombre_lower: [source_node, ...]} — no se limpia con un unregister
## explícito: is_name_locked() valida en cada consulta si el source sigue
## vivo y en juego (auto-expira solo cuando el que nombró sale de juego).
var _named_ability_locks: Dictionary = {}

## Bloqueo de habilidad de UNA carta puntual, mientras una fuente concreta
## siga en juego (2026-09-03, p.ej. Kuchiku Kan: "una carta pierda su
## habilidad... mientras este Aliado esté en juego") — análogo instance-
## based de _named_ability_locks (mismo criterio de auto-expiración
## perezosa), a diferencia de silence_card(..., "permanent") que es
## indefinido de verdad y no debe usarse aquí (rompería cartas como
## Convertir/_execute_targeted_silence, que SÍ son permanentes sin
## condición). {card_instance_id: [source_node, ...]}
var _instance_ability_locks: Dictionary = {}


## Cache de keywords parseados por carta {card_instance_id: Array}
var _parsed_cache: Dictionary = {}


## "Tus Aliados que porten Arma no pueden perder su habilidad" (2026-08-30,
## p.ej. Manuel Bulnes) — lista de fuentes activas de esta protección.
## Array[Node] — sin unregister explícito, se auto-limpia comparando
## is_instance_valid()/is_in_play() en cada consulta.
var _weapon_wielder_silence_immunity_sources: Array = []

## 'Tus Aliados... no pueden perder su habilidad' SIN calificador de Arma
## (2026-09-04, p.ej. Abu Simbel) — versión más amplia de
## _weapon_wielder_silence_immunity_sources, protege a TODOS los Aliados
## del controlador de la fuente, no solo a los que porten Arma.
var _all_allies_silence_immunity_sources: Array = []

## '...No puede perder su habilidad' EN SINGULAR referido a sí misma
## (2026-09-04, p.ej. lagrima del dragon: 'Oro Inicial. Indesterrable. No
## puede perder su habilidad.') — a diferencia de las dos listas de arriba
## (que protegen a TERCEROS mientras 'source' siga en juego), aquí 'source'
## se protege a SÍ MISMA.
var _self_silence_immunity_sources: Array = []

## 'Si está en tu Reserva, las cartas que controles no pueden perder su
## habilidad...' (2026-09-04, p.ej. Terminal P-12) — protege TODAS las
## cartas del controlador de 'source' (sin restringir a Aliados, a
## diferencia de _all_allies_silence_immunity_sources), pero SOLO mientras
## 'source' esté específicamente en Reserva de Oro (no en juego en general).
var _reserva_conditional_full_silence_immunity_sources: Array = []


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
			Keyword.UNICA:
				_set_card_flag(card, "is_unique", true)
			Keyword.EXHUMAR:
				_set_card_flag(card, "has_exhume", true)
			Keyword.ERRANTE:
				_set_card_flag(card, "is_errante", true)
			Keyword.RETADOR:
				_set_card_flag(card, "is_retador", true)


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
	2. Método card.has_keyword() si existe — ya incluye las keywords que
	   transmiten las Armas equipadas (ver Card.has_keyword(), 2026-08-24)
	3. Array de keywords en la carta
	4. Flags booleanos directos
	5. Parsing en tiempo real (fallback)
	"""
	var card_id = card.get_instance_id()

	# Método 1: Verificar cache (resultado de scan_and_apply_keywords) — solo
	# como atajo cuando SÍ encuentra el keyword. El cache son las keywords
	# propias de la carta, calculadas una vez al entrar en juego, y no se
	# actualiza si después se le equipa un Arma — un "no está en cache" aquí
	# NO es definitivo, hay que seguir a Método 2 (2026-08-26: Cañón Helios
	# daba Furia al portador, pero este corte impedía que TurnManager.
	# can_attack() lo viera nunca, porque nunca llegaba a Método 2, que sí
	# revisa las Armas equipadas).
	if _parsed_cache.has(card_id) and keyword in _parsed_cache[card_id]:
		return true

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
		Keyword.ERRANTE:
			if card.get("is_errante") == true:
				return true
			if card.get_meta("is_errante", false):
				return true
		Keyword.RETADOR:
			if card.get("is_retador") == true:
				return true
			if card.get_meta("is_retador", false):
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
	"""DAR Sección 8: Verifica si un atacante puede ser bloqueado.
	Imbloqueable: no puede ser bloqueado, sin excepción por keyword — en
	Mitos y Leyendas no existe una keyword general tipo 'Alcance'. Si algún
	Aliado puede bloquear Imbloqueables, lo dice su propio texto."""
	if not has_keyword(attacker, Keyword.IMBLOQUEABLE):
		return true  # Atacante normal, puede ser bloqueado

	# Atacante es Imbloqueable — solo lo bloquea algo cuyo propio texto lo permita
	if blocker != null and blocker.get("card_ability") != null:
		var blocker_text: String = blocker.card_ability.to_lower()
		if "bloquear" in blocker_text and "imbloqueable" in blocker_text:
			return true

	return false


func can_be_destroyed(card: Node) -> bool:
	"""DAR Sección 8: Verifica si una carta puede ser destruida"""
	return not has_keyword(card, Keyword.INDESTRUCTIBLE)


func register_weapon_wielder_silence_immunity(source: Node) -> void:
	"""'Tus Aliados que porten Arma no pueden perder su habilidad' (2026-08-30,
	p.ej. Manuel Bulnes) — mientras 'source' siga en juego, protege de
	silence_card() a los Aliados equipados con un Arma que controle el
	MISMO jugador que controla 'source' (no a los del rival)."""
	if not is_instance_valid(source):
		return
	if source not in _weapon_wielder_silence_immunity_sources:
		_weapon_wielder_silence_immunity_sources.append(source)


func _is_protected_from_silence_by_weapon(card: Node) -> bool:
	"""Consulta acumulativa de register_weapon_wielder_silence_immunity() —
	auto-limpia fuentes inválidas/fuera de juego en el camino."""
	if not is_instance_valid(card):
		return false
	var weapons = card.get("equipped_weapons")
	if not (weapons is Array) or weapons.is_empty():
		return false
	var card_controller: int = card.controller_id if card.get("controller_id") != null else -1
	var still_valid: Array = []
	var protected_by_weapon := false
	for source in _weapon_wielder_silence_immunity_sources:
		if not is_instance_valid(source) or not source.is_in_play():
			continue
		still_valid.append(source)
		var source_controller: int = source.controller_id if source.get("controller_id") != null else -2
		if source_controller == card_controller:
			protected_by_weapon = true
	_weapon_wielder_silence_immunity_sources = still_valid
	return protected_by_weapon


func register_all_allies_silence_immunity(source: Node) -> void:
	"""'Tus Aliados... no pueden perder su habilidad' SIN calificador de
	Arma (2026-09-04, p.ej. Abu Simbel) — mientras 'source' siga en juego,
	protege de silence_card() a TODOS los Aliados del MISMO controlador de
	'source' (a diferencia de register_weapon_wielder_silence_immunity(),
	que solo protege a los que porten Arma)."""
	if not is_instance_valid(source):
		return
	if source not in _all_allies_silence_immunity_sources:
		_all_allies_silence_immunity_sources.append(source)


func _is_protected_from_silence_by_all_allies_source(card: Node) -> bool:
	"""Consulta acumulativa de register_all_allies_silence_immunity() —
	auto-limpia fuentes inválidas/fuera de juego en el camino."""
	if not is_instance_valid(card) or card.get("card_type") != Constants.CardType.ALIADO:
		return false
	var card_controller: int = card.controller_id if card.get("controller_id") != null else -1
	var still_valid: Array = []
	var protected_generally := false
	for source in _all_allies_silence_immunity_sources:
		if not is_instance_valid(source) or not source.is_in_play():
			continue
		still_valid.append(source)
		var source_controller: int = source.controller_id if source.get("controller_id") != null else -2
		if source_controller == card_controller:
			protected_generally = true
	_all_allies_silence_immunity_sources = still_valid
	return protected_generally


## 'Tus Armas no pueden perder su habilidad' (2026-09-04, p.ej. skofnung) —
## mismo criterio que _all_allies_silence_immunity_sources, pero para Armas.
var _all_weapons_silence_immunity_sources: Array = []


func register_all_weapons_silence_immunity(source: Node) -> void:
	"""'Tus Armas... no pueden perder su habilidad' (2026-09-04, p.ej.
	skofnung) — mientras 'source' siga en juego, protege de silence_card()
	a TODAS las Armas del MISMO controlador de 'source'."""
	if not is_instance_valid(source):
		return
	if source not in _all_weapons_silence_immunity_sources:
		_all_weapons_silence_immunity_sources.append(source)


func _is_protected_from_silence_by_all_weapons_source(card: Node) -> bool:
	"""Consulta acumulativa de register_all_weapons_silence_immunity()."""
	if not is_instance_valid(card) or card.get("card_type") != Constants.CardType.ARMA:
		return false
	var card_controller: int = card.controller_id if card.get("controller_id") != null else -1
	var still_valid: Array = []
	var protected_generally := false
	for source in _all_weapons_silence_immunity_sources:
		if not is_instance_valid(source) or not source.is_in_play():
			continue
		still_valid.append(source)
		var source_controller: int = source.controller_id if source.get("controller_id") != null else -2
		if source_controller == card_controller:
			protected_generally = true
	_all_weapons_silence_immunity_sources = still_valid
	return protected_generally


func register_self_silence_immunity(source: Node) -> void:
	"""'No puede perder su habilidad' en singular, referido a la propia
	carta (2026-09-04, p.ej. lagrima del dragon)."""
	if not is_instance_valid(source):
		return
	if source not in _self_silence_immunity_sources:
		_self_silence_immunity_sources.append(source)


func _is_protected_from_silence_by_self(card: Node) -> bool:
	"""Consulta de register_self_silence_immunity() — auto-limpia fuentes
	inválidas/fuera de juego en el camino."""
	if not is_instance_valid(card):
		return false
	var still_valid: Array = []
	var protected_self := false
	for source in _self_silence_immunity_sources:
		if not is_instance_valid(source) or not source.is_in_play():
			continue
		still_valid.append(source)
		if source == card:
			protected_self = true
	_self_silence_immunity_sources = still_valid
	return protected_self


func register_reserva_conditional_full_silence_immunity(source: Node) -> void:
	"""'Si está en tu Reserva, las cartas que controles no pueden perder su
	habilidad...' (2026-09-04, p.ej. Terminal P-12) — protege TODAS las
	cartas del mismo controlador de 'source' (no solo Aliados), pero solo
	mientras 'source' esté en Constants.Zone.RESERVA_ORO específicamente."""
	if not is_instance_valid(source):
		return
	if source not in _reserva_conditional_full_silence_immunity_sources:
		_reserva_conditional_full_silence_immunity_sources.append(source)


func _is_protected_from_silence_by_reserva_source(card: Node) -> bool:
	"""Consulta de register_reserva_conditional_full_silence_immunity() —
	auto-limpia fuentes inválidas/fuera de la Reserva en el camino."""
	if not is_instance_valid(card):
		return false
	var card_controller: int = card.controller_id if card.get("controller_id") != null else -1
	var still_valid: Array = []
	var protected_generally := false
	for source in _reserva_conditional_full_silence_immunity_sources:
		if not is_instance_valid(source) or source.get("current_zone") != Constants.Zone.RESERVA_ORO:
			continue
		still_valid.append(source)
		var source_controller: int = source.controller_id if source.get("controller_id") != null else -2
		if source_controller == card_controller:
			protected_generally = true
	_reserva_conditional_full_silence_immunity_sources = still_valid
	return protected_generally


func silence_card(card: Node, source: Node = null, duration: String = "permanent") -> void:
	"""Silencia una carta: pierde todas sus keywords (vía remove_keyword, así
	respeta la misma limpieza por duración/salida de juego que cualquier otra
	remoción) y deja de disparar sus habilidades activadas/disparadas — eso lo
	filtra TriggerSystem._check_trigger_conditions() consultando is_silenced().
	Respeta la protección de 'Aliados que porten Arma no pueden perder su
	habilidad' (2026-08-30, Manuel Bulnes), 'Tus Aliados... no pueden perder
	su habilidad' sin calificador (2026-09-04, Abu Simbel) y la de 'prevenir
	que una carta sea afectada por un efecto oponente' (2026-08-30, Estaca)
	— si cualquiera aplica, no hace nada."""
	if not is_instance_valid(card):
		return
	if _is_protected_from_silence_by_weapon(card):
		print("[KeywordManager] %s no pierde su habilidad — protegido por porta Arma" % _get_card_name(card))
		return
	if _is_protected_from_silence_by_all_allies_source(card):
		print("[KeywordManager] %s no pierde su habilidad — protección de Aliados" % _get_card_name(card))
		return
	if _is_protected_from_silence_by_all_weapons_source(card):
		print("[KeywordManager] %s no pierde su habilidad — protección de Armas" % _get_card_name(card))
		return
	if _is_protected_from_silence_by_self(card):
		print("[KeywordManager] %s no pierde su habilidad — protección propia" % _get_card_name(card))
		return
	if _is_protected_from_silence_by_reserva_source(card):
		print("[KeywordManager] %s no pierde su habilidad — protección de Terminal P-12 en Reserva" % _get_card_name(card))
		return
	# Prevención reactiva real (2026-09-09 — Estaca, tag "silence"): los
	# ~20 llamadores de silence_card() ya se actualizaron con 'await' para
	# soportar esto (a pedido del usuario).
	if await EffectController.offer_prevention(card, source, "silence"):
		return
	var card_id = card.get_instance_id()
	if not _silenced_cards.has(card_id):
		_silenced_cards[card_id] = []
	_silenced_cards[card_id].append({"source": source, "duration": duration})
	# Solo los keywords que la carta REALMENTE tiene (2026-09-04, bug
	# reportado: silenciar un Oro base imprimía 'perdió FURIA'/'perdió
	# INDESTRUCTIBLE'/etc. para los ~8 keywords del juego enteros, sin
	# importar si la carta los tenía o no — puro ruido de debug engañoso,
	# no afectaba is_silenced() en sí (que solo mira si hay ENTRADA en
	# _silenced_cards, no cuántos keywords se sacaron).
	for keyword in Constants.Keyword.values():
		if has_keyword(card, keyword):
			remove_keyword(card, keyword, source, duration)
	print("[KeywordManager] %s fue silenciada (fuente: %s)" % [
		_get_card_name(card), _get_card_name(source) if source else "efecto"
	])
	if card.has_method("_refresh_disabled_rotation"):
		card._refresh_disabled_rotation()


## 'Los Oros oponentes pierden su habilidad' (2026-09-06, p.ej. Daikaiju
## Furioso) — a diferencia de _silenced_cards (silencio puntual ya
## resuelto), esto es una condición CONTINUA: cualquier Oro rival del
## controlador de 'source', presente o futuro, mientras 'source' siga en
## juego (mismo criterio de auto-limpieza perezosa que _named_ability_locks).
var _opponent_type_silence_sources: Array = []

func register_opponent_type_silence(source: Node, card_type: int) -> void:
	if not is_instance_valid(source):
		return
	_opponent_type_silence_sources.append({"source": source, "card_type": card_type})


func _is_silenced_by_opponent_type_source(card: Node) -> bool:
	if not is_instance_valid(card):
		return false
	var card_type: int = card.get("card_type") if card.get("card_type") != null else -1
	var card_controller: int = card.controller_id if card.get("controller_id") != null else -1
	var still_valid: Array = []
	var silenced := false
	for entry in _opponent_type_silence_sources:
		var source = entry.get("source")
		if not is_instance_valid(source) or not _is_card_in_play_generic(source):
			continue
		still_valid.append(entry)
		if entry.get("card_type") != card_type:
			continue
		var source_controller: int = source.controller_id if source.get("controller_id") != null else -2
		if source_controller != card_controller:
			silenced = true
	_opponent_type_silence_sources = still_valid
	return silenced


func _is_card_in_play_generic(card: Node) -> bool:
	var zone = card.get("current_zone")
	return zone != null and zone in Constants.ZONES_IN_PLAY


## 'los Aliados que estén o entren en juego... si tienen Fuerza 0 no pueden
## disparar sus habilidades' (Tercer Sello, 2026-09-20) — a diferencia de
## _opponent_type_silence_sources (ligado a que 'source' siga en juego), un
## Talismán como Tercer Sello resuelve y se va al Cementerio de inmediato,
## así que este efecto no puede depender de una fuente viva: se apaga solo
## por CONTEO DE TURNOS, igual que el modificador de Fuerza -3 que lo
## acompaña (ver SearchOwnZonePatterns.try_execute_tercer_sello_pattern(),
## mismo valor de 2 pasado a ambos para que se apaguen juntos). GLOBAL
## (ambos jugadores) y sin registrar cartas puntuales — se evalúa la Fuerza
## efectiva de cada carta en el momento de la consulta, vía
## ContinuousEffectManager.get_modified_strength().
var _zero_strength_ability_lock_turns_remaining: int = 0


func register_zero_strength_ability_lock(turns: int) -> void:
	_zero_strength_ability_lock_turns_remaining = max(_zero_strength_ability_lock_turns_remaining, turns)


func _is_silenced_by_zero_strength_lock(card: Node) -> bool:
	if _zero_strength_ability_lock_turns_remaining <= 0:
		return false
	if not is_instance_valid(card) or card.get("card_type") != Constants.CardType.ALIADO:
		return false
	if not _is_card_in_play_generic(card):
		return false
	return ContinuousEffectManager.get_modified_strength(card) <= 0


func is_silenced(card: Node) -> bool:
	"""Verifica si una carta está silenciada (no debe disparar habilidades).
	Incluye el silencio por instancia (_silenced_cards) Y el bloqueo por
	nombre (_named_ability_locks, 2026-08-29) — ambos comparten el mismo
	indicador visual (giro 180°, ver Card._refresh_disabled_rotation()) y el
	mismo choke point real (TriggerSystem._check_trigger_conditions())."""
	if not is_instance_valid(card):
		return false
	var entries = _silenced_cards.get(card.get_instance_id(), [])
	if not entries.is_empty():
		return true
	if is_instance_locked(card):
		return true
	if _is_silenced_by_opponent_type_source(card):
		return true
	if _is_silenced_by_zero_strength_lock(card):
		return true
	var card_name: String = str(card.get("card_name")) if card.get("card_name") != null else ""
	if card_name.is_empty():
		return false
	return is_name_locked(card_name)


func lock_ability_by_name(card_name: String, source: Node) -> void:
	"""Registra que TODAS las copias de 'card_name' (en cualquier zona,
	presentes o futuras) pierden su habilidad mientras 'source' siga vivo y
	en juego — DAR 'nombra una carta para que pierda su habilidad' (2026-08-29,
	p.ej. Alicia en Wonderland). No hace falta un unregister explícito:
	is_name_locked() descarta solo las fuentes que ya no son válidas."""
	if card_name.is_empty() or not is_instance_valid(source):
		return
	var key := card_name.to_lower()
	if not _named_ability_locks.has(key):
		_named_ability_locks[key] = []
	_named_ability_locks[key].append(source)
	print("[KeywordManager] '%s' pierde su habilidad en todas las Zonas (fuente: %s)" % [
		card_name, _get_card_name(source)
	])


func is_name_locked(card_name: String) -> bool:
	"""Verifica si el nombre de carta dado está bloqueado por algún
	lock_ability_by_name() todavía vigente — descarta en el camino las
	fuentes inválidas o que ya salieron de juego (auto-limpieza perezosa,
	sin necesidad de un hook explícito de 'on_left_play' de la fuente)."""
	var key := card_name.to_lower()
	if not _named_ability_locks.has(key):
		return false
	var sources: Array = _named_ability_locks[key]
	var still_valid: Array = []
	var any_active := false
	for source in sources:
		if not is_instance_valid(source):
			continue
		var zone = source.get("current_zone")
		if zone != null and zone not in Constants.ZONES_IN_PLAY:
			continue
		still_valid.append(source)
		any_active = true
	if still_valid.size() != sources.size():
		if still_valid.is_empty():
			_named_ability_locks.erase(key)
		else:
			_named_ability_locks[key] = still_valid
	return any_active


func lock_ability_by_instance(card: Node, source: Node) -> void:
	"""Registra que ESTA carta puntual (no todas las copias del nombre,
	ver lock_ability_by_name) pierde su habilidad mientras 'source' siga
	vivo y en juego (2026-09-03, DAR 'pierda su habilidad... mientras
	[esta carta] esté en juego', p.ej. Kuchiku Kan). Sin unregister
	explícito: is_instance_locked() descarta solo las fuentes que ya no
	son válidas, mismo criterio que is_name_locked()."""
	if not is_instance_valid(card) or not is_instance_valid(source):
		return
	var key := card.get_instance_id()
	if not _instance_ability_locks.has(key):
		_instance_ability_locks[key] = []
	_instance_ability_locks[key].append(source)
	print("[KeywordManager] %s pierde su habilidad (fuente: %s, mientras esté en juego)" % [
		_get_card_name(card), _get_card_name(source)
	])


func is_instance_locked(card: Node) -> bool:
	"""Verifica si esta carta puntual está bloqueada por algún
	lock_ability_by_instance() todavía vigente — descarta en el camino las
	fuentes inválidas o que ya salieron de juego (auto-limpieza perezosa)."""
	if not is_instance_valid(card):
		return false
	var key := card.get_instance_id()
	if not _instance_ability_locks.has(key):
		return false
	var sources: Array = _instance_ability_locks[key]
	var still_valid: Array = []
	var any_active := false
	for source in sources:
		if not is_instance_valid(source):
			continue
		var zone = source.get("current_zone")
		if zone != null and zone not in Constants.ZONES_IN_PLAY:
			continue
		still_valid.append(source)
		any_active = true
	if still_valid.size() != sources.size():
		if still_valid.is_empty():
			_instance_ability_locks.erase(key)
		else:
			_instance_ability_locks[key] = still_valid
	return any_active


func can_be_exiled(card: Node) -> bool:
	"""DAR Sección 8: Verifica si una carta puede ser desterrada"""
	return not has_keyword(card, Keyword.INDESTERRABLE)


func is_errante(card: Node) -> bool:
	"""Verifica Errante (solo 1 copia de esta carta en juego a la vez)"""
	return has_keyword(card, Keyword.ERRANTE)


func is_retador(card: Node) -> bool:
	"""Verifica Retador (el atacante elige qué Aliado enemigo debe bloquearlo)"""
	return has_keyword(card, Keyword.RETADOR)


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
	# Tercer Sello (2026-09-20) — mismo criterio de conteo que el modificador
	# de Fuerza -3 hermano (ContinuousEffectManager, duration=TIMED): se
	# descuenta en CADA fin de turno de cualquier jugador, no solo el propio.
	if _zero_strength_ability_lock_turns_remaining > 0:
		_zero_strength_ability_lock_turns_remaining -= 1


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
			# Ya no está silenciada — restaurar el giro visual si tampoco
			# está convertida (2026-08-26, ver Card._refresh_disabled_rotation).
			var card_node = instance_from_id(card_id)
			if card_node and is_instance_valid(card_node) and card_node.has_method("_refresh_disabled_rotation"):
				card_node._refresh_disabled_rotation()
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
	# is_instance_valid() PRIMERO (2026-09-19, misma familia de bug que
	# ContinuousEffectManager._get_card_id()/_get_card_name()/_resolve_
	# targets() y ContinuousVisualSync.update_all_card_visuals() — 'is Node'
	# bare sobre una referencia ya liberada revienta con "Left operand of
	# 'is' is a previously freed instance").
	if is_instance_valid(card) and card is Node and card.get("card_name") != null:
		return card.card_name
	return "Carta"
