extends Node
## ContinuousEffectManager - Gestiona efectos continuos y modificadores (Sección 7.2)
## Registra modificadores de cartas en juego y recalcula valores dinámicamente

# =============================================================================
# SEÑALES
# =============================================================================
signal modifier_registered(modifier: Dictionary)
signal modifier_removed(modifier_id: String)
signal card_stats_changed(card: Node, stat: String, old_value: int, new_value: int)
signal recalculation_completed(affected_cards: Array)

## Señales para actualización visual de UI
signal strength_bonus_gained(card: Node, bonus: int, total_strength: int, source_name: String)
signal strength_bonus_lost(card: Node, bonus: int, total_strength: int, source_name: String)
signal cost_modified(card: Node, old_cost: int, new_cost: int)
signal card_visual_update_required(card: Node, stat: String, base_value: int, modified_value: int)

# =============================================================================
# ENUMS
# =============================================================================
enum ModifierType {
	STRENGTH,       # Modifica fuerza
	COST,           # Modifica coste
	DAMAGE,         # Modifica daño infligido
	KEYWORDS,       # Agrega/quita keywords
	ABILITIES,      # Agrega/quita habilidades
	PROTECTION,     # Protección contra efectos
	RESTRICTION,    # Restricciones (no puede atacar, etc.)
	ZONE_CHANGE,    # Modifica comportamiento de cambio de zona
	CUSTOM          # Efectos personalizados
}

enum ModifierDuration {
	PERMANENT,      # Mientras la fuente esté en juego
	UNTIL_END_TURN, # Hasta fin del turno
	UNTIL_LEAVES,   # Hasta que el objetivo salga del juego
	TIMED,          # Por X turnos
	CONDITIONAL     # Mientras se cumpla una condición
}

enum ModifierLayer {
	# Capas de aplicación (orden importa)
	LAYER_0_BASE,           # Valores base impresos
	LAYER_1_COPY,           # Efectos de copia
	LAYER_2_CONTROL,        # Cambios de control
	LAYER_3_TEXT,           # Cambios de texto/habilidades
	LAYER_4_TYPE,           # Cambios de tipo
	LAYER_5_COLOR,          # Cambios de color/raza
	LAYER_6_ABILITIES,      # Agregar/quitar habilidades
	LAYER_7A_CHAR_SETTING,  # Establecer fuerza/coste a valor específico
	LAYER_7B_CHAR_MODIFY,   # Modificar fuerza/coste (+X/-X)
	LAYER_7C_COUNTERS,      # Contadores
	LAYER_8_COMBAT          # Modificadores de combate
}

# =============================================================================
# ESTADO
# =============================================================================
## Todos los modificadores activos: {modifier_id: modifier_data}
var _modifiers: Dictionary = {}

## Índice por carta afectada: {card_id: [modifier_ids]}
var _modifiers_by_target: Dictionary = {}

## Índice por carta fuente: {source_id: [modifier_ids]}
var _modifiers_by_source: Dictionary = {}

## Índice por tipo: {ModifierType: [modifier_ids]}
var _modifiers_by_type: Dictionary = {}

## Cache de valores calculados: {card_id: {stat: value}}
var _calculated_cache: Dictionary = {}

## Valores anteriores para detectar cambios: {card_id: {stat: value}}
var _previous_values: Dictionary = {}

## Flag para invalidar cache
var _cache_dirty: bool = false

## Contador para IDs únicos
var _modifier_counter: int = 0

## Regla de Prioridad Negativa (Sección 7.4)
## Las restricciones y efectos negativos tienen prioridad absoluta
const NEGATIVE_PRIORITY_ENABLED: bool = true

# =============================================================================
# REFERENCIAS
# =============================================================================
var _game_board: Node = null

## Módulos extraídos (Fase 4 de reestructuración)
var _keyword_query: KeywordQuery
var _visual_sync: ContinuousVisualSync


func _ready() -> void:
	_keyword_query = KeywordQuery.new()
	_keyword_query.setup(self)
	_visual_sync = ContinuousVisualSync.new()
	_visual_sync.setup(self)

	# Inicializar índices por tipo
	for type in ModifierType.values():
		_modifiers_by_type[type] = []

	call_deferred("_get_references")
	call_deferred("_connect_signals")
	print("[ContinuousEffectManager] Inicializado")


func _get_references() -> void:
	# _game_board queda siempre null: apuntaba a /root/Main/GameBoard, que es
	# un Control plano sin script (ver Main.tscn) — no un GameBoard.gd real
	# (ese archivo era huérfano y se eliminó). Sirve solo como fallback
	# inerte para recalculate_all()/update_all_card_visuals(), que hoy no
	# los llama nadie.
	pass


func _connect_signals() -> void:
	# Conectar a GameManager (el único conductor de turnos, ver consolidación
	# 2026-08-19) para limpiar modificadores temporales al final de cada turno.
	if GameManager and GameManager.has_signal("turn_ended"):
		GameManager.turn_ended.connect(_on_turn_ended)

	# Conectar a EffectController para detectar cartas que entran/salen del
	# juego. Antes intentaba conectarse a señales 'card_entered_zone'/
	# 'card_left_zone' de un GameBoard que nunca existió con esas señales
	# — _on_card_entered_zone()/_on_card_left_zone() nunca se llamaban, así
	# que ningún efecto continuo se registraba/limpiaba automáticamente al
	# entrar o salir de juego. EffectController sí emite estos eventos de
	# verdad (on_card_entered_play/on_card_left_play).
	EffectController.on_card_entered_play.connect(_on_effect_controller_card_entered)
	EffectController.on_card_left_play.connect(_on_effect_controller_card_left)


func _on_effect_controller_card_entered(_player_id: int, card: Node, zone: int) -> void:
	_on_card_entered_zone(card, zone, _player_id)


func _on_effect_controller_card_left(_player_id: int, card: Node, from_zone: int) -> void:
	_on_card_left_zone(card, from_zone, _player_id)


# =============================================================================
# REGISTRO DE MODIFICADORES
# =============================================================================
func register_modifier(params: Dictionary) -> String:
	"""Registra un nuevo modificador continuo

	Args:
		params: {
			source: Node,           # Carta que genera el efecto
			target: Node/Array,     # Carta(s) afectada(s) o "ALL"/"ALLIES"/"ENEMIES"
			type: ModifierType,     # Tipo de modificador
			stat: String,           # Stat afectado ("strength", "cost", etc.)
			value: int/Callable,    # Valor fijo o función para calcular
			operation: String,      # "add", "subtract", "set", "multiply"
			duration: ModifierDuration,
			duration_value: int,    # Turnos para TIMED
			condition: Callable,    # Función que retorna bool para CONDITIONAL
			layer: ModifierLayer,   # Capa de aplicación
			priority: int,          # Prioridad dentro de la capa (timestamp)
			filter: Dictionary,     # Filtro para targets dinámicos
			keywords_add: Array,    # Keywords a agregar
			keywords_remove: Array, # Keywords a quitar
			description: String     # Descripción del efecto
		}

	Returns: modifier_id único
	"""
	_modifier_counter += 1
	var modifier_id = "mod_%d_%d" % [Time.get_ticks_msec(), _modifier_counter]

	var source = params.get("source")
	var source_id = _get_card_id(source) if source else "system"

	var modifier = {
		"id": modifier_id,
		"source": source,
		"source_id": source_id,
		"target": params.get("target"),
		"type": params.get("type", ModifierType.STRENGTH),
		"stat": params.get("stat", "strength"),
		"value": params.get("value", 0),
		"operation": params.get("operation", "add"),
		"duration": params.get("duration", ModifierDuration.PERMANENT),
		"duration_value": params.get("duration_value", 0),
		"turns_remaining": params.get("duration_value", 0),
		"condition": params.get("condition", Callable()),
		"layer": params.get("layer", ModifierLayer.LAYER_7B_CHAR_MODIFY),
		"priority": params.get("priority", Time.get_ticks_msec()),
		"filter": params.get("filter", {}),
		"keywords_add": params.get("keywords_add", []),
		"keywords_remove": params.get("keywords_remove", []),
		"protection_type": params.get("protection_type", "ALL"),
		"restriction_type": params.get("restriction_type", ""),
		"description": params.get("description", ""),
		"registered_at": Time.get_unix_time_from_system(),
		"is_active": true
	}

	# Almacenar modificador
	_modifiers[modifier_id] = modifier

	# Indexar por fuente
	if not _modifiers_by_source.has(source_id):
		_modifiers_by_source[source_id] = []
	_modifiers_by_source[source_id].append(modifier_id)

	# Indexar por tipo
	var mod_type = modifier.type
	_modifiers_by_type[mod_type].append(modifier_id)

	# Indexar por target(s)
	var targets = _resolve_targets(modifier)
	for target in targets:
		var target_id = _get_card_id(target)
		if not _modifiers_by_target.has(target_id):
			_modifiers_by_target[target_id] = []
		_modifiers_by_target[target_id].append(modifier_id)

	# Invalidar cache
	_invalidate_cache()

	emit_signal("modifier_registered", modifier)
	print("[ContinuousEffectManager] Modificador registrado: %s (%s)" % [modifier_id, modifier.description])

	# Recalcular y actualizar visuales de las cartas afectadas. Con target
	# dinámico (ALL/ALLIES/ENEMIES/OTHER, un String) _resolve_targets()
	# devuelve vacío a propósito — se resuelve carta por carta en
	# _get_applicable_modifiers(), no acá — así que sin esto el badge de
	# Fuerza de los Aliados YA en juego nunca se refrescaba al entrar un
	# aura nueva (2026-08-25, confirmado con Patria Vieja: el bonus se
	# calculaba bien pero no se veía hasta que algo más recalculaba esa
	# carta puntual).
	var visual_targets: Array = targets
	if targets.is_empty() and modifier.target is String:
		visual_targets = _get_all_cards_in_play()
	_visual_sync.call_deferred("update_affected_cards_visuals", visual_targets, modifier.stat)

	return modifier_id


func unregister_modifier(modifier_id: String) -> bool:
	"""Remueve un modificador

	Returns: true si se removió exitosamente
	"""
	if not _modifiers.has(modifier_id):
		return false

	var modifier = _modifiers[modifier_id]
	var stat = modifier.get("stat", "strength")

	# Remover de índice por fuente
	var source_id = modifier.source_id
	if _modifiers_by_source.has(source_id):
		_modifiers_by_source[source_id].erase(modifier_id)

	# Remover de índice por tipo
	var mod_type = modifier.type
	_modifiers_by_type[mod_type].erase(modifier_id)

	# Remover de índice por targets y guardar para actualizar visuals
	var targets = _resolve_targets(modifier)
	for target in targets:
		var target_id = _get_card_id(target)
		if _modifiers_by_target.has(target_id):
			_modifiers_by_target[target_id].erase(modifier_id)

	# Remover modificador
	_modifiers.erase(modifier_id)

	# Invalidar cache
	_invalidate_cache()

	emit_signal("modifier_removed", modifier_id)
	print("[ContinuousEffectManager] Modificador removido: %s" % modifier_id)

	# Recalcular y actualizar visuales de las cartas afectadas — mismo
	# motivo que en register_modifier() para target dinámico (String).
	var visual_targets: Array = targets
	if targets.is_empty() and modifier.target is String:
		visual_targets = _get_all_cards_in_play()
	_visual_sync.call_deferred("update_affected_cards_visuals", visual_targets, stat)

	return true


func remove_modifiers_from_source(source: Node) -> int:
	"""Remueve todos los modificadores de una fuente

	Usado cuando una carta sale del juego.

	Returns: Número de modificadores removidos
	"""
	var source_id = _get_card_id(source)
	if not _modifiers_by_source.has(source_id):
		return 0

	var modifier_ids = _modifiers_by_source[source_id].duplicate()
	var count = 0

	for mod_id in modifier_ids:
		if unregister_modifier(mod_id):
			count += 1

	print("[ContinuousEffectManager] Removidos %d modificadores de %s" % [count, source_id])
	return count


# =============================================================================
# CÁLCULO DE VALORES MODIFICADOS (Sección 8 - Fuerza)
# =============================================================================
func get_modified_strength(card: Node) -> int:
	"""Obtiene la fuerza modificada de una carta

	Aplica todos los modificadores activos en orden de capas.

	Args:
		card: Nodo de la carta

	Returns: Fuerza final después de todos los modificadores
	"""
	return _get_modified_stat(card, "strength")


func get_modified_cost(card: Node) -> int:
	"""Obtiene el coste modificado de una carta

	Args:
		card: Nodo de la carta

	Returns: Coste final después de todos los modificadores
	"""
	return _get_modified_stat(card, "cost")


func get_modified_damage(card: Node) -> int:
	"""Obtiene el daño modificado que inflige una carta

	Args:
		card: Nodo de la carta

	Returns: Daño final después de todos los modificadores
	"""
	return _get_modified_stat(card, "damage")


func _get_modified_stat(card: Node, stat: String) -> int:
	"""Función interna para calcular cualquier stat modificado

	Proceso:
	1. Obtener valor base impreso
	2. Recolectar todos los modificadores aplicables
	3. Ordenar por capa y prioridad (negativos al final - Sección 7.4)
	4. Aplicar en orden
	5. Emitir señales para actualización visual
	6. Retornar valor final

	Args:
		card: Nodo de la carta
		stat: Nombre del stat ("strength", "cost", "damage")

	Returns: Valor final calculado
	"""
	var card_id = _get_card_id(card)

	# Verificar cache
	if not _cache_dirty and _calculated_cache.has(card_id):
		if _calculated_cache[card_id].has(stat):
			return _calculated_cache[card_id][stat]

	# Obtener valor previo (para detectar cambios)
	var previous_value = -999
	if _previous_values.has(card_id) and _previous_values[card_id].has(stat):
		previous_value = _previous_values[card_id][stat]

	# Obtener valor base
	var base_value = _get_base_stat(card, stat)
	var current_value = base_value

	# Recolectar modificadores aplicables
	var applicable_mods = _get_applicable_modifiers(card, stat)

	# Ordenar por capa y prioridad (Sección 7.4: negativos al final)
	applicable_mods.sort_custom(_compare_modifiers)

	# Tracking de bonos para señales visuales
	var total_bonus = 0
	var last_source_name = ""

	# Aplicar modificadores en orden
	for mod in applicable_mods:
		# Verificar si el modificador está activo
		if not _is_modifier_active(mod):
			continue

		# Calcular valor del modificador
		var mod_value = _calculate_modifier_value(mod, card, current_value)

		# Aplicar según operación
		var old_value = current_value
		current_value = _apply_operation(current_value, mod_value, mod.operation)

		# Tracking para señales
		if mod_value != 0:
			total_bonus += (current_value - old_value)
			last_source_name = mod.description

		# Debug
		if mod_value != 0:
			print("[ContinuousEffectManager] %s: %s %d → %d (%s)" % [
				stat, _get_card_name(card), old_value, current_value, mod.description
			])

	# El valor mínimo de fuerza/coste es 0
	current_value = max(0, current_value)

	# Guardar en cache
	if not _calculated_cache.has(card_id):
		_calculated_cache[card_id] = {}
	_calculated_cache[card_id][stat] = current_value

	# Guardar valor previo para próxima comparación
	if not _previous_values.has(card_id):
		_previous_values[card_id] = {}
	_previous_values[card_id][stat] = current_value

	# =========================================================================
	# ACTUALIZACIÓN VISUAL - Emitir señales si el valor cambió
	# =========================================================================
	if previous_value != -999 and previous_value != current_value:
		# Emitir señal genérica de cambio
		emit_signal("card_stats_changed", card, stat, previous_value, current_value)
		emit_signal("card_visual_update_required", card, stat, base_value, current_value)

		# Señales específicas para fuerza
		if stat == "strength":
			var bonus_diff = current_value - previous_value
			if bonus_diff > 0:
				emit_signal("strength_bonus_gained", card, bonus_diff, current_value, last_source_name)
				_visual_sync.notify_card_visual_update(card, "strength", base_value, current_value, bonus_diff)
			elif bonus_diff < 0:
				emit_signal("strength_bonus_lost", card, abs(bonus_diff), current_value, last_source_name)
				_visual_sync.notify_card_visual_update(card, "strength", base_value, current_value, bonus_diff)

		# Señales específicas para coste
		elif stat == "cost":
			emit_signal("cost_modified", card, previous_value, current_value)
			_visual_sync.notify_card_visual_update(card, "cost", base_value, current_value, current_value - previous_value)

	return current_value


func _get_base_stat(card: Node, stat: String) -> int:
	"""Obtiene el valor base impreso de un stat"""
	if card == null:
		return 0

	match stat:
		"strength":
			if card.get("printed_strength") != null:
				return card.printed_strength
			if card.get("card_strength") != null:
				return card.card_strength
			if card.get("fuerza") != null:
				return card.fuerza
			return 0

		"cost":
			if card.get("printed_cost") != null:
				return card.printed_cost
			if card.get("card_cost") != null:
				return card.card_cost
			if card.get("coste") != null:
				return card.coste
			return 0

		"damage":
			# Daño base = fuerza por defecto
			return _get_base_stat(card, "strength")

		_:
			if card.get(stat) != null:
				return card.get(stat)
			return 0


func _get_applicable_modifiers(card: Node, stat: String) -> Array:
	"""Obtiene todos los modificadores que aplican a una carta y stat"""
	var card_id = _get_card_id(card)
	var applicable: Array = []

	# Modificadores directos a esta carta
	if _modifiers_by_target.has(card_id):
		for mod_id in _modifiers_by_target[card_id]:
			if _modifiers.has(mod_id):
				var mod = _modifiers[mod_id]
				if mod.stat == stat or stat == "":
					applicable.append(mod)

	# Modificadores globales (target = "ALL", "ALLIES", "ENEMIES")
	for mod_id in _modifiers:
		var mod = _modifiers[mod_id]
		if mod.stat != stat and stat != "":
			continue

		var target = mod.target
		if target is String:
			if _card_matches_global_target(card, target, mod):
				if mod not in applicable:
					applicable.append(mod)

	return applicable


func _card_matches_global_target(card: Node, target_type: String, modifier: Dictionary) -> bool:
	"""Verifica si una carta coincide con un target global"""
	var source = modifier.source
	var filter = modifier.filter

	match target_type.to_upper():
		"ALL":
			return _card_matches_filter(card, filter)

		"ALLIES", "ALIADOS":
			# Mismo controlador que la fuente (2026-08-24): antes esto comparaba
			# mitologia/faccion, no dueno real -- "Tus Aliados" en el texto real
			# de las cartas significa "los que tu controlas", sin importar su
			# mitologia; con la comparacion vieja, un aura como la de Patria Vieja
			# habria afectado a Aliados rivales de la misma mitologia y ninguno de
			# los propios de otra.
			# EN JUEGO (2026-09-02, bug reportado por el usuario: Sable de
			# Napoleón le daba Fuerza a Aliados en la MANO) — "Tus Aliados"
			# significa los que controlás EN JUEGO, nunca los de la mano/
			# Castillo/Cementerio. _is_card_in_play() ya existía (usado solo
			# para registrar/desregistrar la fuente al entrar/salir de juego
			# ella misma) pero nunca se consultaba acá, del lado del OBJETIVO.
			if source and card and _is_card_in_play(card):
				if _get_card_owner(source) == _get_card_owner(card):
					return _card_matches_filter(card, filter)
			return false

		"ENEMIES", "ENEMIGOS":
			# Distinto controlador que la fuente (mismo motivo que ALLIES),
			# y mismo chequeo de "en juego" agregado arriba.
			if source and card and _is_card_in_play(card):
				if _get_card_owner(source) != _get_card_owner(card):
					return _card_matches_filter(card, filter)
			return false

		"SELF", "ESTA":
			return card == source

		"OTHER", "OTROS":
			return card != source and _card_matches_filter(card, filter)

		_:
			return false


func _card_matches_filter(card: Node, filter: Dictionary) -> bool:
	"""Verifica si una carta cumple con un filtro"""
	if filter.is_empty():
		return true

	# Filtro por tipo
	if filter.has("type"):
		var card_type = _get_card_type(card)
		if card_type != filter.type:
			return false

	# Filtro por coste
	if filter.has("max_cost"):
		var card_cost = _get_base_stat(card, "cost")
		if card_cost > filter.max_cost:
			return false

	if filter.has("min_cost"):
		var card_cost = _get_base_stat(card, "cost")
		if card_cost < filter.min_cost:
			return false

	# Filtro por fuerza
	if filter.has("max_strength"):
		var card_str = _get_base_stat(card, "strength")
		if card_str > filter.max_strength:
			return false

	# Filtro por zona
	if filter.has("zone"):
		var card_zone = _get_card_zone(card)
		if card_zone != filter.zone:
			return false

	# Filtro por keyword
	if filter.has("has_keyword"):
		if not _card_has_keyword(card, filter.has_keyword):
			return false

	# Filtro por nombre
	if filter.has("name_contains"):
		var card_name = _get_card_name(card).to_lower()
		if not filter.name_contains.to_lower() in card_name:
			return false

	return true


func _compare_modifiers(a: Dictionary, b: Dictionary) -> bool:
	"""Compara dos modificadores para ordenamiento (Sección 7.4)

	Orden de prioridad:
	1. Regla de Prioridad Negativa: Restricciones y efectos negativos SIEMPRE se aplican al final
	   (para que tengan prioridad absoluta sobre buffs)
	2. Capa (ascendente)
	3. Prioridad/Timestamp (ascendente)

	La Sección 7.4 establece que si existen modificadores contradictorios,
	las restricciones (efectos negativos) tienen prioridad absoluta.
	Esto se logra aplicándolos AL FINAL de la cadena.
	"""
	if NEGATIVE_PRIORITY_ENABLED:
		var a_is_negative = _is_negative_modifier(a)
		var b_is_negative = _is_negative_modifier(b)

		# Los negativos van al final (se aplican después, tienen última palabra)
		if a_is_negative != b_is_negative:
			return not a_is_negative  # a va primero si NO es negativo

	# Mismo tipo (ambos positivos o ambos negativos): ordenar por capa
	if a.layer != b.layer:
		return a.layer < b.layer

	return a.priority < b.priority


func _is_negative_modifier(modifier: Dictionary) -> bool:
	"""Determina si un modificador es negativo/restrictivo (Sección 7.4)

	Modificadores negativos incluyen:
	- Valores negativos (debuffs)
	- Restricciones
	- Operaciones de resta o establecer a 0
	- Remover keywords/habilidades
	"""
	# Tipo de restricción siempre es negativo
	if modifier.type == ModifierType.RESTRICTION:
		return true

	# Valor negativo
	var value = modifier.value
	if value is int and value < 0:
		return true
	if value is float and value < 0:
		return true

	# Operación de resta
	var operation = modifier.get("operation", "add")
	if operation in ["subtract", "-"]:
		return true

	# Establecer a 0
	if operation in ["set", "="] and value == 0:
		return true

	# Remover keywords
	var keywords_remove = modifier.get("keywords_remove", [])
	if not keywords_remove.is_empty():
		return true

	return false


func _is_modifier_active(modifier: Dictionary) -> bool:
	"""Verifica si un modificador está activo"""
	if not modifier.is_active:
		return false

	# Verificar duración
	match modifier.duration:
		ModifierDuration.PERMANENT:
			# Verificar que la fuente siga en juego
			var source = modifier.source
			if source and not is_instance_valid(source):
				return false
			if source and not _is_card_in_play(source):
				return false

		ModifierDuration.TIMED:
			if modifier.turns_remaining <= 0:
				return false

		ModifierDuration.CONDITIONAL:
			var condition = modifier.condition
			if condition.is_valid():
				if not condition.call():
					return false

	return true


func _calculate_modifier_value(modifier: Dictionary, card: Node, current_value: int) -> int:
	"""Calcula el valor de un modificador

	El valor puede ser fijo o calculado dinámicamente.
	"""
	var value = modifier.value

	if value is Callable:
		# Valor dinámico
		return value.call(card, current_value, modifier)
	elif value is int:
		return value
	elif value is float:
		return int(value)

	return 0


func _apply_operation(current: int, value: int, operation: String) -> int:
	"""Aplica una operación matemática"""
	match operation.to_lower():
		"add", "+":
			return current + value
		"subtract", "-":
			return current - value
		"set", "=":
			return value
		"multiply", "*":
			return current * value
		"divide", "/":
			return current / max(1, value)
		"min":
			return min(current, value)
		"max":
			return max(current, value)
		_:
			return current + value


# =============================================================================
# KEYWORDS, HABILIDADES Y RESTRICCIONES (implementación en KeywordQuery.gd)
# =============================================================================
func get_active_keywords(card: Node) -> Array:
	return _keyword_query.get_active_keywords(card)


func has_keyword(card: Node, keyword) -> bool:
	return _keyword_query.has_keyword(card, keyword)


func has_protection(card: Node, protection_type: String = "") -> bool:
	return _keyword_query.has_protection(card, protection_type)


func can_attack(card: Node) -> bool:
	return _keyword_query.can_attack(card)


func can_block(card: Node) -> bool:
	return _keyword_query.can_block(card)


func can_be_targeted(card: Node, source: Node = null) -> bool:
	return _keyword_query.can_be_targeted(card, source)

# =============================================================================
# EVENTOS Y LIMPIEZA
# =============================================================================
func _on_turn_ended(player_id: int) -> void:
	"""Handler para fin de turno - limpia modificadores temporales"""
	var to_remove: Array = []

	for mod_id in _modifiers:
		var mod = _modifiers[mod_id]

		match mod.duration:
			ModifierDuration.UNTIL_END_TURN:
				to_remove.append(mod_id)

			ModifierDuration.TIMED:
				mod.turns_remaining -= 1
				if mod.turns_remaining <= 0:
					to_remove.append(mod_id)

	# Remover modificadores expirados
	for mod_id in to_remove:
		unregister_modifier(mod_id)

	if not to_remove.is_empty():
		print("[ContinuousEffectManager] %d modificadores expirados al fin del turno" % to_remove.size())


func _on_card_entered_zone(card: Node, zone: int, player_id: int) -> void:
	"""Handler cuando una carta entra a una zona

	Registra efectos continuos de cartas que entran en juego.
	"""
	# Solo procesar cartas que entran en zonas de juego
	if zone not in Constants.ZONES_IN_PLAY:
		return

	# Verificar si la carta tiene efectos continuos
	_register_card_continuous_effects(card)

	# Invalidar cache
	_invalidate_cache()


func _on_card_left_zone(card: Node, zone: int, player_id: int) -> void:
	"""Handler cuando una carta sale de una zona

	Remueve todos los modificadores de esa carta como fuente.
	"""
	# Solo procesar si sale de zonas de juego
	if zone not in Constants.ZONES_IN_PLAY:
		return

	# Remover modificadores de esta carta como fuente
	remove_modifiers_from_source(card)

	# Invalidar cache
	_invalidate_cache()


func _register_card_continuous_effects(card: Node) -> void:
	"""Registra los efectos continuos de una carta al entrar en juego

	Lee la habilidad de la carta y registra modificadores apropiados.
	"""
	if card == null:
		return

	# 2026-08-25: antes leía card.get_meta("card_data", {}) — metadata de
	# Godot que NUNCA se asigna en el juego real (solo en TestScene.gd, una
	# escena de prueba vieja). Siempre volvía {}, así que ability_text
	# siempre estaba vacío y este detector nunca encontraba nada, para
	# ninguna carta — confirmado con Patria Vieja, que no aplicaba su aura
	# a pesar de tener el patrón ya soportado.
	var ability_text: String = card.card_ability if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		var card_data = card.get("card_data") if card.get("card_data") != null else {}
		if card_data is Dictionary:
			ability_text = card_data.get("ability", card_data.get("habilidad", ""))

	# Detectar efectos continuos en el texto
	_parse_and_register_continuous_effects(card, ability_text)


func _parse_and_register_continuous_effects(card: Node, ability_text: String) -> void:
	"""Parsea el texto de habilidad y registra efectos continuos"""
	if ability_text.is_empty():
		return

	var text = ability_text.to_lower()

	# Detectar buffs a aliados: "Tus aliados obtienen +X/+X"
	var ally_buff_regex = RegEx.new()
	ally_buff_regex.compile("(?:tus |los )?(aliados|criaturas).+obtienen?\\s*\\+(\\d+)")
	var ally_match = ally_buff_regex.search(text)

	if ally_match:
		var buff_value = int(ally_match.get_string(2))
		register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": ModifierType.STRENGTH,
			"stat": "strength",
			"value": buff_value,
			"operation": "add",
			"duration": ModifierDuration.PERMANENT,
			"layer": ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Buff a aliados +%d" % buff_value
		})

	# Detectar buffs a aliados con calificador de coste, forma "ganan N de
	# Fuerza" (2026-08-24, p.ej. Patria Vieja: "Tus Aliados de coste 1 o más
	# ganan 1 de Fuerza") — distinto del patrón de arriba, que solo cubre
	# "obtienen +N" sin calificador de coste.
	# "(?:que controlas)?" agregado (2026-08-30, p.ej. Sable de Napoleón:
	# "Los Aliados que controlas ganan 1 de Fuerza") — antes exigía "aliados"
	# seguido DIRECTO de "ganan" (salvo el calificador de coste), así que
	# "que controlas" en el medio rompía el match y esta variante quedaba
	# sin ningún patrón que la reconociera.
	var qualified_buff_regex = RegEx.new()
	qualified_buff_regex.compile("(?:tus |los )?aliados(?:\\s+de coste\\s+(\\d+)\\s+o\\s+m[aá]s)?(?:\\s+que controlas)?\\s+ganan?\\s*(\\d+)\\s*de fuerza")
	var qualified_match = qualified_buff_regex.search(text)

	if qualified_match:
		var min_cost_str := qualified_match.get_string(1)
		var qualified_value := int(qualified_match.get_string(2))
		var qualified_filter: Dictionary = {}
		if not min_cost_str.is_empty():
			qualified_filter["min_cost"] = int(min_cost_str)

		register_modifier({
			"source": card,
			"target": "ALLIES",
			"type": ModifierType.STRENGTH,
			"stat": "strength",
			"value": qualified_value,
			"operation": "add",
			"duration": ModifierDuration.PERMANENT,
			"layer": ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"filter": qualified_filter,
			"description": "Buff a aliados +%d%s" % [
				qualified_value,
				(" (coste %d o más)" % qualified_filter.min_cost) if qualified_filter.has("min_cost") else ""
			]
		})

		# Cláusula adicional: "...y no son Destruidos cuando bloquean"
		# (p.ej. Patria Vieja) — protección acotada SOLO a destrucción por
		# perder un combate bloqueando (BattleManager la consulta con
		# protection_type "BLOCK_DESTROY"), no protección general.
		if "no son destruid" in text and "bloquean" in text:
			register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": ModifierType.PROTECTION,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": ModifierDuration.PERMANENT,
				"layer": ModifierLayer.LAYER_6_ABILITIES,
				"filter": qualified_filter,
				"protection_type": "BLOCK_DESTROY",
				"description": "No son destruidos cuando bloquean"
			})

		# Cláusula adicional: "...Furia..." en la misma oración (2026-09-02,
		# p.ej. Espíritu Kotaix: "Tus Aliados ganan 2 de Fuerza, Furia y no
		# pueden ser afectados por Talismanes") — mismo criterio que la
		# cláusula de BLOCK_DESTROY de arriba, pero para el patrón de
		# keyword_regex más abajo (que exige 'tienen', no matchea 'ganan...
		# Furia' en lista separada por comas).
		if "furia" in text:
			register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": ModifierType.KEYWORDS,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": ModifierDuration.PERMANENT,
				"layer": ModifierLayer.LAYER_6_ABILITIES,
				"filter": qualified_filter,
				"keywords_add": [Constants.Keyword.FURIA],
				"description": "Otorga Furia a aliados"
			})

		# Cláusula adicional: "...no pueden ser afectados por Talismanes"
		# (2026-09-02, Espíritu Kotaix) — protección otorgada a OTRAS cartas
		# (a diferencia de Constants.gd/TargetedEffectExecutor._target_text_denies(),
		# que solo detecta cuando una carta se protege a SÍ MISMA con su
		# propio texto impreso). ContinuousEffectManager.has_protection(card,
		# "TALISMAN") es la consulta; TargetedEffectExecutor._select_ally_target()
		# la respeta cuando source_card es un Talismán.
		if "no pueden ser afectados por talismanes" in text or "no puede ser afectado por talismanes" in text:
			register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": ModifierType.PROTECTION,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": ModifierDuration.PERMANENT,
				"layer": ModifierLayer.LAYER_6_ABILITIES,
				"filter": qualified_filter,
				"protection_type": "TALISMAN",
				"description": "Inmune a Talismanes"
			})

	# Detectar debuffs a enemigos: "Los enemigos obtienen -X"
	var enemy_debuff_regex = RegEx.new()
	enemy_debuff_regex.compile("(?:los )?(enemigos|oponente).+obtienen?\\s*-(\\d+)")
	var enemy_match = enemy_debuff_regex.search(text)

	if enemy_match:
		var debuff_value = int(enemy_match.get_string(2))
		register_modifier({
			"source": card,
			"target": "ENEMIES",
			"type": ModifierType.STRENGTH,
			"stat": "strength",
			"value": -debuff_value,
			"operation": "add",
			"duration": ModifierDuration.PERMANENT,
			"layer": ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Debuff a enemigos -%d" % debuff_value
		})

	# Detectar keywords otorgadas: "Tus aliados tienen Furia"
	var keyword_regex = RegEx.new()
	keyword_regex.compile("(?:tus |los )?(aliados|criaturas).+tienen\\s+(\\w+)")
	var keyword_match = keyword_regex.search(text)

	if keyword_match:
		var keyword_name = keyword_match.get_string(2)
		var keyword_enum = _string_to_keyword(keyword_name)

		if keyword_enum != -1:
			register_modifier({
				"source": card,
				"target": "ALLIES",
				"type": ModifierType.KEYWORDS,
				"stat": "",
				"value": 0,
				"operation": "add",
				"duration": ModifierDuration.PERMANENT,
				"layer": ModifierLayer.LAYER_6_ABILITIES,
				"keywords_add": [keyword_enum],
				"description": "Otorga %s a aliados" % keyword_name
			})

	# "Gana N de Fuerza por cada Arma que controles" (2026-08-30, p.ej.
	# Manuel Bulnes) — buff a SÍ MISMA (no 'tus Aliados'), con valor
	# DINÁMICO que se recalcula solo (value como Callable, ya soportado por
	# _calculate_modifier_value()). Cuenta Armas equipadas en cualquier
	# Aliado del mismo controlador — las Armas son hijas de su portador,
	# no children directos del campo, así que no alcanza con
	# _get_all_cards_in_play() + filtro de tipo.
	var self_scaling_weapon_regex = RegEx.new()
	self_scaling_weapon_regex.compile("gana\\s+(\\d+)\\s+de\\s+fuerza\\s+por\\s+cada\\s+arma\\s+que\\s+controles")
	var self_scaling_match = self_scaling_weapon_regex.search(text)
	if self_scaling_match:
		var per_unit_value := int(self_scaling_match.get_string(1))
		var value_callable := func(c: Node, _current: int, _mod: Dictionary) -> int:
			var card_owner := _get_card_owner(c)
			var weapon_count := 0
			for other in _get_all_cards_in_play():
				if _get_card_owner(other) != card_owner:
					continue
				var w = other.get("equipped_weapons")
				if w is Array:
					weapon_count += w.size()
			return per_unit_value * weapon_count
		register_modifier({
			"source": card,
			"target": "SELF",
			"type": ModifierType.STRENGTH,
			"stat": "strength",
			"value": value_callable,
			"operation": "add",
			"duration": ModifierDuration.PERMANENT,
			"layer": ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "Gana %d de Fuerza por cada Arma que controle" % per_unit_value
		})

	# "Tus Aliados que porten Arma no pueden perder su habilidad" (2026-08-30,
	# Manuel Bulnes) — protección contra KeywordManager.silence_card(),
	# consultada directo desde ahí (choke point único).
	if "aliados que porten arma" in text and "no pueden perder su habilidad" in text:
		KeywordManager.register_weapon_wielder_silence_immunity(card)


# =============================================================================
# RECÁLCULO Y CACHE
# =============================================================================
func _invalidate_cache() -> void:
	"""Invalida el cache de valores calculados"""
	_cache_dirty = true
	_calculated_cache.clear()


func recalculate_all() -> void:
	"""Recalcula todos los valores modificados

	Llamar después de cambios masivos.
	"""
	_invalidate_cache()

	# Obtener todas las cartas en juego
	var affected_cards: Array = []

	if _game_board:
		for zone in [Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_APOYO]:
			for player_id in [0, 1]:
				var cards = _game_board.get_cards_in_zone(zone, player_id)
				affected_cards.append_array(cards)

	# Recalcular cada carta
	for card in affected_cards:
		get_modified_strength(card)
		get_modified_cost(card)

	_cache_dirty = false
	emit_signal("recalculation_completed", affected_cards)
	print("[ContinuousEffectManager] Recálculo completado: %d cartas" % affected_cards.size())


# =============================================================================
# UTILIDADES
# =============================================================================
func _get_card_id(card) -> String:
	"""Obtiene un ID único para una carta"""
	if card == null:
		return "null"

	if card is String:
		return card

	if card is Node:
		if card.get("card_id"):
			return str(card.card_id)
		return str(card.get_instance_id())

	if card is Dictionary:
		return card.get("id", str(card.hash()))

	return str(card)


func _get_card_name(card) -> String:
	"""Obtiene el nombre de una carta"""
	if card == null:
		return "???"

	if card is Node:
		if card.get("card_name"):
			return card.card_name
		if card.get("nombre"):
			return card.nombre

	if card is Dictionary:
		return card.get("name", card.get("nombre", "???"))

	return "???"


func _get_card_type(card: Node) -> String:
	"""Obtiene el tipo de una carta"""
	if card == null:
		return ""

	if card.get("card_type"):
		var ct = card.card_type
		if ct is int:
			return Constants.CardType.keys()[ct]
		return str(ct)

	if card.get("tipo"):
		return str(card.tipo)

	return ""


func _get_card_faction(card: Node) -> String:
	"""Obtiene la facción/mitología de una carta"""
	if card == null:
		return ""

	if card.get("faction"):
		return card.faction
	if card.get("mitologia"):
		return card.mitologia

	return ""


func _get_card_owner(card: Node) -> int:
	"""Obtiene el jugador que controla la carta (2026-08-24) — usado para
	targeting ALLIES/ENEMIES real (por dueño, no por mitología). owner_id es
	el campo que de verdad se asigna en todo el juego (ver HandManager.
	_setup_card); controller_id existe pero nunca se popula salvo en algún
	efecto puntual de robo de control."""
	if card == null:
		return -1
	if card.get("owner_id") != null:
		return card.owner_id
	if card.get("controller_id") != null:
		return card.controller_id
	return -1


func _get_all_cards_in_play() -> Array:
	"""Todas las cartas de ambos jugadores en las 3 líneas del campo
	(2026-08-25) — usado para refrescar el badge visual de TODOS los
	afectados cuando se registra/quita un aura de target dinámico (ALL/
	ALLIES/ENEMIES/OTHER), ya que _resolve_targets() no las enumera (se
	resuelven carta por carta en _get_applicable_modifiers(), no acá)."""
	var main = get_node_or_null("/root/Main")
	if not main:
		return []
	var result: Array = []
	for field in [main.get("player_field"), main.get("player_linea_ataque"), main.get("player_linea_apoyo"),
				  main.get("opponent_field"), main.get("opponent_linea_ataque"), main.get("opponent_linea_apoyo")]:
		if not field:
			continue
		for card in field.get_children():
			result.append(card)
	return result


func _get_card_zone(card: Node) -> int:
	"""Obtiene la zona actual de una carta"""
	if card == null:
		return -1

	if card.get("current_zone"):
		return card.current_zone

	return -1


func _card_has_keyword(card: Node, keyword) -> bool:
	"""Verifica si una carta tiene una keyword base"""
	if card == null:
		return false

	var keywords = []
	if card.get("keywords"):
		keywords = card.keywords
	elif card.get("base_keywords"):
		keywords = card.base_keywords

	for kw in keywords:
		if kw == keyword:
			return true

	return false


func _is_card_in_play(card: Node) -> bool:
	"""Verifica si una carta está en una zona de juego"""
	if card == null or not is_instance_valid(card):
		return false

	var zone = _get_card_zone(card)
	return zone in Constants.ZONES_IN_PLAY


func _resolve_targets(modifier: Dictionary) -> Array:
	"""Resuelve los targets de un modificador a un array de cartas"""
	var target = modifier.target
	var targets: Array = []

	if target == null:
		return targets

	if target is Node:
		targets.append(target)
	elif target is Array:
		targets = target
	# Strings como "ALL", "ALLIES" se manejan dinámicamente

	return targets


func _string_to_keyword(keyword_str: String) -> int:
	"""Convierte string de keyword a enum"""
	match keyword_str.to_upper():
		"FURIA": return Constants.Keyword.FURIA
		"IMBLOQUEABLE": return Constants.Keyword.IMBLOQUEABLE
		"INDESTRUCTIBLE": return Constants.Keyword.INDESTRUCTIBLE
		"INDESTERRABLE": return Constants.Keyword.INDESTERRABLE
		"EXHUMAR": return Constants.Keyword.EXHUMAR
		"UNICA", "ÚNICA": return Constants.Keyword.UNICA
		"ERRANTE": return Constants.Keyword.ERRANTE
		"RETADOR": return Constants.Keyword.RETADOR
		_: return -1


# =============================================================================
# ACTUALIZACION VISUAL, DESGLOSES Y DEBUG (implementacion en ContinuousVisualSync.gd)
# =============================================================================
func update_all_card_visuals() -> void:
	_visual_sync.update_all_card_visuals()


func get_strength_breakdown(card: Node) -> Dictionary:
	return _visual_sync.get_strength_breakdown(card)


func get_cost_breakdown(card: Node) -> Dictionary:
	return _visual_sync.get_cost_breakdown(card)


func debug_print_modifiers() -> void:
	_visual_sync.debug_print_modifiers()


func debug_print_card_stats(card: Node) -> void:
	_visual_sync.debug_print_card_stats(card)
