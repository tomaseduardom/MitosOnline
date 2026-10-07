extends RefCounted
## GoldManagerVisuals — Tokens visuales de Oro (Reserva/Oro Pagado): conteo
## disponible, separación dinámica entre cartas de Oro, recorte de click para
## la superposición en cascada, e imagen/creación/despawn de tokens de Oro
## Virtual (genérico y restringido). Ninguna de estas funciones toca estado
## propio de GoldManager (oros_virtuales, restricted_gold_pools,
## virtual_gold_tokens siguen viviendo ahí — aquí solo se opera sobre los
## Arrays de tokens que GoldManager pasa como parámetro, y sobre nodos de
## Main vía _main). Extraído de GoldManager.gd (2026-09-06, "módulos gordos",
## Fase 2) — confirmado por grep de todo scripts/ que ninguna de estas
## funciones tiene un llamador externo a GoldManager.gd salvo
## _update_gold_display() (GameBootstrap.gd, MulliganController.gd), que
## GoldManager.gd sigue exponiendo bajo el mismo nombre como forwarder.
## _despawn_gold_token() usa _main.create_tween()/_main.get_tree(), no un
## create_tween() propio — RefCounted no lo tiene, mismo patrón ya usado en
## AnimationEffects.gd (Fase 4).

var _main: Node = null


func setup(main: Node) -> void:
	_main = main


func _update_gold_display() -> void:
	var available = 0
	var valid_cards: Array = []
	for card in _main.gold_cards:
		if not is_instance_valid(card):
			continue
		valid_cards.append(card)
		if card.modulate == Color(1, 1, 1, 1):
			available += 1
	_main.gold_cards = valid_cards

	update_gold_containers_spacing()

	if _main._card_inspector:
		_main._card_inspector.refresh_activatable_glows()


func update_gold_containers_spacing() -> void:
	"""Calcula y ajusta la separación dinámica de las cartas de oro en Reserva
	y Oro Pagado para ambos jugadores, evitando que se superpongan en exceso.

	Reconstruida (2026-09-02, parse error reportado por el usuario): el
	cuerpo de esta función y el de puede_pagar() (más abajo) aparecieron
	truncados a la mitad — un 'if' sin bloque indentado y un 'return' de
	puede_pagar() pegado como si fuera parte de este 'if', con
	_update_container_gold_spacing(_main.player_gold) directamente
	desaparecido. No hay forma de recuperar los valores originales del
	cálculo de separación (la función que llaman, _update_container_gold_
	spacing(), tampoco existía en ningún lado del archivo), así que su
	implementación de más abajo es una reconstrucción conservadora nueva —
	revisala si la separación visual no queda como esperabas."""
	if not _main:
		return
	if _main.player_gold:
		_update_container_gold_spacing(_main.player_gold)
	if _main.player_oro_pagado:
		_update_container_gold_spacing(_main.player_oro_pagado)
	if _main.opponent_gold:
		_update_container_gold_spacing(_main.opponent_gold)
	if _main.opponent_oro_pagado:
		_update_container_gold_spacing(_main.opponent_oro_pagado)


func _update_container_gold_spacing(container: HBoxContainer) -> void:
	"""Comprime progresivamente la separación entre cartas de Oro a medida
	que se acumulan, garantizando que siempre quepan de forma ordenada dentro
	del área de oros (330px) sin invadir el campo. Las cartas se mantienen
	libres sobre el tablero, alineadas rectamente sobre el eje horizontal."""
	if not container or not is_instance_valid(container):
		return

	# Conectar señal sort_children una sola vez para mantener alineadas a Y=0 y escaladas
	# inmediatamente después de cualquier re-ordenamiento interno de Godot.
	if not container.has_meta("gold_sort_connected"):
		container.set_meta("gold_sort_connected", true)
		container.sort_children.connect(func():
			_on_container_sort_children(container)
		)

	var count: int = container.get_child_count()
	if count <= 1:
		container.add_theme_constant_override("separation", 6)
		_clear_gold_click_clip(container)
		_align_gold_cards(container)
		container.queue_sort()
		return

	var max_width: float = 330.0
	var card_visual_width: float = 150.0 * Constants.GOLD_CARD_SCALE.x  # 120.0
	var ideal_step: float = (max_width - card_visual_width) / float(count - 1)
	var step: float = minf(ideal_step, 130.0)  # Límite en 130px para dejar 10px de espacio libre entre 2 cartas
	var final_sep: int = int(round(step - 150.0))
	container.add_theme_constant_override("separation", final_sep)

	_apply_gold_click_clip(container, step)
	container.queue_sort()

	_align_gold_cards.call_deferred(container)


func _on_container_sort_children(container: HBoxContainer) -> void:
	if not is_instance_valid(container):
		return
	_align_gold_cards.call_deferred(container)


func _align_gold_cards(container: HBoxContainer) -> void:
	if not is_instance_valid(container):
		return
	var count := container.get_child_count()
	for i in range(count):
		var c = container.get_child(i)
		if not is_instance_valid(c):
			continue
		c.z_index = i
		if "original_z_index" in c:
			c.original_z_index = i
		if c is Control:
			if c.scale != Constants.GOLD_CARD_SCALE:
				c.scale = Constants.GOLD_CARD_SCALE
			if "base_scale" in c and c.base_scale != Constants.GOLD_CARD_SCALE:
				c.base_scale = Constants.GOLD_CARD_SCALE


func _apply_gold_click_clip(container: HBoxContainer, step: float) -> void:
	"""Recorta el área de CLICK en coordenadas locales de la carta cuando hay
	superposición, asegurando que cada carta de la baraja responda solo en su
	franja visible. Al pasar el cursor por encima (hover), CardInteraction eleva
	la carta y desactiva temporalmente el recorte para inspección completa."""
	var scale_x: float = maxf(Constants.GOLD_CARD_SCALE.x, 0.001)
	var card_visual_width: float = 150.0 * scale_x
	var children := container.get_children()
	var local_exposed: float = (step / scale_x) if step < card_visual_width else -1.0
	for i in range(children.size()):
		var c = children[i]
		if not is_instance_valid(c) or not c.has_method("set_click_clip_right"):
			continue
		if i == children.size() - 1:
			c.set_click_clip_right(-1.0)
			c.set_meta("gold_click_clip", -1.0)
			if c.has_method("set_click_clip_top_free"):
				c.set_click_clip_top_free(0.0)
		else:
			c.set_click_clip_right(local_exposed)
			c.set_meta("gold_click_clip", local_exposed)
			if c.has_method("set_click_clip_top_free"):
				c.set_click_clip_top_free(0.0)


func _clear_gold_click_clip(container: HBoxContainer) -> void:
	for c in container.get_children():
		if is_instance_valid(c):
			if c.has_method("set_click_clip_right"):
				c.set_click_clip_right(-1.0)
				c.set_meta("gold_click_clip", -1.0)
			if c.has_method("set_click_clip_top_free"):
				c.set_click_clip_top_free(0.0)


func _get_token_image_for_label(label: String) -> String:
	"""Selecciona la ilustración temática de Oro Virtual adecuada según la restricción."""
	var l := label.to_lower().strip_edges()
	if "caballero" in l:
		return "res://assets/ui/tokens/token_oro_arma_caballero.png"
	elif ("aliado" in l or "aliados" in l) and ("arma" in l or "armas" in l):
		return "res://assets/ui/tokens/token_oro_aliados_armas.png"
	elif ("arma" in l or "armas" in l) and ("tótem" in l or "totem" in l or "tótems" in l or "totems" in l):
		return "res://assets/ui/tokens/token_oro_armas_totem.png"
	elif ("aliado" in l or "aliados" in l) and ("tótem" in l or "totem" in l or "tótems" in l or "totems" in l):
		return "res://assets/ui/tokens/token_oro_aliados_totem.png"
	elif "coste 2" in l or "coste 3" in l or "o más" in l or "o mas" in l:
		return "res://assets/ui/tokens/token_oro_totem_coste2.png"
	elif "mismo tipo" in l:
		return "res://assets/ui/tokens/token_oro_mismo_tipo.png"
	elif "arma" in l or "armas" in l:
		return "res://assets/ui/tokens/token_oro_armas.png"
	elif "aliado" in l or "aliados" in l:
		return "res://assets/ui/tokens/token_oro_aliados.png"
	elif "tótem" in l or "totem" in l or "tótems" in l or "totems" in l:
		return "res://assets/ui/tokens/token_oro_totems.png"
	return "res://assets/ui/tokens/token_oro_libre.png"


func _spawn_gold_token(nombre: String, label: String, target_list: Array, player_id: int = 0) -> void:
	"""Token visual en Reserva de Oro con ilustración temática de ficha rúnica/éter.

	'player_id' (2026-10-06, ver arquitectura.md §33): a qué Reserva real
	(player_gold u opponent_gold) va el token — antes siempre player_gold,
	sin importar de quién era el Oro Virtual que representaba."""
	var image_path := _get_token_image_for_label(label)
	var token_data := {
		"id": "%s_token_%d" % [nombre.to_lower().replace(" ", "_"), Time.get_ticks_usec()],
		"nombre": nombre,
		"tipo": Constants.CardType.ORO,
		"coste": 0,
		"fuerza": 0,
		"habilidad": label,
		"raza": "",
		"imagen": image_path,
		"keywords": ["token", "virtual_gold"]
	}
	var token: Node = _main._create_card(token_data, false)
	token.can_interact = false
	token.scale = Constants.GOLD_CARD_SCALE
	token.base_scale = Constants.GOLD_CARD_SCALE
	token.set_zone(Constants.Zone.RESERVA_ORO)
	token.owner_id = player_id
	token.controller_id = player_id
	var reserva_container: HBoxContainer = _main.player_gold if player_id == 0 else _main.opponent_gold
	reserva_container.add_child(token)
	target_list.append(token)
	update_gold_containers_spacing()


func _despawn_gold_token(target_list: Array, player_id: int = 0) -> void:
	"""Retira un token con animación mágica de disolución y elevación."""
	if target_list.is_empty():
		return
	var token: Node = target_list.pop_back()
	if not is_instance_valid(token):
		return
	var reserva_container: HBoxContainer = _main.player_gold if player_id == 0 else _main.opponent_gold
	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(token, "modulate:a", 0.0, 0.22)
	tween.tween_property(token, "scale", token.scale * 1.12, 0.22)
	tween.tween_property(token, "position:y", token.position.y - 20.0, 0.22)
	await tween.finished
	if is_instance_valid(token):
		if token.get_parent() == reserva_container:
			reserva_container.remove_child(token)
		token.queue_free()
		update_gold_containers_spacing()
