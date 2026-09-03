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
	contra la API — 2 reimpresiones idénticas, y corregido a pedido del
	usuario contra la lectura literal inicial): las cartas 'convertidas' NO
	se juegan ni se pagan, aparecen directo en juego bajo el control del
	jugador del efecto sin importar de qué Castillo salieron.

	2026-08-29, correcciones del usuario sobre la primera versión:
	- El Castillo es zona OCULTA/aleatoria — se toman las 2 cartas del tope
	  SIEMPRE, sin filtrar por tipo (aunque sean Oro). 'que no sean Oro' no
	  se aplica como filtro de selección acá.
	- Es el Convertir real de DAR Sección 8 (is_converted + KeywordManager.
	  silence_card — mismo mecanismo que Capitán O'Brien/Signo Amarillo,
	  giro visual de 180° 'dadas vuelta'), NO un token con datos en blanco
	  armado a mano. Conservan coste. Al ser Aliados de verdad pueden portar
	  Armas, ser desterrados, etc. — nada especial que hacer ahí, ya lo
	  cubre el resto del motor con solo estar en player_field.
	- La Fuerza 3 se aplica como un modificador CONTINUO (Continuous
	  EffectManager, capa LAYER_7A_CHAR_SETTING, operación 'set', sin
	  source real — permanente de verdad, no atado a que Sherlock siga en
	  juego) para que el badge de Fuerza muestre el valor EFECTIVO (3)
	  aunque la carta impresa diga otra cosa (p.ej. una carta de Fuerza 2
	  impresa termina mostrando 3 en el badge, no reescribe el dato base).
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

	# Dueño del Castillo — ambiguo ('un Castillo', sin posesivo), el
	# jugador elige (mismo patrón que _execute_targeted_search()).
	var zone_owner: int = await _executor._choose_search_zone_owner(controller_id, Constants.Zone.CASTILLO)

	var deck: Array = CardManager.get_deck(zone_owner)
	var converted := 0
	while converted < max_amount and not deck.is_empty():
		var top_data: Dictionary = deck.pop_front()
		var new_data: Dictionary = top_data.duplicate()
		new_data["tipo"] = Constants.CardType.ALIADO  # Puede venir de cualquier tipo no-Oro original; acá SIEMPRE se fuerza a Aliado
		new_data["esta_oculta"] = false
		var token_node = main._create_card(new_data, false)
		token_node.owner_id = controller_id
		main._connect_card_signals(token_node)
		var target_field: HBoxContainer = main.player_field if controller_id == 0 else main.opponent_field
		target_field.add_child(token_node)
		token_node.can_interact = (controller_id == 0)
		token_node.set_zone(Constants.Zone.LINEA_DEFENSA)

		# Convertir de verdad (DAR Sección 8): pierde su habilidad, giro
		# visual 180° — mismo mecanismo que el resto del proyecto, no un
		# camino aparte.
		token_node.is_converted = true
		KeywordManager.silence_card(token_node, card, "permanent")

		# Fuerza EFECTIVA fijada en token_strength, sin tocar el dato base
		# impreso — el badge de Fuerza (Card._apply_strength_badge_text())
		# solo se muestra cuando el valor efectivo difiere del impreso, que
		# es justo el caso de una carta original de, digamos, Fuerza 2.
		ContinuousEffectManager.register_modifier({
			"source": null,
			"target": token_node,
			"type": ContinuousEffectManager.ModifierType.STRENGTH,
			"stat": "strength",
			"value": token_strength,
			"operation": "set",
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
			"description": "Sherlock Holmes: Fuerza fijada en %d" % token_strength,
		})
		token_node.refresh_strength_badge()

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
	acá aparte.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("convertirlo en un oro" in lower and "oro pagado" in lower):
		return false
	if controller_id != 0 or not is_instance_valid(card):
		return true
	if not _executor._main._gold_manager:
		return true

	# min_selections=0 (2026-08-30, bug real corregido de paso): esta
	# confirmación solo escuchaba card_selected/selection_cancelled, nunca
	# selection_completed — si el jugador confirmaba con 0 elegidas (min=0
	# lo permite), el panel se quedaba colgado para siempre en silencio.
	# await_single_pick() ya escucha las tres señales.
	var confirm_btn = SelectionManager.get("_confirm_button")
	if confirm_btn:
		confirm_btn.visible = false
	var accepted: Dictionary = await SelectionManager.await_single_pick(
		[card.card_data], "%s: puedes convertirlo en un Oro y moverlo a tu Oro Pagado" % card.card_name, true, 0)
	if confirm_btn:
		confirm_btn.visible = true
	if accepted.is_empty():
		return true

	await _executor._main._gold_manager.convert_ally_to_gold_in_pagado(card)
	return true


func try_execute_banish_top_by_ally_count_and_draw_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'Destierra tantas cartas del tope de un Castillo como
	Aliados controles y Roba una carta' (2026-08-30, p.ej. Espada del
	Juicio — dispara tanto en 'Cuando entra en juego' como 'en tu
	Agrupación'). Cantidad DINÁMICA (= Aliados que controla quien activa
	el efecto); 'un Castillo' sin posesivo = a elección (mismo criterio ya
	confirmado para 'un Cementerio' de Miguel). El 'Roba una carta' es
	independiente y siempre ocurre, incluso si la cantidad a desterrar da 0
	(cero Aliados controlados es una resolución completa, no parcial).
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("destierra tantas cartas del tope de un castillo" in lower
			and "como aliados controles" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	var ally_fields: Array = [main.player_field, main.player_linea_ataque] if controller_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque]
	var ally_count := 0
	for field in ally_fields:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO:
				ally_count += 1

	if ally_count > 0:
		var deck_owner: int = controller_id
		if controller_id == 0:
			var look_own: bool = await SelectionManager.await_castillo_pick(main, "Espada del Juicio — destierra del tope")
			deck_owner = controller_id if look_own else (1 - controller_id)
		var deck: Array = CardManager.get_deck(deck_owner)
		var amount: int = mini(ally_count, deck.size())
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
	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)
	return true


func try_execute_name_a_card_pattern(ability_text: String, card: Node, _controller_id: int) -> bool:
	"""Detecta 'nombra una carta para que pierda(n) su habilidad en todas
	las Zonas mientras esta carta esté en juego' (2026-08-29, Alicia en
	Wonderland). Distinto de un silencio puntual (KeywordManager.
	silence_card(), que apunta a UNA carta ya en juego): acá se nombra un
	NOMBRE, y afecta cualquier copia de ese nombre en cualquier zona, esté
	ya en juego o aparezca después (mazo, mano) — KeywordManager.
	lock_ability_by_name()/is_name_locked(), consultado desde is_silenced().
	Solo cubre esta variante concreta (silenciar por nombre); el 'nombra una
	carta' de Tesoro de los Césares es un efecto DISTINTO (sube el coste,
	no silencia) y es una habilidad ACTIVADA, no pasa por acá.
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

	KeywordManager.lock_ability_by_name(picked_name, card)

	var main := _executor._main.get_node_or_null("/root/Main")
	if main:
		_executor._refresh_rotation_for_name(main, picked_name)

	if main:
		main._update_debug("%s: '%s' pierde su habilidad en todas las Zonas" % [
			str(card.get("card_name")), picked_name
		])
	return true
