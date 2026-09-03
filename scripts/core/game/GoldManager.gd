extends Node
class_name GoldManager
## GoldManager — Sistema de pago de costes y gestión de Oro (DAR Secciones 6 y 8).
## Se instancia como hijo de Main en _ready(). Accede a nodos de Main via _main.

## Emitida cada vez que un jugador realiza la acción DAR de "Colocar un
## Oro" (mano → Reserva, _place_card_as_gold — NO Oro que llega por
## búsqueda/efecto, ver _register_gold_placed()) — count_this_turn es el
## total de esa acción para ESE jugador en el turno actual (2026-08-29,
## p.ej. Don de Amma: "cuando tu oponente ponga su SEGUNDO Oro en juego
## este turno").
signal gold_placed(player_id: int, count_this_turn: int)

## Conteo de Oros colocados este turno, por jugador — se resetea en cada
## turno nuevo (_on_turn_started_clear_virtual_gold), sea de quien sea el
## turno, porque el conteo es "este turno", no "en mi turno".
var oro_colocado_conteo: Dictionary = {0: 0, 1: 0}

var _main: Node = null
var oros_virtuales: int = 0
## Tokens visuales en Reserva de Oro, uno por unidad de oros_virtuales — 1:1,
## para que la Reserva nunca muestre más ni menos Oro del que hay realmente
## disponible (2026-08-28, a pedido del usuario: antes oros_virtuales no
## tenía ningún rastro visual, solo el contador interno).
var virtual_gold_tokens: Array = []

## Oro Virtual RESTRINGIDO (2026-08-28, p.ej. Padre de la Patria: "genera un
## Oro para jugar Armas o Aliados Caballero por el turno") — a diferencia de
## oros_virtuales (Lobo Sagrado, sirve para pagar cualquier cosa), cada
## unidad acá solo paga cartas que cumplan su propio 'predicate'. Varias
## fuentes pueden coexistir (cada una es una entrada separada de esta
## lista), por eso es Array de pools y no un solo contador+predicate.
## Cada entrada: {"amount": int, "tokens": Array, "predicate": Callable,
## "label": String}. predicate: func(card_type: int, card_race: String,
## card_cost: int) -> bool (card_cost agregado 2026-08-28 para Legión
## Paladín: "genera un Oro para jugar Aliados o Armas de coste 2 o más" —
## texto reconfirmado 2026-08-29 contra un fetch en vivo de la API, ver
## [[feedback_api_is_source_of_truth]]).
var restricted_gold_pools: Array = []

## "No puedes jugar más cartas este turno" (2026-08-30, p.ej. Tempilcahue) —
## bloqueo TOTAL de jugar cartas (Oro incluido, ver play_card() más abajo:
## colocar Oro también pasa por acá) para el resto del turno actual, por
## jugador. Se limpia en cada turno nuevo, no en "su próximo turno" —
## _on_turn_started_clear_virtual_gold() ya resetea otros estados "por este
## turno" (oro_colocado_conteo, virtuales), mismo criterio acá.
var _no_more_cards_this_turn: Dictionary = {0: false, 1: false}

func setup(main: Node) -> void:
	_main = main
	# 'Oro por el turno' (p.ej. Lobo Sagrado) expira al pasar de turno — sin
	# esto oros_virtuales nunca se limpiaba y el Oro generado quedaba
	# disponible para siempre (2026-08-28).
	if GameManager and GameManager.has_signal("turn_started"):
		if not GameManager.turn_started.is_connected(_on_turn_started_clear_virtual_gold):
			GameManager.turn_started.connect(_on_turn_started_clear_virtual_gold)


func _on_turn_started_clear_virtual_gold(_player_id: int, _turn: int) -> void:
	limpiar_oros_virtuales()
	limpiar_oro_restringido()
	oro_colocado_conteo = {0: 0, 1: 0}
	_no_more_cards_this_turn = {0: false, 1: false}


func set_no_more_cards_this_turn(player_id: int) -> void:
	_no_more_cards_this_turn[player_id] = true
	print("[GoldManager] J%d ya no puede jugar más cartas este turno" % (player_id + 1))


func _no_more_cards_violation(card: Node) -> bool:
	var player_id: int = card.controller_id if card.get("controller_id") != null else 0
	return _no_more_cards_this_turn.get(player_id, false)


## "Elegir una carta de ahí (mano rival) que no sea Oro para que no pueda
## ser jugada hasta tu próximo turno" (2026-08-30, p.ej. Chakram) — candado
## por CARTA puntual (instance_id), a diferencia de _no_more_cards_this_turn
## (esa bloquea TODO, por jugador). Se limpia cuando empieza el próximo
## turno de QUIEN PUSO el candado (el controlador del Arma que activó la
## habilidad, "tu próximo turno" — no el dueño de la carta candada).
var _play_locked_cards: Dictionary = {}


func lock_card_from_playing(card: Node, locking_player_id: int) -> void:
	if not is_instance_valid(card):
		return
	var id := card.get_instance_id()
	_play_locked_cards[id] = true
	var card_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Carta"
	print("[GoldManager] %s no puede jugarse hasta el próximo turno de J%d" % [card_name, locking_player_id + 1])
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != locking_player_id:
			return
		_play_locked_cards.erase(id)
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
	GameManager.turn_started.connect(clear_it)


func _card_play_locked(card: Node) -> bool:
	return _play_locked_cards.get(card.get_instance_id(), false)


func _register_gold_placed(player_id: int) -> void:
	"""Punto único de conteo para gold_placed — llamar SOLO desde la acción
	real de 'Colocar un Oro' (_place_card_as_gold, DAR: un Oro de la mano
	a la Reserva, la acción que Don de Amma cuenta), no desde Oro que
	llega por búsqueda/efecto (put_gold_directly_in_reserva/_en_pagado —
	esos son otro verbo del DAR, no 'poner en juego' el Oro del turno).
	Dispara el chequeo reactivo de 'cuando tu oponente ponga su segundo
	Oro' contra el OTRO jugador."""
	oro_colocado_conteo[player_id] = oro_colocado_conteo.get(player_id, 0) + 1
	gold_placed.emit(player_id, oro_colocado_conteo[player_id])
	_check_reactive_second_gold_triggers(player_id)


func _check_reactive_second_gold_triggers(placer_id: int) -> void:
	"""'Cuando tu oponente ponga su segundo Oro en juego este turno, puedes
	poner este Oro desde tu mano o Cementerio en tu Oro Pagado' (Don de
	Amma, 2026-08-29). Solo importa el SEGUNDO Oro exacto de placer_id este
	turno — no el primero, ni el tercero en adelante (el texto dice 'su
	segundo Oro', no 'a partir del segundo'). Solo se ofrece el diálogo
	cuando el reactor es el jugador humano (reactor_id == 0): el oponente
	no tiene decisiones propias todavía (sin IA), así que si reactor_id
	fuera 1 no habría forma de responder — se detecta igual (conteo
	correcto para ambos jugadores) pero no se le pregunta nada a un bot que
	no puede contestar.
	NOTA — límite conocido: hoy solo GoldManager._place_card_as_gold()
	(jugador 0, desde la mano) llama a _register_gold_placed(). El
	oponente nunca coloca Oro por su cuenta (no hay IA que juegue por él),
	así que en la práctica esta rama solo puede dispararse si en el futuro
	se agrega alguna forma de que el Oro del oponente aumente durante su
	turno — el conteo ya queda listo y correcto para ese momento."""
	var reactor_id: int = 1 - placer_id
	if oro_colocado_conteo.get(placer_id, 0) != 2:
		return
	if reactor_id != 0:
		return
	var candidates: Array = []
	for card_data in _main.player_hand.cards.map(func(c): return c.card_data):
		candidates.append({"data": card_data, "from": "mano"})
	for card_data in CardManager.get_cemetery(reactor_id):
		candidates.append({"data": card_data, "from": "cementerio"})
	for entry in candidates:
		var card_data: Dictionary = entry.data
		if card_data.get("tipo", -1) != Constants.CardType.ORO:
			continue
		var ability_lower := _fix_mojibake(str(card_data.get("habilidad", ""))).to_lower()
		if not ("segundo oro" in ability_lower and "oro pagado" in ability_lower):
			continue
		_offer_reactive_second_gold_to_pagado(reactor_id, card_data, entry.from)


func _offer_reactive_second_gold_to_pagado(reactor_id: int, card_data: Dictionary, from_zone: String) -> void:
	"""Ofrece mover UNA carta específica (ya confirmada como el patrón de
	Don de Amma) desde mano/Cementerio directo a Oro Pagado — reutiliza
	SelectionManager con un solo candidato como diálogo sí/no (clickearla =
	aceptar, Cancelar = declinar; mismo patrón 'puedes' que el resto de
	esta familia)."""
	# Sin botón "Confirmar" (2026-08-29, mismo criterio que El Presente/
	# Tangata/Perder la Razón): con un solo candidato, Confirmar-con-0 y
	# Cancelar son el mismo resultado — clickear la carta ya acepta sola.
	# min_selections=0 (2026-08-30, bug real corregido de paso):
	# await_single_pick() escucha selection_completed además de
	# card_selected/selection_cancelled — la versión manual de acá no lo
	# hacía, así que confirmar con 0 elegidas dejaba el panel colgado.
	var confirm_btn = SelectionManager.get("_confirm_button")
	if confirm_btn:
		confirm_btn.visible = false
	var accepted: Dictionary = await SelectionManager.await_single_pick(
		[card_data], "%s: puedes ponerlo en tu Oro Pagado (tu oponente ya puso su 2do Oro)" % card_data.get("nombre", "Oro"), true, 0)
	if confirm_btn:
		confirm_btn.visible = true
	if accepted.is_empty():
		return

	if from_zone == "mano":
		var hand_card: Node = null
		for c in _main.player_hand.cards:
			if c.card_data == card_data:
				hand_card = c
				break
		if hand_card:
			var idx = _main.player_hand.cards.find(hand_card)
			if idx >= 0:
				_main.player_hand.cards.remove_at(idx)
			_main.player_hand.remove_child(hand_card)
			_main.player_hand._arrange_cards()
			hand_card.queue_free()
	else:
		var cemetery: Array = CardManager.get_cemetery(reactor_id)
		var idx: int = cemetery.find(card_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(reactor_id, idx)

	await put_gold_directly_in_pagado(reactor_id, card_data)


func put_gold_directly_in_pagado(player_id: int, card_data: Dictionary) -> Node:
	"""Pone un Oro directo en el Oro Pagado de un jugador — nunca estuvo
	disponible para pagar nada, entra ya-gastado (2026-08-29, p.ej. Don de
	Amma). Mismo patrón que LookAndPlayResolver (Perder la Razón), pero
	generalizado a cualquier player_id en vez de asumir siempre 0."""
	var data: Dictionary = card_data.duplicate()
	data["esta_oculta"] = false
	var card_node = _main._create_card(data)
	card_node.owner_id = player_id
	card_node.can_interact = true
	card_node.scale = Constants.GOLD_CARD_SCALE
	card_node.base_scale = Constants.GOLD_CARD_SCALE
	_main._connect_card_signals(card_node)
	var target_container: HBoxContainer = _main.player_oro_pagado if player_id == 0 else _main.opponent_oro_pagado
	target_container.add_child(card_node)
	card_node.top_level = false
	card_node.modulate = Color(0.6, 0.6, 0.6, 1.0)
	card_node.set_zone(Constants.Zone.ORO_PAGADO)
	GameState.agregar_oro_pagado(player_id, 1)
	if player_id == 0:
		_main.gold_cards.append(card_node)
	await _trigger_enter_play(card_node, Constants.Zone.ORO_PAGADO)
	return card_node


func _place_card_as_gold(card: Node) -> void:
	if card.get_parent() != _main.player_hand:
		_main._update_debug("Solo puedes colocar cartas de la mano como Oro")
		return
	if card.card_type != Constants.CardType.ORO:
		_main._update_debug("Solo puedes colocar cartas de tipo Oro")
		return
	if not TurnManager.can_place_oro(GameManager.current_phase, card):
		_main._update_debug("No puedes colocar Oro ahora")
		if _main._card_interaction: _main._card_interaction.is_placing_gold = false
		return
	if PriorityManager.priority_window_active:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de colocar otro Oro")
		if _main._card_interaction: _main._card_interaction.is_placing_gold = false
		return
	var start_pos = card.global_position
	var idx = _main.player_hand.cards.find(card)
	if idx >= 0:
		_main.player_hand.cards.remove_at(idx)
	_main.player_hand.remove_child(card)
	_main.player_hand._arrange_cards()
	card.can_interact = false
	_main.player_gold.add_child(card)
	update_gold_containers_spacing()
	card.top_level = false
	card.set_zone(Constants.Zone.RESERVA_ORO)
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	# Oro más chico en Reserva (2026-08-28, a pedido del usuario — ganar
	# espacio en pantalla). Constants.GOLD_CARD_SCALE es el único punto de
	# verdad: mismo valor en GameBootstrap (Oro Inicial), _spawn_virtual_
	# gold_token() y LookAndPlayResolver (Oro Pagado directo de Perder la
	# Razón) — _mover_oro_a_pagado()/_mover_oro_a_reserva() no tocan scale,
	# así que solo hay que fijarlo una vez acá donde se crea/coloca.
	card.scale = Constants.GOLD_CARD_SCALE
	# base_scale ANTES del tween, no después (2026-08-28, a pedido del
	# usuario): CardInteraction._on_mouse_exited() calcula el tamaño de
	# reposo como base_scale * card_scale_normal — si el mouse pasaba por
	# encima de la carta durante estos ~0.3s de animación (base_scale
	# todavía en Vector2.ONE, el de la mano), el hover la devolvía a tamaño
	# completo. Recién en el próximo hover se veía "encoger de más" a su
	# tamaño real — no eran dos bugs, era el mismo: base_scale llegaba tarde.
	card.base_scale = Constants.GOLD_CARD_SCALE
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	card.can_interact = true
	TurnManager.oro_placed_this_turn = true
	TurnManager.any_card_played_this_turn = true
	_main.gold_cards.append(card)
	GameState.agregar_oro_reserva(0, 1)
	_register_gold_placed(0)
	var oro_actual = GameState.get_oro_reserva(0)
	_main._update_debug("%s colocado como Oro (Reserva: %d)" % [card.card_name, oro_actual])
	if _main._card_interaction: _main._card_interaction.is_placing_gold = false
	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)
	# Los Oros también pueden tener habilidades "Al entrar" (p.ej. Signo
	# Amarillo: "mira 4 cartas del tope") — este camino nunca las disparaba,
	# a diferencia de _play_card_to_field()/_play_talisman() que sí lo hacen.
	await _trigger_enter_play(card, Constants.Zone.RESERVA_ORO)


func put_gold_directly_in_reserva(player_id: int, card_data: Dictionary) -> Node:
	"""Pone un Oro directo en la Reserva de un jugador, sin pasar por la
	mano ni pagar coste — sale de una búsqueda ('busca un Oro en tu
	Castillo y ponlo en tu Reserva', 2026-08-29, p.ej. Don de Amma), no de
	jugarlo. Mismo patrón visual que el Oro Inicial de GameBootstrap.gd
	(único otro lugar que coloca Oro en Reserva sin pasar por
	_place_card_as_gold, que exige que la carta ya sea un Node hijo de
	player_hand)."""
	var card_node = _main._create_card(card_data, false)  # Oro es información pública (DAR), boca arriba siempre
	card_node.owner_id = player_id
	card_node.can_interact = true
	card_node.scale = Constants.GOLD_CARD_SCALE
	card_node.base_scale = Constants.GOLD_CARD_SCALE
	if player_id != 0:
		card_node.pivot_offset = Vector2(75.0, 105.0)
		card_node.rotation_degrees = 180.0
	_main._connect_card_signals(card_node)
	var target_container: HBoxContainer = _main.player_gold if player_id == 0 else _main.opponent_gold
	target_container.add_child(card_node)
	card_node.set_zone(Constants.Zone.RESERVA_ORO)
	if player_id == 0:
		_main.gold_cards.append(card_node)
	GameState.agregar_oro_reserva(player_id, 1)
	if player_id == 0:
		_update_gold_display()
	await _trigger_enter_play(card_node, Constants.Zone.RESERVA_ORO)
	return card_node


func play_card(card: Node) -> bool:
	# Excepciones de fase (2026-08-28): por defecto TODO se restringe a
	# Vigilia por los dos gateos de abajo (VIGILIA-only y ventana de
	# prioridad activa — Guerra de Talismanes SIEMPRE tiene una abierta,
	# PriorityManager.start_priority_window() al entrar a la fase). Dos
	# excepciones:
	#  1. Arma puntual habilitada por una carta en juego (Lobo Sagrado:
	#     'Puedes jugar Armas en Guerra de Talismanes') — ver
	#     _can_play_weapons_in_guerra_talismanes().
	#  2. Talismanes en general (DAR 5.3.3): se pueden jugar en Vigilia O en
	#     Guerra de Talismanes por defecto, salvo que su propio texto diga
	#     lo contrario (sin ejemplo concreto todavía — pendiente el día que
	#     aparezca una carta así) o sean de respuesta (Anular/Cancelar,
	#     p.ej. Red de Plata) — esos ya quedan bloqueados en CUALQUIER fase
	#     más abajo por _is_response_only_talisman(), así que no hace falta
	#     repetir la exclusión acá.
	var phase_exception: bool = has_phase_exception(card.card_type)

	if GameManager.current_phase != Constants.Phase.VIGILIA and not phase_exception:
		_main._update_debug(get_phase_rejection_reason(card.card_type))
		card.return_to_hand()
		return false
	if GameManager.active_player_id != 0:
		_main._update_debug("No es tu turno")
		card.return_to_hand()
		return false
	# Si hay una ventana de prioridad abierta (respuesta a un trigger que se
	# acaba de disparar, p.ej. 'cuando entre en juego' de la carta anterior),
	# no dejar jugar otra carta todavía — el trigger pendiente quedaba
	# pospuesto y se resolvía recién cuando pasaba OTRA acción, en el
	# momento equivocado. Hay que resolver esa ventana primero (¿Paso?).
	if PriorityManager.priority_window_active and not phase_exception:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de jugar otra carta")
		card.return_to_hand()
		return false
	if _no_more_cards_violation(card):
		_main._update_debug("No puedes jugar más cartas este turno")
		card.return_to_hand()
		return false
	if _card_play_locked(card):
		_main._update_debug("%s no puede jugarse todavía" % card.card_name)
		card.return_to_hand()
		return false
	if card.card_type == Constants.CardType.ORO:
		await _place_card_as_gold(card)
		return true
	if card.card_type == Constants.CardType.ARMA and not _player_has_ally_in_play():
		_main._update_debug("No puedes jugar un Arma sin Aliados en juego")
		await _return_card_rejected(card)
		return false
	if _errante_violation(card):
		_main._update_debug("Ya hay una copia de %s en juego (Errante)" % card.card_name)
		await _return_card_rejected(card)
		return false
	if _play_limit_violation(card):
		_main._update_debug("Ya jugaste un %s este turno" % card.card_name)
		await _return_card_rejected(card)
		return false
	if card.card_type == Constants.CardType.TALISMAN and _is_response_only_talisman(card):
		# DAR: Talismanes que Anulan/Cancelan/Previenen son de velocidad
		# instantánea — se juegan EN RESPUESTA a una carta o habilidad del
		# oponente, EN CUALQUIER MOMENTO DE LA PARTIDA (no restringidos a
		# Vigilia ni a Guerra de Talismanes, a diferencia de los Talismanes
		# normales de arriba) siempre y cuando exista un efecto válido al
		# que anular/cancelar/prevenir (2026-08-25 y confirmado 2026-08-28,
		# p.ej. Red de Plata, Sheut). El motor todavía no tiene una ventana
		# de respuesta real contra acciones del oponente (el bot no actúa de
		# forma independiente todavía — ver PriorityManager/
		# TriggerResolution._wait_for_response_window()), así que por ahora
		# esto los bloquea siempre, sin importar la fase; el día que exista
		# esa ventana real, acá se debe permitir en CUALQUIER fase si hay
		# algo válido a lo que responder — no solo Vigilia/Guerra de
		# Talismanes.
		_main._update_debug("%s solo se puede jugar en respuesta a una carta o habilidad del oponente" % card.card_name)
		await _return_card_rejected(card)
		return false
	# "Muestra X para reducir el coste" (2026-08-29, p.ej. El Rey y el
	# Verdugo) — se resuelve ANTES de calcular coste_real, porque el
	# descuento depende de una elección del jugador hecha en este mismo
	# instante (cuántas cartas mostrar), no de un modificador persistente.
	# No se remueve el modificador después a mano (2026-08-29: si esta
	# carta fuera un Arma habría un SEGUNDO cálculo de coste_real más abajo,
	# tras elegir portador, que también necesita verlo activo) — se deja
	# que _on_turn_started_clear_modifiers() lo limpie en el próximo turno,
	# igual que el resto de cost_modifiers; queda inerte una vez la carta
	# ya está en juego (nadie vuelve a pedir su coste después de jugada).
	var reveal_pattern: Dictionary = _get_reveal_cost_reduction_pattern(card)
	if not reveal_pattern.is_empty():
		var revealed_count: int = await _resolve_reveal_cost_reduction(card, reveal_pattern)
		if revealed_count > 0:
			var applies_to_this_card := func(c: Node) -> bool:
				return c == card
			PaymentManager.agregar_modificador_coste(card, -revealed_count, applies_to_this_card, reveal_pattern.allow_zero)

	# Filtro de asequibilidad ANTES de ofrecer portador (2026-08-28, a pedido
	# del usuario): con excepciones de fase tipo Lobo Sagrado (Guerra de
	# Talismanes permite Armas de cualquier coste) el jugador podía llegar a
	# elegir portador para un Arma que ya sabíamos que no podía pagar (0 Oro
	# disponible, Arma de coste 3) — no debía ser siquiera una opción válida,
	# igual que Tangata Manu/_make_look_play_free_filter ya filtran por
	# asequibilidad antes de mostrar candidatos. Se corta acá, antes de la
	# selección de portador, en vez de recién después.
	var coste_real = PaymentManager.calcular_coste_real(card)
	if not PaymentManager.puede_jugar_carta(card, 0):
		var disponible = get_oro_disponible()
		_main._update_debug("Oro insuficiente: necesitas %d, tienes %d (gastado este turno: %d)" % [
			coste_real, disponible, PaymentManager.oro_gastado_este_turno])
		# Limpiar el descuento de "muestra X" si se rechaza acá (2026-08-29):
		# si no, un segundo intento de jugar la misma carta más tarde este
		# turno heredaría el descuento sin haber mostrado nada de nuevo.
		PaymentManager.remover_modificador_coste(card)
		await _return_card_rejected(card)
		return false
	# Elegir portador ANTES de pagar el coste — si el jugador cancela (ESC),
	# no queremos que haya perdido Oro por un Arma que no llegó a equiparse.
	var chosen_wielder: Node = null
	if card.card_type == Constants.CardType.ARMA:
		# Bloquear el Arma mientras se elige portador (2026-08-21): seguía
		# interactiva en la mano durante la selección, así que un segundo
		# click/doble-click sobre ELLA MISMA volvía a llamar play_card() y
		# pisaba el filtro/callback pendiente en CardInteractionModule (son
		# campos únicos, no una cola) — la primera selección quedaba
		# colgada para siempre y 'Elige qué Aliado porta el Arma' se repetía
		# sin que ningún click a un Aliado la resolviera.
		card.can_interact = false
		chosen_wielder = await _select_weapon_wielder()
		if not chosen_wielder or not is_instance_valid(chosen_wielder):
			_main._update_debug("Equipar Arma cancelado")
			PaymentManager.remover_modificador_coste(card)
			await _return_card_rejected(card)
			return false
		# Re-chequeo tras la espera async de selección de portador: el Oro
		# disponible no debería cambiar en medio del propio turno del
		# jugador, pero es una comprobación barata y evita pagar de más si
		# algo sí lo cambió mientras esperaba.
		if not PaymentManager.puede_jugar_carta(card, 0):
			var disponible2 = get_oro_disponible()
			_main._update_debug("Oro insuficiente: necesitas %d, tienes %d (gastado este turno: %d)" % [
				coste_real, disponible2, PaymentManager.oro_gastado_este_turno])
			PaymentManager.remover_modificador_coste(card)
			await _return_card_rejected(card)
			return false
	if coste_real > 0:
		await pagar_coste(coste_real, card.card_type, card.get("card_raza") if card.get("card_raza") != null else "", card.card_cost)
		PaymentManager.registrar_pago(coste_real)
	_register_play_limit(card)
	if card.card_type == Constants.CardType.TALISMAN:
		await _play_talisman(card)
	elif card.card_type == Constants.CardType.ARMA:
		await _equip_weapon(card, chosen_wielder)
	else:
		await _play_card_to_field(card)
	return true


func play_card_from_cemetery(card_data: Dictionary) -> bool:
	"""Juega una carta con Exhumar directamente desde el Cementerio propio,
	como si estuviera en la mano (DAR - Exhumar). Espejo de play_card() pero
	con el Cementerio como origen en vez de la mano — la carta nunca pasa
	por player_hand, así que _play_talisman()/_play_card_to_field()/
	_equip_weapon() deben tolerar que no tenga ese parent (ya corregido).
	Al salir del juego irá al Destierro en vez del Cementerio: la carta se
	marca con is_exhumed = true, que CardManager.destroy_card() y
	GoldManager._play_talisman() ya respetan."""
	# Mismas excepciones que play_card() — ver su comentario (Arma puntual
	# tipo Lobo Sagrado + Talismanes en general en Guerra de Talismanes).
	var phase_exception: bool = has_phase_exception(card_data.get("tipo", -1))

	if GameManager.current_phase != Constants.Phase.VIGILIA and not phase_exception:
		_main._update_debug(get_phase_rejection_reason(card_data.get("tipo", -1)))
		return false
	if GameManager.active_player_id != 0:
		_main._update_debug("No es tu turno")
		return false
	if PriorityManager.priority_window_active and not phase_exception:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de jugar otra carta")
		return false
	if _no_more_cards_this_turn.get(0, false):
		_main._update_debug("No puedes jugar más cartas este turno")
		return false

	var card_type: int = card_data.get("tipo", -1)
	# Nota: _card_play_locked() opera sobre el Node (candado por instance_id,
	# ver lock_card_from_playing()) — play_card_from_cemetery() todavía no
	# tiene el Node acá (se crea más abajo), así que el candado de Chakram no
	# aplica a este camino (jugar con Exhumar desde el Cementerio no es el
	# caso que esa carta describe: 'una carta de la mano rival').
	var card = _main._create_card(card_data, false)
	card.owner_id = 0
	card.is_exhumed = true
	_main._connect_card_signals(card)

	if card_type == Constants.CardType.ARMA and not _player_has_ally_in_play():
		_main._update_debug("No puedes jugar un Arma sin Aliados en juego")
		card.queue_free()
		return false
	if _errante_violation(card):
		_main._update_debug("Ya hay una copia de %s en juego (Errante)" % card.card_name)
		card.queue_free()
		return false
	if _play_limit_violation(card):
		_main._update_debug("Ya jugaste un %s este turno" % card.card_name)
		card.queue_free()
		return false

	# Filtro de asequibilidad ANTES de ofrecer portador — ver mismo comentario
	# en play_card() (2026-08-28): no ofrecer selección de portador para un
	# Arma que ya sabemos que no se puede pagar.
	var coste_real = PaymentManager.calcular_coste_real(card)
	if not PaymentManager.puede_jugar_carta(card, 0):
		var disponible = get_oro_disponible()
		_main._update_debug("Oro insuficiente: necesitas %d, tienes %d" % [coste_real, disponible])
		card.queue_free()
		return false

	var chosen_wielder: Node = null
	if card_type == Constants.CardType.ARMA:
		card.can_interact = false
		chosen_wielder = await _select_weapon_wielder()
		if not chosen_wielder or not is_instance_valid(chosen_wielder):
			_main._update_debug("Equipar Arma cancelado")
			card.queue_free()
			return false
		if not PaymentManager.puede_jugar_carta(card, 0):
			var disponible2 = get_oro_disponible()
			_main._update_debug("Oro insuficiente: necesitas %d, tienes %d" % [coste_real, disponible2])
			card.queue_free()
			return false

	# Recién con todo confirmado (portador elegido, Oro alcanza) se retira
	# de verdad del Cementerio — igual que play_card() con la mano, para que
	# cancelar a mitad de camino no deje el Cementerio corrompido.
	var cemetery: Array = CardManager.get_cemetery(0)
	var idx: int = cemetery.find(card_data)
	if idx < 0:
		card.queue_free()
		return false
	CardManager.exhume_card(0, idx)

	if coste_real > 0:
		await pagar_coste(coste_real, card_type, card_data.get("raza", ""), card_data.get("coste", 0))
		PaymentManager.registrar_pago(coste_real)

	_register_play_limit(card)
	if card_type == Constants.CardType.TALISMAN:
		await _play_talisman(card)
	elif card_type == Constants.CardType.ARMA:
		await _equip_weapon(card, chosen_wielder)
	else:
		await _play_card_to_field(card)
	return true


func play_card_for_free(card_data: Dictionary) -> bool:
	"""Juega una carta SIN pagar su coste ni pasar por la mano (2026-08-25,
	p.ej. Tangata Manu: 'juega una carta de coste 2 o menos... sin pagar su
	coste'). El llamador ya sacó card_data de su zona de origen — acá solo
	se crea el nodo y se enruta según su tipo, igual que play_card()/
	play_card_from_cemetery() pero sin pasar por PaymentManager."""
	var card_type: int = card_data.get("tipo", -1)
	var card = _main._create_card(card_data, false)
	card.owner_id = 0
	_main._connect_card_signals(card)

	if card_type == Constants.CardType.ARMA and not _player_has_ally_in_play():
		_main._update_debug("No se pudo jugar %s: sin Aliados en juego para portar el Arma" % card.card_name)
		card.queue_free()
		return false
	if _errante_violation(card):
		_main._update_debug("No se pudo jugar %s: ya hay una copia en juego (Errante)" % card.card_name)
		card.queue_free()
		return false

	var chosen_wielder: Node = null
	if card_type == Constants.CardType.ARMA:
		card.can_interact = false
		chosen_wielder = await _select_weapon_wielder()
		if not chosen_wielder or not is_instance_valid(chosen_wielder):
			_main._update_debug("Equipar Arma cancelado")
			card.queue_free()
			return false

	if card_type == Constants.CardType.TALISMAN:
		await _play_talisman(card)
	elif card_type == Constants.CardType.ARMA:
		await _equip_weapon(card, chosen_wielder)
	else:
		await _play_card_to_field(card)
	return true


func _select_weapon_wielder() -> Node:
	"""Abre selección de objetivo para elegir qué Aliado propio porta el
	Arma que se está jugando (DAR — un Arma no puede ir suelta, y un Aliado
	solo porta una a la vez)."""
	if not _main._card_interaction:
		return null
	# Chequeo defensivo ANTES de abrir la selección (2026-08-28): todos los
	# llamadores ya verifican _player_has_ally_in_play() antes de llegar
	# acá, pero si por cualquier motivo (nuevo llamador, estado cambiado
	# entre medio) esto se llamara con cero candidatos elegibles, abrir la
	# selección de todos modos la dejaba colgada para siempre — cualquier
	# click en cualquier carta (incluidas otras de la mano) caía en
	# "Objetivo no válido" sin resolver nunca 'done', y el jugador quedaba
	# sin poder jugar más cartas hasta reiniciar. Cortar acá es la última
	# red de seguridad, sin importar qué otro chequeo haya fallado antes.
	if _get_eligible_weapon_wielders().is_empty():
		_main._update_debug("No tienes un Aliado libre para portar el Arma")
		return null
	var filter := func(c: Node) -> bool:
		return c in _get_eligible_weapon_wielders()
	return await _main._card_interaction.await_target("Elige qué Aliado porta el Arma", filter)


func _equip_weapon(weapon: Node, ally: Node) -> void:
	"""Ancla el Arma como hija directa del Aliado portador — no va a ningún
	contenedor de línea. Se puede seguir inspeccionando con clic derecho por
	separado (mismo Card.tscn/Card.gd) y la sigue automáticamente si el
	Aliado se reparenta (ataca) o sale de juego (ver CardManager.destroy_card/
	exile_card, que la mueven al mismo destino que el portador)."""
	TurnManager.on_card_played(weapon)
	_main._update_debug("Equipando %s a %s" % [weapon.card_name, ally.card_name])

	# Quitar de la mano SOLO si de verdad sigue ahí (2026-08-22): llamadores
	# como TriggerSystem._execute_play_weapon_discount_draw() (Lobo Sagrado)
	# pueden pasar un Arma que YA se sacó de su origen antes de llamar acá
	# (de mano) o que nunca estuvo en la mano (recién instanciada desde el
	# Cementerio) — remove_child() sobre un nodo que no es hijo tira error.
	var idx = _main.player_hand.cards.find(weapon)
	if idx >= 0:
		_main.player_hand.cards.remove_at(idx)
	if weapon.get_parent() == _main.player_hand:
		_main.player_hand.remove_child(weapon)
		_main.player_hand._arrange_cards()
	weapon.can_interact = false

	var start_pos = weapon.global_position if weapon.is_inside_tree() else ally.global_position
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	ally.add_child(weapon)
	# Detrás del Aliado, asomando solo por abajo (2026-08-29, tercera vuelta
	# de este mismo ajuste, a pedido del usuario: 'el portador está sobre el
	# arma y esta solo se puede ver su caja de texto por abajo'). El primer
	# intento (2026-08-26) usó z_index=-1 con un offset chico (30px) — TODO
	# el Arma quedaba dentro del rect del Aliado, tapada 100% por su
	# CardBase. El segundo intento (más arriba en el historial) sacó la
	# superposición por completo (Arma abajo del todo, sin tapar nada) — el
	# usuario prefiere la superposición real: portador arriba, Arma
	# asomando abajo. La diferencia con el primer intento es el OFFSET: acá
	# es lo bastante grande (140 de 210 de alto) para que la parte de abajo
	# del Arma quede FUERA del rect del Aliado (ahí sí se ve, nada del
	# Aliado la tapa), y solo la parte de arriba (dentro del rect) queda
	# escondida detrás del CardBase.
	ally.move_child(weapon, 0)
	weapon.z_index = 0
	weapon.original_z_index = 0
	weapon.top_level = false
	weapon.modulate.a = 1.0
	weapon.visible = true
	weapon.set_zone(ally.current_zone)

	# Mismo tamaño que el Aliado, no una insignia chica (2026-08-29, a pedido
	# del usuario: 'el arma debe ser del mismo tamaño que el aliado') —
	# escala dinámica (ally.base_scale) en vez de un valor fijo, para seguir
	# el tamaño real del Aliado sea cual sea (campo normal vs. Tótem u otra
	# escala futura). base_scale junto con scale, no solo scale (misma clase
	# de bug que _place_card_as_gold(): CardInteraction usa base_scale como
	# referencia para el tamaño de reposo tras el hover, y CardAnimations.
	# play_enter_animation() la usa como destino de su tween de entrada).
	# Y=140 de 210 de alto de carta (Card.tscn) — deja ~70px asomando abajo
	# del borde inferior del Aliado, la franja donde una carta real imprime
	# su texto. Con más de un Arma equipada se van apilando hacia abajo.
	var slot_index = ally.equipped_weapons.size()
	var equip_scale: Vector2 = ally.base_scale
	weapon.scale = equip_scale
	weapon.base_scale = equip_scale
	weapon.position = Vector2(0.0, 125.0 + slot_index * 40.0)
	ally.equipped_weapons.append(weapon)
	weapon.wielder = ally
	_register_weapon_strength_bonus(weapon, ally)
	_register_wielder_leave_play_immunity(weapon, ally)
	_refresh_dynamic_strength_badges(ally.controller_id if ally.get("controller_id") != null else 0)

	await get_tree().process_frame
	var end_pos = weapon.global_position
	weapon.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(weapon, "global_position", end_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	weapon.can_interact = true
	weapon.modulate.a = 1.0
	VisualManager.play_card_effect(weapon.card_cost)
	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)
	await _trigger_enter_play(weapon, ally.current_zone)


func _register_weapon_strength_bonus(weapon: Node, ally: Node) -> void:
	"""Parsea 'El portador gana N de Fuerza' del texto del Arma y registra el
	bono en ContinuousEffectManager con duración PERMANENT ('mientras la
	fuente esté en juego') — se limpia solo cuando el Arma sale de juego
	(Card._exit_tree() llama remove_modifiers_from_source() sin importar
	cómo salió: destruida, desterrada, devuelta al mazo). El combate
	(BattleManager._get_strength()) y el badge visual de la carta ya
	consultan este valor calculado, así que con solo registrar el
	modificador alcanza para que todo se refleje solo."""
	var ability_text: String = weapon.get("card_ability") if weapon.get("card_ability") != null else ""
	if ability_text.is_empty():
		return
	var rx := RegEx.new()
	rx.compile("(?i)el portador gana (\\d+) de fuerza")
	var m := rx.search(ability_text)
	if not m:
		return
	var bonus := int(m.get_string(1))
	if bonus <= 0:
		return
	ContinuousEffectManager.register_modifier({
		"source": weapon,
		"target": ally,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": bonus,
		"operation": "add",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "%s porta %s (+%d Fuerza)" % [ally.card_name, weapon.card_name, bonus],
	})
	if ally.has_method("refresh_strength_badge"):
		ally.refresh_strength_badge()


func _register_wielder_leave_play_immunity(weapon: Node, ally: Node) -> void:
	"""'Cuando entra en juego, el portador no puede salir del juego hasta tu
	próximo turno' (2026-08-30, p.ej. Garfio Pirata) — mismo criterio que
	_register_weapon_strength_bonus(): efecto propio del Arma sobre su
	portador al equiparse, resuelto directo acá (no por el pipeline genérico
	de triggers) porque necesita saber QUIÉN es el portador, algo que
	ABILITY_PATTERNS no puede extraer solo de un regex."""
	var ability: String = weapon.card_ability.to_lower() if weapon.get("card_ability") else ""
	if not ("el portador no puede salir del juego" in ability):
		return
	var controller_id: int = weapon.controller_id if weapon.get("controller_id") != null else 0
	EffectController.add_single_card_leave_play_immunity(ally, controller_id)


func _refresh_dynamic_strength_badges(player_id: int) -> void:
	"""Invalida el cache de ContinuousEffectManager y refresca el badge de
	Fuerza de TODOS los Aliados de player_id (2026-08-30, bug real: Manuel
	Bulnes 'Gana N de Fuerza por cada Arma que controles' es un modificador
	DINÁMICO — value es un Callable que cuenta Armas equipadas en TODO el
	campo de su controlador cada vez que se evalúa. Equipar un Arma en OTRO
	Aliado no registra/desregistra ningún modificador DE Bulnes, así que
	ContinuousEffectManager._get_modified_stat()'s cache (solo se invalida
	en register_modifier()/unregister_modifier(), no cuando cambia el
	CONTEO de Armas de otra carta) nunca se enteraba — el valor calculado
	quedaba pegado al de cuando Bulnes entró en juego, sin importar cuántas
	Armas se equiparan después. Llamar cada vez que el conteo de Armas
	equipadas de un jugador puede haber cambiado (acá: al equipar una)."""
	if ContinuousEffectManager.has_method("_invalidate_cache"):
		ContinuousEffectManager._invalidate_cache()
	var fields = [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo] if player_id == 0 \
		else [_main.opponent_field, _main.opponent_linea_ataque, _main.opponent_linea_apoyo]
	for field in fields:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c.has_method("refresh_strength_badge"):
				c.refresh_strength_badge()


func _fix_mojibake(text: String) -> String:
	"""Corrige el patrón de doble-codificación UTF-8→Latin-1→UTF-8 más común
	en español (2026-08-26, visto en el texto de habilidad que trae la API
	de ShadowForge para varias cartas, p.ej. 'TalismÃ¡n' en vez de
	'Talismán'). No es un fix general de encoding, solo cubre las vocales
	acentuadas + ñ que aparecen en texto de cartas. El orden importa: los
	reemplazos de 2 caracteres van antes que el 'Ã' suelto, si no ese
	genérico los rompe primero."""
	var fixed := text
	fixed = fixed.replace("Ã¡", "á")
	fixed = fixed.replace("Ã©", "é")
	fixed = fixed.replace("Ã­", "í")
	fixed = fixed.replace("Ã³", "ó")
	fixed = fixed.replace("Ãº", "ú")
	fixed = fixed.replace("Ã±", "ñ")
	fixed = fixed.replace("Ã¼", "ü")
	fixed = fixed.replace("Ã‰", "É")
	fixed = fixed.replace("Ã", "Á")
	return fixed


func _register_talisman_totem_tax(card: Node) -> void:
	"""Detecta 'jugar Talismanes y Tótems cuesta un Oro adicional' (p.ej.
	Bernardo O'Higgins) y registra el impuesto en PaymentManager — afecta a
	CUALQUIER Talismán/Tótem que se calcule con calcular_coste_real(), del
	dueño que sea (2026-08-26, a pedido del usuario: aplica a los dos
	jugadores por igual).

	PaymentManager.cost_modifiers se vacía entero en cada turno nuevo
	(_on_turn_started_clear_modifiers, pensado para descuentos de un solo
	uso como el de Lobo Sagrado) — para que este impuesto dure 'mientras la
	carta esté en juego' (varios turnos), se re-registra en cada
	turn_started mientras la carta siga válida y en juego, y se desconecta
	sola apenas deja de estarlo. La limpieza al salir de juego de verdad la
	hace Card._exit_tree() → PaymentManager.remover_modificador_coste()."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return
	# _fix_mojibake() (2026-08-26): la API de ShadowForge trae "TalismÃ¡n"/
	# "TÃ³tem" con doble codificación rota para varias cartas (Bernardo
	# O'Higgins entre ellas) — sin normalizar, "talismán"/"tótem" nunca
	# matcheaban y este impuesto quedaba inerte para esas cartas.
	var lower := _fix_mojibake(ability_text).to_lower()
	var mentions_tax := "oro adicional" in lower
	var mentions_talisman_totem := ("talismán" in lower or "talisman" in lower) and ("tótem" in lower or "totem" in lower)
	if not (mentions_tax and mentions_talisman_totem):
		return

	var condition := func(c: Node) -> bool:
		return c.get("card_type") in [Constants.CardType.TALISMAN, Constants.CardType.TOTEM]

	PaymentManager.agregar_modificador_coste(card, 1, condition)
	# Afecta a una CATEGORÍA de cartas (todo Talismán/Tótem), no una sola —
	# refresca toda la mano, no un solo card_node (2026-08-30).
	PaymentManager.refresh_all_hand_cost_badges()

	var reapply: Callable
	reapply = func(_player_id: int, _turn: int) -> void:
		if not is_instance_valid(card) or not card.is_in_play():
			if GameManager.turn_started.is_connected(reapply):
				GameManager.turn_started.disconnect(reapply)
			return
		PaymentManager.agregar_modificador_coste(card, 1, condition)
		PaymentManager.refresh_all_hand_cost_badges()
	GameManager.turn_started.connect(reapply)


func _get_reveal_cost_reduction_pattern(card: Node) -> Dictionary:
	"""Detecta 'Reduce su coste en un Oro por cada X que muestres de tu
	mano, Cementerio o que controles, hasta un mínimo de N' (2026-08-29,
	p.ej. El Rey y el Verdugo: '...por cada Arma...'). A diferencia de
	_register_talisman_totem_tax()/_register_weapon_first_play_discount()
	(modificadores PERSISTENTES de una carta ya en juego, afectando a
	OTRAS), este es un descuento de UN SOLO USO sobre la carta que se está
	jugando AHORA MISMO — se resuelve en play_card(), no como un modifier
	registrado en turn_started.
	Returns: {} si no aplica, si no {type: Constants.CardType, allow_zero: bool}."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return {}
	var lower := _fix_mojibake(ability_text).to_lower()
	if not ("reduce su coste" in lower and "que muestres" in lower):
		return {}
	var wanted_type: int = -1
	if "arma" in lower:
		wanted_type = Constants.CardType.ARMA
	elif "aliado" in lower:
		wanted_type = Constants.CardType.ALIADO
	elif "talismán" in lower or "talisman" in lower:
		wanted_type = Constants.CardType.TALISMAN
	elif "tótem" in lower or "totem" in lower:
		wanted_type = Constants.CardType.TOTEM
	elif "oro" in lower:
		wanted_type = Constants.CardType.ORO
	if wanted_type == -1:
		return {}
	var allow_zero := "mínimo de 0" in lower or "minimo de 0" in lower
	return {"type": wanted_type, "allow_zero": allow_zero}


func _gather_showable_candidates(card_type: int, exclude_card: Node, source: int) -> Array:
	"""Reúne candidatos 'que muestres de tu mano, Cementerio o que
	controles' de UNA sola zona a la vez (source: 0=mano, 1=Cementerio,
	2=en juego) — 'mostrar' (DAR) no mueve ni gasta nada, la carta se queda
	donde está.

	Antes juntaba las tres zonas en un solo pool combinado (2026-08-31,
	corregido a pedido del usuario): el 'y/o' de 'tu mano, Cementerio o que
	controles' es DAR para 'elegí UNA de las tres', no 'mostrá cualquier
	combinación de las tres a la vez' — con el pool combinado se podía
	mostrar, p.ej., un Arma de la mano Y otra del Cementerio en el mismo
	'muestra X', algo que el texto real no permite. Ver
	_resolve_reveal_cost_reduction(), que ahora pide la zona ANTES de
	llamar acá."""
	var candidates: Array = []
	match source:
		0:
			for c in _main.player_hand.cards:
				if c == exclude_card:
					continue
				if c.get("card_type") == card_type:
					candidates.append(c.card_data)
		1:
			for d in CardManager.get_cemetery(0):
				if d.get("tipo", -1) == card_type:
					candidates.append(d)
		2:
			var field_zones: Array = [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo]
			for zone in field_zones:
				if not zone:
					continue
				for ally in zone.get_children():
					if ally.get("card_type") == card_type:
						candidates.append(ally.card_data)
					for weapon in ally.get("equipped_weapons") if ally.get("equipped_weapons") != null else []:
						if is_instance_valid(weapon) and weapon.get("card_type") == card_type:
							candidates.append(weapon.card_data)
	return candidates


const _CARD_TYPE_DISPLAY_NAMES: Dictionary = {
	0: "Oro", 1: "Aliado(s)", 2: "Arma(s)", 3: "Talismán(es)", 4: "Tótem(s)"
}


func _resolve_reveal_cost_reduction(card: Node, pattern: Dictionary) -> int:
	"""Primero elige UNA zona de origen (mano / Cementerio / en juego —
	2026-08-31, corregido: el 'y/o' del texto es 'elegí una', no un pool
	combinado, ver _gather_showable_candidates()), después abre selección
	múltiple (0 a todos los candidatos DE ESA ZONA) — el jugador elige
	CUÁLES mostrar, el conteo de elegidas es la reducción de Oro (DAR: 1
	por carta mostrada). No remueve nada de su zona ('mostrar' no es
	'gastar' ni 'desterrar').
	Returns: cantidad de cartas mostradas (0 si no había candidatos en la
	zona elegida o no se eligió ninguna)."""
	var type_name: String = _CARD_TYPE_DISPLAY_NAMES.get(pattern.type, "carta(s)")
	var source: int = await SelectionManager.await_choice(
		_main, "¿Desde dónde mostrar %s para reducir el coste?" % type_name,
		["Tu mano", "Tu Cementerio", "Lo que controlas en juego"])
	var candidates: Array = _gather_showable_candidates(pattern.type, card, source)
	if candidates.is_empty():
		return 0
	# Tope real de cartas ÚTILES a mostrar (2026-09-02, bug reportado por el
	# usuario: con base_cost=2 y 'hasta un mínimo de 0', mostrar más de 2
	# no reduce nada más — pero el picker seguía ofreciendo hasta
	# candidates.size(), dejando elegir 3 o 4 sin ningún efecto). El piso
	# real que aplica calcular_coste_real() es 0 con allow_zero, 1 si no
	# (mismo criterio documentado ahí) — más allá de coste_base - piso, cada
	# carta adicional mostrada es un no-op.
	var floor_val: int = 0 if pattern.get("allow_zero", false) else 1
	var base_cost: int = int(card.get("card_cost")) if card.get("card_cost") != null else 0
	var useful_cap: int = maxi(base_cost - floor_val, 0)
	var max_selections: int = mini(candidates.size(), useful_cap) if useful_cap > 0 else candidates.size()
	var result: Dictionary = await SelectionManager.await_multi_pick(
		candidates,
		"Muestra %s de esa zona para reducir el coste (1 Oro c/u)" % type_name,
		max_selections)
	return result.picked.size()


func _errante_violation(card: Node) -> bool:
	"""Errante (keyword real de Mitos y Leyendas, corrección 2026-08-20):
	solo puede haber una copia de esta carta en juego a la vez, sin importar
	el controlador. Distinto de Única, que limita copias en el MAZO."""
	if not KeywordManager.has_keyword(card, Constants.Keyword.ERRANTE):
		return false
	var card_name: String = card.card_name if card.get("card_name") != null else ""
	if card_name.is_empty():
		return false
	for field in [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo, _main.opponent_field, _main.opponent_linea_ataque, _main.opponent_linea_apoyo]:
		if not field:
			continue
		for existing in field.get_children():
			if existing != card and existing.get("card_name") == card_name:
				return true
	return false


func _play_limit_violation(card: Node) -> bool:
	"""'Sólo puedes jugar un <Nombre> por turno' (2026-08-30, p.ej. Aaru) —
	restricción de JUGAR la carta en sí (distinta de 'una vez por turno'
	sobre una habilidad ACTIVADA), por NOMBRE y compartida entre todas las
	copias: si ya jugaste un <Nombre> este turno, no puedes jugar un segundo
	aunque sea una copia distinta. Se registra en UniversalCardParser.
	turn_registry con un prefijo propio ('play_limit:') para no compartir
	namespace con el registro de habilidades ACTIVADAS (card_id/ability_index
	numéricos)."""
	var habilidad: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var lower := habilidad.to_lower()
	if not (("solo puedes jugar un" in lower or "sólo puedes jugar un" in lower) and "por turno" in lower):
		return false
	var card_name: String = card.card_name if card.get("card_name") != null else ""
	if card_name.is_empty():
		return false
	var name_key: String = "play_limit:%s" % card_name.to_lower()
	return UniversalCardParser.turn_registry.was_used(name_key, 0, GameManager.current_turn)


func _register_play_limit(card: Node) -> void:
	"""Registra el uso del cupo de 'Sólo puedes jugar un <Nombre> por turno'
	(ver _play_limit_violation()) — llamar solo cuando el juego de la carta
	ya está garantizado (después de todas las validaciones, justo antes de
	colocarla), para no gastar el cupo en un intento que después se cancela
	(sin Oro suficiente, portador cancelado, etc.)."""
	var habilidad: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var lower := habilidad.to_lower()
	if not (("solo puedes jugar un" in lower or "sólo puedes jugar un" in lower) and "por turno" in lower):
		return
	var card_name: String = card.card_name if card.get("card_name") != null else ""
	if card_name.is_empty():
		return
	var name_key: String = "play_limit:%s" % card_name.to_lower()
	UniversalCardParser.turn_registry.register(name_key, 0, GameManager.current_turn)


func _is_response_only_talisman(card: Node) -> bool:
	"""Detecta Talismanes de velocidad instantánea (DAR): 'Anula un Aliado o
	Tótem...' / 'Anula o cancela la habilidad de una carta...' (p.ej. Red de
	Plata, Sheut, Sacrificio Solar). Busca una ORACIÓN que EMPIECE con
	'anula'/'cancela' — no basta con 'anula' en cualquier parte del texto,
	porque frases de protección como 'no puede ser Anulada' o 'esta
	habilidad no puede ser cancelada' contienen la misma palabra pero son
	lo opuesto (protección de la propia carta, no su efecto)."""
	var ability_text: String = card.card_ability if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return false
	for raw_sentence in ability_text.split("."):
		var sentence: String = raw_sentence.strip_edges().to_lower()
		if sentence.begins_with("anula") or sentence.begins_with("cancela"):
			return true
	return false


func _player_has_ally_in_play() -> bool:
	"""Verifica si el jugador tiene al menos un Aliado SIN Arma ya equipada
	(requisito para poder jugar un Arma — un Aliado solo porta una a la vez,
	y sin portador libre no tiene sentido). Antes solo miraba si había
	CUALQUIER Aliado, sin importar si ya portaba Arma — dejaba pasar a
	_select_weapon_wielder() con cero candidatos elegibles de verdad y esa
	selección se quedaba colgada para siempre (2026-08-28, bug reportado por
	el usuario: intentar jugar un Arma sin portador válido lo dejaba sin
	poder jugar más cartas)."""
	return not _get_eligible_weapon_wielders().is_empty()


func _get_eligible_weapon_wielders() -> Array:
	"""Aliados propios en juego que todavía tienen espacio para portar un
	Arma más (normalmente 1, o más con 'Tus Aliados pueden portar un Arma
	adicional' en juego — ver _max_weapons_per_ally(), 2026-08-31, Levisterio)."""
	var eligible: Array = []
	var max_weapons: int = _max_weapons_per_ally()
	for field in [_main.player_field, _main.player_linea_ataque]:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			if card.get("card_type") != Constants.CardType.ALIADO:
				continue
			if _ally_weapon_count(card) >= max_weapons:
				continue
			eligible.append(card)
	return eligible


func _ally_weapon_count(ally: Node) -> int:
	# equipped_weapons es la lista mantenida por _equip_weapon() — mismo
	# campo que ya usan BernardoAbilityHandler/CardManager/ActionModule, más
	# directo que volver a escanear get_children() a mano.
	var weapons = ally.get("equipped_weapons")
	return weapons.size() if weapons is Array else 0


func _max_weapons_per_ally() -> int:
	"""1 Arma por Aliado por defecto (DAR). +1 por cada carta propia en
	juego con 'Tus Aliados pueden portar un Arma adicional' (2026-08-31,
	Levisterio) — mismo patrón de escaneo por texto que
	_can_play_weapons_in_guerra_talismanes(), no es una Keyword fija
	(ver nota en Constants.gd)."""
	var extra: int = 0
	for field in [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo]:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
			if ability_text.is_empty():
				continue
			var lower := _fix_mojibake(ability_text).to_lower()
			if "aliados pueden portar un arma adicional" in lower:
				extra += 1
	return 1 + extra


func _can_play_weapons_in_guerra_talismanes() -> bool:
	"""Detecta 'Puedes jugar Armas en Guerra de Talismanes' (p.ej. Lobo
	Sagrado) en el propio jugador (2026-08-28) — misma técnica de
	escaneo-de-texto que _register_talisman_totem_tax(), pero como chequeo
	de legalidad puntual en vez de un modificador registrado, porque acá
	solo importa el instante de jugar el Arma, no algo que deba persistir."""
	for field in [_main.player_field, _main.player_linea_ataque, _main.player_linea_apoyo]:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
			if ability_text.is_empty():
				continue
			var lower := _fix_mojibake(ability_text).to_lower()
			if "jugar armas en guerra de talismanes" in lower:
				return true
	return false


func has_phase_exception(card_type: int) -> bool:
	"""Único punto de verdad para las excepciones de fase (Arma puntual tipo
	Lobo Sagrado + Talismanes en general en Guerra de Talismanes) — antes
	estaba duplicado inline en play_card()/play_card_from_cemetery(), y
	CardInteractionModule._on_card_double_clicked() tenía su PROPIO gateo de
	fase sin conocer esta excepción, así que nunca dejaba ni siquiera
	intentar jugar el Arma/Talismán (2026-08-28, bug reportado por el
	usuario: 'no puedo jugar armas en guerra'). Llamar esto desde cualquier
	punto que decida si una carta se puede jugar fuera de Vigilia."""
	if GameManager.current_phase != Constants.Phase.GUERRA_TALISMANES:
		return false
	if card_type == Constants.CardType.TALISMAN:
		return true
	if card_type == Constants.CardType.ARMA:
		return _can_play_weapons_in_guerra_talismanes()
	return false


func get_phase_rejection_reason(card_type: int) -> String:
	"""Mensaje específico de por qué ESTA carta no se puede jugar ahora mismo
	(2026-08-28, a pedido del usuario: el genérico 'Solo puedes jugar cartas
	en Vigilia' no decía si esa carta en particular sí tenía alguna
	excepción posible — un Talismán en Guerra de Talismanes normalmente SÍ
	se puede, un Aliado no puede nunca fuera de Vigilia). Llamar solo cuando
	ya se decidió rechazar (current_phase != VIGILIA and not
	has_phase_exception(card_type))."""
	var phase := GameManager.current_phase
	if phase == Constants.Phase.GUERRA_TALISMANES:
		match card_type:
			Constants.CardType.ARMA:
				return "Necesitas un efecto en juego (como Lobo Sagrado) para jugar Armas en Guerra de Talismanes"
			Constants.CardType.TALISMAN:
				return "Ese Talismán es de respuesta — solo se juega en respuesta a una carta o habilidad del oponente"
			_:
				return "En Guerra de Talismanes solo se pueden jugar Talismanes (y Armas, si algo lo permite)"
	return "Solo puedes jugar cartas en tu Vigilia o en Guerra de Talismanes (Talismanes/Armas habilitadas)"


func _return_card_rejected(card: Node) -> void:
	if not card or not is_instance_valid(card):
		return
	# Restaurar interactividad (2026-08-21): el Arma se deshabilita al abrir
	# la selección de portador (ver play_card()) — si esa selección se
	# cancela o el pago falla, la carta debe volver a ser clickeable.
	card.can_interact = true
	# Si la carta nunca fue arrastrada (doble click), original_position es Vector2.ZERO — corregirlo
	# antes de llamar return_to_hand(), que usa esa propiedad para animar el regreso.
	if card.get("original_position") != null and card.original_position == Vector2.ZERO:
		card.original_position = card.global_position
	# Flash rojo — sin tweenear global_position para no pelear con el layout del contenedor
	var tween = create_tween()
	tween.tween_property(card, "modulate", Color(1.5, 0.3, 0.3, 1.0), 0.08)
	await tween.finished
	var tween2 = create_tween()
	tween2.tween_property(card, "modulate", Color.WHITE, 0.2)
	await tween2.finished
	card.return_to_hand()


func _play_card_to_field(card: Node) -> void:
	TurnManager.on_card_played(card)
	_main._update_debug("Jugando: %s" % card.card_name)
	var start_pos = card.global_position
	var idx = _main.player_hand.cards.find(card)
	if idx >= 0:
		_main.player_hand.cards.remove_at(idx)
	# Solo si de verdad sigue en la mano (2026-08-23): un Aliado/Tótem
	# jugado via Exhumar (play_card_from_cemetery) nunca estuvo en la mano —
	# remove_child() sobre un nodo que no es hijo tira error (mismo bug ya
	# corregido en _equip_weapon() para Lobo Sagrado).
	if card.get_parent() == _main.player_hand:
		_main.player_hand.remove_child(card)
		_main.player_hand._arrange_cards()
	card.can_interact = false
	# Tótems van a Línea de Apoyo; Aliados y Armas a Línea de Defensa
	# (DAR — 3 zonas reales dentro del campo, ver consolidación 2026-08-20).
	var target_container: HBoxContainer = _main.player_linea_apoyo if card.card_type == Constants.CardType.TOTEM else _main.player_field
	var target_zone: int = Constants.Zone.LINEA_APOYO if card.card_type == Constants.CardType.TOTEM else Constants.Zone.LINEA_DEFENSA
	target_container.add_child(card)
	# Si la carta llegó por arrastre (drag), top_level seguía en true (modo
	# 'posición global libre' que usa Card._update_drag()). Sin resetearlo,
	# el contenedor no puede posicionarla de verdad, y el 'end_pos' leído
	# más abajo terminaba siendo la última posición del arrastre en vez de
	# la casilla real del campo — la carta se animaba hacia un lugar sin
	# relación con el campo, dando la sensación de que desaparecía.
	card.top_level = false
	card.set_zone(target_zone)
	await get_tree().process_frame
	# Escala del campo (2026-08-29, a pedido del usuario: 'las cartas ahora
	# en juego están muy chicas, agrándalas'): los Aliados vuelven a 1.0.
	# Los Tótems se quedan en 0.8 — la Línea de Apoyo es más baja que una
	# carta a escala 1.0 y terminaba tapada por la Mano (2026-08-26, no se
	# tocó la geometría de Main.tscn entonces, revertido a pedido).
	var field_scale: Vector2 = Vector2(0.8, 0.8) if card.card_type == Constants.CardType.TOTEM else Vector2.ONE
	card.scale = field_scale
	# Slot fijo en vez de la posición que el HBoxContainer calculaba
	# (2026-08-31, a pedido del usuario: 'cuando 1 ataque, el otro toma su
	# puesto' — con el Container reordenando TODO cada vez que entraba/salía
	# un hijo, los Aliados/Tótems ya en juego se corrían de lugar solos. Ver
	# ZoneManager.pin_card_to_field_slot()).
	var end_pos: Vector2 = _main._zone_manager.pin_card_to_field_slot(card, target_container)
	card.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	card.base_scale = field_scale
	card.can_interact = true
	VisualManager.play_card_effect(card.card_cost)
	if card.has_method("play_enter_animation"):
		card.play_enter_animation()
	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)
	await _trigger_enter_play(card, target_zone)


func _trigger_enter_play(card: Node, zone: int = Constants.Zone.LINEA_DEFENSA) -> void:
	"""Dispara la entrada al juego (DAR 7.4) para habilidades 'Al entrar' de
	Aliados/Armas/Oro/Tótems. Para Talismanes es distinto (2026-08-27): no
	'disparan' nada, se resuelven directo vía TriggerSystem.resolve_talisman()
	sin pasar por la cola de triggers — ver el branch de card_type más abajo.

	Este método mueve la carta directamente (ver player_field.add_child arriba)
	en vez de pasar por EffectController.play_card_to_zone(), porque esa función
	depende de un GameBoard legacy que no está activo en la escena actual (su
	@onready apunta a nodos de un layout de tablero anterior — BattleField/
	PlayerLineaDefensa/etc. — que ya no existe en Main.tscn).

	CardEffectSystem sigue escuchando la señal (fire-and-forget) solo para
	recalcular efectos continuos — su propia ejecución de texto está
	desactivada a propósito para no duplicar el efecto. Pero el trigger en
	sí (TriggerSystem → UniversalCardParser → ActionModule) se llama DIRECTO
	con 'await' en vez de por señal: conectado por señal, quien juega la
	carta no esperaba a que el trigger terminara de resolverse, así que el
	juego seguía de fase mientras el trigger todavía se procesaba en
	segundo plano — se vio con Drácula y Signo Amarillo resolviendo recién
	en la fase de Bloqueo, varios pasos después de jugarse.

	Los Talismanes se ramifican ANTES de todo esto (2026-08-28, a pedido
	del usuario): un Talismán nunca 'entra en juego' (DAR Sección 8, ver
	_play_talisman()), así que no pasan por CardFactory.on_card_enters_play()
	ni Card.on_entered_play() (ambos son bookkeeping de 'entró al campo' —
	Furia/summoning sickness, bind a la cola de triggers — que no aplica a
	un Talismán) ni emiten on_card_entered_play (evitaba que CardEffectSystem
	lo logueara como si hubiese entrado a Línea de Apoyo). Antes estos tres
	pasos corrían igual para Talismanes y dejaban logs falsos tipo 'entró en
	juego'/'entró a Línea de Apoyo' incluso jugándolo via Exhumar desde el
	Cementerio, donde nunca pisa una zona de juego real."""
	if card.get("card_type") == Constants.CardType.TALISMAN:
		_register_talisman_totem_tax(card)
		var origin: String = "Exhumar (Cementerio → Destierro)" if card.get("is_exhumed") == true else "mano"
		print("[GoldManager] %s resuelve su efecto (Talismán, jugado desde %s)" % [
			card.card_name if card.get("card_name") else "Carta", origin
		])
		# Un Talismán no dispara nada (DAR Sección 8): su texto ES el efecto
		# de jugarlo, se resuelve directo — no pasa por has_trigger() ni por
		# la cola compartida de TriggerSystem (2026-08-27, a pedido del
		# usuario: "los Talismanes no disparan, resuelven").
		await TriggerSystem.resolve_talisman(card)
		return

	CardFactory.on_card_enters_play(card)
	if card.has_method("on_entered_play"):
		card.on_entered_play()
	_register_talisman_totem_tax(card)
	EffectController.emit_signal("on_card_entered_play", 0, card, zone)

	await TriggerSystem._collect_triggers_for_event("on_enter_play", {
		"player_id": 0, "card": card, "zone": zone
	})


func _play_talisman(card: Node) -> void:
	"""Los Talismanes se resuelven al jugarse y no se quedan en el campo
	como un Aliado ni como un Tótem (DAR Sección 8): disparan su habilidad y
	van al Cementerio por defecto — al Destierro si su propio texto dice
	'destiérralo', o de vuelta al Mazo (barajado) si dice 'barájala'. Si fue
	jugado via Exhumar (card.is_exhumed), el Destierro manda siempre, sin
	importar lo que diga el propio texto (regla de Exhumar, DAR)."""
	TurnManager.on_card_played(card)
	_main._update_debug("Jugando talismán: %s" % card.card_name)

	var idx = _main.player_hand.cards.find(card)
	if idx >= 0:
		_main.player_hand.cards.remove_at(idx)
	# Ver GoldManager._play_card_to_field() — misma corrección (Exhumar: la
	# carta nunca estuvo en la mano).
	if card.get_parent() == _main.player_hand:
		_main.player_hand.remove_child(card)
		_main.player_hand._arrange_cards()
	card.can_interact = false
	_main.player_field.add_child(card)
	# Ver GoldManager._play_card_to_field() — misma corrección.
	card.top_level = false
	card.set_zone(Constants.Zone.LINEA_APOYO)
	await get_tree().create_timer(0.3).timeout

	# _trigger_enter_play() ya queda 'await'-eado hasta el final de verdad
	# (resolve_talisman() → _resolve_look_and_play_patterns(), toda la
	# cadena incluye cualquier elección anidada del jugador) — la espera
	# fija que había acá después ("dar tiempo a que la habilidad resuelva")
	# era pura demora sin motivo real, la carta quedaba pegada en Línea de
	# Apoyo un rato de más después de haber terminado (2026-08-30, a pedido
	# del usuario: los Talismanes deben irse al Cementerio apenas resuelven,
	# no quedarse dando vueltas).
	await _trigger_enter_play(card, Constants.Zone.LINEA_APOYO)

	var habilidad: String = card.card_ability.to_lower() if card.get("card_ability") else ""
	var self_exile := "destierr" in habilidad    # cubre "destiérralo", "destierra esta carta", etc.
	# "barájala"/"barajala" (2026-08-30, antes bastaba "baraj" sin más —
	# falso positivo real con Aaru: su texto dice 'Baraja cualquier cantidad
	# de cartas de tu MANO', un efecto sobre OTRAS cartas, no sobre sí
	# mismo, y el check viejo lo mandaba de vuelta al mazo en lugar de al
	# Cementerio). El pronombre reflejo "-la" es lo que de verdad distingue
	# 'esta carta se baraja a sí misma' de cualquier otro uso del verbo.
	var self_shuffle := "barájala" in habilidad or "barajala" in habilidad

	# card.owner_id, no 0 fijo (2026-08-29): esta función asumía siempre
	# Talismanes propios (jugados de la mano del jugador humano, owner_id=0
	# de por sí), pero con Miguel ('juega una carta de... un Cementerio')
	# ahora puede ser un Talismán del RIVAL jugado desde SU Cementerio —
	# owner_id sigue siendo suyo (el que controla el efecto es otra cosa,
	# ver controller_id), así que debe volver a SU Cementerio/Destierro, no
	# al del jugador que lo jugó.
	var true_owner: int = card.owner_id if card.get("owner_id") != null else 0

	if card.get("is_exhumed") == true:
		# Exhumar manda siempre al Destierro, sin importar el propio texto
		# de la carta (ni "barájala" ni el Cementerio por defecto aplican).
		await EffectController.exile_card(true_owner, card)
	elif self_shuffle:
		ActionModule.return_to_deck(card, true_owner, false)
		ActionModule.shuffle_deck(true_owner)
	else:
		# self_exile respeta el texto propio de la carta tal cual, sea cual
		# sea el camino por el que se jugó (2026-08-29, corregido a pedido
		# del usuario): "no tengan condición de juego que te obligue a
		# mandarlas al destierro" — si SÍ la tiene (dice "destiérralo"), se
		# destierra igual jugada desde el Cementerio o no. La única regla
		# que fuerza Destierro PASE LO QUE DIGA el texto es Exhumar de
		# verdad (is_exhumed, arriba) — jugar desde el Cementerio por otro
		# efecto (Miguel) no agrega ninguna regla nueva acá, cae en el
		# comportamiento normal de siempre.
		if self_exile:
			await EffectController.exile_card(true_owner, card)
		else:
			await EffectController.destroy_card(true_owner, card)

	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)


func _update_gold_display() -> void:
	var available = 0
	var valid_cards: Array = []
	for card in _main.gold_cards:
		if not is_instance_valid(card):
			continue
		valid_cards.append(card)
		if card.modulate == Color(1, 1, 1, 1):
			available += 1
	_main.gold_cards = valid_cards

	update_gold_containers_spacing()

	if _main._card_inspector:
		_main._card_inspector.refresh_activatable_glows()


func update_gold_containers_spacing() -> void:
	"""Calcula y ajusta la separación dinámica de las cartas de oro en Reserva
	y Oro Pagado para ambos jugadores, evitando que se superpongan en exceso.

	Reconstruida (2026-09-02, parse error reportado por el usuario): el
	cuerpo de esta función y el de puede_pagar() (más abajo) aparecieron
	truncados a la mitad — un 'if' sin bloque indentado y un 'return' de
	puede_pagar() pegado como si fuera parte de este 'if', con
	_update_container_gold_spacing(_main.player_gold) directamente
	desaparecido. No hay forma de recuperar los valores originales del
	cálculo de separación (la función que llaman, _update_container_gold_
	spacing(), tampoco existía en ningún lado del archivo), así que su
	implementación de más abajo es una reconstrucción conservadora nueva —
	revisala si la separación visual no queda como esperabas."""
	if not _main:
		return
	if _main.player_gold:
		_update_container_gold_spacing(_main.player_gold)
	if _main.player_oro_pagado:
		_update_container_gold_spacing(_main.player_oro_pagado)
	if _main.opponent_gold:
		_update_container_gold_spacing(_main.opponent_gold)
	if _main.opponent_oro_pagado:
		_update_container_gold_spacing(_main.opponent_oro_pagado)


func _update_container_gold_spacing(container: HBoxContainer) -> void:
	"""Comprime progresivamente la separación entre cartas de Oro a medida que se acumulan,
	garantizando que siempre quepan dentro del área de oros (340px) sin invadir el campo."""
	if not container or not is_instance_valid(container):
		return
	var count: int = container.get_child_count()
	if count <= 1:
		container.add_theme_constant_override("separation", 6)
		container.queue_sort()
		return

	var max_width: float = 340.0
	var card_width: float = 150.0 * Constants.GOLD_CARD_SCALE.x
	var ideal_sep: float = (max_width - float(count) * card_width) / float(count - 1)
	var final_sep: int = int(clampf(ideal_sep, -125.0, 6.0))
	container.add_theme_constant_override("separation", final_sep)
	container.queue_sort()


func puede_pagar(cantidad: int, card_type: int = -1, card_race: String = "", card_cost: int = -1) -> bool:
	var oro_fisico = GameState.get_oro_reserva(0)
	var restringido = _restricted_gold_available_for(card_type, card_race, card_cost)
	var disponible = oros_virtuales + restringido + oro_fisico
	return disponible >= cantidad


func pagar_coste(cantidad: int, card_type: int = -1, card_race: String = "", card_cost: int = -1) -> bool:
	"""card_type/card_race/card_cost identifican QUÉ se está pagando — sin
	esto no hay forma de saber si el Oro Virtual restringido aplica (p.ej.
	Padre de la Patria: 'para jugar Armas o Aliados Caballero' — usa
	card_type/card_race). Pasar -1/"" cuando no corresponda (p.ej. una
	habilidad activada sin carta objetivo) para que el pago ignore los pools
	restringidos de forma segura."""
	if not puede_pagar(cantidad, card_type, card_race, card_cost):
		# player_gold.get_child_count() incluye los tokens visuales de Oro
		# Virtual (genérico + restringido) — se restan para no contarlos dos
		# veces en el mensaje.
		var restricted_token_count := 0
		for pool in restricted_gold_pools:
			restricted_token_count += pool.tokens.size()
		var oro_fisico_visible = _main.player_gold.get_child_count() - virtual_gold_tokens.size() - restricted_token_count
		var restringido_disp = _restricted_gold_available_for(card_type, card_race, card_cost)
		var disponible = oros_virtuales + restringido_disp + oro_fisico_visible
		_main._update_debug("Oro insuficiente: necesitas %d, tienes %d (V:%d + R:%d + F:%d)" % [
			cantidad, disponible, oros_virtuales, restringido_disp, oro_fisico_visible])
		return false
	if cantidad <= 0:
		return true
	var restante = cantidad

	# 1. Oro Virtual RESTRINGIDO primero — es el más específico: si no se usa
	# ahora que sí aplica, se pierde igual al pasar de turno, mientras que el
	# genérico y el físico se pueden guardar para otra compra.
	if restante > 0:
		var restr_usados = await _consume_restricted_gold_for(card_type, card_race, card_cost, restante)
		if restr_usados > 0:
			restante -= restr_usados
			_main._update_debug("Consumido %d Oro Virtual restringido (quedan %d por pagar)" % [restr_usados, restante])

	if restante > 0 and oros_virtuales > 0:
		var virtuales_usados = mini(oros_virtuales, restante)
		oros_virtuales -= virtuales_usados
		restante -= virtuales_usados
		for i in range(virtuales_usados):
			await _despawn_virtual_gold_token()
		_main._update_debug("Consumido %d Oro Virtual (quedan %d)" % [virtuales_usados, oros_virtuales])
	if restante > 0:
		_main._update_debug("Pagando %d Oro físico..." % restante)
		var oros_reserva = _main.player_gold.get_children()
		# diverted cuenta las unidades que NO terminaron en Oro Pagado de
		# verdad (2026-08-29, p.ej. Jormundgander: '...convierte este Oro en
		# un Aliado y muévelo a tu Línea de Defensa' en vez del movimiento
		# normal) — GameState.pagar_oro() de abajo suma 'restante' completo
		# a oro_pagado sin saber esto, así que hay que restar la diferencia
		# después o el próximo Reagrupamiento regala Oro de más que nunca
		# existió físicamente en la pila.
		var diverted := 0
		for i in range(restante):
			if i >= oros_reserva.size():
				break
			var was_diverted: bool = await _mover_oro_a_pagado(oros_reserva[i])
			if was_diverted:
				diverted += 1
		GameState.pagar_oro(0, restante)
		if diverted > 0:
			GameState.agregar_oro_pagado(0, -diverted)
	TurnManager.any_card_played_this_turn = true
	var oro_restante = GameState.get_oro_reserva(0)
	_main._update_debug("Pagado %d Oro total (Reserva: %d, Virtual: %d)" % [cantidad, oro_restante, oros_virtuales])
	_update_gold_display()
	return true


func generar_oros_virtuales(cantidad: int) -> void:
	oros_virtuales += cantidad
	for i in range(cantidad):
		_spawn_gold_token("Oro Virtual", Color(1.0, 0.85, 0.3, 0.85), virtual_gold_tokens)
	_main._update_debug("Generado %d Oro Virtual (total: %d)" % [cantidad, oros_virtuales])
	_update_gold_display()


func limpiar_oros_virtuales() -> void:
	if oros_virtuales > 0:
		_main._update_debug("Oros Virtuales expirados: %d" % oros_virtuales)
		oros_virtuales = 0
		for token in virtual_gold_tokens.duplicate():
			if is_instance_valid(token):
				token.queue_free()
		virtual_gold_tokens.clear()
		_update_gold_display()


func generar_oro_virtual_restringido(cantidad: int, predicate: Callable, label: String) -> void:
	"""Oro Virtual que SOLO paga cartas que cumplan 'predicate(card_type,
	card_race) -> bool' (p.ej. Padre de la Patria: 'para jugar Armas o
	Aliados Caballero'). A diferencia de generar_oros_virtuales(), queda
	guardado en restricted_gold_pools como su propia entrada — varias
	fuentes con distintas restricciones pueden coexistir sin mezclarse."""
	var tokens: Array = []
	for i in range(cantidad):
		_spawn_gold_token("Oro Virtual (%s)" % label, Color(0.45, 0.75, 1.0, 0.85), tokens)
	restricted_gold_pools.append({"amount": cantidad, "tokens": tokens, "predicate": predicate, "label": label})
	_main._update_debug("Generado %d Oro Virtual restringido (%s)" % [cantidad, label])
	_update_gold_display()


func limpiar_oro_restringido() -> void:
	if restricted_gold_pools.is_empty():
		return
	for pool in restricted_gold_pools:
		for token in pool.tokens:
			if is_instance_valid(token):
				token.queue_free()
	_main._update_debug("Oro Virtual restringido expirado (%d pool(s))" % restricted_gold_pools.size())
	restricted_gold_pools.clear()
	_update_gold_display()


func _restricted_gold_available_for(card_type: int, card_race: String, card_cost: int = -1) -> int:
	if card_type < 0:
		return 0
	var total := 0
	for pool in restricted_gold_pools:
		if pool.predicate.call(card_type, card_race, card_cost):
			total += pool.amount
	return total


func _consume_restricted_gold_for(card_type: int, card_race: String, card_cost: int, needed: int) -> int:
	if card_type < 0 or needed <= 0 or restricted_gold_pools.is_empty():
		return 0
	var consumed := 0
	var empty_indices: Array = []
	for i in range(restricted_gold_pools.size()):
		if consumed >= needed:
			break
		var pool: Dictionary = restricted_gold_pools[i]
		if not pool.predicate.call(card_type, card_race, card_cost):
			continue
		var usa: int = mini(pool.amount, needed - consumed)
		pool.amount -= usa
		consumed += usa
		for j in range(usa):
			await _despawn_gold_token(pool.tokens)
		if pool.amount <= 0:
			empty_indices.append(i)
	for i in range(empty_indices.size() - 1, -1, -1):
		restricted_gold_pools.remove_at(empty_indices[i])
	return consumed


func _spawn_gold_token(nombre: String, color: Color, target_list: Array) -> void:
	"""Token visual en Reserva de Oro — puramente cosmético: no toca
	GameState ni el conteo real de Reserva (get_oro_disponible() sigue
	leyendo GameState, no la cantidad de nodos), así que no puede
	desincronizar el pago. 'color' distingue de un vistazo Oro Virtual
	genérico (Lobo Sagrado) de uno restringido (p.ej. Padre de la Patria)."""
	var token_data := {
		"id": "%s_token_%d" % [nombre.to_lower().replace(" ", "_"), Time.get_ticks_usec()],
		"nombre": nombre,
		"tipo": Constants.CardType.ORO,
		"coste": 0,
		"fuerza": 0,
		"habilidad": "",
		"raza": "",
		"imagen": "/dorso_default.webp",
		"keywords": []
	}
	var token: Node = _main._create_card(token_data)
	token.can_interact = false
	token.modulate = color
	token.scale = Constants.GOLD_CARD_SCALE
	token.base_scale = Constants.GOLD_CARD_SCALE
	token.set_zone(Constants.Zone.RESERVA_ORO)
	_main.player_gold.add_child(token)
	target_list.append(token)


func _despawn_virtual_gold_token() -> void:
	await _despawn_gold_token(virtual_gold_tokens)


func _despawn_gold_token(target_list: Array) -> void:
	"""Retira un token — llamado en el mismo momento en que pagar_coste()
	descuenta una unidad de Oro Virtual (genérico o restringido), para que
	la Reserva nunca muestre más del que realmente queda disponible.
	pagar_coste() hace 'await' de esta función ANTES de leer
	player_gold.get_children() para el Oro físico, así que el remove_child
	de acá abajo (aunque va después del fade) siempre termina antes de que
	ese loop se ejecute."""
	if target_list.is_empty():
		return
	var token: Node = target_list.pop_back()
	if not is_instance_valid(token):
		return
	var tween = create_tween()
	tween.tween_property(token, "modulate:a", 0.0, 0.15)
	await tween.finished
	if is_instance_valid(token):
		if token.get_parent() == _main.player_gold:
			_main.player_gold.remove_child(token)
		token.queue_free()


func _mover_oro_a_pagado(card: Node) -> bool:
	"""Returns: true si la carta se DESVIÓ del movimiento normal (2026-08-29,
	Jormundgander: revert_to_data marcado por convert_ally_to_gold_in_pagado()
	— en vez de ir a Oro Pagado, vuelve a ser el Aliado original), false si
	se movió a Oro Pagado normalmente. El llamador (pagar_coste()) usa el
	valor de retorno para no contar de más en GameState.oro_pagado."""
	if card.get("revert_to_data") != null and not (card.revert_to_data as Dictionary).is_empty():
		await _revert_gold_to_ally(card)
		return true
	# controller_id, no siempre 'player' (2026-08-31, Tyet: 'Puedes pagar
	# este Oro para que un Oro pierda su habilidad este turno y muévelo al
	# Oro Pagado' — el texto real no dice 'de tu Reserva' ni 'tuyo', así que
	# el Oro elegido puede ser del rival; antes esta función asumía siempre
	# _main.player_gold/player_oro_pagado y tronaba (remove_child sobre el
	# padre equivocado) apenas se probaba con un Oro rival).
	var controller_id: int = card.controller_id if card.get("controller_id") != null else 0
	var reserva_container: HBoxContainer = _main.player_gold if controller_id == 0 else _main.opponent_gold
	var pagado_container: HBoxContainer = _main.player_oro_pagado if controller_id == 0 else _main.opponent_oro_pagado
	var start_pos = card.global_position
	reserva_container.remove_child(card)
	card.can_interact = false
	pagado_container.add_child(card)
	update_gold_containers_spacing()
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.parallel().tween_property(card, "modulate", Color(0.6, 0.6, 0.6, 1.0), 0.25)
	await tween.finished
	card.can_interact = true
	return false


func _revert_gold_to_ally(card: Node) -> void:
	"""'Si esta carta es un Oro, cuando lo pagues para jugar un Aliado,
	convierte este Oro en un Aliado y muévelo a tu Línea de Defensa'
	(Jormundgander, 2026-08-29) — la otra mitad de convert_ally_to_gold_in_
	pagado(): en vez de terminar en Oro Pagado como cualquier Oro gastado,
	esta carta específica vuelve a ser el Aliado original y entra en juego
	de nuevo."""
	var original_data: Dictionary = card.revert_to_data.duplicate()
	card.revert_to_data = {}
	var start_pos = card.global_position
	_main.player_gold.remove_child(card)
	card.can_interact = false
	card.load_from_data(original_data)
	_main.player_field.add_child(card)
	card.top_level = false
	card.set_zone(Constants.Zone.LINEA_DEFENSA)
	card.scale = Vector2.ONE
	card.base_scale = Vector2.ONE
	await get_tree().process_frame
	# Slot fijo (2026-08-31) — ver ZoneManager.pin_card_to_field_slot() y el
	# mismo motivo en GoldManager._play_card_to_field().
	var end_pos: Vector2 = _main._zone_manager.pin_card_to_field_slot(card, _main.player_field)
	card.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.parallel().tween_property(card, "modulate", Color(1, 1, 1, 1), 0.3)
	await tween.finished
	card.can_interact = true
	if card.has_method("play_enter_animation"):
		card.play_enter_animation()
	_update_gold_display()
	await _trigger_enter_play(card, Constants.Zone.LINEA_DEFENSA)


func convert_ally_to_gold_in_pagado(card: Node) -> void:
	"""'Cuando haga daño, puedes convertirlo en un Oro y moverlo a tu Oro
	Pagado' (Jormundgander, 2026-08-29) — transforma un Aliado en juego en
	un Oro y lo mueve directo a Oro Pagado (ya 'gastado' hasta el próximo
	Reagrupamiento, no disponible para pagar nada este turno). Guarda los
	datos originales en card.revert_to_data — _mover_oro_a_pagado() los usa
	para reconvertir el Oro en Aliado si de verdad se lo paga más adelante
	(la otra mitad del texto de esta misma carta)."""
	if not is_instance_valid(card):
		return
	var owner_id: int = card.owner_id if card.get("owner_id") != null else 0
	if owner_id != 0:
		return  # Sin soporte de conversión para el oponente todavía

	card.revert_to_data = card.card_data.duplicate()

	var start_pos = card.global_position
	var parent = card.get_parent()
	if parent:
		parent.remove_child(card)
	card.can_interact = false

	# Re-tipar como Oro: card_data y las propiedades derivadas que el resto
	# del motor lee (PaymentManager.calcular_coste_real, filtros de
	# búsqueda/selección, etc.) leen card_type/card_cost, no re-parsean el
	# texto de la carta.
	var new_data: Dictionary = card.card_data.duplicate()
	new_data["tipo"] = Constants.CardType.ORO
	card.load_from_data(new_data)

	_main.player_oro_pagado.add_child(card)
	card.top_level = false
	card.set_zone(Constants.Zone.ORO_PAGADO)
	card.scale = Constants.GOLD_CARD_SCALE
	card.base_scale = Constants.GOLD_CARD_SCALE
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.parallel().tween_property(card, "modulate", Color(0.6, 0.6, 0.6, 1.0), 0.3)
	await tween.finished
	card.can_interact = true
	GameState.agregar_oro_pagado(0, 1)
	_main.gold_cards.append(card)
	_update_gold_display()


func _mover_oro_a_reserva(card: Node) -> void:
	var start_pos = card.global_position
	_main.player_oro_pagado.remove_child(card)
	card.can_interact = false
	_main.player_gold.add_child(card)
	update_gold_containers_spacing()
	await get_tree().process_frame
	var end_pos = card.global_position
	card.global_position = start_pos
	var tween = create_tween()
	tween.tween_property(card, "global_position", end_pos, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.parallel().tween_property(card, "modulate", Color(1, 1, 1, 1), 0.25)
	await tween.finished
	card.can_interact = true


func _reset_gold() -> void:
	"""Reagrupamiento del Oro (DAR, Agrupación): todo el Oro Pagado propio
	vuelve a la Reserva al empezar el turno. Llamada desde PhaseFlowController
	en el caso AGRUPACION, pero no existía en ningún lado de este archivo
	(2026-09-02, mismo tipo de corrupción ya encontrado y arreglado en
	update_gold_containers_spacing()/puede_pagar()/_revert_gold_to_ally()/
	get_oro_disponible() — funciones llamadas sin definición). GameState.
	reagrupar_oro() ya existe y resetea los contadores reales; acá se
	mueven las cartas VISUALES de vuelta una por una con
	_mover_oro_a_reserva(), que ya existe pero no toca GameState (por eso
	el orden: contadores primero, visual después)."""
	GameState.reagrupar_oro(0)
	if _main.player_oro_pagado:
		for card in _main.player_oro_pagado.get_children().duplicate():
			if is_instance_valid(card):
				await _mover_oro_a_reserva(card)
	_update_gold_display()


func get_oro_disponible() -> int:
	return GameState.get_oro_reserva(0)


func get_oro_pagado() -> int:
	return GameState.get_oro_pagado(0)


func get_oro_total() -> int:
	return GameState.get_oro_total(0)
