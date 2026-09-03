extends RefCounted
class_name TriggerResolution
## TriggerResolution — Saca triggers de la cola y los resuelve uno por uno
## (ventana de respuesta inmediata + ejecución del efecto, con fallback a
## extract_action() si la carta no tiene handler propio). Opera sobre
## TriggerSystem via _main (cola compartida, señales).
## Extraído de TriggerSystem.gd (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func resolve_next_trigger() -> Dictionary:
	"""Resuelve el siguiente trigger en la cola con ventana de respuesta
	DAR Sección 8: Permite cancelación antes de resolver
	Returns: El trigger resuelto o {} si no hay más
	"""
	if _main.trigger_queue.is_empty():
		_main.is_resolving = false
		_main.emit_signal("all_triggers_resolved")
		return {}

	_main.is_resolving = true
	var trigger = _main.trigger_queue.pop_front()

	var card: Node = trigger.card
	var trigger_type: String = trigger.trigger_type
	var event_data: Dictionary = trigger.event_data
	var controller_id: int = trigger.get("controller_id", 0)

	# Verificar que la carta sigue en juego
	if not is_instance_valid(card):
		print("[TriggerSystem] Carta ya no existe, saltando trigger")
		return await resolve_next_trigger()

	if not card.is_in_play():
		print("[TriggerSystem] %s ya no está en juego, saltando trigger" % card.card_name)
		return await resolve_next_trigger()

	# Verificar si un efecto continuo negativo bloquea este trigger
	if _main._restrictions.is_blocked_by_continuous_effect(card, trigger_type):
		print("[TriggerSystem] %s bloqueado por efecto continuo" % trigger_type)
		return await resolve_next_trigger()

	# === PASO D: VENTANA DE RESPUESTA (DAR Sección 8 - Cancelar) ===
	var opponent_id = 1 - controller_id
	_main.current_trigger_for_response = trigger
	_main.awaiting_response = true

	print("[TriggerSystem] Resolviendo trigger de inmediato: %s" % card.card_name)
	_main.emit_signal("waiting_for_responses", trigger, opponent_id)

	# Esperar respuesta o timeout
	var was_cancelled = await _wait_for_response_window()

	_main.awaiting_response = false
	_main.emit_signal("response_window_closed", trigger, was_cancelled)

	if was_cancelled:
		print("[TriggerSystem] %s fue CANCELADO" % trigger_type)
		_main.emit_signal("trigger_cancelled", card, trigger_type, null)
		return await resolve_next_trigger()

	# === RESOLVER "EN MEDIDA DE LO POSIBLE" (DAR Sección 8) ===
	print("[TriggerSystem] Resolviendo: %s de %s" % [trigger_type, card.card_name])

	var result = await _execute_trigger_effect(card, trigger_type, event_data)
	result["card"] = card
	result["type"] = trigger_type

	_main.emit_signal("trigger_resolved", card, trigger_type, result)

	return trigger


func _wait_for_response_window() -> bool:
	"""Resuelve el trigger de inmediato, sin abrir una ventana de prioridad.
	Returns: true si fue cancelado, false si pasó

	Antes abría una ventana real vía PriorityManager y esperaba a que el
	oponente (bot) le pasara la prioridad — mecánicamente funcionaba, pero
	el bot nunca responde nada de verdad todavía (no hay IA real), así que
	esa espera era pura fricción: obligaba al jugador a presionar ¿Paso?
	para cada carta con 'cuando entra en juego'/'cuando ataque' antes de
	poder seguir jugando, sin ningún beneficio (nadie iba a cancelar nada).
	A pedido del usuario (2026-08-17), los triggers ahora se resuelven de
	inmediato.

	EXCEPCIÓN (2026-08-26, Signo Amarillo): si el trigger viene de un Oro o
	de una carta fuera del juego (mano/destierro/cementerio/castillo) Y el
	rival controla un Oro sin convertir con el texto de Signo Amarillo, ahí
	sí hay algo real que puede pasar — se espera de verdad a que responda.
	resolve_next_trigger() ya emitió waiting_for_responses ANTES de llamar
	acá (línea de arriba, sin condición) — CardInspectionLayer la escucha y
	solo muestra el botón de Signo Amarillo si encuentra uno disponible, así
	que no hace falta emitir de nuevo, solo esperar. En cualquier otro caso
	se sigue resolviendo al instante, sin fricción."""
	if _main.pending_cancel_callback.is_valid():
		_main.pending_cancel_callback = Callable()
		return true

	if _signo_amarillo_response_available():
		var elapsed := 0.0
		while elapsed < 8.0 and _main.awaiting_response:
			if _main.pending_cancel_callback.is_valid():
				_main.pending_cancel_callback = Callable()
				return true
			await _main.get_tree().create_timer(0.1).timeout
			elapsed += 0.1

	return false


func _signo_amarillo_response_available() -> bool:
	"""¿Este trigger es cancelable por Signo Amarillo (habilidad de Oro o de
	fuera del juego) y el rival tiene uno sin convertir para hacerlo?"""
	var trigger: Dictionary = _main.current_trigger_for_response
	if trigger.is_empty():
		return false
	var card: Node = trigger.get("card")
	if not card or not is_instance_valid(card):
		return false

	var qualifies: bool = card.get("card_type") == Constants.CardType.ORO
	if not qualifies:
		var off_board_zones = [Constants.Zone.MANO, Constants.Zone.DESTIERRO, Constants.Zone.CEMENTERIO, Constants.Zone.CASTILLO]
		qualifies = card.get("current_zone") in off_board_zones
	if not qualifies:
		return false

	var controller_id: int = trigger.get("controller_id", 0)
	return _find_signo_amarillo(1 - controller_id) != null


func _find_signo_amarillo(player_id: int) -> Node:
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return null
	var container = main.player_gold if player_id == 0 else main.opponent_gold
	if not container:
		return null
	for c in container.get_children():
		if not is_instance_valid(c) or c.get("is_converted") == true:
			continue
		var ability_text: String = str(c.get("card_ability") if c.get("card_ability") != null else "")
		if "convertir este oro en un oro sin habilidad" in ability_text.to_lower():
			return c
	return null


func cancel_current_trigger(cancelling_card: Node = null) -> bool:
	"""Cancela el trigger actual en la ventana de respuesta
	Llamado cuando el oponente usa una habilidad de cancelación
	"""
	if not _main.awaiting_response:
		return false

	if _main.current_trigger_for_response.is_empty():
		return false

	_main.pending_cancel_callback = func(): pass  # Flag para indicar cancelación
	var card = _main.current_trigger_for_response.get("card")
	var trigger_type = _main.current_trigger_for_response.get("trigger_type", "")

	print("[TriggerSystem] Cancelando %s con %s" % [
		trigger_type,
		cancelling_card.card_name if cancelling_card else "efecto"
	])

	_main.emit_signal("trigger_cancelled", card, trigger_type, cancelling_card)
	return true


func pass_response() -> void:
	"""El jugador pasa su oportunidad de responder"""
	_main.awaiting_response = false


func _resolve_look_and_play_patterns(card: Node, full_ability_text: String, isolated_ability_text: String, controller_id: int, event_data: Dictionary) -> bool:
	"""Prueba en orden los patrones compuestos "muestra/mira N..." (cada uno
	con su propio regex específico, así que reciben el texto COMPLETO, no
	aislado a una oración — ver historial de por qué) y si ninguno matchea
	cae al genérico extract_action() + execute_parsed_action() sobre el
	texto aislado. Compartido entre la resolución de habilidades disparadas
	(on_enter_play/on_ally_enters de Aliados/Armas/Oro) y la resolución
	directa de Talismanes (TriggerSystem.resolve_talisman(), que NO pasa
	por la cola de triggers — 2026-08-27, a pedido del usuario: 'los
	Talismanes no disparan, resuelven').
	Returns: true si algo se ejecutó."""
	if await _main._look_and_play.try_execute_look_pick_pattern(full_ability_text, controller_id):
		return true
	if await _main._look_and_play.try_execute_look_play_free_pattern(full_ability_text, card, controller_id):
		return true
	if await _main._look_and_play.try_execute_look_play_or_hand_pattern(full_ability_text, card, controller_id):
		return true
	if await _main._look_and_play.try_execute_look_play_or_gold_pattern(full_ability_text, card, controller_id):
		return true
	if await _main._look_and_play.try_execute_look_dynamic_gold_count_pattern(full_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_draw_gold_search_pattern(full_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_draw_reveal_talisman_gold_pattern(full_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_deck_top_or_bottom_to_hand_pattern(full_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_shuffle_exile_and_draw_pattern(full_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_shuffle_hand_and_draw_plus_two_pattern(full_ability_text, controller_id):
		return true
	if await _main._convert_misc_resolver.try_execute_mill_convert_to_ally_pattern(full_ability_text, card, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_tempilcahue_choice_pattern(full_ability_text, card, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_golpe_solar_pattern(full_ability_text, card, controller_id):
		return true
	# Estos dos, a diferencia de todos los de arriba, chequean sobre el texto
	# YA AISLADO al bloque de este trigger en particular (no el texto
	# completo de la carta) — 2026-08-29: una carta puede tener el MISMO
	# trigger repetido dos veces (Alicia en Wonderland), y este resolutor se
	# llama una vez POR BLOQUE; si estos dos chequearan full_ability_text
	# (que no cambia entre llamadas) se dispararían dos veces, una por cada
	# bloque de la carta.
	if await _main._look_and_play.try_execute_reveal_until_distinct_cost_allies_pattern(isolated_ability_text, controller_id):
		return true
	if await _main._convert_misc_resolver.try_execute_name_a_card_pattern(isolated_ability_text, card, controller_id):
		return true
	if await _main._convert_misc_resolver.try_execute_opponent_discard_and_draw_pattern(isolated_ability_text, card, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_banish_from_cemeteries_and_draw_pattern(isolated_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_weapon_count_banish_cemetery_pattern(isolated_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_draw_and_shuffle_hand_pattern(isolated_ability_text, controller_id):
		return true
	if await _main._draw_shuffle_resolver.try_execute_draw_and_shuffle_opponent_card_pattern(isolated_ability_text, controller_id):
		return true
	if await _main._convert_misc_resolver.try_execute_banish_top_by_ally_count_and_draw_pattern(isolated_ability_text, controller_id):
		return true
	var action := UniversalCardParser.extract_action(isolated_ability_text)
	if action.get("matched", false):
		await _main._targeted_executor.execute_parsed_action(action, card, event_data)
		return true
	return false


func _execute_trigger_effect(card: Node, trigger_type: String, event_data: Dictionary) -> Dictionary:
	"""Ejecuta el efecto del trigger usando Callable
	Resuelve 'en medida de lo posible' (DAR Sección 8)
	"""
	var result = {
		"resolved": true,
		"partial": false,
		"blocked_by": null
	}

	# Verificar si la carta tiene un handler ESPECÍFICO para este trigger
	# (Card.effect_handlers) — 'handled' solo queda true si de verdad hizo
	# algo. Antes, cualquier Card (TODAS tienen _on_trigger_event definido
	# en la clase base) cortaba acá sin importar el resultado, así que el
	# fallback bueno de más abajo (aísla la oración correcta, reconoce
	# SEARCH/DESTROY/BUFF/etc.) nunca se ejecutaba — Card._on_trigger_event()
	# caía en su propio _resolve_default_effect(), un escaneo de palabras
	# clave sobre el texto COMPLETO sin aislar por oración (2026-08-22: por
	# esto Tyet, cuyo texto tiene 'busca un Arma...' Y 'Robar dos cartas' de
	# una habilidad de Oro totalmente distinta más adelante, terminaba
	# robando una carta en vez de buscar). _resolve_default_effect() se
	# eliminó y _on_trigger_event() ahora marca no_handler=true cuando no
	# hay handler específico, dejando pasar la ejecución hasta acá.
	var handled := false
	if card.has_method("_on_trigger_event"):
		var effect_callable: Callable = card._on_trigger_event
		var effect_result = await effect_callable.call(trigger_type, event_data)
		if effect_result is Dictionary:
			result.merge(effect_result, true)
			handled = not effect_result.get("no_handler", false)
	elif card.has_method("execute_ability"):
		await card.execute_ability(trigger_type, event_data)
		handled = true

	if not handled:
		# ── Fallback: parsear texto de la carta con extract_action() ─────────
		# Cubre habilidades ETB declaradas en texto plano ("Cuando entra: Roba dos cartas")
		result["no_handler"] = true
		if trigger_type in ["on_enter_play", "on_ally_enters"]:
			var full_ability_text: String = ""
			if card.get("card_data") != null:
				full_ability_text = card.card_data.get("habilidad", "")
			# Aislar la(s) oración(es) de ENTRA (2026-08-22, mismo bug que
			# on_attack/on_damage_dealt de más abajo, nunca se había
			# corregido acá): una carta puede tener "Cuando entra en juego,
			# X.\nEn tu Fase Final, Y." en el mismo bloque — sin aislar,
			# extract_action() podía encontrar Y (p.ej. un 'Destierra...' de
			# Fase Final) como la PRIMERA acción reconocible del texto
			# completo y ejecutarla al entrar en juego, disparando el efecto
			# equivocado.
			# 2026-08-29: una carta puede tener DOS "Cuando entra en juego"
			# independientes (p.ej. Alicia en Wonderland) — se procesa cada
			# bloque aislado por separado, no solo el primero.
			var clauses: Array[String] = _isolate_all_trigger_clauses(full_ability_text, ["cuando entra", "al entrar"])
			if clauses.is_empty() and not full_ability_text.is_empty():
				clauses = [full_ability_text]
			var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
			for ability_text: String in clauses:
				var resolved := await _resolve_look_and_play_patterns(card, full_ability_text, ability_text, controller_id, event_data)
				if resolved:
					result["no_handler"] = false
		elif trigger_type == "on_leave_play":
			# 'Al salir del juego'/'cuando salga del juego'/'cuando entra o
			# salga del juego' (2026-08-29, p.ej. Legión Paladín) — hasta acá
			# solo on_enter_play/on_ally_enters tenían fallback genérico por
			# texto; on_leave_play nunca resolvía nada por este camino, sin
			# importar qué tan bien detectado estuviera el patrón en
			# TargetedEffectExecutor/LookAndPlayResolver.
			var full_ability_text: String = ""
			if card.get("card_data") != null:
				full_ability_text = card.card_data.get("habilidad", "")
			var ability_text := _isolate_trigger_clause(full_ability_text, [
				"al salir del juego", "cuando salga del juego", "cuando sale del juego", "cuando entra o salga del juego"
			])
			if ability_text.is_empty():
				ability_text = full_ability_text
			if not ability_text.is_empty():
				var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
				var resolved := await _resolve_look_and_play_patterns(card, full_ability_text, ability_text, controller_id, event_data)
				if resolved:
					result["no_handler"] = false
		elif trigger_type == "on_attack":
			# No usar extract_action() sobre el texto completo: una carta puede
			# tener "Cuando entra en juego, Roba dos cartas. Cuando ataque, ..."
			# en el mismo bloque, y extract_action() encuentra la PRIMERA acción
			# reconocible en todo el texto sin importar bajo qué disparador
			# está — dispararía de nuevo el robo de la entrada. Por eso acá se
			# aísla primero la oración que contiene la frase de "ataque".
			var ability_text: String = ""
			if card.get("card_data") != null:
				ability_text = card.card_data.get("habilidad", "")
			# "cuando entra en juego o ataque" (2026-08-29, p.ej. Sherlock
			# Holmes) es la misma cláusula que el disparador de entrada — no
			# tiene 'cuando ataque' como substring literal.
			var clause := _isolate_trigger_clause(ability_text, [
				"cuando ataque", "cuando atac", "al atacar", "en juego o ataque"
			])
			if not clause.is_empty():
				var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
				if await _main._convert_misc_resolver.try_execute_mill_convert_to_ally_pattern(clause, card, controller_id):
					result["no_handler"] = false
				else:
					var action := UniversalCardParser.extract_action(clause)
					if action.get("matched", false):
						await _main._targeted_executor.execute_parsed_action(action, card, event_data)
						result["no_handler"]    = false
					result["parsed_action"] = action
		elif trigger_type == "on_turn_end":
			# 'En tu Fase Final'/'Al final del turno' (2026-08-30, p.ej.
			# Espada de O'Higgins) — primer trigger de este tipo que
			# realmente resuelve algo; hasta ahora TriggerSystem.
			# resolve_turn_end_triggers() nunca se llamaba desde ningún lado
			# y esta rama no existía, así que ninguna carta con este texto
			# había hecho nada jamás. Mismo aislamiento de oración que
			# on_attack/on_damage_dealt, por la misma razón (una carta puede
			# tener varios disparadores distintos en el mismo bloque).
			var ability_text: String = ""
			if card.get("card_data") != null:
				ability_text = card.card_data.get("habilidad", "")
			var clause := _isolate_trigger_clause(ability_text, [
				"en tu fase final", "al final del turno", "al terminar el turno"
			])
			if not clause.is_empty():
				var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
				var resolved := await _resolve_look_and_play_patterns(card, ability_text, clause, controller_id, event_data)
				if resolved:
					result["no_handler"] = false
		elif trigger_type == "on_agrupacion":
			# 'En tu Agrupación' (2026-08-30, p.ej. Espada del Juicio: 'Cuando
			# entra en juego y en tu Agrupación, Destierra...') — misma
			# oración puede contener DOS disparadores distintos ('cuando
			# entra' Y 'en tu agrupación'); se aísla igual que on_turn_end,
			# y se procesa una vez por cada trigger_type que matchee esa
			# misma oración (no es un doble-disparo, son dos eventos reales
			# distintos que comparten el mismo efecto impreso).
			var ability_text: String = ""
			if card.get("card_data") != null:
				ability_text = card.card_data.get("habilidad", "")
			var clause := _isolate_trigger_clause(ability_text, [
				"en tu agrupación", "en tu agrupacion"
			])
			if not clause.is_empty():
				var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
				var resolved := await _resolve_look_and_play_patterns(card, ability_text, clause, controller_id, event_data)
				if resolved:
					result["no_handler"] = false
		elif trigger_type == "on_damage_dealt":
			# 'Cuando haga daño de combate'/'cuando haga daño'/'si hizo daño'
			# (DAR) — mismo aislamiento de oración que on_attack, por la
			# misma razón: una carta puede tener varios disparadores
			# distintos en el mismo bloque de texto. "Infligir"/"inflija"/
			# "inflige" no es terminología real del juego (2026-08-28, a
			# pedido del usuario) — se sacó de la lista.
			var ability_text: String = ""
			if card.get("card_data") != null:
				ability_text = card.card_data.get("habilidad", "")
			var clause := _isolate_trigger_clause(ability_text, [
				"cuando haga daño de combate", "cuando haga daño", "si hizo daño"
			])
			if not clause.is_empty():
				var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
				if await _main._convert_misc_resolver.try_execute_convert_ally_to_gold_pattern(clause, card, controller_id):
					result["no_handler"] = false
				else:
					var action := UniversalCardParser.extract_action(clause)
					if action.get("matched", false):
						await _main._targeted_executor.execute_parsed_action(action, card, event_data)
						result["no_handler"]    = false
						result["parsed_action"] = action

	return result


func _isolate_trigger_clause(ability_text: String, trigger_phrases: Array) -> String:
	"""Devuelve solo la oración (separada por '.') que contiene alguna de las
	frases disparadoras dadas, para no interpretar el texto de OTRO
	disparador de la misma carta como si fuera el de este evento."""
	if ability_text.is_empty():
		return ""
	for raw_sentence in ability_text.split("."):
		var sentence: String = raw_sentence.strip_edges()
		if sentence.is_empty():
			continue
		var lower_s := sentence.to_lower()
		for phrase in trigger_phrases:
			if phrase in lower_s:
				return sentence
	return ""


func _isolate_all_trigger_clauses(ability_text: String, trigger_phrases: Array) -> Array[String]:
	"""Como _isolate_trigger_clause() pero devuelve TODOS los bloques que
	empiezan con alguna frase de trigger_phrases, no solo el primero — una
	carta puede repetir el MISMO tipo de trigger dos veces con efectos
	independientes (2026-08-29, p.ej. Alicia en Wonderland: dos 'Cuando
	entra en juego' separados, cada uno con su propio efecto). Cada bloque
	junta las oraciones siguientes hasta que aparece:
	  - otra oración que vuelva a matchear trigger_phrases (empieza el
	    siguiente bloque), o
	  - una oración de habilidad ACTIVADA ('una vez por turno'/'una vez al
	    turno'/'una vez en tu turno'/'una vez en su turno') — esas se
	    resuelven por un camino totalmente distinto (parse_abilities() +
	    ActionPipeline) y no deben mezclarse acá aunque no matcheen
	    trigger_phrases (2026-08-29, p.ej. Tesoro de los Césares: el ETB
	    de esta carta son DOS oraciones separadas por punto, seguidas de
	    una habilidad activada en el mismo bloque de texto — sin este corte
	    el bloque del ETB se comía también la activada).
	Ya NO tiene la limitación que este comentario documentaba antes
	(2026-08-30, bug real encontrado: Garfio Pirata — 'Cuando entra en
	juego, el portador no puede salir del juego hasta tu próximo turno.
	Cuando el portador ataque, ... Roba una carta.' — sin el corte de abajo,
	la oración de 'Cuando el portador ataque' quedaba pegada al bloque de
	'Cuando entra en juego', y extract_action() encontraba 'Roba una carta'
	y la ejecutaba AL EQUIPARSE en vez de al atacar). Ahora también corta el
	bloque en curso apenas aparece una oración de un trigger de OTRO TIPO
	(cualquier frase de Card.TRIGGER_KEYWORDS que no sea de este mismo
	trigger_phrases)."""
	var blocks: Array[String] = []
	if ability_text.is_empty():
		return blocks

	var current: Array[String] = []
	var once_markers := ["una vez por turno", "una vez al turno", "una vez en tu turno", "una vez en su turno"]

	# Frases de cualquier OTRO tipo de trigger (no las de trigger_phrases,
	# las que estamos aislando) — ver corrección de 2026-08-30 arriba.
	var other_trigger_phrases: Array = []
	for kw_type in Card.TRIGGER_KEYWORDS:
		for phrase in Card.TRIGGER_KEYWORDS[kw_type]:
			if phrase not in trigger_phrases:
				other_trigger_phrases.append(phrase)

	for raw_sentence in ability_text.split("."):
		var sentence: String = raw_sentence.strip_edges()
		if sentence.is_empty():
			continue
		var lower_s := sentence.to_lower()

		var starts_new_block := false
		for phrase in trigger_phrases:
			if phrase in lower_s:
				starts_new_block = true
				break

		if starts_new_block:
			if not current.is_empty():
				blocks.append(". ".join(current))
			current = [sentence]
			continue

		var is_once_marker := false
		for marker in once_markers:
			if marker in lower_s:
				is_once_marker = true
				break
		if is_once_marker:
			if not current.is_empty():
				blocks.append(". ".join(current))
				current = []
			continue

		var starts_other_trigger := false
		for phrase in other_trigger_phrases:
			if phrase in lower_s:
				starts_other_trigger = true
				break
		if starts_other_trigger:
			if not current.is_empty():
				blocks.append(". ".join(current))
				current = []
			continue

		if not current.is_empty():
			current.append(sentence)

	if not current.is_empty():
		blocks.append(". ".join(current))
	return blocks


func resolve_all_triggers() -> void:
	"""Resuelve todos los triggers en la cola secuencialmente"""
	while not _main.trigger_queue.is_empty():
		var trigger = await resolve_next_trigger()
		if trigger.is_empty():
			break
		# Esperar un frame entre triggers para permitir animaciones
		await _main.get_tree().process_frame

	_main.is_resolving = false
	_main.emit_signal("all_triggers_resolved")


func has_pending_triggers() -> bool:
	"""Verifica si hay triggers pendientes"""
	return not _main.trigger_queue.is_empty()


func clear_triggers() -> void:
	"""Limpia todos los triggers pendientes"""
	_main.trigger_queue.clear()
	_main.pending_active_triggers.clear()
	_main.pending_opponent_triggers.clear()
	_main.is_collecting = false
	_main.is_resolving = false
