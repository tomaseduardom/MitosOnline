extends RefCounted
## PreventionAbilityHandler_AE — Mitad A-E (alfabético por nombre de carta) de
## PreventionAbilityHandler.gd, dividido por tamaño (2026-09-06, "módulos
## gordos" — mismo corte que ya separó SearchAbilityHandler_AI.gd/
## SearchAbilityHandler_JV.gd del propio SearchAbilityHandler.gd). Ver
## PreventionAbilityHandler.gd para el facade que reune esta parte con
## PreventionAbilityHandler_EP.gd y PreventionAbilityHandler_PV.gd bajo los
## mismos nombres públicos que antes — CardInspectionLayer.gd no cambió una
## sola línea por este split. Opera sobre CardInspectionLayer via _inspector
## (y sobre el Main del juego via _inspector._main).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _activate_akari_banish_annul_non_ally(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarlo para Anular una carta de coste 1 o menos que no
	sea Aliado' (akari, 2026-09-04) — 'Anular' ~ destruir (misma
	simplificación usada en todo el proyecto), objetivo Arma/Tótem (no
	Aliado, no Oro) de coste efectivo ≤1."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if not main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ARMA, Constants.CardType.TOTEM]:
			return false
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 1
	var target: Node = await main._card_interaction.await_target("Elige un Arma o Tótem de coste 1 o menos para anular", filter, true, owner_id)
	if not target or not is_instance_valid(target):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.banish([source_card], source_card, true)

	if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser anulad"]):
		main._update_debug("%s no puede ser anulada" % str(target.get("card_name")))
	else:
		await ActionModule.destroy([target], source_card, true, true)


func _activate_akuma_banish_or_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Desterrar hasta dos cartas de los
	Cementerio o Roba una carta' (akuma el terrible, 2026-09-04) —
	elección A/B; 'los Cementerios' = ambos jugadores
	([[project_no_zone_means_in_play]])."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0

	var choose_banish: bool = await SelectionManager.await_two_choice(
		_inspector._main, "akuma el terrible", "Desterrar hasta dos cartas de los Cementerios", "Robar una carta", owner_id)

	if choose_banish:
		# 2026-09-13, a pedido del usuario: click directo sobre ambos
		# Cementerios en vez del modal de lista viejo — pool combinado, sin
		# lock (mismo caso que Espada de O'Higgins, ver arquitectura.md
		# §10.14/§10.19).
		if not _inspector._main._zone_viewer:
			return
		var no_filter := func(_c: Node) -> bool: return true
		var picked: Array = await _inspector._main._zone_viewer.open_cemetery_target_picker(
			"Destierra hasta dos carta(s) de los Cementerios", no_filter, 2, "cemetery", false, false, owner_id)
		if picked.is_empty():
			return
		if await TriggerSystem.open_response_window(source_card, "akuma el terrible", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		for entry in picked:
			var owner_of_picked: int = entry.owner_id
			var picked_data: Dictionary = entry.data
			var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
			if idx < 0:
				continue
			CardManager.remove_from_cemetery(owner_of_picked, idx)
			CardManager.add_to_exile(owner_of_picked, picked_data)
	else:
		if await TriggerSystem.open_response_window(source_card, "akuma el terrible", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await ActionModule.draw(owner_id, 1, "activated_ability", true)


## _activate_almirante_akari_shuffle_annul_or_prevent() eliminada
## (2026-09-09, "sistema de respuestas" — corregido a pedido del usuario:
## Akari no es una elección A/B proactiva, son dos disparadores reactivos
## distintos). "Prevenir" ahora vive en EffectController._prevention_registry
## (mismo mecanismo que Estaca, solo Aliados); "Anular cuando el rival juega
## una carta" vive en EffectController.offer_counter_annul(), llamado desde
## GoldManager._trigger_enter_play()/EasyBotController._play_ally() justo
## después de que la carta jugada entra en juego. Ambas comparten el costo
## (barajar 1 carta propia) vía EffectController._pay_akari_shuffle_cost().


## _activate_angel_redentor_prevent() eliminada (2026-09-09, "sistema de
## respuestas"): ya no es un botón — EffectController.offer_prevention()
## la detecta y ofrece reactivamente (tags "annul"/"cancel"), con su propio
## candado de una vez por turno vía turn_registry en el 'is_available' del
## registro (ver EffectController.gd).


func _activate_atenea_grant_double_damage_exile(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, un Aliado hace doble daño de combate al
	Destierro este turno' (atenea en wonderland, 2026-09-04) — otorga
	Card.doubles_damage_to_exile TEMPORALMENTE (solo este turno) a un
	Aliado elegido (propio o rival, el texto no lo restringe), vía
	GameManager.turn_started para limpiarlo (mismo patrón que el Exhumar
	temporal de sumi el terrible)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if not main._card_interaction:
		return

	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.ALIADO:
			return false
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		return c.get("current_zone") in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]
	var target: Node = await main._card_interaction.await_target("Elige un Aliado que haga doble daño de combate al Destierro este turno", filter, true, owner_id)
	if not target or not is_instance_valid(target):
		return
	if await TriggerSystem.open_response_window(source_card, "atenea en wonderland", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	target.doubles_damage_to_exile = true
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != owner_id:
			return
		if is_instance_valid(target):
			target.doubles_damage_to_exile = false
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
	GameManager.turn_started.connect(clear_it)


func _activate_belta_barajar_desterrar(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, Baraja y/o Destierra hasta dos cartas de los
	Cementerios' (Belta, 2026-09-04) — reusa GoldManager._resolve_armeria_
	barajar_desterrar() genérica, sin costo (a diferencia de Armería, aquí
	no hay condición previa)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	# _resolve_armeria_barajar_desterrar() resuelve elección intercalada
	# carta-por-carta sin un punto limpio de "declarar todo antes de
	# ejecutar" (mismo motivo por el que quedó diferida en el barrido de
	# triggers) — se gatea con UNA ventana ANTES de arrancar toda la
	# resolución en vez de reescribir el helper compartido.
	if await TriggerSystem.open_response_window(source_card, "Belta", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await _inspector._main._gold_manager._resolve_armeria_barajar_desterrar(2, "Belta", owner_id)


func _activate_belta_self_banish_revive(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrar dos cartas de tu Cementerio para ponerlo en juego
	desde tu Cementerio como un Aliado sin habilidad de Fuerza 2' (Belta,
	2026-09-04) — costo: desterrar 2 cartas CUALQUIERA de tu Cementerio
	(no incluye a Belta misma, que está siendo jugada desde ahí). Efecto:
	Belta deja de ser el Oro y pasa a ser un Aliado Fuerza 2 sin
	habilidad, en juego."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0:
		# 2026-10-05: el efecto final resuelve con GoldManager.
		# _play_card_to_field(), que registra 'played_ally_cost2plus:0' con
		# el 0 fijo y saca la carta SIEMPRE de _main.player_hand.cards —
		# mismo tipo de límite de un solo jugador que puede_pagar()/
		# pagar_coste() (ver §22), esta vez en la ruta de "jugar la carta",
		# no en el pago. Se deja sin desbloquear.
		return  # el Remoto no puede usar esta habilidad todavía
	if source_card.get("current_zone") != Constants.Zone.CEMENTERIO:
		main._update_debug("Belta ya no está en tu Cementerio")
		return

	var cemetery: Array = CardManager.get_cemetery(owner_id)
	var others: Array = cemetery.filter(func(d): return d != source_card.card_data)
	if others.size() < 2:
		main._update_debug("Necesitas otras 2 cartas en tu Cementerio para desterrar")
		return
	if not main._zone_viewer:
		return
	# 2026-09-13, a pedido del usuario: click directo en vez del modal de
	# lista viejo — 'tu Cementerio' (solo propio) + excluir a la propia
	# Belta, lock_to_one_side=true de paso restringe al lado propio (mismo
	# efecto que filtrar por owner, reutiliza el parámetro ya existente en
	# vez de duplicar la exclusión en el filtro). Costo TODO o NADA: si
	# cancela antes de elegir las 2, no se mueve nada (el picker no muta
	# estado — solo aquí se toca el Cementerio).
	var filter := func(c: Node) -> bool:
		return c.owner_id == owner_id and c.card_data != source_card.card_data
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Destierra 2 cartas de tu Cementerio para poner a Belta en juego", filter, 2, "cemetery", true)
	if picked.size() < 2:
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	for entry in picked:
		var idx: int = CardManager.get_cemetery(owner_id).find(entry.data)
		if idx >= 0:
			CardManager.remove_from_cemetery(owner_id, idx)
			CardManager.add_to_exile(owner_id, entry.data)

	var self_idx: int = CardManager.get_cemetery(owner_id).find(source_card.card_data)
	if self_idx >= 0:
		CardManager.remove_from_cemetery(owner_id, self_idx)

	var ally_data: Dictionary = source_card.card_data.duplicate()
	ally_data["tipo"] = Constants.CardType.ALIADO
	ally_data["fuerza"] = 2
	ally_data["habilidad"] = ""
	var ally_node = main._create_card(ally_data, false)
	ally_node.owner_id = owner_id
	main._connect_card_signals(ally_node)
	await main._gold_manager._play_card_to_field(ally_node)


func _activate_campanita_banish_cancel_or_draw(source_card: Node, ability: Dictionary) -> void:
	"""'Puedes Desterrarlo para cancelar una habilidad o Robar dos cartas'
	(Campanita, 2026-09-04) — elección A/B. 'Cancelar la habilidad' ~
	silenciar (misma simplificación de Frankenstein/Red de Plata/Sheut),
	sin restricción de coste ni tipo (a diferencia de Frankenstein, que sí
	las tiene en su propio texto)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main

	var choose_cancel: bool = await SelectionManager.await_two_choice(
		main, "Campanita", "Desterrarla para cancelar una habilidad", "Desterrarla para Robar dos cartas", owner_id)

	var target: Node = null
	if choose_cancel:
		if not main._card_interaction:
			return
		var filter := func(c: Node) -> bool:
			# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
			return c.get("current_zone") in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE,
				Constants.Zone.LINEA_APOYO, Constants.Zone.RESERVA_ORO]
		target = await main._card_interaction.await_target("Elige una carta para cancelar su habilidad", filter, true, owner_id)
		if not target or not is_instance_valid(target):
			return

	# Rama "roba dos": a diferencia de la de cancelar (protegida después por
	# silence_card()), el Robo no tiene cobertura propia — la ventana va AQUÍ,
	# antes del autodestierro de más abajo (2026-09-10), porque después
	# source_card queda inválida para open_response_window().
	if not choose_cancel and await TriggerSystem.open_response_window(source_card, "Campanita", owner_id):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	await ActionModule.banish([source_card], source_card, true)

	if choose_cancel and target:
		if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede perder su habilidad", "no pierde su habilidad"]):
			main._update_debug("%s no pierde su habilidad" % str(target.get("card_name")))
		else:
			await KeywordManager.silence_card(target, source_card, "permanent")
	else:
		await ActionModule.draw(owner_id, 2, "activated_ability", true)


func _activate_crono_diamante_discard_ally_discount(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, si jugaste un Aliado de coste 2 o más este
	turno puedes Descartar una carta para jugar un Aliado reduciendo su
	coste en un Oro, hasta un mínimo de 1' (Crono Diamante, 2026-09-02 —
	verificado contra la API, sin discrepancias con el cache local).
	Condición previa (GoldManager._play_card_to_field() registra
	'played_ally_cost2plus:0' cada vez que se juega un Aliado de coste ≥2,
	sin importar el origen — mano/Exhumar/gratis). Costo: descartar 1
	carta CUALQUIERA de la mano. Efecto: jugar OTRA carta de la mano (un
	Aliado) con -1 Oro, piso 1 — a diferencia de Paladín Bestiarium
	(_activate_paladin_bestiarium_discard_weapon_discount(), mismo
	esqueleto), el texto NO dice 'hasta un mínimo de 0', así que
	allow_zero queda en false. 'Puedes X para Y' es atómico (2026-08-31,
	mismo criterio ya aplicado a Padre de la Patria/Paladín Bestiarium):
	solo se ofrecen como candidatas las Aliados que YA son pagables con
	el descuento aplicado, filtrado antes de preguntar qué descartar."""
	if not is_instance_valid(source_card) or not _inspector._main._gold_manager:
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	if owner_id != 0 or not _inspector._main.player_hand or _inspector._main.player_hand.cards.is_empty():
		# 2026-10-05: el efecto final llama gold_manager.play_card(ally_node)
		# directo — esa función rechaza con "No es tu turno" cuando
		# GameManager.active_player_id != 0 (hardcodeado), además de que
		# puede_pagar() del descuento también es de un solo jugador (§22).
		# Se deja sin desbloquear.
		return  # el Remoto no puede usar esta habilidad todavía

	if not UniversalCardParser.turn_registry.was_used("played_ally_cost2plus:%d" % owner_id, 0, GameManager.current_turn):
		_inspector._main._update_debug("Necesitas haber jugado un Aliado de coste 2 o más este turno")
		return

	var hand_cards: Array = _inspector._main.player_hand.cards.duplicate()
	var gold_manager: GoldManager = _inspector._main._gold_manager

	var ally_candidates: Array = []
	for c in hand_cards:
		if not is_instance_valid(c) or c.get("card_type") != Constants.CardType.ALIADO:
			continue
		var base_cost: int = int(c.card_cost) if c.get("card_cost") != null else 0
		var discounted_cost: int = maxi(base_cost - 1, 1)
		if gold_manager.puede_pagar(discounted_cost, c.card_type, c.card_raza, base_cost):
			ally_candidates.append(c)
	if ally_candidates.is_empty():
		_inspector._main._update_debug("No tienes ningún Aliado que puedas pagar en la mano, ni con el descuento")
		return

	if not _inspector._main._card_interaction:
		return
	# 2026-09-13, a pedido del usuario: click directo en la mano en vez de
	# los dos modales de lista viejos.
	var ally_filter := func(c: Node) -> bool: return c in ally_candidates
	var ally_node: Node = await _inspector._main._card_interaction.await_target(
		"Elige el Aliado a jugar con 1 Oro de descuento", ally_filter)
	if not ally_node or not is_instance_valid(ally_node):
		return

	var discard_filter := func(c: Node) -> bool:
		return c.get("current_zone") == Constants.Zone.MANO and c != ally_node
	if not hand_cards.any(func(c): return discard_filter.call(c)):
		_inspector._main._update_debug("Necesitas otra carta en tu mano para descartar como costo")
		return

	var discard_node: Node = await _inspector._main._card_interaction.await_target(
		"Descarta 1 carta para jugar %s con 1 Oro de descuento" % str(ally_node.card_name), discard_filter)
	if not discard_node or not is_instance_valid(discard_node):
		return

	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)

	await ActionModule.discard(owner_id, [discard_node], "ability_cost", true)

	var applies_to_this_card := func(c: Node) -> bool:
		return c == ally_node
	PaymentManager.agregar_modificador_coste(ally_node, -1, applies_to_this_card, false)
	await gold_manager.play_card(ally_node)


## _activate_dracula_convert_for_prevention() eliminada (2026-09-09,
## "sistema de respuestas"): ya no es un botón — EffectController.
## offer_prevention()/offer_prevention_for_player() detecta a Drácula
## (sin convertir, en juego) y ofrece reactivamente (tags "cancel"/"annul")
## en el momento exacto; el 'on_used' del registro hace el auto-convertir +
## silenciar que antes pasaba aquí.


func _activate_dulce_canasta(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, un Aliado gana o pierde 2 de Fuerza
	permanentemente' (Dulce Canasta, 2026-09-04). Sin costo. Cualquier
	Aliado en juego, propio o rival (sin calificador de dueño en el
	texto). 'permanentemente' = mismo molde que Espada del Juicio:
	source=target, sobrevive aunque Dulce Canasta salga de juego."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var target: Node = await TriggerSystem._targeted_executor._select_ally_target(
		"Elige un Aliado que gane o pierda 2 de Fuerza permanentemente", source_card, owner_id)
	if not target or not is_instance_valid(target):
		return
	var gains: bool = await SelectionManager.await_two_choice(
		_inspector._main, "Dulce Canasta", "Gana 2 de Fuerza", "Pierde 2 de Fuerza", owner_id)
	# Solo el débuff es prevenible (2026-09-09 — Estaca, tag "strength_change")
	# — un buff no es un efecto hostil que valga la pena bloquear.
	if not gains and await EffectController.offer_prevention(target, source_card, "strength_change"):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	ContinuousEffectManager.register_modifier({
		"source": target,
		"target": target,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": 2 if gains else -2,
		"operation": "add",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "%s de Dulce Canasta" % ("Buff" if gains else "Debuff"),
	})


func _activate_ereshkigal_banish_cost1_or_cemeteries(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Desterrar una carta de coste 1 o menos o
	Barajar y/o Desterrar dos cartas de los Cementerios' (ereshkigal,
	2026-09-04) — elección A/B; B reusa GoldManager._resolve_armeria_
	barajar_desterrar() genérica (ya generalizada para Belta/Perla de
	Sangre)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0

	var choose_banish: bool = await SelectionManager.await_two_choice(
		_inspector._main, "ereshkigal", "Desterrar una carta de coste 1 o menos", "Barajar y/o Desterrar hasta dos cartas de los Cementerios", owner_id)

	if choose_banish:
		var target: Node = await TriggerSystem._targeted_executor._select_banish_target_cost_filter(
			"Elige una carta de coste 1 o menos para desterrar", 1, owner_id)
		if not target or not is_instance_valid(target):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await ActionModule.banish([target], source_card, true)
	else:
		if await TriggerSystem.open_response_window(source_card, "ereshkigal", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await _inspector._main._gold_manager._resolve_armeria_barajar_desterrar(2, "ereshkigal", owner_id)


func _activate_espada_ohiggins_shuffle_or_search_gold(source_card: Node, ability: Dictionary) -> void:
	"""'En tu Vigilia, una vez por turno, puedes Barajar una carta que no
	sea Oro o buscar un Oro en tu Castillo y ponerlo en tu mano' (Espada
	de O'Higgins, 2026-09-04) — elección A/B.
	2026-09-14, a pedido del usuario: en vez de preguntar antes "¿qué
	quieres hacer?" con un diálogo A/B, ahora es una carrera de click
	directo (`CardInteractionModule.await_target_or_castillo_pick()`,
	mismo mecanismo ya usado por Sherlock Holmes/La Ouija — ver
	arquitectura.md §10.14): el Castillo PROPIO brilla como objetivo
	clickeable (buscar un Oro) AL MISMO TIEMPO que las cartas en juego que
	no sean Oro brillan como objetivo (barajar) — el primer click real
	decide cuál de las dos ramas resuelve; la otra deja de ofrecerse.
	`castillo_own_only=true` porque el texto dice 'tu Castillo' con
	posesivo (a diferencia de Sherlock Holmes, 'un Castillo' sin
	posesivo)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if owner_id != 0 or not main._card_interaction:
		# 2026-10-05: usa CardInteractionModule.await_target_or_castillo_
		# pick() — un SÉPTIMO tipo de diálogo sin puente de red (carrera
		# entre clickear una carta o el Castillo propio), sin chooser_id en
		# su firma. Se deja documentado como gap nuevo (ver §22).
		return  # el Remoto no puede usar esta habilidad todavía

	# 2026-09-12 (bug real reportado por el usuario: no dejaba elegir un
	# Aliado del rival — 5 clicks seguidos rechazados como "objetivo no
	# válido"). El filtro comparaba c.get_parent() contra los contenedores
	# de zona directo, en vez de current_zone (la propiedad que el motor
	# ya usa para esto en todo el resto del código, p.ej.
	# _select_convert_target()) — un Arma equipada, por ejemplo, es hija
	# de su portador, no de la línea, así que ese chequeo de parent NUNCA
	# la hubiera aceptado ni a ella ni a cualquier carta cuya jerarquía de
	# nodos no calzara 1:1 con la zona lógica.
	var valid_zone_ids = [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]
	var filter := func(c: Node) -> bool:
		if c.get("card_type") == Constants.CardType.ORO:
			return false
		return c.get("current_zone") in valid_zone_ids
	var result: Dictionary = await main._card_interaction.await_target_or_castillo_pick(
		"Elige una carta que no sea Oro para barajar, o clickea tu Castillo para buscar un Oro",
		filter, "Espada de O'Higgins", true, true)

	if result.type == "card":
		var target: Node = result.card
		if not is_instance_valid(target):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		var target_owner: int = target.controller_id if target.get("controller_id") != null else owner_id
		if await ActionModule.return_to_deck(target, target_owner, true, source_card):
			CardManager.shuffle_deck(target_owner)
	elif result.type == "castillo":
		if await TriggerSystem.open_response_window(source_card, "Espada de O'Higgins", owner_id):
			return
		UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
		await ActionModule.search(owner_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.ORO}, 1, true, false, false, source_card, Constants.Zone.MANO)
	# result.type == "none": ESC sin elegir nada (habilidad opcional, allow_cancel=true) — no hacer nada.


func _activate_espiritu_maquina_shuffle_or_banish_cemetery(source_card: Node, ability: Dictionary) -> void:
	"""'Una vez por turno, puedes Barajar o Desterrar una carta de un
	Cementerio' (Espíritu de la Máquina, 2026-09-04) — 'un Cementerio' =
	elige CUÁL (propio o rival), no ambos ([[project_y_o_means_choose_one_zone]]
	mismo criterio aplicado a 'un' singular). Macu comparte el mismo texto
	('Una vez en tu turno, ...') y este mismo handler (2026-09-07, bug real
	encontrado en auditoría: el diálogo de Barajar/Desterrar tenía el título
	'Espíritu de la Máquina' hardcodeado, mostrándose igual cuando activaba
	Macu — ahora usa el nombre real de la carta)."""
	if not is_instance_valid(source_card):
		return
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0
	var main := _inspector._main
	if not main._zone_viewer:
		return
	# 2026-09-13, a pedido del usuario: click directo con ambos Cementerios
	# visibles en vez de preguntar antes "¿en cuál?" — "un Cementerio"
	# (elige uno) se resuelve con lock_to_one_side=true, mismo criterio que
	# Hanta el Samurai (aunque aquí el tope es 1 carta, el lock no cambia
	# nada práctico salvo dejar el resto sin brillo tras el primer click).
	var no_filter := func(_c: Node) -> bool: return true
	var picked_list: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Elige una carta de un Cementerio", no_filter, 1, "cemetery", true, false, owner_id)
	if picked_list.is_empty():
		return
	var target_owner: int = picked_list[0].owner_id
	var picked_data: Dictionary = picked_list[0].data
	var barajar: bool = await SelectionManager.await_two_choice(
		main, source_card.card_name if source_card.get("card_name") else "Esa carta", "Barajarla", "Desterrarla", owner_id)
	var idx: int = CardManager.get_cemetery(target_owner).find(picked_data)
	if idx < 0:
		return
	if await TriggerSystem.open_response_window(source_card, str(source_card.card_name) if source_card.get("card_name") else "Espíritu de la Máquina", owner_id):
		return
	UniversalCardParser.turn_registry.register_ability_use(source_card, ability)
	CardManager.remove_from_cemetery(target_owner, idx)
	if barajar:
		CardManager.get_deck(target_owner).append(picked_data)
		CardManager.shuffle_deck(target_owner)
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(target_owner),
			"description": "Barajar mazo (Espíritu de la Máquina)"
		})
	else:
		CardManager.add_to_exile(target_owner, picked_data)
