extends RefCounted
class_name ModifierRegistry
## ModifierRegistry — Registro CRUD de modificadores continuos (alta/baja) y
## cálculo de valores modificados (Fuerza/Coste/Daño), aplicando capas y la
## Regla de Prioridad Negativa (Sección 7.4). Opera sobre
## ContinuousEffectManager via _main (el estado — _modifiers, _modifiers_by_*,
## cache — sigue viviendo en el autoload, igual que ContinuousVisualSync.gd ya
## lo consulta ahí). Extraído de ContinuousEffectManager.gd (Fase 4 de
## reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


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
	_main._modifier_counter += 1
	var modifier_id = "mod_%d_%d" % [Time.get_ticks_msec(), _main._modifier_counter]

	var source = params.get("source")
	var source_id = _main._get_card_id(source) if source else "system"

	var modifier = {
		"id": modifier_id,
		"source": source,
		"source_id": source_id,
		"target": params.get("target"),
		"type": params.get("type", _main.ModifierType.STRENGTH),
		"stat": params.get("stat", "strength"),
		"value": params.get("value", 0),
		"operation": params.get("operation", "add"),
		"duration": params.get("duration", _main.ModifierDuration.PERMANENT),
		"duration_value": params.get("duration_value", 0),
		"turns_remaining": params.get("duration_value", 0),
		"condition": params.get("condition", Callable()),
		"layer": params.get("layer", _main.ModifierLayer.LAYER_7B_CHAR_MODIFY),
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
	_main._modifiers[modifier_id] = modifier

	# Indexar por fuente
	if not _main._modifiers_by_source.has(source_id):
		_main._modifiers_by_source[source_id] = []
	_main._modifiers_by_source[source_id].append(modifier_id)

	# Indexar por tipo
	var mod_type = modifier.type
	_main._modifiers_by_type[mod_type].append(modifier_id)

	# Indexar por target(s)
	var targets = _main._resolve_targets(modifier)
	for target in targets:
		var target_id = _main._get_card_id(target)
		if not _main._modifiers_by_target.has(target_id):
			_main._modifiers_by_target[target_id] = []
		_main._modifiers_by_target[target_id].append(modifier_id)

	# Invalidar cache
	_main._invalidate_cache()

	_main.emit_signal("modifier_registered", modifier)
	print("[ContinuousEffectManager] Modificador registrado: %s (%s)" % [modifier_id, modifier.description])

	# Recalcular y actualizar visuales de las cartas afectadas. Con target
	# dinámico (ALL/ALLIES/ENEMIES/OTHER, un String) _resolve_targets()
	# devuelve vacío a propósito — se resuelve carta por carta en
	# _get_applicable_modifiers(), no aquí — así que sin esto el badge de
	# Fuerza de los Aliados YA en juego nunca se refrescaba al entrar un
	# aura nueva (2026-08-25, confirmado con Patria Vieja: el bonus se
	# calculaba bien pero no se veía hasta que algo más recalculaba esa
	# carta puntual).
	var visual_targets: Array = targets
	if targets.is_empty() and modifier.target is String:
		visual_targets = _main._get_all_cards_in_play()
	_main._visual_sync.call_deferred("update_affected_cards_visuals", visual_targets, modifier.stat)

	return modifier_id


func unregister_modifier(modifier_id: String) -> bool:
	"""Remueve un modificador

	Returns: true si se removió exitosamente
	"""
	if not _main._modifiers.has(modifier_id):
		return false

	var modifier = _main._modifiers[modifier_id]
	var stat = modifier.get("stat", "strength")

	# Remover de índice por fuente
	var source_id = modifier.source_id
	if _main._modifiers_by_source.has(source_id):
		_main._modifiers_by_source[source_id].erase(modifier_id)

	# Remover de índice por tipo
	var mod_type = modifier.type
	_main._modifiers_by_type[mod_type].erase(modifier_id)

	# Remover de índice por targets y guardar para actualizar visuals
	var targets = _main._resolve_targets(modifier)
	for target in targets:
		var target_id = _main._get_card_id(target)
		if _main._modifiers_by_target.has(target_id):
			_main._modifiers_by_target[target_id].erase(modifier_id)

	# Remover modificador
	_main._modifiers.erase(modifier_id)

	# Invalidar cache
	_main._invalidate_cache()

	_main.emit_signal("modifier_removed", modifier_id)
	print("[ContinuousEffectManager] Modificador removido: %s" % modifier_id)

	# Recalcular y actualizar visuales de las cartas afectadas — mismo
	# motivo que en register_modifier() para target dinámico (String).
	var visual_targets: Array = targets
	if targets.is_empty() and modifier.target is String:
		visual_targets = _main._get_all_cards_in_play()
	_main._visual_sync.call_deferred("update_affected_cards_visuals", visual_targets, stat)

	return true


func remove_modifiers_from_source(source: Node) -> int:
	"""Remueve todos los modificadores de una fuente

	Usado cuando una carta sale del juego.

	Returns: Número de modificadores removidos
	"""
	var source_id = _main._get_card_id(source)
	if not _main._modifiers_by_source.has(source_id):
		return 0

	var modifier_ids = _main._modifiers_by_source[source_id].duplicate()
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
	var card_id = _main._get_card_id(card)

	# Verificar cache
	if not _main._cache_dirty and _main._calculated_cache.has(card_id):
		if _main._calculated_cache[card_id].has(stat):
			return _main._calculated_cache[card_id][stat]

	# Obtener valor previo (para detectar cambios)
	var previous_value: int = -999
	if _main._previous_values.has(card_id) and _main._previous_values[card_id].has(stat):
		var raw_prev = _main._previous_values[card_id][stat]
		# 2026-09-15, bug real reportado por el usuario: "Invalid operands
		# 'String' and 'int' in operator '!='" — algo dejó un valor no-int
		# en _previous_values (probablemente vía _get_base_stat()'s rama
		# genérica '_:', que devuelve card.get(stat) SIN castear a int para
		# cualquier stat que no sea strength/cost/damage). Se castea aquí
		# como salvaguarda y se deja rastro si pasa, en vez de romper la
		# comparación de abajo.
		if raw_prev is String or raw_prev is StringName:
			push_warning("[ModifierRegistry] previous_value no-int para card_id=%s stat=%s: %s (%s)" % [
				str(card_id), stat, str(raw_prev), typeof(raw_prev)
			])
			previous_value = int(raw_prev) if String(raw_prev).is_valid_int() else -999
		else:
			previous_value = int(raw_prev)

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
	var debug_lines: Array[String] = []

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
			# Debug — acumulado, no impreso todavía (2026-09-11, bug real
			# reportado por el usuario: esta función recalcula TODOS los
			# modificadores de la carta cada vez que CUALQUIER cosa dispara
			# un recálculo global, no solo cuando esta carta cambia — sin
			# este acumulador, cada modificador ya aplicado se reimprimía
			# idéntico en cada pasada aunque el resultado final no cambiara).
			# Se imprime más abajo solo si el valor final de verdad cambió.
			debug_lines.append("[ContinuousEffectManager] %s: %s %d → %d (%s)" % [
				stat, _main._get_card_name(card), old_value, current_value, mod.description
			])

	# El valor mínimo de fuerza/coste es 0
	current_value = max(0, current_value)

	# Guardar en cache
	if not _main._calculated_cache.has(card_id):
		_main._calculated_cache[card_id] = {}
	_main._calculated_cache[card_id][stat] = current_value

	# Guardar valor previo para próxima comparación
	if not _main._previous_values.has(card_id):
		_main._previous_values[card_id] = {}
	_main._previous_values[card_id][stat] = current_value

	# =========================================================================
	# ACTUALIZACIÓN VISUAL - Emitir señales si el valor cambió
	# =========================================================================
	var has_changed: bool = (previous_value != -999 and previous_value != current_value) or (previous_value == -999 and current_value != base_value)
	if has_changed:
		var ref_prev: int = previous_value if previous_value != -999 else base_value
		for line in debug_lines:
			print(line)

		# Emitir señal genérica de cambio
		_main.emit_signal("card_stats_changed", card, stat, ref_prev, current_value)
		_main.emit_signal("card_visual_update_required", card, stat, base_value, current_value)

		# Señales específicas para fuerza
		if stat == "strength":
			var bonus_diff = current_value - ref_prev
			if bonus_diff > 0:
				_main.emit_signal("strength_bonus_gained", card, bonus_diff, current_value, last_source_name)
				_main._visual_sync.notify_card_visual_update(card, "strength", base_value, current_value, bonus_diff)
			elif bonus_diff < 0:
				_main.emit_signal("strength_bonus_lost", card, abs(bonus_diff), current_value, last_source_name)
				_main._visual_sync.notify_card_visual_update(card, "strength", base_value, current_value, bonus_diff)

		# Señales específicas para coste
		elif stat == "cost":
			_main.emit_signal("cost_modified", card, ref_prev, current_value)
			_main._visual_sync.notify_card_visual_update(card, "cost", base_value, current_value, current_value - ref_prev)

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
			var raw = card.get(stat)
			if raw != null:
				# 2026-09-15: cast defensivo — a diferencia de las ramas de
				# arriba (strength/cost, que leen propiedades típicamente
				# numéricas de Card), aquí 'stat' es un nombre arbitrario y
				# card.get(stat) es Variant sin garantía de tipo; devolver
				# un String directo aquí (declarado -> int) fue la causa real
				# de "Invalid operands 'String' and 'int' in operator '!='"
				# más adelante en _get_modified_stat()/ModifierRegistry.
				if raw is String or raw is StringName:
					return int(raw) if String(raw).is_valid_int() else 0
				return int(raw)
			return 0


func _get_applicable_modifiers(card: Node, stat: String) -> Array:
	"""Obtiene todos los modificadores que aplican a una carta y stat"""
	var card_id = _main._get_card_id(card)
	var applicable: Array = []

	# Modificadores directos a esta carta
	if _main._modifiers_by_target.has(card_id):
		for mod_id in _main._modifiers_by_target[card_id]:
			if _main._modifiers.has(mod_id):
				var mod = _main._modifiers[mod_id]
				if mod.stat == stat or stat == "":
					applicable.append(mod)

	# Modificadores globales (target = "ALL", "ALLIES", "ENEMIES")
	for mod_id in _main._modifiers:
		var mod = _main._modifiers[mod_id]
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
			# significa los que controlas EN JUEGO, nunca los de la mano/
			# Castillo/Cementerio. _is_card_in_play() ya existía (usado solo
			# para registrar/desregistrar la fuente al entrar/salir de juego
			# ella misma) pero nunca se consultaba aquí, del lado del OBJETIVO.
			if source and card and _main._is_card_in_play(card):
				if _main._get_card_owner(source) == _main._get_card_owner(card):
					return _card_matches_filter(card, filter)
			return false

		"ENEMIES", "ENEMIGOS":
			# Distinto controlador que la fuente (mismo motivo que ALLIES),
			# y mismo chequeo de "en juego" agregado arriba.
			if source and card and _main._is_card_in_play(card):
				if _main._get_card_owner(source) != _main._get_card_owner(card):
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
		var card_type = _main._get_card_type(card)
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
		var card_zone = _main._get_card_zone(card)
		if card_zone != filter.zone:
			return false

	# Filtro por keyword
	if filter.has("has_keyword"):
		if not _main._card_has_keyword(card, filter.has_keyword):
			return false

	# Filtro por nombre
	if filter.has("name_contains"):
		var card_name = _main._get_card_name(card).to_lower()
		if not filter.name_contains.to_lower() in card_name:
			return false

	# Filtro por raza — admite una raza única o una lista (2026-09-04, p.ej.
	# shedo titan: "Tus Aliados Ignis o Titán ganan...")
	if filter.has("raza"):
		var card_raza: String = str(card.get("card_raza")) if card.get("card_raza") != null else ""
		if filter.raza is Array:
			var raza_list: Array = filter.raza
			if not raza_list.any(func(r): return card_raza.to_lower() == String(r).to_lower()):
				return false
		elif card_raza.to_lower() != String(filter.raza).to_lower():
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
	if _main.NEGATIVE_PRIORITY_ENABLED:
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
	if modifier.type == _main.ModifierType.RESTRICTION:
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
		_main.ModifierDuration.PERMANENT:
			# Verificar que la fuente siga en juego
			var source = modifier.source
			if source and not is_instance_valid(source):
				return false
			if source and not _main._is_card_in_play(source):
				return false

		_main.ModifierDuration.TIMED:
			if modifier.turns_remaining <= 0:
				return false

		_main.ModifierDuration.CONDITIONAL:
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
