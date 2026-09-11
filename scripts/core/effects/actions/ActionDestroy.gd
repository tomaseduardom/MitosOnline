extends RefCounted
## ActionDestroy — DESTROY (Destruir cartas, DAR Sección 8).
## Opera sobre ActionModule via _main (game board, trigger collection,
## validador, señales de AnimationQueue).
## Extraído de ActionModule.gd (Fase 4 de reestructuración, "módulos gordos").
## _check_destruction_prevention() solo la usa destroy() (banish() consulta
## EffectController.try_consume_opponent_effect_prevention() directo, un
## chequeo distinto) — se queda acá entera, sin necesidad de compartirla.

var _main: Node


func setup(main: Node) -> void:
	_main = main


func destroy(targets: Array, source: Node = null, can_be_prevented: bool = true, skip_validation: bool = false) -> Dictionary:
	"""Destruye cartas, enviándolas al Cementerio

	Args:
		targets: Array de cartas a destruir
		source: Carta/efecto que causa la destrucción
		can_be_prevented: Si puede ser prevenida por efectos
		skip_validation: Si omitir validación previa

	Returns: {success, destroyed, survived, prevented}
	"""
	var result = {
		"success": true,
		"destroyed": [],
		"survived": [],
		"prevented": []
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _main._validator._validate_destroy(targets, {"source_card": source})
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] DESTROY rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _main._get_game_board()

	_main._begin_trigger_collection()

	_main.emit_signal("action_destroy_started", targets, source)

	for target in targets:
		if not is_instance_valid(target):
			continue

		var can_destroy = true
		var prevented_by = null

		# Verificar si puede ser prevenida
		if can_be_prevented:
			var prevention = await _check_destruction_prevention(target, source)
			if prevention.prevented:
				can_destroy = false
				prevented_by = prevention.prevented_by
				result.prevented.append({"card": target, "by": prevented_by})

		if can_destroy:
			var from_zone = target.current_zone if target.get("current_zone") != null else Constants.Zone.LINEA_DEFENSA
			var owner_id = target.owner_id if target.get("owner_id") != null else 0

			# Trigger antes de destruir
			_main._notify_trigger("on_about_to_die", {
				"card": target,
				"source": source,
				"from_zone": from_zone
			})

			_main.emit_signal("action_destroy_card", target, source)

			AnimationQueue.add_command(AnimationQueue.CommandType.DESTROY_CARD, {
				"card": target,
				"source": source,
				"from_zone": from_zone
			})

			# ─────────────────────────────────────────────────────────────────
			# FLAG EXHUMAR: Cartas jugadas via Exhumar van a DESTIERRO
			# ─────────────────────────────────────────────────────────────────
			var destination = Constants.Zone.CEMENTERIO
			var card_data = target.get("card_data") if target.has_method("get") else target
			if card_data is Dictionary:
				if card_data.get("_exhumar_flag", false):
					destination = Constants.Zone.DESTIERRO
					print("[ActionModule] 💀 Carta con Exhumar destruida → DESTIERRO")
				elif card_data.get("_force_destination", -1) == Constants.Zone.DESTIERRO:
					destination = Constants.Zone.DESTIERRO

			if board:
				board.move_card(target, destination, owner_id)
			else:
				# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) —
				# EffectController.destroy_card()/exile_card() ya respetan la
				# regla de exhumación (is_exhumed) y mantienen los contadores
				# de UI sincronizados vía CardManager.
				if destination == Constants.Zone.DESTIERRO:
					await EffectController.exile_card(owner_id, target)
				else:
					await EffectController.destroy_card(owner_id, target)
			result.destroyed.append(target)

			# Trigger después de destruir
			_main._notify_trigger("on_destroyed", {
				"card": target,
				"source": source,
				"owner_id": owner_id
			})
		else:
			result.survived.append(target)

	_main.emit_signal("action_destroy_completed", result.destroyed, result.survived)

	await _main._end_trigger_collection_and_resolve()

	return result


func _check_destruction_prevention(target: Node, source: Node) -> Dictionary:
	"""Verifica si la destrucción puede ser prevenida"""
	var result = {"prevented": false, "prevented_by": null}

	# Verificar indestructible — vía KeywordManager.can_be_destroyed(),
	# no card.has_keyword() directo (2026-09-02, refactor: mismo motivo ya
	# documentado en ActionValidator._can_be_destroyed() — un silenciado
	# que le quite Indestructible por KeywordManager no se respetaba acá,
	# porque card.has_keyword() no mira los overrides de KeywordManager).
	if not KeywordManager.can_be_destroyed(target):
		result.prevented = true
		result.prevented_by = target
		return result

	# Verificar protección
	if target.has_method("has_protection_from"):
		if source and target.has_protection_from(source):
			result.prevented = true
			result.prevented_by = target
			return result

	# Prevención reactiva real (2026-09-09, "sistema de respuestas" —
	# Estaca): se pregunta al jugador EN EL MOMENTO, no una carga previa.
	if await EffectController.offer_prevention(target, source, "destroy"):
		result.prevented = true
		result.prevented_by = target
		return result

	return result
