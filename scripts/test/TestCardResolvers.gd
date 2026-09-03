extends RefCounted
class_name TestCardResolvers
## TestCardResolvers — Flujo de resolución de talismanes/cartas de elección
## del escenario de pruebas (Pasos A-E del DAR). Opera sobre el estado de
## TestScene via _main. Extraído de TestScene.gd (Fase 4 de reestructuración).

var _main: Control


func setup(main: Control) -> void:
	_main = main


# =============================================================================
# RESOLUCIÓN DE CARTAS
# =============================================================================
func resolve_talisman(card_data: Dictionary) -> void:
	"""Resuelve un talismán y sus efectos siguiendo el flujo DAR"""
	var card_name = card_data.get("name", "???")

	_main._log("═══════════════════════════════════════════════")
	_main._log("RESOLVIENDO TALISMÁN: %s" % card_name)
	_main._log("═══════════════════════════════════════════════")

	# Verificar si tiene choice_config
	var choice_config = card_data.get("choice_config", {})

	if not choice_config.is_empty():
		await _resolve_choice_card(card_data)
	else:
		_main._log("Talismán resuelto (sin efectos especiales)")

	# =========================================================================
	# DESTINO FINAL (Sección 8 vs Sección 17)
	# =========================================================================
	_main._log("───────────────────────────────────────────────")
	_main._log("DESTINO FINAL:")

	# Sección 8: Si fue anulada, el destino propio de la carta tiene prioridad
	if _main._was_annulled:
		# El destino ya fue calculado considerando BANISH_SELF
		var final_dest = _main._response_result.get("annul_destination", "CEMENTERIO")

		match final_dest:
			"DESTIERRO":
				_main._move_to_exile(card_data)
				_main._log("[SECCIÓN 8] %s → DESTIERRO (anulada, pero carta dice destiérrala)" % card_name)
			_:
				_main._move_to_grave(card_data)
				_main._log("[SECCIÓN 8] %s → CEMENTERIO (anulada)" % card_name)

		_main._log("  • El pipeline fue cancelado")
		_main._log("  • Efectos no se resolvieron")
		_main._was_annulled = false  # Reset flag
	else:
		# Sección 17: Destino según condición on_resolution
		# Usar ActionExecutor para determinar destino correcto
		var executor = _main._get_action_executor()
		var final_dest = "CEMENTERIO"

		if executor:
			final_dest = executor.get_final_destination(card_data)

		match final_dest:
			"DESTIERRO":
				_main._move_to_exile(card_data)
				if executor and executor.is_played_via_exhumar():
					_main._log("[EXHUMAR] %s → DESTIERRO (jugada via Exhumar)" % card_name)
				else:
					_main._log("[SECCIÓN 17] %s → DESTIERRO" % card_name)
					_main._log("  • Condición: BANISH_SELF cumplida")
			"MANO":
				# TODO: Implementar retorno a mano
				_main._log("[SECCIÓN 17] %s → MANO (no implementado)" % card_name)
			"CASTILLO":
				# TODO: Implementar retorno al mazo
				_main._log("[SECCIÓN 17] %s → MAZO (no implementado)" % card_name)
			_:
				_main._move_to_grave(card_data)
				_main._log("[SECCIÓN 17] %s → CEMENTERIO (por defecto)" % card_name)

	_main._log("═══════════════════════════════════════════════")

	# Remover carta visual de la mano
	if _main.selected_card:
		_main.selected_card.queue_free()
		_main.selected_card = null

	# Remover de player_hand
	var idx = -1
	for i in range(_main.player_hand.size()):
		if _main.player_hand[i].get("name", "") == card_name or _main.player_hand[i].get("nombre", "") == card_name:
			idx = i
			break
	if idx >= 0:
		_main.player_hand.remove_at(idx)


func _resolve_choice_card(card_data: Dictionary) -> void:
	"""Resuelve una carta con sistema de elección"""
	var choice_config = card_data.get("choice_config", {})
	var amount_to_choose = choice_config.get("amount_to_choose", 1)
	var options = choice_config.get("options", [])
	var card_name = card_data.get("name", "???")

	if options.is_empty():
		_main._log("[ERROR] Carta sin opciones definidas")
		return

	# Guardar referencia a carta actual
	_main._current_card_data = card_data
	_main._was_annulled = false

	# =========================================================================
	# REGISTRAR EN PIPELINE (expuesta a respuestas)
	# =========================================================================
	var executor = _main._get_action_executor()
	if executor:
		executor.enter_pipeline(card_data, {
			"controller_id": _main.active_player,
			"phase": "choice"
		})

	# =========================================================================
	# PASO A: Jugador elige efectos
	# =========================================================================
	_main._log("[PASO A] Elige %d opción(es):" % amount_to_choose)

	var formatted_options: Array = []
	for opt in options:
		formatted_options.append({
			"id": opt.get("id", ""),
			"text": opt.get("text", "???")
		})

	await _main._ui_builder.show_choice_ui("Elige %d efectos:" % amount_to_choose, formatted_options, amount_to_choose)

	if _main._selected_choices.size() < amount_to_choose:
		_main._log("[WARN] Selección incompleta")
		return

	# Guardar efectos pendientes
	_main._pending_effects.clear()
	for choice_id in _main._selected_choices:
		for opt in options:
			if opt.get("id", "") == choice_id:
				_main._pending_effects.append(opt)
				break

	_main._log("[PASO A] Efectos elegidos: %s" % str(_main._selected_choices))

	# =========================================================================
	# ACTUALIZAR PIPELINE con efectos pendientes
	# =========================================================================
	if executor:
		var ctx = executor.get_pipeline_context()
		ctx["pending_effects"] = _main._pending_effects.duplicate()
		ctx["phase"] = "waiting_response"

	# =========================================================================
	# SINCRONIZACIÓN: Enviar efectos al oponente
	# =========================================================================
	_sync_effects_to_opponent(card_data, _main._pending_effects)

	# =========================================================================
	# PASO D: Ventana de respuesta del oponente
	# =========================================================================
	_main._log("[PASO D] Ventana de respuesta - Oponente puede responder...")

	var response_result = await _main._ui_builder.open_response_window(card_name, _main._pending_effects)

	# =========================================================================
	# SECCIÓN 8: Verificar si hubo ANULACIÓN
	# =========================================================================
	if response_result.had_response and response_result.get("is_annullment", false):
		_main._log("[ANULACIÓN] ¡%s fue ANULADA!" % card_name)
		_main._was_annulled = true
		_main._pending_effects.clear()
		# La carta va al cementerio, no al destierro
		return

	if response_result.had_response:
		_main._log("[PASO D] Oponente respondió (no fue anulación)")
	else:
		_main._log("[PASO D] Oponente pasó")

	# =========================================================================
	# PASO E: Resolución - Ejecutar efectos (Sección 17 - Condición)
	# =========================================================================
	if not _main._was_annulled:
		_main._log("[PASO E] ═══════════════════════════════════════")
		_main._log("[PASO E] RESOLUCIÓN - Oponente pasó prioridad")
		_main._log("[PASO E] Ejecutando %d efecto(s)..." % _main._pending_effects.size())

		# Emitir señal de inicio de resolución
		_main._get_action_executor_emit("resolution_started", null, _main._pending_effects)

		var effects_resolved: int = 0
		for effect_opt in _main._pending_effects:
			effects_resolved += 1
			_main._log("[PASO E] Efecto %d/%d:" % [effects_resolved, _main._pending_effects.size()])
			await _execute_choice_action(effect_opt)
			# Pequeña pausa entre efectos para visualización
			await _main.get_tree().create_timer(0.3).timeout

		_main._log("[PASO E] ✓ Todos los efectos resueltos (%d/%d)" % [effects_resolved, _main._pending_effects.size()])
		_main._log("[PASO E] ═══════════════════════════════════════")

		# Emitir señal de resolución completada
		_main._get_action_executor_emit("resolution_completed", null, true, effects_resolved)

		# Sección 17: Verificar condición post-resolución
		_check_post_resolution_condition(card_data)

	_main._pending_effects.clear()
	_main._current_card_data = {}

	# =========================================================================
	# SALIR DEL PIPELINE
	# =========================================================================
	var executor_exit = _main._get_action_executor()
	if executor_exit:
		executor_exit.exit_pipeline()


func _execute_choice_action(option: Dictionary) -> void:
	"""Ejecuta la acción de una opción elegida"""
	var action = option.get("action", {})
	var action_type = action.get("type", "")
	var value = action.get("value", 1)
	var target = action.get("target", "SELF")

	_main._log("Ejecutando: %s" % option.get("text", "???"))

	var player_id = 0 if target == "SELF" else 1

	match action_type:
		"DRAW":
			await _main._execute_draw(player_id, value)
		"MILL":
			await _main._execute_mill(player_id, value)
		"SEARCH":
			var zone = action.get("zone", "DECK")
			var filter = action.get("filter", {})
			await _main._execute_search(player_id, zone, filter, value)
		"DESTROY":
			_main._log("[TODO] Destruir implementación")
		"DAMAGE":
			_main._log("[TODO] Daño implementación")
		_:
			_main._log("[WARN] Acción no implementada: %s" % action_type)


# =============================================================================
# SECCIÓN 17 - CONDICIÓN POST-RESOLUCIÓN
# =============================================================================
func _check_post_resolution_condition(card_data: Dictionary) -> void:
	"""Verifica y aplica condiciones post-resolución (Sección 17)

	Después de que todos los efectos se resuelven, se verifican
	las condiciones especiales de la carta (ej: BANISH_SELF).
	"""
	var card_name = card_data.get("name", card_data.get("nombre", "???"))
	var on_resolution = card_data.get("on_resolution", "")

	if on_resolution.is_empty():
		return

	_main._log("[SECCIÓN 17] Verificando condición post-resolución...")

	var destination = "GRAVEYARD"

	match on_resolution:
		"BANISH_SELF":
			destination = "EXILE"
			_main._log("[SECCIÓN 17] Condición: BANISH_SELF")
			_main._log("[SECCIÓN 17] → '%s' será desterrada tras resolución" % card_name)
		"RETURN_TO_HAND":
			destination = "HAND"
			_main._log("[SECCIÓN 17] Condición: RETURN_TO_HAND")
			_main._log("[SECCIÓN 17] → '%s' volverá a la mano tras resolución" % card_name)
		"RETURN_TO_DECK":
			destination = "DECK"
			_main._log("[SECCIÓN 17] Condición: RETURN_TO_DECK")
			_main._log("[SECCIÓN 17] → '%s' volverá al mazo tras resolución" % card_name)
		"DESTROY_SELF":
			destination = "GRAVEYARD"
			_main._log("[SECCIÓN 17] Condición: DESTROY_SELF")
			_main._log("[SECCIÓN 17] → '%s' será destruida tras resolución" % card_name)
		_:
			_main._log("[SECCIÓN 17] Condición: %s (default → cementerio)" % on_resolution)

	# Emitir señal para sistemas externos
	_main._get_action_executor_emit("post_resolution_condition", null, on_resolution, destination)


func _process_annullment(annuller_card_data: Dictionary) -> void:
	"""Procesa una anulación del oponente (Sección 8)

	Args:
		annuller_card_data: Datos de la carta de anulación
	"""
	var card_name = _main._current_card_data.get("name", "???")
	var annuller_name = annuller_card_data.get("name", "Anulación")

	_main._log("[SECCIÓN 8] %s ANULA a %s" % [annuller_name, card_name])

	# Marcar como anulada
	_main._was_annulled = true

	# Cancelar efectos pendientes
	_main._log("[ANULACIÓN] Pipeline cancelado - %d efectos no se resolverán" % _main._pending_effects.size())
	_main._pending_effects.clear()

	# Emitir señal
	_main._get_action_executor_emit("spell_annulled", null, null)


func _sync_effects_to_opponent(card_data: Dictionary, effects: Array) -> void:
	"""Sincroniza la selección de efectos con el cliente del oponente

	En una partida real, esto enviaría los datos por red.
	El oponente verá qué efectos se intentarán resolver.
	"""
	var card_name = card_data.get("name", card_data.get("nombre", "???"))

	_main._log("[SYNC] Enviando efectos al oponente:")
	for eff in effects:
		_main._log("  → %s" % eff.get("text", "???"))

	# Usar ActionExecutor para emitir señal de sincronización
	_main._get_action_executor_sync(_main.active_player, card_data, effects)
