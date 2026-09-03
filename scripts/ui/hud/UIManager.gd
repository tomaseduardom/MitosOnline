# game/scripts/ui/UIManager.gd
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
	var cm = get_node_or_null("/root/CardManager")
	if cm:
		if cm.has_signal("deck_count_changed") and not cm.deck_count_changed.is_connected(update_castillo_count):
			cm.deck_count_changed.connect(update_castillo_count)
		if cm.has_signal("cemetery_count_changed") and not cm.cemetery_count_changed.is_connected(update_cementerio_count):
			cm.cemetery_count_changed.connect(update_cementerio_count)
		if cm.has_signal("exile_count_changed") and not cm.exile_count_changed.is_connected(update_destierro_count):
			cm.exile_count_changed.connect(update_destierro_count)

	var gs = get_node_or_null("/root/GameState")
	if gs:
		if gs.has_signal("oro_reserva_changed") and not gs.oro_reserva_changed.is_connected(update_oro_reserva):
			gs.oro_reserva_changed.connect(update_oro_reserva)
		if gs.has_signal("oro_pagado_changed") and not gs.oro_pagado_changed.is_connected(update_oro_pagado):
			gs.oro_pagado_changed.connect(update_oro_pagado)

	# Sistema "Puedes" — ActionPipeline solicita confirmación del jugador
	var ap = get_node_or_null("/root/ActionPipeline")
	if ap and ap.has_signal("puedes_confirm_requested"):
		if not ap.puedes_confirm_requested.is_connected(_on_puedes_confirm_requested):
			ap.puedes_confirm_requested.connect(_on_puedes_confirm_requested)


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
	var text = "RESERVA: %d" % amount
	if player_id == 0:
		_blink_label(player_oro_reserva_label, text)
	else:
		_blink_label(opponent_oro_reserva_label, text)


func update_oro_pagado(player_id: int, amount: int) -> void:
	var text = "PAGADO: %d" % amount
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
# SISTEMA "PUEDES" — Diálogo de confirmación de habilidades opcionales
# =============================================================================
func _on_puedes_confirm_requested(ability_data: Dictionary, _context: Dictionary) -> void:
	"""Recibe la señal de ActionPipeline y muestra el diálogo modal."""
	_show_puedes_dialog(ability_data)


func _show_puedes_dialog(ability_data: Dictionary) -> void:
	"""Crea un overlay modal que pregunta al jugador si desea activar la habilidad opcional."""
	var ap := get_node_or_null("/root/ActionPipeline")
	if not ap:
		return

	# Limpiar diálogos previos si los hay
	for child in _dialog_layer.get_children():
		child.queue_free()

	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.55)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dialog_layer.add_child(overlay)

	var panel := PanelContainer.new()
	panel.set_anchor(SIDE_LEFT,   0.5)
	panel.set_anchor(SIDE_TOP,    0.5)
	panel.set_anchor(SIDE_RIGHT,  0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.set_offset(SIDE_LEFT,  -195)
	panel.set_offset(SIDE_TOP,   -80)
	panel.set_offset(SIDE_RIGHT,  195)
	panel.set_offset(SIDE_BOTTOM, 80)
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "¿Deseas activar esta habilidad?"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title_lbl)

	var effect_lbl := Label.new()
	var effect_text: String = ability_data.get("effect_text", ability_data.get("raw_text", ""))
	effect_lbl.text = effect_text.substr(0, 100)
	effect_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	effect_lbl.add_theme_font_size_override("font_size", 11)
	effect_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(effect_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 24)
	vbox.add_child(btn_row)

	var btn_yes := Button.new()
	btn_yes.text = "Sí, activar"
	btn_yes.pressed.connect(func():
		overlay.queue_free()
		ap.respond_puedes(true)
	)
	btn_row.add_child(btn_yes)

	var btn_no := Button.new()
	btn_no.text = "No"
	btn_no.pressed.connect(func():
		overlay.queue_free()
		ap.respond_puedes(false)
	)
	btn_row.add_child(btn_no)


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
