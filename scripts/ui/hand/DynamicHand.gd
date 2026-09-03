extends Control
class_name DynamicHand
## Mano dinámica con cartas solapadas y efecto hover

signal card_clicked(card: Node)
signal card_double_clicked(card: Node)

@export var card_overlap: float = -10.0  # Solapamiento (-10 = solo 10px de overlap, más visible)
@export var hover_lift: float = 50.0  # Elevación al hover
@export var hover_scale: float = 1.15  # Escala al hover
@export var neighbor_push: float = 60.0  # Empuje a vecinos
@export var animation_duration: float = 0.15

var cards: Array[Node] = []
var hovered_card: Node = null
var _tweens: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func add_card(card: Node) -> void:
	"""Añade una carta a la mano"""
	cards.append(card)
	add_child(card)

	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)
	card.card_clicked.connect(func(c): card_clicked.emit(c))
	card.card_double_clicked.connect(func(c): card_double_clicked.emit(c))

	_arrange_cards()


func remove_card(card: Node) -> void:
	"""Remueve una carta de la mano"""
	var idx = cards.find(card)
	if idx >= 0:
		cards.remove_at(idx)
		card.queue_free()
		_arrange_cards()


func get_card_count() -> int:
	return cards.size()


func clear_hand() -> void:
	"""Limpia todas las cartas"""
	for card in cards:
		card.queue_free()
	cards.clear()


func _arrange_cards(animated: bool = true) -> void:
	"""Organiza las cartas con solapamiento"""
	if cards.is_empty():
		return

	var card_width = 150.0  # Ancho base de carta
	var total_width = card_width + (cards.size() - 1) * (card_width + card_overlap)
	var start_x = (size.x - total_width) / 2.0
	var center_y = size.y / 2.0

	for i in range(cards.size()):
		var card = cards[i]
		var target_x = start_x + i * (card_width + card_overlap)
		var target_y = center_y - 105.0  # Centrado vertical (210/2)
		var target_pos = Vector2(target_x, target_y)

		# Z-index basado en posición
		card.z_index = i

		if card == hovered_card:
			continue  # El hover se maneja aparte

		if animated and _tweens.has(card):
			_tweens[card].kill()

		if animated:
			var tween = create_tween()
			tween.set_parallel(true)
			tween.tween_property(card, "position", target_pos, animation_duration)
			tween.tween_property(card, "scale", Vector2.ONE, animation_duration)
			_tweens[card] = tween
		else:
			card.position = target_pos
			card.scale = Vector2.ONE


func _on_card_hovered(card: Node) -> void:
	"""Cuando se hace hover sobre una carta"""
	hovered_card = card
	var idx = cards.find(card)
	if idx < 0:
		return

	# Elevar z-index de la carta hovereada
	card.z_index = 100

	# Animar carta hovereada
	if _tweens.has(card):
		_tweens[card].kill()

	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position:y", card.position.y - hover_lift, animation_duration)
	tween.tween_property(card, "scale", Vector2(hover_scale, hover_scale), animation_duration)
	_tweens[card] = tween

	# Empujar vecinos
	_push_neighbors(idx)


func _on_card_unhovered(card: Node) -> void:
	"""Cuando se deja de hacer hover"""
	if hovered_card == card:
		hovered_card = null
		_arrange_cards()


func _push_neighbors(hovered_idx: int) -> void:
	"""Empuja las cartas vecinas"""
	var card_width = 150.0
	var start_x = (size.x - (card_width + (cards.size() - 1) * (card_width + card_overlap))) / 2.0
	var center_y = size.y / 2.0

	for i in range(cards.size()):
		if i == hovered_idx:
			continue

		var card = cards[i]
		var base_x = start_x + i * (card_width + card_overlap)
		var target_y = center_y - 105.0

		# Calcular empuje
		var push = 0.0
		if i < hovered_idx:
			push = -neighbor_push
		elif i > hovered_idx:
			push = neighbor_push

		var target_pos = Vector2(base_x + push, target_y)

		# Restaurar z-index
		card.z_index = i

		if _tweens.has(card):
			_tweens[card].kill()

		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(card, "position", target_pos, animation_duration)
		tween.tween_property(card, "scale", Vector2.ONE, animation_duration)
		_tweens[card] = tween
