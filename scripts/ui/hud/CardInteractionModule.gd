extends Node
class_name CardInteractionModule
## CardInteractionModule — Gestiona clicks, hover y arrastre de cartas.
## Se instancia como hijo de Main en _ready().

var _main: Node = null

var selected_card: Node = null
var is_placing_gold: bool = false
var _card_clicked_this_frame: bool = false
var _opponent_card_original_pos: Dictionary = {}
## Traba de reentrada por carta para _declare_attacker() (2026-08-23):
## la función es async con varios await ANTES de llegar a
## GameManager.attackers.append() — un segundo click (p.ej. el eco de
## card_double_clicked sobre un Aliado ya en juego) podía entrar de nuevo
## mientras el primero seguía en vuelo, ganándole la carrera a
## GameManager.declare_attacker() y quedando rechazado con 'no puede
## atacar todavía' aunque el primero sí se hubiera declarado bien.
var _declaring_attackers: Dictionary = {}

# =============================================================================
# SELECCIÓN DE OBJETIVO — usado por efectos que apuntan a UNA carta en juego
# (dar fuerza, silenciar, anular/destruir dirigido). Mismo patrón que
# is_placing_gold: se activa un "modo", y el próximo click en una carta que
# pase el filtro resuelve la acción pendiente en vez de abrir la selección
# normal de carta.
# =============================================================================
var is_selecting_target: bool = false
var _target_filter: Callable = Callable()
var _target_callback: Callable = Callable()
## Debounce del eco de doble-click (ver _resolve_target_selection): un
## double-click real dispara PRIMERO card_clicked (press 1) y LUEGO
## card_double_clicked (press 2, mismo gesto) — si press 1 ya resolvió la
## selección, press 2 no debe caer en "Solo puedes jugar cartas de la mano".
var _last_resolved_target: Node = null
var _last_resolved_at_ms: int = -100000


func setup(main: Node) -> void:
	_main = main


func start_target_selection(prompt: String, filter: Callable, on_selected: Callable) -> void:
	"""Activa el modo de selección de objetivo.
	filter: Callable(card) -> bool — decide si esa carta es un objetivo legal.
	on_selected: Callable(card) — se llama con la carta elegida al resolver."""
	is_selecting_target = true
	_target_filter = filter
	_target_callback = on_selected
	_main._update_debug(prompt)


func await_target(prompt: String, filter: Callable) -> Node:
	"""Envoltorio de start_target_selection() que espera la respuesta —
	extraído (2026-08-30) del mismo bloque de 8 líneas que se repetía
	copiado en _select_ally_target()/_select_convert_target()
	(TargetedEffectExecutor.gd), la elección de portador de Tyet/Aho
	(CardManager.gd) y GoldManager._select_weapon_wielder(). Dictionary de
	estado a propósito, no 'var chosen'/'var done' sueltas — mismo motivo
	de siempre (los lambdas de GDScript capturan variables locales por
	VALOR, ver comentarios de esta clase). Devuelve la carta elegida, o
	null si se canceló (ESC) o no había forma de abrir la selección."""
	if not is_instance_valid(self):
		return null
	var state := {"done": false, "chosen": null}
	var on_selected := func(c: Node) -> void:
		state.chosen = c
		state.done = true
	start_target_selection(prompt, filter, on_selected)
	while not state.done:
		await get_tree().process_frame
	return state.chosen


func cancel_target_selection() -> void:
	"""Cancela con ESC. Llama al callback con null (en vez de dejarlo sin
	invocar) — quien esperaba con 'while not done: await process_frame'
	(TriggerSystem._select_ally_target, GoldManager._select_weapon_wielder,
	etc.) se quedaba colgado para siempre si el jugador cancelaba, porque
	'done' nunca se ponía en true."""
	if not is_selecting_target:
		return
	is_selecting_target = false
	var callback = _target_callback
	_target_filter = Callable()
	_target_callback = Callable()
	_main._update_debug("Selección de objetivo cancelada")
	if callback.is_valid():
		callback.call(null)


func _resolve_target_selection(card: Node) -> void:
	if _target_filter.is_valid() and not _target_filter.call(card):
		# 2026-09-06, bug reportado por el usuario: quedarse pegado
		# clickeando la mano repetidamente sin saber que ESC cancela la
		# selección (p.ej. Golpe Solar: 'Baraja hasta una carta rival...
		# ESC para no barajar ninguna' — sin este recordatorio, cada click
		# en la mano solo repetía este mensaje para siempre, sin pista de
		# cómo salir). El mensaje ahora lo dice explícito.
		_main._update_debug("Objetivo no válido — elige otra carta o presiona ESC para cancelar")
		return
	var callback = _target_callback
	is_selecting_target = false
	_target_filter = Callable()
	_target_callback = Callable()
	_last_resolved_target = card
	_last_resolved_at_ms = Time.get_ticks_msec()
	if callback.is_valid():
		callback.call(card)


func check_deselect() -> void:
	"""Deselecciona la carta si el click fue fuera de cualquier carta."""
	if _card_clicked_this_frame:
		_card_clicked_this_frame = false
		return
	if selected_card:
		selected_card.deselect()
		selected_card = null


# =============================================================================
# CLICKS EN CARTAS DEL JUGADOR
# =============================================================================
func _on_card_clicked(card: Node) -> void:
	_card_clicked_this_frame = true
	if is_selecting_target:
		_resolve_target_selection(card)
		return
	if is_placing_gold:
		await _main._gold_manager._place_card_as_gold(card)
		return
	# Declarar bloqueador con un clic (2026-09-08, primera vez que se conecta
	# GameManager.declare_blocker() a una UI real — existía desde antes pero
	# sin ningún llamador, así que Bloqueo nunca dejaba hacer nada más que
	# pasar prioridad, bug real reportado por el usuario: "no funcionó el
	# sistema de bloqueos"). Solo el propio Aliado en Línea de Defensa del
	# jugador humano — si el humano es quien ataca, sus Aliados están en
	# Línea de Ataque, no Defensa, así que este bloque no interfiere.
	if GameManager.current_phase == Constants.Phase.BLOQUEO and card.card_type == Constants.CardType.ALIADO \
			and card.current_zone == Constants.Zone.LINEA_DEFENSA and card.controller_id == 0:
		await _declare_blocker(card)
		return
	# Declarar atacante con un clic (2026-08-17): el arrastre se desactivó
	# (Card.drag_enabled = false) por los bugs de posicionamiento que
	# causaba — ver Card._can_declare_attack_drag() para la condición real
	# (fase de Ataque, ya sin atajo de Vigilia — 2026-08-28). Se reutiliza
	# esa función tal cual para no duplicar la lógica de cuándo tiene
	# sentido intentar atacar.
	# Acepta Defensa (para declarar) o Ataque (para desdeclarar con un
	# segundo clic) — desde que declarar mueve de verdad la carta a Línea
	# de Ataque (consolidación 2026-08-20), ya no se queda en Defensa.
	if card.card_type == Constants.CardType.ALIADO and card.current_zone in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE]:
		# Si ya está atacando, un segundo clic lo retira del combate en vez
		# de rechazar el clic con un mensaje — a pedido del usuario, para
		# poder corregir una declaración antes de confirmar con ¿Paso?.
		if card in GameManager.attackers:
			if GameManager.current_phase in [Constants.Phase.VIGILIA, Constants.Phase.ATAQUE]:
				var undeclared = GameManager.undeclare_attacker(card)
				if undeclared:
					unmark_attackers([card])
					var name_undeclared = card.get("card_name") if card.get("card_name") else "Aliado"
					_main._update_debug("%s ya no está atacando" % name_undeclared)
			return
		if card.has_method("_can_declare_attack_drag") and card._can_declare_attack_drag():
			await _declare_attacker(card)
			return
		# No puede atacar todavía, pero SÍ estamos en una fase donde intentar
		# atacar tiene sentido (2026-08-23) — dar la razón real (enfermedad
		# de invocación, normalmente) en vez de caer al mensaje genérico de
		# selección de más abajo, que no explica nada sobre el ataque.
		if GameManager.current_phase in [Constants.Phase.VIGILIA, Constants.Phase.ATAQUE]:
			var validation_reason = TurnManager.can_attack(card)
			if not validation_reason.get("can_attack", true):
				var reason_name = card.get("card_name") if card.get("card_name") else "Aliado"
				_main._update_debug("%s: %s" % [reason_name, validation_reason.get("reason", "no puede atacar todavía")])
				return

	if selected_card and selected_card != card:
		selected_card.deselect()
	card.toggle_selection()
	selected_card = card if card.is_selected else null
	if card.card_type == Constants.CardType.ORO:
		_main._update_debug("Oro: %s" % card.card_name)
	elif card.card_type == Constants.CardType.ALIADO:
		_main._update_debug("Carta: %s (Coste: %d, Fuerza: %d)" % [card.card_name, card.card_cost, card.card_strength])
	else:
		_main._update_debug("Carta: %s (Coste: %d)" % [card.card_name, card.card_cost])


func _on_card_double_clicked(card: Node) -> void:
	# Un click real en Godot (Card._on_gui_input) SIEMPRE dispara card_clicked
	# primero (press 1, double_click=false) y LUEGO card_double_clicked (press
	# 2 del mismo gesto, double_click=true) — confirmado con logging en vivo
	# (2026-08-22). Si press 1 ya resolvió una selección de objetivo pendiente
	# (p.ej. elegir portador de un Arma), press 2 llega con is_selecting_target
	# ya en false — sin este chequeo caía en 'Solo puedes jugar cartas de la
	# mano' como si hubiera fallado, aunque la selección ya se había resuelto
	# bien. Se ignora en silencio ese eco (mismo objetivo, <700ms).
	if card == _last_resolved_target and Time.get_ticks_msec() - _last_resolved_at_ms < 700:
		return
	# Si la selección sigue pendiente (el objetivo de este double-click no es
	# el que se acaba de resolver), resolverla igual que un click simple —
	# evita que reentre en play_card() y pise el filtro/callback en curso.
	if is_selecting_target:
		_resolve_target_selection(card)
		return
	# Un Aliado ya en juego (Defensa/Ataque) no se 'juega' con doble-click —
	# tratarlo como el click simple de declarar/desdeclarar ataque en vez de
	# caer en el rechazo genérico de abajo (2026-08-23): antes, doble-clickear
	# por error un Aliado que no podía atacar todavía mostraba 'Solo puedes
	# jugar cartas de la mano', un mensaje que no tiene nada que ver con la
	# razón real (enfermedad de invocación, no es su turno, etc.).
	if card.card_type == Constants.CardType.ALIADO and card.current_zone in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE]:
		_on_card_clicked(card)
		return
	# No usar solo VIGILIA acá: este gateo corría ANTES de que la carta
	# llegara a GoldManager.play_card(), así que un Arma con Lobo Sagrado en
	# juego (o cualquier Talismán) en Guerra de Talismanes nunca alcanzaba a
	# intentarse siquiera (2026-08-28, bug reportado por el usuario).
	# Talismanes de respuesta instantánea (Anula/Cancela) también quedan
	# exceptuados acá, en CUALQUIER fase (2026-09-06) — mismo criterio que
	# GoldManager.play_card()'s is_instant_response, este gateo de UI corre
	# antes y los habría bloqueado igual sin este chequeo repetido.
	var is_instant_response_talisman: bool = card.card_type == Constants.CardType.TALISMAN \
		and _main._gold_manager._is_response_only_talisman(card)
	if GameManager.current_phase != Constants.Phase.VIGILIA and not _main._gold_manager.has_phase_exception(card.card_type) \
			and not is_instant_response_talisman:
		_main._update_debug(_main._gold_manager.get_phase_rejection_reason(card.card_type))
		return
	if GameManager.active_player_id != 0:
		_main._update_debug("No es tu turno")
		return
	if card.get_parent() != _main.player_hand:
		_main._update_debug("Solo puedes jugar cartas de la mano (%s)" % card.get("card_name"))
		return
	if card.card_type == Constants.CardType.ORO:
		await _main._gold_manager._place_card_as_gold(card)
		return
	await _main._gold_manager.play_card(card)


func _on_card_hovered(_card: Node) -> void:
	pass


func _on_card_unhovered(_card: Node) -> void:
	pass


# =============================================================================
# HOVER EN CARTAS DEL OPONENTE
# =============================================================================
func _on_opponent_card_hovered(card: Node) -> void:
	if not _opponent_card_original_pos.has(card):
		_opponent_card_original_pos[card] = card.position
	card.z_index = 100
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position:y", card.position.y + 15, 0.15)
	tween.tween_property(card, "scale", card.base_scale * 1.08, 0.15)


func _on_opponent_card_unhovered(card: Node) -> void:
	card.z_index = 0
	var original_pos = _opponent_card_original_pos.get(card, card.position)
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", original_pos, 0.15)
	tween.tween_property(card, "scale", card.base_scale, 0.15)


func _on_card_dropped(card: Node, pos: Vector2) -> void:
	if card.has_method("move_to"):
		card.move_to(card.original_position)


# =============================================================================
# COLOCAR ORO
# =============================================================================
func _on_place_gold_pressed() -> void:
	# Excepción de mano (2026-08-30, p.ej. Infernum Vox): este botón genérico
	# no tiene todavía una carta elegida, así que el chequeo por-carta de
	# TurnManager.can_place_oro(phase, card) no aplica acá — se escanea la
	# mano por si hay algún Oro con la excepción de texto propia antes de
	# bloquear la sola ENTRADA al modo "colocar Oro" (el chequeo real, con
	# la carta específica, sigue en GoldManager._place_card_as_gold()).
	if not TurnManager.can_place_oro(GameManager.current_phase) and not _hand_has_oro_chance_exception():
		if TurnManager.oro_placed_this_turn:
			_main._update_debug("Ya colocaste Oro este turno")
		elif TurnManager.oro_chance_lost:
			_main._update_debug("Perdiste la oportunidad de colocar Oro (jugaste otra carta primero)")
		else:
			_main._update_debug("Solo puedes colocar Oro en Fase de Vigilia")
		return
	is_placing_gold = not is_placing_gold
	if is_placing_gold:
		_main._update_debug("Selecciona una carta para colocar como Oro (debe ser tu primera acción)")
	else:
		_main._update_debug("Modo Oro cancelado")


func _hand_has_oro_chance_exception() -> bool:
	"""¿Hay en la mano algún Oro con la excepción de Infernum Vox (ver
	TurnManager.ignores_oro_chance_lost())? oro_placed_this_turn NO tiene
	excepción (ni Infernum Vox se salta esa parte), así que se corta antes
	si ya se colocó Oro este turno o no es Vigilia."""
	if TurnManager.oro_placed_this_turn or GameManager.current_phase != Constants.Phase.VIGILIA:
		return false
	if not _main.player_hand:
		return false
	for c in _main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ORO and TurnManager.ignores_oro_chance_lost(c):
			return true
	return false


# =============================================================================
# BATALLA — DECLARAR ATACANTE
# =============================================================================
func _declare_attacker(card: Node) -> void:
	"""Declara un Aliado como atacante. Se llama al soltarlo en la Línea de
	Ataque — DropZone solo deja soltar aquí durante el paso de Ataque (DAR
	5.3.1, ya sin atajo de Vigilia — ver 2026-08-28), y
	GameManager.declare_attacker() valida enfermedad de invocación (Furia
	la evita, pero ya no salta la fase). Antes esta función solo se usaba
	(y nombraba) para Furia, pero el drop de DropZone ya aceptaba ambos
	casos — ver hallazgo 5.

	NO abre su propia ventana de prioridad (2026-08-16): antes lo hacía
	siempre, apenas se declaraba UN atacante — eso hacía que, en cuanto se
	pasaba esa ventana, se interpretara como 'atacantes confirmados' y el
	combate arrancaba con un solo Aliado, sin dejar declarar más. Además esa
	ventana se solapaba con la que GameManager.declare_attacker() ya abre
	internamente al resolver el trigger 'cuando ataque' de la propia carta
	(ver TriggerSystem._collect_triggers_for_event), lo que dejaba la
	prioridad en un estado inconsistente. Ahora el jugador puede seguir
	arrastrando más Aliados a la Línea de Ataque, y confirma todos juntos
	presionando ¿Paso? — que ya llama a GameManager.confirm_attackers()
	cuando no hay ninguna ventana de prioridad activa (ver _on_paso_pressed
	en PhaseFlowController), y ESA transición sí abre la ventana real
	(Guerra de Talismanes o Bloqueo)."""
	if not card or not is_instance_valid(card):
		return
	# Traba de reentrada (2026-08-23): un segundo click/eco sobre la MISMA
	# carta mientras una declaración anterior sigue en vuelo (ver comentario
	# de _declaring_attackers) no debe iniciar una segunda declaración en
	# paralelo — se ignora en silencio en vez de competir por
	# GameManager.attackers.
	if _declaring_attackers.has(card):
		return
	_declaring_attackers[card] = true
	# Con el clic reemplazando al arrastre, es fácil volver a clickear un
	# Aliado que ya está atacando (por error, o para revisarlo). Antes esto
	# caía en GameManager.declare_attacker(), que lo rechaza en silencio
	# (ally in attackers), y el mensaje genérico de más abajo ('no puede
	# atacar todavía') daba a entender que el ataque había fallado, cuando
	# en realidad ya estaba registrado y el combate seguía su curso normal.
	if card in GameManager.attackers:
		_main._update_debug("%s ya está atacando" % (card.get("card_name") if card.get("card_name") else "Aliado"))
		_declaring_attackers.erase(card)
		return
	# Si hay una ventana de prioridad abierta (p.ej. respuesta a un 'cuando
	# entre en juego' que se acaba de disparar), no dejar declarar un nuevo
	# atacante todavía — eso hacía que el efecto pendiente (p.ej. el 'roba 2'
	# de un oro) quedara pospuesto y se resolviera recién al momento de
	# atacar, en vez de cuando se jugó la carta. Hay que resolver esa
	# ventana primero (presionando ¿Paso?).
	if PriorityManager.priority_window_active:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de declarar otro atacante")
		card.return_to_hand()
		_declaring_attackers.erase(card)
		return
	var card_name = card.get("card_name") if card.get("card_name") else "Aliado"
	# KeywordManager.can_attack_immediately() (2026-09-02, refactor), no
	# card.has_keyword() directo — mismo motivo que el resto de checks de
	# keyword movidos a KeywordManager: respeta silencio/remociones
	# temporales, y ya es la misma función que usa TurnManager.can_attack()
	# para la validación real, así que el mensaje ahora no puede
	# desincronizarse de si el ataque de verdad contó como 'con Furia'.
	var has_furia = KeywordManager.can_attack_immediately(card)
	await get_tree().process_frame
	var declared = await GameManager.declare_attacker(card)
	if not declared:
		var reason = TurnManager.can_attack(card).get("reason", "")
		_main._update_debug("%s no puede atacar%s" % [card_name, (": " + reason) if not reason.is_empty() else " todavía"])
		_declaring_attackers.erase(card)
		return

	var ataque_container: HBoxContainer = _main.player_linea_ataque if card.controller_id == 0 else _main.opponent_linea_ataque
	await _advance_card_to_attack_line(card, ataque_container)
	_mark_card_as_attacker(card)
	_main._game_hud.start_paso_glow()
	_main._update_debug("⚔ %s declara ataque%s! Puedes seguir declarando o presionar ¿Paso?" % [card_name, " con Furia" if has_furia else ""])
	print("[CardInteraction] '%s' declaró ataque%s" % [card_name, " (Furia)" if has_furia else ""])
	_declaring_attackers.erase(card)


func _declare_blocker(card: Node) -> void:
	"""Declara 'card' como bloqueador de un atacante (fase BLOQUEO, DAR
	5.3.2). Si hay más de un atacante sin bloquear, pregunta cuál — con
	exactamente uno, se asigna directo sin preguntar. Un segundo clic sobre
	un bloqueador ya declarado no hace nada especial todavía (deselección/
	reasignación queda fuera de alcance de este primer cableado real)."""
	if not card or not is_instance_valid(card):
		return
	if card in GameManager.blockers.values():
		var blocking_name: String = card.get("card_name") if card.get("card_name") else "Aliado"
		_main._update_debug("%s ya está bloqueando" % blocking_name)
		return

	var unblocked_attackers: Array = []
	for attacker in GameManager.attackers:
		if is_instance_valid(attacker) and not GameManager.blockers.has(attacker):
			unblocked_attackers.append(attacker)
	if unblocked_attackers.is_empty():
		_main._update_debug("No hay atacantes sin bloquear")
		return

	var attacker: Node = unblocked_attackers[0]
	if unblocked_attackers.size() > 1:
		var options: Array = []
		for a in unblocked_attackers:
			options.append(a.get("card_name") if a.get("card_name") else "Aliado")
		var idx: int = await SelectionManager.await_choice(_main, "¿A cuál atacante bloquea?", options)
		attacker = unblocked_attackers[idx]

	GameManager.declare_blocker(card, attacker)
	var card_name: String = card.get("card_name") if card.get("card_name") else "Aliado"
	var attacker_name: String = attacker.get("card_name") if attacker.get("card_name") else "Aliado"
	var tween = create_tween()
	tween.tween_property(card, "modulate", Color(0.4, 0.7, 1.0, 1.0), 0.2)
	_main._update_debug("%s bloquea a %s" % [card_name, attacker_name])
	print("[CardInteraction] '%s' bloquea a '%s'" % [card_name, attacker_name])


func _mark_card_as_attacker(card: Node) -> void:
	"""Aspecto visual de 'atacando': tinte naranja."""
	if not card or not is_instance_valid(card):
		return
	var tween = create_tween()
	tween.tween_property(card, "modulate", Color(1.0, 0.55, 0.35, 1.0), 0.2)


func unmark_attackers(cards: Array) -> void:
	"""Revierte el aspecto visual de 'atacando' y mueve al sobreviviente
	de vuelta a Línea de Defensa en línea recta por el eje Y."""
	for card in cards:
		if not card or not is_instance_valid(card):
			continue
		var tween = create_tween()
		tween.tween_property(card, "modulate", Color.WHITE, 0.2)
		var defensa_container: HBoxContainer = _main.player_field if card.controller_id == 0 else _main.opponent_field
		await _move_card_to_line(card, defensa_container, Constants.Zone.LINEA_DEFENSA)
	if _main and _main.get("_zone_manager") != null:
		_main._zone_manager.compact_all_fields(true)


func _advance_card_to_attack_line(card: Node, ataque_container: HBoxContainer) -> void:
	"""Avanza el Aliado en línea recta exclusivamente sobre el eje vertical Y,
	manteniendo su coordenada X fija en su carril sin recentrar ni desviar."""
	if not card or not is_instance_valid(card) or not ataque_container:
		return
	var start_pos: Vector2 = card.global_position
	var slot_x: float = card.get_meta("field_slot_x", start_pos.x)

	var previous_parent: Node = card.get_parent()
	if previous_parent and previous_parent != ataque_container:
		previous_parent.remove_child(card)
	if card.get_parent() != ataque_container:
		ataque_container.add_child(card)

	card.set_zone(Constants.Zone.LINEA_ATAQUE)
	card.top_level = true
	card.global_position = start_pos

	var card_height: float = (card.size.y * card.scale.y) if card.size.y > 0 else 210.0
	var target_y: float = ataque_container.global_position.y + (ataque_container.size.y - card_height) / 2.0
	var target_pos: Vector2 = Vector2(slot_x, target_y)
	card.set_meta("field_slot_pos", target_pos)

	var tween = create_tween()
	tween.tween_method(
		func(y: float): card.global_position = Vector2(slot_x, y),
		start_pos.y, target_y, 0.25
	).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished


func _move_card_to_line(card: Node, target_container: HBoxContainer, zone: int) -> void:
	"""Regresa un Aliado a Línea de Defensa en línea recta vertical sobre el eje Y
	hacia su slot de columna X reservado."""
	if not card or not is_instance_valid(card) or not target_container:
		return
	var start_pos: Vector2 = card.global_position
	var previous_parent: Node = card.get_parent()
	if previous_parent and previous_parent != target_container:
		previous_parent.remove_child(card)
	if card.get_parent() != target_container:
		target_container.add_child(card)

	card.set_zone(zone)
	card.top_level = true
	var end_pos: Vector2 = _main._zone_manager.pin_card_to_field_slot(card, target_container)
	var slot_x: float = card.get_meta("field_slot_x", end_pos.x)
	card.global_position = Vector2(slot_x, start_pos.y)

	var tween = create_tween()
	tween.tween_method(
		func(y: float): card.global_position = Vector2(slot_x, y),
		start_pos.y, end_pos.y, 0.25
	).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
