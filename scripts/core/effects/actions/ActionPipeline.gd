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

## Anulación y Cancelación
signal object_annulled(stack_object: Dictionary, annuller: Dictionary)
signal object_cancelled(stack_object: Dictionary)
signal object_fizzled(stack_object: Dictionary)

## Pipeline general
signal pipeline_started
signal pipeline_idle

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

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
const PRIORITY_TIMEOUT: float = 30.0

# =============================================================================
# MÓDULOS
# =============================================================================
var _step_resolver: StackStepResolver


func _ready() -> void:
	_step_resolver = StackStepResolver.new()
	_step_resolver.setup(self)
	call_deferred("_connect_signals")
	print("[ActionPipeline] Inicializado - Sistema de Pila LIFO (DAR Sección 6)")


func _connect_signals() -> void:
	# (2026-08-28, "módulos gordos" punto 1): PriorityManager/GameManager son
	# autoloads garantizados — se saca el cacheo redundante vía get_node_or_null().
	PriorityManager.both_players_passed.connect(_step_resolver._on_priority_both_passed)
	PriorityManager.action_taken.connect(_step_resolver._on_priority_action_taken)
	# Resetear uso de habilidades al inicio de cada turno.
	# GameManager es el único conductor de turnos (ver consolidación 2026-08-19).
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
# play_card()/add_response_to_stack() (StackObjectType.CARD_PLAYED/
# RESPONSE_CARD) se eliminaron acá (2026-08-27, limpieza a pedido del
# usuario): sin ningún llamador real en el juego — el camino que de verdad
# juega cartas es GoldManager (_play_card_to_field/_place_card_as_gold/
# _equip_weapon/_play_talisman), no ActionPipeline. Quedaban como un
# segundo sistema paralelo sin terminar (_resolve_talisman_effects() tenía
# hasta un TODO sin implementar) que podía confundir a futuro. Las
# habilidades disparadas/activadas SÍ están vivas y no se tocaron —
# add_triggered_ability_to_stack()/activate_ability() siguen igual.


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
	var block_id = CombatLog.log_detailed_play(card_data, player_id)
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

	# (2026-09-09, bug real encontrado al preparar la migración de la Pila de
	# Respuesta Universal): esta función NUNCA arrancaba _process_stack() por
	# su cuenta — solo activate_ability() lo hacía. El único llamador real de
	# hasta ahora (SelectionModule._on_exhume_card_selected(), Exhumar) quedaba
	# esperando un stack_object_resolved que jamás llegaba salvo que otra
	# habilidad activada ya estuviera procesándose al mismo tiempo por
	# coincidencia. Mismo guard que activate_ability() ya usa.
	if not _is_resolving:
		_process_stack()

	return stack_obj.id


func add_triggered_ability_to_stack_and_await(ability_data: Dictionary, source_card: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Como add_triggered_ability_to_stack(), pero espera a que ESE objeto
	puntual (no la pila entera — puede haber respuestas anidadas encima que
	tarden más) termine de resolver/anularse/cancelarse/fizzlear, para que el
	llamador (un patrón de trigger en TriggerSystem/LookAndPlayResolver/etc.,
	Sección "Pila de Respuesta Universal") sepa si debe seguir ejecutando su
	propio efecto o abortar. Filtra las señales por stack_id — si mientras
	tanto se apilan respuestas encima, esas resuelven primero y esta función
	sigue esperando hasta que le toque el turno a ESTE objeto en particular.

	Returns: {resolved: bool, annulled: bool, cancelled: bool, fizzled: bool}
	— como máximo uno de los cuatro es true."""
	var stack_id: int = add_triggered_ability_to_stack(ability_data, source_card, context)

	var outcome: Dictionary = {"resolved": false, "annulled": false, "cancelled": false, "fizzled": false}
	var done: bool = false

	var on_resolved := func(obj: Dictionary, _result: Dictionary) -> void:
		if obj.get("id", -1) == stack_id:
			outcome.resolved = true
			done = true
	var on_annulled := func(obj: Dictionary, _annuller) -> void:
		if obj.get("id", -1) == stack_id:
			outcome.annulled = true
			done = true
	var on_cancelled := func(obj: Dictionary) -> void:
		if obj.get("id", -1) == stack_id:
			outcome.cancelled = true
			done = true
	var on_fizzled := func(obj: Dictionary) -> void:
		if obj.get("id", -1) == stack_id:
			outcome.fizzled = true
			done = true

	stack_object_resolved.connect(on_resolved)
	object_annulled.connect(on_annulled)
	object_cancelled.connect(on_cancelled)
	object_fizzled.connect(on_fizzled)

	# Salvaguarda con timeout (2026-09-11, bug real reportado por el usuario:
	# el juego quedaba congelado para siempre en Fase Final, sin ningún log
	# posterior — TriggerSystem.awaiting_response/is_resolving atascados,
	# consistente con que este objeto puntual NUNCA llegó a recibir su Paso
	# D/E, probablemente porque _process_stack() no se relanzó cuando hacía
	# falta). Sin una salida de emergencia, cualquier causa que impida que
	# ESTE objeto puntual resuelva deja el juego entero sin poder avanzar —
	# mismo criterio de "no fricción, seguir igual" que ya usa
	# _wait_for_response_window() (Signo Amarillo, timeout de 8s) en vez de
	# arriesgar un cuelgue permanente. Si esto se dispara, es evidencia real
	# de un bug más profundo por perseguir después — el push_warning deja
	# rastro concreto (antes no había NINGÚN log en este punto de cuelgue).
	var waited := 0.0
	while not done and waited < 8.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if not done:
		push_warning("[ActionPipeline] add_triggered_ability_to_stack_and_await() atascado >8s para stack_id=%d (_is_resolving=%s, tamaño de pila=%d) — forzando continuación sin anular/cancelar" % [
			stack_id, str(_is_resolving), _stack.size()
		])

	stack_object_resolved.disconnect(on_resolved)
	object_annulled.disconnect(on_annulled)
	object_cancelled.disconnect(on_cancelled)
	object_fizzled.disconnect(on_fizzled)

	return outcome


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
	# instance_id, no source_card_data.id — mismo motivo que en
	# can_activate_ability() (2026-08-30, bug de copias compartiendo cupo).
	var card_node = context.get("source_card_node")
	var card_id: String    = str(card_node.get_instance_id()) if card_node and is_instance_valid(card_node) else str(source_card_data.get("id", ""))
	var ability_index: int = ability_data.get("ability_index", 0)
	var cost_type: int     = ability_data.get("cost_type", UniversalCardParser.CostType.NONE)
	var cost_amount: int   = ability_data.get("cost_amount", 0)

	# Sistema "Puedes" ELIMINADO para habilidades ACTIVADAS (2026-08-28, a
	# pedido del usuario): clickear el botón de la habilidad YA ES la
	# confirmación — pedir un "¿seguro?" aparte era redundante ("se entiende
	# que si le doy al botón utilizo la habilidad"). Los triggers ("puedes"
	# en 'Cuando entra/ataca/...', resueltos por TriggerResolution/
	# LookAndPlayResolver/TargetedEffectExecutor, que no pasan por acá) ya
	# ofrecen su propio "declinar" via can_cancel en el SelectionManager que
	# abren — nunca dependieron de este diálogo.

	# ── Paso A: Validar activación ────────────────────────────────────────────
	var check = can_activate_ability(source_card_data, ability_data, context)
	if not check.can:
		push_warning("[ActionPipeline] No se puede activar habilidad: %s" % check.reason)
		return {"success": false, "reason": check.reason}

	# ── Paso B: Pagar el costo ────────────────────────────────────────────────
	# El oro real vive en GoldManager (hijo de Main), no en ActionModule/
	# GameManager — ver docs/audit y consolidación 2026-08-19/2026-08-20.
	var main_ref := get_node_or_null("/root/Main")
	var source_card_node = context.get("source_card_node")
	match cost_type:
		UniversalCardParser.CostType.GOLD:
			if controller_id == 0:
				if not main_ref or not main_ref._gold_manager:
					return {"success": false, "reason": "GoldManager no disponible"}
				var paid: bool = await main_ref._gold_manager.pagar_coste(cost_amount)
				if not paid:
					return {"success": false, "reason": "Oro insuficiente"}
			else:
				# El bot no tiene Oro Virtual/restringido (esos pools solo
				# existen del lado humano) — paga siempre Oro físico real vía
				# el mismo helper que ya usa para jugar cartas (2026-09-09).
				if not main_ref or not main_ref._easy_bot or not GameState.puede_pagar(controller_id, cost_amount):
					return {"success": false, "reason": "Oro insuficiente"}
				main_ref._easy_bot._pay_oro_for_bot(cost_amount)
		UniversalCardParser.CostType.DISCARD:
			if controller_id != 0:
				# El bot no tiene mano representada como Nodos todavía
				# (2026-09-09) — este tipo de costo queda fuera de su alcance
				# hasta que exista esa representación.
				return {"success": false, "reason": "El bot no puede descartar todavía"}
			if not main_ref or not main_ref.player_hand:
				return {"success": false, "reason": "No se pudo descartar"}
			var hand_cards: Array = main_ref.player_hand.cards.duplicate()
			if hand_cards.is_empty():
				return {"success": false, "reason": "Mano vacía"}
			var chosen: Array = await TriggerSystem._select_hand_cards_for_discard(hand_cards, 1)
			if chosen.is_empty():
				return {"success": false, "reason": "Descarte cancelado"}
			await ActionModule.discard(controller_id, chosen, "activated_ability", true)
		UniversalCardParser.CostType.TAP:
			if source_card_node and is_instance_valid(source_card_node):
				source_card_node.is_tapped = true
		# ONCE_PER_TURN no tiene costo de recurso, solo la restricción de uso

	# ── Marcar como usada (para "una vez por turno") ──────────────────────────
	if cost_type == UniversalCardParser.CostType.ONCE_PER_TURN or ability_data.get("once_per_turn", false):
		var turn: int = GameManager.current_turn
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
	await _step_resolver._execute_step_c(stack_obj)

	# ── Añadir al tope de la Pila ─────────────────────────────────────────────
	_add_to_stack(stack_obj)

	print("[ActionPipeline] ✦ Habilidad activada: '%s' de '%s'" % [
		ability_data.get("cost_text", "?"), source_card_data.get("nombre", "?")
	])

	# ── Iniciar procesamiento si la pila no está activa ───────────────────────
	if not _is_resolving:
		_process_stack()

	return {"success": true, "stack_id": stack_obj.id}


func can_activate_ability(source_card_data: Dictionary, ability_data: Dictionary, context: Dictionary = {}) -> Dictionary:
	"""Comprueba si una habilidad puede activarse ahora.

	Returns: {can: bool, reason: String}
	"""
	# instance_id de la carta VIVA cuando está disponible, no
	# source_card_data.id (2026-08-30, corrección: ese id es el de la
	# carta/impresión, compartido por TODAS las copias en juego — con 2
	# copias de una misma carta, usar el 'una vez por turno' de una marcaba
	# también el cupo de la otra, bug real reportado por el usuario). Cae a
	# source_card_data.id solo si de verdad no hay Nodo (no debería pasar en
	# los dos caminos reales que llaman a esta función).
	var context_node = context.get("source_card_node")
	var card_id        = str(context_node.get_instance_id()) if context_node and is_instance_valid(context_node) else str(source_card_data.get("id", ""))
	var ability_index  = ability_data.get("ability_index", 0)
	var cost_type      = ability_data.get("cost_type", UniversalCardParser.CostType.NONE)
	var cost_amount    = ability_data.get("cost_amount", 0)
	var controller_id  = context.get("controller_id", 0)

	# Fase: Vigilia + Guerra de Talismanes por defecto (DAR) — solo se
	# restringe a Vigilia si el propio texto de la habilidad lo dice ("en
	# Vigilia"). Sin esa mención, cualquier habilidad activada se puede usar
	# en cualquiera de las dos ventanas.
	var phase = GameManager.current_phase
	var ability_text: String = ability_data.get("raw_text", ability_data.get("effect_text", "")).to_lower()
	var vigilia_only: bool = "en vigilia" in ability_text
	var phase_ok: bool = phase == Constants.Phase.VIGILIA or (phase == Constants.Phase.GUERRA_TALISMANES and not vigilia_only)
	if not phase_ok:
		return {"can": false, "reason": "Fuera de fase Vigilia" if vigilia_only else "Solo en Vigilia o Guerra de Talismanes"}
	# NO se exige 'active_player_id == controller_id' (2026-09-10, corregido):
	# el DAR permite activar habilidades instantáneas en Vigilia/Guerra de
	# Talismanes seas o no el jugador activo — es justo lo que hace falta
	# para responder dentro de la Pila de Respuesta Universal en el turno
	# rival. El chequeo viejo bloqueaba esto tanto al humano como al bot.

	# Una vez por turno: verificar en _ability_usage y en TurnRegistry del parser
	if cost_type == UniversalCardParser.CostType.ONCE_PER_TURN or ability_data.get("once_per_turn", false):
		var turn: int = GameManager.current_turn
		var key: String = "%s_%d" % [card_id, ability_index]
		var in_local:    bool = _ability_usage.get(key, -1) == turn
		var in_registry: bool = UniversalCardParser.turn_registry.was_used(card_id, ability_index, turn)
		if in_local or in_registry:
			return {"can": false, "reason": "Ya usada este turno"}

	# Oro: verificar si el jugador tiene suficiente — vía GoldManager (real,
	# solo jugador 0, con sus pools de Oro Virtual/restringido) o vía
	# GameState (bot, Oro físico simple) — misma distinción que Paso B.
	if cost_type == UniversalCardParser.CostType.GOLD and cost_amount > 0:
		if controller_id == 0:
			var main_check := get_node_or_null("/root/Main")
			if main_check and main_check._gold_manager:
				var available: int = main_check._gold_manager.get_oro_disponible()
				if not main_check._gold_manager.puede_pagar(cost_amount):
					return {"can": false, "reason": "Necesitas %d Oro (tienes %d)" % [cost_amount, available]}
			else:
				return {"can": false, "reason": "GoldManager no disponible"}
		else:
			if not GameState.puede_pagar(controller_id, cost_amount):
				return {"can": false, "reason": "Necesitas %d Oro (tienes %d)" % [cost_amount, GameState.get_oro_reserva(controller_id)]}

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
		var step_d_result = await _step_resolver._execute_step_d(top)

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
		await _step_resolver._execute_step_e(top)

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
		# (2026-08-28): 'move_to_zone' nunca existió en ActionModule.gd — este
		# guard siempre daba falso y la carta NUNCA iba al cementerio al
		# cancelarse/fizzlear, quedaba en limbo fuera de la pila. La API real
		# para mover una carta (por Dictionary) al cementerio es
		# CardManager.add_to_cemetery(player_id, card_data).
		CardManager.add_to_cemetery(controller_id, stack_obj.card_data)

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
		# (2026-08-28): 'move_to_zone' nunca existió en ActionModule.gd — este
		# guard siempre daba falso y la carta NUNCA iba al cementerio al
		# cancelarse/fizzlear, quedaba en limbo fuera de la pila. La API real
		# para mover una carta (por Dictionary) al cementerio es
		# CardManager.add_to_cemetery(player_id, card_data).
		CardManager.add_to_cemetery(controller_id, stack_obj.card_data)

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

	if block_id >= 0:
		CombatLog.annul_block(block_id, annuller_name, "")
		CombatLog.complete_block(block_id, false, {"annulled": true})

	emit_signal("object_annulled", stack_obj, stack_obj.annuller)

	# Mover al cementerio sin resolver (2026-08-28: 'move_to_zone' no existe
	# en ActionModule.gd — ver mismo fix en _handle_cancelled_object/_handle_fizzled_object)
	CardManager.add_to_cemetery(controller_id, stack_obj.card_data)

	# (2026-08-28): 'trigger_event' no existe en TriggerSystem.gd — este
	# disparo de on_card_annulled nunca ocurrió realmente. Documentado, no
	# se inventa un trigger nuevo fuera del alcance de esta limpieza.

	_remove_from_stack(stack_obj, "annulled")


# =============================================================================
# UTILIDADES
# =============================================================================
# =============================================================================
# LOGGING Y UTILIDADES
# =============================================================================
func _log_action(action_type: String, message: String, data: Dictionary = {}) -> void:
	"""Envía una entrada al CombatLog"""
	CombatLog.add_entry(action_type, message, data)


func _get_player_name(player_id: int) -> String:
	"""Obtiene el nombre del jugador
	(2026-08-28: GameManager no expone get_player_name() — ver mismo hallazgo
	en PaymentManager.gd)"""
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
