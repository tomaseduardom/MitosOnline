extends RefCounted
class_name DetailedPlayLog
## DetailedPlayLog — Bloques de acción colapsables (DAR Sección 18) y logs
## especiales de efectos parciales / coste X. Opera sobre CombatLog via
## _main (add_entry, emit_signal, formatters, turno/fase actuales).
## Extraído de CombatLog.gd (Fase 4 de reestructuración).

var _main: Node

## Bloques activos: {block_id: ActionBlock}
var _active_blocks: Dictionary = {}
var _block_id_counter: int = 0


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# BLOQUES DE ACCIÓN - Contenedores Colapsables (DAR Sección 18)
# =============================================================================
func log_detailed_play(card_instance: Dictionary, player_id: int = 0) -> int:
	"""Inicia un bloque de acción detallado para una carta

	Agrupa todos los pasos de una carta en un contenedor visual colapsable.
	Muestra el cálculo transparente de coste para verificación de anulaciones.

	Args:
		card_instance: Datos de la carta (debe incluir instance_x si aplica)
		player_id: ID del jugador que juega la carta

	Returns:
		block_id para agregar pasos adicionales
	"""
	_block_id_counter += 1
	var block_id = _block_id_counter

	var block = ActionBlock.new()
	block.id = block_id
	block.card_name = card_instance.get("nombre", card_instance.get("name", "???"))
	block.card_data = card_instance.duplicate(true)
	block.player_id = player_id
	block.started_at = Time.get_unix_time_from_system()

	# ─────────────────────────────────────────────────────────────────────────
	# CÁLCULO TRANSPARENTE DE COSTE (DAR Sección 18 - Hacer el Bien)
	# ─────────────────────────────────────────────────────────────────────────
	var base_cost = card_instance.get("coste", 0)
	if base_cost is String:
		base_cost = 0  # Será calculado con X

	block.instance_x = card_instance.get("instance_x", card_instance.get("x_value", -1))
	block.has_x_cost = block.instance_x >= 0

	if block.has_x_cost:
		var x_total = card_instance.get("x_total_cost", -1)
		if x_total >= 0:
			block.total_cost = x_total
		else:
			# Calcular desde fórmula
			var x_base = card_instance.get("x_base_cost", 0)
			var x_mult = card_instance.get("x_multiplier", 1)
			block.total_cost = x_base + (block.instance_x * x_mult)

		block.cost_breakdown = {
			"formula": card_instance.get("cost_formula", "X"),
			"base_cost": card_instance.get("x_base_cost", 0),
			"x_value": block.instance_x,
			"x_multiplier": card_instance.get("x_multiplier", 1),
			"total": block.total_cost
		}
	else:
		block.total_cost = base_cost if base_cost is int else 0
		block.cost_breakdown = {
			"base_cost": block.total_cost,
			"total": block.total_cost
		}

	# ─────────────────────────────────────────────────────────────────────────
	# TRAZABILIDAD DE EXHUMAR (DAR Sección 6)
	# Si viene del Cementerio, indicar que destino final = Destierro
	# ─────────────────────────────────────────────────────────────────────────
	block.via_exhumar = card_instance.get("via_exhumar", false) or \
						card_instance.get("_exhumar_flag", false)
	block.source_zone = card_instance.get("source_zone", -1)

	# Construir nombre de display con prefijos
	block.display_name = block.card_name
	if block.via_exhumar:
		block.display_name = "[EXHUMAR] " + block.card_name

	_active_blocks[block_id] = block

	# ─────────────────────────────────────────────────────────────────────────
	# LOG INICIAL DEL BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var player_str = _main._formatters.format_player(player_id)
	var card_str = _main._formatters.format_card(block.display_name)

	# Header del bloque
	_main.add_entry("block_start", "╔══════════════════════════════════════════════╗", {
		"block_id": block_id
	})

	# Mensaje de jugar con indicador de Exhumar
	if block.via_exhumar:
		_main.add_entry("block_start", "║ %s juega %s" % [player_str, card_str], {
			"block_id": block_id,
			"card": block.card_name,
			"player": player_id,
			"via_exhumar": true
		})
		_main.add_entry("block_start", "║ [color=#9C27B0]💀 Desde CEMENTERIO → Destino: DESTIERRO[/color]", {
			"block_id": block_id,
			"source": "cemetery",
			"destination": "exile"
		})
	else:
		_main.add_entry("block_start", "║ %s juega %s" % [player_str, card_str], {
			"block_id": block_id,
			"card": block.card_name,
			"player": player_id
		})

	# Mostrar cálculo de coste TRANSPARENTE
	_log_cost_breakdown(block)

	_main.add_entry("block_start", "╠══════════════════════════════════════════════╣", {
		"block_id": block_id
	})

	_main.emit_signal("action_block_started", block)

	# Broadcast para oponente
	_broadcast_detailed_play(block)

	return block_id


func _log_cost_breakdown(block: ActionBlock) -> void:
	"""Loguea el desglose de coste de forma transparente

	CRÍTICO: El oponente debe ver el coste total para saber si
	'Hacer el Bien' (anula coste ≤3) puede aplicarse.
	"""
	var breakdown = block.cost_breakdown
	var block_id = block.id

	if block.has_x_cost:
		# Coste variable X - mostrar cálculo completo
		var formula = breakdown.get("formula", "X")
		var base = breakdown.get("base_cost", 0)
		var x_val = breakdown.get("x_value", 0)
		var mult = breakdown.get("x_multiplier", 1)
		var total = breakdown.get("total", 0)

		_main.add_entry("block_cost", "║ [color=#FFD700]💰 COSTE VARIABLE[/color]", {
			"block_id": block_id
		})

		# Mostrar fórmula
		_main.add_entry("block_cost", "║    Fórmula: [color=#FFA500]%s[/color]" % formula, {
			"block_id": block_id
		})

		# Mostrar cálculo paso a paso
		if mult > 1:
			_main.add_entry("block_cost", "║    X elegido: [color=#4CAF50]%d[/color] × %d = %d" % [
				x_val, mult, x_val * mult
			], {"block_id": block_id})
		else:
			_main.add_entry("block_cost", "║    X elegido: [color=#4CAF50]%d[/color]" % x_val, {
				"block_id": block_id
			})

		if base > 0:
			_main.add_entry("block_cost", "║    Coste base: +%d" % base, {"block_id": block_id})

		# COSTE TOTAL - VISIBLE PARA AMBOS JUGADORES
		var total_color = "#4CAF50" if total <= 3 else "#FFD700"
		var annul_warning = ""
		if total <= 3:
			annul_warning = " [color=#FF5722](⚠ Anulable por 'Hacer el Bien')[/color]"

		_main.add_entry("block_cost", "║ ═══════════════════════════════════════════", {
			"block_id": block_id
		})
		_main.add_entry("block_cost", "║    [b]COSTE TOTAL: [color=%s]%d ORO[/color][/b]%s" % [
			total_color, total, annul_warning
		], {
			"block_id": block_id,
			"total_cost": total,
			"can_hacer_el_bien": total <= 3
		})
	else:
		# Coste fijo normal
		var total = breakdown.get("total", 0)
		var total_color = "#4CAF50" if total <= 3 else "#FFD700"
		var annul_warning = ""
		if total <= 3:
			annul_warning = " [color=#FF5722](⚠ Anulable por 'Hacer el Bien')[/color]"

		_main.add_entry("block_cost", "║ [color=#FFD700]💰 COSTE:[/color] [color=%s][b]%d ORO[/b][/color]%s" % [
			total_color, total, annul_warning
		], {
			"block_id": block_id,
			"total_cost": total,
			"can_hacer_el_bien": total <= 3
		})


func add_block_step(block_id: int, step_type: String, message: String, data: Dictionary = {}) -> void:
	"""Agrega un paso al bloque de acción

	Args:
		block_id: ID del bloque
		step_type: Tipo de paso (A, B, C, D, E, resolution, etc.)
		message: Mensaje del paso
		data: Datos adicionales
	"""
	if not _active_blocks.has(block_id):
		# Si no hay bloque, loguear normalmente
		_main.add_entry(step_type, message, data)
		return

	var block = _active_blocks[block_id] as ActionBlock

	var step = {
		"type": step_type,
		"message": message,
		"data": data,
		"timestamp": Time.get_unix_time_from_system()
	}

	block.steps.append(step)

	# Formatear según tipo de paso
	var step_prefix = _get_step_prefix(step_type)
	_main.add_entry("block_step", "║ %s %s" % [step_prefix, message], {
		"block_id": block_id,
		"step_type": step_type,
		"data": data
	})

	_main.emit_signal("action_block_step_added", block, step)


func _get_step_prefix(step_type: String) -> String:
	"""Obtiene prefijo visual para tipo de paso"""
	match step_type.to_upper():
		"A", "STEP_A", "DECLARATION":
			return "[color=#64B5F6]A →[/color]"
		"B", "STEP_B", "PAYMENT":
			return "[color=#FFD700]B →[/color]"
		"C", "STEP_C", "TRIGGERS":
			return "[color=#BA68C8]C →[/color]"
		"D", "STEP_D", "RESPONSE":
			return "[color=#FF9800]D →[/color]"
		"E", "STEP_E", "RESOLUTION":
			return "[color=#4CAF50]E →[/color]"
		"TARGET":
			return "[color=#03A9F4]🎯[/color]"
		"EFFECT":
			return "[color=#E91E63]⚡[/color]"
		"ANNUL":
			return "[color=#FF5722]🚫[/color]"
		_:
			return "[color=#9E9E9E]•[/color]"


func complete_block(block_id: int, success: bool = true, result: Dictionary = {}) -> void:
	"""Completa un bloque de acción

	Args:
		block_id: ID del bloque
		success: Si la carta se resolvió exitosamente
		result: Resultados de la resolución
	"""
	if not _active_blocks.has(block_id):
		return

	var block = _active_blocks[block_id] as ActionBlock

	# Footer del bloque
	if block.was_annulled:
		_main.add_entry("block_end", "║ [color=#FF5722]🚫 ANULADO por %s[/color]" % _main._formatters.format_card(block.annuller_name), {
			"block_id": block_id
		})
	elif success:
		_main.add_entry("block_end", "║ [color=#4CAF50]✓ RESUELTO[/color]", {
			"block_id": block_id,
			"result": result
		})
		# Indicar destino final si es Exhumar
		if block.via_exhumar:
			_main.add_entry("block_end", "║ [color=#9C27B0]→ Destino: DESTIERRO (vía Exhumar)[/color]", {
				"block_id": block_id,
				"destination": "destierro",
				"via_exhumar": true
			})
	else:
		_main.add_entry("block_end", "║ [color=#F44336]✗ FALLÓ[/color]", {
			"block_id": block_id,
			"result": result
		})

	_main.add_entry("block_end", "╚══════════════════════════════════════════════╝", {
		"block_id": block_id
	})

	_main.emit_signal("action_block_completed", block)

	# Broadcast resultado
	_broadcast_block_complete(block, success, result)

	# Limpiar
	_active_blocks.erase(block_id)


func annul_block(block_id: int, annuller_name: String, reason: String = "") -> void:
	"""Marca un bloque como anulado

	Args:
		block_id: ID del bloque
		annuller_name: Nombre de la carta que anula
		reason: Razón de la anulación
	"""
	if not _active_blocks.has(block_id):
		return

	var block = _active_blocks[block_id] as ActionBlock
	block.was_annulled = true
	block.annuller_name = annuller_name

	var reason_text = ""
	if not reason.is_empty():
		reason_text = " (%s)" % reason

	add_block_step(block_id, "ANNUL", "[color=#FF5722]%s ANULA a %s%s[/color]" % [
		_main._formatters.format_card(annuller_name),
		_main._formatters.format_card(block.card_name),
		reason_text
	], {
		"annuller": annuller_name,
		"target": block.card_name,
		"reason": reason
	})

	_main.emit_signal("action_block_annulled", block, annuller_name)

	# Broadcast anulación
	_broadcast_block_annulled(block, annuller_name, reason)


func get_active_block(block_id: int) -> ActionBlock:
	"""Obtiene un bloque activo por ID"""
	return _active_blocks.get(block_id)


func get_block_cost(block_id: int) -> int:
	"""Obtiene el coste total de un bloque (para verificar 'Hacer el Bien')"""
	if not _active_blocks.has(block_id):
		return -1

	var block = _active_blocks[block_id] as ActionBlock
	return block.total_cost


func can_hacer_el_bien(block_id: int) -> bool:
	"""Verifica si 'Hacer el Bien' puede anular este bloque

	Hacer el Bien anula cartas con coste ≤ 3.
	"""
	var cost = get_block_cost(block_id)
	return cost >= 0 and cost <= 3


# =============================================================================
# EFECTOS PARCIALES - "En medida de lo posible" (DAR Sección 6)
# =============================================================================
func log_partial_effect(effect_type: String, requested: int, actual: int, target_name: String = "", context: Dictionary = {}) -> void:
	"""Loguea un efecto que se resolvió parcialmente

	Según DAR Sección 6: Los efectos se resuelven "en medida de lo posible".
	Si el oponente tiene menos cartas que X, se botan las disponibles.

	Args:
		effect_type: Tipo de efecto (mill, draw, damage, etc.)
		requested: Cantidad solicitada (valor de X)
		actual: Cantidad real ejecutada
		target_name: Nombre del objetivo (jugador, carta, etc.)
		context: Datos adicionales
	"""
	if actual >= requested:
		# Efecto completo, no es parcial
		return

	var effect_name = _effect_type_to_spanish(effect_type)
	var target_str = target_name if not target_name.is_empty() else "objetivo"

	# ─────────────────────────────────────────────────────────────────────────
	# Formato: "Botando [Actual] de X (en medida de lo posible)"
	# ─────────────────────────────────────────────────────────────────────────
	var message = "[color=#FFC107]⚠ %s [%d] de %d a %s[/color] [color=#888888](en medida de lo posible)[/color]" % [
		effect_name,
		actual,
		requested,
		target_str
	]

	_main.add_entry("partial_effect", message, {
		"effect_type": effect_type,
		"requested": requested,
		"actual": actual,
		"target": target_name,
		"partial": true,
		"context": context
	})

	# Broadcast a ambos jugadores
	_broadcast_partial_effect(effect_type, requested, actual, target_name)


func log_partial_mill(requested: int, actual: int, player_id: int, cards_milled: Array = []) -> void:
	"""Log específico para Botar/Mill parcial

	Ejemplo: "Botando [3] de 5 (en medida de lo posible)"
	"""
	var player_str = _main._formatters.format_player(player_id)
	var card_names = _main._formatters.get_card_names(cards_milled) if not cards_milled.is_empty() else []

	var message = "[color=#FFC107]⚠ Botando [%d] de %d cartas de %s[/color] [color=#888888](en medida de lo posible)[/color]" % [
		actual, requested, player_str
	]

	if not card_names.is_empty():
		message += "\n    → %s" % _main._formatters.format_card_list(card_names)

	_main.add_entry("partial_mill", message, {
		"effect_type": "mill",
		"requested": requested,
		"actual": actual,
		"player": player_id,
		"cards": card_names,
		"partial": true
	})

	_broadcast_partial_effect("mill", requested, actual, "Jugador %d" % (player_id + 1))


func log_partial_draw(requested: int, actual: int, player_id: int) -> void:
	"""Log específico para Robar parcial (mazo vacío)"""
	var player_str = _main._formatters.format_player(player_id)

	var message = "[color=#FFC107]⚠ Robando [%d] de %d cartas para %s[/color] [color=#888888](mazo agotado)[/color]" % [
		actual, requested, player_str
	]

	_main.add_entry("partial_draw", message, {
		"effect_type": "draw",
		"requested": requested,
		"actual": actual,
		"player": player_id,
		"partial": true
	})

	_broadcast_partial_effect("draw", requested, actual, "Jugador %d" % (player_id + 1))


func log_partial_damage(requested: int, actual: int, target_name: String, reason: String = "") -> void:
	"""Log específico para Daño parcial"""
	var reason_str = ""
	if not reason.is_empty():
		reason_str = " [color=#888888](%s)[/color]" % reason

	var message = "[color=#FFC107]⚠ Infligiendo [%d] de %d daño a %s%s[/color]" % [
		actual, requested, _main._formatters.format_card(target_name), reason_str
	]

	_main.add_entry("partial_damage", message, {
		"effect_type": "damage",
		"requested": requested,
		"actual": actual,
		"target": target_name,
		"reason": reason,
		"partial": true
	})

	_broadcast_partial_effect("damage", requested, actual, target_name)


func log_x_effect_result(effect_type: String, x_value: int, actual: int, target_name: String, success: bool = true) -> void:
	"""Log del resultado de un efecto con X

	Muestra claramente cuánto del efecto X se resolvió.
	"""
	var effect_name = _effect_type_to_spanish(effect_type)

	if actual >= x_value:
		# Efecto completo
		var message = "[color=#4CAF50]✓ %s %d a %s (X=%d)[/color]" % [
			effect_name, actual, target_name, x_value
		]
		_main.add_entry("x_effect", message, {
			"effect_type": effect_type,
			"x_value": x_value,
			"actual": actual,
			"target": target_name,
			"complete": true
		})
	else:
		# Efecto parcial
		var message = "[color=#FFC107]⚠ %s [%d] de X=%d a %s[/color] [color=#888888](en medida de lo posible)[/color]" % [
			effect_name, actual, x_value, target_name
		]
		_main.add_entry("x_effect_partial", message, {
			"effect_type": effect_type,
			"x_value": x_value,
			"actual": actual,
			"target": target_name,
			"complete": false,
			"partial": true
		})


func _effect_type_to_spanish(effect_type: String) -> String:
	"""Convierte tipo de efecto a verbo en español (gerundio)"""
	match effect_type.to_lower():
		"mill", "botar": return "Botando"
		"draw", "robar": return "Robando"
		"discard", "descartar": return "Descartando"
		"damage", "daño": return "Infligiendo"
		"destroy", "destruir": return "Destruyendo"
		"banish", "desterrar": return "Desterrando"
		"heal", "curar": return "Curando"
		"buff", "fortalecer": return "Fortaleciendo"
		"debuff", "debilitar": return "Debilitando"
		_: return "Aplicando"


func _broadcast_partial_effect(effect_type: String, requested: int, actual: int, target: String) -> void:
	"""Broadcast efecto parcial a ambos jugadores"""
	var sync_data = {
		"type": "partial_effect",
		"effect_type": effect_type,
		"requested": requested,
		"actual": actual,
		"target": target,
		"turn": _main._current_turn,
		"phase": _main._current_phase_name
	}

	_main.emit_signal("public_action_occurred", sync_data)
	_main.emit_signal("sync_to_opponent", "partial_effect", sync_data)


# =============================================================================
# BROADCASTING - BLOQUES DE ACCIÓN
# =============================================================================
func _broadcast_detailed_play(block: ActionBlock) -> void:
	"""Broadcast inicio de jugada detallada"""
	var sync_data = {
		"type": "detailed_play_start",
		"block_id": block.id,
		"card_name": block.card_name,
		"display_name": block.display_name,
		"player_id": block.player_id,
		"has_x_cost": block.has_x_cost,
		"instance_x": block.instance_x,
		"total_cost": block.total_cost,
		"cost_breakdown": block.cost_breakdown,
		"can_hacer_el_bien": block.total_cost <= 3,
		"via_exhumar": block.via_exhumar,
		"destination_if_exhumar": "destierro" if block.via_exhumar else "cementerio",
		"turn": _main._current_turn,
		"phase": _main._current_phase_name
	}

	_main.emit_signal("public_action_occurred", sync_data)
	_main.emit_signal("sync_to_opponent", "detailed_play_start", sync_data)


func _broadcast_block_complete(block: ActionBlock, success: bool, result: Dictionary) -> void:
	"""Broadcast finalización de bloque"""
	var sync_data = {
		"type": "detailed_play_complete",
		"block_id": block.id,
		"card_name": block.card_name,
		"success": success,
		"was_annulled": block.was_annulled,
		"annuller": block.annuller_name,
		"result": result,
		"steps_count": block.steps.size()
	}

	_main.emit_signal("public_action_occurred", sync_data)
	_main.emit_signal("sync_to_opponent", "detailed_play_complete", sync_data)


func _broadcast_block_annulled(block: ActionBlock, annuller: String, reason: String) -> void:
	"""Broadcast anulación de bloque"""
	var sync_data = {
		"type": "detailed_play_annulled",
		"block_id": block.id,
		"card_name": block.card_name,
		"total_cost": block.total_cost,
		"annuller": annuller,
		"reason": reason
	}

	_main.emit_signal("public_action_occurred", sync_data)
	_main.emit_signal("sync_to_opponent", "detailed_play_annulled", sync_data)


# =============================================================================
# LOG DE COSTE X SIMPLIFICADO (Para uso externo)
# =============================================================================
func log_x_cost_selection(card_name: String, player_id: int, x_value: int, total_cost: int, formula: String = "X") -> void:
	"""Loguea la selección de valor X de forma transparente

	Llamar desde PaymentManager cuando se confirma el valor de X.
	"""
	var player_str = _main._formatters.format_player(player_id)
	var card_str = _main._formatters.format_card(card_name)

	var annul_warning = ""
	if total_cost <= 3:
		annul_warning = " [color=#FF5722](⚠ Anulable)[/color]"

	_main.add_entry("cost", "%s elige [color=#4CAF50]X = %d[/color] para %s" % [
		player_str, x_value, card_str
	], {
		"player": player_id,
		"card": card_name,
		"x_value": x_value
	})

	_main.add_entry("cost", "   [color=#FFD700]Coste:[/color] %s → [b]%d Oro[/b]%s" % [
		formula, total_cost, annul_warning
	], {
		"formula": formula,
		"total_cost": total_cost,
		"can_annul": total_cost <= 3
	})
