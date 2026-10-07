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

## Colores del brillo de set_activatable() (2026-09-15, a pedido del usuario):
## antes era SIEMPRE dorado sin importar el motivo — ahora distingue "por qué
## brilla" con 3 colores fijos, usados desde CardInteractionModule.gd/
## TriggerSystem.gd: DORADO = "disparadas" (habilidad activable disponible,
## u orden de triggers a elegir — CardInspectionLayer.refresh_activatable_
## glows()/TriggerSystem._prompt_trigger_order()); CELESTE = objetivo válido
## PROPIO de una selección en curso; ROJO = objetivo válido RIVAL. Ver
## CardInteractionModule._glow_valid_targets()/await_multi_target().
const GLOW_COLOR_GOLD := Color(1.0, 0.85, 0.38, 1.0)
const GLOW_COLOR_CELESTE := Color(0.35, 0.78, 1.0, 1.0)
const GLOW_COLOR_RED := Color(1.0, 0.32, 0.30, 1.0)

var _card: Card

var activatable_glow: Panel = null  # Indicador de "tiene una habilidad activada disponible ahora"
var _activatable_tween: Tween = null
var is_activatable: bool = false
## Motivos independientes de brillo activo (StringName -> Color), 2026-09-30
## fix de revisión: antes un solo is_activatable/color representaba a la vez
## "habilidad activable" (CardInspectionLayer) Y "objetivo de una selección
## en curso" (CardInteractionModule/GoldManager) — apagar uno apagaba el
## otro aunque siguiera vigente. Ver set_activatable() más abajo.
var _activatable_reasons: Dictionary = {}

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
	style.bg_color = Color(GLOW_COLOR_GOLD.r, GLOW_COLOR_GOLD.g, GLOW_COLOR_GOLD.b, 0.0)
	style.border_color = Color(GLOW_COLOR_GOLD.r, GLOW_COLOR_GOLD.g, GLOW_COLOR_GOLD.b, 0.95)
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(GLOW_COLOR_GOLD.r, GLOW_COLOR_GOLD.g, GLOW_COLOR_GOLD.b, 0.55)
	style.shadow_size = 10
	activatable_glow.add_theme_stylebox_override("panel", style)

	_card.add_child(activatable_glow)
	_card.move_child(activatable_glow, 0)  # detrás del arte de la carta


func _create_strength_badge() -> void:
	"""Crea el badge de Placa Heráldica en la esquina superior izquierda (+X esmeralda / -X rubí)."""
	var container = Control.new()
	container.name = "StrengthBadge"
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.position = Vector2(26, 4)
	container.size = Vector2(28, 34)
	container.pivot_offset = Vector2(14, 17)
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
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.12, 0.03, 0.85))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("shadow_outline_size", 0)
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0.01, 0.18, 0.04, 0.98))
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
	container.position = Vector2(_card.custom_minimum_size.x - 52.0, 4)
	container.size = Vector2(28, 34)
	container.pivot_offset = Vector2(14, 17)
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
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.12, 0.03, 0.85))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("shadow_outline_size", 0)
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0.01, 0.18, 0.04, 0.98))
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
			_strength_plaque_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
			_strength_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.12, 0.03, 0.85))
			_strength_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.01, 0.18, 0.04, 0.98))
		else:
			_strength_plaque_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
			_strength_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.15, 0.01, 0.01, 0.85))
			_strength_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.22, 0.02, 0.02, 0.98))

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
			_cost_plaque_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
			_cost_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.12, 0.03, 0.85))
			_cost_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.01, 0.18, 0.04, 0.98))
		else:
			_cost_plaque_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
			_cost_plaque_lbl.add_theme_color_override("font_shadow_color", Color(0.15, 0.01, 0.01, 0.85))
			_cost_plaque_lbl.add_theme_color_override("font_outline_color", Color(0.22, 0.02, 0.02, 0.98))

	if not cost_badge.visible:
		cost_badge.visible = true
		cost_badge.scale = Vector2(1.35, 1.35)
		var tw = _card.create_tween()
		tw.tween_property(cost_badge, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	else:
		cost_badge.visible = true


func set_activatable(value: bool, glow_color: Color = GLOW_COLOR_GOLD, reason: StringName = &"ability") -> void:
	"""Muestra u oculta el brillo que indica 'esto es relevante ahora mismo'
	— dorado por defecto ('tienes una habilidad activable disponible ahora
	mismo', o el orden de triggers a elegir — distinto del brillo amarillo
	desde CardInspectionLayer.refresh_activatable_glows()).
	'glow_color' (2026-09-15, a pedido del usuario): CardInteractionModule.
	_glow_valid_targets()/await_multi_target() lo llaman con GLOW_COLOR_
	CELESTE/GLOW_COLOR_RED para distinguir objetivo propio de objetivo
	rival en una selección — el color se re-aplica en cada llamado con
	value=true, incluso si ya estaba prendida (p.ej. una carta que YA
	brillaba dorada por tener una habilidad activable y ahora además es
	objetivo rival de otra selección concurrente pasa a rojo).

	'reason' (2026-09-30, fix de revisión — hallazgo real: un solo bool
	'is_activatable' representaba a la vez tres motivos independientes
	["habilidad activable" de CardInspectionLayer, "objetivo propio/rival de
	una selección en curso" de CardInteractionModule, "elegí qué Oro gastar"
	de GoldManager] — apagar UN motivo (value=false) apagaba el brillo
	entero aunque otro motivo siguiera vigente: una carta que brillaba
	dorada por tener una habilidad activable, y que de paso se vuelve
	objetivo válido de una selección en curso, perdía su brillo dorado
	apenas esa selección terminaba, aunque la habilidad siguiera activable.
	Ahora cada motivo se registra por separado en _activatable_reasons y el
	brillo solo se apaga del todo cuando ninguno queda. Los llamadores que no
	son CardInspectionLayer DEBEN pasar su propio 'reason' explícito (p.ej.
	&"target_select") — el default &"ability" es el motivo original de
	CardInspectionLayer, para no tener que tocar sus llamados existentes."""
	if value:
		_activatable_reasons[reason] = glow_color
	else:
		_activatable_reasons.erase(reason)
	is_activatable = not _activatable_reasons.is_empty()
	if not activatable_glow:
		return
	if is_activatable:
		# Prioridad visual: el motivo de selección en curso (si hay uno) pisa
		# al de "habilidad activable" — es el más urgente/contextual ahora
		# mismo. Si por algún motivo hay más de uno sin ser "target_select",
		# gana cualquiera (mismo comportamiento que antes de este fix).
		var active_color: Color = _activatable_reasons.get(&"target_select", _activatable_reasons.values()[0])
		var style: StyleBoxFlat = activatable_glow.get_theme_stylebox("panel")
		if style:
			style.bg_color = Color(active_color.r, active_color.g, active_color.b, style.bg_color.a)
			style.border_color = Color(active_color.r, active_color.g, active_color.b, 0.95)
			style.shadow_color = Color(active_color.r, active_color.g, active_color.b, 0.55)
		if not activatable_glow.visible:
			activatable_glow.visible = true
			activatable_glow.modulate.a = 0.3
			if _activatable_tween and _activatable_tween.is_valid():
				_activatable_tween.kill()
			_activatable_tween = _card.create_tween()
			_activatable_tween.set_loops()
			_activatable_tween.tween_property(activatable_glow, "modulate:a", 1.0, 0.6).set_ease(Tween.EASE_IN_OUT)
			_activatable_tween.tween_property(activatable_glow, "modulate:a", 0.3, 0.6).set_ease(Tween.EASE_IN_OUT)
	else:
		if _activatable_tween and _activatable_tween.is_valid():
			_activatable_tween.kill()
		activatable_glow.visible = false
