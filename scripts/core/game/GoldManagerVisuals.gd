extends RefCounted
## GoldManagerVisuals — Tokens visuales de Oro (Reserva/Oro Pagado): conteo
## disponible, separación dinámica entre cartas de Oro, recorte de click para
## la superposición en cascada, e imagen/creación/despawn de tokens de Oro
## Virtual (genérico y restringido). Ninguna de estas funciones toca estado
## propio de GoldManager (oros_virtuales, restricted_gold_pools,
## virtual_gold_tokens siguen viviendo ahí — acá solo se opera sobre los
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
	que se acumulan, garantizando que siempre quepan dentro del área de
	oros (340px) sin invadir el campo.

	2026-09-04, aclarado por el usuario: la lógica correcta NO es 'nunca se
	tapan' (el rediseño a escala que se probó antes) — es que el click se
	resuelva por PRIORIDAD DE CAPA: la carta de ENCIMA tiene 100% de
	prioridad en toda su área (incluida la parte que tapa a la de abajo), y
	la de ABAJO tiene 100% de prioridad en lo que le queda expuesto, y así
	en cascada. Eso es exactamente lo que hace el recorte de click de
	Card._has_point()/_apply_gold_click_clip() — se mantiene la superposición
	(separación negativa) para que quepan más Oros sin achicarlos, con el
	recorte garantizando que cada capa responda 100% en su porción real."""
	if not container or not is_instance_valid(container):
		return
	var count: int = container.get_child_count()
	if count <= 1:
		container.add_theme_constant_override("separation", 6)
		_clear_gold_click_clip(container)
		container.queue_sort()
		return

	var max_width: float = 340.0
	var card_width: float = 150.0 * Constants.GOLD_CARD_SCALE.x
	var ideal_sep: float = (max_width - float(count) * card_width) / float(count - 1)
	# Piso en -95 (no -125): con -125 el área expuesta de cada carta tapada
	# bajaba hasta 25px de 150, un blanco incómodo de acertar aunque el
	# hit-test ya apuntara a la carta correcta. Con -95 el mínimo garantizado
	# sube a 55px — con muchos Oros a la vez el contenedor puede desbordar
	# un poco más allá de los 340px nominales, aceptado a propósito.
	var final_sep: int = int(clampf(ideal_sep, -95.0, 6.0))
	container.add_theme_constant_override("separation", final_sep)
	_apply_gold_click_clip(container, card_width, final_sep)
	container.queue_sort()


func _apply_gold_click_clip(container: HBoxContainer, card_width: float, final_sep: int) -> void:
	"""Recorta el área de CLICK (no el arte — Card._has_point(), 2026-09-03)
	de cada carta de Oro tapada por la derecha por la siguiente (superposición
	por separación negativa, ver _update_container_gold_spacing()). Cada carta
	sigue siendo un Control de 150px completo aunque solo se le vea una
	porción — sin este recorte, esa porción tapada seguía comiéndose los
	clicks (izquierdo Y derecho) que visualmente apuntaban a la carta
	siguiente, dibujada encima. La ÚLTIMA carta de la fila nunca está tapada,
	así que conserva el rect completo. Esto implementa la prioridad en
	cascada: capa de encima 100% en su rect completo, capa de abajo 100% en
	lo que le queda expuesto (2026-09-04, confirmado por el usuario)."""
	# card_width/final_sep están en unidades YA escaladas por GOLD_CARD_SCALE
	# (igual que el HBoxContainer las posiciona); Card._has_point() recibe el
	# punto en el espacio LOCAL sin escalar (Control.size se queda en 150,
	# solo card.scale la transforma visualmente) — hay que deshacer la escala.
	var scale_x: float = maxf(Constants.GOLD_CARD_SCALE.x, 0.001)
	var children := container.get_children()
	var exposed_width: float = (card_width + float(final_sep)) / scale_x if final_sep < 0 else -1.0
	for i in range(children.size()):
		var c = children[i]
		if not is_instance_valid(c) or not c.has_method("set_click_clip_right"):
			continue
		if i == children.size() - 1:
			c.set_click_clip_right(-1.0)
		else:
			c.set_click_clip_right(exposed_width)


func _clear_gold_click_clip(container: HBoxContainer) -> void:
	for c in container.get_children():
		if is_instance_valid(c) and c.has_method("set_click_clip_right"):
			c.set_click_clip_right(-1.0)


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


func _spawn_gold_token(nombre: String, label: String, target_list: Array) -> void:
	"""Token visual en Reserva de Oro con ilustración temática de ficha rúnica/éter."""
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
	_main.player_gold.add_child(token)
	target_list.append(token)
	update_gold_containers_spacing()


func _despawn_gold_token(target_list: Array) -> void:
	"""Retira un token con animación mágica de disolución y elevación."""
	if target_list.is_empty():
		return
	var token: Node = target_list.pop_back()
	if not is_instance_valid(token):
		return
	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.tween_property(token, "modulate:a", 0.0, 0.22)
	tween.tween_property(token, "scale", token.scale * 1.12, 0.22)
	tween.tween_property(token, "position:y", token.position.y - 20.0, 0.22)
	await tween.finished
	if is_instance_valid(token):
		if token.get_parent() == _main.player_gold:
			_main.player_gold.remove_child(token)
		token.queue_free()
		update_gold_containers_spacing()
