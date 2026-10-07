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

	print("[PhaseFlow] === FASE: %s (jugador activo: %d) ===" % [Constants.PHASE_NAMES[new_phase], GameManager.active_player_id])

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
			else:
				await _main._easy_bot.reset_gold()
			# "En tu Agrupación" (2026-08-30, p.ej. Espada del Juicio) —
			# mismo patrón que resolve_turn_end_triggers() para Fase Final.
			await TriggerSystem.resolve_agrupacion_triggers(GameManager.active_player_id)

		Constants.Phase.VIGILIA:
			_main._game_hud.show_phase_announcement("VIGILIA")
			TurnManager._reset_oro_tracking()
			# "En tu Vigilia" (2026-09-03, p.ej. Mariano Osorio) — mismo
			# patrón que Agrupación/Fase Final.
			await TriggerSystem.resolve_vigilia_triggers(GameManager.active_player_id)
			if _main._card_inspector:
				_main._card_inspector.refresh_activatable_glows()
			if GameManager.active_player_id == 1:
				await _main._easy_bot.take_vigilia_actions()

		Constants.Phase.ATAQUE:
			_main._game_hud.show_phase_announcement("BATALLA MITOLÓGICA")
			# "Al comienzo del Ataque" (2026-09-04, p.ej. almirante akari) —
			# mismo patrón que Agrupación/Vigilia/Fase Final.
			await TriggerSystem.resolve_ataque_triggers(GameManager.active_player_id)
			if GameManager.active_player_id == 1:
				await _main._easy_bot.take_ataque_actions()

		Constants.Phase.BLOQUEO:
			_main._game_hud.show_phase_announcement("BLOQUEO")

		Constants.Phase.GUERRA_TALISMANES:
			_main._game_hud.show_phase_announcement("GUERRA DE TALISMANES")

		Constants.Phase.ASIGNACION_DANIO:
			_main._game_hud.show_phase_announcement("ASIGNACIÓN DE DAÑO")

		Constants.Phase.FINAL:
			_main._game_hud.show_phase_announcement("FASE FINAL")
			if GameManager.active_player_id == 1:
				await _resolve_fase_final(1)


func _on_turn_started(player_id: int, turn_number: int) -> void:
	UIManager.announce_turn(player_id, turn_number)


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
	# 2026-09-15: se captura la generación de ESTA ventana (ver
	# PriorityManager._window_generation) ANTES del await — mismo motivo
	# que _human_pass_after()/_bot_pass_after(), ver esos comentarios.
	var scheduled_for_generation: int = PriorityManager._window_generation
	# 0.2s (2026-09-11, bajado de 0.6s — a pedido del usuario: las cadenas de
	# varias cartas entrando en juego seguidas acumulaban demasiado con 0.6s
	# por ventana). Sigue siendo perceptible, no instantáneo/confuso.
	await get_tree().create_timer(0.2).timeout
	if PriorityManager._window_generation != scheduled_for_generation:
		return  # la ventana para la que se programó este timer ya no es la actual
	if PriorityManager.priority_window_active and PriorityManager.current_priority_player == 1:
		PriorityManager.pass_priority()
	else:
		if Constants.VERBOSE_DIAG_LOGS:
			print("[DIAG] bot_autopass: tras esperar, ya no aplica — priority_window_active=%s current_priority_player=%d" % [PriorityManager.priority_window_active, PriorityManager.current_priority_player])
		_try_recover_stuck_phase_priority_window()


func _try_recover_stuck_phase_priority_window() -> bool:
	"""Reabre la ventana de prioridad de FASE (Guerra de Talismanes/Bloqueo)
	si quedó clobbereada (2026-09-04, bug reportado: 'se queda estancado
	en guerra de talismanes') — una ventana anidada de Paso D
	(StackStepResolver._execute_step_d(), que abre su PROPIA
	RESPONSE_WINDOW sobre la misma instancia de PriorityManager cuando algo
	pasa por la pila del ActionPipeline durante la fase) a veces no la
	restaura al cerrar, dejando priority_window_active=false sin que nadie
	vuelva a abrir nada — ni el botón ¿Paso? (gateado a
	priority_window_active) con qué reaccionar. Extraído a función propia
	(2026-09-06, bug reportado: el mismo estancamiento en Bloqueo, esta vez
	SIN pasar por el auto-pase del bot — el botón ¿Paso? del humano caía
	directo en el aviso 'Sin ventana de prioridad activa' sin intentar
	recuperarse) para poder llamarla también desde ahí. Returns true si
	reabrió una ventana."""
	var phase = GameManager.current_phase
	if GameManager.is_game_active and not PriorityManager.priority_window_active \
			and not ActionPipeline.is_stack_processing() and not TriggerSystem.awaiting_response \
			and phase in [Constants.Phase.GUERRA_TALISMANES, Constants.Phase.BLOQUEO]:
		if Constants.VERBOSE_DIAG_LOGS:
			print("[DIAG] recuperación: reabriendo ventana de prioridad para %s" % Constants.PHASE_NAMES.get(phase, "?"))
		PriorityManager.start_priority_window(
			PriorityManager.PriorityContext.GUERRA_TALISMANES if phase == Constants.Phase.GUERRA_TALISMANES
			else PriorityManager.PriorityContext.BLOCK_DECLARATION
		)
		return true
	return false


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
	# La visibilidad del botón depende de quién tiene la prioridad AHORA
	# (ver update_paso_button_state(), 2026-09-03) — no solo se recalcula
	# al cambiar de fase, también hay que refrescarla cada vez que la
	# prioridad cambia de jugador DENTRO de la misma fase (p.ej. el bot
	# pasa en Guerra de Talismanes y la prioridad vuelve al humano).
	_main._game_hud.update_paso_button_state()
	if player_id == 0:
		_main._game_hud.start_paso_glow()
		# 2026-09-11 (bug real reportado por el usuario: quedaba bloqueado
		# jugando otra carta — "Resuelve la respuesta pendiente (¿Paso?)" —
		# después de que el bot pasara en una ventana que arrancó CON ÉL,
		# p.ej. tu propia habilidad entrando a la pila, donde el oponente
		# responde primero). Punto único de auto-pase para el humano en
		# RESPONSE_WINDOW: cubre tanto que la ventana arranque contigo como
		# que la prioridad te llegue apenas a mitad de camino — priority_
		# changed se emite en ambos casos, así que no hace falta duplicar
		# esta lógica en _on_step_d_waiting()/_on_stack_resolved(). Ver
		# ResponseWindowHandler._offer_signo_amarillo_for_step_d() para la
		# única decisión real que puede haber aquí (Signo Amarillo), que
		# suprime este auto-pase mientras espera tu click (PriorityManager.
		# suppress_human_autopass). Restringido a RESPONSE_WINDOW a propósito:
		# la Guerra de Talismanes y el Bloqueo REALES (fase, no la reutilización
		# de esta misma etiqueta para el Paso D) sí deben esperar tu decisión
		# real, nunca auto-pasar.
		if PriorityManager.current_priority_context == PriorityManager.PriorityContext.RESPONSE_WINDOW \
				and not (_main._easy_bot is RemotePlayerController):
			# 2026-09-19 (arquitectura.md §10.51/§10.52): la espera real de 5s
			# (has_response == true, ver refresh_activatable_glows()/
			# _human_has_instant_response_talisman_in_hand() más abajo) queda
			# construida para cuando el oponente sea un jugador REMOTO de
			# verdad (esta rama ya excluye RemotePlayerController arriba, así
			# que en ese caso ni se llega aquí) — pero contra el EasyBot local,
			# a pedido explícito del usuario ("de momento, jugando contra el
			# bot, que pase de inmediato"), se mantiene el pase rápido de
			# siempre: no tiene sentido hacer esperar al humano 5s reales por
			# una decisión del BOT cuando puede decidir con solo mirar el
			# tablero. refresh_activatable_glows() se sigue llamando igual
			# (glow celeste de qué carta podría responder — informativo, sin
			# costo) pero el delay real quedó fijo en 0.2s, como antes de
			# §10.52. Si más adelante se conecta un oponente remoto por esta
			# misma rama, revisar si corresponde variar el delay según
			# `_main._easy_bot is RemotePlayerController` en vez de la
			# exclusión total de arriba.
			if _main._card_inspector:
				_main._card_inspector.refresh_activatable_glows()
			# 2026-09-15: se captura la generación de ESTA ventana (ver
			# PriorityManager._window_generation) para que el timer no actúe
			# sobre una ventana NUEVA si esta ya cerró sola antes de que pase el delay.
			_human_pass_after(0.2, PriorityManager._window_generation)  # bajado de 0.5s, 2026-09-11
	else:
		_main._game_hud.stop_paso_glow()
		if _main._card_inspector:
			_main._card_inspector._clear_all_activatable_glows()


func _on_priority_window_closed_glow() -> void:
	"""Apaga el brillo del botón ¿Paso? al cerrarse la ventana de prioridad.

	2026-09-11 (bug real reportado por el usuario: después de jugar Tyet —
	Oro con búsqueda — el botón de pasar dejaba de aparecer del todo, sin
	forma de seguir jugando). update_paso_button_state() solo se llamaba en
	dos momentos: al cambiar de fase, o cuando cambia de jugador la
	prioridad (_on_priority_changed_glow) — ninguno de los dos coincide
	necesariamente con el cierre real de la ventana. Si la última vez que
	se recalculó la visibilidad fue con current_priority_player == 1 (bot),
	_paso_button.visible quedaba en false, y como cerrar la ventana no
	recalculaba nada, se quedaba así para siempre aunque siguiera siendo tu
	Vigilia — la regla de respaldo (¿es tu turno en una fase relevante?) de
	update_paso_button_state() nunca llegaba a aplicarse."""
	_main._game_hud.stop_paso_glow()
	_main._game_hud.update_paso_button_state()


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

	# NO se desmarca a los atacantes aquí (2026-08-21): DAR — un Aliado que
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
	nada aquí."""
	if TriggerSystem.awaiting_response:
		if Constants.VERBOSE_DIAG_LOGS:
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
			# 2026-09-20 (arquitectura.md "539 cartas sin cobertura", libro de
			# thoth): antes esto llamaba advance_to_phase() directo, sin
			# recolectar 'cuando bloqueas' — primer uso real de ese trigger,
			# ver GameManager.confirm_blockers_and_collect_triggers() (mismo
			# criterio que ATAQUE arriba, que sí espera confirm_attackers()).
			await GameManager.confirm_blockers_and_collect_triggers()

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
	"""La pila LIFO (ActionPipeline) quedó vacía — abrir ventana de prioridad si no hay una activa.

	2026-09-11 (bug real reportado por el usuario: bloqueo silencioso de
	10-30s tras resolver la pila, "Drácula en Vigilia") — esta ventana se abre
	llamando a PriorityManager directo, sin pasar por StackStepResolver.
	_execute_step_d(), pero eso ya alcanza: start_priority_window() emite
	'priority_changed', que _on_priority_changed_glow() (conectado en setup())
	ya escucha para mostrar y hacer brillar el botón único ¿Paso?/Atacar del
	HUD cuando le toca al humano — no hace falta ningún overlay separado."""
	if not PriorityManager.priority_window_active:
		PriorityManager.start_priority_window(
			PriorityManager.PriorityContext.RESPONSE_WINDOW,
			GameManager.active_player_id
		)
		# Si arranca contigo (jugador 0), _on_priority_changed_glow() de aquí
		# abajo se encarga del auto-pase "no hay nada que decidir" — bug real
		# reportado por el usuario: quedaba bloqueado jugando otra carta
		# ("Resuelve la respuesta pendiente (¿Paso?)") hasta tocar el botón a
		# mano, aunque no hubiera nada real que decidir aquí (esta ventana no
		# tiene un stack_obj puntual que ofrecer para cancelar con Signo
		# Amarillo, a diferencia del Paso D real — ver ResponseWindowHandler).


func _human_has_instant_response_talisman_in_hand() -> bool:
	"""¿Hay al menos un Talismán de respuesta instantánea (Red de Plata,
	Sacrificio Solar, etc. — GoldManagerRestrictions._is_response_only_
	talisman(), §10.50) en tu mano que además puedes pagar ahora mismo?

	2026-09-19, §10.52: SIN LLAMADOR HOY A PROPÓSITO — junto con el valor de
	retorno de refresh_activatable_glows(), estaba pensada para decidir si el
	auto-pase de Paso D da 5s reales para decidir o pasa casi al toque, pero
	el usuario pidió volver al pase rápido fijo contra el EasyBot local "de
	momento" (no tiene sentido hacer esperar al humano por una decisión del
	bot). Queda lista para cuando la rama de _on_priority_changed_glow() se
	conecte a un oponente REMOTO de verdad (hoy esa rama excluye
	RemotePlayerController por completo, así que ni se llega a llamar esto) —
	no se borró para no perder el trabajo, pero no confundir "sin llamador"
	con "código muerto sin dueño" como el cluster de TargetSelector.gd (§2):
	aquí el dueño futuro ya está identificado."""
	if not _main.player_hand or not _main._gold_manager:
		return false
	for card in _main.player_hand.cards:
		if not is_instance_valid(card):
			continue
		if card.get("card_type") != Constants.CardType.TALISMAN:
			continue
		if not _main._gold_manager._is_response_only_talisman(card):
			continue
		var coste_real = PaymentManager.calcular_coste_real(card)
		if _main._gold_manager.puede_pagar(coste_real):
			return true
	return false


func _human_pass_after(delay: float, scheduled_for_generation: int) -> void:
	await get_tree().create_timer(delay).timeout
	if PriorityManager.suppress_human_autopass:
		return  # hay un diálogo reactivo real esperando decisión (Signo Amarillo)
	# 2026-09-15, bug real reportado por el usuario ("se traba en Guerra de
	# Talismanes", confirmado con diagnóstico en vivo: la ventana abría bien
	# pero se cerraba sola sin ningún click): si la ventana de RESPONSE_
	# WINDOW para la que se programó este timer ya cerró y se abrió una
	# ventana NUEVA (p.ej. Guerra de Talismanes) antes de que pasen los
	# 0.2s, _window_generation ya cambió — este timer viejo no debe tocar
	# la ventana nueva, aunque técnicamente "priority_window_active=true y
	# te toca a ti" siga siendo cierto (es cierto de la ventana NUEVA, no
	# de la que este timer estaba mirando).
	if PriorityManager._window_generation != scheduled_for_generation:
		return
	if PriorityManager.priority_window_active and PriorityManager.current_priority_player == 0:
		PriorityManager.pass_priority()


# =============================================================================
# BOTÓN ¿PASO?
# =============================================================================
func _on_paso_pressed() -> void:
	"""El jugador presiona ¿Paso? — pasa prioridad o avanza fase."""
	# 2026-09-14, bug real reportado por el usuario: con una selección de
	# objetivo pendiente (p.ej. 'Elige un Oro o una carta de coste 2 o menos
	# para Convertir', TargetedEffectExecutor._execute_targeted_convert())
	# nada impedía presionar ¿Paso? y seguir jugando — el await_target() de
	# esa selección queda esperando un click que nunca llega (correcto: una
	# decisión humana NO debería tener timeout), pero TriggerSystem.
	# awaiting_response/is_resolving se quedan atascados en true para
	# siempre, bloqueando el fin de CUALQUIER fase futura (el guard de
	# PhaseFlowController._on_priority_both_passed_main() hace su trabajo
	# correctamente, pero nunca hay nada que destrabe la causa real). Se
	# bloquea aquí en la raíz: mientras is_selecting_target sea true, el
	# jugador tiene que resolver el objetivo (o cancelar con ESC, si la
	# habilidad lo permite) antes de poder avanzar de fase.
	if _main._card_interaction and _main._card_interaction.is_selecting_target:
		_main._update_debug("Resuelve la selección de objetivo pendiente antes de pasar (ESC para cancelar si es opcional)")
		return

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
			if _try_recover_stuck_phase_priority_window():
				_main._update_debug("Ventana de prioridad recuperada — pulsa ¿Paso? de nuevo")
			else:
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

	# Efectos suspendidos de un solo uso agendados para ESTA Fase Final en
	# particular (2026-09-06, p.ej. Fisión Nuclear: 'En la próxima Fase
	# Final oponente, Baraja una carta de coste 2 o menos o Roba dos
	# cartas') — distinto de resolve_turn_end_triggers() de arriba, que
	# consulta cartas EN JUEGO; esto resuelve algo que quedó pendiente de
	# un Talismán ya Desterrado hace rato.
	await EffectController.consume_scheduled_final_phase_effects(player_id)

	# torii (2026-09-20, arquitectura.md "539 cartas sin cobertura"): "Si lo
	# haces, no Robas al finalizar tu turno" — bandera de una sola vez,
	# consumida ANTES del robo normal de Fase Final (ver OroAbilityPatterns.
	# gd, try_execute_torii_agrupacion_pattern()).
	if TriggerSystem._oro_patterns.should_skip_final_draw(player_id):
		_main._update_debug("Fase Final: jugador %d no roba (torii)" % (player_id + 1))
	elif GameManager.is_first_turn:
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
		await _discard_excess_by_click(excess)
	else:
		_opponent_auto_discard(excess)


func _discard_excess_by_click(amount: int) -> void:
	"""Descarte por límite de mano (DAR 5.D.4) — click directo sobre las
	cartas reales de la mano (2026-09-13, a pedido del usuario, mismo
	criterio ya usado para el resto de descartes de mano de la sesión, ver
	arquitectura.md §10.16/§10.29), en vez del modal de lista viejo de
	SelectionModule.open_discard_selection(). Reusa el helper compartido de
	TargetedEffectExecutor (mandatorio, cancellable=false)."""
	var hand_cards: Array = _main.player_hand.cards.duplicate()
	if hand_cards.is_empty():
		return
	amount = mini(amount, hand_cards.size())
	var to_discard: Array = await TriggerSystem._select_hand_cards_for_discard(hand_cards, amount)
	for card in to_discard:
		var discard_data: Dictionary = card.card_data.duplicate()
		discard_data["esta_oculta"] = false
		CardManager.add_to_cemetery(0, discard_data)
		# animate_card_to_cemetery() hace ella misma el remove_card() de la
		# mano como parte de la animación (ver ZoneManager.gd) y se niega a
		# animar si la carta ya no está en el árbol — por eso NO se saca de
		# la mano antes de llamarla; solo en el camino sin animación hace
		# falta sacarla a mano.
		if _main._zone_manager and is_instance_valid(card) and card.is_inside_tree() and card.visible:
			await _main._zone_manager.animate_card_to_cemetery(card, 0)
		else:
			_main.player_hand.remove_card(card, false)
		CardManager._disconnect_card_interaction_signals(card)
		card.queue_free()
	_main._update_debug("Descarte por límite de mano completado (%d carta(s))" % to_discard.size())
	_main._zone_manager._update_castillo_counts()


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
		# Ver comentario equivalente en _discard_excess_by_click(): la
		# animación hace su propio fan.remove_card() y se niega a animar si
		# la carta ya se sacó del árbol antes de llamarla.
		if _main._zone_manager and is_instance_valid(card) and card.is_inside_tree() and card.visible:
			await _main._zone_manager.animate_card_to_cemetery(card, 1)
		else:
			fan.remove_card(card, false)
		CardManager._disconnect_card_interaction_signals(card)
		card.queue_free()
	_main._update_debug("Oponente descarta %d carta(s) por límite de mano" % to_discard.size())
