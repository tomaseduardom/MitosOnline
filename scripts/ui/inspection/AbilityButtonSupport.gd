extends RefCounted
## AbilityButtonSupport — validación de habilidades ACTIVADAS + ciclo de
## vida del botón superpuesto de habilidad (creación visual, activación vía
## ActionPipeline, brillo de "habilidad en la pila") extraído de
## CardInspectionLayer.gd (2026-09-06, "módulos gordos", Fase 2 — ver
## iterative-booping-abelson.md). Sin llamadores externos confirmados por
## grep — CardInspectionLayer.gd sigue siendo el único punto de entrada,
## ahora vía _button_support, montado en setup().

var _inspector: CardInspectionLayer
var _glowing_cards: Dictionary = {}


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _tamales_ability_restriction_reason(source_card: Node) -> String:
	"""Wrapper — la lógica real vive en ContinuousEffectManager.tamales_
	ability_restriction_reason() (2026-09-04, movida ahí para compartirla
	con TriggerSystem._check_trigger_conditions(), que necesita el mismo
	chequeo para 'ni disparar')."""
	return ContinuousEffectManager.tamales_ability_restriction_reason(source_card)


func _validate_ability(ability: Dictionary, source_card: Node) -> Dictionary:
	"""Valida si una habilidad activada puede ejecutarse ahora.
	Comprueba: prioridad, oro disponible, cartas en mano, carta girada, ActionPipeline."""
	if PriorityManager.priority_window_active and not PriorityManager.can_act(0):
		return {"can": false, "reason": "Sin prioridad ahora"}

	# Silenciada (por instancia o por nombre, ver KeywordManager.is_silenced())
	# = pierde TODAS sus habilidades, activadas incluidas — antes esto solo
	# se chequeaba para triggers (TriggerSystem._check_trigger_conditions()),
	# los botones de habilidad activada seguían mostrándose igual (2026-08-29).
	if KeywordManager.is_silenced(source_card):
		return {"can": false, "reason": "Sin habilidad (silenciada)"}

	# Restricción de fase por texto propio de la carta (2026-08-30, p.ej.
	# Espada de O'Higgins: "En tu Vigilia, una vez por turno, puedes...").
	# _build_ability_buttons() ya permite el botón en Vigilia O en ventana
	# de prioridad (genérico, para cartas sin restricción de fase) — esto
	# cierra el caso más estricto de una carta que solo se puede usar en su
	# propia Vigilia, ni siquiera con prioridad abierta en otra fase.
	var raw_lower: String = str(ability.get("raw_text", "")).to_lower()
	if "en tu vigilia" in raw_lower and GameManager.current_phase != Constants.Phase.VIGILIA:
		return {"can": false, "reason": "Solo en tu Vigilia"}

	# 'Tu oponente sólo puede utilizar las habilidades de Oros y cartas de
	# coste 2 o más si no controla más copias de esa carta' (2026-09-04,
	# Tamales) — único choke point real de validación de habilidades
	# ACTIVADAS, así que basta un chequeo acá para cubrir cualquier carta.
	var tamales_reason: String = _tamales_ability_restriction_reason(source_card)
	if not tamales_reason.is_empty():
		return {"can": false, "reason": tamales_reason}

	var cost_type   = ability.get("cost_type",   UniversalCardParser.CostType.NONE)
	var cost_amount = ability.get("cost_amount", 0)

	match cost_type:
		UniversalCardParser.CostType.GOLD:
			if _inspector._main._gold_manager:
				var available = _inspector._main._gold_manager.get_oro_disponible()
				if not _inspector._main._gold_manager.puede_pagar(cost_amount):
					return {"can": false, "reason": "Oro insuficiente (%d/%d)" % [available, cost_amount]}

		UniversalCardParser.CostType.DISCARD:
			var hand = _inspector._main.player_hand
			var count = hand.cards.size() if hand and hand.get("cards") != null else hand.get_child_count() if hand else 0
			if count == 0:
				return {"can": false, "reason": "Mano vacía"}

		UniversalCardParser.CostType.TAP:
			if source_card.get("is_tapped") == true:
				return {"can": false, "reason": "Carta ya girada"}

		UniversalCardParser.CostType.ONCE_PER_TURN:
			# instance_id, NO card_data.id (2026-08-30, corrección: card_data.id
			# es el ID de la carta/impresión, compartido por TODAS las copias en
			# juego — con 2 Aho en juego, usar uno marcaba el cupo también para
			# el otro. Cada copia física necesita su propio cupo).
			var card_id: String = str(source_card.get_instance_id())
			var ability_idx: int = ability.get("ability_index", 0)
			var turn: int = GameManager.current_turn
			if UniversalCardParser.turn_registry.was_used(card_id, ability_idx, turn):
				return {"can": false, "reason": "Ya usada este turno"}

	# Flag once_per_turn desde parse_abilities() (puede venir sin cost_type ONCE_PER_TURN)
	if ability.get("once_per_turn", false) and cost_type != UniversalCardParser.CostType.ONCE_PER_TURN:
		var card_id: String = str(source_card.get_instance_id())
		var ability_idx: int = ability.get("ability_index", 0)
		var turn: int = GameManager.current_turn
		if UniversalCardParser.turn_registry.was_used(card_id, ability_idx, turn):
			return {"can": false, "reason": "Ya usada este turno"}

	# Verificación adicional con ActionPipeline — source_card_node en el
	# context (2026-08-30) para que can_activate_ability() también use el
	# instance_id, no el id compartido entre copias.
	var context = {"controller_id": 0, "source_card_node": source_card}
	var check = ActionPipeline.can_activate_ability(source_card.card_data, ability, context)
	if not check.get("can", true):
		return {"can": false, "reason": check.get("reason", "No disponible")}

	return {"can": true, "reason": ""}


func _create_ability_overlay_button(ability: Dictionary, validation: Dictionary) -> Button:
	"""Botón superpuesto sobre el párrafo de la carta donde está impresa esta
	habilidad. No dibuja texto propio (la carta ya lo muestra); un
	rectángulo de bordes curvos color celeste marca SIEMPRE qué habilidad se
	puede activar y dónde clickear (2026-08-26, a pedido del usuario — antes
	el borde solo aparecía al pasar el mouse, así que no había forma de
	saber de antemano qué parte de la carta era clickeable). Al pasar el
	mouse se resalta más fuerte, y lleva el costo y efecto como tooltip."""
	var cost_type   = ability.get("cost_type",   UniversalCardParser.CostType.NONE)
	var cost_amount = ability.get("cost_amount", 0)
	var effect_text = ability.get("effect_text", ability.get("raw_text", ""))

	var cost_label: String
	match cost_type:
		UniversalCardParser.CostType.GOLD:
			cost_label = "Paga %d Oro" % cost_amount
		UniversalCardParser.CostType.ONCE_PER_TURN:
			cost_label = "Una vez por turno"
		UniversalCardParser.CostType.DISCARD:
			cost_label = "Descarta una carta"
		UniversalCardParser.CostType.TAP:
			cost_label = "Gira esta carta"
		_:
			cost_label = ability.get("cost_text", "")

	var btn = Button.new()
	btn.text = ""
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.tooltip_text = ""  # Sin texto negro explicativo en hover

	# Estilo normal: Cápsula dorada/ámbar cálida con sutil resplandor rúnico
	var style_normal = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.85, 0.65, 0.20, 0.08)
	style_normal.set_border_width_all(1)
	style_normal.border_color = Color(0.92, 0.78, 0.35, 0.85)
	style_normal.set_corner_radius_all(6)
	style_normal.shadow_color = Color(0.95, 0.75, 0.20, 0.25)
	style_normal.shadow_size = 2
	style_normal.anti_aliasing = true
	btn.add_theme_stylebox_override("normal", style_normal)
	btn.add_theme_stylebox_override("focus", style_normal)

	# Estilo hover: Oro brillante con halo de energía mística
	var style_hover = StyleBoxFlat.new()
	style_hover.bg_color = Color(0.95, 0.75, 0.25, 0.18)
	style_hover.set_border_width_all(1)
	style_hover.border_color = Color(1.0, 0.90, 0.45, 1.0)
	style_hover.set_corner_radius_all(6)
	style_hover.shadow_color = Color(1.0, 0.82, 0.30, 0.55)
	style_hover.shadow_size = 4
	style_hover.anti_aliasing = true
	btn.add_theme_stylebox_override("hover", style_hover)

	# Estilo pressed: Brillo de oro intenso
	var style_pressed = StyleBoxFlat.new()
	style_pressed.bg_color = Color(1.0, 0.85, 0.35, 0.30)
	style_pressed.set_border_width_all(1)
	style_pressed.border_color = Color(1.0, 0.98, 0.70, 1.0)
	style_pressed.set_corner_radius_all(6)
	style_pressed.shadow_color = Color(1.0, 0.90, 0.40, 0.75)
	style_pressed.shadow_size = 5
	style_pressed.anti_aliasing = true
	btn.add_theme_stylebox_override("pressed", style_pressed)

	return btn


func _activate_ability_via_pipeline(card_node: Node, card_data: Dictionary, ability: Dictionary, context: Dictionary) -> void:
	"""Envía la habilidad a la Pila LIFO y arranca el flujo Paso D.
	ActionPipeline se encarga de: Paso B (pagar), Paso C (triggers), añadir a pila, Paso D (ventana respuesta)."""
	print("[CardInspection] Activando habilidad '%s' vía Pila" % ability.get("cost_text", "?"))
	var result = await ActionPipeline.activate_ability(card_data, ability, context)
	if not result.get("success", false):
		_inspector._main._update_debug("Habilidad no pudo activarse: %s" % result.get("reason", "?"))
		return
	# Brillo en la carta fuente mientras la habilidad está en la pila
	if is_instance_valid(card_node):
		_start_card_glow(card_node)


func _activate_ability_with_glow(card_node: Node, card_data: Dictionary, ability: Dictionary, context: Dictionary) -> void:
	# Alias mantenido por compatibilidad — delega al nuevo método
	await _activate_ability_via_pipeline(card_node, card_data, ability, context)


func _start_card_glow(card_node: Node) -> void:
	if not is_instance_valid(card_node):
		return
	if card_node in _glowing_cards:
		_glowing_cards[card_node].kill()
	var tween = _inspector.create_tween().set_loops()
	tween.tween_property(card_node, "modulate", Color(1.5, 1.2, 0.2, 1.0), 0.45)
	tween.tween_property(card_node, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.45)
	_glowing_cards[card_node] = tween


func _stop_card_glow(card_node: Node) -> void:
	if card_node in _glowing_cards:
		_glowing_cards[card_node].kill()
		_glowing_cards.erase(card_node)
	if is_instance_valid(card_node):
		var tw = _inspector.create_tween()
		tw.tween_property(card_node, "modulate", Color.WHITE, 0.25)


func _on_ability_glow_resolved(stack_obj: Dictionary, _result: Dictionary) -> void:
	if not stack_obj.get("card_data", {}).get("_is_activated_ability", false):
		return
	var source_id = stack_obj.get("card_data", {}).get("id", "")
	if source_id.is_empty():
		return
	for card_node in _glowing_cards.keys():
		if not is_instance_valid(card_node):
			_glowing_cards.erase(card_node)
			continue
		var cd = card_node.get("card_data") if card_node.get("card_data") != null else {}
		if cd.get("id", "") == source_id:
			_stop_card_glow(card_node)
			break
