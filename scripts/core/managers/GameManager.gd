extends Node
## GameManager - Singleton que controla el estado global del juego
## Maneja turnos, fases, jugadores y el flujo general de la partida
##
## GAME_BOARD (2026-08-16): `game_board` y `game_board_ready` quedan
## declarados pero SIEMPRE null/nunca se emiten a propósito. Poblaban una
## clase GameBoard.gd que resultó ser código huérfano — su @onready apuntaba
## a un layout de tablero de una versión anterior de la escena (líneas de
## ataque/defensa/apoyo separadas) que ya no existe en Main.tscn actual, así
## que nunca se pudo adjuntar a ningún nodo real. Se eliminó ese archivo.
## No se quitó la propiedad de aquí porque ~15 archivos todavía la LEEN (todos
## ya con su propio camino real de respaldo vía CardManager/Main, no
## necesitan el board para funcionar) — quitarla también de ahí es un
## cambio más grande que se hará por partes. El único camino que hoy mueve
## cartas de verdad es CardManager + Main (ver docs/audit-2026-08-13.html).
signal game_started
signal game_ended(winner: int)
signal game_board_ready(board: Node)  # nunca se emite — ver nota de arriba
signal player_lost(player_id: int, reason: String)
signal turn_started(player_id: int, turn_number: int)
signal turn_ended(player_id: int)
signal phase_changed(new_phase: Constants.Phase)
signal card_played(card: Node, player_id: int)
signal card_destroyed(card: Node)
signal damage_dealt(amount: int, target_player: int)

# =============================================================================
# ESTADO DEL JUEGO
# =============================================================================
var is_game_active: bool = false
var current_turn: int = 0
var active_player_id: int = 0  # 0 o 1
var current_phase: Constants.Phase = Constants.Phase.AGRUPACION

# Referencias a los jugadores
var players: Array[Node] = []

# Legacy — siempre null, ver nota al inicio del archivo
var game_board: Node = null

# Flag para el primer turno (no se roba carta, no hay agrupación)
var is_first_turn: bool = true

# Prioridad en Guerra de Talismanes
var priority_player_id: int = 0
var players_passed_priority: Array[bool] = [false, false]

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	print("[GameManager] Inicializado")


func setup_game(player1: Node, player2: Node) -> void:
	"""Configura una nueva partida con dos jugadores"""
	players = [player1, player2]
	is_game_active = false
	current_turn = 0
	is_first_turn = true
	print("[GameManager] Partida configurada")


func start_game(starting_player: int = 0) -> void:
	"""Inicializa el estado global de la partida, emite game_started y arranca
	el Turno 1. Seguro llamar _start_turn() directamente aquí: PhaseFlowController
	ya conectó GameManager.phase_changed/turn_started en Main._ready(), mucho
	antes de que termine el mulligan y se llegue a este punto.
	"""
	if players.size() != 2:
		push_error("[GameManager] Se necesitan 2 jugadores para iniciar")
		return

	active_player_id = clampi(starting_player, 0, 1)
	is_game_active = true
	current_turn = 1

	print("[GameManager] Partida iniciada. Jugador %d comienza." % (active_player_id + 1))
	emit_signal("game_started")

	_start_turn()


# =============================================================================
# FLUJO DE TURNOS
# =============================================================================
func _start_turn() -> void:
	"""Inicia un nuevo turno para el jugador activo"""
	print("[GameManager] === TURNO %d - Jugador %d ===" % [current_turn, active_player_id + 1])
	emit_signal("turn_started", active_player_id, current_turn)

	if is_first_turn:
		# Primer turno: saltar agrupación
		_change_phase(Constants.Phase.VIGILIA)
	else:
		_change_phase(Constants.Phase.AGRUPACION)


func end_turn() -> void:
	"""Finaliza el turno actual y pasa al siguiente jugador"""
	if not is_game_active:
		return

	emit_signal("turn_ended", active_player_id)

	# Cambiar jugador activo
	active_player_id = 1 - active_player_id  # Alterna entre 0 y 1

	# Si volvemos al jugador inicial, incrementar número de turno
	if active_player_id == 0:
		current_turn += 1

	is_first_turn = false
	_start_turn()


func advance_to_phase(new_phase: Constants.Phase) -> void:
	"""Método público para que sistemas externos avancen la fase."""
	_change_phase(new_phase)


func _change_phase(new_phase: Constants.Phase) -> void:
	"""Cambia a una nueva fase del turno"""
	current_phase = new_phase
	print("[GameManager] Fase: %s" % Constants.PHASE_NAMES[new_phase])
	emit_signal("phase_changed", new_phase)

	# Lógica específica de cada fase
	match new_phase:
		Constants.Phase.AGRUPACION:
			_process_agrupacion()
		Constants.Phase.VIGILIA:
			_process_vigilia()
		Constants.Phase.ATAQUE:
			_start_batalla()
		Constants.Phase.FINAL:
			_process_fase_final()


# =============================================================================
# FASE DE AGRUPACIÓN
# =============================================================================
func _process_agrupacion() -> void:
	"""
	Fase de Agrupación (DAR 5.1):
	1. Aliados de Línea de Ataque → Línea de Defensa  (vía PhaseFlowController,
	   caso AGRUPACION de _on_phase_state_machine() — llama unmark_attackers())
	2. Oros Pagados → Reserva de Oro                   (vía PhaseFlowController._reset_gold())
	3. Limpiar enfermedad de invocación (DAR 3.1) — a partir de aquí los
	   Aliados del jugador activo pueden atacar sin necesitar Furia.
	La fase avanza automáticamente a VIGILIA tras un breve delay para que el
	título visual sea visible.

	NOTA: el comentario original decía que TurnManager aplicaba esta lógica
	por señales propias — eso nunca pasa en la partida real (TurnManager.
	phase_changed casi no se dispara, ver docs/audit hallazgo 1/3). Por eso
	la enfermedad de invocación nunca se limpiaba y ningún Aliado sin Furia
	podía atacar después del turno en que se jugó.
	"""
	print("[GameManager] Procesando agrupación...")

	CardFactory.on_turn_start_clear_summon_sickness(active_player_id)

	# Dar tiempo a que el anunciador de AGRUPACIÓN sea visible antes de avanzar.
	await get_tree().create_timer(1.5).timeout

	_change_phase(Constants.Phase.VIGILIA)


# =============================================================================
# FASE DE VIGILIA
# =============================================================================
var oro_played_this_turn: bool = false

func _process_vigilia() -> void:
	"""
	Fase de Vigilia:
	- Poner un Oro (debe ser la primera acción)
	- Jugar Aliados, Armas, Tótems, Talismanes
	- Usar habilidades
	"""
	oro_played_this_turn = false
	# Limpiar atacantes/bloqueadores de la ÚLTIMA batalla real (2026-08-22):
	# si un turno termina SIN atacar, PhaseFlowController salta directo de
	# VIGILIA a FINAL (ver 'Paso: omitiendo batalla → Fase Final') y jamás
	# pasa por _start_batalla(), que era el único lugar que vaciaba
	# 'attackers' — un Aliado que atacó quedaba en esa lista para siempre
	# hasta que OTRO Aliado forzara la fase de Ataque de rebote. Aquí se
	# limpia sí o sí al empezar cada Vigilia, haya habido batalla o no.
	attackers.clear()
	blockers.clear()
	print("[GameManager] Vigilia activa - Jugador puede jugar cartas")
	# El jugador tiene el control ahora


func can_play_oro() -> bool:
	"""Verifica si el jugador puede poner un Oro"""
	return current_phase == Constants.Phase.VIGILIA and not oro_played_this_turn


func play_oro() -> void:
	"""Registra que se ha puesto un Oro este turno"""
	oro_played_this_turn = true


func proceed_to_battle() -> void:
	"""Pasa de Vigilia a Batalla Mitológica — único disparador ahora es el
	botón "Atacar" (2026-08-28). Si nadie ataca, confirm_attackers() con la
	lista vacía manda directo a Fase Final de todos modos (_end_batalla()),
	así que ya no hace falta un atajo aparte para "saltar la batalla"."""
	if current_phase == Constants.Phase.VIGILIA:
		_change_phase(Constants.Phase.ATAQUE)


# =============================================================================
# BATALLA MITOLÓGICA
# NOTA: La lógica detallada de batalla está en TurnManager.gd
# GameManager mantiene funciones básicas para compatibilidad
# =============================================================================
var attackers: Array[Node] = []
var blockers: Dictionary = {}  # {atacante: bloqueador}

func _start_batalla() -> void:
	"""Inicia la Batalla Mitológica — disparada por el botón "Atacar"
	(proceed_to_battle(), 2026-08-28). NO limpiar 'attackers'/'blockers'
	aquí: siguen vacíos porque solo ahora, ya en fase Ataque, se pueden
	declarar (_process_vigilia() ya garantiza que arrancan vacíos al
	empezar cada Vigilia nueva)."""
	print("[GameManager] Batalla Mitológica iniciada - Paso de Ataque")


func declare_attacker(ally: Node) -> bool:  # coroutine — el llamador debe usar 'await'
	"""Declara un Aliado como atacante (DAR 5.3.1).
	Único punto de entrada real (vía CardInteractionModule._declare_attacker,
	llamado desde DropZone al soltar en la Línea de Ataque) — antes no validaba
	enfermedad de invocación, así que un Aliado recién jugado podía atacar sin
	Furia con solo arrastrarlo. Ver docs/audit-2026-08-13.html, hallazgo 5.

	Devuelve true/false (2026-08-17): antes no devolvía nada, y el llamador
	aplicaba el aspecto visual de 'atacando' (rotación, tinte naranja) SIN
	esperar a saber si esta validación aceptaba el ataque. Si fallaba por
	cualquier motivo (enfermedad de invocación, fase incorrecta, etc.), la
	carta quedaba con el aspecto de atacante para siempre sin haberse
	agregado realmente al combate — nunca hacía daño, y como nada revertía
	ese aspecto, parecía 'desaparecer'/quedar con un color raro."""
	# Ya no acepta VIGILIA (2026-08-28, reemplaza el diseño de 2026-08-23 a
	# pedido del usuario): declarar atacantes requiere haber pasado antes
	# por el botón "Atacar" (GameManager.proceed_to_battle()), que es lo
	# único que ahora termina Vigilia y empieza la Batalla Mitológica.
	if current_phase != Constants.Phase.ATAQUE:
		return false
	if ally in attackers:
		return false
	var validation = TurnManager.can_attack(ally)
	if not validation.get("can_attack", true):
		print("[GameManager] %s no puede atacar: %s" % [ally.name, validation.get("reason", "")])
		return false
	attackers.append(ally)
	print("[GameManager] Atacante declarado: %s" % ally.name)

	# "Cuando ataque" (DAR 5.3.1) YA NO se dispara aquí (2026-08-29, corrige
	# exploit real reportado: declarar/desdeclarar el mismo Aliado varias
	# veces antes de confirmar disparaba el trigger una vez POR CADA
	# declare, generando Oro/robando cartas/etc. de más — p.ej. Lobo
	# Sagrado, "Cuando ataques, genera un Oro por el turno", Oro infinito).
	# Se dispara una sola vez por Aliado en confirm_attackers(), cuando el
	# ataque ya es definitivo — ver ese comentario para el detalle.
	return true


func undeclare_attacker(ally: Node) -> bool:
	"""Retira un Aliado de la lista de atacantes antes de confirmar
	(2026-08-17, a pedido del usuario): con el clic reemplazando al
	arrastre, declarar un atacante por error es más fácil de lo que era —
	esto permite deshacerlo con otro clic mientras siga en el paso de
	Ataque, antes de presionar ¿Paso? para confirmar a todos juntos.
	No revierte el trigger 'cuando ataque' que ya se disparó (DAR: una vez
	resuelto un trigger no se deshace) — solo saca a la carta del combate
	que está por resolverse. Ya no acepta VIGILIA (2026-08-28): mismo
	cambio que declare_attacker(), ahora solo se declara/deshace una vez
	que la fase ya es Ataque."""
	if current_phase != Constants.Phase.ATAQUE:
		return false
	if ally not in attackers:
		return false
	attackers.erase(ally)
	print("[GameManager] Atacante retirado: %s" % ally.name)
	return true


func confirm_attackers() -> void:  # coroutine — el llamador debe usar 'await'
	"""Confirma los atacantes y pasa al paso de Bloqueo — o directo a Guerra
	de Talismanes si el defensor no tiene ningún Aliado con el que bloquear
	(hoy es siempre el caso mientras el oponente-bot no juegue Aliados)."""
	if attackers.is_empty():
		# Sin atacantes, terminar batalla
		_end_batalla()
		return

	# "Cuando ataque" (DAR 5.3.1) se dispara AQUÍ, una sola vez por Aliado,
	# no en declare_attacker() (2026-08-29, corrige exploit real: declarar/
	# desdeclarar el mismo Aliado varias veces antes de confirmar disparaba
	# el trigger una vez POR CADA declare — p.ej. Lobo Sagrado, "genera un
	# Oro por el turno", permitía Oro infinito). 'attackers' ya es la lista
	# final deduplicada — declare_attacker() rechaza duplicados y
	# undeclare_attacker() los saca — así que cada Aliado dispara su propio
	# 'cuando ataque' exactamente una vez aquí, sin importar cuántas veces
	# se declaró/desdeclaró antes de este punto.
	for ally in attackers:
		if is_instance_valid(ally):
			EffectController.emit_signal("on_card_attacks", active_player_id, ally)
			await TriggerSystem._collect_triggers_for_event("on_attack", {
				"player_id": active_player_id, "card": ally
			})
			await _check_wielder_attack_triggers(ally, active_player_id)

	# "Cuando ataques con tres o más Aliados..." (2026-08-30, p.ej. Sable de
	# Napoleón) — condición sobre la CANTIDAD TOTAL de atacantes confirmados,
	# no un trigger por Aliado individual (el loop de arriba dispara "cuando
	# ataque" una vez por cada uno; esto es aparte, una sola vez).
	_check_attack_count_triggers(active_player_id, attackers.size())

	if not _defender_has_blockers():
		print("[GameManager] Defensor sin Aliados para bloquear — saltando Bloqueo")
		_change_phase(Constants.Phase.GUERRA_TALISMANES)
	else:
		_change_phase(Constants.Phase.BLOQUEO)


func _check_wielder_attack_triggers(ally: Node, player_id: int) -> void:
	"""'Cuando el portador ataque, si es de coste 1 o más, genera un Oro o
	Roba una carta' (2026-08-30, p.ej. Garfio Pirata) — trigger propio de un
	Arma equipada sobre el ataque de SU portador. El camino genérico
	(TriggerSystem._collect_triggers_for_event) solo revisa el texto de la
	carta que ataca, no el de sus Armas equipadas (mismo motivo por el que
	_check_attack_count_triggers() existe aparte para Sable de Napoleón) —
	se resuelve aquí, directo, con el mismo criterio."""
	if not is_instance_valid(ally):
		return
	var weapons = ally.get("equipped_weapons")
	if not (weapons is Array):
		return
	for w in weapons:
		if is_instance_valid(w) and _card_has_wielder_attack_choice(w):
			await _resolve_wielder_attack_choice(w, ally, player_id)


func _card_has_wielder_attack_choice(card: Node) -> bool:
	var text: String = str(card.get("card_ability")) if card.get("card_ability") != null else ""
	var lower := text.to_lower()
	return ("cuando el portador ataque" in lower and "genera un oro" in lower and "roba una carta" in lower)


func _resolve_wielder_attack_choice(weapon: Node, ally: Node, player_id: int) -> void:
	if int(ally.get("card_cost")) < 1:
		return
	var main := get_node_or_null("/root/Main")
	if not main:
		return
	var choose_gold: bool = await SelectionManager.await_two_choice(
		main, weapon.card_name if weapon.get("card_name") else "Arma", "Generar un Oro", "Robar una carta", player_id)
	if choose_gold:
		if main._gold_manager:
			main._gold_manager.generar_oros_virtuales(1, player_id)
	else:
		await ActionModule.draw(player_id, 1, "weapon_attack_trigger", true)


func _check_attack_count_triggers(player_id: int, attacker_count: int) -> void:
	"""'Cuando ataques con tres o más Aliados, las cartas que estén o sean
	puestas en los Cementerios este turno pierden su habilidad hasta tu
	próximo turno' (2026-08-30, p.ej. Sable de Napoleón). Se resuelve UNA
	SOLA VEZ aquí (no es un trigger por Aliado, es una condición sobre el
	total de atacantes confirmados) — apenas se encuentra una fuente con
	este texto, se aplica y se corta (no tiene sentido aplicar dos veces
	aunque hubiera dos copias)."""
	if attacker_count < 3:
		return
	var main = get_node_or_null("/root/Main")
	if not main:
		return
	var fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if player_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
	for field in fields:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card):
				continue
			var weapons = card.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and _card_has_attack_count_cemetery_silence(w):
						CardManager.silence_all_cemetery_cards(player_id)
						return
			if _card_has_attack_count_cemetery_silence(card):
				CardManager.silence_all_cemetery_cards(player_id)
				return


func _card_has_attack_count_cemetery_silence(card: Node) -> bool:
	var text: String = str(card.get("card_ability")) if card.get("card_ability") != null else ""
	var lower := text.to_lower()
	return ("cuando ataques con tres o" in lower and "aliados" in lower
		and "pierden su habilidad" in lower and "cementerio" in lower)


func _defender_has_blockers() -> bool:
	"""Verifica si el jugador defensor tiene al menos un Aliado en juego."""
	var defender_id = 1 - active_player_id
	var main = get_node_or_null("/root/Main")
	if not main:
		return false
	var field = main.player_field if defender_id == 0 else main.opponent_field
	if not field:
		return false
	for card in field.get_children():
		if card.get("card_type") == Constants.CardType.ALIADO:
			return true
	return false


func declare_blocker(blocker: Node, attacker: Node) -> void:
	"""Declara un Aliado como bloqueador de un atacante"""
	if current_phase == Constants.Phase.BLOQUEO:
		blockers[attacker] = blocker
		print("[GameManager] %s bloquea a %s" % [blocker.name, attacker.name])


func confirm_blockers() -> void:
	"""HUÉRFANA — nunca llamada por nadie (verificado 2026-09-20, grep de todo
	`scripts/`: cero call sites). El camino real que confirma bloqueadores y
	avanza a Guerra de Talismanes es PhaseFlowController._on_priority_both_
	passed_main(), rama Constants.Phase.BLOQUEO, que llama directo a
	GameManager.advance_to_phase(GUERRA_TALISMANES) (sin pasar por aquí) — y
	_start_guerra_talismanes() de abajo (reset manual de priority_player_id/
	players_passed_priority) quedó redundante desde que PriorityManager
	empezó a manejar esto solo, escuchando la señal phase_changed
	(PriorityManager.gd, rama GUERRA_TALISMANES de _on_phase_changed). No se
	borra (podría tener un dueño futuro no identificado), pero NO es la
	función a tocar para 'cuando bloqueas' — ver confirm_blockers_and_
	collect_triggers() más abajo, que sí es el camino real nuevo."""
	_change_phase(Constants.Phase.GUERRA_TALISMANES)
	_start_guerra_talismanes()


func confirm_blockers_and_collect_triggers() -> void:  # coroutine — el llamador debe usar 'await'
	"""Recolecta el trigger 'cuando bloqueas' (DAR 7.2/7.3) para cada
	bloqueador REALMENTE declarado, luego avanza a Guerra de Talismanes.
	Mismo criterio que confirm_attackers(): la lista ya es la definitiva (un
	bloqueador por atacante, declare_blocker() reescribe la misma clave del
	diccionario, no acumula duplicados si el jugador cambia de bloqueador
	antes de confirmar), así que cada Aliado dispara su propio 'cuando
	bloqueas' una sola vez, aquí, cuando el bloqueo ya es definitivo — no en
	declare_blocker() (mismo motivo del exploit ya documentado para
	confirm_attackers(): declarar/desdeclarar varias veces antes de
	confirmar dispararía el trigger una vez por cada intento).

	2026-09-20 (arquitectura.md "539 cartas sin cobertura", libro de thoth):
	primer uso real del trigger on_block — hasta ahora estaba clasificado en
	Card.TRIGGER_KEYWORDS pero sin ningún código que lo recolectara ni
	resolviera (TriggerResolution._execute_trigger_effect() no tenía rama
	'on_block'). No se reutiliza confirm_blockers() de arriba porque esa
	función quedó huérfana con lógica de reset que hoy podría pisar el
	estado de PriorityManager — este camino nuevo solo hace lo que el
	camino real (PhaseFlowController → advance_to_phase) ya hacía, más la
	recolección de triggers antes del cambio de fase."""
	var main := get_node_or_null("/root/Main")
	for blocker in blockers.values():
		if is_instance_valid(blocker):
			var blocker_owner: int = blocker.get("controller_id") if blocker.get("controller_id") != null else (1 - active_player_id)
			EffectController.emit_signal("on_card_blocks", blocker_owner, blocker)
			await TriggerSystem._collect_triggers_for_event("on_block", {
				"player_id": blocker_owner, "card": blocker
			})
			# libro de thoth (Oro, 2026-09-20) — carta pasiva ajena al
			# bloqueador, no llega por el camino de trigger_type de arriba
			# (ver docstring de GoldManager.check_libro_de_thoth_block()).
			if main and main.get("_gold_manager"):
				main._gold_manager.check_libro_de_thoth_block(blocker, blocker_owner)
	advance_to_phase(Constants.Phase.GUERRA_TALISMANES)


func _start_guerra_talismanes() -> void:
	"""Inicia la Guerra de Talismanes"""
	# El defensor tiene prioridad primero
	priority_player_id = 1 - active_player_id
	players_passed_priority = [false, false]
	print("[GameManager] Guerra de Talismanes - Prioridad: Jugador %d" % (priority_player_id + 1))


func pass_priority() -> void:
	"""
	DEPRECATED: El flujo de prioridad ahora pasa por PriorityManager.pass_priority().
	Esta función queda por compatibilidad pero no debe ser usada directamente.
	"""
	push_warning("[GameManager] pass_priority() llamada directamente — usar PriorityManager.pass_priority()")
	PriorityManager.pass_priority()


func _end_batalla() -> void:
	"""Finaliza la Batalla Mitológica"""
	attackers.clear()
	blockers.clear()
	_change_phase(Constants.Phase.FINAL)


# =============================================================================
# FASE FINAL
# =============================================================================
func _process_fase_final() -> void:
	"""
	Fase Final: solo anuncia el cambio de fase.
	El robo de fin de turno y el descarte por límite de mano (DAR 5.D.3/5.D.4)
	se resuelven en PhaseFlowController._resolve_fase_final(), que corre para
	ambos jugadores (humano vía botón ¿Paso?, oponente vía _opponent_auto_pass).
	No dupliques esa lógica aquí — ver docs/audit-2026-08-13.html, hallazgo 1.
	"""
	print("[GameManager] Fase Final")


# =============================================================================
# CONDICIONES DE VICTORIA
# =============================================================================
func check_victory() -> void:
	"""Verifica si algún jugador se quedó sin cartas en el Castillo (DAR
	2.1 — perder por Castillo vacío).

	2026-08-31, corrección de un bug real (reportado por el usuario: desterró
	5 cartas del tope de un Castillo con Aho y el Castillo rival quedó en 0,
	pero el juego nunca declaró ganada la partida): 'players' son dos
	Node.new() vacíos (ver GameBootstrap._prepare_game(): 'Player1'/
	'Player2' se crean sin script propio), así que
	player.has_method('get_deck_count') daba SIEMPRE false — esta función
	nunca disparó una victoria, ni siquiera en su único llamador real
	(ZoneManager.draw_card() al intentar robar con el mazo ya vacío). El
	camino de victoria por DAÑO DE COMBATE nunca pasó por aquí — BattleManager
	calcula el mazo vacío él mismo y llama GameManager.player_loses()
	directo, por eso ese sí funcionaba. Se lee el tamaño real de
	player_deck/opponent_deck en Main (mismo patrón que el resto de
	autoloads para llegar a Main) en vez de los Nodos dummy."""
	if not is_game_active:
		return
	var main := get_node_or_null("/root/Main")
	if not main:
		return
	if main.player_deck.is_empty():
		player_loses(0, "deck_empty")
	elif main.opponent_deck.is_empty():
		player_loses(1, "deck_empty")


func _end_game(winner_id: int) -> void:
	"""Termina la partida"""
	is_game_active = false
	print("[GameManager] ¡Jugador %d GANA!" % (winner_id + 1))
	emit_signal("game_ended", winner_id)


# =============================================================================
# GAME BOARD MANAGEMENT
# =============================================================================
func player_loses(player_id: int, reason: String) -> void:
	"""Marca que un jugador ha perdido la partida (DAR 2.1)
	reason puede ser: "deck_empty", "castle_destroyed", "concede"
	"""
	if not is_game_active:
		return  # ya terminó por otro camino (p.ej. combate y check_victory casi a la vez)
	var winner_id = 1 - player_id
	print("[GameManager] Jugador %d pierde por: %s" % [player_id + 1, reason])
	emit_signal("player_lost", player_id, reason)
	_end_game(winner_id)
