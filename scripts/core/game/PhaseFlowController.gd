extends Node
class_name PhaseFlowController
## PhaseFlowController — Gestiona el ciclo de fases DAR, prioridad y flujo de turno.
## Se instancia como hijo de Main en _ready().

var _main: Node = null
var _last_state_machine_phase: int = -1


func setup(main: Node) -> void:
	_main = main

	# BattleManager
	if not BattleManager.damage_to_castle.is_connected(_on_battle_damage_to_castle):
		BattleManager.damage_to_castle.connect(_on_battle_damage_to_castle)
	if not BattleManager.player_defeated.is_connected(_on_battle_player_defeated):
		BattleManager.player_defeated.connect(_on_battle_player_defeated)
	if not BattleManager.combat_finished.is_connected(_on_battle_combat_finished):
		BattleManager.combat_finished.connect(_on_battle_combat_finished)

	# PriorityManager
	if not PriorityManager.both_players_passed.is_connected(_on_priority_both_passed_main):
		PriorityManager.both_players_passed.connect(_on_priority_both_passed_main)
	if not PriorityManager.priority_changed.is_connected(_on_priority_changed_bot_autopass):
		PriorityManager.priority_changed.connect(_on_priority_changed_bot_autopass)
	if not PriorityManager.priority_changed.is_connected(_on_priority_changed_glow):
		PriorityManager.priority_changed.connect(_on_priority_changed_glow)
	if not PriorityManager.priority_window_closed.is_connected(_on_priority_window_closed_glow):
		PriorityManager.priority_window_closed.connect(_on_priority_window_closed_glow)

	# ActionPipeline
	if not ActionPipeline.stack_empty.is_connected(_on_stack_resolved):
		ActionPipeline.stack_empty.connect(_on_stack_resolved)

	# GameManager — fase y turno
	if not GameManager.phase_changed.is_connected(_on_phase_changed_relay):
		GameManager.phase_changed.connect(_on_phase_changed_relay)
	if not GameManager.turn_started.is_connected(_on_turn_started):
		GameManager.turn_started.connect(_on_turn_started)


func reset_phase_guard() -> void:
	"""Resetea el guard de doble-disparo al inicio de cada turno nuevo."""
	_last_state_machine_phase = -1


# =============================================================================
# MÁQUINA DE ESTADOS DE FASES
# Punto de entrada unificado para cualquier cambio de fase,
# ya venga de GameManager o de TurnManager.
# =============================================================================
func _on_phase_changed_relay(new_phase: Constants.Phase) -> void:
	_on_phase_state_machine(new_phase)


func _on_phase_state_machine(new_phase: Constants.Phase) -> void:
	"""Orquesta la respuesta a cada cambio de fase (DAR Sección 5).

	Ciclo completo:
	  AGRUPACION → VIGILIA → ATAQUE → BLOQUEO → GUERRA_TALISMANES
	              → ASIGNACION_DANIO → FINAL → (siguiente turno)

	Turno 1: GameManager salta AGRUPACION y emite directamente VIGILIA.
	"""
	if int(new_phase) == _last_state_machine_phase:
		return
	_last_state_machine_phase = int(new_phase)

	GameManager.current_phase = new_phase
	UIManager.announce_phase(new_phase)
	_main._update_buttons_for_phase(new_phase)
	_main._game_hud.update_paso_button_state()

	print("[PhaseFlow] === FASE: %s ===" % Constants.PHASE_NAMES[new_phase])

	match new_phase:

		Constants.Phase.AGRUPACION:
			_main._game_hud.show_phase_announcement("AGRUPACIÓN")
			# Línea de Ataque → Línea de Defensa (DAR): un Aliado que atacó en
			# el turno anterior de este jugador se queda "comprometido" en
			# Ataque hasta esta Agrupación — igual que el Oro Pagado. Se lee
			# directo de los hijos del contenedor (no de GameManager.attackers,
			# que _start_batalla() ya vació al llegar el Ataque del rival).
			var atk_line: HBoxContainer = _main.player_linea_ataque if GameManager.active_player_id == 0 else _main.opponent_linea_ataque
			if _main._card_interaction and atk_line:
				await _main._card_interaction.unmark_attackers(atk_line.get_children().duplicate())
			if GameManager.active_player_id == 0:
				await _main._gold_manager._reset_gold()
			# "En tu Agrupación" (2026-08-30, p.ej. Espada del Juicio) —
			# mismo patrón que resolve_turn_end_triggers() para Fase Final.
			await TriggerSystem.resolve_agrupacion_triggers(GameManager.active_player_id)

		Constants.Phase.VIGILIA:
			_main._game_hud.show_phase_announcement("VIGILIA")
			TurnManager._reset_oro_tracking()
			if _main._card_inspector:
				_main._card_inspector.refresh_activatable_glows()

		Constants.Phase.ATAQUE:
			_main._game_hud.show_phase_announcement("BATALLA MITOLÓGICA")

		Constants.Phase.BLOQUEO:
			_main._game_hud.show_phase_announcement("BLOQUEO")

		Constants.Phase.GUERRA_TALISMANES:
			_main._game_hud.show_phase_announcement("GUERRA DE TALISMANES")

		Constants.Phase.ASIGNACION_DANIO:
			_main._game_hud.show_phase_announcement("ASIGNACIÓN DE DAÑO")

		Constants.Phase.FINAL:
			_main._game_hud.show_phase_announcement("FASE FINAL")


func _on_turn_started(player_id: int, turn_number: int) -> void:
	UIManager.announce_turn(player_id, turn_number)
	if player_id == 1:
		_opponent_auto_pass()


func _on_priority_changed_bot_autopass(player_id: int) -> void:
	"""El oponente (bot) todavía no sabe usar habilidades ni talismanes para
	responder a nada — por ahora, cada vez que le toca prioridad en CUALQUIER
	ventana activa (Guerra de Talismanes, ventana de respuesta de un trigger,
	etc.), espera un momento (el '¿Algo?' real, aunque nunca conteste que sí)
	y pasa solo. El humano sigue viendo/usando el botón ¿Paso? normalmente
	cuando la prioridad es suya. Cuando exista una IA real, este auto-pase
	se reemplaza por su lógica de decisión."""
	if player_id != 1:
		return
	if not PriorityManager.priority_window_active:
		return
	await get_tree().create_timer(0.6).timeout
	if PriorityManager.priority_window_active and PriorityManager.current_priority_player == 1:
		PriorityManager.pass_priority()
	else:
		print("[DIAG] bot_autopass: tras esperar, ya no aplica — priority_window_active=%s current_priority_player=%d" % [PriorityManager.priority_window_active, PriorityManager.current_priority_player])


func _on_priority_changed_glow(player_id: int) -> void:
	"""Hace brillar el botón ¿Paso? cuando el humano tiene prioridad en
	CUALQUIER ventana activa, no solo después de declarar un atacante.

	Antes _start_paso_glow() solo se llamaba desde CardInteractionModule
	tras declarar un ataque — cuando una carta abría su propia ventana de
	respuesta al entrar en juego (p.ej. Mariano Osorio), el botón ¿Paso?
	seguía visible pero sin ninguna señal de que había algo pendiente. El
	jugador no tenía forma de saber que debía presionarlo para continuar y
	el juego parecía trabado. Si la prioridad pasa al oponente (bot) dentro
	de la misma ventana, el brillo se apaga hasta que vuelva a ser el turno
	del humano de actuar."""
	if player_id == 0:
		_main._game_hud.start_paso_glow()
	else:
		_main._game_hud.stop_paso_glow()


func _on_priority_window_closed_glow() -> void:
	"""Apaga el brillo del botón ¿Paso? al cerrarse la ventana de prioridad."""
	_main._game_hud.stop_paso_glow()


func _opponent_auto_pass() -> void:
	"""IA stub: espera a que la fase FINAL esté activa y termina el turno del oponente.
	Comparte _resolve_fase_final() con el jugador humano para que robo y descarte
	por límite de mano no diverjan entre los dos caminos (ver auditoría, hallazgo 1)."""
	await get_tree().create_timer(1.2).timeout
	if not GameManager.is_game_active or GameManager.active_player_id != 1:
		return
	GameManager.advance_to_phase(Constants.Phase.FINAL)
	await get_tree().create_timer(0.6).timeout
	if GameManager.active_player_id == 1:
		_main._update_debug("Oponente termina su turno")
		await _resolve_fase_final(1)


# =============================================================================
# CALLBACKS DE COMBATE (BattleManager)
# =============================================================================
func _on_battle_damage_to_castle(player_id: int, total_damage: int, _sources: Array) -> void:
	"""BattleManager calculó y aplicó daño al Castillo — solo feedback visual."""
	var target = "tu Castillo" if player_id == 0 else "Castillo oponente"
	_main._update_debug("%d daño hacia %s" % [total_damage, target])
	_main._zone_manager._update_castillo_counts()


func _on_battle_player_defeated(player_id: int) -> void:
	_main._update_debug("¡Jugador %d derrotado!" % (player_id + 1))


func _on_battle_combat_finished(result: Dictionary) -> void:
	if result.get("game_ended", false):
		return

	# NO se desmarca a los atacantes acá (2026-08-21): DAR — un Aliado que
	# atacó se queda en Línea de Ataque (tinte naranja incluido) hasta la
	# Agrupación del próximo turno de su controlador, igual que el Oro
	# Pagado no vuelve a la Reserva hasta entonces. Ver el caso AGRUPACION
	# en _on_phase_state_machine(), que ahora hace ese trabajo.
	_main._zone_manager._update_castillo_counts()

	# DAR: tras Asignación de Daño, las habilidades 'cuando inflija daño'/
	# 'si hizo daño' pueden resolverse antes de pasar a Fase Final. Antes
	# nada disparaba este evento — DamageManager.gd lo intentaba pero es
	# código muerto que nadie llama (el daño real lo aplica BattleManager,
	# que no disparaba ningún trigger al terminar).
	await _fire_damage_dealt_triggers(result.get("damage_sources", []))

	GameManager.advance_to_phase(Constants.Phase.FINAL)


func _fire_damage_dealt_triggers(damage_sources: Array) -> void:
	"""Dispara 'on_damage_dealt' para cada carta que infligió daño al
	Castillo este combate (DAR — 'cuando inflija daño'/'si hizo daño')."""
	for source_info in damage_sources:
		var card = source_info.get("source")
		if not is_instance_valid(card):
			continue
		var controller_id = card.controller_id if card.get("controller_id") != null else 0
		await TriggerSystem._collect_triggers_for_event("on_damage_dealt", {
			"player_id": controller_id, "card": card, "amount": source_info.get("damage", 0)
		})


# =============================================================================
# PASO D — PRIORIDAD Y PILA
# =============================================================================
func _on_priority_both_passed_main() -> void:
	"""Ambos jugadores pasaron con la pila vacía — avanza la fase según contexto.
	DAR Sección 5.C3: Pila vacía + ambos pasan → la fase termina.

	GUARDIA (2026-08-17): TriggerSystem._wait_for_response_window() abre su
	propia ventana de prioridad (p.ej. para poder cancelar el 'cuando entra
	en juego' de un Aliado) y espera a que se cierre sondeando
	priority_window_active directamente — no necesita que ESTE handler
	haga nada. Pero como es un listener global de la misma señal
	both_players_passed, antes reaccionaba igual: si esa ventana se cerraba
	mientras la fase actual era VIGILIA, se interpretaba como 'el jugador
	pasó su turno de batalla' y saltaba directo a Fase Final — aunque el
	jugador solo había pasado para resolver el trigger pendiente, nunca
	llegó a declarar su ataque. Si TriggerSystem sigue esperando una
	respuesta, esta ventana es suya, no una señal de fin de fase — no tocar
	nada acá."""
	if TriggerSystem.awaiting_response:
		print("[DIAG] _on_priority_both_passed_main: BLOQUEADO por awaiting_response=true (fase=%s, is_collecting=%s, is_resolving=%s)" % [
			Constants.PHASE_NAMES.get(GameManager.current_phase, "?"), TriggerSystem.is_collecting, TriggerSystem.is_resolving
		])
		return

	var phase = GameManager.current_phase
	match phase:
		Constants.Phase.ATAQUE:
			_main._game_hud.stop_paso_glow()
			_main._update_debug("Paso D confirmado — pasando a Bloqueo")
			await GameManager.confirm_attackers()

		Constants.Phase.GUERRA_TALISMANES:
			_main._update_debug("Paso D completado — calculando daño de combate")
			# DAR 5.C4: la Guerra de Talismanes termina en el paso de
			# Asignación de Daño, no directo en el cálculo — antes
			# GameManager nunca fijaba esta fase (no se disparaba su título
			# ni daba pie a que triggers 'cuando inflija daño' resolvieran
			# antes de Fase Final).
			GameManager.advance_to_phase(Constants.Phase.ASIGNACION_DANIO)
			await BattleManager.calculate_combat_damage()

		Constants.Phase.BLOQUEO:
			_main._update_debug("Bloqueadores confirmados → GT")
			GameManager.advance_to_phase(Constants.Phase.GUERRA_TALISMANES)

		# Constants.Phase.VIGILIA (eliminado 2026-08-17): este caso era
		# redundante con _on_paso_pressed()'s propio manejo de VIGILIA (que
		# hoy es el botón "Atacar" — GameManager.proceed_to_battle() —, ver
		# 2026-08-28 más arriba). Este handler, en cambio,
		# reacciona a CUALQUIER ventana que se cierre con ambos pasados
		# mientras la fase siga siendo VIGILIA — incluida una ventana de
		# respuesta anidada de un trigger 'cuando entra en juego' (o la que
		# abre _on_stack_resolved() al vaciarse la pila). Eso hacía que
		# resolver un trigger pendiente con ¿Paso? saltara la batalla entera
		# sin que el jugador llegara a declarar ningún atacante.
		_:
			_main._update_debug("Ambos pasaron en %s" % Constants.PHASE_NAMES.get(phase, "?"))


func _on_stack_resolved() -> void:
	"""La pila LIFO (ActionPipeline) quedó vacía — abrir ventana de prioridad si no hay una activa."""
	if not PriorityManager.priority_window_active:
		PriorityManager.start_priority_window(
			PriorityManager.PriorityContext.RESPONSE_WINDOW,
			GameManager.active_player_id
		)


# =============================================================================
# BOTÓN ¿PASO?
# =============================================================================
func _on_paso_pressed() -> void:
	"""El jugador presiona ¿Paso? — pasa prioridad o avanza fase."""
	var phase = GameManager.current_phase

	if PriorityManager.priority_window_active:
		_main._update_debug("Paso: pasando prioridad en %s" % Constants.PHASE_NAMES.get(phase, "?"))
		PriorityManager.pass_priority()
		return

	match phase:
		Constants.Phase.VIGILIA:
			# El botón en Vigilia dice "Atacar" (2026-08-28, reemplaza el
			# diseño de 2026-08-23 a pedido del usuario): ya no se declaran
			# atacantes apartados DURANTE Vigilia — este botón solo termina
			# Vigilia y empieza la Batalla Mitológica. Declarar (o no) queda
			# para la fase de Ataque; si nadie ataca, un segundo ¿Paso? ahí
			# la salta igual (confirm_attackers() con la lista vacía llama a
			# _end_batalla() directo a Fase Final).
			_main._update_debug("Atacar: empieza la Batalla Mitológica")
			GameManager.proceed_to_battle()

		Constants.Phase.ATAQUE:
			_main._update_debug("Paso: confirmando atacantes")
			await GameManager.confirm_attackers()

		Constants.Phase.FINAL:
			_do_fase_final()

		Constants.Phase.GUERRA_TALISMANES, Constants.Phase.BLOQUEO:
			push_warning("[PhaseFlow] ¿Paso? en %s sin ventana activa" % Constants.PHASE_NAMES.get(phase, "?"))
			_main._update_debug("Sin ventana de prioridad activa")

		_:
			_main._update_debug("Paso presionado en fase %s" % Constants.PHASE_NAMES.get(phase, "?"))


func _do_fase_final() -> void:
	"""Disparado por el botón ¿Paso? del jugador humano en Fase Final."""
	_main._game_hud.hide_paso_button()  # sin delegate — método único de GameHUDModule
	await _resolve_fase_final(GameManager.active_player_id)


func _resolve_fase_final(player_id: int) -> void:
	"""Robo de fin de turno + límite de mano (DAR 5.D.3/5.D.4) + fin de turno.
	Camino único compartido por jugador humano (vía _do_fase_final) y oponente
	(vía _opponent_auto_pass), para que ambos apliquen exactamente las mismas reglas."""
	# 'En tu Fase Final' (2026-08-30, p.ej. Espada de O'Higgins) — se
	# dispara al ENTRAR a la fase, antes del robo/límite de mano normales
	# (mismo orden que cualquier trigger de entrada de fase en el DAR).
	await TriggerSystem.resolve_turn_end_triggers(player_id)

	if GameManager.is_first_turn:
		_main._update_debug("Fase Final: primer turno — sin robo")
	else:
		_main._update_debug("Fase Final: jugador %d roba %d carta(s)" % [player_id + 1, Constants.CARDS_DRAWN_PER_TURN])
		for i in range(Constants.CARDS_DRAWN_PER_TURN):
			if not await _main._zone_manager.draw_card(player_id):
				break

	await _enforce_hand_limit(player_id)

	_main._game_hud.show_phase_announcement("FIN DEL TURNO")
	await get_tree().create_timer(1.2).timeout

	_main._update_debug("Fin del turno %d" % GameManager.current_turn)
	GameManager.end_turn()


# =============================================================================
# LÍMITE DE MANO (DAR 5.D.4) — 8 cartas, se aplica en todos los turnos
# =============================================================================
func _enforce_hand_limit(player_id: int) -> void:
	"""Verifica el límite de mano al final del turno y fuerza el descarte del
	exceso. El jugador humano elige qué descartar (UI); el oponente descarta
	automáticamente sus cartas más caras."""
	var hand_count = _main.player_hand.get_card_count() if player_id == 0 else _main._opponent_fan.get_card_count()
	var excess = hand_count - Constants.MAX_HAND_SIZE
	if excess <= 0:
		return

	_main._update_debug("Jugador %d excede el límite de mano (%d/%d) — debe descartar %d" % [
		player_id + 1, hand_count, Constants.MAX_HAND_SIZE, excess
	])

	if player_id == 0:
		await _main._selection.open_discard_selection(0, excess)
	else:
		_opponent_auto_discard(excess)


func _opponent_auto_discard(amount: int) -> void:
	"""Descarta automáticamente las cartas más caras de la mano del oponente."""
	var fan = _main._opponent_fan
	if not fan:
		return
	var hand_cards: Array = fan.get_cards().duplicate()
	hand_cards.sort_custom(func(a, b): return a.card_cost > b.card_cost)
	var to_discard: Array = hand_cards.slice(0, mini(amount, hand_cards.size()))
	for card in to_discard:
		var data: Dictionary = card.card_data.duplicate() if card.get("card_data") else {}
		data["esta_oculta"] = false
		CardManager.add_to_cemetery(1, data)
		fan.remove_card(card, true)
	_main._update_debug("Oponente descarta %d carta(s) por límite de mano" % to_discard.size())
