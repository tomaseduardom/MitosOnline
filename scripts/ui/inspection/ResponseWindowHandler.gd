extends RefCounted
class_name ResponseWindowHandler
## ResponseWindowHandler — Overlays de "ventana de respuesta": Paso D
## genérico (ActionPipeline.step_d_waiting, para habilidades activadas/cartas
## jugadas en la Pila) y el caso especial de Signo Amarillo (2026-08-26,
## TriggerSystem.waiting_for_responses, para triggers ETB de Oro/fuera del
## juego — señal separada porque TriggerResolution._wait_for_response_window()
## solo la emite cuando de verdad hay algo que pueda responder).
## Opera sobre CardInspectionLayer via _inspector (y sobre el Main del juego
## via _inspector._main).
## Extraído de CardInspectionLayer.gd (2026-08-28, "módulos gordos").

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _on_step_d_waiting(stack_obj: Dictionary, priority_player: int) -> void:
	# Pila de Respuesta Universal (2026-09-09, Capa 1 — ver docs/plans/
	# 2026-09-09-pila-respuesta-universal-design.md): con la migración de los
	# patrones de trigger, esta ventana ya puede abrirse para CUALQUIERA de
	# los dos jugadores (antes, en la práctica, priority_player siempre
	# terminaba siendo el humano, porque nada disparado por el bot llegaba
	# hasta aquí). Si le toca al bot, todavía no tiene ninguna lógica real de
	# "¿quiero responder con algo?" (Capa 2, pendiente) — pasa siempre, pero
	# por el camino REAL de PriorityManager (no el auto-pase ciego de antes),
	# para no romper la secuencia de "ambos pasan consecutivamente" que
	# ActionPipeline espera.
	if priority_player != 0:
		# 2026-09-15: se captura la generación de ESTA ventana (ver
		# PriorityManager._window_generation) — mismo motivo que
		# PhaseFlowController._human_pass_after(), ver ese comentario.
		_bot_pass_after(0.15, PriorityManager._window_generation)  # bajado de 0.3s, 2026-09-11 — cadenas de varias cartas acumulaban demora
		return

	# 2026-09-11 (a pedido del usuario): el botón único ¿Paso?/Atacar del HUD
	# (GameHUDModule) ya se pone visible y brilla solo apenas la prioridad es
	# tuya, y PhaseFlowController._on_priority_changed_glow() ya se encarga
	# del auto-pase "no hay nada que decidir" — dejó de hacer falta un panel
	# propio aquí solo para pasar. Lo único que sigue necesitando UI propia es
	# la oferta de Signo Amarillo (cancelar convirtiendo un Oro): es una
	# decisión real, así que se ofrece como diálogo reactivo, y suprime ese
	# auto-pase mientras espera tu click (ver _offer_signo_amarillo_for_step_d).
	if _qualifies_for_signo_amarillo(stack_obj):
		_offer_signo_amarillo_for_step_d(stack_obj)


func _offer_signo_amarillo_for_step_d(stack_obj: Dictionary) -> void:
	var signo_card := _find_signo_amarillo_in_reserve(0)
	if not signo_card:
		return
	# Suprime cualquier auto-pase "no hay nada que decidir" mientras este
	# diálogo real está esperando un click — ver PriorityManager.
	# suppress_human_autopass (2026-09-11).
	#
	# 'scheduled_for_generation' (mismo motivo que _bot_pass_after(), ver su
	# comentario): si se abre una ventana NUEVA mientras este diálogo
	# esperaba el click (dos oportunidades de Signo Amarillo seguidas), esa
	# ventana nueva puede haber puesto suppress_human_autopass=true para SU
	# PROPIO diálogo — resetearlo sin este chequeo lo apaga por debajo.
	var scheduled_for_generation: int = PriorityManager._window_generation
	PriorityManager.suppress_human_autopass = true
	var ability_name: String = stack_obj.get("name", "esta habilidad")
	var use_it: bool = await SelectionManager.await_two_choice(
		_inspector._main,
		"¿Convertir %s en un Oro sin habilidad para cancelar %s?" % [str(signo_card.card_name), ability_name],
		"Sí, cancelar", "No")
	if PriorityManager._window_generation == scheduled_for_generation:
		PriorityManager.suppress_human_autopass = false
	if not use_it:
		return
	if not PriorityManager.priority_window_active:
		return  # la ventana ya se cerró mientras decidías (p.ej. pasaste con el botón)
	signo_card.is_converted = true
	ActionPipeline.cancel_stack_object(stack_obj.get("id", -1))
	if PriorityManager.priority_window_active:
		PriorityManager.pass_priority()


func _bot_pass_after(delay: float, scheduled_for_generation: int) -> void:
	"""Capa 2 de la Pila de Respuesta Universal (2026-09-09): antes de pasar,
	el bot intenta responder de verdad con una habilidad activada propia
	(ver EasyBotController.try_respond_with_activated_ability(), alcance v1
	documentado ahí) — Prevención se maneja aparte, en su propio choke point
	(EffectController.offer_prevention_for_player()), no aquí. Si usó algo,
	ese objeto ya quedó en el tope de ActionPipeline y el propio loop de
	StackStepResolver lo detecta solo como "hubo respuesta" — no corresponde
	pasar. Si no, pasa por el camino REAL de PriorityManager (no un atajo
	que ignore de quién es el turno), con un pequeño delay solo para que no
	se sienta instantáneo/confuso en pantalla — sin ninguna intención de
	ocultar información (el usuario confirmó que el timing contra el bot no
	importa).
	'scheduled_for_generation' (2026-09-15, bug real reportado por el
	usuario: "se traba en Guerra de Talismanes" sin ningún click — ver
	PriorityManager._window_generation): si la ventana para la que se
	programó este timer ya cerró y se abrió una ventana NUEVA antes de que
	termine la espera, no hay que tocarla — aunque priority_window_active
	siga siendo true, es de la ventana NUEVA, no la que este timer estaba
	mirando."""
	await _inspector.get_tree().create_timer(delay).timeout
	if PriorityManager._window_generation != scheduled_for_generation:
		return
	if not PriorityManager.priority_window_active:
		return
	if _inspector._main._easy_bot and await _inspector._main._easy_bot.try_respond_with_activated_ability():
		return
	if PriorityManager._window_generation == scheduled_for_generation and PriorityManager.priority_window_active:
		PriorityManager.pass_priority()
		await _inspector.get_tree().create_timer(0.15).timeout  # bajado de 0.35s, 2026-09-11
		if PriorityManager._window_generation == scheduled_for_generation and PriorityManager.priority_window_active:
			PriorityManager.pass_priority()


func _qualifies_for_signo_amarillo(stack_obj: Dictionary) -> bool:
	"""¿La fuente de este objeto de la Pila es un Oro, o una carta fuera del
	juego (Mano/Destierro/Cementerio/Castillo)? Esas dos categorías son las
	que Signo Amarillo puede cancelar (2026-08-26, texto real de la carta)."""
	var context: Dictionary = stack_obj.get("context", {})
	var source_data: Dictionary = context.get("source_card", stack_obj.get("card_data", {}))
	if source_data.get("tipo", -1) == Constants.CardType.ORO:
		return true
	var source_node = context.get("source_card_node")
	if source_node and is_instance_valid(source_node):
		var off_board_zones = [Constants.Zone.MANO, Constants.Zone.DESTIERRO, Constants.Zone.CEMENTERIO, Constants.Zone.CASTILLO]
		return source_node.get("current_zone") in off_board_zones
	return false


func _find_signo_amarillo_in_reserve(player_id: int) -> Node:
	"""Busca en la Reserva de Oro de player_id un Oro con el texto de Signo
	Amarillo que todavía no se haya convertido — detección por texto, no por
	nombre, para cubrir cualquier carta con el mismo patrón."""
	var container = _inspector._main.player_gold if player_id == 0 else _inspector._main.opponent_gold
	if not container:
		return null
	for c in container.get_children():
		if not is_instance_valid(c) or c.get("is_converted") == true:
			continue
		var ability_text: String = str(c.get("card_ability") if c.get("card_ability") != null else "")
		if "convertir este oro en un oro sin habilidad" in ability_text.to_lower():
			return c
	return null


func _on_trigger_waiting_for_responses(trigger: Dictionary, responding_player: int) -> void:
	"""Ventana de respuesta para triggers ETB de Oro/fuera del juego
	(2026-08-26).

	2026-09-19, §10.53: SIN LLAMADOR HOY A PROPÓSITO — TriggerSystem.
	waiting_for_responses ya no se emite (TriggerResolution.resolve_next_
	trigger() pasó a abrir una ventana real vía open_response_window(), a
	pedido del usuario), así que esta función no se vuelve a llamar. NO
	BORRAR sin más: si volviera a emitirse esa señal por error, el 'Sí,
	cancelar' de este diálogo llamaría a TriggerSystem.cancel_current_
	trigger(), que solo _wait_for_response_window() (huérfana también, ver su
	docstring) llegaba a leer — quedaría un diálogo clickeable que no cancela
	nada de verdad. Signo Amarillo para triggers se sigue ofreciendo bien hoy
	por el camino nuevo: _offer_signo_amarillo_for_step_d() más abajo, que
	escucha ActionPipeline.step_d_waiting (open_response_window() sí la
	emite, para cualquier objeto de la Pila).

	Antes (2026-08-26 a 2026-09-19): TriggerResolution._wait_for_response_
	window() solo emitía esta señal cuando de verdad había algo que pudiera
	responder (un Signo Amarillo sin convertir), así que si no lo encontraba
	aquí algo había cambiado de estado entremedio.

	2026-09-11 (a pedido del usuario): reemplazó el panel flotante por un
	diálogo reactivo (mismo criterio que _offer_signo_amarillo_for_step_d) —
	esta ventana no tenía botón ¿Paso? propio (se resolvía sola a los 8s vía
	TriggerResolution._wait_for_response_window()), así que responder "No"
	ahí adelantaba ese pase en vez de forzar la espera completa."""
	if responding_player != 0:
		return  # el bot no usa Signo Amarillo todavía
	var signo_card := _find_signo_amarillo_in_reserve(responding_player)
	if not signo_card:
		return
	var source_card: Node = trigger.get("card")
	var card_name: String = str(source_card.card_name) if source_card and is_instance_valid(source_card) else "esta habilidad"
	var use_it: bool = await SelectionManager.await_two_choice(
		_inspector._main,
		"¿Convertir %s en un Oro sin habilidad para cancelar %s?" % [str(signo_card.card_name), card_name],
		"Sí, cancelar", "No")
	if not TriggerSystem.awaiting_response:
		return  # ya se resolvió solo (timeout de 8s) mientras decidías
	if use_it:
		signo_card.is_converted = true
		TriggerSystem.cancel_current_trigger(signo_card)
	else:
		TriggerSystem.pass_response()
