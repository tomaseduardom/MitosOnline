extends RefCounted
## ActionBanish — BANISH (Desterrar cartas, DAR Sección 8).
## Opera sobre ActionModule via _main (game board, trigger collection,
## validador, señales de AnimationQueue).
## Extraído de ActionModule.gd (Fase 4 de reestructuración, "módulos gordos").

var _main: Node


func setup(main: Node) -> void:
	_main = main


func banish(targets: Array, source: Node = null, skip_validation: bool = false, can_be_prevented: bool = true) -> Dictionary:
	"""Destierra cartas, enviándolas al Destierro (zona de exilio)
	Las cartas desterradas no pueden ser recuperadas por medios normales

	Args:
		targets: Array de cartas a desterrar
		source: Carta/efecto que causa el destierro
		skip_validation: Si omitir validación previa
		can_be_prevented: Si puede ser prevenida por Estaca — false cuando
			el llamador YA resolvió su propia Prevención específica antes
			de llegar acá (2026-09-09, p.ej. TargetedEffectExecutor.
			_execute_targeted_annul(): Anular solo lo previene Drácula, no
			Estaca, así que pasa false para no volver a preguntar acá).
			AL FINAL a propósito, no antes de skip_validation: los ~15
			llamadores existentes ya pasan 'true' como tercer argumento
			posicional para skip_validation — insertar un parámetro ANTES
			de esa posición correría ese 'true' a can_be_prevented sin que
			ningún llamador lo pidiera, dejando skip_validation=false en
			todos ellos por accidente.

	Returns: {success, banished, failed}
	"""
	var result = {
		"success": true,
		"banished": [],
		"failed": []
	}

	# DAR Sección 6: Validar estado del juego
	if not skip_validation:
		var validation = _main._validator._validate_banish(targets)
		if not validation.valid:
			result.success = false
			result.error = validation.reason
			result.validation_failed = true
			print("[ActionModule] BANISH rechazado: %s" % validation.reason)
			return result
		if not validation.warnings.is_empty():
			result.warnings = validation.warnings

	var board = _main._get_game_board()

	_main._begin_trigger_collection()

	_main.emit_signal("action_banish_started", targets, source)

	for target in targets:
		if not is_instance_valid(target):
			result.failed.append({"card": target, "reason": "invalid"})
			continue

		# Prevención reactiva real (2026-09-09 — Estaca), mismo chequeo que
		# destroy(). can_be_prevented=false cuando el llamador ya resolvió
		# su propia Prevención específica (ver docstring de arriba).
		if can_be_prevented and await EffectController.offer_prevention(target, source, "exile"):
			result.failed.append({"card": target, "reason": "prevented"})
			continue

		var from_zone = target.current_zone if target.get("current_zone") != null else -1
		var owner_id = target.owner_id if target.get("owner_id") != null else 0

		_main.emit_signal("action_banish_card", target, from_zone)

		AnimationQueue.add_command(AnimationQueue.CommandType.EXILE_CARD, {
			"card": target,
			"source": source,
			"from_zone": from_zone
		})

		if board:
			board.move_card(target, Constants.Zone.DESTIERRO, owner_id)
		else:
			# GameBoard legacy no disponible (docs/audit, hallazgo 2/4)
			await EffectController.exile_card(owner_id, target)
		result.banished.append(target)

		_main._notify_trigger("on_exiled", {
			"card": target,
			"source": source,
			"owner_id": owner_id,
			"from_zone": from_zone
		})

	_main.emit_signal("action_banish_completed", result.banished)

	await _main._end_trigger_collection_and_resolve()

	return result
