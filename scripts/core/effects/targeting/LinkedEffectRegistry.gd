extends RefCounted
class_name LinkedEffectRegistry
## LinkedEffectRegistry — Vincula una carta de respuesta (Anular/Cancelar)
## con su objetivo en la pila y ejecuta el efecto cuando la respuesta
## resuelve (DAR Sección 8). Opera sobre TargetSelector via _main
## (ActionPipeline, señales). Extraído de TargetSelector.gd (Fase 4).

var _main: Node

## Almacena las vinculaciones activas: {response_stack_id: LinkedEffect}
var _linked_effects: Dictionary = {}


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# VINCULACIÓN DE EFECTO (Sección 8)
# =============================================================================
func link_effect(response_stack_id: int, target_stack_id: int,
				  effect_type, source_card: Dictionary) -> bool:
	"""Vincula una carta de respuesta con su objetivo en la pila

	Cuando la carta de respuesta se resuelva, ejecutará annul() o cancel()
	sobre el objetivo vinculado.

	Args:
		response_stack_id: ID de la carta de respuesta en la pila
		target_stack_id: ID del objetivo a afectar
		effect_type: ANNUL o CANCEL
		source_card: Datos de la carta de respuesta

	Returns:
		true si la vinculación fue exitosa
	"""
	if response_stack_id <= 0 or target_stack_id <= 0:
		push_error("[TargetSelector] IDs inválidos para vinculación")
		return false

	if effect_type not in [_main.SelectionType.ANNUL, _main.SelectionType.CANCEL]:
		push_error("[TargetSelector] Tipo de efecto inválido para vinculación")
		return false

	# Verificar que el objetivo existe y es válido
	if _main._action_pipeline:
		var target_obj = _main._action_pipeline.get_object_by_id(target_stack_id)
		if target_obj.is_empty():
			push_error("[TargetSelector] Objetivo #%d no encontrado en la pila" % target_stack_id)
			return false

		# Crear vinculación
		var link = LinkedEffect.new()
		link.response_stack_id = response_stack_id
		link.target_stack_id = target_stack_id
		link.effect_type = effect_type
		link.source_card = source_card.duplicate(true)
		link.target_card = target_obj.get("card_data", {}).duplicate(true)
		link.created_at = Time.get_ticks_msec()
		link.is_pending = true

		_linked_effects[response_stack_id] = link

		print("[TargetSelector] ═══ EFECTO VINCULADO ═══")
		print("[TargetSelector] Respuesta #%d → Objetivo #%d (%s)" % [
			response_stack_id,
			target_stack_id,
			"ANULAR" if effect_type == _main.SelectionType.ANNUL else "CANCELAR"
		])

		_main.emit_signal("effect_linked", response_stack_id, target_stack_id, effect_type)
		return true

	return false


func get_linked_effect(response_stack_id: int) -> LinkedEffect:
	"""Obtiene la vinculación de efecto para una carta de respuesta"""
	if _linked_effects.has(response_stack_id):
		return _linked_effects[response_stack_id]
	return null


func has_linked_effect(response_stack_id: int) -> bool:
	"""Verifica si una carta de respuesta tiene un efecto vinculado"""
	return _linked_effects.has(response_stack_id)


func execute_linked_effect(response_stack_id: int) -> bool:
	"""Ejecuta el efecto vinculado cuando la carta de respuesta se resuelve

	Llama a annul() o cancel() en el ActionPipeline sobre el objetivo.

	Returns:
		true si el efecto se ejecutó exitosamente
	"""
	if not _linked_effects.has(response_stack_id):
		print("[TargetSelector] No hay efecto vinculado para #%d" % response_stack_id)
		return false

	var link: LinkedEffect = _linked_effects[response_stack_id]

	if not link.is_pending:
		print("[TargetSelector] Efecto #%d ya fue ejecutado" % response_stack_id)
		return false

	if not _main._action_pipeline:
		push_error("[TargetSelector] ActionPipeline no disponible")
		return false

	var target_id = link.target_stack_id
	var success = false

	# Verificar que el objetivo sigue en la pila
	var target_obj = _main._action_pipeline.get_object_by_id(target_id)
	if target_obj.is_empty():
		print("[TargetSelector] Objetivo #%d ya no está en la pila (fizzle)" % target_id)
		link.is_pending = false
		_main.emit_signal("effect_executed", response_stack_id, target_id, false)
		return false

	# Verificar que no fue ya procesado
	if target_obj.get("was_annulled", false) or target_obj.get("was_cancelled", false):
		print("[TargetSelector] Objetivo #%d ya fue anulado/cancelado" % target_id)
		link.is_pending = false
		_main.emit_signal("effect_executed", response_stack_id, target_id, false)
		return false

	# Ejecutar según tipo
	match link.effect_type:
		_main.SelectionType.ANNUL:
			success = _execute_annul(target_id, link.source_card)

		_main.SelectionType.CANCEL:
			success = _execute_cancel(target_id, link.source_card)

	link.is_pending = false

	print("[TargetSelector] Efecto %s sobre #%d: %s" % [
		"ANULAR" if link.effect_type == _main.SelectionType.ANNUL else "CANCELAR",
		target_id,
		"ÉXITO" if success else "FALLÓ"
	])

	_main.emit_signal("effect_executed", response_stack_id, target_id, success)

	return success


func _execute_annul(target_stack_id: int, source_card: Dictionary) -> bool:
	"""Ejecuta ANULAR sobre un objetivo (Sección 8)

	La carta objetivo no se resuelve y va al Cementerio.
	"""
	if not _main._action_pipeline:
		return false

	# Prevención de Drácula (2026-08-30): "prevenir que ... un Aliado de
	# coste 1 sea Anulado" — solo cubre Aliados de coste 1 exactamente,
	# consume la carga del jugador DUEÑO del objetivo (no del que anula).
	var pre_obj := _main._action_pipeline.get_object_by_id(target_stack_id)
	if not pre_obj.is_empty():
		var pre_data: Dictionary = pre_obj.get("card_data", {})
		var pre_controller: int = pre_obj.get("context", {}).get("controller_id", 0)
		if int(pre_data.get("tipo", -1)) == Constants.CardType.ALIADO and int(pre_data.get("coste", -1)) == 1:
			if EffectController.try_consume_stack_annul_cancel_prevention(pre_controller):
				return false

	# Llamar al ActionPipeline para marcar como anulado
	if _main._action_pipeline.has_method("apply_special_action"):
		_main._action_pipeline.apply_special_action({
			"type": "nullify",
			"target_stack_id": target_stack_id,
			"source_card": source_card
		})
		return true

	# Fallback: marcar directamente
	var target_obj = _main._action_pipeline.get_object_by_id(target_stack_id)
	if not target_obj.is_empty():
		target_obj.was_annulled = true
		target_obj.annuller = source_card
		if _main._action_pipeline.has_signal("object_annulled"):
			_main._action_pipeline.emit_signal("object_annulled", target_obj, source_card)
		return true

	return false


func _execute_cancel(target_stack_id: int, source_card: Dictionary) -> bool:
	"""Ejecuta CANCELAR sobre un objetivo (Sección 8)

	La habilidad objetivo no se resuelve.
	"""
	if not _main._action_pipeline:
		return false

	var pre_obj := _main._action_pipeline.get_object_by_id(target_stack_id)
	if not pre_obj.is_empty():
		var pre_ctx: Dictionary = pre_obj.get("context", {})
		var pre_source: Dictionary = pre_ctx.get("source_card", {})
		# "Las habilidades de este Oro no pueden ser canceladas" (2026-08-30,
		# Drácula) — protección ESTÁTICA de sus propias habilidades, no una
		# carga: se revisa el texto de la carta DUEÑA de la habilidad objetivo
		# (pre_source, no target_obj.card_data — eso es la habilidad en sí,
		# no la carta que la tiene).
		var pre_source_ability: String = str(pre_source.get("habilidad", "")).to_lower()
		if "no pueden ser canceladas" in pre_source_ability:
			return false
		# Prevención de Drácula (2026-08-30): "prevenir que una habilidad sea
		# cancelada" — carga consumible, cualquier habilidad propia.
		if EffectController.try_consume_stack_annul_cancel_prevention(pre_ctx.get("controller_id", 0)):
			return false

	# Llamar al ActionPipeline
	if _main._action_pipeline.has_method("apply_special_action"):
		_main._action_pipeline.apply_special_action({
			"type": "cancel",
			"target_stack_id": target_stack_id,
			"source_card": source_card,
			"reason": "cancelled_by_effect"
		})
		return true

	# Fallback: marcar directamente
	var target_obj = _main._action_pipeline.get_object_by_id(target_stack_id)
	if not target_obj.is_empty():
		target_obj.was_cancelled = true
		target_obj.cancel_reason = "cancelled_by_%s" % source_card.get("nombre", "effect")
		if _main._action_pipeline.has_signal("object_cancelled"):
			_main._action_pipeline.emit_signal("object_cancelled", target_obj)
		return true

	return false


func remove_linked_effect(response_stack_id: int) -> void:
	"""Remueve una vinculación de efecto"""
	if _linked_effects.has(response_stack_id):
		_linked_effects.erase(response_stack_id)


func clear_all_linked_effects() -> void:
	"""Limpia todas las vinculaciones (para nuevo juego)"""
	_linked_effects.clear()


# =============================================================================
# CALLBACKS DE ACTIONPIPELINE - Ejecución automática de efectos vinculados
# =============================================================================
func _on_stack_object_resolving(stack_obj: Dictionary) -> void:
	"""Cuando un objeto comienza a resolver, ejecutar efecto vinculado si existe"""
	var stack_id = stack_obj.get("id", -1)

	# Si es una carta de respuesta con efecto vinculado, ejecutarlo
	if has_linked_effect(stack_id):
		print("[TargetSelector] Carta de respuesta #%d resolviendo - ejecutando efecto vinculado" % stack_id)
		execute_linked_effect(stack_id)


func _on_stack_object_resolved(stack_obj: Dictionary, _result: Dictionary) -> void:
	"""Cuando un objeto termina de resolver"""
	var stack_id = stack_obj.get("id", -1)

	# Limpiar vinculación usada
	remove_linked_effect(stack_id)


func _on_stack_object_removed(stack_obj: Dictionary, reason: String) -> void:
	"""Cuando un objeto es removido de la pila"""
	var stack_id = stack_obj.get("id", -1)

	# Si el objetivo de una vinculación fue removido, la vinculación hace fizzle
	for response_id in _linked_effects.keys():
		var link: LinkedEffect = _linked_effects[response_id]
		if link.target_stack_id == stack_id and link.is_pending:
			print("[TargetSelector] Objetivo #%d removido (%s) - vinculación #%d hace fizzle" % [
				stack_id, reason, response_id
			])
			link.is_pending = false

	# Limpiar vinculación si es la respuesta
	remove_linked_effect(stack_id)
