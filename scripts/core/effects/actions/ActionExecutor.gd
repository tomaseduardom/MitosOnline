extends Node
## ActionExecutor - Ejecuta bloques de habilidad de forma secuencial
## Procesa acciones usando ActionModule y respeta conectores del pipeline

# =============================================================================
# SEÑALES
# =============================================================================
## Habilidades
signal ability_execution_started(card: Node, ability_block: Dictionary)
signal ability_execution_completed(card: Node, result: Dictionary)

## Acciones individuales
signal action_executed(action: Dictionary, result: Dictionary)
signal action_draw_completed(player_id: int, cards: Array, amount: int)
signal action_discard_completed(player_id: int, cards: Array)
signal action_destroy_completed(destroyed: Array, source: Node)
signal action_banish_completed(banished: Array, source: Node)
signal action_mill_completed(player_id: int, cards: Array, to_exile: bool)
signal action_search_completed(player_id: int, selected: Array, zone: int)
signal action_damage_completed(targets: Array, amount: int, source: Node)
signal action_buff_completed(targets: Array, amount: int, is_buff: bool)
signal action_heal_completed(player_id: int, amount: int)
signal action_token_created(player_id: int, tokens: Array)

## Costes
signal cost_paid(cost: Dictionary, success: bool)
signal execution_failed(reason: String, context: Dictionary)

## Paso D - Ventana de Respuesta (DAR Sección 6)
signal waiting_for_opponent_response(card: Node, context: Dictionary)
signal response_window_closed(had_response: bool)
signal opponent_passed()
signal opponent_responded(response_card: Node)

## Sección 8 - Anulación
signal spell_annulled(annulled_card: Node, annuller_card: Node)
signal effects_synced_to_opponent(card_name: String, effects: Array)

## Sincronización multiplayer
signal broadcast_pending_effects(player_id: int, card_data: Dictionary, selected_effects: Array)

## Paso E - Resolución (Sección 17)
signal resolution_started(card: Node, effects: Array)
signal resolution_completed(card: Node, success: bool, effects_resolved: int)
signal post_resolution_condition(card: Node, condition: String, destination: String)

# =============================================================================
# REFERENCIAS
# =============================================================================

# =============================================================================
# ESTADO DE VENTANA DE RESPUESTA
# =============================================================================
var _waiting_for_response: bool = false
var _response_pending: Node = null  # Carta de respuesta del oponente
var _response_timeout: float = 30.0  # Tiempo máximo de espera (segundos)

# =============================================================================
# ESTADO DEL ACTION PIPELINE (Paso A-D)
# =============================================================================
## Carta actualmente en el pipeline (siendo jugada/resuelta)
var _card_in_pipeline: Dictionary = {}
var _pipeline_context: Dictionary = {}
var _is_pipeline_active: bool = false

# =============================================================================
# EXHUMAR - Cartas jugables desde el Cementerio (Sección 8)
# =============================================================================
## Flag para tracking de cartas jugadas con Exhumar
var _played_via_exhumar: bool = false


func _ready() -> void:
	# (2026-08-28, "módulos gordos" punto 1): ActionModule/GameManager/
	# AnimationQueue se cacheaban vía get_node_or_null() pero no se usaban
	# en ningún otro punto de este archivo — cacheo muerto.
	print("[ActionExecutor] Inicializado")


# =============================================================================
# EJECUCIÓN DE BLOQUES DE HABILIDAD — ELIMINADO (2026-08-17)
# =============================================================================
# execute_ability()/execute_ability_blocks() y todo lo que colgaba
# exclusivamente de ahí (_verify_trigger, _can_pay_costs/_can_pay_single_
# cost/_pay_cost, _request_card_selection, _execute_effect y las 14
# funciones de efectos específicos que solo _execute_effect llamaba,
# _should_continue_pipeline) tenían CERO llamadores en todo el proyecto —
# ni el juego real ni TestScene.gd. Las señales que emitían (ability_
# execution_started/completed, action_executed, cost_paid, action_*_
# completed) se dejaron declaradas arriba porque AnimationQueue.gd se
# conecta a ellas directamente sin has_signal() — borrarlas rompería esa
# conexión aunque ya nunca se disparen. El camino real de ejecución de
# acciones es TriggerSystem → UniversalCardParser → ActionModule.
# =============================================================================
# PASO D - VENTANA DE RESPUESTA (DAR Sección 6)
# =============================================================================
func open_response_window(triggering_card: Node, context: Dictionary = {}) -> Dictionary:
	"""Abre la ventana de respuesta para el oponente

	Después de que el jugador activo completa el Paso A (ej: elige efectos),
	el sistema pausa y permite al oponente responder.

	Args:
		triggering_card: La carta que activó la ventana
		context: Contexto adicional (efectos elegidos, etc.)

	Returns: {had_response, response_card, passed}
	"""
	var result = {
		"had_response": false,
		"response_card": null,
		"passed": false,
		"timed_out": false
	}

	_waiting_for_response = true
	_response_pending = null

	print("[ActionExecutor] Ventana de respuesta abierta para oponente")
	emit_signal("waiting_for_opponent_response", triggering_card, context)

	# Esperar respuesta o timeout
	var elapsed: float = 0.0
	while _waiting_for_response and elapsed < _response_timeout:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1

	# Evaluar resultado
	if _response_pending != null:
		result.had_response = true
		result.response_card = _response_pending
		emit_signal("opponent_responded", _response_pending)
	elif elapsed >= _response_timeout:
		result.timed_out = true
		result.passed = true
		print("[ActionExecutor] Timeout - oponente pasa automáticamente")
	else:
		result.passed = true

	_waiting_for_response = false
	emit_signal("response_window_closed", result.had_response)

	return result


func submit_response(response_card: Node) -> void:
	"""El oponente juega una carta en respuesta

	Args:
		response_card: Carta jugada como respuesta
	"""
	if not _waiting_for_response:
		push_warning("[ActionExecutor] No hay ventana de respuesta activa")
		return

	_response_pending = response_card
	_waiting_for_response = false
	print("[ActionExecutor] Oponente respondió con: %s" % response_card.card_name if response_card.get("card_name") else "carta")


func pass_response() -> void:
	"""El oponente pasa (no responde)"""
	if not _waiting_for_response:
		return

	_response_pending = null
	_waiting_for_response = false
	emit_signal("opponent_passed")
	print("[ActionExecutor] Oponente pasó")


func is_waiting_for_response() -> bool:
	"""Retorna si hay una ventana de respuesta activa"""
	return _waiting_for_response


func set_response_timeout(seconds: float) -> void:
	"""Configura el tiempo máximo de espera para respuestas"""
	_response_timeout = max(5.0, seconds)


# =============================================================================
# PRIORIDAD INTERCALADA (Sección 5.C3) — ELIMINADO (2026-08-17):
# request_priority_window/get_priority_stack/clear_priority_stack/
# is_priority_window_active/get_responding_player/check_can_respond y sus
# 3 señales (priority_check_required/priority_passed/priority_used, sin
# conexiones externas) tenían CERO llamadores en todo el proyecto — un
# segundo mecanismo de ventana de prioridad, nunca conectado, en paralelo
# al que sí funciona (PriorityManager).
# =============================================================================
# =============================================================================
# GESTIÓN DEL ACTION PIPELINE (Paso A-D)
# =============================================================================
func enter_pipeline(card_data: Dictionary, context: Dictionary = {}) -> void:
	"""Registra una carta entrando al ActionPipeline (Paso A)

	Cuando una carta entra al pipeline, queda expuesta a respuestas
	hasta que se resuelva (Paso E) o sea anulada.

	Args:
		card_data: Datos de la carta siendo jugada
		context: Contexto (efectos pendientes, jugador, etc.)
	"""
	_card_in_pipeline = card_data.duplicate(true)
	_card_in_pipeline["is_annulled"] = false
	_card_in_pipeline["entered_pipeline_at"] = Time.get_unix_time_from_system()

	_pipeline_context = context.duplicate(true)
	_pipeline_context["pending_effects"] = context.get("pending_effects", [])
	_pipeline_context["controller_id"] = context.get("controller_id", 0)

	_is_pipeline_active = true

	print("[ActionExecutor] Carta entró al pipeline: %s" % card_data.get("name", "???"))


func exit_pipeline() -> Dictionary:
	"""Saca la carta del pipeline (después de Paso E o anulación)

	Returns: Datos de la carta que salió del pipeline
	"""
	var exited_card = _card_in_pipeline.duplicate(true)

	_card_in_pipeline = {}
	_pipeline_context = {}
	_is_pipeline_active = false
	_played_via_exhumar = false  # Reset flag

	print("[ActionExecutor] Carta salió del pipeline")
	return exited_card


# =============================================================================
# EXHUMAR - Jugar cartas desde el Cementerio (Sección 8)
# =============================================================================
func get_exhumable_cards(player_id: int, cemetery: Array) -> Array:
	"""Obtiene cartas con Exhumar jugables desde el Cementerio

	Detecta cartas en el cementerio que tienen el trait has_exhumar
	o la keyword EXHUMAR, haciéndolas opciones jugables.

	Args:
		player_id: ID del jugador
		cemetery: Array de cartas en el cementerio

	Returns: Array de cartas jugables via Exhumar
	"""
	var exhumable: Array = []

	for card in cemetery:
		if _card_has_exhumar(card):
			exhumable.append(card)

	return exhumable


func _card_has_exhumar(card_data: Dictionary) -> bool:
	"""Verifica si una carta tiene la habilidad Exhumar"""
	# Verificar en traits
	var traits = card_data.get("traits", {})
	if traits.get("has_exhumar", false):
		return true

	# Verificar en keywords (array)
	var keywords = card_data.get("keywords", [])
	for kw in keywords:
		if kw is String and kw.to_upper() == "EXHUMAR":
			return true
		if kw is int and kw == Constants.Keyword.EXHUMAR:
			return true

	# Verificar en habilidad texto
	var ability = card_data.get("ability", card_data.get("habilidad", ""))
	if "exhumar" in ability.to_lower():
		return true

	return false


func play_card_via_exhumar(card_data: Dictionary, player_id: int) -> Dictionary:
	"""Juega una carta desde el Cementerio usando Exhumar

	Cuando una carta se juega via Exhumar:
	1. Se paga su coste normalmente
	2. Se resuelve como siempre
	3. Su destino final es SIEMPRE Destierro (no Cementerio)

	Args:
		card_data: Datos de la carta a jugar
		player_id: ID del jugador

	Returns: {success, card, played_from}
	"""
	var result = {
		"success": false,
		"card": card_data,
		"played_from": "CEMENTERIO",
		"final_destination": "DESTIERRO"
	}

	if not _card_has_exhumar(card_data):
		result.error = "La carta no tiene Exhumar"
		return result

	# Marcar flag de Exhumar activo
	_played_via_exhumar = true

	# Registrar en el pipeline con context especial
	var exhumar_context = {
		"controller_id": player_id,
		"played_from": Constants.Zone.CEMENTERIO,
		"played_via_exhumar": true,
		"force_destination": "DESTIERRO"
	}

	enter_pipeline(card_data, exhumar_context)

	result.success = true
	print("[ActionExecutor] Carta jugada via EXHUMAR: %s" % card_data.get("name", "???"))
	print("[ActionExecutor] Destino final forzado: DESTIERRO")

	return result


func is_played_via_exhumar() -> bool:
	"""Verifica si la carta actual fue jugada via Exhumar"""
	return _played_via_exhumar


func get_final_destination(card_data: Dictionary) -> String:
	"""Determina el destino final de una carta según contexto

	Prioridades:
	1. Si la carta dice BANISH_SELF → DESTIERRO (incluso si anulada)
	2. Si fue jugada via Exhumar → DESTIERRO
	3. Si no → según resolution_rules u on_resolution

	Args:
		card_data: Datos de la carta

	Returns: String del destino (CEMENTERIO, DESTIERRO, etc.)
	"""
	# Prioridad 1: Si la carta dice "destiérrala", siempre va al destierro
	# (incluso si fue anulada - el destino propio de la carta tiene prioridad)
	var on_resolution = card_data.get("on_resolution", "")
	if on_resolution == "BANISH_SELF":
		return "DESTIERRO"

	# Prioridad 2: Si fue jugada via Exhumar
	if _played_via_exhumar:
		return "DESTIERRO"

	# Nota: Si fue anulada pero NO tiene BANISH_SELF, va al cementerio por defecto
	if _card_in_pipeline.get("is_annulled", false):
		return "CEMENTERIO"

	# Prioridad 3: resolution_rules (formato JSON estructurado)
	var resolution_rules = card_data.get("resolution_rules", {})
	if _played_via_exhumar and resolution_rules.has("on_exhumar_resolve"):
		var dest = resolution_rules.get("on_exhumar_resolve", "")
		return _normalize_destination(dest)

	if resolution_rules.has("on_resolve"):
		var dest = resolution_rules.get("on_resolve", "")
		return _normalize_destination(dest)

	# Prioridad 4: on_resolution (formato simple) - ya tenemos la variable desde arriba
	if on_resolution.is_empty():
		on_resolution = "GRAVEYARD"
	return _normalize_destination(on_resolution)


func _normalize_destination(dest: String) -> String:
	"""Normaliza strings de destino a formato estándar"""
	match dest.to_upper():
		"MOVE_TO_CEMENTERIO", "GRAVEYARD", "CEMENTERIO":
			return "CEMENTERIO"
		"MOVE_TO_DESTIERRO", "BANISH_SELF", "EXILE", "DESTIERRO":
			return "DESTIERRO"
		"MOVE_TO_MANO", "RETURN_TO_HAND", "HAND", "MANO":
			return "MANO"
		"MOVE_TO_CASTILLO", "RETURN_TO_DECK", "DECK", "CASTILLO":
			return "CASTILLO"
		_:
			return "CEMENTERIO"


func get_card_in_pipeline() -> Dictionary:
	"""Obtiene la carta actualmente en el pipeline

	Returns: Datos de la carta o {} si no hay ninguna
	"""
	return _card_in_pipeline


func get_pipeline_context() -> Dictionary:
	"""Obtiene el contexto del pipeline actual"""
	return _pipeline_context


func is_pipeline_active() -> bool:
	"""Verifica si hay una carta en el pipeline"""
	return _is_pipeline_active


func can_target_card_in_pipeline(response_card_data: Dictionary) -> Dictionary:
	"""Verifica si una carta de respuesta puede apuntar a la carta en el pipeline

	Evalúa las condiciones de la carta de respuesta contra la carta objetivo.

	Args:
		response_card_data: Datos de la carta de respuesta (ej: Hacer el Bien)

	Returns: {can_target, reason, target_card}
	"""
	var result = {
		"can_target": false,
		"reason": "",
		"target_card": {}
	}

	if not _is_pipeline_active:
		result.reason = "No hay carta en el pipeline"
		return result

	var target_card = _card_in_pipeline
	result.target_card = target_card

	# Verificar que la carta en pipeline no esté ya anulada
	if target_card.get("is_annulled", false):
		result.reason = "La carta ya fue anulada"
		return result

	# Obtener condiciones de la carta de respuesta
	var hability_blocks = response_card_data.get("hability_blocks", [])

	for block in hability_blocks:
		if block.get("type") != "RESPONSE":
			continue

		# Verificar target_type
		var target_type = block.get("target_type", "")
		if target_type != "CARD_IN_STACK" and target_type != "CARD_IN_PIPELINE":
			continue

		# Verificar condiciones
		var conditions = block.get("conditions", [])
		var all_conditions_met = true

		for condition in conditions:
			if not _evaluate_condition(condition, target_card):
				all_conditions_met = false
				result.reason = "No cumple condición: %s %s %s" % [
					condition.get("attribute", ""),
					condition.get("operator", ""),
					condition.get("value", "")
				]
				break

		if all_conditions_met:
			result.can_target = true
			result.reason = "Puede apuntar"
			return result

	if result.reason.is_empty():
		result.reason = "Sin bloque de respuesta válido"

	return result


func _evaluate_condition(condition: Dictionary, target_card: Dictionary) -> bool:
	"""Evalúa una condición contra una carta objetivo (Sección 6 - Validación)

	Args:
		condition: {attribute, operator, value}
		target_card: Carta a evaluar

	Returns: true si la condición se cumple
	"""
	var attribute = condition.get("attribute", "")
	var operator = condition.get("operator", "==")
	var value = condition.get("value")

	# Obtener valor del atributo de la carta
	var card_value = _get_card_attribute(target_card, attribute)

	# Convertir a número si es necesario
	if card_value is String and card_value.is_valid_int():
		card_value = int(card_value)
	if value is String and str(value).is_valid_int():
		value = int(value)

	match operator:
		"==", "=":
			return card_value == value
		"!=", "<>":
			return card_value != value
		"<":
			return card_value < value
		"<=":
			return card_value <= value
		">":
			return card_value > value
		">=":
			return card_value >= value
		"contains":
			return str(value).to_lower() in str(card_value).to_lower()
		_:
			return false


func _get_card_attribute(card: Dictionary, attribute: String):
	"""Obtiene un atributo de una carta con fallbacks (Sección 6)

	Para 'cost' usa printed_cost como prioridad (coste impreso, no modificado)

	Args:
		card: Datos de la carta
		attribute: Nombre del atributo

	Returns: Valor del atributo
	"""
	match attribute:
		"cost", "coste":
			# Prioridad: printed_cost > cost > coste
			if card.has("printed_cost"):
				return card.printed_cost
			if card.has("cost"):
				return card.cost
			if card.has("coste"):
				return card.coste
			return 0

		"type", "tipo":
			if card.has("type"):
				return card.type
			if card.has("tipo"):
				return card.tipo
			return ""

		"strength", "fuerza":
			# Para fuerza usamos el valor impreso también
			if card.has("printed_strength"):
				return card.printed_strength
			if card.has("strength"):
				return card.strength
			if card.has("fuerza"):
				return card.fuerza
			return 0

		"name", "nombre":
			if card.has("name"):
				return card.name
			if card.has("nombre"):
				return card.nombre
			return ""

		_:
			return card.get(attribute, null)


func validate_annul_target(annuller_card: Dictionary, target_card: Dictionary) -> Dictionary:
	"""Valida si una carta puede ser anulada por otra (Sección 6)

	Verifica todas las condiciones del efecto de anulación
	contra la carta objetivo.

	Args:
		annuller_card: Carta que intenta anular (ej: Hacer el Bien)
		target_card: Carta objetivo en el pipeline

	Returns: {valid, reason, conditions_checked}
	"""
	var result = {
		"valid": false,
		"reason": "",
		"conditions_checked": []
	}

	var hability_blocks = annuller_card.get("hability_blocks", [])

	for block in hability_blocks:
		if block.get("type") != "RESPONSE":
			continue

		var effect = block.get("effect", {})
		if effect.get("action") != "ANNUL":
			continue

		var conditions = block.get("conditions", [])

		# Si no hay condiciones, puede anular cualquier cosa
		if conditions.is_empty():
			result.valid = true
			result.reason = "Sin restricciones de condición"
			return result

		# Verificar cada condición
		var all_met = true
		for condition in conditions:
			var attr = condition.get("attribute", "")
			var op = condition.get("operator", "")
			var val = condition.get("value")
			var card_val = _get_card_attribute(target_card, attr)

			var condition_met = _evaluate_condition(condition, target_card)

			result.conditions_checked.append({
				"attribute": attr,
				"operator": op,
				"required_value": val,
				"actual_value": card_val,
				"met": condition_met
			})

			if not condition_met:
				all_met = false
				result.reason = "Condición no cumplida: %s (valor: %s, requerido: %s %s)" % [
					attr, str(card_val), op, str(val)
				]

		if all_met:
			result.valid = true
			result.reason = "Todas las condiciones cumplidas"
			return result

	if result.reason.is_empty():
		result.reason = "No se encontró bloque de anulación válido"

	return result


# =============================================================================
# SECCIÓN 8 - ANULACIÓN
# =============================================================================
func annul_card_in_pipeline(annuller_card: Dictionary) -> Dictionary:
	"""Anula la carta actualmente en el pipeline (Sección 8)

	Marca la carta como anulada, cancela sus efectos pendientes,
	y determina su destino. Si la carta anulada dice "destiérrala"
	(BANISH_SELF), va al destierro aunque sea anulada.

	Args:
		annuller_card: Carta que realiza la anulación (ej: Hacer el Bien)

	Returns: {success, annulled_card, cancelled_effects, destination}
	"""
	var result = {
		"success": false,
		"annulled_card": {},
		"cancelled_effects": [],
		"destination": "CEMENTERIO"
	}

	if not _is_pipeline_active:
		result.error = "No hay carta en el pipeline"
		return result

	# Marcar como anulada
	_card_in_pipeline["is_annulled"] = true
	_card_in_pipeline["annulled_by"] = annuller_card.get("name", "???")
	_card_in_pipeline["annulled_at"] = Time.get_unix_time_from_system()

	result.success = true
	result.annulled_card = _card_in_pipeline.duplicate(true)
	result.cancelled_effects = _pipeline_context.get("pending_effects", [])

	# Prioridad de destino: La carta anulada tiene prioridad si dice BANISH_SELF
	var annulled_on_resolution = _card_in_pipeline.get("on_resolution", "")
	if annulled_on_resolution == "BANISH_SELF":
		result.destination = "DESTIERRO"
	else:
		# Si no, usar destino del anulador (default: CEMENTERIO)
		var hability_blocks = annuller_card.get("hability_blocks", [])
		for block in hability_blocks:
			if block.get("type") == "RESPONSE":
				var effect = block.get("effect", {})
				if effect.get("action") == "ANNUL":
					result.destination = effect.get("destination", "CEMENTERIO")
					break

	var card_name = _card_in_pipeline.get("name", "???")
	var annuller_name = annuller_card.get("name", "???")

	print("[ActionExecutor] ANULACIÓN: %s anuló a %s" % [annuller_name, card_name])
	print("[ActionExecutor] Efectos cancelados: %d" % result.cancelled_effects.size())
	print("[ActionExecutor] Destino: %s" % result.destination)

	# Emitir señal
	emit_signal("spell_annulled", null, null)

	return result


func is_card_annulled() -> bool:
	"""Verifica si la carta en el pipeline fue anulada"""
	return _card_in_pipeline.get("is_annulled", false)


func check_annullment(response_card) -> bool:
	"""Verifica si la carta de respuesta es una Anulación

	Args:
		response_card: Carta (Node o Dictionary) jugada en respuesta

	Returns: true si es una carta de anulación
	"""
	if response_card == null:
		return false

	# Soportar tanto Node como Dictionary
	var card_type = ""
	var card_name = ""
	var keywords = []

	if response_card is Dictionary:
		card_type = str(response_card.get("type", response_card.get("tipo", "")))
		card_name = str(response_card.get("name", response_card.get("nombre", ""))).to_lower()
		keywords = response_card.get("keywords", [])
	elif is_instance_valid(response_card):
		if response_card.has_method("get_card_type"):
			card_type = response_card.get_card_type()
		elif response_card.get("card_type"):
			card_type = str(response_card.card_type)
		if response_card.get("card_name"):
			card_name = response_card.card_name.to_lower()
		if response_card.get("keywords"):
			keywords = response_card.keywords
	else:
		return false

	# Es anulación si:
	# 1. Tipo es "Anulación" o "Counter"
	if card_type.to_lower() in ["anulación", "anulacion", "counter"]:
		return true

	# 2. Nombre contiene "anula" o "counter"
	if "anula" in card_name or "counter" in card_name:
		return true

	# 3. Tiene la palabra "ANULAR" en su lista de keywords de texto — Anular
	# no es una keyword fija en Mitos y Leyendas, es un efecto de carta.
	if not keywords.is_empty():
		for kw in keywords:
			if kw is String and kw.to_upper() == "ANULAR":
				return true

	return false


# process_annullment() eliminado (2026-08-17): cero llamadores en todo el
# proyecto. La anulación real (Sección 8) la resuelve TriggerSystem/
# ActionModule cuando una carta con keyword ANULAR responde.
# =============================================================================
# SINCRONIZACIÓN DE UI (MULTIPLAYER)
# =============================================================================
func sync_effects_to_opponent(player_id: int, card_data: Dictionary, selected_effects: Array) -> void:
	"""Envía la selección de efectos al cliente del oponente

	Usado para sincronizar UI en partidas multijugador.
	El oponente verá qué efectos se intentarán resolver.

	Args:
		player_id: ID del jugador que seleccionó
		card_data: Datos de la carta jugada
		selected_effects: Array de efectos seleccionados [{id, text, action}]
	"""
	var sync_data = {
		"player_id": player_id,
		"card_name": card_data.get("name", card_data.get("nombre", "???")),
		"card_type": card_data.get("type", card_data.get("tipo", "")),
		"effects": []
	}

	for effect in selected_effects:
		sync_data.effects.append({
			"id": effect.get("id", ""),
			"text": effect.get("text", "???"),
			"action_type": effect.get("action", {}).get("type", "UNKNOWN")
		})

	print("[ActionExecutor] Sincronizando efectos al oponente: %s" % sync_data.card_name)

	# Emitir señal para que el sistema de red la capture
	emit_signal("broadcast_pending_effects", player_id, card_data, selected_effects)
	emit_signal("effects_synced_to_opponent", sync_data.card_name, sync_data.effects)

	# TODO: Aquí se conectaría con el sistema de networking
	# NetworkManager.send_to_opponent(sync_data)

# receive_opponent_effects()/begin_resolution()/apply_post_resolution_
# condition()/_get_game_board() eliminados (2026-08-17): cero llamadores
# en todo el proyecto (ni el juego real ni TestScene.gd). begin_resolution
# era el único lugar que usaba _execute_effect() (ya eliminado junto con
# execute_ability); apply_post_resolution_condition dependía de
# _get_game_board(), que quedaba huérfano sin ninguna función que lo
# llamara tras este recorte.
