extends Node
## ActionPipeline - Pipeline con Pila LIFO (DAR Sección 6)
## Cada carta/habilidad es un objeto en la pila con su propio Paso D
##
## Flujo:
## 1. Carta jugada → Pasos A, B, C → Añadir a Pila
## 2. Habilidades disparadas en C → Añadir al tope de la Pila
## 3. Ventana de Prioridad (D) para el tope de la Pila
## 4. Ambos pasan → Resolver tope (E) → Siguiente objeto
## 5. Pila vacía → Fin

# =============================================================================
# SEÑALES DEL PIPELINE
# =============================================================================
## Pila
signal stack_object_added(stack_object: Dictionary)
signal stack_object_resolving(stack_object: Dictionary)
signal stack_object_resolved(stack_object: Dictionary, result: Dictionary)
signal stack_object_removed(stack_object: Dictionary, reason: String)
signal stack_empty

## Pasos individuales
signal step_a_completed(stack_object: Dictionary)
signal step_b_completed(stack_object: Dictionary, cost_paid: int)
signal step_c_completed(stack_object: Dictionary, triggers_added: int)
signal step_d_waiting(stack_object: Dictionary, priority_player: int)
signal step_d_completed(stack_object: Dictionary, had_response: bool)
signal step_e_completed(stack_object: Dictionary, result: Dictionary)

## Prioridad
signal priority_window_opened(stack_object: Dictionary, player_id: int)
signal priority_passed(player_id: int)
signal both_players_passed_on_stack
signal response_added_to_stack(response: Dictionary)

## Anulación y Cancelación
signal object_annulled(stack_object: Dictionary, annuller: Dictionary)
signal object_cancelled(stack_object: Dictionary)
signal object_fizzled(stack_object: Dictionary)

## Pipeline general
signal pipeline_started
signal pipeline_idle

## Sistema "Puedes": habilidades opcionales requieren confirmación del jugador
signal puedes_confirm_requested(ability_data: Dictionary, context: Dictionary)
signal puedes_responded(accepted: bool)

# =============================================================================
# ENUMS
# =============================================================================
enum StackObjectType {
	CARD_PLAYED,        # Carta siendo jugada
	TRIGGERED_ABILITY,  # Habilidad disparada
	ACTIVATED_ABILITY,  # Habilidad activada
	RESPONSE_CARD       # Carta de respuesta (talismán, anulación)
}

enum StackObjectStep {
	PENDING,           # Esperando entrar a la pila
	STEP_A,            # Declaración
	STEP_B,            # Pago de costes
	STEP_C,            # Disparar habilidades (añade más a la pila)
	ON_STACK,          # En la pila, esperando Paso D
	STEP_D,            # Ventana de respuesta activa
	STEP_E,            # Resolviendo
	RESOLVED,          # Resuelto exitosamente
	ANNULLED,          # Anulado
	FIZZLED            # Falló (objetivos inválidos)
}

const STEP_NAMES: Dictionary = {
	StackObjectStep.PENDING: "Pendiente",
	StackObjectStep.STEP_A: "A: Declaración",
	StackObjectStep.STEP_B: "B: Pago",
	StackObjectStep.STEP_C: "C: Triggers",
	StackObjectStep.ON_STACK: "En Pila",
	StackObjectStep.STEP_D: "D: Respuesta",
	StackObjectStep.STEP_E: "E: Resolución",
	StackObjectStep.RESOLVED: "Resuelto",
	StackObjectStep.ANNULLED: "Anulado",
	StackObjectStep.FIZZLED: "Falló"
}

const TYPE_NAMES: Dictionary = {
	StackObjectType.CARD_PLAYED: "Carta",
	StackObjectType.TRIGGERED_ABILITY: "Habilidad Disparada",
	StackObjectType.ACTIVATED_ABILITY: "Habilidad Activada",
	StackObjectType.RESPONSE_CARD: "Respuesta"
}

# =============================================================================
# LA PILA (THE STACK) - LIFO
# =============================================================================
## Pila principal - Array de StackObjects
## El índice 0 es el FONDO, el último índice es el TOPE
var _stack: Array[Dictionary] = []

## Contador de IDs únicos para objetos de la pila
var _stack_id_counter: int = 0

## Estado actual de la pila
var _is_resolving: bool = false
var _is_waiting_priority: bool = false
var _current_priority_player: int = -1

# =============================================================================
# TRACKING DE HABILIDADES ACTIVADAS ("Una vez por turno")
# =============================================================================
## Clave: "{card_id}_{ability_index}"  →  turno en que se usó por última vez
var _ability_usage: Dictionary = {}

# =============================================================================
# REFERENCIAS
# =============================================================================
var _game_manager: Node = null
var _trigger_system: Node = null
var _action_module: Node = null
var _keyword_manager: Node = null
var _priority_manager: Node = null
var _combat_log: Node = null

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
const PRIORITY_TIMEOUT: float = 30.0


func _ready() -> void:
	call_deferred("_get_references")
	call_deferred("_connect_signals")
	print("[ActionPipeline] Inicializado - Sistema de Pila LIFO (DAR Sección 6)")


func _get_references() -> void:
	_game_manager = get_node_or_null("/root/GameManager")
	_trigger_system = get_node_or_null("/root/TriggerSystem")
	_action_module = get_node_or_null("/root/ActionModule")
	_keyword_manager = get_node_or_null("/root/KeywordManager")
	_priority_manager = get_node_or_null("/root/PriorityManager")
	_combat_log = get_node_or_null("/root/CombatLog")


func _connect_signals() -> void:
	if _priority_manager:
		if _priority_manager.has_signal("both_players_passed"):
			_priority_manager.both_players_passed.connect(_on_priority_both_passed)
		if _priority_manager.has_signal("action_taken"):
			_priority_manager.action_taken.connect(_on_priority_action_taken)
	# Resetear uso de habilidades al inicio de cada turno.
	# GameManager es el único conductor de turnos (ver consolidación 2026-08-19).
	if GameManager and GameManager.has_signal("turn_started"):
		GameManager.turn_started.connect(_reset_ability_usage)


# =============================================================================
# CREAR OBJETOS DE PILA
# =============================================================================
func _create_stack_object(type: StackObjectType, data: Dictionary, context: Dictionary) -> Dictionary:
	"""Crea un nuevo objeto para la pila con ID único"""
	_stack_id_counter += 1

	# ─────────────────────────────────────────────────────────────────────────
	# INSTANCE_X: Valor de X inyectado desde XValueSelector
	# Prioridad: data.instance_x > data.x_value > context.x_value
	# ─────────────────────────────────────────────────────────────────────────
	var instance_x = data.get("instance_x", data.get("x_value", context.get("x_value", -1)))
	var x_total_cost = data.get("x_total_cost", context.get("x_total_cost", -1))
	var has_x = instance_x >= 0

	var stack_obj = {
		# Identificación
		"id": _stack_id_counter,
		"type": type,
		"type_name": TYPE_NAMES.get(type, "Desconocido"),

		# Datos de la carta/habilidad
		"card_data": data.duplicate(true),
		"name": _get_name_from_data(data),
		"context": context.duplicate(true),

		# Estado del pipeline
		"step": StackObjectStep.PENDING,
		"step_name": STEP_NAMES[StackObjectStep.PENDING],

		# Objetivos y costes
		"targets": context.get("targets", []),
		"cost_paid": 0,
		"cost_modifiers": [],

		# ─────────────────────────────────────────────────────────────────────
		# COSTE VARIABLE X - instance_x es el valor canónico
		# ─────────────────────────────────────────────────────────────────────
		"instance_x": instance_x,       # Valor inyectado (canónico)
		"x_value": instance_x,          # Alias para compatibilidad
		"x_total_cost": x_total_cost,
		"has_x_cost": has_x,

		# Resultados
		"triggers_generated": [],
		"was_annulled": false,
		"was_cancelled": false,
		"was_fizzled": false,
		"annuller": null,
		"cancel_reason": "",
		"resolution_result": {},

		# Timestamps
		"created_at": Time.get_ticks_msec(),
		"resolved_at": 0
	}

	# Inyectar instance_x también en card_data para que EffectCommands lo vean
	if has_x:
		stack_obj.card_data["instance_x"] = instance_x

	return stack_obj


func _get_name_from_data(data: Dictionary) -> String:
	"""Extrae el nombre de los datos"""
	if data.has("nombre"):
		return str(data.nombre)
	if data.has("name"):
		return str(data.name)
	if data.has("ability_name"):
		return str(data.ability_name)
	if data.has("source_name"):
		return str(data.source_name)
	return "???"


# =============================================================================
# API PRINCIPAL - JUGAR CARTA
# =============================================================================
func play_card(card_data: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Inicia el proceso de jugar una carta

	La carta pasa por A → B → C y luego se añade a la pila.
	Las habilidades disparadas en C también van a la pila.
	Luego se procesan ventanas de prioridad y resolución LIFO.

	Returns: {success, stack_id, reason}
	"""
	var result = {
		"success": false,
		"stack_id": -1,
		"reason": ""
	}

	print("[ActionPipeline] ══════════════════════════════════════")
	print("[ActionPipeline] JUGANDO CARTA: %s" % _get_name_from_data(card_data))

	# Crear objeto de pila
	var stack_obj = _create_stack_object(StackObjectType.CARD_PLAYED, card_data, context)
	result.stack_id = stack_obj.id

	# ─────────────────────────────────────────────────────────────────────────
	# PASO A: Declaración
	# ─────────────────────────────────────────────────────────────────────────
	var step_a = await _execute_step_a(stack_obj)
	if not step_a.success:
		result.reason = step_a.reason
		return result

	# ─────────────────────────────────────────────────────────────────────────
	# PASO B: Pago de costes
	# ─────────────────────────────────────────────────────────────────────────
	var step_b = await _execute_step_b(stack_obj)
	if not step_b.success:
		result.reason = step_b.reason
		return result

	# ─────────────────────────────────────────────────────────────────────────
	# PASO C: Disparar habilidades → Añadir a la Pila (NO resolver)
	# ─────────────────────────────────────────────────────────────────────────
	var step_c = await _execute_step_c(stack_obj)
	# Step C añade triggers a la pila, pero no los resuelve

	# ─────────────────────────────────────────────────────────────────────────
	# Añadir carta a la Pila
	# ─────────────────────────────────────────────────────────────────────────
	_add_to_stack(stack_obj)

	# ─────────────────────────────────────────────────────────────────────────
	# Procesar la Pila (Paso D recursivo + Resolución LIFO)
	# ─────────────────────────────────────────────────────────────────────────
	await _process_stack()

	# Buscar resultado de nuestra carta
	result.success = stack_obj.step == StackObjectStep.RESOLVED
	if stack_obj.was_annulled:
		result.reason = "Carta anulada"
	elif stack_obj.step == StackObjectStep.FIZZLED:
		result.reason = "Objetivos inválidos"

	return result


# =============================================================================
# AÑADIR OBJETOS A LA PILA
# =============================================================================
func _add_to_stack(stack_obj: Dictionary) -> void:
	"""Añade un objeto al tope de la pila"""
	stack_obj.step = StackObjectStep.ON_STACK
	stack_obj.step_name = STEP_NAMES[StackObjectStep.ON_STACK]

	_stack.append(stack_obj)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DETALLADO: Usar bloques de acción de CombatLog
	# ─────────────────────────────────────────────────────────────────────────
	var player_id = stack_obj.context.get("controller_id", 0)
	var card_data = stack_obj.card_data.duplicate(true)

	# Inyectar info de X en card_data para el bloque
	if stack_obj.has_x_cost:
		card_data["instance_x"] = stack_obj.instance_x
		card_data["x_value"] = stack_obj.instance_x
		card_data["x_total_cost"] = stack_obj.x_total_cost

	# Crear bloque de acción detallado en CombatLog
	var block_id = -1
	if _combat_log and _combat_log.has_method("log_detailed_play"):
		block_id = _combat_log.log_detailed_play(card_data, player_id)
		stack_obj["log_block_id"] = block_id

	# Console log
	if stack_obj.has_x_cost and stack_obj.instance_x >= 0:
		print("[ActionPipeline] ┌─ PILA [%d]: + %s (%s) [X=%d, Coste=%d]" % [
			_stack.size(),
			stack_obj.name,
			stack_obj.type_name,
			stack_obj.instance_x,
			stack_obj.x_total_cost
		])
	else:
		print("[ActionPipeline] ┌─ PILA [%d]: + %s (%s)" % [
			_stack.size(),
			stack_obj.name,
			stack_obj.type_name
		])

	_print_stack_state()

	emit_signal("stack_object_added", stack_obj)


func add_triggered_ability_to_stack(ability_data: Dictionary, source_card: Dictionary, context: Dictionary = {}) -> int:
	"""Añade una habilidad disparada al tope de la pila

	Llamado durante Paso C o cuando se disparan habilidades por eventos.

	Returns: ID del objeto en la pila
	"""
	var ctx = context.duplicate(true)
	ctx["source_card"] = source_card
	ctx["source_name"] = _get_name_from_data(source_card)

	var stack_obj = _create_stack_object(StackObjectType.TRIGGERED_ABILITY, ability_data, ctx)

	# Las habilidades disparadas saltan A y B, van directo a la pila
	stack_obj.step = StackObjectStep.ON_STACK
	stack_obj.step_name = STEP_NAMES[StackObjectStep.ON_STACK]

	_stack.append(stack_obj)

	print("[ActionPipeline] ┌─ PILA [%d]: + Habilidad '%s' (de %s)" % [
		_stack.size(),
		stack_obj.name,
		ctx.get("source_name", "???")
	])

	emit_signal("stack_object_added", stack_obj)

	return stack_obj.id


func add_response_to_stack(card_data: Dictionary, context: Dictionary) -> int:
	"""Añade una carta de respuesta al tope de la pila

	Usado cuando un jugador responde durante Paso D.

	Returns: ID del objeto en la pila
	"""
	var stack_obj = _create_stack_object(StackObjectType.RESPONSE_CARD, card_data, context)

	# Respuestas también pasan por A, B, C
	var step_a = await _execute_step_a(stack_obj)
	if not step_a.success:
		return -1

	var step_b = await _execute_step_b(stack_obj)
	if not step_b.success:
		return -1

	var step_c = await _execute_step_c(stack_obj)

	_add_to_stack(stack_obj)
	emit_signal("response_added_to_stack", stack_obj)

	return stack_obj.id


# =============================================================================
# HABILIDADES ACTIVADAS (DAR Sección 6 — Paso A→B→C→Pila→D→E)
# =============================================================================
func activate_ability(source_card_data: Dictionary, ability_data: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Activa una habilidad activada y la mete en la Pila LIFO.

	Args:
		source_card_data: Datos de la carta que contiene la habilidad
		ability_data: Dict devuelto por UniversalCardParser.get_activated_abilities()
		context: {controller_id, ...}

	Returns: {success: bool, reason: String}
	"""
	var controller_id: int = context.get("controller_id", 0)
	var card_id: String    = str(source_card_data.get("id", ""))
	var ability_index: int = ability_data.get("ability_index", 0)
	var cost_type: int     = ability_data.get("cost_type", UniversalCardParser.CostType.NONE)
	var cost_amount: int   = ability_data.get("cost_amount", 0)

	# ── Sistema "Puedes": confirmar con el jugador antes de pagar ────────────
	if ability_data.get("is_optional", false):
		emit_signal("puedes_confirm_requested", ability_data, context)
		var accepted: bool = await puedes_responded
		if not accepted:
			return {"success": false, "reason": "Cancelado por el jugador"}

	# ── Paso A: Validar activación ────────────────────────────────────────────
	var check = can_activate_ability(source_card_data, ability_data, context)
	if not check.can:
		push_warning("[ActionPipeline] No se puede activar habilidad: %s" % check.reason)
		return {"success": false, "reason": check.reason}

	# ── Paso B: Pagar el costo ────────────────────────────────────────────────
	match cost_type:
		UniversalCardParser.CostType.GOLD:
			if _action_module and _action_module.has_method("pay_gold"):
				var payment = _action_module.pay_gold(controller_id, cost_amount)
				if not payment.get("success", false):
					return {"success": false, "reason": "Oro insuficiente"}
		UniversalCardParser.CostType.DISCARD:
			# TODO: abrir selector de carta en mano para descartar
			push_warning("[ActionPipeline] Costo DISCARD no implementado aún")
			return {"success": false, "reason": "Descarte no implementado"}
		UniversalCardParser.CostType.TAP:
			# TODO: girar la carta fuente
			push_warning("[ActionPipeline] Costo TAP no implementado aún")
			return {"success": false, "reason": "Tap no implementado"}
		# ONCE_PER_TURN no tiene costo de recurso, solo la restricción de uso

	# ── Marcar como usada (para "una vez por turno") ──────────────────────────
	if cost_type == UniversalCardParser.CostType.ONCE_PER_TURN or ability_data.get("once_per_turn", false):
		var turn: int = _game_manager.current_turn if _game_manager else 0
		_ability_usage["%s_%d" % [card_id, ability_index]] = turn
		# Registrar también en TurnRegistry del parser para coherencia
		UniversalCardParser.turn_registry.register(card_id, ability_index, turn)

	# ── Crear objeto de pila: la habilidad activada ───────────────────────────
	# Presentamos la habilidad como una "carta" con habilidad = efecto_text
	var ability_as_data = source_card_data.duplicate(true)
	ability_as_data["habilidad"]             = ability_data.get("effect_text", "")
	ability_as_data["coste"]                 = 0      # ya pagado arriba
	ability_as_data["_is_activated_ability"] = true
	ability_as_data["_ability_meta"]         = ability_data.duplicate()

	var ctx = context.duplicate(true)
	ctx["source_card"]           = source_card_data
	ctx["source_name"]           = source_card_data.get("nombre", "???")
	ctx["is_activated_ability"]  = true
	ctx["ability_cost_paid"]     = cost_amount

	var stack_obj = _create_stack_object(StackObjectType.ACTIVATED_ABILITY, ability_as_data, ctx)

	# ── Paso C: Triggers ──────────────────────────────────────────────────────
	await _execute_step_c(stack_obj)

	# ── Añadir al tope de la Pila ─────────────────────────────────────────────
	_add_to_stack(stack_obj)

	print("[ActionPipeline] ✦ Habilidad activada: '%s' de '%s'" % [
		ability_data.get("cost_text", "?"), source_card_data.get("nombre", "?")
	])

	# ── Iniciar procesamiento si la pila no está activa ───────────────────────
	if not _is_resolving:
		_process_stack()

	return {"success": true, "stack_id": stack_obj.id}


func respond_puedes(accepted: bool) -> void:
	"""Respuesta del jugador al diálogo '¿Quieres activar esta habilidad?'
	Llamado desde UIManager tras mostrar el diálogo de confirmación."""
	emit_signal("puedes_responded", accepted)


func can_activate_ability(source_card_data: Dictionary, ability_data: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Comprueba si una habilidad puede activarse ahora.

	Returns: {can: bool, reason: String}
	"""
	var card_id        = str(source_card_data.get("id", ""))
	var ability_index  = ability_data.get("ability_index", 0)
	var cost_type      = ability_data.get("cost_type", UniversalCardParser.CostType.NONE)
	var cost_amount    = ability_data.get("cost_amount", 0)
	var controller_id  = context.get("controller_id", 0)

	# Fase: solo durante Vigilia (para habilidades estándar)
	if _game_manager:
		var phase = _game_manager.current_phase
		if phase != Constants.Phase.VIGILIA:
			return {"can": false, "reason": "Fuera de fase Vigilia"}
		if _game_manager.active_player_id != controller_id:
			return {"can": false, "reason": "No es tu turno"}

	# Una vez por turno: verificar en _ability_usage y en TurnRegistry del parser
	if cost_type == UniversalCardParser.CostType.ONCE_PER_TURN or ability_data.get("once_per_turn", false):
		var turn: int = _game_manager.current_turn if _game_manager else 0
		var key: String = "%s_%d" % [card_id, ability_index]
		var in_local:    bool = _ability_usage.get(key, -1) == turn
		var in_registry: bool = UniversalCardParser.turn_registry.was_used(card_id, ability_index, turn)
		if in_local or in_registry:
			return {"can": false, "reason": "Ya usada este turno"}

	# Oro: verificar si el jugador tiene suficiente
	if cost_type == UniversalCardParser.CostType.GOLD and cost_amount > 0:
		var available := 0
		if _action_module and _action_module.has_method("get_available_gold"):
			available = _action_module.get_available_gold(controller_id)
		else:
			var payment_manager = Engine.get_singleton("PaymentManager") if Engine.has_singleton("PaymentManager") \
				else get_node_or_null("/root/PaymentManager")
			if payment_manager and payment_manager.has_method("_get_player_available_gold"):
				available = payment_manager._get_player_available_gold(controller_id)
		if available < cost_amount:
			return {"can": false, "reason": "Necesitas %d Oro (tienes %d)" % [cost_amount, available]}

	return {"can": true, "reason": ""}


func _reset_ability_usage(_player_id = null, _turn_number = null) -> void:
	"""Resetea el tracking de habilidades al inicio de cada turno."""
	_ability_usage.clear()
	print("[ActionPipeline] Usos de habilidades reseteados para el nuevo turno")


# =============================================================================
# PROCESAR LA PILA (LOOP PRINCIPAL) - Resolución por Capas (DAR 5.C3)
# =============================================================================
func _process_stack() -> void:
	"""Procesa la pila con resolución por capas (DAR Sección 5.C3)

	RESOLUCIÓN POR CAPAS:
	1. Abrir ventana de prioridad para el tope
	2. Si alguien responde → añadir al tope, volver a 1
	3. Ambos pasan consecutivamente → resolver SOLO el tope
	4. Tras resolver, abrir NUEVA ventana de prioridad para el siguiente
	5. Repetir hasta pila vacía

	DETECCIÓN DE OBJETIVOS:
	- Si una habilidad pierde todos sus objetivos → fizzle (eliminar sin resolver)
	- Si es cancelada → eliminar sin ejecutar efectos
	"""
	if _is_resolving:
		push_warning("[ActionPipeline] Ya hay un proceso de pila activo")
		return

	_is_resolving = true
	emit_signal("pipeline_started")

	print("[ActionPipeline] ═══════════════════════════════════════════════")
	print("[ActionPipeline] PROCESANDO PILA - Resolución por Capas (5.C3)")
	print("[ActionPipeline] ═══════════════════════════════════════════════")

	var layer_count = 0

	while not _stack.is_empty():
		layer_count += 1
		var top = _get_stack_top()

		if top.is_empty():
			break

		print("[ActionPipeline] ┌─── CAPA %d: %s ───" % [layer_count, top.name])
		_print_stack_state()

		# ─────────────────────────────────────────────────────────────────────
		# PRE-CHECK: Verificar si el objeto fue cancelado o perdió objetivos
		# ─────────────────────────────────────────────────────────────────────
		var pre_check = _pre_resolution_check(top)
		if pre_check.should_remove:
			await _handle_removed_object(top, pre_check.reason)
			print("[ActionPipeline] └─── CAPA %d: %s (%s) ───" % [layer_count, top.name, pre_check.reason])
			continue

		# ─────────────────────────────────────────────────────────────────────
		# PASO D: Ventana de Prioridad (Sección 6.D)
		# Ambos jugadores deben pasar consecutivamente para resolver
		# ─────────────────────────────────────────────────────────────────────
		var step_d_result = await _execute_step_d(top)

		# Si hubo respuesta, se añadió al tope - nueva capa
		if step_d_result.had_response:
			print("[ActionPipeline] │ → Respuesta añadida al tope")
			print("[ActionPipeline] └─── CAPA %d: Interrumpida ───" % layer_count)
			continue

		# ─────────────────────────────────────────────────────────────────────
		# POST-CHECK: Verificar anulación/cancelación después de Paso D
		# ─────────────────────────────────────────────────────────────────────
		if top.was_annulled:
			await _handle_annulled_object(top)
			print("[ActionPipeline] └─── CAPA %d: Anulada ───" % layer_count)
			continue

		if top.was_cancelled:
			await _handle_cancelled_object(top)
			print("[ActionPipeline] └─── CAPA %d: Cancelada ───" % layer_count)
			continue

		# ─────────────────────────────────────────────────────────────────────
		# VERIFICACIÓN DE OBJETIVOS: Fizzle si perdió todos los objetivos
		# ─────────────────────────────────────────────────────────────────────
		if _should_fizzle(top):
			await _handle_fizzled_object(top)
			print("[ActionPipeline] └─── CAPA %d: Fizzled ───" % layer_count)
			continue

		# ─────────────────────────────────────────────────────────────────────
		# PASO E: Resolver SOLO el tope (ambos pasaron consecutivamente)
		# ─────────────────────────────────────────────────────────────────────
		print("[ActionPipeline] │ ✓ Ambos pasaron → Resolviendo tope")
		await _execute_step_e(top)

		# Remover del tope después de resolver
		_remove_from_stack(top, "resolved")

		print("[ActionPipeline] └─── CAPA %d: Resuelta ───" % layer_count)

		# ─────────────────────────────────────────────────────────────────────
		# NUEVA VENTANA DE PRIORIDAD: Antes de resolver el siguiente (5.C3)
		# ─────────────────────────────────────────────────────────────────────
		if not _stack.is_empty():
			print("[ActionPipeline] │")
			print("[ActionPipeline] │ → Nueva ventana de prioridad (5.C3)")
			# El loop continuará y abrirá Paso D para el nuevo tope

	print("[ActionPipeline] ═══════════════════════════════════════════════")
	print("[ActionPipeline] PILA VACÍA - %d capas procesadas" % layer_count)
	print("[ActionPipeline] ═══════════════════════════════════════════════")

	emit_signal("stack_empty")
	_is_resolving = false
	emit_signal("pipeline_idle")


# =============================================================================
# DETECCIÓN DE OBJETIVOS Y CANCELACIÓN
# =============================================================================
func _pre_resolution_check(stack_obj: Dictionary) -> Dictionary:
	"""Verifica si el objeto debe removerse antes de abrir prioridad

	Returns: {should_remove: bool, reason: String}
	"""
	var result = {"should_remove": false, "reason": ""}

	# Verificar si ya fue marcado como cancelado
	if stack_obj.get("was_cancelled", false):
		result.should_remove = true
		result.reason = "cancelled"
		return result

	# Verificar si perdió todos sus objetivos obligatorios
	if _has_required_targets(stack_obj) and not _has_valid_targets(stack_obj):
		result.should_remove = true
		result.reason = "no_targets"
		return result

	# Verificar si la fuente ya no existe (para habilidades)
	if stack_obj.type in [StackObjectType.TRIGGERED_ABILITY, StackObjectType.ACTIVATED_ABILITY]:
		var source = stack_obj.context.get("source_card", null)
		if source is Node and not is_instance_valid(source):
			# Algunas habilidades aún se resuelven si la fuente salió
			# Solo cancelar si la habilidad lo requiere
			if stack_obj.card_data.get("requires_source", false):
				result.should_remove = true
				result.reason = "source_removed"

	return result


func _has_required_targets(stack_obj: Dictionary) -> bool:
	"""Determina si el objeto requiere objetivos obligatorios"""
	var card_data = stack_obj.card_data
	var ability_blocks = card_data.get("hability_blocks", [])

	for block in ability_blocks:
		var effects = block.get("effect", [])
		for effect in effects:
			var target = effect.get("target", {})
			var target_type = target.get("type", "")
			# "targeted" = requiere objetivo, "all"/"self" = no requiere selección
			if target_type == "targeted" or target_type == "choose":
				return true

	# También verificar objetivos directos
	return not stack_obj.targets.is_empty()


func _has_valid_targets(stack_obj: Dictionary) -> bool:
	"""Verifica si al menos un objetivo sigue siendo válido"""
	if stack_obj.targets.is_empty():
		return false

	for target in stack_obj.targets:
		if _is_target_valid(target, stack_obj):
			return true

	return false


func _is_target_valid(target, stack_obj: Dictionary) -> bool:
	"""Verifica si un objetivo específico sigue siendo válido"""
	# Nodos deben existir
	if target is Node:
		if not is_instance_valid(target):
			return false
		# Verificar que siga en una zona válida
		var zone = target.get("current_zone")
		if zone != null and zone in [Constants.Zone.CEMENTERIO, Constants.Zone.DESTIERRO]:
			return false

	# Diccionarios (datos de carta) - verificar si fue removido del juego
	if target is Dictionary:
		var target_id = target.get("id", "")
		if target_id.is_empty():
			return false
		# TODO: Verificar contra GameManager si la carta sigue en juego

	return true


func _should_fizzle(stack_obj: Dictionary) -> bool:
	"""Determina si el objeto debe hacer fizzle (perder todos los objetivos)

	Regla: Si TODOS los objetivos de un hechizo/habilidad son inválidos
	cuando intenta resolver, el hechizo hace fizzle y no hace nada.
	"""
	# Si no requiere objetivos, no puede fizzle por esto
	if not _has_required_targets(stack_obj):
		return false

	# Si tiene al menos un objetivo válido, no fizzle
	if _has_valid_targets(stack_obj):
		return false

	# Todos los objetivos son inválidos
	return true


# =============================================================================
# MANEJO DE OBJETOS REMOVIDOS
# =============================================================================
func _handle_removed_object(stack_obj: Dictionary, reason: String) -> void:
	"""Maneja un objeto que debe removerse antes de resolver"""
	match reason:
		"cancelled":
			await _handle_cancelled_object(stack_obj)
		"no_targets":
			await _handle_fizzled_object(stack_obj)
		"source_removed":
			await _handle_source_removed(stack_obj)
		_:
			_remove_from_stack(stack_obj, reason)


func _handle_cancelled_object(stack_obj: Dictionary) -> void:
	"""Maneja un objeto que fue CANCELADO (eliminar sin ejecutar efectos)

	Cancelar ≠ Anular:
	- Anular: La carta/habilidad va al cementerio
	- Cancelar: El efecto simplemente no ocurre
	"""
	stack_obj.step = StackObjectStep.FIZZLED
	stack_obj.step_name = STEP_NAMES[StackObjectStep.FIZZLED]

	var controller_id = stack_obj.context.get("controller_id", 0)

	print("[ActionPipeline] [%s] ✗ CANCELADA - efectos no ejecutados" % stack_obj.name)

	emit_signal("object_cancelled", stack_obj)

	# Para habilidades, simplemente se remueven
	# Para cartas, van al cementerio sin resolver
	if stack_obj.type in [StackObjectType.CARD_PLAYED, StackObjectType.RESPONSE_CARD]:
		if _action_module and _action_module.has_method("move_to_zone"):
			_action_module.move_to_zone(stack_obj.card_data, Constants.Zone.CEMENTERIO, controller_id)

	_remove_from_stack(stack_obj, "cancelled")


func _handle_fizzled_object(stack_obj: Dictionary) -> void:
	"""Maneja un objeto que hizo FIZZLE (perdió todos los objetivos)"""
	stack_obj.step = StackObjectStep.FIZZLED
	stack_obj.step_name = STEP_NAMES[StackObjectStep.FIZZLED]

	var controller_id = stack_obj.context.get("controller_id", 0)

	print("[ActionPipeline] [%s] ✗ FIZZLED - sin objetivos válidos" % stack_obj.name)

	emit_signal("object_fizzled", stack_obj)

	# Cartas van al cementerio, habilidades simplemente desaparecen
	if stack_obj.type in [StackObjectType.CARD_PLAYED, StackObjectType.RESPONSE_CARD]:
		if _action_module and _action_module.has_method("move_to_zone"):
			_action_module.move_to_zone(stack_obj.card_data, Constants.Zone.CEMENTERIO, controller_id)

	_remove_from_stack(stack_obj, "fizzled")


func _handle_source_removed(stack_obj: Dictionary) -> void:
	"""Maneja cuando la fuente de una habilidad fue removida del juego"""
	stack_obj.step = StackObjectStep.FIZZLED
	stack_obj.step_name = STEP_NAMES[StackObjectStep.FIZZLED]

	print("[ActionPipeline] [%s] ✗ Fuente removida del juego" % stack_obj.name)

	emit_signal("object_fizzled", stack_obj)
	_remove_from_stack(stack_obj, "source_removed")


func cancel_stack_object(stack_id: int) -> bool:
	"""Cancela un objeto específico de la pila por su ID

	Llamar esto marca el objeto como cancelado.
	Será removido cuando sea su turno de resolver.

	Returns: true si se encontró y marcó
	"""
	for obj in _stack:
		if obj.id == stack_id:
			obj["was_cancelled"] = true
			print("[ActionPipeline] Objeto #%d marcado para cancelación" % stack_id)
			return true
	return false


func cancel_top_object() -> bool:
	"""Cancela el objeto en el tope de la pila"""
	var top = _get_stack_top()
	if top.is_empty():
		return false
	return cancel_stack_object(top.id)


func _get_stack_top() -> Dictionary:
	"""Obtiene el objeto en el tope de la pila (sin remover)"""
	if _stack.is_empty():
		return {}
	return _stack[_stack.size() - 1]


func _remove_from_stack(stack_obj: Dictionary, reason: String) -> void:
	"""Remueve un objeto de la pila"""
	var idx = _stack.find(stack_obj)
	if idx >= 0:
		_stack.remove_at(idx)
		print("[ActionPipeline] └─ PILA [%d]: - %s (%s)" % [
			_stack.size(),
			stack_obj.name,
			reason
		])
		emit_signal("stack_object_removed", stack_obj, reason)


# =============================================================================
# PASO A: DECLARACIÓN
# =============================================================================
func _execute_step_a(stack_obj: Dictionary) -> Dictionary:
	"""Paso A: Declarar carta, objetivos, condiciones"""
	stack_obj.step = StackObjectStep.STEP_A
	stack_obj.step_name = STEP_NAMES[StackObjectStep.STEP_A]

	var result = {"success": true, "reason": ""}
	var card_data = stack_obj.card_data
	var context = stack_obj.context

	print("[ActionPipeline] [%s] Paso A: Declaración" % stack_obj.name)

	# Verificar que puede jugarse
	var controller_id = context.get("controller_id", 0)
	var card_type = card_data.get("tipo", -1)

	# Validar fase
	if _game_manager:
		var phase = _game_manager.get("current_phase")
		if phase != null:
			if card_type == Constants.CardType.TALISMAN:
				if phase not in [Constants.Phase.VIGILIA, Constants.Phase.GUERRA_TALISMANES]:
					result.success = false
					result.reason = "Solo en Vigilia o Guerra de Talismanes"
					return result
			elif stack_obj.type == StackObjectType.CARD_PLAYED:
				if phase != Constants.Phase.VIGILIA:
					result.success = false
					result.reason = "Solo en Fase de Vigilia"
					return result

	# Validar objetivos si se requieren
	var targets = context.get("targets", [])
	stack_obj.targets = targets

	emit_signal("step_a_completed", stack_obj)
	print("[ActionPipeline] [%s] ✓ Paso A completado" % stack_obj.name)

	return result


# =============================================================================
# PASO B: PAGO DE COSTES
# =============================================================================
func _execute_step_b(stack_obj: Dictionary) -> Dictionary:
	"""Paso B: Calcular y pagar costes"""
	stack_obj.step = StackObjectStep.STEP_B
	stack_obj.step_name = STEP_NAMES[StackObjectStep.STEP_B]

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
	if _trigger_system and _trigger_system.has_method("get_cost_modifiers"):
		var mods = _trigger_system.get_cost_modifiers(card_data, context)
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
	if final_cost > 0 and _action_module:
		if _action_module.has_method("pay_gold"):
			var payment = _action_module.pay_gold(controller_id, final_cost)
			if not payment.get("success", false):
				result.success = false
				result.reason = "Oro insuficiente"
				return result

	stack_obj.cost_paid = final_cost

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE PASO B EN BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var block_id = stack_obj.get("log_block_id", -1)
	if block_id >= 0 and _combat_log and _combat_log.has_method("add_block_step"):
		if has_x_cost:
			_combat_log.add_block_step(block_id, "B", "Pagado: %d Oro (X=%d)" % [
				final_cost, x_value
			], {"cost": final_cost, "x_value": x_value})
		else:
			_combat_log.add_block_step(block_id, "B", "Pagado: %d Oro" % final_cost, {
				"cost": final_cost
			})

	emit_signal("step_b_completed", stack_obj, final_cost)
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
	stack_obj.step = StackObjectStep.STEP_C
	stack_obj.step_name = STEP_NAMES[StackObjectStep.STEP_C]

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

	if _trigger_system:
		# Jugador activo primero (DAR Sección 6.C)
		if _trigger_system.has_method("get_triggered_abilities"):
			var active_triggers = _trigger_system.get_triggered_abilities(controller_id, "on_card_played", event_data)
			triggered_abilities.append_array(active_triggers)

			var opponent_triggers = _trigger_system.get_triggered_abilities(opponent_id, "on_card_played", event_data)
			triggered_abilities.append_array(opponent_triggers)

	# ─────────────────────────────────────────────────────────────────────────
	# Añadir cada habilidad disparada a la Pila (NO resolver)
	# ─────────────────────────────────────────────────────────────────────────
	for trigger in triggered_abilities:
		var trigger_id = add_triggered_ability_to_stack(trigger, card_data, {
			"controller_id": trigger.get("controller_id", controller_id),
			"original_event": event_data
		})
		stack_obj.triggers_generated.append(trigger_id)
		result.triggers_added += 1

	emit_signal("step_c_completed", stack_obj, result.triggers_added)

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
	stack_obj.step = StackObjectStep.STEP_D
	stack_obj.step_name = STEP_NAMES[StackObjectStep.STEP_D]

	var result = {
		"had_response": false,
		"response_object": null
	}

	var controller_id = stack_obj.context.get("controller_id", 0)
	var opponent_id = 1 - controller_id

	print("[ActionPipeline] [%s] Paso D: Ventana de Respuesta" % stack_obj.name)

	_is_waiting_priority = true
	emit_signal("step_d_waiting", stack_obj, opponent_id)
	emit_signal("priority_window_opened", stack_obj, opponent_id)

	# ─────────────────────────────────────────────────────────────────────────
	# Abrir ventana de prioridad (oponente primero)
	# ─────────────────────────────────────────────────────────────────────────
	if _priority_manager:
		_priority_manager.start_priority_window(1, opponent_id)  # RESPONSE_WINDOW = 1

	# ─────────────────────────────────────────────────────────────────────────
	# Esperar hasta que ambos pasen o alguien responda
	# ─────────────────────────────────────────────────────────────────────────
	var wait_result = await _wait_for_priority_on_stack_object(stack_obj)

	_is_waiting_priority = false

	result.had_response = wait_result.had_response
	if wait_result.had_response:
		result.response_object = wait_result.response_object

	emit_signal("step_d_completed", stack_obj, result.had_response)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE PASO D EN BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var block_id = stack_obj.get("log_block_id", -1)
	if block_id >= 0 and _combat_log and _combat_log.has_method("add_block_step"):
		if result.had_response:
			_combat_log.add_block_step(block_id, "D", "Ventana de respuesta: [color=#FF9800]Respuesta recibida[/color]", {
				"had_response": true
			})
		else:
			_combat_log.add_block_step(block_id, "D", "Ventana de respuesta: [color=#4CAF50]Ambos pasaron[/color]", {
				"had_response": false
			})

	print("[ActionPipeline] [%s] ✓ Paso D: %s" % [
		stack_obj.name,
		"Respuesta recibida" if result.had_response else "Ambos pasaron"
	])

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
	var original_stack_size = _stack.size()

	while _is_waiting_priority:
		await get_tree().create_timer(check_interval).timeout
		timeout += check_interval

		# Verificar si se añadió algo a la pila (respuesta)
		if _stack.size() > original_stack_size:
			result.had_response = true
			result.response_object = _get_stack_top()
			break

		# Verificar si el objeto fue anulado
		if stack_obj.was_annulled:
			result.was_annulled = true
			break

		# Verificar si PriorityManager cerró la ventana
		if _priority_manager and not _priority_manager.priority_window_active:
			break

		# Timeout
		if timeout >= PRIORITY_TIMEOUT:
			print("[ActionPipeline] Timeout de prioridad")
			break

	return result


func _on_priority_both_passed() -> void:
	"""Callback cuando ambos jugadores pasan"""
	if _is_waiting_priority:
		_is_waiting_priority = false
		emit_signal("both_players_passed_on_stack")


func _on_priority_action_taken(player_id: int, action: Dictionary) -> void:
	"""Callback cuando un jugador toma una acción"""
	if not _is_waiting_priority:
		return

	var action_type = action.get("type", "")
	var target_stack_id = action.get("target_stack_id", -1)

	# Determinar qué objeto de la pila es el objetivo
	var target_obj: Dictionary = {}
	if target_stack_id > 0:
		target_obj = get_object_by_id(target_stack_id)
	else:
		target_obj = _get_stack_top()

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
	stack_obj.step = StackObjectStep.STEP_E
	stack_obj.step_name = STEP_NAMES[StackObjectStep.STEP_E]

	var result = {
		"success": true,
		"entered_play": false,
		"destination": Constants.Zone.CEMENTERIO,
		"effects_resolved": []
	}

	var card_data = stack_obj.card_data
	var context = stack_obj.context
	var controller_id = context.get("controller_id", 0)

	print("[ActionPipeline] [%s] Paso E: Resolución" % stack_obj.name)

	emit_signal("stack_object_resolving", stack_obj)

	# ─────────────────────────────────────────────────────────────────────────
	# Verificar objetivos válidos (fizzle check)
	# ─────────────────────────────────────────────────────────────────────────
	if not _validate_targets(stack_obj):
		stack_obj.step = StackObjectStep.FIZZLED
		result.success = false
		print("[ActionPipeline] [%s] ✗ Fizzled - objetivos inválidos" % stack_obj.name)
		return result

	# ─────────────────────────────────────────────────────────────────────────
	# Resolver según tipo
	# ─────────────────────────────────────────────────────────────────────────
	match stack_obj.type:
		StackObjectType.CARD_PLAYED, StackObjectType.RESPONSE_CARD:
			result = await _resolve_card(stack_obj)

		StackObjectType.TRIGGERED_ABILITY, StackObjectType.ACTIVATED_ABILITY:
			result = await _resolve_ability(stack_obj)

	stack_obj.step = StackObjectStep.RESOLVED
	stack_obj.step_name = STEP_NAMES[StackObjectStep.RESOLVED]
	stack_obj.resolved_at = Time.get_ticks_msec()
	stack_obj.resolution_result = result

	emit_signal("stack_object_resolved", stack_obj, result)
	emit_signal("step_e_completed", stack_obj, result)

	# ─────────────────────────────────────────────────────────────────────────
	# LOG DE PASO E Y COMPLETAR BLOQUE
	# ─────────────────────────────────────────────────────────────────────────
	var block_id = stack_obj.get("log_block_id", -1)
	if block_id >= 0 and _combat_log:
		# Log del paso E
		if _combat_log.has_method("add_block_step"):
			var effects_count = result.get("effects_resolved", []).size()
			_combat_log.add_block_step(block_id, "E", "Resuelto: %d efecto(s)" % effects_count, {
				"effects_count": effects_count
			})

		# Completar bloque
		if _combat_log.has_method("complete_block"):
			_combat_log.complete_block(block_id, result.success, result)

	print("[ActionPipeline] [%s] ✓ Paso E: Resuelto" % stack_obj.name)

	return result


func _validate_targets(stack_obj: Dictionary) -> bool:
	"""Valida que los objetivos sigan siendo válidos (Paso E)

	En Paso E, si el objeto requiere objetivos y ninguno es válido,
	hace fizzle. Si NO requiere objetivos, siempre es válido.
	"""
	# Si no requiere objetivos, es válido
	if not _has_required_targets(stack_obj):
		return true

	# Si requiere objetivos, al menos uno debe ser válido
	return _has_valid_targets(stack_obj)


func _resolve_card(stack_obj: Dictionary) -> Dictionary:
	"""Resuelve una carta (entra en juego o efecto)"""
	var result = {
		"success": true,
		"entered_play": false,
		"destination": Constants.Zone.CEMENTERIO
	}

	var card_data = stack_obj.card_data
	var card_type = card_data.get("tipo", -1)
	var controller_id = stack_obj.context.get("controller_id", 0)
	var via_exhumar = stack_obj.context.get("via_exhumar", false)

	# ─────────────────────────────────────────────────────────────────────────
	# FLAG EXHUMAR: Marcar carta para que vaya a DESTIERRO al salir del juego
	# ─────────────────────────────────────────────────────────────────────────
	if via_exhumar:
		card_data["_exhumar_flag"] = true
		card_data["_force_destination"] = Constants.Zone.DESTIERRO
		print("[ActionPipeline] 💀 Carta via Exhumar - destino forzado: DESTIERRO")

	match card_type:
		Constants.CardType.ALIADO:
			result.destination = Constants.Zone.LINEA_DEFENSA
			result.entered_play = true
			card_data["entered_this_turn"] = true

		Constants.CardType.ARMA:
			if not stack_obj.targets.is_empty():
				result.destination = Constants.Zone.LINEA_DEFENSA
				result.entered_play = true

		Constants.CardType.TOTEM:
			result.destination = Constants.Zone.LINEA_APOYO
			result.entered_play = true

		Constants.CardType.TALISMAN:
			# Resolver efectos
			await _resolve_talisman_effects(stack_obj)
			# Talismanes siempre van a cementerio/destierro tras resolver
			result.destination = Constants.Zone.DESTIERRO if via_exhumar else Constants.Zone.CEMENTERIO

	# Mover carta
	if _action_module and _action_module.has_method("move_to_zone"):
		_action_module.move_to_zone(card_data, result.destination, controller_id)

	# Disparar on_enter_play si entró
	if result.entered_play and _trigger_system:
		if _trigger_system.has_method("trigger_event"):
			await _trigger_system.trigger_event("on_enter_play", {
				"card": card_data,
				"controller_id": controller_id
			})

	return result


func _resolve_ability(stack_obj: Dictionary) -> Dictionary:
	"""Resuelve una habilidad disparada o activada"""
	var result = {"success": true, "effects_resolved": []}

	var ability_data = stack_obj.card_data
	var context = stack_obj.context

	# TODO: Ejecutar efectos de la habilidad via ActionModule
	if _action_module and _action_module.has_method("execute_ability"):
		var exec_result = await _action_module.execute_ability(ability_data, context)
		result.effects_resolved = exec_result.get("effects", [])

	return result


func _resolve_talisman_effects(stack_obj: Dictionary) -> Array:
	"""Resuelve los efectos de un talismán"""
	var resolved: Array = []
	var card_data = stack_obj.card_data
	var ability_blocks = card_data.get("hability_blocks", [])

	for block in ability_blocks:
		var effects = block.get("effect", [])
		for effect in effects:
			# TODO: Ejecutar cada efecto
			resolved.append(effect)

	return resolved


# =============================================================================
# MANEJO DE ANULACIÓN
# =============================================================================
func _handle_annulled_object(stack_obj: Dictionary) -> void:
	"""Maneja un objeto que fue anulado"""
	stack_obj.step = StackObjectStep.ANNULLED
	stack_obj.step_name = STEP_NAMES[StackObjectStep.ANNULLED]

	var controller_id = stack_obj.context.get("controller_id", 0)

	print("[ActionPipeline] [%s] ✗ ANULADO" % stack_obj.name)

	# ─────────────────────────────────────────────────────────────────────────
	# MARCAR BLOQUE COMO ANULADO EN COMBATLOG
	# ─────────────────────────────────────────────────────────────────────────
	var block_id = stack_obj.get("log_block_id", -1)
	var annuller_data = stack_obj.get("annuller", {})
	var annuller_name = annuller_data.get("nombre", annuller_data.get("name", "carta"))

	if block_id >= 0 and _combat_log:
		if _combat_log.has_method("annul_block"):
			_combat_log.annul_block(block_id, annuller_name, "")
		if _combat_log.has_method("complete_block"):
			_combat_log.complete_block(block_id, false, {"annulled": true})

	emit_signal("object_annulled", stack_obj, stack_obj.annuller)

	# Mover al cementerio sin resolver
	if _action_module and _action_module.has_method("move_to_zone"):
		_action_module.move_to_zone(stack_obj.card_data, Constants.Zone.CEMENTERIO, controller_id)

	# Disparar evento on_annulled
	if _trigger_system and _trigger_system.has_method("trigger_event"):
		await _trigger_system.trigger_event("on_card_annulled", {
			"card": stack_obj.card_data,
			"annuller": stack_obj.annuller,
			"controller_id": controller_id
		})

	_remove_from_stack(stack_obj, "annulled")


# =============================================================================
# UTILIDADES
# =============================================================================
# =============================================================================
# LOGGING Y UTILIDADES
# =============================================================================
func _log_action(action_type: String, message: String, data: Dictionary = {}) -> void:
	"""Envía una entrada al CombatLog"""
	if _combat_log and _combat_log.has_method("add_entry"):
		_combat_log.add_entry(action_type, message, data)


func _get_player_name(player_id: int) -> String:
	"""Obtiene el nombre del jugador"""
	if _game_manager and _game_manager.has_method("get_player_name"):
		return _game_manager.get_player_name(player_id)

	# Fallback
	return "Jugador %d" % (player_id + 1)


func _print_stack_state() -> void:
	"""Imprime el estado actual de la pila"""
	if _stack.is_empty():
		print("[ActionPipeline] │  (vacía)")
		return

	for i in range(_stack.size() - 1, -1, -1):
		var obj = _stack[i]
		var prefix = "│  TOPE → " if i == _stack.size() - 1 else "│       "
		var x_info = " [X=%d]" % obj.x_value if obj.get("has_x_cost", false) else ""
		print("[ActionPipeline] %s[%d] %s (%s)%s" % [
			prefix, obj.id, obj.name, obj.step_name, x_info
		])


# =============================================================================
# API PÚBLICA
# =============================================================================
func get_stack() -> Array[Dictionary]:
	"""Retorna copia de la pila actual"""
	return _stack.duplicate()


func get_stack_size() -> int:
	"""Retorna tamaño de la pila"""
	return _stack.size()


func is_stack_empty() -> bool:
	"""Retorna si la pila está vacía"""
	return _stack.is_empty()


func get_stack_top_object() -> Dictionary:
	"""Retorna el objeto en el tope (sin remover)"""
	return _get_stack_top()


func is_stack_processing() -> bool:
	"""Retorna si se está procesando la pila"""
	return _is_resolving


func is_waiting_for_priority() -> bool:
	"""Retorna si hay una ventana de prioridad abierta"""
	return _is_waiting_priority


func get_object_by_id(stack_id: int) -> Dictionary:
	"""Busca un objeto en la pila por ID"""
	for obj in _stack:
		if obj.id == stack_id:
			return obj
	return {}


# =============================================================================
# API DE COSTE VARIABLE X - Acceso para Annul/EffectCommands
# =============================================================================
func get_instance_x(stack_id: int) -> int:
	"""Obtiene instance_x de un objeto en la pila (valor canónico)

	Usado por:
	- EffectCommands para resolver efectos que usan X
	- Cualquier sistema que necesite el valor de X elegido

	Returns: Valor de X, o -1 si no tiene coste variable
	"""
	var obj = get_object_by_id(stack_id)
	if obj.is_empty():
		return -1

	# instance_x es el valor canónico
	return obj.get("instance_x", obj.get("x_value", -1))


func get_x_value(stack_id: int) -> int:
	"""Alias de get_instance_x para compatibilidad"""
	return get_instance_x(stack_id)


func get_x_total_cost(stack_id: int) -> int:
	"""Obtiene el coste total (incluyendo X) de un objeto en la pila

	Returns: Coste total pagado, o -1 si no tiene coste variable
	"""
	var obj = get_object_by_id(stack_id)
	if obj.is_empty():
		return -1

	return obj.get("x_total_cost", -1)


func has_x_cost(stack_id: int) -> bool:
	"""Verifica si un objeto tiene coste variable X"""
	var obj = get_object_by_id(stack_id)
	if obj.is_empty():
		return false

	return obj.get("has_x_cost", false)


func get_stack_object_x_info(stack_id: int) -> Dictionary:
	"""Obtiene toda la información de X de un objeto

	Returns: {has_x_cost, instance_x, x_total_cost, cost_paid}
	"""
	var obj = get_object_by_id(stack_id)
	if obj.is_empty():
		return {"has_x_cost": false, "instance_x": -1, "x_value": -1, "x_total_cost": -1, "cost_paid": 0}

	var instance_x = obj.get("instance_x", obj.get("x_value", -1))
	return {
		"has_x_cost": obj.get("has_x_cost", false),
		"instance_x": instance_x,
		"x_value": instance_x,  # Alias
		"x_total_cost": obj.get("x_total_cost", -1),
		"cost_paid": obj.get("cost_paid", 0)
	}
