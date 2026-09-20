extends Node
class_name GoldManager
## GoldManager — Sistema de pago de costes y gestión de Oro (DAR Secciones 6 y 8).
## Se instancia como hijo de Main en _ready(). Accede a nodos de Main via _main.
##
## Tokens visuales de Oro (conteo disponible, separación entre cartas,
## recorte de click, creación/despawn de tokens de Oro Virtual) extraídos a
## GoldManagerVisuals.gd (2026-09-06, "módulos gordos", Fase 2). Impuestos de
## coste de Talismanes/Tótems/Oro y descuento de coste por "muestra X"
## extraídos a GoldManagerTax.gd, y elegibilidad para jugar una carta
## (Errante, límite de juego por nombre, Talismanes de respuesta instantánea,
## portadores de Arma, excepciones de fase) a GoldManagerRestrictions.gd
## (ambos 2026-09-06, "módulos gordos", Fase 3) — las funciones de abajo
## marcadas como forwarder de una sola línea son esos splits; el resto de
## este archivo sigue sin tocar.

const GoldManagerVisualsScript = preload("res://scripts/core/game/GoldManagerVisuals.gd")
const GoldManagerTaxScript = preload("res://scripts/core/game/GoldManagerTax.gd")
const GoldManagerRestrictionsScript = preload("res://scripts/core/game/GoldManagerRestrictions.gd")

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

## 'Los jugadores no pueden poner Oros en juego por efectos si ya
## pusieron Oros en juego por efectos durante esta partida' (2026-09-04,
## Armería del Guerrero) — a diferencia de oro_colocado_conteo (por
## turno), esto dura TODA LA PARTIDA: no se toca en _reset_gold() ni en
## ningún reset por turno, cada jugador tiene como máximo UNA vez en toda
## la partida (no se resetea nunca hasta la próxima partida nueva).
var _oro_por_efecto_used_game: Dictionary = {0: false, 1: false}

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

var _visuals: RefCounted = null
var _tax: RefCounted = null
var _restrictions: RefCounted = null

func setup(main: Node) -> void:
	_main = main
	_visuals = GoldManagerVisualsScript.new()
	_visuals.setup(main)
	_tax = GoldManagerTaxScript.new()
	_tax.setup(main)
	_restrictions = GoldManagerRestrictionsScript.new()
	_restrictions.setup(main)
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
	# 'Entra en juego como una copia de un Oro que controle tu oponente'
	# (Corazón de Dragón, 2026-09-06, a pedido del usuario: es una CONDICIÓN
	# DE JUEGO, no algo a lo que responder — se resuelve acá, ANTES del ETB
	# genérico de abajo, con el jugador eligiendo a qué Oro rival apuntar.
	# Como load_from_data() reemplaza nombre/habilidad/keywords de verdad
	# antes de que _trigger_enter_play() lea card_ability, si el Oro copiado
	# tiene su propio 'Cuando entra en juego' (p.ej. Drácula: 'Roba dos
	# cartas'), ese ETB SÍ dispara con normalidad, como pidió el usuario).
	if _is_become_opponent_gold_copy_text(card):
		await _resolve_become_opponent_gold_copy(card)
	# Los Oros también pueden tener habilidades "Al entrar" (p.ej. Signo
	# Amarillo: "mira 4 cartas del tope") — este camino nunca las disparaba,
	# a diferencia de _play_card_to_field()/_play_talisman() que sí lo hacen.
	await _trigger_enter_play(card, Constants.Zone.RESERVA_ORO)


func _is_become_opponent_gold_copy_text(card: Node) -> bool:
	var habilidad: String = str(card.get("card_ability")) if card.get("card_ability") != null else ""
	return "entra en juego como una copia de un oro que controle tu oponente" in habilidad.to_lower()


func _resolve_become_opponent_gold_copy(card: Node) -> void:
	"""Convierte 'card' (Corazón de Dragón, ya colocado en su Reserva) en una
	copia completa (nombre, habilidad, keywords, fuerza, imagen — todo lo
	que load_from_data() carga) de un Oro elegido en la Reserva rival.
	instance_id sigue siendo el propio de 'card' (Card.gd no lo toca), así
	que ninguna referencia externa (contenedor, señales ya conectadas) se
	rompe — solo cambia QUÉ carta representa visualmente y funcionalmente."""
	if not _main.opponent_gold or not _main._card_interaction:
		return
	var candidates: Array = []
	for c in _main.opponent_gold.get_children():
		if is_instance_valid(c) and c != card:
			candidates.append(c)
	if candidates.is_empty():
		_main._update_debug("No hay ningún Oro rival para copiar — %s se queda sin habilidad" % card.card_name)
		return
	var filter := func(c: Node) -> bool:
		return c in candidates
	var target: Node = await _main._card_interaction.await_target("Elige un Oro rival para copiar", filter)
	if not target or not is_instance_valid(target):
		return
	var copied_data: Dictionary = target.card_data.duplicate(true)
	card.load_from_data(copied_data, false)
	_main._update_debug("%s entra en juego como copia de %s" % [card.card_name, target.card_name])


func _has_card_named_in_play(name_lower: String) -> bool:
	"""Busca por nombre (insensible a mayúsculas) entre todas las zonas de
	campo/Oro de ambos jugadores — usado para restricciones 'mientras X
	esté en juego' que dependen de si una carta puntual está presente, no
	de un modificador registrado (2026-09-04, Armería del Guerrero)."""
	for field in [_main.player_field, _main.opponent_field, _main.player_linea_ataque, _main.opponent_linea_ataque,
			_main.player_linea_apoyo, _main.opponent_linea_apoyo,
			_main.player_gold, _main.opponent_gold, _main.player_oro_pagado, _main.opponent_oro_pagado]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and str(c.get("card_name")).to_lower() == name_lower:
				return true
	return false


func _register_armeria_opponent_turn_trigger(card: Node) -> void:
	"""'Al comienzo del turno oponente, Baraja y/o Destierra hasta dos
	cartas de los Cementerios' (2026-09-04, Armería del Guerrero) — el Oro
	Inicial nunca pasa por _trigger_enter_play() (GameBootstrap._setup_
	oro_inicial() lo coloca aparte), así que este trigger se conecta acá
	directo en vez del molde estándar de triggers de fase (resolve_
	agrupacion_triggers()/resolve_vigilia_triggers(), pensados para cartas
	que SÍ entran en juego normalmente). 'Al comienzo del turno oponente' =
	el turno de CUALQUIERA que no sea el dueño de esta carta — se reevalúa
	en cada turn_started, no una sola vez al registrar."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	if not ("al comienzo del turno oponente" in ability_text.to_lower()):
		return
	var handler: Callable
	handler = func(new_active_player: int, _turn: int) -> void:
		if not is_instance_valid(card) or not card.is_in_play():
			if GameManager.turn_started.is_connected(handler):
				GameManager.turn_started.disconnect(handler)
			return
		var owner: int = card.owner_id if card.get("owner_id") != null else 0
		if new_active_player == owner:
			return  # es el turno DE ella, no el del oponente
		if owner != 0:
			return  # el bot todavía no resuelve esta elección interactiva
		await _resolve_armeria_barajar_desterrar()
	GameManager.turn_started.connect(handler)


func _resolve_armeria_barajar_desterrar(max_amount: int = 2, title: String = "Armería del Guerrero") -> void:
	"""Elige hasta 'max_amount' cartas de los Cementerios (de cualquiera de
	los dos jugadores, sin zona explícita = en juego, ver
	[[project_no_zone_means_in_play]]) y, para cada una, Barajarla (vuelve
	a su Castillo, barajado) o Desterrarla — elección independiente por
	carta. Genérica desde 2026-09-04 (antes hardcodeada a 2/Armería del
	Guerrero) — reusada por Belta ('hasta dos') y cualquier otra carta con
	el mismo patrón exacto de texto, solo cambia la cantidad."""
	var candidates: Array = []
	for owner_id in [0, 1]:
		for d in CardManager.get_cemetery(owner_id):
			candidates.append({"data": d, "owner": owner_id})
	if candidates.is_empty():
		return
	var display_data: Array = []
	for c in candidates:
		display_data.append(c.data)
	var result: Dictionary = await SelectionManager.await_multi_pick(
		display_data, "%s — elige hasta %d carta(s) de los Cementerios" % [title, max_amount], max_amount, 0, true)
	for picked_data in result.picked:
		var owner_of_picked: int = 0
		for c in candidates:
			if c.data == picked_data:
				owner_of_picked = c.owner
				break
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		var shuffle_it: bool = await SelectionManager.await_two_choice(
			_main, "¿Qué hacer con esa carta?", "Barajarla (vuelve a su Castillo)", "Desterrarla")
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		if shuffle_it:
			CardManager.get_deck(owner_of_picked).append(picked_data)
			CardManager.shuffle_deck(owner_of_picked)
		else:
			CardManager.add_to_exile(owner_of_picked, picked_data)


func put_gold_directly_in_reserva(player_id: int, card_data: Dictionary) -> Node:
	"""Pone un Oro directo en la Reserva de un jugador, sin pasar por la
	mano ni pagar coste — sale de una búsqueda ('busca un Oro en tu
	Castillo y ponlo en tu Reserva', 2026-08-29, p.ej. Don de Amma), no de
	jugarlo. Mismo patrón visual que el Oro Inicial de GameBootstrap.gd
	(único otro lugar que coloca Oro en Reserva sin pasar por
	_place_card_as_gold, que exige que la carta ya sea un Node hijo de
	player_hand).

	'Los jugadores no pueden poner Oros en juego por efectos si ya
	pusieron Oros en juego por efectos durante esta partida' (2026-09-04,
	Armería del Guerrero) — este es EL choke point real de 'poner un Oro
	en juego por efectos' (a diferencia de _place_card_as_gold(), que es
	la acción normal de la mano, DAR distinto verbo). Por jugador, toda la
	partida, solo se chequea/aplica si hay una Armería del Guerrero en
	juego (de cualquiera de los dos lados — el texto dice 'los jugadores',
	no 'tu oponente')."""
	if _has_card_named_in_play("armería del guerrero") and _oro_por_efecto_used_game.get(player_id, false):
		_main._update_debug("Ya pusiste un Oro en juego por efectos esta partida (Armería del Guerrero)")
		return null
	_oro_por_efecto_used_game[player_id] = true

	var card_node = _main._create_card(card_data, false)  # Oro es información pública (DAR), boca arriba siempre
	card_node.owner_id = player_id
	card_node.can_interact = true
	card_node.scale = Constants.GOLD_CARD_SCALE
	card_node.base_scale = Constants.GOLD_CARD_SCALE
	_main._connect_card_signals(card_node)
	var target_container: HBoxContainer = _main.player_gold if player_id == 0 else _main.opponent_gold
	target_container.add_child(card_node)
	card_node.set_zone(Constants.Zone.RESERVA_ORO)
	card_node._refresh_disabled_rotation()
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
	# Talismanes de velocidad instantánea (Anula/Cancela, p.ej. Red de Plata,
	# Sacrificio Solar — ver _is_response_only_talisman()) son "de respuesta"
	# en el sentido de DAR: se juegan EN CUALQUIER MOMENTO en el que el
	# jugador tenga la palabra, no solo en Vigilia o con una ventana de
	# prioridad puntual abierta (2026-09-06, implementa lo que el comentario
	# de más abajo venía dejando pendiente desde 2026-08-25/28). Alcance
	# acordado (igual que TargetedEffectExecutor._execute_targeted_annul()):
	# no hay pila/interrupción real de la acción del oponente — el motor no
	# tiene un oponente que juegue cartas por su cuenta todavía (ver
	# comentarios "el bot no actúa de forma independiente" repartidos por
	# el proyecto) — así que "instantáneo" acá significa "juega esto cuando
	# quieras mientras sea tu turno", resolviendo sobre algo que YA está en
	# juego (su objetivo), no sobre una acción a medio resolver.
	var is_instant_response: bool = card.card_type == Constants.CardType.TALISMAN and _is_response_only_talisman(card)

	if GameManager.current_phase != Constants.Phase.VIGILIA and not phase_exception and not is_instant_response:
		_main._update_debug(get_phase_rejection_reason(card.card_type))
		await _return_card_rejected(card)
		return false
	if GameManager.active_player_id != 0:
		_main._update_debug("No es tu turno")
		await _return_card_rejected(card)
		return false
	# Si hay una ventana de prioridad abierta (respuesta a un trigger que se
	# acaba de disparar, p.ej. 'cuando entre en juego' de la carta anterior),
	# no dejar jugar otra carta todavía — el trigger pendiente quedaba
	# pospuesto y se resolvía recién cuando pasaba OTRA acción, en el
	# momento equivocado. Hay que resolver esa ventana primero (¿Paso?).
	# Los Talismanes instantáneos SÍ pueden jugarse con la ventana abierta —
	# es justo el caso de uso real (responder a lo que la disparó).
	if PriorityManager.priority_window_active and not phase_exception and not is_instant_response:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de jugar otra carta")
		await _return_card_rejected(card)
		return false
	if _no_more_cards_violation(card):
		_main._update_debug("No puedes jugar más cartas este turno")
		await _return_card_rejected(card)
		return false
	if _card_play_locked(card):
		_main._update_debug("%s no puede jugarse todavía" % card.card_name)
		await _return_card_rejected(card)
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
	# Talismanes de respuesta (Anula/Cancela) ya NO se bloquean acá sin más
	# (2026-09-06, implementado): is_instant_response arriba ya los dejó
	# pasar las dos ventanas normales de fase/prioridad — de acá para abajo
	# siguen el mismo camino genérico que cualquier Talismán (coste, target,
	# _play_talisman()). Si su objetivo (Anular un Aliado/Tótem, Cancelar
	# una habilidad) no existe en la mesa, el propio selector de objetivo
	# (_execute_targeted_annul()/equivalente) se cancela solo con ESC — no
	# hace falta precalcular "hay objetivo válido" acá.
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


func play_card_from_exile(card_data: Dictionary, discount: int = 0) -> bool:
	"""Juega una carta directamente desde el Destierro propio, pagando su
	coste real, como si estuviera en la mano (2026-09-04, a pedido del
	usuario — p.ej. uriel: 'Puedes jugarlo de tu Destierro pagando su
	coste'; batallon de ovejas: 'Si tienes cuatro cartas o menos en tu
	mano, puedes jugarlo desde tu Destierro'; cruzar el bosque: 'Puedes
	jugar esta carta desde tu Destierro'). Espejo casi exacto de
	play_card_from_cemetery(), con el Destierro como origen en vez del
	Cementerio — a diferencia de Exhumar, NO se marca is_exhumed (jugar
	desde el Destierro no es un castigo recurrente: si esta carta vuelve a
	salir del juego después, va al Cementerio normalmente, salvo que su
	propio texto diga otra cosa — no hay ningún caso así todavía).
	discount (2026-09-04, p.ej. rafael: 'reduciendo su coste en un Oro') —
	descuento fijo aplicado ANTES de calcular coste_real, piso 1 (no dice
	'hasta un mínimo de 0')."""
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
	var card = _main._create_card(card_data, false)
	card.owner_id = 0
	_main._connect_card_signals(card)

	if discount > 0:
		var applies_to_this_card := func(c: Node) -> bool:
			return c == card
		PaymentManager.agregar_modificador_coste(card, -discount, applies_to_this_card, false)

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

	var exile: Array = CardManager.get_exile(0)
	var idx: int = exile.find(card_data)
	if idx < 0:
		card.queue_free()
		return false
	exile.remove_at(idx)

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
	# tipo Lobo Sagrado + Talismanes en general en Guerra de Talismanes, y
	# Talismanes de respuesta instantánea — Exhumar uno también cuenta como
	# jugarlo, 2026-09-06).
	var phase_exception: bool = has_phase_exception(card_data.get("tipo", -1))
	var is_instant_response: bool = card_data.get("tipo", -1) == Constants.CardType.TALISMAN \
		and _is_response_only_talisman_data(card_data)

	if GameManager.current_phase != Constants.Phase.VIGILIA and not phase_exception and not is_instant_response:
		_main._update_debug(get_phase_rejection_reason(card_data.get("tipo", -1)))
		return false
	if GameManager.active_player_id != 0:
		_main._update_debug("No es tu turno")
		return false
	if PriorityManager.priority_window_active and not phase_exception and not is_instant_response:
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
	"""Abre selección de objetivo para elegir qué Aliado porta el Arma que
	se está jugando — propio O rival (2026-09-03, corregido a pedido del
	usuario: DAR no restringe el portador a Aliados que controlas). Un
	Arma no puede ir suelta, y un Aliado solo porta una a la vez (o más,
	con 'Arma adicional' en juego)."""
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
		_main._update_debug("No hay ningún Aliado libre en juego para portar el Arma")
		return null
	var filter := func(c: Node) -> bool:
		return c in _get_eligible_weapon_wielders()
	return await _main._card_interaction.await_target("Elige qué Aliado porta el Arma (propio o rival)", filter)


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

	# "El portador gana Furia y 1 de Fuerza por cada Oro que controles"
	# (2026-09-04, skofnung) — bono DINÁMICO (no un número fijo), value
	# como Callable recontado en cada consulta (_calculate_modifier_value()
	# ya lo soporta, mismo mecanismo que Manuel Bulnes/shedo titan).
	var dynamic_rx := RegEx.new()
	dynamic_rx.compile("(?i)el portador gana furia y (\\d+) de fuerza por cada oro que controles")
	var dynamic_m := dynamic_rx.search(ability_text)
	if dynamic_m:
		var per_oro: int = int(dynamic_m.get_string(1))
		var wielder_controller: int = ally.controller_id if ally.get("controller_id") != null else 0
		ContinuousEffectManager.register_modifier({
			"source": weapon,
			"target": ally,
			"type": ContinuousEffectManager.ModifierType.STRENGTH,
			"stat": "strength",
			"value": func(_c: Node, _current: int, _mod: Dictionary) -> int:
				return GameState.get_oro_total(wielder_controller) * per_oro,
			"operation": "add",
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
			"description": "%s porta %s (+Fuerza por Oro)" % [ally.card_name, weapon.card_name],
		})
		ContinuousEffectManager.register_modifier({
			"source": weapon,
			"target": ally,
			"type": ContinuousEffectManager.ModifierType.KEYWORDS,
			"stat": "",
			"value": 0,
			"operation": "add",
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"layer": ContinuousEffectManager.ModifierLayer.LAYER_6_ABILITIES,
			"keywords_add": [Constants.Keyword.FURIA],
			"description": "%s porta %s (Furia)" % [ally.card_name, weapon.card_name],
		})
		if ally.has_method("refresh_strength_badge"):
			ally.refresh_strength_badge()
		return

	var rx := RegEx.new()
	# Captura keywords adicionales otorgadas en la MISMA oración ("e
	# Indesterrable"/"y Furia"/etc., 2026-09-04 — a pedido del usuario,
	# 'El portador gana 2 de Fuerza e Indesterrable' es el texto más común
	# de TODAS las Armas del juego, y hasta ahora esta función solo leía
	# el número de Fuerza, ignorando cualquier keyword en la misma frase).
	# El grupo de la keyword acepta tanto "e Indesterrable"/"y Furia" (con
	# conjunción) como ", Furia" sin conjunción (2026-09-06, p.ej. Daga
	# Ritual: "gana 2 de Fuerza, Furia" — antes exigía "y"/"e" literal
	# antes de la keyword, así que una lista separada solo por coma nunca
	# matcheaba el grupo 2 y la keyword quedaba sin otorgar).
	rx.compile("(?i)el portador gana (\\d+) de fuerza(?:[,\\s]*(?:[ey]\\s+)?([a-záéíóúñ]+))?")
	var m := rx.search(ability_text)
	if not m:
		return
	var bonus := int(m.get_string(1))
	if bonus > 0:
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

	var extra_word: String = m.get_string(2).to_lower()
	var keyword_map := {
		"indesterrable": Constants.Keyword.INDESTERRABLE,
		"indestructible": Constants.Keyword.INDESTRUCTIBLE,
		"furia": Constants.Keyword.FURIA,
		"imbloqueable": Constants.Keyword.IMBLOQUEABLE,
	}
	if keyword_map.has(extra_word):
		ContinuousEffectManager.register_modifier({
			"source": weapon,
			"target": ally,
			"type": ContinuousEffectManager.ModifierType.KEYWORDS,
			"stat": "",
			"value": 0,
			"operation": "add",
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"layer": ContinuousEffectManager.ModifierLayer.LAYER_6_ABILITIES,
			"keywords_add": [keyword_map[extra_word]],
			"description": "%s porta %s (%s)" % [ally.card_name, weapon.card_name, extra_word.capitalize()],
		})


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


## Impuestos de coste de Talismanes/Tótems/Oro y descuento de coste por
## "muestra X" — cuerpo movido a GoldManagerTax.gd (2026-09-06, "módulos
## gordos", Fase 3). Forwarders de una sola línea: los cuatro se siguen
## llamando internamente desde play_card()/_trigger_enter_play() más abajo
## con su nombre original.
func _register_talisman_totem_tax(card: Node) -> void:
	_tax._register_talisman_totem_tax(card)


func _register_talisman_second_play_tax(card: Node) -> void:
	_tax._register_talisman_second_play_tax(card)


func _get_reveal_cost_reduction_pattern(card: Node) -> Dictionary:
	return _tax._get_reveal_cost_reduction_pattern(card)


func _resolve_reveal_cost_reduction(card: Node, pattern: Dictionary) -> int:
	return await _tax._resolve_reveal_cost_reduction(card, pattern)


## Elegibilidad para jugar una carta (Errante, límite de juego por nombre,
## Talismanes de respuesta instantánea, portadores de Arma, excepciones de
## fase) — cuerpo movido a GoldManagerRestrictions.gd (2026-09-06, "módulos
## gordos", Fase 3). Forwarders de una sola línea: _is_response_only_talisman/
## has_phase_exception/get_phase_rejection_reason/_get_eligible_weapon_
## wielders/_player_has_ally_in_play tienen llamadores externos reales
## (CardInteractionModule.gd, DropZone.gd, CardManager.gd,
## LookRevealPatterns.gd, confirmado por grep de todo scripts/); el resto se
## sigue llamando internamente desde play_card()/play_card_from_exile()/
## play_card_from_cemetery()/_select_weapon_wielder() más abajo.
func _errante_violation(card: Node) -> bool:
	return _restrictions._errante_violation(card)


func _play_limit_violation(card: Node) -> bool:
	return _restrictions._play_limit_violation(card)


func _register_play_limit(card: Node) -> void:
	_restrictions._register_play_limit(card)


func _is_response_only_talisman(card: Node) -> bool:
	return _restrictions._is_response_only_talisman(card)


func _is_response_only_talisman_data(card_data: Dictionary) -> bool:
	return _restrictions._is_response_only_talisman_data(card_data)


func _player_has_ally_in_play() -> bool:
	return _restrictions._player_has_ally_in_play()


func _get_eligible_weapon_wielders() -> Array:
	return _restrictions._get_eligible_weapon_wielders()


func has_phase_exception(card_type: int) -> bool:
	return _restrictions.has_phase_exception(card_type)


func get_phase_rejection_reason(card_type: int) -> String:
	return _restrictions.get_phase_rejection_reason(card_type)


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
	# Crono Diamante (2026-09-02): "si jugaste un Aliado de coste 2 o más
	# este turno" — condición previa de su otra habilidad. Se registra acá
	# porque es el único lugar real donde un Aliado termina jugado, sin
	# importar el origen (mano, Exhumar, gratis) — los tres caminos
	# (play_card/play_card_from_cemetery/play_card_for_free) pasan por
	# esta misma función para Aliados/Tótems.
	if card.card_type == Constants.CardType.ALIADO and int(card.card_cost) >= 2:
		UniversalCardParser.turn_registry.register("played_ally_cost2plus:0", 0, GameManager.current_turn)
	if card.card_type in [Constants.CardType.ALIADO, Constants.CardType.TOTEM] and int(card.card_cost) >= 2:
		_apply_crono_diamante_annul_protection(card)
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


func _apply_crono_diamante_annul_protection(card: Node) -> void:
	"""Segunda habilidad de Crono Diamante (2026-09-02): 'tu primer Aliado
	o Tótem de coste 2 o más [este turno] no puede ser Anulado' — protege
	solo si el controlador tiene un Crono Diamante en su Reserva de Oro, y
	solo la PRIMERA vez por turno (turn_registry, mismo patrón que el
	resto de 'una vez por turno' de este archivo). Marca la carta con
	set_meta(), consultado en TargetedEffectExecutor._execute_targeted_annul().

	La otra mitad de esa misma oración ('la primera habilidad de Oro que
	utilices cada turno no puede ser cancelada') queda SIN implementar a
	propósito: este motor todavía no resuelve 'Cancelar' como una acción
	real ejecutable (solo Anular tiene un choque real, ver
	_execute_targeted_annul()) — no hay ningún lugar de verdad donde
	consultar esa protección todavía. Ver docs/plans/2026-09-02-prevention-
	response-window-design.md para el sistema más grande del que esto
	terminaría formando parte."""
	var controller_id: int = card.controller_id if card.get("controller_id") != null else 0
	if controller_id != 0:
		return  # el rival no tiene Crono Diamante implementado de ese lado todavía
	var gold_container = _main.player_gold
	if not gold_container:
		return
	var has_crono_diamante := false
	for c in gold_container.get_children():
		if is_instance_valid(c) and str(c.get("card_name")).to_lower() == "crono diamante":
			has_crono_diamante = true
			break
	if not has_crono_diamante:
		return
	var key := "crono_diamante_annul_protection:%d" % controller_id
	if UniversalCardParser.turn_registry.was_used(key, 0, GameManager.current_turn):
		return
	UniversalCardParser.turn_registry.register(key, 0, GameManager.current_turn)
	card.set_meta("protected_from_annul_this_turn", true)


func _trigger_enter_play(card: Node, zone: int = Constants.Zone.LINEA_DEFENSA) -> bool:
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
		_register_talisman_second_play_tax(card)
		var origin: String = "Exhumar (Cementerio → Destierro)" if card.get("is_exhumed") == true else "mano"
		print("[GoldManager] %s resuelve su efecto (Talismán, jugado desde %s)" % [
			card.card_name if card.get("card_name") else "Carta", origin
		])
		# Un Talismán no dispara nada (DAR Sección 8): su texto ES el efecto
		# de jugarlo, se resuelve directo — no pasa por has_trigger() ni por
		# la cola compartida de TriggerSystem (2026-08-27, a pedido del
		# usuario: "los Talismanes no disparan, resuelven"). resolve_talisman()
		# ya abre su propia ventana de respuesta real ANTES de resolver (Pila
		# de Respuesta Universal, 2026-09-09) — devuelve true si fue
		# anulado/cancelado ahí, para que _play_talisman() lo mande al
		# Cementerio sin mirar su propio texto para decidir destino.
		return await TriggerSystem.resolve_talisman(card)

	# CARD_PLAYED para Aliado/Arma/Tótem/Oro (2026-09-10, Pila de Respuesta
	# Universal). A diferencia de un Talismán, acá la carta YA está
	# físicamente en una zona de juego (jugarla y que entre en juego no son
	# el mismo momento del DAR) — reescribir cada camino de juego (play_card,
	# _equip_weapon, _place_card_as_gold, las búsquedas que colocan directo)
	# para abrir la ventana ANTES de animar/crear el Node hubiera exigido un
	# destino nuevo (Cementerio directo desde la mano) sin poder reusar
	# destroy_card() (exige zona de juego válida). Aproximación acordada con
	# el usuario: la ventana se abre ACÁ, justo antes de que dispare su
	# propio "Cuando entra en juego" — se la ve entrar igual que hoy, pero si
	# se anula/cancela acá su ETB nunca dispara y va directo al Cementerio
	# (mismo destino por defecto que cualquier Anular, igual que el Talismán
	# de arriba).
	var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card.get("card_name") else "", controller_id):
		await EffectController.destroy_card(controller_id, card, false)
		_update_gold_display()
		_main._update_buttons_for_phase(GameManager.current_phase)
		return true

	CardFactory.on_card_enters_play(card)
	if card.has_method("on_entered_play"):
		card.on_entered_play()
	_register_talisman_totem_tax(card)
	_register_talisman_second_play_tax(card)
	# 2026-09-20 (auditoría de Task 1.3, remote-multiplayer-parity Fase 1):
	# estos tres usaban "0" fijo en vez de 'controller_id' (ya calculado un
	# poco más arriba, línea 1447, para la ventana de respuesta). Mientras
	# _equip_weapon() solo se llamaba para Armas del Anfitrión (owner_id
	# siempre 0) esto nunca se notaba — pero _play_weapon_remote() (nuevo,
	# RemotePlayerController.gd) llama a _equip_weapon() para Armas del
	# jugador 1 (Remoto), y GameStateBroadcaster._on_card_entered_play()
	# decide "own"/"opponent" leyendo justo este player_id — con "0" fijo,
	# un Arma jugada por el Remoto se mostraba como si la hubiera jugado el
	# Anfitrión del otro lado de la red. Mismo bug que la nota de Task 1.2
	# ya advertía sobre _trigger_enter_play() en general.
	EffectController.emit_signal("on_card_entered_play", controller_id, card, zone)
	_refresh_dynamic_strength_badges(controller_id)

	await TriggerSystem._collect_triggers_for_event("on_enter_play", {
		"player_id": controller_id, "card": card, "zone": zone
	})

	# Almirante Akari — "cuando tu oponente juegue cartas, puedes Anular"
	# (2026-09-09). Se ofrece DESPUÉS de que el ETB propio ya resolvió —
	# distinto de la ventana de arriba (esa cubre CUALQUIER anulación antes
	# del ETB; esta es la habilidad puntual de Akari, que sigue viviendo
	# acá por si Akari no estaba entre los candidatos de la ventana genérica
	# — offer_counter_annul() tiene su propio chequeo interno, no duplica
	# la pregunta si ya se resolvió arriba).
	await EffectController.offer_counter_annul(card)
	return false


func _play_talisman(card: Node) -> void:
	"""Los Talismanes se resuelven al jugarse y no se quedan en el campo
	como un Aliado ni como un Tótem (DAR Sección 8): disparan su habilidad y
	van al Cementerio por defecto — al Destierro si su propio texto dice
	'destiérralo', o de vuelta al Mazo (barajado) si dice 'barájala'. Si fue
	jugado via Exhumar (card.is_exhumed), el Destierro manda siempre, sin
	importar lo que diga el propio texto (regla de Exhumar, DAR)."""
	TurnManager.on_card_played(card)
	_main._update_debug("Jugando talismán: %s" % card.card_name)

	# Rastreo por jugador de 'ya jugó un Talismán este turno' (2026-09-04,
	# p.ej. Fuente de la Juventud: 'les cuesta un Oro adicional jugar
	# Talismanes SI han jugado Talismanes este turno' — la condición del
	# impuesto la consulta _register_talisman_second_play_tax() más abajo).
	var talisman_owner: int = card.owner_id if card.get("owner_id") != null else 0
	UniversalCardParser.turn_registry.register("talisman_played:%d" % talisman_owner, 0, GameManager.current_turn)

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
	var was_annulled: bool = await _trigger_enter_play(card, Constants.Zone.LINEA_APOYO)

	if was_annulled:
		# Pila de Respuesta Universal (2026-09-09): anulado/cancelado durante
		# la ventana de respuesta real que resolve_talisman() ya abrió — su
		# efecto NUNCA resolvió, así que no corresponde mirar el propio texto
		# de la carta para decidir destino (ni "destiérralo" ni "barájala"
		# aplican a un efecto que no ocurrió) — va directo al Cementerio,
		# mismo destino por defecto que cualquier Anular.
		var true_owner_annulled: int = card.owner_id if card.get("owner_id") != null else 0
		await EffectController.destroy_card(true_owner_annulled, card, false)
		_update_gold_display()
		_main._update_buttons_for_phase(GameManager.current_phase)
		return

	var habilidad: String = card.card_ability.to_lower() if card.get("card_ability") else ""
	# 2026-09-08, bug real reportado por el usuario (Golpe Solar se quedaba
	# en juego en vez de desterrarse solo): "destierr" (sin tilde) NO
	# matchea "destiérralo"/"destiérrala" — el pronombre enclítico "-lo"/
	# "-la" pegado al verbo mueve el acento y SÍ lleva tilde en español
	# correcto ("destierra" sola no la lleva, pero "destiérralo" sí),
	# aunque el texto esté bien escrito sin ningún mojibake de por medio.
	var self_exile := "destierr" in habilidad or "destiérr" in habilidad    # cubre "destiérralo", "destierra esta carta", etc.
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
		await ActionModule.return_to_deck(card, true_owner, false, card)
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
			# is_being_destroyed=false (2026-09-04, bug reportado: texto de
			# consola decía 'fue destruida' — un Talismán que ya resolvió su
			# efecto y va al Cementerio por defecto no es una 'destrucción'
			# DAR, solo cambia el texto que imprime, mismo camino/señales.
			await EffectController.destroy_card(true_owner, card, false)

	_update_gold_display()
	_main._update_buttons_for_phase(GameManager.current_phase)


func _update_gold_display() -> void:
	_visuals._update_gold_display()


func update_gold_containers_spacing() -> void:
	_visuals.update_gold_containers_spacing()


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
		var oros_reserva: Array = _main.player_gold.get_children()
		# Elegir CUÁLES Oros físicos se gastan (2026-09-03, a pedido del
		# usuario) — antes se tomaban los primeros N de get_children() sin
		# que el jugador eligiera nada, lo que hacía imposible usar cartas
		# como Monitor Araucano ('Este Oro genera un Oro adicional cuando
		# sea usado para pagar Armas de coste 2 o más'): no había forma de
		# saber si FUE ese Oro puntual el que pagó. Los Oros Virtuales
		# (restringido y genérico, arriba) siguen siendo los primeros en
		# gastarse siempre — esto solo decide el orden DENTRO del Oro
		# físico, cuando de verdad hace falta.
		var chosen_oros: Array = await _choose_physical_gold_to_spend(oros_reserva, restante)
		# diverted cuenta las unidades que NO terminaron en Oro Pagado de
		# verdad (2026-08-29, p.ej. Jormundgander: '...convierte este Oro en
		# un Aliado y muévelo a tu Línea de Defensa' en vez del movimiento
		# normal) — GameState.pagar_oro() de abajo suma 'restante' completo
		# a oro_pagado sin saber esto, así que hay que restar la diferencia
		# después o el próximo Reagrupamiento regala Oro de más que nunca
		# existió físicamente en la pila.
		var diverted := 0
		for oro_card in chosen_oros:
			var was_diverted: bool = await _mover_oro_a_pagado(oro_card)
			if was_diverted:
				diverted += 1
			_resolve_gold_paid_reaction(oro_card, card_type, card_race, card_cost)
		GameState.pagar_oro(0, restante)
		if diverted > 0:
			GameState.agregar_oro_pagado(0, -diverted)
	TurnManager.any_card_played_this_turn = true
	var oro_restante = GameState.get_oro_reserva(0)
	_main._update_debug("Pagado %d Oro total (Reserva: %d, Virtual: %d)" % [cantidad, oro_restante, oros_virtuales])
	_update_gold_display()
	return true


func _choose_physical_gold_to_spend(oros_reserva: Array, restante: int) -> Array:
	"""Elige qué Oros físicos de Reserva se gastan para pagar 'restante'
	unidades (2026-09-03, a pedido del usuario — ver _resolve_gold_paid_
	reaction()). Sin elección real (hay que gastarlos todos, o solo queda
	uno) no pregunta nada, para no agregar fricción sin necesidad."""
	if restante >= oros_reserva.size() or oros_reserva.size() <= 1:
		return oros_reserva.slice(0, mini(restante, oros_reserva.size()))
	if not _main._card_interaction:
		return oros_reserva.slice(0, restante)

	# Clic directo sobre las cartas (2026-09-03, a pedido del usuario —
	# reemplaza el picker modal de antes): mismo mecanismo de "elegir
	# objetivo" que ya usa el resto del juego (Anular, Convertir, banear
	# del Cementerio rival, etc.) — CardInteractionModule.await_target(),
	# con el brillo celeste de "activable" (Card.set_activatable()) como
	# indicador visual de cuáles Oros son válidos para elegir ahora.
	var chosen: Array = []
	var remaining_candidates: Array = oros_reserva.duplicate()
	for c in remaining_candidates:
		if is_instance_valid(c):
			c.set_activatable(true)

	while chosen.size() < restante and not remaining_candidates.is_empty():
		var filter := func(c: Node) -> bool:
			return c in remaining_candidates
		var picked: Node = await _main._card_interaction.await_target(
			"Elige qué Oro gastar (%d de %d)" % [chosen.size() + 1, restante], filter)
		if not picked or not is_instance_valid(picked):
			break  # cancelado (ESC) — se completa abajo con el orden mecánico de siempre
		remaining_candidates.erase(picked)
		picked.set_activatable(false)
		chosen.append(picked)

	for c in remaining_candidates:
		if is_instance_valid(c):
			c.set_activatable(false)

	if chosen.size() < restante:
		# Cancelado a mitad de camino (ESC) — completar con las que falten
		# en el orden mecánico de siempre, para no dejar el pago sin
		# resolver a medio camino.
		for c in oros_reserva:
			if chosen.size() >= restante:
				break
			if c not in chosen:
				chosen.append(c)

	return chosen


func _resolve_gold_paid_reaction(oro_card: Node, card_type: int, card_race: String, card_cost: int) -> void:
	"""Detecta 'Este Oro genera un Oro adicional cuando sea usado para
	pagar X [de coste N o más]' en el texto del Oro que EFECTIVAMENTE pagó
	(2026-09-03, p.ej. Monitor Araucano) — solo se llama con el nodo físico
	real ya elegido en _choose_physical_gold_to_spend(), así que 'usado
	para pagar' acá es literal, no una aproximación."""
	if not is_instance_valid(oro_card):
		return
	var ability_text: String = oro_card.get("card_ability") if oro_card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return
	var lower := _fix_mojibake(ability_text).to_lower()
	if not ("este oro genera un oro adicional cuando sea usado para pagar" in lower):
		return

	var wanted_type: int = -1
	if "armas" in lower:
		wanted_type = Constants.CardType.ARMA
	elif "aliados" in lower:
		wanted_type = Constants.CardType.ALIADO
	elif "talismanes" in lower:
		wanted_type = Constants.CardType.TALISMAN
	elif "tótems" in lower or "totems" in lower:
		wanted_type = Constants.CardType.TOTEM
	if wanted_type != -1 and card_type != wanted_type:
		return

	var cost_rx := RegEx.new()
	cost_rx.compile("(?i)coste\\s+(\\w+)\\s+o\\s+m[aá]s")
	var m_cost := cost_rx.search(ability_text)
	if m_cost:
		var min_cost: int = UniversalCardParser._parse_amount(m_cost.get_string(1))
		if card_cost < min_cost:
			return

	generar_oros_virtuales(1)
	_main._update_debug("%s generó 1 Oro adicional" % str(oro_card.get("card_name")))


func generar_oros_virtuales(cantidad: int) -> void:
	oros_virtuales += cantidad
	for i in range(cantidad):
		_spawn_gold_token("Oro Virtual Libre", "Libre", virtual_gold_tokens)
	_main._update_debug("Generado %d Oro Virtual (total: %d)" % [cantidad, oros_virtuales])
	_update_gold_display()


func limpiar_oros_virtuales() -> void:
	if oros_virtuales > 0:
		_main._update_debug("Oros Virtuales expirados: %d" % oros_virtuales)
		oros_virtuales = 0
		var tokens_to_clear = virtual_gold_tokens.duplicate()
		virtual_gold_tokens.clear()
		for token in tokens_to_clear:
			if is_instance_valid(token):
				var tw = create_tween()
				tw.set_parallel(true)
				tw.tween_property(token, "modulate:a", 0.0, 0.20)
				tw.tween_property(token, "position:y", token.position.y - 15.0, 0.20)
				tw.finished.connect(func():
					if is_instance_valid(token):
						if token.get_parent() == _main.player_gold:
							_main.player_gold.remove_child(token)
						token.queue_free()
						update_gold_containers_spacing()
				)
		_update_gold_display()


func generar_oro_virtual_restringido(cantidad: int, predicate: Callable, label: String) -> void:
	"""Oro Virtual que SOLO paga cartas que cumplan 'predicate(card_type,
	card_race) -> bool' (p.ej. Padre de la Patria: 'para jugar Armas o
	Aliados Caballero'). A diferencia de generar_oros_virtuales(), queda
	guardado en restricted_gold_pools como su propia entrada — varias
	fuentes con distintas restricciones pueden coexistir sin mezclarse."""
	var tokens: Array = []
	for i in range(cantidad):
		_spawn_gold_token("Oro Virtual (%s)" % label, label, tokens)
	restricted_gold_pools.append({"amount": cantidad, "tokens": tokens, "predicate": predicate, "label": label})
	_main._update_debug("Generado %d Oro Virtual restringido (%s)" % [cantidad, label])
	_update_gold_display()


func limpiar_oro_restringido() -> void:
	if restricted_gold_pools.is_empty():
		return
	var pools_to_clear = restricted_gold_pools.duplicate()
	restricted_gold_pools.clear()
	_main._update_debug("Oro Virtual restringido expirado (%d pool(s))" % pools_to_clear.size())
	for pool in pools_to_clear:
		for token in pool.tokens:
			if is_instance_valid(token):
				var tw = create_tween()
				tw.set_parallel(true)
				tw.tween_property(token, "modulate:a", 0.0, 0.20)
				tw.tween_property(token, "position:y", token.position.y - 15.0, 0.20)
				tw.finished.connect(func():
					if is_instance_valid(token):
						if token.get_parent() == _main.player_gold:
							_main.player_gold.remove_child(token)
						token.queue_free()
						update_gold_containers_spacing()
				)
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


func _spawn_gold_token(nombre: String, label: String, target_list: Array) -> void:
	_visuals._spawn_gold_token(nombre, label, target_list)


func _despawn_virtual_gold_token() -> void:
	await _despawn_gold_token(virtual_gold_tokens)


func _despawn_gold_token(target_list: Array) -> void:
	await _visuals._despawn_gold_token(target_list)


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
