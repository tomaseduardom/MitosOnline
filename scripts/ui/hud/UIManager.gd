# game/scripts/ui/hud/UIManager.gd
extends Node
## UIManager — Único responsable de actualizar etiquetas y contadores de la UI.
## Main.gd no escribe Labels directamente; llama a estos métodos o UIManager
## escucha señales de los singletons.

# =============================================================================
# REFERENCIAS A NODOS (inyectadas por Main.gd al arrancar)
# =============================================================================
var turn_label: Label = null
var phase_label: Label = null
var player_info: Label = null
var debug_label: Label = null
var timer_label: Label = null

# Contadores de zonas
var player_castillo_count: Label = null
var player_cementerio_count: Label = null
var player_destierro_count: Label = null
var opponent_castillo_count: Label = null
var opponent_cementerio_count: Label = null
var opponent_destierro_count: Label = null

# Labels de oro
var player_oro_reserva_label: Label = null
var player_oro_pagado_label: Label = null
var opponent_oro_reserva_label: Label = null
var opponent_oro_pagado_label: Label = null

var _is_ready: bool = false
var _active_tweens: Dictionary = {}
# Cache de contadores de zonas para evitar leer .text del Label
var _zone_counts: Dictionary = {
	"destierro_0": 0, "destierro_1": 0,
	"cementerio_0": 0, "cementerio_1": 0,
	"castillo_0": 0, "castillo_1": 0,
}
# CanvasLayer dedicado a diálogos modales (creado en _ready)
var _dialog_layer: CanvasLayer = null


func _ready() -> void:
	_dialog_layer = CanvasLayer.new()
	_dialog_layer.layer = 95
	add_child(_dialog_layer)


func setup(refs: Dictionary) -> void:
	"""Inicializa UIManager con referencias a los nodos de la escena.
	Llamado desde Main._ready() tras los @onready.

	UIManager es un autoload — sobrevive a change_scene_to_file() (usado por
	'salir al menú' / 'jugar de nuevo', ver MainMenu.gd/SceneSetupModule.gd).
	Antes, el guard de _is_ready hacía que la SEGUNDA vez que se entraba a
	una partida en el mismo proceso de Godot, setup() se ignorara por
	completo — todas las referencias a Label quedaban apuntando a los nodos
	de la partida anterior, ya liberados, y la primera actualización de UI
	crasheaba con 'previously freed' (p.ej. _set_label). _connect_signals()
	ya es idempotente (chequea is_connected antes de conectar), así que no
	hay riesgo de duplicar conexiones al llamar setup() de nuevo — siempre
	debe refrescar las referencias."""
	turn_label              = refs.get("turn_label")
	phase_label             = refs.get("phase_label")
	player_info             = refs.get("player_info")
	debug_label             = refs.get("debug_label")
	timer_label             = refs.get("timer_label")
	player_castillo_count   = refs.get("player_castillo_count")
	player_cementerio_count = refs.get("player_cementerio_count")
	player_destierro_count  = refs.get("player_destierro_count")
	opponent_castillo_count = refs.get("opponent_castillo_count")
	opponent_cementerio_count = refs.get("opponent_cementerio_count")
	opponent_destierro_count = refs.get("opponent_destierro_count")
	player_oro_reserva_label  = refs.get("player_oro_reserva_label")
	player_oro_pagado_label   = refs.get("player_oro_pagado_label")
	opponent_oro_reserva_label  = refs.get("opponent_oro_reserva_label")
	opponent_oro_pagado_label   = refs.get("opponent_oro_pagado_label")

	_connect_signals()
	_is_ready = true
	print("[UIManager] Configurado con %d referencias" % refs.size())


func _connect_signals() -> void:
	"""Conecta señales de singletons para actualizaciones reactivas."""
	if not CardManager.deck_count_changed.is_connected(update_castillo_count):
		CardManager.deck_count_changed.connect(update_castillo_count)
	if not CardManager.cemetery_count_changed.is_connected(update_cementerio_count):
		CardManager.cemetery_count_changed.connect(update_cementerio_count)
	if not CardManager.exile_count_changed.is_connected(update_destierro_count):
		CardManager.exile_count_changed.connect(update_destierro_count)

	if not GameState.oro_reserva_changed.is_connected(update_oro_reserva):
		GameState.oro_reserva_changed.connect(update_oro_reserva)
	if not GameState.oro_pagado_changed.is_connected(update_oro_pagado):
		GameState.oro_pagado_changed.connect(update_oro_pagado)


# =============================================================================
# API PÚBLICA — llamada desde Main.gd
# =============================================================================
func announce_phase(phase: Constants.Phase) -> void:
	"""Actualiza el label de fase."""
	_set_label(phase_label, Constants.PHASE_NAMES.get(phase, "Fase desconocida"))


func announce_turn(player_id: int, turn_number: int) -> void:
	"""Actualiza el label de turno."""
	var player_text = "Tu turno" if player_id == 0 else "Turno oponente"
	_set_label(turn_label, "Turno %d - %s" % [turn_number, player_text])


func show_debug(msg: String) -> void:
	"""Actualiza el label de debug."""
	_set_label(debug_label, msg)


func update_castillo_count(player_id: int, count: int) -> void:
	if player_id == 0:
		_set_label(player_castillo_count, str(count))
	else:
		_set_label(opponent_castillo_count, str(count))


func update_cementerio_count(player_id: int, count: int) -> void:
	if player_id == 0:
		_set_label(player_cementerio_count, str(count))
	else:
		_set_label(opponent_cementerio_count, str(count))


func update_destierro_count(player_id: int, count: int) -> void:
	_zone_counts["destierro_%d" % player_id] = count
	if player_id == 0:
		_set_label(player_destierro_count, str(count))
	else:
		_set_label(opponent_destierro_count, str(count))


func get_destierro_count(player_id: int) -> int:
	return _zone_counts.get("destierro_%d" % player_id, 0)


func update_oro_reserva(player_id: int, amount: int) -> void:
	var text = "RESERVA · %d" % amount
	if player_id == 0:
		_blink_label(player_oro_reserva_label, text)
	else:
		_blink_label(opponent_oro_reserva_label, text)


func update_oro_pagado(player_id: int, amount: int) -> void:
	var text = "PAGADO · %d" % amount
	if player_id == 0:
		_blink_label(player_oro_pagado_label, text)
	else:
		_blink_label(opponent_oro_pagado_label, text)


func sync_castillo_counts(player_deck_size: int, opponent_deck_size: int) -> void:
	"""Sincronización directa cuando CardManager no tiene los datos."""
	_set_label(player_castillo_count, str(player_deck_size))
	_set_label(opponent_castillo_count, str(opponent_deck_size))


func update_timer(seconds_remaining: int) -> void:
	"""Actualiza el label del temporizador."""
	_set_label(timer_label, str(seconds_remaining))


func set_phase_text(text: String) -> void:
	"""Escribe texto literal en el label de fase (para 'Mulligan', 'Sorteo', 'VICTORIA!', etc.)."""
	_set_label(phase_label, text)


# =============================================================================
# INTERNO
# =============================================================================
func _set_label(label: Label, text: String) -> void:
	if label and is_instance_valid(label):
		label.text = text


func _blink_label(label: Label, new_text: String) -> void:
	"""Actualiza con animación de parpadeo dorado."""
	if not label or not is_instance_valid(label):
		return
	var old_text = label.text
	label.text = new_text
	if old_text == new_text:
		return
	label.pivot_offset = label.size / 2.0
	if _active_tweens.has(label) and is_instance_valid(_active_tweens[label]):
		_active_tweens[label].kill()
	var tween = label.create_tween().set_parallel(true)
	_active_tweens[label] = tween
	tween.tween_property(label, "modulate", Color(1.0, 0.85, 0.3, 1.0), 0.1)
	tween.tween_property(label, "scale",    Vector2(1.2, 1.2), 0.1)
	tween.chain().tween_property(label, "modulate", Color.WHITE, 0.2)
	tween.chain().tween_property(label, "scale",    Vector2.ONE, 0.2)
