extends RefCounted
## ConvertAndMiscResolver — Patrones compuestos de Convertir/transformar
## cartas (Sherlock Holmes, Jormundgander), destierro por cantidad dinámica
## de Aliados (Espada del Juicio), descarte+robo del oponente (Miguel) y
## silencio por nombre (Alicia en Wonderland). Cada uno detecta su propio
## texto por regex y resuelve lo que extract_action() no puede manejar solo
## (esa función reconoce UNA acción por texto, la primera que matchea).
## Opera sobre TriggerSystem via _executor._main (mismo Node que
## TargetedEffectExecutor._main — ver ese archivo).
## Extraído de TargetedEffectExecutor.gd (2026-08-30, "módulos gordos" —
## mismo corte que ya separó LookAndPlayResolver.gd).

var _executor: TargetedEffectExecutor


func setup(executor: TargetedEffectExecutor) -> void:
	_executor = executor


# =============================================================================
# PATRÓN "CUANDO ENTRA EN JUEGO O ATAQUE, CONVIERTE HASTA N CARTAS QUE NO
# SEAN ORO DEL TOPE DE UN CASTILLO EN ALIADOS DE FUERZA F SIN HABILIDAD Y
# GANA SU CONTROL. ROBA M CARTAS Y LOS ALIADOS QUE CONTROLAS NO PUEDEN
# SALIR DEL JUEGO HASTA TU PRÓXIMO TURNO" (Sherlock Holmes)
# =============================================================================
func try_execute_mill_convert_to_ally_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""Detecta el patrón único de Sherlock Holmes (2026-08-29, verificado
	contra la API — 2 reimpresiones idénticas). Las cartas 'convertidas' NO
	se juegan ni se pagan, aparecen directo en juego bajo el control del
	jugador del efecto.

	2026-09-06, a pedido del usuario — relectura de 'convierte hasta dos
	cartas que no sean Oro O del tope de un Castillo': el 'o' separa DOS
	fuentes alternativas (elección del jugador), no es un filtro de tipo
	sobre una sola fuente como se había asumido el 2026-08-29:
	- 'cartas en juego que no sean Oro': el jugador elige a mano hasta N
	  cartas YA EN JUEGO (de cualquier lado, sin posesivo — ver
	  [[project_no_zone_means_in_play]]) para convertir in-place.
	- 'del tope de un Castillo': comportamiento original — se sacan a
	  ciegas del tope del mazo elegido, sin filtrar por tipo.
	SIN preguntar antes cuál (a pedido del usuario, 2026-09-06): ambas
	fuentes quedan clickeables A LA VEZ — una carta en juego (no Oro) o
	cualquiera de los dos Paneles de Castillo — y el PRIMER click real
	decide la fuente para el resto de la resolución; la otra deja de ser
	clickeable en cuanto se resuelve la carrera (SelectionManager.
	start_castillo_pick()/cancel_castillo_pick() en carrera contra
	CardInteractionModule.start_target_selection()/cancel_target_selection(),
	mismo split ya usado por await_target()/await_castillo_pick()).

	Ambas ramas terminan en el mismo Convertir real de DAR Sección 8
	(is_converted + KeywordManager.silence_card — mismo mecanismo que
	Capitán O'Brien/Signo Amarillo, giro visual 180°) y la misma Fuerza fija
	como modificador CONTINUO (ContinuousEffectManager, capa
	LAYER_7A_CHAR_SETTING, operación 'set', sin source real — permanente de
	verdad, no atado a que Sherlock siga en juego) para que el badge de
	Fuerza muestre el valor EFECTIVO aunque la carta impresa diga otra cosa.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("del tope de un castillo" in lower and "gana su control" in lower):
		return false
	if controller_id != 0 or not is_instance_valid(card):
		return true
	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var amount_rx := RegEx.new()
	amount_rx.compile("(?i)convierte hasta (\\w+) cartas?")
	var m_amount := amount_rx.search(ability_text)
	var max_amount: int = UniversalCardParser._parse_amount(m_amount.get_string(1)) if m_amount else 1

	var strength_rx := RegEx.new()
	strength_rx.compile("(?i)fuerza (\\d+) sin habilidad")
	var m_str := strength_rx.search(ability_text)
	var token_strength: int = int(m_str.get_string(1)) if m_str else 1

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	var grants_immunity := "no pueden salir del juego" in lower
	var converted := 0

	var _apply_conversion := func(target_node: Node) -> void:
		target_node.is_converted = true
		await KeywordManager.silence_card(target_node, card, "permanent")
		# Fuerza EFECTIVA fijada en token_strength, sin tocar el dato base
		# impreso — el badge de Fuerza (Card._apply_strength_badge_text())
		# solo se muestra cuando el valor efectivo difiere del impreso.
		ContinuousEffectManager.register_modifier({
			"source": null,
			"target": target_node,
			"type": ContinuousEffectManager.ModifierType.STRENGTH,
			"stat": "strength",
			"value": token_strength,
			"operation": "set",
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
			"description": "Sherlock Holmes: Fuerza fijada en %d" % token_strength,
		})
		target_node.refresh_strength_badge()

	if not main._card_interaction:
		return true

	var picked: Array = []
	var filter := func(c: Node) -> bool:
		# Autorreferenciable (2026-09-06, a pedido del usuario: las cartas de
		# Imperio SÍ pueden targetear/afectarse a sí mismas salvo que digan lo
		# contrario) — Sherlock puede convertirse a sí mismo.
		return c.get("card_type") != Constants.CardType.ORO and not (c in picked)

	# Carrera: castillo activo en paralelo mientras se espera el primer
	# click de carta. El que resuelva primero cancela al otro.
	# 2026-09-23: guardado en un Dictionary, no en variables sueltas — un
	# lambda de GDScript captura las locales por VALOR, así que
	# "race_done = true" adentro del callback nunca se veía desde este
	# bucle (ver misma causa raíz en arquitectura.md §13.17 y en
	# CardInteractionModule.await_target_or_castillo_pick()). Un Dictionary
	# sí se captura por referencia.
	var _state := {"race_done": false, "castillo_picked_own": true}
	SelectionManager.start_castillo_pick(main, card.card_name if card.get("card_name") else "Sherlock Holmes",
		func(picked_own: bool) -> void:
			if _state["race_done"]:
				return
			_state["race_done"] = true
			_state["castillo_picked_own"] = picked_own
			main._card_interaction.cancel_target_selection())

	var first_target: Node = null
	while not _state["race_done"]:
		var card_state := {"done": false, "chosen": null}
		main._card_interaction.start_target_selection(
			"Elige una carta en juego (no Oro) o un Castillo para Convertir", filter,
			func(c: Node) -> void:
				card_state.chosen = c
				card_state.done = true)
		while not card_state.done and not _state["race_done"]:
			await main.get_tree().process_frame
		if _state["race_done"]:
			break
		if card_state.chosen:
			first_target = card_state.chosen
			_state["race_done"] = true
			SelectionManager.cancel_castillo_pick()
		# Si card_state.chosen es null (ESC), se vuelve a armar el listener
		# de cartas mientras el Castillo sigue esperando en paralelo — la
		# habilidad no es 'puedes', tiene que resolverse por una fuente u otra.

	if first_target:
		picked.append(first_target)
		while picked.size() < max_amount:
			var target: Node = await main._card_interaction.await_target(
				"Elige otra carta en juego (no Oro) para Convertir — ESC para terminar", filter)
			if not target or not is_instance_valid(target):
				break
			picked.append(target)

		# Ya se declaró todo (los hasta max_amount objetivos elegidos) — aquí
		# corresponde la ventana, antes de convertir ninguno.
		if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
			return true
		var target_field: HBoxContainer = main.player_field if controller_id == 0 else main.opponent_field
		for target_node in picked:
			if not is_instance_valid(target_node):
				continue
			var old_parent = target_node.get_parent()
			if old_parent and old_parent != target_field:
				old_parent.remove_child(target_node)
				target_field.add_child(target_node)
			target_node.card_type = Constants.CardType.ALIADO
			target_node.controller_id = controller_id
			target_node.can_interact = (controller_id == 0)
			target_node.set_zone(Constants.Zone.LINEA_DEFENSA)
			await _apply_conversion.call(target_node)
			converted += 1
	else:
		# Castillo ya elegido por el propio click que ganó la carrera
		# (_state["castillo_picked_own"]) — sin preguntar aparte.
		var zone_owner: int = controller_id if _state["castillo_picked_own"] else (1 - controller_id)
		var deck: Array = CardManager.get_deck(zone_owner)
		# Sin objetivos puntuales que declarar aquí (salen del tope, en el
		# orden del mazo, no elegidos) — la ventana va antes de empezar a
		# revelar/convertir, gate de toda la secuencia.
		if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
			return true
		while converted < max_amount and not deck.is_empty():
			var top_data: Dictionary = deck.pop_front()
			var new_data: Dictionary = top_data.duplicate()
			new_data["tipo"] = Constants.CardType.ALIADO  # Puede venir de cualquier tipo no-Oro original; aquí SIEMPRE se fuerza a Aliado
			new_data["esta_oculta"] = false
			var token_node = main._create_card(new_data, false)
			token_node.owner_id = controller_id
			main._connect_card_signals(token_node)
			var target_field: HBoxContainer = main.player_field if controller_id == 0 else main.opponent_field
			target_field.add_child(token_node)
			token_node.can_interact = (controller_id == 0)
			token_node.set_zone(Constants.Zone.LINEA_DEFENSA)
			await _apply_conversion.call(token_node)

			if CardFactory and CardFactory.has_method("on_card_enters_play"):
				CardFactory.on_card_enters_play(token_node)  # enfermedad de invocación, igual que cualquier Aliado
			if token_node.has_method("play_enter_animation"):
				token_node.play_enter_animation()
			converted += 1

	if converted > 0 and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	if grants_immunity:
		EffectController.add_blanket_leave_play_immunity(controller_id)

	return true


# =============================================================================
# PATRÓN "CUANDO HAGA DAÑO, PUEDES CONVERTIRLO EN UN ORO Y MOVERLO A TU ORO
# PAGADO" (Jormundgander)
# =============================================================================
func try_execute_convert_ally_to_gold_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""Detecta 'puedes convertirlo en un Oro y moverlo a tu Oro Pagado'
	(Jormundgander, 2026-08-29, verificado contra la API — única
	reimpresión, sin discrepancias) — un Aliado en juego se transforma en
	Oro y se reubica directo en Oro Pagado. La otra mitad de esta misma
	carta ('si esta carta es un Oro, cuando lo pagues para jugar un
	Aliado, conviértela en un Aliado y muévela a tu Línea de Defensa') se
	resuelve del lado de GoldManager._mover_oro_a_pagado(), que revisa
	card.revert_to_data al pagar cualquier Oro — no hace falta detectarla
	aquí aparte.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("convertirlo en un oro" in lower and "oro pagado" in lower):
		return false
	if controller_id != 0 or not is_instance_valid(card):
		return true
	# 2026-09-30, bug real reportado por el usuario: _executor._main acá es
	# TriggerSystem (ver TargetedEffectExecutor.gd:441-445, mismo patrón de
	# bug ya documentado en arquitectura.md §2), no el Main real del juego
	# — _gold_manager/_card_interaction no existen ahí y tiraban "Invalid
	# access to property or key". Mismo fix de indirección que ya usa
	# try_execute_jabberwocky_convert_opponent_top_pattern() más abajo.
	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	# 2026-09-13, a pedido del usuario: en vez de un modal de confirmación
	# con un solo candidato, clickear la carta misma (ya está en juego,
	# visible) confirma; ESC declina — mismo mecanismo que cualquier otro
	# await_target(), sin necesidad de un panel aparte para un "sí/no" de
	# una sola carta conocida de antemano.
	if not main._card_interaction:
		return true
	var self_filter := func(c: Node) -> bool: return c == card
	var accepted: Node = await main._card_interaction.await_target(
		"%s: clickéala para convertirla en un Oro y moverla a tu Oro Pagado (ESC para declinar)" % card.card_name, self_filter)
	if not accepted or not is_instance_valid(accepted):
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true

	await main._gold_manager.convert_ally_to_gold_in_pagado(card)
	return true


# =============================================================================
# PATRÓN "CUANDO ENTRA EN JUEGO O ATACA, CONVIERTE LA PRIMERA CARTA DEL
# CASTILLO OPONENTE EN UN ORO SIN HABILIDAD..." (Jabberwocky)
# =============================================================================
func try_execute_jabberwocky_convert_opponent_top_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego o ataca, convierte la primera carta del
	Castillo oponente en un Oro sin habilidad y ponlo en tu Oro Pagado'
	(Jabberwocky, 2026-09-30) — mismo mecanismo de conversión real a Oro
	que try_execute_no_allies_convert_castillo_top_pattern() (Biblioteca de
	Caballería, más abajo) y convert_ally_to_gold_in_pagado() (Jormundgander,
	arriba), pero sobre el tope del Castillo RIVAL y con destino Oro Pagado
	en vez de Línea de Defensa. La carta nunca llega a existir como Node
	con su habilidad real — 'tipo'/'habilidad' se pisan en los datos crudos
	ANTES de crear el Node (mismo criterio que new_data['tipo'] = ORO de
	la función hermana), así que 'sin habilidad' queda resuelto de forma
	más simple que silence_card() (pensada para una carta que YA existe en
	juego). Se registró también 'cuando entra en juego o ataca' (con
	'ataca', no 'ataque') en Card.TRIGGER_KEYWORDS — el texto real de esta
	carta usa esa conjugación, distinta de la plantilla DAR estándar que
	ya cubrían esas listas."""
	var lower := ability_text.to_lower()
	if not ("convierte la primera carta del castillo oponente en un oro sin habilidad" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var opponent_id: int = 1 - controller_id
	var deck: Array = CardManager.get_deck(opponent_id)
	if deck.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")), controller_id):
		return true

	var top_data: Dictionary = deck.pop_front()
	var new_data: Dictionary = top_data.duplicate()
	new_data["tipo"] = Constants.CardType.ORO
	new_data["habilidad"] = ""
	await main._gold_manager.put_gold_directly_in_pagado(controller_id, new_data)
	if main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()
	return true


func try_execute_no_allies_convert_castillo_top_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'En la Fase Final oponente, si no controlas Aliados o si en tu turno
	anterior un Aliado fue Anulado o su habilidad fue cancelada, Roba una
	carta y pon bajo tu control la primera carta de un Castillo como un
	Aliado de Fuerza 2 sin habilidad' (Biblioteca de Caballería, 2026-09-04).

	LIMITACIÓN CONOCIDA: solo se implementa la mitad 'si no controlas
	Aliados' de la condición. La otra mitad ('en tu turno anterior un Aliado
	fue Anulado o su habilidad fue cancelada') exigiría un historial de
	eventos por turno que el motor no tiene todavía — no hay ningún registro
	de 'a este jugador le anularon/cancelaron un Aliado el turno pasado' en
	ninguna parte del código. Mientras no exista, esa rama del 'o' nunca se
	evalúa como verdadera; el efecto solo dispara con el campo propio vacío
	de Aliados.

	Reusa el mecanismo de conversión real de try_execute_mill_convert_to_
	ally_pattern (Sherlock Holmes): is_converted + KeywordManager.
	silence_card + Fuerza fijada por modificador CONTINUO (LAYER_7A_CHAR_
	SETTING, 'set'), no un token de datos en blanco."""
	var lower := ability_text.to_lower()
	if not ("si no controlas aliados" in lower and "pon bajo tu control la primera carta de un castillo" in lower):
		return false
	if controller_id != 0 or not is_instance_valid(card):
		return true

	if _executor._count_allies_in_play(controller_id) > 0:
		return true  # condición no cumplida (falta la otra mitad del 'o', ver docstring)

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true
	# Ventana única para todo el efecto (robar + convertir) — sin objetivo
	# puntual que declarar antes (la carta convertida sale del tope, en el
	# orden del mazo).
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")), controller_id):
		return true

	await ActionModule.draw(controller_id, 1, "final_phase_trigger", true)

	var zone_owner: int = await _executor._choose_search_zone_owner(controller_id, Constants.Zone.CASTILLO, "convertir")
	var deck: Array = CardManager.get_deck(zone_owner)
	if deck.is_empty():
		return true
	# Sin ventana genérica aquí (2026-09-09): silence_card() (más abajo) ya
	# consulta Prevención adentro por su cuenta.
	var top_data: Dictionary = deck.pop_front()
	var new_data: Dictionary = top_data.duplicate()
	new_data["tipo"] = Constants.CardType.ALIADO
	new_data["esta_oculta"] = false
	var token_node = main._create_card(new_data, false)
	token_node.owner_id = controller_id
	main._connect_card_signals(token_node)
	var target_field: HBoxContainer = main.player_field if controller_id == 0 else main.opponent_field
	target_field.add_child(token_node)
	token_node.can_interact = (controller_id == 0)
	token_node.set_zone(Constants.Zone.LINEA_DEFENSA)

	token_node.is_converted = true
	await KeywordManager.silence_card(token_node, card, "permanent")

	ContinuousEffectManager.register_modifier({
		"source": null,
		"target": token_node,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": 2,
		"operation": "set",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
		"description": "Biblioteca de Caballería: Fuerza fijada en 2",
	})
	token_node.refresh_strength_badge()

	if CardFactory and CardFactory.has_method("on_card_enters_play"):
		CardFactory.on_card_enters_play(token_node)
	if token_node.has_method("play_enter_animation"):
		token_node.play_enter_animation()
	if main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()
	return true


func try_execute_banish_top_by_ally_count_and_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'Destierra N cartas del tope de un Castillo y Roba una
	carta' (Espada del Juicio — dispara tanto en 'Cuando entra en juego'
	como 'en tu Agrupación'). Cantidad FIJA, parseada del texto (2026-09-06,
	a pedido del usuario: la carta real dice 'tantas cartas... como
	Aliados controles' — cantidad dinámica —, pero se simplificó a un
	número fijo para esta partida; ver [[feedback_api_is_source_of_truth]]
	para el texto real si se revierte este cambio). 'un Castillo' sin
	posesivo = a elección (mismo criterio ya confirmado para 'un
	Cementerio' de Miguel). El 'Roba una carta' es independiente y
	siempre ocurre.
	Returns: true si el patrón aplicaba."""
	var amount_rx := RegEx.new()
	amount_rx.compile("(?i)destierra (\\w+) cartas? del tope de un castillo")
	var m_amount := amount_rx.search(ability_text)
	if not m_amount:
		return false
	var banish_amount: int = UniversalCardParser._parse_amount(m_amount.get_string(1))

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	var deck_owner: int = controller_id
	if banish_amount > 0 and controller_id == 0:
		var look_own: bool = await SelectionManager.await_castillo_pick(main, "Espada del Juicio — destierra del tope")
		deck_owner = controller_id if look_own else (1 - controller_id)

	if await TriggerSystem.open_response_window(card, "Espada del Juicio", controller_id):
		return true

	if banish_amount > 0:
		var deck: Array = CardManager.get_deck(deck_owner)
		var amount: int = mini(banish_amount, deck.size())
		for i in range(amount):
			var card_data: Dictionary = deck.pop_front()
			CardManager.add_to_exile(deck_owner, card_data)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	return true


func try_execute_opponent_discard_and_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""Detecta 'tu oponente Descarta N cartas y tú Robas [hasta] M cartas'
	(2026-08-29, p.ej. Miguel) — dos acciones en una sola oración que
	extract_action() no puede encadenar (solo reconoce UNA acción por
	texto, la primera que matchea). Reusa _execute_targeted_discard() tal
	cual (ya resuelve 'oponente' y le da a elegir al jugador humano si es
	su propia mano la que descarta) seguido de un robo directo.
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	var lower := ability_text.to_lower()
	if not ("tu oponente descarta" in lower and "robas" in lower):
		return false

	var discard_rx := RegEx.new()
	discard_rx.compile("(?i)tu oponente descarta\\s+(\\d+|una|dos|tres|cuatro|cinco)\\s+cartas?")
	var m_discard := discard_rx.search(ability_text)
	if not m_discard:
		return false
	var discard_amount: int = UniversalCardParser._parse_amount(m_discard.get_string(1))

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)robas?\\s+(?:hasta\\s+)?(\\d+|una|dos|tres|cuatro|cinco)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	await _executor._execute_targeted_discard(card, controller_id, discard_amount)
	# El descarte ya abrió su propia ventana adentro (_execute_targeted_
	# discard) — el Robo es un efecto aparte, sin cobertura propia todavía.
	if draw_amount > 0:
		if await TriggerSystem.open_response_window(card, str(card.get("card_name")), controller_id):
			return true
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)
	return true


func try_execute_name_a_card_pattern(ability_text: String, card: Node, _controller_id: int) -> bool:
	"""Detecta 'nombra una carta para que pierda(n) su habilidad en todas
	las Zonas mientras esta carta esté en juego' (2026-08-29, Alicia en
	Wonderland). Distinto de un silencio puntual (KeywordManager.
	silence_card(), que apunta a UNA carta ya en juego): aquí se nombra un
	NOMBRE, y afecta cualquier copia de ese nombre en cualquier zona, esté
	ya en juego o aparezca después (mazo, mano) — KeywordManager.
	lock_ability_by_name()/is_name_locked(), consultado desde is_silenced().
	Solo cubre esta variante concreta (silenciar por nombre); el 'nombra una
	carta' de Tesoro de los Césares es un efecto DISTINTO (sube el coste,
	no silencia) y es una habilidad ACTIVADA, no pasa por aquí.
	Returns: true si el patrón aplicaba (se haya podido resolver o no)."""
	var lower := ability_text.to_lower()
	if not ("nombra una carta" in lower and ("pierda" in lower or "pierdan" in lower) and "habilidad" in lower):
		return false

	var picked: Dictionary = await _executor._main._card_name_search.open_and_wait(
		"Nombra una carta: pierde su habilidad en todas las Zonas mientras %s esté en juego" % str(card.get("card_name"))
	)
	if picked.is_empty():
		return true  # el jugador canceló la búsqueda — el 'nombra' no se declinaba, pero sin nombre no hay nada que hacer

	var picked_name: String = str(picked.get("nombre", ""))
	if picked_name.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name), _controller_id):
		return true

	KeywordManager.lock_ability_by_name(picked_name, card)

	var main := _executor._main.get_node_or_null("/root/Main")
	if main:
		_executor._refresh_rotation_for_name(main, picked_name)

	if main:
		main._update_debug("%s: '%s' pierde su habilidad en todas las Zonas" % [
			str(card.get("card_name")), picked_name
		])
	return true
