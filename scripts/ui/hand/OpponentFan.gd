extends Control
class_name OpponentFan
## OpponentFan — Mano del oponente en fila horizontal limpia (Opción 3).
##
## Cartas centradas horizontalmente con rotación recta (0°), solapadas
## de manera uniforme y elegante en el borde superior de la pantalla.

signal hand_changed(count: int)

@export var card_scale:    float = 0.50
@export var card_overlap:  float = -40.0   ## Solapamiento base entre cartas
@export var anim_duration: float = 0.20

const CARD_W: float = 150.0  # Ancho base de carta (sin escalar)
const CARD_H: float = 210.0  # Alto base de carta (sin escalar)

var _cards: Array[Node] = []


# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_arrange)


# =============================================================================
# API PÚBLICA
# =============================================================================
func add_card(card: Node) -> void:
	_cards.append(card)
	add_child(card)
	_init_card(card)
	card.modulate.a = 0.0
	_arrange()
	emit_signal("hand_changed", _cards.size())


func remove_card(card: Node, destroy: bool = true) -> void:
	if card not in _cards:
		return
	_cards.erase(card)
	if destroy:
		card.queue_free()
	else:
		remove_child(card)
	_arrange()
	emit_signal("hand_changed", _cards.size())


func clear_hand() -> void:
	for card in _cards:
		if is_instance_valid(card):
			card.queue_free()
	_cards.clear()
	emit_signal("hand_changed", 0)


func get_card_count() -> int:
	return _cards.size()


func get_cards() -> Array[Node]:
	return _cards


# =============================================================================
# CONFIGURACIÓN DE CARTA
# =============================================================================
func _init_card(card: Node) -> void:
	card.owner_id      = 1
	card.controller_id = 1
	card.esta_oculta   = true
	card.can_interact  = false
	card.scale         = Vector2(card_scale, card_scale)
	card.base_scale    = Vector2(card_scale, card_scale)
	card.pivot_offset  = Vector2(CARD_W / 2.0, 0.0)
	card.actualizar_aspecto()
	if card.has_method("_refresh_disabled_rotation"):
		card._refresh_disabled_rotation()


# =============================================================================
# DISPOSICIÓN HORIZONTAL RECTA (OPCIÓN 3)
# =============================================================================
func _arrange() -> void:
	var n := _cards.size()
	if n == 0:
		return

	# Centro horizontal de la pantalla
	var cx := size.x / 2.0
	if cx < 50.0:
		var vp := get_viewport()
		cx = vp.get_visible_rect().size.x / 2.0 if vp else 960.0

	var effective_width := CARD_W * card_scale  # 75px
	
	# Solapamiento dinámico: si hay muchas cartas se comprime suavemente
	var overlap := card_overlap
	var max_available_width := 420.0
	if n > 1:
		var natural_total := effective_width + float(n - 1) * (effective_width + overlap)
		if natural_total > max_available_width:
			var max_step := (max_available_width - effective_width) / float(n - 1)
			overlap = max_step - effective_width

	var step := effective_width + overlap
	var total_w := effective_width + float(n - 1) * step if n > 1 else effective_width
	var start_x := cx - total_w / 2.0

	for i in range(n):
		var card := _cards[i]
		var px := start_x + float(i) * step
		var py := 8.0  # Posicionada limpiamente bajo el borde superior sin cortarse

		card.z_index = i

		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(card, "position",         Vector2(px, py), anim_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(card, "rotation_degrees", 0.0,             anim_duration).set_ease(Tween.EASE_OUT)
		tw.tween_property(card, "modulate:a",       1.0,             anim_duration * 0.6)
		if card.has_method("_refresh_disabled_rotation"):
			card._refresh_disabled_rotation()


func get_card_target_position(card: Node) -> Vector2:
	"""Calcula la posición local de destino de una carta en la mano del oponente."""
	var idx := _cards.find(card)
	if idx < 0:
		idx = _cards.size() - 1
	if idx < 0:
		idx = 0
	var n := maxi(1, _cards.size())
	var cx := size.x / 2.0
	if cx < 50.0:
		var vp := get_viewport()
		cx = vp.get_visible_rect().size.x / 2.0 if vp else 960.0

	var effective_width := CARD_W * card_scale
	var overlap := card_overlap
	var max_available_width := 420.0
	if n > 1:
		var natural_total := effective_width + float(n - 1) * (effective_width + overlap)
		if natural_total > max_available_width:
			var max_step := (max_available_width - effective_width) / float(n - 1)
			overlap = max_step - effective_width

	var step := effective_width + overlap
	var total_w := effective_width + float(n - 1) * step if n > 1 else effective_width
	var start_x := cx - total_w / 2.0
	var target_x := start_x + float(idx) * step
	return Vector2(target_x, 8.0)
