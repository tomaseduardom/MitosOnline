extends Node
## EffectController - Procesa efectos de cartas sobre el mazo
## Implementa validación "En medida de lo posible" (DAR - regla general)
##
## ESTADO REAL (2026-08-17, ver docs/audit-2026-08-13.html hallazgo 2 y 4):
## Casi todo aquí abajo está gateado por _validate_board(), que depende de
## `game_board` (poblado solo por GameBoard.gd — código huérfano de un layout
## de tablero anterior, nunca adjunto a ningún nodo de la escena actual).
## Con fallback hacia CardManager (que SÍ está vivo y sincronizado con Main):
##   draw_cards(), mill_cards(), destroy_card(), exile_card()
## search_cards()/discard_cards()/return_to_deck()/return_to_hand()/
## shuffle_deck()/convert_card_type() y todo lo que colgaba exclusivamente de
## ellas se ELIMINARON (2026-08-17): auditadas función por función, cero
## llamadores en todo el proyecto — implementaciones duplicadas y abandonadas
## de lo que ActionModule.gd (el camino real: TriggerSystem →
## UniversalCardParser → ActionModule) ya hace de verdad. Antes de añadir un
## efecto nuevo, dale a game_board el mismo tratamiento que draw_cards/
## mill_cards/destroy_card/exile_card (fallback a CardManager) en vez de
## asumir que va a aparecer solo — pero solo si algo realmente lo va a llamar.

# =============================================================================
# SIGNALS - Efectos
# =============================================================================
signal effect_started(effect_name: String, player_id: int)
signal effect_completed(effect_name: String, player_id: int, result: Dictionary)
signal effect_failed(effect_name: String, player_id: int, reason: String)
signal player_defeated(player_id: int, reason: String)

# =============================================================================
# SIGNALS - Triggers (DAR 7.2, 7.3, 7.4)
# =============================================================================
# Eventos de cartas individuales (para TriggerSystem)
signal on_card_drawn(player_id: int, card: Node)
signal on_card_milled(player_id: int, card: Node, destination: int)
signal on_card_discarded(player_id: int, card: Node)
signal on_card_entered_play(player_id: int, card: Node, zone: int)
signal on_card_left_play(player_id: int, card: Node, from_zone: int)
signal on_card_destroyed(player_id: int, card: Node)
signal on_card_exiled(player_id: int, card: Node)
signal on_card_returned_to_hand(player_id: int, card: Node)
signal on_card_attacks(player_id: int, card: Node)  # DAR 5.3.1 — "cuando ataque"
signal on_card_returned_to_deck(player_id: int, card: Node, to_top: bool)

# =============================================================================
# REFERENCIAS
# =============================================================================
var game_board: Node = null


func _ready() -> void:
	if GameManager:
		GameManager.connect("game_board_ready", _on_game_board_ready)
		if GameManager.game_board:
			game_board = GameManager.game_board
	_build_prevention_registry()


func _on_game_board_ready(board: Node) -> void:
	game_board = board


# =============================================================================
# VALIDACIÓN "EN MEDIDA DE LO POSIBLE"
# =============================================================================
func _get_available_amount(requested: int, available: int) -> int:
	"""Retorna la cantidad que se puede procesar según 'En medida de lo posible'
	Si se piden 3 pero hay 2, procesa 2 sin error
	"""
	return mini(requested, available)


func _validate_board() -> bool:
	"""Verifica que el GameBoard esté disponible. Siempre devuelve false —
	game_board nunca se asigna (era el GameBoard.gd huérfano, eliminado) —
	y cada llamador ya tiene su propio fallback basado en CardManager para
	cuando esto pasa (ver draw_cards()/mill_cards()/etc). No es un error
	real: antes imprimía push_error() cada vez, como si algo hubiera
	fallado, cuando en realidad el fallback se ejecuta correctamente
	siempre — solo generaba ruido confuso en la consola."""
	return game_board != null


# =============================================================================
# 1. ROBAR CARTAS (DAR - Robo)
# =============================================================================
func draw_cards(player_id: int, amount: int) -> Dictionary:
	"""Roba cartas una a una del Castillo
	'En medida de lo posible': roba hasta que el mazo se vacíe
	DAR 2.1: Si intenta robar con mazo vacío, pierde

	Returns: {success: bool, cards_drawn: Array, deck_emptied: bool}
	"""
	var result = {
		"success": true,
		"cards_drawn": [],
		"deck_emptied": false,
		"requested": amount,
		"actual": 0
	}

	if not _validate_board():
		# El GameBoard legacy no está activo en la escena actual (ver
		# docs/audit-2026-08-13.html, hallazgo 2) — usar el camino real del
		# juego en su lugar en vez de fallar en silencio.
		return await _draw_cards_fallback(player_id, amount)

	emit_signal("effect_started", "draw_cards", player_id)

	for i in range(amount):
		var deck = game_board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

		# Verificar mazo vacío ANTES de robar (condición de derrota)
		if deck.is_empty():
			print("[EffectController] Castillo vacío - Jugador %d pierde (DAR 2.1)" % (player_id + 1))
			result.deck_emptied = true
			emit_signal("player_defeated", player_id, "deck_empty")
			if GameManager:
				GameManager.player_loses(player_id, "deck_empty")
			break

		# Robar carta del tope
		var card = deck[0]
		game_board.move_card(card, Constants.Zone.MANO, player_id, true)
		result.cards_drawn.append(card)
		result.actual += 1

		# Emitir trigger para cada carta robada (DAR 7.2)
		emit_signal("on_card_drawn", player_id, card)

		# Pausa visual entre robos
		if i < amount - 1:
			await get_tree().create_timer(0.12).timeout

	print("[EffectController] Jugador %d robó %d/%d cartas" % [
		player_id + 1, result.actual, amount
	])

	emit_signal("effect_completed", "draw_cards", player_id, result)
	return result


func _draw_cards_fallback(player_id: int, amount: int) -> Dictionary:
	"""Fallback para robar cartas cuando no hay GameBoard legacy registrado.
	Usa Main/ZoneManager (el camino que realmente mueve cartas en la escena
	actual) en vez de fallar. Limitación conocida: como Main.draw_card() no
	devuelve el nodo de la carta robada, cards_drawn queda vacío y no se
	emite on_card_drawn por carta — cualquier trigger que dependa de esa
	señal específica no se disparará todavía. El conteo (actual/deck_emptied)
	sí es correcto."""
	var result = {
		"success": true,
		"cards_drawn": [],
		"deck_emptied": false,
		"requested": amount,
		"actual": 0
	}

	var main = get_node_or_null("/root/Main")
	if not main or not main.get("_zone_manager"):
		result.success = false
		emit_signal("effect_failed", "draw_cards", player_id, "no_main")
		return result

	emit_signal("effect_started", "draw_cards", player_id)

	for i in range(amount):
		var drew: bool = await main._zone_manager.draw_card(player_id)
		if not drew:
			result.deck_emptied = true
			break
		result.actual += 1
		if i < amount - 1:
			await get_tree().create_timer(0.12).timeout

	print("[EffectController] (fallback) Jugador %d robó %d/%d cartas" % [
		player_id + 1, result.actual, amount
	])

	emit_signal("effect_completed", "draw_cards", player_id, result)
	return result


# search_cards()/_card_matches_filter() eliminados (2026-08-17): cero
# llamadores en todo el proyecto — ActionModule.search() es la búsqueda real.
# =============================================================================
# 3. BOTAR CARTAS - MILL (DAR Sección 8 - Botar)
# =============================================================================
func mill_cards(player_id: int, amount: int, destination: int = Constants.Zone.CEMENTERIO) -> Dictionary:
	"""Bota cartas del tope del Castillo una a una
	'En medida de lo posible': bota hasta que el mazo se vacíe
	Nota: Botar NO causa derrota, solo robar (DAR 2.1)

	Returns: {success: bool, milled_cards: Array, actual: int}
	"""
	var result = {
		"success": true,
		"milled_cards": [],
		"requested": amount,
		"actual": 0,
		"destination": destination
	}

	if not _validate_board():
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) — usar el
		# fallback basado en CardManager en vez de fallar en silencio.
		return await _mill_cards_fallback(player_id, amount, destination)

	# Validar destino
	if destination != Constants.Zone.CEMENTERIO and destination != Constants.Zone.DESTIERRO:
		destination = Constants.Zone.CEMENTERIO
		result.destination = destination

	emit_signal("effect_started", "mill_cards", player_id)

	var dest_name = Constants.ZONE_NAMES[destination]

	for i in range(amount):
		var deck = game_board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

		# 'En medida de lo posible': si no hay más cartas, terminar sin error
		if deck.is_empty():
			print("[EffectController] Castillo vacío, no se pueden botar más cartas")
			break

		var card = deck[0]
		game_board.move_card(card, destination, player_id, true)
		result.milled_cards.append(card)
		result.actual += 1

		# Revelar carta botada (información pública)
		if card.has_method("flip_face_up"):
			card.flip_face_up()

		# Emitir trigger para cada carta botada (DAR 7.3)
		emit_signal("on_card_milled", player_id, card, destination)

		print("[EffectController] Botada: %s -> %s" % [
			card.card_name if card.get("card_name") else "Carta",
			dest_name
		])

		# Pausa visual
		if i < amount - 1:
			await get_tree().create_timer(0.1).timeout

	print("[EffectController] Jugador %d botó %d/%d cartas al %s" % [
		player_id + 1, result.actual, amount, dest_name
	])

	emit_signal("effect_completed", "mill_cards", player_id, result)
	return result


func _mill_cards_fallback(player_id: int, amount: int, destination: int) -> Dictionary:
	"""Fallback para botar cartas cuando no hay GameBoard legacy registrado.
	Usa CardManager (su deck/cementerio/destierro quedan sincronizados con
	Main por referencia compartida desde sync_from_main()) en vez de fallar
	en silencio. Limitación conocida: el Castillo no tiene nodos de Card
	individuales (solo un contador visual), así que milled_cards queda vacío
	y no se emite on_card_milled por carta — el conteo sí es correcto."""
	var result = {
		"success": true,
		"milled_cards": [],
		"requested": amount,
		"actual": 0,
		"destination": destination
	}

	emit_signal("effect_started", "mill_cards", player_id)

	if destination == Constants.Zone.DESTIERRO:
		var deck: Array = CardManager.get_deck(player_id)
		var exile: Array = CardManager.get_exile(player_id)
		for i in range(amount):
			if deck.is_empty():
				break
			var card_data: Dictionary = deck.pop_back()
			card_data["esta_oculta"] = false
			exile.append(card_data)
			result.actual += 1
		CardManager._emit_exile_changed(player_id)
		CardManager._emit_deck_changed(player_id)
	else:
		var dmg_result: Dictionary = CardManager.mill_cards(player_id, amount)
		result.actual = dmg_result.get("actual", 0)

	print("[EffectController] (fallback) Jugador %d botó %d/%d cartas al %s" % [
		player_id + 1, result.actual, amount, Constants.ZONE_NAMES.get(destination, "?")
	])

	emit_signal("effect_completed", "mill_cards", player_id, result)
	return result


# shuffle_deck()/discard_cards() eliminados (2026-08-17): cero llamadores
# en todo el proyecto. ActionModule.discard() es el descarte real; el
# barajado real lo hacen CardManager.shuffle_deck()/_zone_manager/GameManager
# directamente (varios sitios ya usan esos, no EffectController).
# =============================================================================
# 6/7. return_to_deck()/play_card_to_zone() eliminados (2026-08-17): cero
# llamadores en todo el proyecto. GoldManager._trigger_enter_play() ya
# documentaba por qué evita play_card_to_zone() (depende del game_board
# muerto) y mueve la carta directo — ver ese comentario para el camino real.
# =============================================================================
# 8. DESTRUIR CARTA (DAR 7.3 - Triggers de destrucción)
# =============================================================================
func destroy_card(player_id: int, card: Node, is_being_destroyed: bool = true, source: Node = null) -> bool:
	"""Destruye una carta, enviándola al Cementerio (o al Destierro si fue
	exhumada, regla que respeta CardManager.destroy_card()).
	Emite on_card_left_play y on_card_destroyed.

	is_being_destroyed (2026-09-04, bug reportado: 'el texto de la consola
	de los Talismanes, estas no se destruyen') — GoldManager._play_talisman()
	reusa esta función para mandar un Talismán ya resuelto a su Cementerio
	por defecto (mismo camino real de salida de juego, mismos contadores/
	señales), pero un Talismán resolviendo NO es una 'destrucción' en
	términos DAR — pasar false solo cambia el texto de consola a algo
	preciso, sin tocar prevención de salida de juego ni las señales (que
	siguen siendo el mismo choke point real para ambos casos).

	Returns: true si se destruyó
	"""
	if await _try_consume_leave_play_prevention(player_id, card, source):
		return false

	# Guardar zona origen
	var from_zone = card.current_zone if card.get("current_zone") != null else -1

	# Verificar que está en juego
	if from_zone not in Constants.ZONES_IN_PLAY:
		push_warning("[EffectController] Carta no está en juego, no se puede destruir")
		return false

	# Notificar a la carta que deja el juego
	if card.has_method("on_left_play"):
		card.on_left_play()

	# Limpiar keywords temporales y cache (DAR Sección 8)
	KeywordManager.clear_all_for_card(card)

	# Limpiar datos de conversión si estaba convertida
	clear_conversion_on_leave(card)

	# Emitir trigger de salida del juego
	emit_signal("on_card_left_play", player_id, card, from_zone)

	# Mover al Cementerio
	if game_board:
		game_board.move_card(card, Constants.Zone.CEMENTERIO, player_id, true)
	else:
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) — CardManager
		# ya respeta la regla de exhumación y mantiene los contadores de UI
		# sincronizados (a diferencia de game_board.move_card(), sí libera el
		# nodo — correcto, porque el Cementerio real solo muestra un contador).
		await CardManager.destroy_card(player_id, card)

	# Emitir trigger de destrucción
	emit_signal("on_card_destroyed", player_id, card)

	var card_name = card.card_name if card.get("card_name") else "Carta"
	if is_being_destroyed:
		print("[EffectController] %s fue destruida" % card_name)
	else:
		print("[EffectController] %s resuelve su efecto y va al Cementerio" % card_name)

	return true


# =============================================================================
# 9. DESTERRAR CARTA (DAR - Destierro)
# =============================================================================
func exile_card(player_id: int, card: Node, bypass_prevention: bool = false, source: Node = null) -> bool:
	"""Destierra una carta, enviándola al Destierro
	Emite on_card_left_play (si estaba en juego) y on_card_exiled

	bypass_prevention (2026-08-28): true cuando desterrar ES el costo que el
	propio jugador eligió pagar (p.ej. 'Puedes Desterrarlo para...', Legión
	Paladín) — la Prevención protege contra remoción del RIVAL, no debe
	poder bloquear que pagues tu propio costo (y si el jugador tiene otra
	copia de la misma carta con una carga de Prevención ya activa, sin esto
	quedaría sin poder pagar el costo de la segunda nunca).

	Returns: true si se desterró
	"""
	if not bypass_prevention and await _try_consume_leave_play_prevention(player_id, card, source):
		return false

	var from_zone = card.current_zone if card.get("current_zone") != null else -1

	# Si estaba en juego, notificar y emitir salida
	if from_zone in Constants.ZONES_IN_PLAY:
		if card.has_method("on_left_play"):
			card.on_left_play()

		# Limpiar keywords temporales y cache (DAR Sección 8)
		KeywordManager.clear_all_for_card(card)

		# Limpiar datos de conversión si estaba convertida
		clear_conversion_on_leave(card)

		emit_signal("on_card_left_play", player_id, card, from_zone)

	# Mover al Destierro
	if game_board:
		game_board.move_card(card, Constants.Zone.DESTIERRO, player_id, true)
	else:
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4)
		await CardManager.exile_card(player_id, card)

	# Emitir trigger de destierro
	emit_signal("on_card_exiled", player_id, card)

	var card_name = card.card_name if card.get("card_name") else "Carta"
	print("[EffectController] %s fue desterrada" % card_name)

	return true


# =============================================================================
# 10. return_to_hand() eliminado (2026-08-17): cero llamadores en todo el
# proyecto (Card.return_to_hand() es un método distinto y no relacionado —
# la animación de "volver a la posición" al cancelar un drag).
# =============================================================================
# 11. CONVERTIR TIPO DE CARTA (DAR Sección 8 - Convertir) — eliminado
# (2026-08-17): convert_card_type(), revert_card_type() y todo lo que
# colgaba exclusivamente de ellas (_validate_persistent_abilities,
# _unequip_weapon, _handle_zone_movement_on_conversion, can_use_ability,
# _update_card_faculties, _set_card_property, _register_conversion_duration,
# _on_turn_end_revert_conversion, _on_combat_end_revert_conversion,
# _revert_card_type, _notify_type_change, is_card_converted,
# get_original_type) tenían CERO llamadores en todo el proyecto — la
# palabra clave Convertir (DAR Sección 8) nunca se conectó a nada real. Se
# conserva clear_conversion_on_leave() (y _converted_cards) porque
# destroy_card()/exile_card() SÍ la llaman, aunque hoy sea un no-op — si
# se reimplementa Convertir en el futuro, ahí queda el punto de enganche.
# =============================================================================
var _converted_cards: Dictionary = {}


func clear_conversion_on_leave(card: Node) -> void:
	"""Limpia datos de conversión cuando una carta sale del juego"""
	if is_instance_valid(card):
		_converted_cards.erase(card.get_instance_id())


# =============================================================================
# PREVENCIÓN "SALE DEL JUEGO" (DAR - Utilizar Habilidades: Prevenir. P.ej.
# Legión Paladín: "Puedes Desterrarlo para prevenir que un Aliado que
# controles salga del juego", 2026-08-28)
# =============================================================================
## Inmunidad TEMPORAL de "no pueden salir del juego" para TODOS los Aliados
## de un jugador, con vencimiento por TURNO (no por carga) — distinto de
## Legión Paladín (Prevención reactiva real por carta, ver
## offer_prevention()/_prevention_registry más abajo): esto es una
## inmunidad OTORGADA por otro efecto, no una carta de Prevención. 2026-08-29,
## p.ej. Sherlock Holmes: "los Aliados que controlas no pueden salir del
## juego hasta tu próximo turno" — protege a TODOS a la vez, sin límite de
## cantidad, hasta que vuelva a empezar el turno de ese jugador.
var _blanket_leave_play_immunity: Dictionary = {0: false, 1: false}


func add_blanket_leave_play_immunity(player_id: int) -> void:
	"""Activa la inmunidad para TODOS los Aliados de player_id hasta que
	vuelva a empezar SU turno (GameManager.turn_started con ese player_id)."""
	if _blanket_leave_play_immunity.get(player_id, false):
		return  # Ya activa — no hace falta una segunda conexión
	_blanket_leave_play_immunity[player_id] = true
	print("[EffectController] Inmunidad de salida del juego activada para J%d (hasta su próximo turno)" % (player_id + 1))
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != player_id:
			return
		_blanket_leave_play_immunity[player_id] = false
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
		print("[EffectController] Inmunidad de salida del juego terminó para J%d" % (player_id + 1))
	GameManager.turn_started.connect(clear_it)


## Inmunidad TEMPORAL de "no puede salir del juego" para UNA carta puntual
## (2026-08-30, p.ej. Garfio Pirata: "Cuando entra en juego, el portador no
## puede salir del juego hasta tu próximo turno") — distinta de
## _blanket_leave_play_immunity (esa protege a TODOS los Aliados de un
## jugador a la vez, no una carta elegida). {card_instance_id: true}
var _single_card_leave_play_immunity: Dictionary = {}


func add_single_card_leave_play_immunity(card: Node, player_id: int) -> void:
	"""Activa la inmunidad para ESTA carta hasta que vuelva a empezar el
	turno de player_id (el controlador de la fuente, no necesariamente el
	dueño de 'card' — DAR: la protección la otorga QUIEN controla el
	efecto)."""
	if not is_instance_valid(card):
		return
	var id := card.get_instance_id()
	if _single_card_leave_play_immunity.get(id, false):
		return  # ya activa — no hace falta una segunda conexión
	_single_card_leave_play_immunity[id] = true
	var card_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Carta"
	print("[EffectController] Inmunidad de salida del juego activada para %s (hasta el próximo turno de J%d)" % [card_name, player_id + 1])
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != player_id:
			return
		_single_card_leave_play_immunity.erase(id)
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
	GameManager.turn_started.connect(clear_it)


func _try_consume_leave_play_prevention(player_id: int, card: Node, source: Node = null) -> bool:
	"""Solo previene la salida de Aliados. La inmunidad temporal en bloque
	(blanket, Sherlock Holmes) y la puntual por carta (Garfio Pirata) se
	revisan PRIMERO y no consumen nada — son inmunidades OTORGADAS por otro
	efecto, no cartas de Prevención, así que no pasan por el registro
	reactivo. Si ninguna aplica, ofrece Prevención reactiva real (Legión
	Paladín — ver offer_prevention(), tag 'leave_play')."""
	if not is_instance_valid(card) or card.get("card_type") != Constants.CardType.ALIADO:
		return false
	if _blanket_leave_play_immunity.get(player_id, false):
		var card_name0: String = str(card.get("card_name")) if card.get("card_name") != null else "Aliado"
		print("[EffectController] %s no sale del juego (inmunidad temporal activa para J%d)" % [card_name0, player_id + 1])
		var main0 := get_node_or_null("/root/Main")
		if main0:
			main0._update_debug("%s: no puede salir del juego este turno" % card_name0)
		return true
	if _single_card_leave_play_immunity.get(card.get_instance_id(), false):
		var card_name1: String = str(card.get("card_name")) if card.get("card_name") != null else "Aliado"
		print("[EffectController] %s no sale del juego (inmunidad puntual activa)" % card_name1)
		var main1 := get_node_or_null("/root/Main")
		if main1:
			main1._update_debug("%s: no puede salir del juego este turno" % card_name1)
		return true
	return await offer_prevention(card, source, "leave_play")


# =============================================================================
# PREVENCIÓN REACTIVA (DAR — Utilizar Habilidades: Prevenir), 2026-09-09
# =============================================================================
## Registro genérico de cartas de Prevención — reemplaza los 3 mecanismos de
## "carga previa" que existían antes (uno por Estaca, otro por Legión
## Paladín, otro por Drácula/Ángel Redentor) por UN solo punto de entrada
## reactivo: se pregunta al jugador EN EL MOMENTO en que el efecto está por
## resolverse, no antes (diseño validado en docs/plans/2026-09-02-
## prevention-response-window-design.md, roster real re-auditado 2026-09-09
## contra la API — Paladín Bestiarium NO es una carta de Prevención, estaba
## en la lista original por error; Almirante Akari queda fuera a propósito,
## su costo compartido con una segunda habilidad (Anular) no encaja limpio
## en este registro todavía).
##
## Cada entry: {name, detect: Callable(text)->bool, effect_tags:
## Array[String], opponent_only: bool, applies: Callable(target)->bool
## (target puede ser Node o Dictionary o null — ver Drácula), is_available:
## Callable(card)->bool, on_used: Callable(card) -> (awaitable)}.
## No hace falta un contador de cargas separado: la disponibilidad de cada
## carta es simplemente "¿sigue existiendo sin usar en una zona de juego?" —
## las 4 se autoconsumen (destierro o conversión) al usarse, salvo Ángel
## Redentor (sin costo), que usa el turn_registry ya existente para su
## candado real de "una vez por turno".
var _prevention_registry: Array[Dictionary] = []


func _build_prevention_registry() -> void:
	_prevention_registry = [
		{
			"name": "Estaca",
			"detect": func(text: String) -> bool:
				return "desterrarla para prevenir que una carta sea afectada por un efecto oponente" in text.to_lower(),
			# OJO: NO incluye "leave_play" — destroy_card()/exile_card() son el
			# funnel final por el que TAMBIÉN pasa cualquier "destroy"/"exile"
			# ya resuelto por ActionDestroy/ActionBanish más arriba en la
			# pila; si Estaca tuviera "leave_play" acá, preguntaría DOS veces
			# por la misma acción (una vez como "destroy"/"exile", otra como
			# "leave_play" al llegar a destroy_card()/exile_card()). Legión
			# 2026-09-09, corregido a pedido del usuario: Estaca SÍ cubre
			# "barajar de vuelta al mazo" — su alcance real es "cualquier
			# efecto oponente que afecte a una carta", no una lista cerrada
			# de verbos. Con "leave_play" en su lista, ambas cartas (Estaca
			# y Legión Paladín) quedan candidatas en destroy_card()/
			# exile_card()/return_to_deck() — pero eso NO duplica la
			# pregunta para un Destruir/Desterrar normal: esos ya se
			# resuelven en el paso "destroy"/"exile" de ActionDestroy/
			# ActionBanish, que NO pasa 'source' al llamar a destroy_card()/
			# exile_card() después — sin 'source' real, el chequeo
			# opponent_only de Estaca no puede confirmarse y no vuelve a
			# preguntar ahí. Solo return_to_deck() (nuevo choke point,
			# 2026-09-09) llama con 'source' real desde varios call sites,
			# así que ahí Estaca sí puede ofrecerse de verdad.
			"effect_tags": ["destroy", "exile", "leave_play", "debuff", "strength_change", "silence"],
			"opponent_only": true,
			"applies": Callable(),
			"is_available": func(_card: Node) -> bool: return true,
			"on_used": func(card: Node) -> bool:
				var owner_id: int = card.owner_id if card.get("owner_id") != null else 0
				var wielder = card.get_parent()
				if wielder and wielder.get("equipped_weapons") is Array:
					wielder.equipped_weapons.erase(card)
				await exile_card(owner_id, card, true)
				return true,
		},
		{
			"name": "Legión Paladín",
			"detect": func(text: String) -> bool:
				return "desterrarlo para prevenir que un aliado que controles salga del juego" in text.to_lower(),
			"effect_tags": ["leave_play"],
			"opponent_only": false,
			# Su texto es específico de "un Aliado" (2026-09-09, corregido —
			# se filtraba antes SOLO en _try_consume_leave_play_prevention(),
			# que no cubre el choke point nuevo de return_to_deck(); ahora
			# vive acá, en el registro mismo, así que aplica sin importar
			# desde dónde se llame offer_prevention()).
			"applies": func(target) -> bool:
				if target == null:
					return true
				var tipo = target.get("tipo") if target is Dictionary else target.get("card_type")
				return tipo == null or int(tipo) == Constants.CardType.ALIADO,
			"is_available": func(_card: Node) -> bool: return true,
			"on_used": func(card: Node) -> bool:
				var owner_id: int = card.owner_id if card.get("owner_id") != null else 0
				await exile_card(owner_id, card, true)
				return true,
		},
		{
			"name": "Drácula",
			"detect": func(text: String) -> bool:
				return "convertirlo en un oro sin habilidad para prevenir que una habilidad sea cancelada" in text.to_lower(),
			# opponent_only=false (2026-09-09, corregido): el texto real de
			# Drácula no dice "oponente" en ningún lado ("prevenir que una
			# habilidad sea cancelada o un Aliado de coste 1 sea Anulado"),
			# a diferencia de Estaca que sí lo dice explícito.
			"effect_tags": ["cancel", "annul"],
			"opponent_only": false,
			# "un Aliado de coste 1 sea Anulado" — solo cubre coste 1 exacto.
			# 'target' puede ser Node (annul directo en juego) o Dictionary
			# (annul en la pila, LinkedEffectRegistry — card_data crudo) o
			# null (tag 'cancel', que no tiene target de carta puntual).
			"applies": func(target) -> bool:
				if target == null:
					return true  # tag "cancel" — no hay carta puntual con coste que revisar
				var tipo = target.get("tipo") if target is Dictionary else target.get("card_type")
				if tipo != null and int(tipo) != Constants.CardType.ALIADO:
					return false
				var cost = target.get("coste") if target is Dictionary else target.get("card_cost")
				return cost == null or int(cost) == 1,
			"is_available": func(card: Node) -> bool: return not card.is_converted,
			"on_used": func(card: Node) -> bool:
				card.is_converted = true
				await KeywordManager.silence_card(card, card, "permanent")
				return true,
		},
		{
			"name": "Ángel Redentor",
			"detect": func(text: String) -> bool:
				return "puedes prevenir que una carta sea anulada" in text.to_lower(),
			"effect_tags": ["annul", "cancel"],
			"opponent_only": false,
			"applies": Callable(),
			"is_available": func(card: Node) -> bool:
				return not UniversalCardParser.turn_registry.was_used(str(card.get_instance_id()), 0, GameManager.current_turn),
			"on_used": func(card: Node) -> bool:
				UniversalCardParser.turn_registry.register(str(card.get_instance_id()), 0, GameManager.current_turn)
				return true,
		},
		{
			# 'Una vez por turno, puedes Barajar una carta de tu mano o que
			# controles para Anular una carta de coste 2 o menos o prevenir
			# que un Aliado sea afectado por un efecto oponente' (Almirante
			# Akari, 2026-09-04) — reactiva de verdad (2026-09-09, corregido
			# a pedido del usuario): SIN botón de activación, dos disparadores
			# reactivos distintos que comparten un único candado de una vez
			# por turno y un único costo (barajar 1 carta propia) pagado
			# recién al confirmar cuál de los dos usa. La mitad "Prevenir"
			# entra acá (mismo registro que Estaca, pero solo Aliados); la
			# mitad "Anular cuando el rival juega una carta" vive en
			# offer_counter_annul() más abajo — comparte is_available/costo
			# vía el mismo helper _pay_akari_shuffle_cost().
			"name": "Almirante Akari",
			"detect": func(text: String) -> bool:
				return "prevenir que un aliado sea afectado por un efecto oponente" in text.to_lower(),
			"effect_tags": ["destroy", "exile", "debuff", "strength_change", "silence"],
			"opponent_only": true,
			"applies": func(target) -> bool:
				if target == null:
					return true
				var tipo = target.get("tipo") if target is Dictionary else target.get("card_type")
				return tipo == null or int(tipo) == Constants.CardType.ALIADO,
			"is_available": func(card: Node) -> bool:
				return not UniversalCardParser.turn_registry.was_used(str(card.get_instance_id()), 0, GameManager.current_turn),
			"on_used": func(card: Node) -> bool:
				var paid: bool = await _pay_akari_shuffle_cost(card)
				if not paid:
					return false
				UniversalCardParser.turn_registry.register(str(card.get_instance_id()), 0, GameManager.current_turn)
				return true,
		},
	]


## Costo compartido de Almirante Akari (barajar 1 carta propia, de la mano o
## en juego) — pagado recién al confirmar cuál de sus 2 respuestas usa
## (Prevenir u offer_counter_annul()). Returns false si el jugador canceló
## la selección (no se paga nada, la respuesta de Akari se aborta entera).
func _pay_akari_shuffle_cost(source_card: Node) -> bool:
	var main := get_node_or_null("/root/Main")
	if not main:
		return false
	var owner_id: int = source_card.owner_id if source_card.get("owner_id") != null else 0

	var cost_candidates: Array = []
	if main.player_hand:
		for c in main.player_hand.cards:
			cost_candidates.append(c)
	for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo]:
		if field:
			cost_candidates.append_array(field.get_children())
	if cost_candidates.is_empty():
		main._update_debug("Almirante Akari: no tienes ninguna carta en tu mano o en juego para Barajar")
		return false

	var cost_data_list: Array = []
	for c in cost_candidates:
		cost_data_list.append(c.card_data)
	var picked_cost: Dictionary = await SelectionManager.await_single_pick(
		cost_data_list, "Almirante Akari: elige una carta de tu mano o que controles para Barajar (costo)")
	if picked_cost.is_empty():
		return false
	var cost_node: Node = null
	for c in cost_candidates:
		if c.card_data == picked_cost:
			cost_node = c
			break
	if not cost_node:
		return false

	if main.player_hand and main.player_hand.cards.has(cost_node):
		var cost_data: Dictionary = cost_node.card_data.duplicate()
		main.player_hand.remove_card(cost_node, true)
		CardManager.get_deck(owner_id).append(cost_data)
	else:
		var cost_owner: int = cost_node.controller_id if cost_node.get("controller_id") != null else owner_id
		await ActionModule.return_to_deck(cost_node, cost_owner, true, source_card)
	CardManager.shuffle_deck(owner_id)
	return true


## Mitad "Anular" de Almirante Akari — disparador DISTINTO al registro de
## arriba (reacciona a "tu oponente juega una carta", no a "un efecto
## oponente afecta a un Aliado"). Llamar justo después de que 'played_card'
## termine de entrar en juego, del lado de QUIEN LA JUGÓ (ver GoldManager.
## _trigger_enter_play()/EasyBotController._play_ally()) — comprueba si el
## RIVAL de quien jugó controla un Akari disponible y la carta jugada cuesta
## 2 o menos; si el jugador confirma, paga el mismo costo compartido
## (_pay_akari_shuffle_cost) y Anula (destruye) la carta recién jugada.
func offer_counter_annul(played_card: Node) -> void:
	if not is_instance_valid(played_card):
		return
	var played_owner: int = played_card.controller_id if played_card.get("controller_id") != null else 0
	var defender_id: int = 1 - played_owner
	if defender_id != 0:
		return  # el bot no responde todavía
	var cost = played_card.get("card_cost")
	if cost == null or int(cost) > 2:
		return

	var main := get_node_or_null("/root/Main")
	if not main:
		return
	var fields: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
		main.player_gold, main.player_oro_pagado]
	var akari: Node = null
	for field in fields:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			var ability_text: String = str(card.card_ability) if card.get("card_ability") != null else ""
			if "anular una carta de coste 2 o menos" in ability_text.to_lower() \
					and not UniversalCardParser.turn_registry.was_used(str(card.get_instance_id()), 0, GameManager.current_turn):
				akari = card
				break
		if akari:
			break
	if not akari:
		return

	var use_it: bool = await SelectionManager.await_two_choice(
		main, "¿Usar Almirante Akari para Anular a %s?" % str(played_card.get("card_name")), "Sí", "No")
	if not use_it:
		return
	var paid: bool = await _pay_akari_shuffle_cost(akari)
	if not paid:
		return
	UniversalCardParser.turn_registry.register(str(akari.get_instance_id()), 0, GameManager.current_turn)
	if not is_instance_valid(played_card):
		return
	await ActionModule.destroy([played_card], akari, true, true)


## Versión "por player_id" — algunos choke points (LinkedEffectRegistry,
## que opera sobre OBJETOS DE LA PILA de ActionPipeline, card_data
## Dictionary, no un Aliado ya en juego) no tienen un Node afectado real
## para leer su controller_id. 'applies_arg' se le pasa tal cual a cada
## entry.applies() — puede ser un Node, un Dictionary, o null.
func offer_prevention_for_player(target_owner_id: int, effect_source: Node, effect_tag: String, applies_arg = null) -> bool:
	var main := get_node_or_null("/root/Main")
	if not main:
		return false

	var source_owner: int = -2
	if effect_source and is_instance_valid(effect_source):
		source_owner = effect_source.controller_id if effect_source.get("controller_id") != null else -2

	var fields: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
		main.player_gold, main.player_oro_pagado] if target_owner_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
			main.opponent_gold, main.opponent_oro_pagado]

	var candidates: Array = []  # [{entry, card}]
	for field in fields:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			var card_controller: int = card.controller_id if card.get("controller_id") != null else -1
			if card_controller != target_owner_id:
				continue
			var ability_text: String = str(card.card_ability) if card.get("card_ability") != null else ""
			if ability_text.is_empty():
				continue
			for entry in _prevention_registry:
				if not (effect_tag in entry.effect_tags):
					continue
				if entry.opponent_only and source_owner != 1 - target_owner_id:
					continue
				if not entry.detect.call(ability_text):
					continue
				if entry.applies.is_valid() and not entry.applies.call(applies_arg):
					continue
				if not entry.is_available.call(card):
					continue
				candidates.append({"entry": entry, "card": card})

	if candidates.is_empty():
		return false

	if target_owner_id != 0:
		# Capa 2 de la Pila de Respuesta Universal (2026-09-09): el bot ya
		# puede usar Prevención de verdad — sin diálogo, decide solo, al azar
		# entre usar una de las candidatas disponibles o no usar ninguna
		# (mismo criterio simple que el resto de las decisiones de
		# EasyBotController — no hay heurística de "conviene o no", solo la
		# posibilidad real de reaccionar en vez de nunca hacerlo).
		if randf() < 0.5:
			return false
		var bot_chosen: Dictionary = candidates[randi() % candidates.size()]
		return await bot_chosen.entry.on_used.call(bot_chosen.card)

	# Fusión con la Pila de Respuesta Universal (2026-09-09): un solo panel
	# visual para "responder a algo" en todo el juego — mismo título/timer/
	# 'Pasar' que ResponseWindowHandler usa para la ventana genérica, en vez
	# del diálogo aparte (await_two_choice/await_single_pick) que Prevención
	# tenía antes. No pasa por ActionPipeline (esto es una pregunta puntual
	# con N candidatas + Pasar, no un objeto de pila que pueda ser anulado a
	# su vez), pero se ve y se siente igual para el jugador.
	var chosen: Dictionary = await _ask_prevention_panel(candidates)
	if chosen.is_empty():
		return false

	return await chosen.entry.on_used.call(chosen.card)


func _ask_prevention_panel(candidates: Array) -> Dictionary:
	"""Panel de "ventana de respuesta" para Prevención — mismo estilo visual
	que ResponseWindowHandler._on_step_d_waiting() (título, tamaño, timer de
	5 segundos, "Pasar" clickeable desde el instante 0), pero construido acá
	directo porque EffectController no tiene una referencia al
	CardInspectionLayer/ResponseWindowHandler del humano (son módulos de UI
	separados, ver arquitectura). Un botón por candidata + "Pasar".
	Returns: {} si pasó o venció el tiempo, {entry, card} si usó una."""
	var main := get_node_or_null("/root/Main")
	if not main:
		return {}

	var layer := CanvasLayer.new()
	layer.layer = 90
	main.add_child(layer)
	var panel := PanelContainer.new()
	panel.set_anchor(SIDE_LEFT, 0.5)
	panel.set_anchor(SIDE_TOP, 0.0)
	panel.set_anchor(SIDE_RIGHT, 0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.0)
	panel.set_offset(SIDE_LEFT, -210)
	panel.set_offset(SIDE_TOP, 8)
	panel.set_offset(SIDE_RIGHT, 210)
	panel.set_offset(SIDE_BOTTOM, 88)
	layer.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "⏸ Ventana de Respuesta"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(title)
	var status_lbl := Label.new()
	status_lbl.text = "¿Prevenir esto? (5s)"
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.add_theme_font_size_override("font_size", 10)
	status_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(status_lbl)
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var state := {"done": false, "chosen": {}}
	var btn_pass := Button.new()
	btn_pass.text = "Pasar ▶"
	btn_pass.pressed.connect(func(): state.done = true)
	btn_row.add_child(btn_pass)

	for c in candidates:
		var btn := Button.new()
		btn.text = "Usar %s" % str(c.entry.name)
		btn.pressed.connect(func():
			state.chosen = c
			state.done = true
		)
		btn_row.add_child(btn)

	panel.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.2)

	var elapsed := 0.0
	while not state.done and elapsed < 5.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()

	layer.queue_free()
	return state.chosen


## Wrapper para los choke points que sí tienen un Node afectado real (la
## mayoría — destroy/exile/silence/debuff/leave_play/annul directo).
func offer_prevention(affected_card: Node, effect_source: Node, effect_tag: String) -> bool:
	if not is_instance_valid(affected_card):
		return false
	if try_consume_legacy_targeted_prevention(affected_card):
		return true
	if affected_card.get("current_zone") == null or not (affected_card.current_zone in Constants.ZONES_IN_PLAY):
		return false
	var owner_id: int = affected_card.controller_id if affected_card.get("controller_id") != null else 0
	return await offer_prevention_for_player(owner_id, effect_source, effect_tag, affected_card)


## Puente temporal (2026-09-09) — para cartas con el modelo VIEJO de carga
## previa que quedaron fuera de este rediseño (Fisión Nuclear/Transformación,
## MiscUniquePatterns.gd: aproximan una protección "burbuja"/repartida con
## una carga por carta, sin pregunta reactiva — no encajan en el registro de
## _prevention_registry, que asume UNA carta de Prevención real detectada
## por texto). Almirante Akari YA NO usa este puente (ver
## _prevention_registry/offer_counter_annul() — se pasó a reactivo de
## verdad). Aislado del registro reactivo a propósito, se consulta primero
## en offer_prevention().
## {card_instance_id: count}
var _legacy_targeted_preventions: Dictionary = {}


func add_legacy_targeted_prevention(card: Node, amount: int = 1) -> void:
	if not is_instance_valid(card):
		return
	var id := card.get_instance_id()
	_legacy_targeted_preventions[id] = _legacy_targeted_preventions.get(id, 0) + amount


func try_consume_legacy_targeted_prevention(card: Node) -> bool:
	if not is_instance_valid(card):
		return false
	var id := card.get_instance_id()
	var charges: int = _legacy_targeted_preventions.get(id, 0)
	if charges <= 0:
		return false
	_legacy_targeted_preventions[id] = charges - 1
	var card_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Carta"
	var main := get_node_or_null("/root/Main")
	if main:
		main._update_debug("%s: protegida (Almirante Akari)" % card_name)
	return true


## Efectos suspendidos que resuelven en la PRÓXIMA Fase Final de un jugador
## puntual, de una sola vez (2026-09-06, a pedido del usuario — p.ej. Fisión
## Nuclear: 'En la próxima Fase Final oponente, Baraja una carta de coste 2
## o menos o Roba dos cartas') — a diferencia de un trigger real en juego
## (on_opponent_turn_end, que dispara TODOS los turnos mientras la fuente
## siga en juego), esto es un Talismán que ya se resolvió y fue Desterrado:
## no hay ninguna carta en juego a la que consultarle has_trigger() después.
## 'No se puede responder con nada' (aclarado por el usuario) = se resuelve
## directo, sin pasar por ningún sistema de prevención.
var _scheduled_next_final_phase_effects: Dictionary = {}


func schedule_next_final_phase_effect(player_id: int, effect: Callable) -> void:
	if not _scheduled_next_final_phase_effects.has(player_id):
		_scheduled_next_final_phase_effects[player_id] = []
	_scheduled_next_final_phase_effects[player_id].append(effect)


func consume_scheduled_final_phase_effects(player_id: int) -> void:
	"""Llamar al ENTRAR a la Fase Final de player_id (PhaseFlowController.
	_resolve_fase_final()) — ejecuta y limpia (una sola vez) los efectos
	suspendidos agendados para esta Fase Final puntual."""
	var effects: Array = _scheduled_next_final_phase_effects.get(player_id, [])
	if effects.is_empty():
		return
	_scheduled_next_final_phase_effects[player_id] = []
	for effect: Callable in effects:
		if effect.is_valid():
			await effect.call()


