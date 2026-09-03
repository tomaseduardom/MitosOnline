extends RefCounted
class_name CardAnimations
## CardAnimations — Animaciones de movimiento, flip y efectos visuales de una carta.
## Opera sobre el nodo Card via _card. Card.gd expone wrappers públicos con el
## mismo nombre porque otros sistemas (GoldManager, TriggerSystem,
## CardInteractionModule) llaman estos métodos directamente sobre la carta.
## Extraído de Card.gd (Fase 4 de reestructuración).

var _card: Card


func setup(card: Card) -> void:
	_card = card


func move_to(target_pos: Vector2, duration: float = 0.3) -> void:
	"""Mueve la carta a una posición con animación"""
	var tween = _card.create_tween()
	tween.tween_property(_card, "position", target_pos, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func flip_card(face_up: bool, duration: float = 0.2) -> void:
	"""Voltea la carta"""
	_card.is_face_up = face_up

	var tween = _card.create_tween()
	tween.tween_property(_card, "scale:x", 0, duration / 2)
	tween.tween_callback(func():
		if _card.card_base:
			_card.card_base.visible = face_up
	)
	tween.tween_property(_card, "scale:x", _card.card_scale_normal, duration / 2)


func play_ability_activation_effect() -> void:
	"""Destello breve para confirmar visualmente que esta carta está
	disparando/activando una habilidad — antes no había ninguna señal salvo
	el log de consola, así que no se notaba qué carta estaba generando un
	efecto. Distinto del brillo celeste de set_activatable() (ese indica
	'disponible para usar', este 'se está usando ahora mismo')."""
	var flash = Panel.new()
	flash.name = "AbilityFlash"
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)

	var style = StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.85, 0.3, 0.0)
	style.border_color = Color(1.0, 0.9, 0.4, 1.0)
	style.set_border_width_all(4)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(1.0, 0.85, 0.3, 0.8)
	style.shadow_size = 14
	flash.add_theme_stylebox_override("panel", style)
	flash.modulate.a = 0.0

	_card.add_child(flash)
	_card.move_child(flash, 0)  # detrás del arte de la carta

	var tween = _card.create_tween()
	tween.tween_property(flash, "modulate:a", 1.0, 0.12)
	tween.tween_property(flash, "modulate:a", 0.0, 0.45)
	tween.tween_callback(flash.queue_free)


func play_destroy_animation() -> void:
	"""Animación cuando la carta es destruida"""
	var tween = _card.create_tween()
	tween.tween_property(_card, "modulate:a", 0, 0.3)
	tween.parallel().tween_property(_card, "scale", Vector2.ONE * 0.5, 0.3)
	tween.tween_callback(_card.queue_free)


func play_enter_animation() -> void:
	"""Animación cuando la carta entra en juego"""
	_card.scale = Vector2.ZERO
	_card.modulate.a = 0

	# Animar hacia base_scale, NO Vector2.ONE fijo (2026-08-29): un Arma
	# recién equipada (GoldManager._equip_weapon(), escala 0.45 de insignia
	# en la esquina del Aliado) llama a esta misma animación — con el target
	# fijo en 1.0 terminaba agrandada a tamaño de mano completa apenas
	# entraba en juego, y encima el hover posterior la recalculaba con un
	# base_scale que nunca se había actualizado a 0.45, dando la sensación de
	# que el Arma 'desaparecía y solo volvía a aparecer al pasar el mouse'.
	var target_scale: Vector2 = _card.base_scale if _card.base_scale != Vector2.ZERO else Vector2.ONE

	var tween = _card.create_tween()
	tween.tween_property(_card, "scale", target_scale, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.parallel().tween_property(_card, "modulate:a", 1, 0.2)
