extends RefCounted
class_name StackStepResolver
## StackStepResolver — Ejecuta los Pasos A-E de la Pila LIFO (DAR Sección 6)
## para cada objeto de ActionPipeline: declaración, pago, disparo de
## habilidades, ventana de respuesta y resolución. Opera sobre ActionPipeline
## vía _main (estado, señales, consts). Extraído de ActionPipeline.gd
## (Fase 4 de reestructuración) — ActionPipeline.gd es un autoload sin
## class_name (colisionaría con su propio nombre de autoload).

var _main: Node


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# PASO A: DECLARACIÓN
# =============================================================================
func _execute_step_a(stack_obj: Dictionary) -> Dictionary:
	"""Paso A: Declarar carta, objetivos, condiciones"""
	stack_obj.step = _main.StackObjectStep.STEP_A
	stack_obj.step_name = _main.STEP_NAMES[_main.StackObjectStep.STEP_A]

	var result = {"success": true, "reason": ""}
	var card_data = stack_obj.card_data
	var context = stack_obj.context

	print("[ActionPipeline] [%s] Paso A: Declaración" % stack_obj.name)

	# Verificar que puede jugarse
	var controller_id = context.get("controller_id", 0)
	var card_type = card_data.get("tipo", -1)

	# Validar fase
	var phase = GameManager.current_phase
	if card_type == Constants.CardType.TALISMAN:
		if phase not in [Constants.Phase.VIGILIA, Constants.Phase.GUERRA_TALISMANES]:
			result.success = false
			result.reason = "Solo en Vigilia o Guerra de Talismanes"
			return result
	elif stack_obj.type == _main.StackObjectType.CARD_PLAYED:
		if phase != Constants.Phase.VIGILIA:
			result.success = false
			result.reason = "Solo en Fase de Vigilia"
			return result

	# Validar objetivos si se requieren
	var targets = context.get("targets", [])
	stack_obj.targets = targets

	_main.emit_signal("step_a_completed", stack_obj)
	print("[ActionPipeline] [%s] ✓ Paso A completado" % stack_obj.name)

	return result


# =============================================================================
# PASO B: PAGO DE COSTES
# =============================================================================
func _execute_step_b(stack_obj: Dictionary) -> Dictionary:
	"""Paso B: Calcular y pagar costes"""
	stack_obj.step = _main.StackObjectStep.STEP_B
	stack_obj.step_name = _main.STEP_NAMES[_main.StackObjectStep.STEP_B]

	var result = {"success": true, "reason": ""}
	var card_data = stack_obj.card_data
	var context = stack_obj.context
	var controller_id = context.get("controller_id", 0)

	print("[ActionPipeline] [%s] Paso B: Pago" % stack_obj.name)

	# ─────────────────────────────────────────────────────────────────────────
	# Detectar Coste Variable X
	# ─────────────────────────────────────────────────────────────────────────
	var has_x_cost = card_data.get("x_value", -1) >= 0
	var x_value = card_data.get("x_value", 0)
	var x_total_cost = card_data.get("x_total_cost", -1)

	var base_cost = 0
	var final_cost = 0

	if has_x_cost and x_total_cost >= 0:
		# Usar el coste total ya calculado por PaymentManager
		final_cost = x_total_cost
		base_cost = final_cost
		stack_obj["x_value"] = x_value
		print("[ActionPipeline] [%s] Coste X=%d (Total: %d)" % [stack_obj.name, x_value, final_cost])
	else:
		# Coste normal
		base_cost = card_data.get("coste", 0)
		if base_cost is String:
			# Coste variable no procesado - debería haber pasado por PaymentManager
			push_warning("[ActionPipeline] Coste variable '%s' sin procesar" % base_cost)
			base_cost = 0
		final_cost = base_cost

	# ─────────────────────────────────────────────────────────────────────────
	# Aplicar modificadores de coste
	# ─────────────────────────────────────────────────────────────────────────
	if TriggerSystem.has_method("get_cost_modifiers"):
		var mods = TriggerSystem.get_cost_modifiers(card_data, context)
		stack_obj.cost_modifiers = mods
		for mod in mods:
			var val = mod.get("value", 0)
			if mod.get("type", "") == "add":
				final_cost += val
			elif mod.get("type", "") == "subtract":
				final_cost -= val

	# Mínimo 1 (si tenía coste, no aplica a coste X=0)
	if not has_x_cost and base_cost > 0 and final_cost < 1:
		final_cost = 1

	# ─────────────────────────────────────────────────────────────────────────
	# Pagar
	# ─────────────────────────────────────────────────────────────────────────
	if final_cost > 0 and ActionModule.has_method("pay_gold"):
		var payment = ActionModule.pay_gold(controller_id, final_cost)
		if not payment.get("success", false):
			result.success = false
			result.reason = "Oro insuficiente"
			return result

	stack_obj.cost_paid = final_cost

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE PASO B EN BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var block_id = stack_obj.get("log_block_id", -1)
	if block_id >= 0 and CombatLog.has_method("add_block_step"):
		if has_x_cost:
			CombatLog.add_block_step(block_id, "B", "Pagado: %d Oro (X=%d)" % [
				final_cost, x_value
			], {"cost": final_cost, "x_value": x_value})
		else:
			CombatLog.add_block_step(block_id, "B", "Pagado: %d Oro" % final_cost, {
				"cost": final_cost
			})

	_main.emit_signal("step_b_completed", stack_obj, final_cost)
	print("[ActionPipeline] [%s] ✓ Paso B completado (Pagado: %d)" % [stack_obj.name, final_cost])

	return result


# =============================================================================
# PASO C: DISPARAR HABILIDADES (Añadir a la Pila, NO resolver)
# =============================================================================
func _execute_step_c(stack_obj: Dictionary) -> Dictionary:
	"""Paso C: Disparar habilidades → Añadirlas a la Pila

	IMPORTANTE: Las habilidades NO se resuelven aquí.
	Se añaden al tope de la pila y tendrán su propia ventana de prioridad.
	"""
	stack_obj.step = _main.StackObjectStep.STEP_C
	stack_obj.step_name = _main.STEP_NAMES[_main.StackObjectStep.STEP_C]

	var result = {"triggers_added": 0}
	var card_data = stack_obj.card_data
	var context = stack_obj.context
	var controller_id = context.get("controller_id", 0)
	var opponent_id = 1 - controller_id

	print("[ActionPipeline] [%s] Paso C: Disparar habilidades" % stack_obj.name)

	# Evento para triggers
	var event_data = {
		"event_type": "on_card_played",
		"card": card_data,
		"card_name": stack_obj.name,
		"card_type": card_data.get("tipo", -1),
		"controller_id": controller_id,
		"targets": stack_obj.targets,
		"stack_id": stack_obj.id
	}

	# ─────────────────────────────────────────────────────────────────────────
	# Recopilar habilidades disparadas (jugador activo primero, luego oponente)
	# ─────────────────────────────────────────────────────────────────────────
	var triggered_abilities: Array = []

	# Jugador activo primero (DAR Sección 6.C)
	if TriggerSystem.has_method("get_triggered_abilities"):
		var active_triggers = TriggerSystem.get_triggered_abilities(controller_id, "on_card_played", event_data)
		triggered_abilities.append_array(active_triggers)

		var opponent_triggers = TriggerSystem.get_triggered_abilities(opponent_id, "on_card_played", event_data)
		triggered_abilities.append_array(opponent_triggers)

	# ─────────────────────────────────────────────────────────────────────────
	# Añadir cada habilidad disparada a la Pila (NO resolver)
	# ─────────────────────────────────────────────────────────────────────────
	for trigger in triggered_abilities:
		var trigger_id = _main.add_triggered_ability_to_stack(trigger, card_data, {
			"controller_id": trigger.get("controller_id", controller_id),
			"original_event": event_data
		})
		stack_obj.triggers_generated.append(trigger_id)
		result.triggers_added += 1

	_main.emit_signal("step_c_completed", stack_obj, result.triggers_added)

	if result.triggers_added > 0:
		print("[ActionPipeline] [%s] ✓ Paso C: %d habilidades añadidas a la pila" % [
			stack_obj.name, result.triggers_added
		])
	else:
		print("[ActionPipeline] [%s] ✓ Paso C: Sin habilidades disparadas" % stack_obj.name)

	return result


# =============================================================================
# PASO D: VENTANA DE RESPUESTA (Para cada objeto en la pila)
# =============================================================================
func _execute_step_d(stack_obj: Dictionary) -> Dictionary:
	"""Paso D: Ventana de respuesta para el objeto en el tope

	- Oponente tiene prioridad primero
	- Alternando hasta que ambos pasen
	- Si alguien responde, la respuesta va al tope y reinicia el proceso
	"""
	stack_obj.step = _main.StackObjectStep.STEP_D
	stack_obj.step_name = _main.STEP_NAMES[_main.StackObjectStep.STEP_D]

	var result = {
		"had_response": false,
		"response_object": null
	}

	var controller_id = stack_obj.context.get("controller_id", 0)
	var opponent_id = 1 - controller_id

	if Constants.VERBOSE_DIAG_LOGS:
		print("[ActionPipeline] [%s] Paso D: Ventana de Respuesta" % stack_obj.name)

	_main._is_waiting_priority = true
	_main.emit_signal("step_d_waiting", stack_obj, opponent_id)
	_main.emit_signal("priority_window_opened", stack_obj, opponent_id)

	# ─────────────────────────────────────────────────────────────────────────
	# Abrir ventana de prioridad (oponente primero)
	# ─────────────────────────────────────────────────────────────────────────
	# 2026-09-11 (bug real reportado por el usuario: la consola mostraba
	# "Guerra de Talismanes" al resolver Paso D de una habilidad cualquiera,
	# sin relación con esa fase). El número mágico "1" no es RESPONSE_WINDOW
	# — el enum real es NONE=0, GUERRA_TALISMANES=1, RESPONSE_WINDOW=2,
	# DISCARD_PHASE=3, BLOCK_DECLARATION=4 (PriorityManager.gd) — así que esta
	# ventana se abría con el contexto equivocado. Sin impacto en quién tiene
	# prioridad primero (aquí siempre se pasa starting_player explícito) ni en
	# valid_actions (sin llamadores reales hoy), pero sí rompía el auto-pase
	# "no hay nada que decidir" del humano (PhaseFlowController._on_priority_
	# changed_glow()), que a propósito solo actúa en RESPONSE_WINDOW real para
	# no auto-pasar una Guerra de Talismanes genuina.
	PriorityManager.start_priority_window(PriorityManager.PriorityContext.RESPONSE_WINDOW, opponent_id)

	# ─────────────────────────────────────────────────────────────────────────
	# Esperar hasta que ambos pasen o alguien responda
	# ─────────────────────────────────────────────────────────────────────────
	var wait_result = await _wait_for_priority_on_stack_object(stack_obj)

	_main._is_waiting_priority = false

	result.had_response = wait_result.had_response
	if wait_result.had_response:
		result.response_object = wait_result.response_object

	_main.emit_signal("step_d_completed", stack_obj, result.had_response)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE PASO D EN BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var block_id = stack_obj.get("log_block_id", -1)
	if block_id >= 0 and CombatLog.has_method("add_block_step"):
		if result.had_response:
			CombatLog.add_block_step(block_id, "D", "Ventana de respuesta: [color=#FF9800]Respuesta recibida[/color]", {
				"had_response": true
			})
		else:
			CombatLog.add_block_step(block_id, "D", "Ventana de respuesta: [color=#4CAF50]Ambos pasaron[/color]", {
				"had_response": false
			})

	# 2026-09-25, a pedido del usuario ("elimina logs redundantes"): "Ambos
	# pasaron" es el resultado normal en casi TODA resolución (el bot nunca
	# responde nada todavía) — no aporta información nueva repetido en cada
	# carta. Una respuesta real sí es noticia y se mantiene visible.
	if result.had_response:
		print("[ActionPipeline] [%s] Respuesta recibida" % stack_obj.name)
	elif Constants.VERBOSE_DIAG_LOGS:
		print("[ActionPipeline] [%s] ✓ Paso D: Ambos pasaron" % stack_obj.name)

	return result


func _wait_for_priority_on_stack_object(stack_obj: Dictionary) -> Dictionary:
	"""Espera prioridad para un objeto específico de la pila"""
	var result = {
		"had_response": false,
		"response_object": null,
		"was_annulled": false
	}

	var timeout: float = 0.0
	var check_interval: float = 0.1
	var original_stack_size = _main._stack.size()

	while _main._is_waiting_priority:
		await _main.get_tree().create_timer(check_interval).timeout
		timeout += check_interval

		# Verificar si se añadió algo a la pila (respuesta)
		if _main._stack.size() > original_stack_size:
			result.had_response = true
			result.response_object = _main._get_stack_top()
			break

		# Verificar si el objeto fue anulado
		if stack_obj.was_annulled:
			result.was_annulled = true
			break

		# Verificar si PriorityManager cerró la ventana
		if not PriorityManager.priority_window_active:
			break

		# Timeout
		if timeout >= _main.PRIORITY_TIMEOUT:
			print("[ActionPipeline] Timeout de prioridad")
			break

	return result


func _on_priority_both_passed() -> void:
	"""Callback cuando ambos jugadores pasan"""
	if _main._is_waiting_priority:
		_main._is_waiting_priority = false
		_main.emit_signal("both_players_passed_on_stack")


func _on_priority_action_taken(player_id: int, action: Dictionary) -> void:
	"""Callback cuando un jugador toma una acción"""
	if not _main._is_waiting_priority:
		return

	var action_type = action.get("type", "")
	var target_stack_id = action.get("target_stack_id", -1)

	# Determinar qué objeto de la pila es el objetivo
	var target_obj: Dictionary = {}
	if target_stack_id > 0:
		target_obj = _main.get_object_by_id(target_stack_id)
	else:
		target_obj = _main._get_stack_top()

	if target_obj.is_empty():
		return

	match action_type:
		"nullify":
			# ANULAR: La carta/habilidad no se resuelve, va al cementerio
			target_obj.was_annulled = true
			target_obj.annuller = action.get("source_card", {})
			print("[ActionPipeline] ¡%s fue ANULADO!" % target_obj.name)

		"cancel":
			# CANCELAR: El efecto no ocurre (para habilidades principalmente)
			target_obj.was_cancelled = true
			target_obj.cancel_reason = action.get("reason", "cancelled")
			print("[ActionPipeline] ¡%s fue CANCELADO!" % target_obj.name)


# =============================================================================
# PASO E: RESOLUCIÓN
# =============================================================================
func _execute_step_e(stack_obj: Dictionary) -> Dictionary:
	"""Paso E: Resolver el objeto (solo si no fue anulado)"""
	stack_obj.step = _main.StackObjectStep.STEP_E
	stack_obj.step_name = _main.STEP_NAMES[_main.StackObjectStep.STEP_E]

	var result = {
		"success": true,
		"entered_play": false,
		"destination": Constants.Zone.CEMENTERIO,
		"effects_resolved": []
	}

	var card_data = stack_obj.card_data
	var context = stack_obj.context
	var controller_id = context.get("controller_id", 0)

	if Constants.VERBOSE_DIAG_LOGS:
		print("[ActionPipeline] [%s] Paso E: Resolución" % stack_obj.name)

	_main.emit_signal("stack_object_resolving", stack_obj)

	# ─────────────────────────────────────────────────────────────────────────
	# Verificar objetivos válidos (fizzle check)
	# ─────────────────────────────────────────────────────────────────────────
	if not _validate_targets(stack_obj):
		stack_obj.step = _main.StackObjectStep.FIZZLED
		result.success = false
		print("[ActionPipeline] [%s] ✗ Fizzled - objetivos inválidos" % stack_obj.name)
		return result

	# ─────────────────────────────────────────────────────────────────────────
	# Resolver según tipo
	# ─────────────────────────────────────────────────────────────────────────
	match stack_obj.type:
		# CARD_PLAYED/RESPONSE_CARD ya no llegan aquí (2026-08-27, limpieza —
		# ver ActionPipeline.gd: play_card()/add_response_to_stack() se
		# eliminaron, nada los crea más).
		_main.StackObjectType.TRIGGERED_ABILITY, _main.StackObjectType.ACTIVATED_ABILITY:
			result = await _resolve_ability(stack_obj)

	stack_obj.step = _main.StackObjectStep.RESOLVED
	stack_obj.step_name = _main.STEP_NAMES[_main.StackObjectStep.RESOLVED]
	stack_obj.resolved_at = Time.get_ticks_msec()
	stack_obj.resolution_result = result

	_main.emit_signal("stack_object_resolved", stack_obj, result)
	_main.emit_signal("step_e_completed", stack_obj, result)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE PASO E Y COMPLETAR BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var block_id = stack_obj.get("log_block_id", -1)
	if block_id >= 0:
		# Log del paso E
		if CombatLog.has_method("add_block_step"):
			var effects_count = result.get("effects_resolved", []).size()
			CombatLog.add_block_step(block_id, "E", "Resuelto: %d efecto(s)" % effects_count, {
				"effects_count": effects_count
			})

		# Completar bloque
		if CombatLog.has_method("complete_block"):
			CombatLog.complete_block(block_id, result.success, result)

	if Constants.VERBOSE_DIAG_LOGS:
		print("[ActionPipeline] [%s] ✓ Paso E: Resuelto" % stack_obj.name)

	return result


func _validate_targets(stack_obj: Dictionary) -> bool:
	"""Valida que los objetivos sigan siendo válidos (Paso E)

	En Paso E, si el objeto requiere objetivos y ninguno es válido,
	hace fizzle. Si NO requiere objetivos, siempre es válido.
	"""
	# Si no requiere objetivos, es válido
	if not _main._has_required_targets(stack_obj):
		return true

	# Si requiere objetivos, al menos uno debe ser válido
	return _main._has_valid_targets(stack_obj)


func _resolve_ability(stack_obj: Dictionary) -> Dictionary:
	"""Resuelve una habilidad disparada o activada: parsea el texto del efecto
	(stack_obj.card_data.habilidad, que activate_ability() ya dejó como el
	effect_text de la habilidad) y lo ejecuta vía el mismo resolutor que usan
	los triggers 'al entrar en juego' y los Talismanes (2026-08-27): primero
	los patrones compuestos ("mira/muestra N... elige qué hacer con una de
	ahí"), y si ninguno matchea, extract_action() simple como antes. Antes
	esto último era lo ÚNICO que se probaba aquí — una habilidad ACTIVADA con
	un efecto compuesto nunca resolvía bien, a diferencia de una disparada
	con el mismo texto. Reutiliza selección de objetivo y todos los tipos de
	acción ya conectados (DRAW, DESTROY, BANISH, DISCARD, SHUFFLE, MILL,
	SEARCH, LOOK, REVEAL, BUFF, DEBUFF, SILENCE, ANNUL, PREVENT_DAMAGE) sin
	duplicar nada."""
	var result = {"success": true, "effects_resolved": []}

	var ability_data = stack_obj.card_data
	var context = stack_obj.context
	var effect_text: String = ability_data.get("habilidad", "")
	var source_card_node = context.get("source_card_node")
	var controller_id: int = context.get("controller_id", 0)

	if effect_text.is_empty() or not source_card_node or not is_instance_valid(source_card_node):
		return result

	var resolved: bool = await TriggerSystem.resolve_ability_effect(source_card_node, effect_text, controller_id)
	if resolved:
		result.effects_resolved.append(effect_text)
	else:
		push_warning("[ActionPipeline] No se reconoció ninguna acción en el efecto: %s" % effect_text)

	return result
