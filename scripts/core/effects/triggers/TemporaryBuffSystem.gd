extends RefCounted
class_name TemporaryBuffSystem
## TemporaryBuffSystem — Buffs/debuffs temporales con duración (this_turn,
## until_final, until_next_turn, permanent), independiente de
## ContinuousEffectManager. Opera sobre TriggerSystem via _main (señales
## buff_applied/buff_expired/buffs_cleared, GameManager.current_turn).
## Extraído de TriggerSystem.gd (Fase 4 de reestructuración).

var _main: Node

## Cada buff: {source: Node, target: Node, type: String, value: int, duration: String, turn_applied: int}
## Duraciones: "this_turn", "until_final", "until_next_turn", "permanent"
var temporary_buffs: Array[Dictionary] = []


func setup(main: Node) -> void:
	_main = main


func apply_buff(source: Node, target: Node, buff_type: String, value: int, duration: String = "this_turn") -> Dictionary:
	"""Aplica un buff/debuff temporal a una carta

	Args:
		source: Carta que genera el efecto
		target: Carta afectada
		buff_type: Tipo de modificador ("attack", "defense", "cost", etc.)
		value: Valor del modificador (positivo = buff, negativo = debuff)
		duration: Duración ("this_turn", "until_final", "until_next_turn", "permanent")

	Returns: El buff creado
	"""
	var current_turn = GameManager.current_turn if GameManager else 0

	var buff = {
		"id": "%s_%d_%d" % [buff_type, target.get_instance_id(), Time.get_ticks_msec()],
		"source": source,
		"target": target,
		"type": buff_type,
		"value": value,
		"duration": duration,
		"turn_applied": current_turn
	}

	temporary_buffs.append(buff)

	# Aplicar el modificador a la carta
	if target.has_method("apply_modifier"):
		target.apply_modifier(buff_type, value, buff.id)

	print("[TriggerSystem] Buff aplicado: %s %+d a %s (duración: %s)" % [
		buff_type, value, target.card_name if target.get("card_name") else str(target), duration
	])

	_main.emit_signal("buff_applied", target, buff)
	return buff


func remove_buff(buff_id: String) -> bool:
	"""Elimina un buff específico por ID"""
	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		if buff.id == buff_id:
			var target = buff.target

			# Quitar el modificador de la carta
			if is_instance_valid(target) and target.has_method("remove_modifier"):
				target.remove_modifier(buff.type, buff.id)

			_main.emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			return true

	return false


func remove_buffs_from_source(source: Node) -> int:
	"""Elimina todos los buffs de una fuente específica"""
	var removed = 0

	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		if buff.source == source:
			var target = buff.target

			if is_instance_valid(target) and target.has_method("remove_modifier"):
				target.remove_modifier(buff.type, buff.id)

			_main.emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			removed += 1

	return removed


func remove_buffs_from_target(target: Node) -> int:
	"""Elimina todos los buffs que afectan a una carta"""
	var removed = 0

	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		if buff.target == target:
			if target.has_method("remove_modifier"):
				target.remove_modifier(buff.type, buff.id)

			_main.emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			removed += 1

	return removed


func clear_expired_buffs(duration: String) -> int:
	"""Limpia todos los buffs que expiran con la duración especificada
	Llamado por TurnManager al final del turno o fase

	Args:
		duration: "this_turn", "until_final", "until_next_turn"

	Returns: Cantidad de buffs eliminados
	"""
	var removed = 0
	var current_turn = GameManager.current_turn if GameManager else 0

	for i in range(temporary_buffs.size() - 1, -1, -1):
		var buff = temporary_buffs[i]
		var should_remove = false

		match duration:
			"this_turn":
				# Expiran al final del turno actual
				should_remove = buff.duration == "this_turn"

			"until_final":
				# Expiran al inicio de la Fase Final
				should_remove = buff.duration == "until_final"

			"until_next_turn":
				# Expiran al inicio del siguiente turno del controlador
				if buff.duration == "until_next_turn":
					should_remove = current_turn > buff.turn_applied

		if should_remove:
			var target = buff.target

			if is_instance_valid(target):
				if target.has_method("remove_modifier"):
					target.remove_modifier(buff.type, buff.id)

				print("[TriggerSystem] Buff expirado: %s de %s" % [
					buff.type, target.card_name if target.get("card_name") else str(target)
				])

			_main.emit_signal("buff_expired", target, buff)
			temporary_buffs.remove_at(i)
			removed += 1

	if removed > 0:
		print("[TriggerSystem] %d buffs con duración '%s' eliminados" % [removed, duration])
		_main.emit_signal("buffs_cleared", removed, duration)

	return removed


func get_buffs_on_target(target: Node) -> Array[Dictionary]:
	"""Obtiene todos los buffs activos en una carta"""
	var result: Array[Dictionary] = []

	for buff in temporary_buffs:
		if buff.target == target:
			result.append(buff)

	return result


func get_total_modifier(target: Node, buff_type: String) -> int:
	"""Calcula el modificador total de un tipo para una carta"""
	var total = 0

	for buff in temporary_buffs:
		if buff.target == target and buff.type == buff_type:
			total += buff.value

	return total


func has_buff_type(target: Node, buff_type: String) -> bool:
	"""Verifica si una carta tiene un buff/debuff de un tipo"""
	for buff in temporary_buffs:
		if buff.target == target and buff.type == buff_type:
			return true
	return false
