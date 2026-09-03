extends Control
class_name OpponentFan
## OpponentFan — Mano del oponente en abanico simétrico hacia abajo.
##
## Las cartas se colocan con pivot_offset = (CARD_W/2, 0) (centro-superior).
## Todas las cartas parten de Y=0 y rotan desde ese pivote, creando un arco
## natural hacia abajo. El contenedor ocupa el ancho completo del padre y se
## ancla al borde superior (PRESET_TOP_WIDE).

signal hand_changed(count: int)

@export var card_scale:   float = 0.55
@export var max_angle:    float = 20.0   ## Ángulo máximo en los extremos (grados)
@export var card_spacing: float = 85.0   ## Separación horizontal entre pivotes
@export var anim_duration: float = 0.18

const CARD_W: float = 150.0  # Ancho base de carta (sin escalar)

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
	card.esta_oculta   = true
	card.can_interact  = false
	card.scale         = Vector2(card_scale, card_scale)
	card.base_scale    = Vector2(card_scale, card_scale)
	# Pivot en el centro-superior de la carta (coordenadas locales sin escalar).
	# Al rotar, la carta "cuelga" hacia abajo desde ese punto → arco natural.
	card.pivot_offset  = Vector2(CARD_W / 2.0, 0.0)


# =============================================================================
# DISPOSICIÓN EN ABANICO
# =============================================================================
func _arrange() -> void:
	var n := _cards.size()
	if n == 0:
		return

	# Centro horizontal (usa el ancho real del contenedor, o el viewport si
	# aún no se calculó — evita el fallback de 800px hardcodeado)
	var cx := size.x / 2.0
	if cx < 50.0:
		var vp := get_viewport()
		cx = vp.get_visible_rect().size.x / 2.0 if vp else 640.0

	var total_w  := float(n - 1) * card_spacing
	var start_x  := cx - total_w / 2.0
	var angle_step := (max_angle * 2.0) / maxf(float(n - 1), 1.0)

	for i in range(n):
		var card := _cards[i]
		var ai   := float(i) - float(n - 1) / 2.0   # centrado: -k … 0 … +k
		var angle := -(ai * angle_step)

		# La posición X coloca el PIVOTE (centro-superior) en start_x + i*spacing.
		# Como position es la esquina superior-izquierda y el pivote está
		# en (CARD_W/2, 0), restamos (CARD_W * scale / 2) para alinearlo.
		var px := start_x + float(i) * card_spacing - (CARD_W * card_scale) / 2.0

		card.z_index = i

		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(card, "position",         Vector2(px, 0.0), anim_duration).set_ease(Tween.EASE_OUT)
		tw.tween_property(card, "rotation_degrees", angle,             anim_duration).set_ease(Tween.EASE_OUT)
		tw.tween_property(card, "modulate:a",       1.0,               anim_duration * 0.6)
