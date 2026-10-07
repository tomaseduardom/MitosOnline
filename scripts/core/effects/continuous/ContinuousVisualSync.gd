extends RefCounted
class_name ContinuousVisualSync
## ContinuousVisualSync — Sincroniza el visual de las cartas (badge de
## Fuerza, indicadores) con los valores modificados, desglose de
## Fuerza/Coste para tooltips, y utilidades de debug. Opera sobre
## ContinuousEffectManager via _main. Extraído de ContinuousEffectManager.gd
## (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func notify_card_visual_update(card: Node, stat: String, base_value: int, modified_value: int, diff: int) -> void:
	"""Notifica a la carta que actualice su visualización

	Intenta llamar directamente al método de la carta si existe.
	"""
	if card == null or not is_instance_valid(card):
		return

	# Intentar llamar método de actualización visual en la carta
	if card.has_method("refresh_strength_badge") and stat == "strength":
		card.refresh_strength_badge()
	elif card.has_method("refresh_cost_badge") and stat == "cost":
		card.refresh_cost_badge()
	elif card.has_method("update_stat_display"):
		card.update_stat_display(stat, base_value, modified_value)

	elif card.has_method("set_modified_strength") and stat == "strength":
		card.set_modified_strength(modified_value)

	elif card.has_method("set_modified_cost") and stat == "cost":
		card.set_modified_cost(modified_value)

	# Mostrar indicador visual de cambio
	if card.has_method("show_stat_change_indicator"):
		var color = Color.GREEN if diff > 0 else Color.RED
		card.show_stat_change_indicator(stat, diff, color)

	# Log para CombatLog
	var card_name = _main._get_card_name(card)
	var sign_str = "+" if diff > 0 else ""
	var action_type = "buff" if diff > 0 else "debuff"

	CombatLog.add_entry(action_type, "%s: %s %s%d (ahora %d)" % [
		CombatLog.format_card(card_name),
		stat.to_upper(),
		sign_str,
		diff,
		modified_value
	], {
		"card": card_name,
		"stat": stat,
		"diff": diff,
		"new_value": modified_value
	})


# =============================================================================
# ACTUALIZACIÓN VISUAL DE CARTAS AFECTADAS
# =============================================================================
func update_affected_cards_visuals(targets: Array, stat: String) -> void:
	"""Actualiza los visuales de todas las cartas afectadas por un cambio de modificador

	Args:
		targets: Array de cartas a actualizar
		stat: El stat que cambió ("strength", "cost", etc.)
	"""
	for target in targets:
		if target == null or not is_instance_valid(target):
			continue

		if not (target is Node):
			continue

		# Forzar recálculo (el método emitirá señales si hay cambios)
		if stat == "strength" or stat == "":
			_main.get_modified_strength(target)
			if target.has_method("refresh_strength_badge"):
				target.refresh_strength_badge()
		if stat == "cost" or stat == "":
			_main.get_modified_cost(target)
			if target.has_method("refresh_cost_badge"):
				target.refresh_cost_badge()


func update_all_card_visuals() -> void:
	"""Fuerza actualización visual de todas las cartas en juego

	Útil después de cambios masivos o al reconectar.
	"""
	var all_cards: Array = []

	# Recolectar todas las cartas en zonas de juego
	if _main._game_board:
		for zone in [Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_APOYO]:
			for player_id in [0, 1]:
				if _main._game_board.has_method("get_cards_in_zone"):
					var cards = _main._game_board.get_cards_in_zone(zone, player_id)
					all_cards.append_array(cards)

	# También actualizar cartas con modificadores directos
	for card_id in _main._modifiers_by_target:
		# Intentar obtener la carta por su ID
		for mod_id in _main._modifiers_by_target[card_id]:
			if _main._modifiers.has(mod_id):
				var mod = _main._modifiers[mod_id]
				var target = mod.target
				# 2026-09-19, bug real reportado por el usuario: "Left operand
				# of 'is' is a previously freed instance" — is_instance_valid()
				# DEBE ir primero: 'is' se evalúa antes que el 'and' de la
				# derecha (orden de evaluación normal, sin cortocircuito a
				# favor), y a diferencia de is_instance_valid(), el operador
				# 'is' de GDScript revienta si el objeto ya fue liberado, no
				# devuelve false. Un modificador cuyo target salió de juego sin
				# limpiarse de _modifiers/_modifiers_by_target (carta destruida/
				# desterrada con un buff/debuff activo todavía registrado) deja
				# exactamente esa referencia colgante aquí.
				if is_instance_valid(target) and target is Node:
					if target not in all_cards:
						all_cards.append(target)

	# Actualizar cada carta
	for card in all_cards:
		_update_single_card_visual(card)

	if Constants.VERBOSE_DIAG_LOGS:
		print("[ContinuousEffectManager] Visuales actualizados: %d cartas" % all_cards.size())


func _update_single_card_visual(card: Node) -> void:
	"""Actualiza el visual de una carta individual"""
	if card == null or not is_instance_valid(card):
		return

	var base_strength = _main._get_base_stat(card, "strength")
	var mod_strength = _main.get_modified_strength(card)
	var base_cost = _main._get_base_stat(card, "cost")
	var mod_cost = _main.get_modified_cost(card)

	if card.has_method("refresh_strength_badge"):
		card.refresh_strength_badge()
	if card.has_method("refresh_cost_badge"):
		card.refresh_cost_badge()

	# Llamar método de actualización si existe
	if card.has_method("update_modified_stats"):
		card.update_modified_stats(mod_strength, mod_cost)
	else:
		# Intentar métodos individuales
		if card.has_method("set_display_strength"):
			card.set_display_strength(mod_strength, base_strength)
		if card.has_method("set_display_cost"):
			card.set_display_cost(mod_cost, base_cost)

	# Emitir señal para UI externa
	_main.emit_signal("card_visual_update_required", card, "all", base_strength, mod_strength)


func get_strength_breakdown(card: Node) -> Dictionary:
	"""Obtiene el desglose de fuerza de una carta

	Útil para mostrar tooltips detallados.

	Returns: {base, modifiers: [{source, value, description}], total}
	"""
	var breakdown = {
		"base": _main._get_base_stat(card, "strength"),
		"modifiers": [],
		"total": 0
	}

	var applicable = _main._get_applicable_modifiers(card, "strength")
	applicable.sort_custom(_main._compare_modifiers)

	var current = breakdown.base

	for mod in applicable:
		if not _main._is_modifier_active(mod):
			continue

		var mod_value = _main._calculate_modifier_value(mod, card, current)
		if mod_value == 0:
			continue

		var old_current = current
		current = _main._apply_operation(current, mod_value, mod.operation)

		breakdown.modifiers.append({
			"source": mod.description,
			"source_id": mod.source_id,
			"value": current - old_current,
			"operation": mod.operation,
			"is_negative": _main._is_negative_modifier(mod)
		})

	breakdown.total = max(0, current)
	return breakdown


func get_cost_breakdown(card: Node) -> Dictionary:
	"""Obtiene el desglose de coste de una carta"""
	var breakdown = {
		"base": _main._get_base_stat(card, "cost"),
		"modifiers": [],
		"total": 0
	}

	var applicable = _main._get_applicable_modifiers(card, "cost")
	applicable.sort_custom(_main._compare_modifiers)

	var current = breakdown.base

	for mod in applicable:
		if not _main._is_modifier_active(mod):
			continue

		var mod_value = _main._calculate_modifier_value(mod, card, current)
		if mod_value == 0:
			continue

		var old_current = current
		current = _main._apply_operation(current, mod_value, mod.operation)

		breakdown.modifiers.append({
			"source": mod.description,
			"source_id": mod.source_id,
			"value": current - old_current,
			"operation": mod.operation,
			"is_negative": _main._is_negative_modifier(mod)
		})

	breakdown.total = max(0, current)
	return breakdown


# =============================================================================
# DEBUG
# =============================================================================
func debug_print_modifiers() -> void:
	"""Imprime todos los modificadores activos"""
	print("=" .repeat(60))
	print("MODIFICADORES ACTIVOS: %d" % _main._modifiers.size())
	print("-" .repeat(60))

	for mod_id in _main._modifiers:
		var mod = _main._modifiers[mod_id]
		var active = "✓" if _main._is_modifier_active(mod) else "✗"
		print("[%s] %s: %s (%s %s%d a %s)" % [
			active,
			mod_id,
			mod.description,
			mod.stat,
			"+" if mod.value >= 0 else "",
			mod.value,
			str(mod.target)
		])

	print("=" .repeat(60))


func debug_print_card_stats(card: Node) -> void:
	"""Imprime los stats de una carta con modificadores"""
	var card_name = _main._get_card_name(card)
	var base_str = _main._get_base_stat(card, "strength")
	var mod_str = _main.get_modified_strength(card)
	var base_cost = _main._get_base_stat(card, "cost")
	var mod_cost = _main.get_modified_cost(card)
	var keywords = _main.get_active_keywords(card)

	print("=" .repeat(40))
	print("CARTA: %s" % card_name)
	print("-" .repeat(40))
	print("Fuerza: %d → %d" % [base_str, mod_str])
	print("Coste:  %d → %d" % [base_cost, mod_cost])
	print("Keywords: %s" % str(keywords))
	print("=" .repeat(40))
