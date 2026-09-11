extends Control
class_name HandManager
## HandManager - Gestiona la mano de cartas con disposición en arco rúnico
## Soporta mano del jugador (visible) y oponente (oculta)

# =============================================================================
# SEÑALES
# =============================================================================
signal card_clicked(card: Node)
signal card_double_clicked(card: Node)
signal card_hovered(card: Node)
signal card_unhovered(card: Node)
signal hand_changed(card_count: int)

# =============================================================================
# CONFIGURACIÓN DEL ARCO
# =============================================================================
@export_group("Arco")
## Radio de curvatura del arco (píxeles desde el centro)
@export var arc_radius: float = 1200.0
## Ángulo máximo de rotación para cartas externas (grados)
@export var max_rotation_angle: float = 20.0
## Curvatura vertical del arco (elevación del centro)
@export var arc_height: float = 40.0
## Separación horizontal base entre cartas (80% visible = 120px para carta de 150px)
@export var card_spacing: float = 130.0
## Separación mínima cuando hay muchas cartas
@export var min_spacing: float = 120.0
## Fracción mínima visible de cada carta (0.6 = 60% visible, más solapamiento)
@export var min_visible_ratio: float = 0.80

@export_group("Hover")
## Elevación al hacer hover (píxeles)
@export var hover_lift: float = 50.0
## Escala al hacer hover (1.1 = 10% más grande)
@export var hover_scale: float = 1.15
## Duración de animaciones (segundos)
@export var animation_duration: float = 0.15
## Empuje a cartas vecinas durante hover
@export var neighbor_push: float = 40.0

@export_group("Configuración")
## ID del jugador (0 = jugador local)
@export var player_id: int = 0
## Escala base de las cartas
@export var card_base_scale: float = 1.0

# =============================================================================
# ESTADO
# =============================================================================
var cards: Array[Node] = []
var hovered_card: Node = null
var _card_targets: Dictionary = {}  # card -> {pos, rot, scale, z}
var _tweens: Dictionary = {}
var _is_arranging: bool = false

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_on_resized)


func _on_resized() -> void:
	"""Recalcula posiciones cuando el contenedor cambia de tamaño"""
	if not cards.is_empty():
		_calculate_arc_positions()
		_arrange_cards(false)


# =============================================================================
# GESTIÓN DE CARTAS
# =============================================================================
func add_card(card: Node, animate: bool = true) -> void:
	"""Añade una carta a la mano"""
	cards.append(card)
	add_child(card)

	# Configurar carta según tipo de mano
	_setup_card(card)

	# Conectar señales
	if card.has_signal("card_hovered"):
		card.card_hovered.connect(_on_card_hovered)
	if card.has_signal("card_unhovered"):
		card.card_unhovered.connect(_on_card_unhovered)
	if card.has_signal("card_clicked"):
		card.card_clicked.connect(_on_card_clicked)
	if card.has_signal("card_double_clicked"):
		card.card_double_clicked.connect(_on_card_double_clicked)

	# Reorganizar
	_calculate_arc_positions()

	# Reubicar cartas existentes a sus nuevas posiciones calculadas
	for existing_card in cards:
		if existing_card != card:
			_apply_card_target(existing_card, animate)

	if animate:
		if card.get("_image_ready") == true:
			_animate_card_entry(card)
		else:
			# Mantener invisible en posición final; animar al llegar la imagen
			if _card_targets.has(card):
				var t = _card_targets[card]
				card.position = t.position
				card.rotation_degrees = t.rotation
				card.scale = t.scale
				card.z_index = t.z_index
				if card.has_method("set_click_clip_right"):
					card.set_click_clip_right(t.get("click_clip", -1.0))
			card.modulate.a = 0.0
			if card.has_signal("image_ready"):
				card.image_ready.connect(_on_card_image_ready.bind(card), CONNECT_ONE_SHOT)
	else:
		_apply_card_target(card, false)

	emit_signal("hand_changed", cards.size())


func remove_card(card: Node, destroy: bool = true) -> void:
	"""Remueve una carta de la mano"""
	var idx = cards.find(card)
	if idx < 0:
		return

	cards.remove_at(idx)
	_card_targets.erase(card)

	# Desconectar señales
	if card.card_hovered.is_connected(_on_card_hovered):
		card.card_hovered.disconnect(_on_card_hovered)
	if card.card_unhovered.is_connected(_on_card_unhovered):
		card.card_unhovered.disconnect(_on_card_unhovered)
	if card.card_clicked.is_connected(_on_card_clicked):
		card.card_clicked.disconnect(_on_card_clicked)
	if card.card_double_clicked.is_connected(_on_card_double_clicked):
		card.card_double_clicked.disconnect(_on_card_double_clicked)

	if destroy:
		card.queue_free()
	else:
		if card.has_method("set_click_clip_right"):
			card.set_click_clip_right(-1.0)
		remove_child(card)

	_calculate_arc_positions()
	_arrange_cards(true)

	emit_signal("hand_changed", cards.size())


func clear_hand() -> void:
	"""Limpia todas las cartas de la mano"""
	for card in cards:
		if is_instance_valid(card):
			card.queue_free()
	cards.clear()
	_card_targets.clear()
	_tweens.clear()
	emit_signal("hand_changed", 0)


func get_card_count() -> int:
	return cards.size()


func get_cards() -> Array[Node]:
	return cards


func _setup_card(card: Node) -> void:
	"""Configura una carta según el tipo de mano"""
	card.owner_id = player_id
	card.base_scale = Vector2(card_base_scale, card_base_scale)
	card.scale = card.base_scale

	# Tamaño base de carta (150x210)
	var card_size = Vector2(150, 210)

	card.can_interact = true
	# Pivot en centro-inferior para que el arco se abra hacia arriba
	card.pivot_offset = Vector2(card_size.x / 2.0, card_size.y)


# =============================================================================
# CÁLCULO DEL ARCO
# =============================================================================
func _calculate_arc_positions() -> void:
	"""Calcula las posiciones en arco para todas las cartas"""
	_card_targets.clear()

	if cards.is_empty():
		return

	var card_count = cards.size()
	var card_width_base = 150.0
	var card_height_base = 210.0
	var card_size = Vector2(card_width_base, card_height_base) * card_base_scale

	# Usar tamaño mínimo si el contenedor aún no tiene size
	var container_size = size
	if container_size.x < 100:
		# Fallback al ancho del viewport en vez de un valor fijo
		var vp = get_viewport()
		container_size.x = vp.get_visible_rect().size.x if vp else 800.0
	if container_size.y < 50:
		container_size.y = 150.0

	# Centro del contenedor
	var center_x = container_size.x / 2.0
	var center_y = container_size.y / 2.0

	var min_effective_spacing = card_size.x * min_visible_ratio

	# Calcular espaciado adaptativo (nunca menos del mínimo para evitar solapamiento excesivo)
	var effective_spacing = card_spacing
	if card_count > 5:
		effective_spacing = max(min_spacing, card_spacing - (card_count - 5) * 6)
	effective_spacing = max(effective_spacing, min_effective_spacing)

	# Ancho total ocupado
	var total_width = (card_count - 1) * effective_spacing
	var start_x = center_x - total_width / 2.0

	# Calcular ángulo de separación entre cartas
	var angle_per_card = max_rotation_angle * 2.0 / max(card_count - 1, 1)

	for i in range(card_count):
		var card = cards[i]

		# Posición X centrada
		var pos_x = start_x + i * effective_spacing - card_size.x / 2.0

		# Índice normalizado desde el centro: -0.5*(n-1) a +0.5*(n-1)
		var angle_index = float(i) - (card_count - 1) / 2.0

		# Rotación: izquierda inclina a la izquierda, derecha a la derecha.
		# La misma fórmula para jugador y oponente — el pivot diferente crea el efecto opuesto.
		# (Con pivot inferior: centro arriba, extremos abajo. Con pivot superior: centro abajo, extremos arriba.)
		var rotation = angle_index * angle_per_card

		# Factor normalizado (-1 a 1) para curva vertical
		var t = 0.0
		if card_count > 1:
			t = angle_index / ((card_count - 1) / 2.0)

		# Curva cóseno: cartas del centro más arriba, extremos más bajos
		var curve_factor = cos(t * PI / 2.0)
		var curve_offset = curve_factor * arc_height
		var pos_y = center_y - card_size.y / 2.0 - curve_offset

		# Recorte del área de CLICK cuando esta carta queda tapada por la
		# derecha por la siguiente (2026-09-03, mismo bug/fix que la
		# Reserva de Oro — ver Card._has_point()/GoldManager._apply_gold_
		# click_clip()): con min_visible_ratio<1 las cartas del arco se
		# superponen SIEMPRE que effective_spacing < card_size.x, y la
		# última carta de la mano (i == card_count-1) nunca está tapada.
		# effective_spacing está en unidades YA escaladas (card_size usa
		# card_base_scale) pero Card._has_point() recibe el punto en el
		# espacio LOCAL sin escalar de la carta (Control.size se queda en
		# 150, solo card.scale la transforma visualmente) — hay que
		# deshacer la escala para el umbral de recorte.
		var click_clip: float = -1.0
		if i < card_count - 1 and effective_spacing < card_size.x and card_base_scale > 0.0:
			click_clip = effective_spacing / card_base_scale

		# Guardar target
		_card_targets[card] = {
			"position": Vector2(pos_x, pos_y),
			"rotation": rotation,
			"scale": Vector2(card_base_scale, card_base_scale),
			"z_index": i,
			"click_clip": click_clip
		}


func _apply_card_target(card: Node, animated: bool = true) -> void:
	"""Aplica la posición objetivo a una carta"""
	if not _card_targets.has(card):
		return

	var target = _card_targets[card]
	card.z_index = target.z_index
	if card.has_method("set_click_clip_right"):
		card.set_click_clip_right(target.get("click_clip", -1.0))

	if animated:
		_kill_tween(card)
		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(card, "position", target.position, animation_duration).set_ease(Tween.EASE_OUT)
		tween.tween_property(card, "rotation_degrees", target.rotation, animation_duration).set_ease(Tween.EASE_OUT)
		tween.tween_property(card, "scale", target.scale, animation_duration).set_ease(Tween.EASE_OUT)
		_tweens[card] = tween
	else:
		card.position = target.position
		card.rotation_degrees = target.rotation
		card.scale = target.scale


func _arrange_cards(animated: bool = true) -> void:
	"""Reorganiza todas las cartas en el arco"""
	if _is_arranging:
		return

	_is_arranging = true

	for card in cards:
		if card != hovered_card:
			_apply_card_target(card, animated)

	_is_arranging = false


# =============================================================================
# ANIMACIÓN DE ENTRADA
# =============================================================================
func _animate_card_entry(card: Node) -> void:
	"""Anima la entrada de una carta nueva"""
	if not _card_targets.has(card):
		return

	var target = _card_targets[card]

	# Posición inicial (desde abajo)
	card.position = target.position + Vector2(0, 200)
	card.rotation_degrees = target.rotation + 15
	card.scale = Vector2(0.5, 0.5)
	card.modulate.a = 0.0
	card.z_index = 100
	if card.has_method("set_click_clip_right"):
		card.set_click_clip_right(-1.0)

	_kill_tween(card)
	var tween = create_tween()

	# Fade in
	tween.tween_property(card, "modulate:a", 1.0, animation_duration * 0.5)

	# Movimiento y rotación
	tween.parallel().tween_property(card, "position", target.position, animation_duration * 2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.parallel().tween_property(card, "rotation_degrees", target.rotation, animation_duration * 2).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "scale", target.scale, animation_duration * 2).set_ease(Tween.EASE_OUT)

	# Restaurar z-index (y el recorte de click) al final
	tween.tween_callback(func():
		card.z_index = target.z_index
		if card.has_method("set_click_clip_right"):
			card.set_click_clip_right(target.get("click_clip", -1.0))
	)

	_tweens[card] = tween


# =============================================================================
# SISTEMA DE HOVER
# =============================================================================
func _on_card_hovered(card: Node) -> void:
	"""Cuando el mouse entra en una carta"""
	if not card in cards:
		return

	hovered_card = card
	var idx = cards.find(card)

	if not _card_targets.has(card):
		return

	var target = _card_targets[card]

	# Elevar z-index — y quitar el recorte de click (2026-09-03): al pasar
	# a estar por encima de todas las vecinas, ya no hay nada que la tape.
	card.z_index = 100
	if card.has_method("set_click_clip_right"):
		card.set_click_clip_right(-1.0)

	var hover_pos = target.position + Vector2(0, -hover_lift)

	# Animar: elevar, enderezar, escalar
	_kill_tween(card)
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", hover_pos, animation_duration).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "rotation_degrees", 0.0, animation_duration).set_ease(Tween.EASE_OUT)  # Enderezar
	tween.tween_property(card, "scale", target.scale * hover_scale, animation_duration).set_ease(Tween.EASE_OUT)
	_tweens[card] = tween

	# Empujar vecinos
	_push_neighbors(idx)

	emit_signal("card_hovered", card)


func _on_card_unhovered(card: Node) -> void:
	"""Cuando el mouse sale de una carta"""
	if hovered_card != card:
		return

	hovered_card = null
	_arrange_cards(true)

	emit_signal("card_unhovered", card)


func _push_neighbors(hovered_idx: int) -> void:
	"""Empuja las cartas vecinas para dar espacio"""
	for i in range(cards.size()):
		if i == hovered_idx:
			continue

		var card = cards[i]
		if not _card_targets.has(card):
			continue

		var target = _card_targets[card]
		var push = 0.0

		# Calcular dirección del empuje
		if i < hovered_idx:
			push = -neighbor_push
		elif i > hovered_idx:
			push = neighbor_push

		var pushed_pos = target.position + Vector2(push, 0)

		# Restaurar z-index
		card.z_index = target.z_index

		_kill_tween(card)
		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(card, "position", pushed_pos, animation_duration).set_ease(Tween.EASE_OUT)
		tween.tween_property(card, "rotation_degrees", target.rotation, animation_duration).set_ease(Tween.EASE_OUT)
		tween.tween_property(card, "scale", target.scale, animation_duration).set_ease(Tween.EASE_OUT)
		_tweens[card] = tween


# =============================================================================
# CALLBACKS DE CARTAS
# =============================================================================
func _on_card_clicked(card: Node) -> void:
	emit_signal("card_clicked", card)


func _on_card_double_clicked(card: Node) -> void:
	emit_signal("card_double_clicked", card)


# =============================================================================
# UTILIDADES
# =============================================================================
func _on_card_image_ready(card: Node) -> void:
	"""Anima la entrada de una carta cuando su imagen frontal está lista."""
	if card in cards:
		_animate_card_entry(card)


func _kill_tween(card: Node) -> void:
	"""Detiene el tween activo de una carta"""
	if _tweens.has(card):
		var tween = _tweens[card]
		if tween and tween.is_valid():
			tween.kill()
		_tweens.erase(card)


func get_card_at_index(index: int) -> Node:
	"""Obtiene la carta en un índice específico"""
	if index >= 0 and index < cards.size():
		return cards[index]
	return null


func find_card(card: Node) -> int:
	"""Encuentra el índice de una carta"""
	return cards.find(card)


func set_cards_interactive(interactive: bool) -> void:
	"""Activa/desactiva la interacción de todas las cartas"""
	for card in cards:
		card.can_interact = interactive


func update_arc_settings(radius: float = -1, max_angle: float = -1, height: float = -1) -> void:
	"""Actualiza la configuración del arco dinámicamente"""
	if radius > 0:
		arc_radius = radius
	if max_angle > 0:
		max_rotation_angle = max_angle
	if height > 0:
		arc_height = height

	_calculate_arc_positions()
	_arrange_cards(true)
