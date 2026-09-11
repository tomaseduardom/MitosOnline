extends RefCounted
class_name CardBadges
## CardBadges — Badges visuales de una carta: el brillo celeste de "habilidad
## activable ahora" y las Placas Heráldicas de Fuerza/Coste efectivos
## (verde=buff/descuento, rojo=debuff/recargo). Opera sobre el nodo Card via
## _card. Card.gd reenvía como wrappers públicos los métodos que otros
## sistemas llaman directamente sobre la carta (refresh_strength_badge,
## refresh_cost_badge, set_activatable — llamados desde muchos managers cada
## vez que un modificador continuo puede haber cambiado el valor mostrado).
## Extraído de Card.gd (2026-09-06, "módulos gordos" — mismo corte que ya
## separó CardInteraction.gd/CardAnimations.gd, Fase 4 de reestructuración).

const PlaqueBuffEmerald = preload("res://assets/ui/badges/plaque_buff_emerald.png")
const PlaqueDebuffRuby = preload("res://assets/ui/badges/plaque_debuff_ruby.png")

var _card: Card

var activatable_glow: Panel = null  # Indicador de "tiene una habilidad activada disponible ahora"
var _activatable_tween: Tween = null
var is_activatable: bool = false

var strength_badge: Control = null
var _strength_plaque_tex: TextureRect = null
var _strength_plaque_lbl: Label = null

## Badge de Coste efectivo con Placa Heráldica (-X esmeralda / +X rubí)
var cost_badge: Control = null
var _cost_plaque_tex: TextureRect = null
var _cost_plaque_lbl: Label = null


func setup(card: Card) -> void:
	_card = card


# =============================================================================
# INDICADOR DE HABILIDAD ACTIVABLE
# Distinto de "disparar" (trigger, automático) — esto es una habilidad que
# el jugador PUEDE elegir usar ahora mismo. Brillo celeste pulsante,
# independiente del brillo amarillo de CardInspectionLayer (ese indica
# "resolviéndose en la pila", no "disponible para activar").
# =============================================================================
func _create_activatable_glow() -> void:
	"""Crea el panel de brillo celeste, oculto por defecto. Se construye por
	código (no en el .tscn) para no tocar la escena de Card, igual que
	hover_effect/selection_effect en espíritu pero como nodo nuevo."""
	activatable_glow = Panel.new()
	activatable_glow.name = "ActivatableGlow"
	activatable_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	activatable_glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	activatable_glow.visible = false

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.9, 0.7, 0.2, 0.0)
	style.border_color = Color(1.0, 0.85, 0.38, 0.95)
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(1.0, 0.78, 0.25, 0.55)
	style.shadow_size = 10
	activatable_glow.add_theme_stylebox_override("panel", style)

	_card.add_child(activatable_glow)
	_card.move_child(activatable_glow, 0)  # detrás del arte de la carta


func _create_strength_badge() -> void:
	"""Crea el badge de Placa Heráldica en la esquina superior izquierda (+X esmeralda / -X rubí)."""
	var container = Control.new()
	container.name = "StrengthBadge"
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.position = Vector2(25, 4)
	container.size = Vector2(26, 30)
	container.pivot_offset = Vector2(13, 15)
	container.visible = false

	var tex_rect = TextureRect.new()
	tex_rect.name = "PlaqueTexture"
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tex_rect.anchor_right = 1.0
	tex_rect.anchor_bottom = 1.0
	container.add_child(tex_rect)
	_strength_plaque_tex = tex_rect

	var lbl = Label.new()
	lbl.name = "PlaqueLabel"
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.anchor_right = 1.0
	lbl.anchor_bottom = 1.0
	lbl.offset_top = -2.0
	lbl.offset_bottom = -2.0
	lbl.add_theme_font_override("font", preload("res://assets/fonts/Cinzel-Bold.ttf"))
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.92, 1.0, 0.92, 1.0))
	lbl.add_theme_color_override("font_shadow_color", Color(0.01, 0.20, 0.05, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("shadow_outline_size", 2)
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.25, 0.08, 0.95))
	container.add_child(lbl)
	_strength_plaque_lbl = lbl

	strength_badge = container
	_card.add_child(strength_badge)
	_card.move_child(strength_badge, _card.get_child_count() - 1)


func _create_cost_badge() -> void:
	"""Crea el badge de Placa Heráldica de Coste en la esquina superior derecha (-X esmeralda / +X rubí)."""
	var container = Control.new()
	container.name = "CostBadge"
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.position = Vector2(_card.custom_minimum_size.x - 51.0, 4)
	container.size = Vector2(26, 30)
	container.pivot_offset = Vector2(13, 15)
	container.visible = false

	var tex_rect = TextureRect.new()
	tex_rect.name = "PlaqueTexture"
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tex_rect.anchor_right = 1.0
	tex_rect.anchor_bottom = 1.0
	container.add_child(tex_rect)
	_cost_plaque_tex = tex_rect

	var lbl = Label.new()
	lbl.name = "PlaqueLabel"
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.anchor_right = 1.0
	lbl.anchor_bottom = 1.0
	lbl.offset_top = -2.0
	lbl.offset_bottom = -2.0
	lbl.add_theme_font_override("font", preload("res://assets/fonts/Cinzel-Bold.ttf"))
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.92, 1.0, 0.92, 1.0))
	lbl.add_theme_color_override("font_shadow_color", Color(0.01, 0.20, 0.05, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("shadow_outline_size", 2)
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.25, 0.08, 0.95))
	container.add_child(lbl)
	_cost_plaque_lbl = lbl

	cost_badge = container
	_card.add_child(cost_badge)
	_card.move_child(cost_badge, _card.get_child_count() - 1)


func refresh_strength_badge(source_override: Node = null) -> void:
	"""Recalcula y muestra la Fuerza efectiva AHORA — llamar justo después de equipar/quitar un Arma
	o cualquier acción que pueda afectar la Fuerza de esta carta."""
	var effective := _card.card_strength
	if ContinuousEffectManager.has_method("get_modified_strength"):
		effective = ContinuousEffectManager.get_modified_strength(source_override if source_override else _card)
	_apply_strength_badge_text(effective)


func _apply_strength_badge_text(value: int) -> void:
	if not strength_badge:
		return
	if _card.card_type != Constants.CardType.ALIADO or _card.esta_oculta:
		strength_badge.visible = false
		return
	if value == _card.card_strength:
		strength_badge.visible = false
		return

	var diff := value - _card.card_strength
	var is_buff := diff > 0
	var text_val := ("+%d" % diff) if is_buff else str(diff)

	if _strength_plaque_tex:
		_strength_plaque_tex.texture = PlaqueBuffEmerald if is_buff else PlaqueDebuffRuby
	if _strength_plaque_lbl:
		_strength_plaque_lbl.text = text_val
		if is_buff:
			_strength_plaque_lbl.add_theme_color_override("font_color", Color(0.92, 1.0, 0.92, 1.0))
			_strength_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.01, 0.20, 0.05, 0.95))
			_strength_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.25, 0.08, 0.95))
		else:
			_strength_plaque_lbl.add_theme_color_override("font_color", Color(1.0, 0.90, 0.90, 1.0))
			_strength_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.25, 0.02, 0.02, 0.95))
			_strength_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.30, 0.03, 0.03, 0.95))

	if not strength_badge.visible:
		strength_badge.visible = true
		strength_badge.scale = Vector2(1.35, 1.35)
		var tw = _card.create_tween()
		tw.tween_property(strength_badge, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	else:
		strength_badge.visible = true


func refresh_cost_badge(source_override: Node = null) -> void:
	"""Recalcula y muestra el Coste efectivo AHORA — llamar después de cualquier acción que pueda cambiarlo."""
	var effective := _card.card_cost
	if PaymentManager.has_method("calcular_coste_real"):
		effective = PaymentManager.calcular_coste_real(source_override if source_override else _card)
	_apply_cost_badge_text(effective)


func _apply_cost_badge_text(value: int) -> void:
	if not cost_badge:
		return
	if _card.esta_oculta:
		cost_badge.visible = false
		return
	if value == _card.card_cost:
		cost_badge.visible = false
		return

	var diff := value - _card.card_cost
	var is_discount := diff < 0
	var text_val := str(diff) if is_discount else ("+%d" % diff)

	if _cost_plaque_tex:
		_cost_plaque_tex.texture = PlaqueBuffEmerald if is_discount else PlaqueDebuffRuby
	if _cost_plaque_lbl:
		_cost_plaque_lbl.text = text_val
		if is_discount:
			_cost_plaque_lbl.add_theme_color_override("font_color", Color(0.92, 1.0, 0.92, 1.0))
			_cost_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.01, 0.20, 0.05, 0.95))
			_cost_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.25, 0.08, 0.95))
		else:
			_cost_plaque_lbl.add_theme_color_override("font_color", Color(1.0, 0.90, 0.90, 1.0))
			_cost_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.25, 0.02, 0.02, 0.95))
			_cost_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.30, 0.03, 0.03, 0.95))

	if not cost_badge.visible:
		cost_badge.visible = true
		cost_badge.scale = Vector2(1.35, 1.35)
		var tw = _card.create_tween()
		tw.tween_property(cost_badge, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	else:
		cost_badge.visible = true


func set_activatable(value: bool) -> void:
	"""Muestra u oculta el brillo celeste que indica 'tienes una habilidad
	activable disponible ahora mismo' (distinto del brillo amarillo de
	desde CardInspectionLayer.refresh_activatable_glows()."""
	if is_activatable == value:
		return
	is_activatable = value
	if not activatable_glow:
		return
	if _activatable_tween and _activatable_tween.is_valid():
		_activatable_tween.kill()
	if value:
		activatable_glow.visible = true
		activatable_glow.modulate.a = 0.3
		_activatable_tween = _card.create_tween()
		_activatable_tween.set_loops()
		_activatable_tween.tween_property(activatable_glow, "modulate:a", 1.0, 0.6).set_ease(Tween.EASE_IN_OUT)
		_activatable_tween.tween_property(activatable_glow, "modulate:a", 0.3, 0.6).set_ease(Tween.EASE_IN_OUT)
	else:
		activatable_glow.visible = false
