extends Node
## GameState - Estado global centralizado del juego
## Maneja oro, contadores y estado compartido entre sistemas

# =============================================================================
# SEÑALES
# =============================================================================
signal oro_reserva_changed(player_id: int, amount: int)
signal oro_pagado_changed(player_id: int, amount: int)
signal oro_total_changed(player_id: int, reserva: int, pagado: int)

# =============================================================================
# ESTADO DE ORO POR JUGADOR
# =============================================================================
## Oro disponible en reserva (listo para usar)
var oro_reserva: Dictionary = {0: 0, 1: 0}
## Oro ya pagado este turno (usado)
var oro_pagado: Dictionary = {0: 0, 1: 0}

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	print("[GameState] Inicializado")


# =============================================================================
# API DE ORO - CONSULTA
# =============================================================================
func get_oro_reserva(player_id: int) -> int:
	"""Obtiene el oro disponible en reserva del jugador"""
	return oro_reserva.get(player_id, 0)


func get_oro_pagado(player_id: int) -> int:
	"""Obtiene el oro ya pagado del jugador"""
	return oro_pagado.get(player_id, 0)


func get_oro_total(player_id: int) -> int:
	"""Obtiene el oro total (reserva + pagado)"""
	return get_oro_reserva(player_id) + get_oro_pagado(player_id)


func puede_pagar(player_id: int, cantidad: int) -> bool:
	"""Verifica si el jugador puede pagar un coste"""
	return get_oro_reserva(player_id) >= cantidad


# =============================================================================
# API DE ORO - MODIFICACIÓN
# =============================================================================
func agregar_oro_reserva(player_id: int, cantidad: int = 1) -> void:
	"""Agrega oro a la reserva (cuando se coloca una carta de oro)"""
	oro_reserva[player_id] = oro_reserva.get(player_id, 0) + cantidad
	_emit_oro_signals(player_id)
	print("[GameState] J%d: +%d oro reserva (total: %d)" % [player_id, cantidad, oro_reserva[player_id]])


func agregar_oro_pagado(player_id: int, cantidad: int = 1) -> void:
	"""Agrega oro YA a Oro Pagado directo, sin pasar por Reserva (p.ej.
	Perder la Razón: 'poner un Oro de ahí en tu Oro Pagado' — a diferencia
	de agregar_oro_reserva(), esta carta nunca estuvo disponible para pagar
	nada, entra directo como ya-gastada)."""
	oro_pagado[player_id] = oro_pagado.get(player_id, 0) + cantidad
	_emit_oro_signals(player_id)
	print("[GameState] J%d: +%d oro pagado directo (total pagado: %d)" % [player_id, cantidad, oro_pagado[player_id]])


func pagar_oro(player_id: int, cantidad: int) -> bool:
	"""Paga oro moviendo de reserva a pagado. Returns: true si se pudo pagar"""
	if not puede_pagar(player_id, cantidad):
		return false

	oro_reserva[player_id] -= cantidad
	oro_pagado[player_id] = oro_pagado.get(player_id, 0) + cantidad
	_emit_oro_signals(player_id)
	print("[GameState] J%d: Pagó %d oro (reserva: %d, pagado: %d)" % [
		player_id, cantidad, oro_reserva[player_id], oro_pagado[player_id]
	])
	return true


func reagrupar_oro(player_id: int) -> void:
	"""Mueve todo el oro pagado de vuelta a reserva (inicio de turno)"""
	var pagado = oro_pagado.get(player_id, 0)
	if pagado > 0:
		oro_reserva[player_id] = oro_reserva.get(player_id, 0) + pagado
		oro_pagado[player_id] = 0
		_emit_oro_signals(player_id)
		print("[GameState] J%d: Reagrupó %d oro (reserva: %d)" % [player_id, pagado, oro_reserva[player_id]])


func reset_oro(player_id: int) -> void:
	"""Resetea todo el oro del jugador (nueva partida)"""
	oro_reserva[player_id] = 0
	oro_pagado[player_id] = 0
	_emit_oro_signals(player_id)


func set_oro_reserva(player_id: int, cantidad: int) -> void:
	"""Establece directamente el oro en reserva (para sincronización con UI)"""
	oro_reserva[player_id] = cantidad
	_emit_oro_signals(player_id)


func set_oro_pagado(player_id: int, cantidad: int) -> void:
	"""Establece directamente el oro pagado (para sincronización con UI)"""
	oro_pagado[player_id] = cantidad
	_emit_oro_signals(player_id)


# =============================================================================
# SEÑALES INTERNAS
# =============================================================================
func _emit_oro_signals(player_id: int) -> void:
	"""Emite señales de cambio de oro"""
	emit_signal("oro_reserva_changed", player_id, oro_reserva.get(player_id, 0))
	emit_signal("oro_pagado_changed", player_id, oro_pagado.get(player_id, 0))
	emit_signal("oro_total_changed", player_id, oro_reserva.get(player_id, 0), oro_pagado.get(player_id, 0))


# =============================================================================
# SINCRONIZACIÓN CON UI (Main.gd)
# =============================================================================
func sync_from_ui(player_id: int, reserva_count: int, pagado_count: int) -> void:
	"""Sincroniza el estado desde contadores de UI"""
	oro_reserva[player_id] = reserva_count
	oro_pagado[player_id] = pagado_count
	# No emitir señales para evitar loops
