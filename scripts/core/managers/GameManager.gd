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
## No se quitó la propiedad de acá porque ~15 archivos todavía la LEEN (todos
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
	el Turno 1. Seguro llamar _start_turn() directamente acá: PhaseFlowController
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
	1. Aliados de Línea de Ataque → Línea de Defensa  (no aplica: no hay líneas
	   separadas en el tablero actual, un Aliado que atacó ya está "de vuelta"
	   visualmente en el mismo contenedor de campo)
	2. Oros Pagados → Reserva de Oro                   (vía PhaseFlowController._reset_gold())
	3. Limpiar enfermedad de invocación (DAR 3.1) — a partir de acá los
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

	var card_factory = get_node_or_null("/root/CardFactory")
	if card_factory and card_factory.has_method("on_turn_start_clear_summon_sickness"):
		card_factory.on_turn_start_clear_summon_sickness(active_player_id)

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
	print("[GameManager] Vigilia activa - Jugador puede jugar cartas")
	# El jugador tiene el control ahora


func can_play_oro() -> bool:
	"""Verifica si el jugador puede poner un Oro"""
	return current_phase == Constants.Phase.VIGILIA and not oro_played_this_turn


func play_oro() -> void:
	"""Registra que se ha puesto un Oro este turno"""
	oro_played_this_turn = true


func proceed_to_battle() -> void:
	"""Pasa de Vigilia a Batalla Mitológica"""
	if current_phase == Constants.Phase.VIGILIA:
		_change_phase(Constants.Phase.ATAQUE)


func skip_battle() -> void:
	"""Salta la Batalla y va directo a Fase Final"""
	if current_phase == Constants.Phase.VIGILIA:
		_change_phase(Constants.Phase.FINAL)


# =============================================================================
# BATALLA MITOLÓGICA
# NOTA: La lógica detallada de batalla está en TurnManager.gd
# GameManager mantiene funciones básicas para compatibilidad
# =============================================================================
var attackers: Array[Node] = []
var blockers: Dictionary = {}  # {atacante: bloqueador}

func _start_batalla() -> void:
	"""Inicia la Batalla Mitológica"""
	attackers.clear()
	blockers.clear()
	# La fase ya es ATAQUE, procesamos
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
	if current_phase != Constants.Phase.ATAQUE:
		return false
	if ally in attackers:
		return false
	var turn_mgr = get_node_or_null("/root/TurnManager")
	if turn_mgr and turn_mgr.has_method("can_attack"):
		var validation = turn_mgr.can_attack(ally)
		if not validation.get("can_attack", true):
			print("[GameManager] %s no puede atacar: %s" % [ally.name, validation.get("reason", "")])
			return false
	attackers.append(ally)
	print("[GameManager] Atacante declarado: %s" % ally.name)

	# Disparar habilidades "cuando ataque" (DAR 5.3.1). Se llama DIRECTO con
	# 'await' (no por señal fire-and-forget) para que el trigger termine de
	# resolverse antes de seguir — mismo motivo que en GoldManager._trigger_
	# enter_play(). TriggerSystem aísla la oración correcta del texto para
	# no re-disparar otro disparador de la misma carta (p.ej. "Al entrar").
	var effect_ctrl = get_node_or_null("/root/EffectController")
	if effect_ctrl:
		effect_ctrl.emit_signal("on_card_attacks", active_player_id, ally)
	await TriggerSystem._collect_triggers_for_event("on_attack", {
		"player_id": active_player_id, "card": ally
	})
	return true


func undeclare_attacker(ally: Node) -> bool:
	"""Retira un Aliado de la lista de atacantes antes de confirmar
	(2026-08-17, a pedido del usuario): con el clic reemplazando al
	arrastre, declarar un atacante por error es más fácil de lo que era —
	esto permite deshacerlo con otro clic mientras siga en el paso de
	Ataque, antes de presionar ¿Paso? para confirmar a todos juntos.
	No revierte el trigger 'cuando ataque' que ya se disparó (DAR: una vez
	resuelto un trigger no se deshace) — solo saca a la carta del combate
	que está por resolverse."""
	if current_phase != Constants.Phase.ATAQUE:
		return false
	if ally not in attackers:
		return false
	attackers.erase(ally)
	print("[GameManager] Atacante retirado: %s" % ally.name)
	return true


func confirm_attackers() -> void:
	"""Confirma los atacantes y pasa al paso de Bloqueo — o directo a Guerra
	de Talismanes si el defensor no tiene ningún Aliado con el que bloquear
	(hoy es siempre el caso mientras el oponente-bot no juegue Aliados)."""
	if attackers.is_empty():
		# Sin atacantes, terminar batalla
		_end_batalla()
		return
	if not _defender_has_blockers():
		print("[GameManager] Defensor sin Aliados para bloquear — saltando Bloqueo")
		_change_phase(Constants.Phase.GUERRA_TALISMANES)
	else:
		_change_phase(Constants.Phase.BLOQUEO)


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
	"""Confirma los bloqueadores y pasa a Guerra de Talismanes"""
	_change_phase(Constants.Phase.GUERRA_TALISMANES)
	_start_guerra_talismanes()


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
	var pm = get_node_or_null("/root/PriorityManager")
	if pm:
		pm.pass_priority()


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
	"""Verifica si algún jugador ha ganado"""
	for i in range(players.size()):
		var player = players[i]
		if player.has_method("get_deck_count"):
			if player.get_deck_count() <= 0:
				_end_game(1 - i)  # El otro jugador gana
				return


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
	var winner_id = 1 - player_id
	print("[GameManager] Jugador %d pierde por: %s" % [player_id + 1, reason])
	emit_signal("player_lost", player_id, reason)
	_end_game(winner_id)
