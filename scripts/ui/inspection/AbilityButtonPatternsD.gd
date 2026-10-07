extends RefCounted
## AbilityButtonPatternsD — cuarto y último grupo (por posición en el archivo
## original) de los patrones especiales de botones de habilidad ACTIVADA
## extraídos de CardInspectionLayer._build_ability_buttons() (2026-09-06,
## "módulos gordos", Fase 2). Ver AbilityButtonPatternsA.gd para la
## explicación completa del mecanismo try_build()/orden de evaluación.
##
## Uriel, Atenea, Sumi, Gran Kraken, Ereshkigal, Campanita, akuma el
## terrible, Chakram, Estaca (x2), Ángel Redentor, Espada del Juicio,
## Drácula (x2), Espíritu Kotaix, Sacrificio Solar, La Ouija.

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func try_build(ability_lower: String, btn: Button, panel: Control, card_for_glow: Node, captured: Dictionary) -> bool:
	var is_uriel_pattern: bool = "baraja y/o destierra hasta tres cartas de los cementerios, roba una carta y destierra una carta de tu mano" in ability_lower
	if is_uriel_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_uriel_shuffle_banish_draw_discard(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_atenea_pattern: bool = "un aliado hace doble daño de combate al destierro" in ability_lower
	if is_atenea_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_atenea_grant_double_damage_exile(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_sumi_pattern: bool = "puedes descartarlo de tu mano para que una carta de coste 1 en tu cementerio gane exhumar" in ability_lower
	if is_sumi_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_sumi_discard_grant_exhumar(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_gran_kraken_pattern: bool = "puedes descartar una carta para destruir una carta de coste 3 o menos" in ability_lower
	if is_gran_kraken_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_gran_kraken_discard_destroy(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_ereshkigal_pattern: bool = "puedes desterrar una carta de coste 1 o menos o barajar y/o desterrar dos cartas de los cementerios" in ability_lower
	if is_ereshkigal_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_ereshkigal_banish_cost1_or_cemeteries(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_campanita_pattern: bool = "puedes desterrarlo para cancelar una habilidad o robar dos cartas" in ability_lower
	if is_campanita_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_campanita_banish_cancel_or_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_akuma_pattern: bool = "puedes desterrar hasta dos cartas de los cementerio" in ability_lower and "roba una carta" in ability_lower
	if is_akuma_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_akuma_banish_or_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Chakram (2026-08-30): "Una vez por turno, puedes
	# mirar la mano de tu oponente y elegir una carta de ahí que no sea
	# Oro para que no pueda ser jugada hasta tu próximo turno y Roba una
	# carta." — reveal privado de la mano rival + candado por carta
	# puntual (GoldManager.lock_card_from_playing()), ningún concepto que
	# ActionPipeline resuelva solo.
	var is_chakram_pattern: bool = ("mirar la mano de tu oponente" in ability_lower
		and "no pueda ser jugada" in ability_lower)
	if is_chakram_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._search_handler._activate_chakram_look_and_lock(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Estaca (2026-08-30): "Una vez por turno, puedes
	# Robar tres cartas, Barajar una carta oponente que no sea Oro y
	# tantas cartas de tu mano como coste tenga." — la carta oponente no
	# dice zona (EN JUEGO, ver [[project_no_zone_means_in_play]]) y la
	# cantidad a barajar de la propia mano es DINÁMICA (el coste de la
	# carta rival elegida), nada de esto lo resuelve ActionPipeline solo.
	var is_estaca_pattern: bool = ("barajar una carta oponente que no sea oro" in ability_lower
		and "tantas cartas de tu mano como coste tenga" in ability_lower)
	if is_estaca_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._hand_cementerio_handler._activate_estaca_draw_and_shuffle(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Estaca (segunda habilidad) y Ángel Redentor removidos de aquí
	# (2026-09-09, "sistema de respuestas"): ya no son botones que el
	# jugador activa desde el Zoom — EffectController.offer_prevention()
	# las detecta y ofrece reactivamente en el momento exacto en que
	# corresponde (ver el registro en EffectController.gd). Los handlers
	# viejos (_activate_estaca_banish_for_prevention/_activate_angel_
	# redentor_prevent en PreventionAbilityHandler_EP.gd/_AE.gd) se
	# eliminaron junto con este bloque.

	# Patrón especial de Espada del Juicio (2026-08-30): "Puedes
	# Desterrarla de tu Cementerio para que un Aliado gane o pierda 2
	# de Fuerza permanentemente." — primera habilidad usable DESDE EL
	# CEMENTERIO de esta sesión (ver _ability_is_cementerio_usable()),
	# costo sobre el DATO real del Cementerio (no sobre este nodo de
	# solo vista) + elegir Aliado y signo del bono.
	var is_espada_juicio_pattern: bool = ("desterrarla de tu cementerio" in ability_lower
		and "gane o pierda 2 de fuerza" in ability_lower)
	if is_espada_juicio_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._hand_cementerio_handler._activate_espada_juicio_banish_cemetery_for_buff(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Drácula (tercera habilidad, "convertirlo... para prevenir...")
	# removida de aquí (2026-09-09, "sistema de respuestas") — mismo motivo
	# que Estaca/Ángel Redentor arriba: ya no es un botón, es reactiva.

	# Patrón especial de Drácula, cuarta habilidad (2026-08-30): "Puedes
	# Desterrarlo de tu mano o Cementerio para cancelar el ataque de
	# hasta dos Aliados." — usable DESDE LA MANO o el CEMENTERIO (ver
	# _ability_is_hand_usable()/_ability_is_cementerio_usable()), primera
	# habilidad que cancela un ataque ya declarado (nuevo: sacar de
	# GameManager.attackers + revertir el aspecto visual, sin pasar por
	# undeclare_attacker() porque no requiere ser el propio turno del
	# controlador de ese Aliado).
	var is_dracula_cancel_attack_pattern: bool = ("desterrarlo de tu mano o cementerio" in ability_lower
		and "cancelar el ataque" in ability_lower)
	if is_dracula_cancel_attack_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._hand_cementerio_handler._activate_dracula_cancel_attacks(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Espíritu Kotaix, segunda habilidad (2026-09-02):
	# "Una vez por turno, Roba dos cartas y Baraja una carta oponente que
	# no sea Oro. Esta habilidad no puede ser cancelada." — mismo patrón
	# que Estaca (Robo incondicional + Baraja de una carta rival en juego
	# excluyendo Oro), sin el barajado adicional de la propia mano.
	var is_kotaix_pattern: bool = "baraja una carta oponente que no sea oro" in ability_lower
	if is_kotaix_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._search_handler._activate_kotaix_draw_and_shuffle_opponent(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Sacrificio Solar (2026-09-02): "Puedes pagar un
	# Oro y Barajar esta carta desde tu mano para Desterrar o Barajar
	# una carta de coste 2 o menos y Robar una carta." — usable DESDE LA
	# MANO (ver _ability_is_hand_usable()), costo de Oro + la propia
	# carta (autobarajarse desde la mano, no destierro ni descarte —
	# concepto que ActionPipeline no tiene) y elección Destierra/Baraja
	# sobre el objetivo, algo que tampoco resuelve solo.
	var is_sacrificio_solar_pattern: bool = "barajar esta carta desde tu mano" in ability_lower
	if is_sacrificio_solar_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._hand_cementerio_handler._activate_sacrificio_solar_self_shuffle_banish_or_shuffle(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de La Ouija (2026-08-31): "Una vez por turno, puedes
	# jugar una carta de tu Cementerio o del tope de tu Castillo." — dos
	# zonas de origen alternativas ('de tu Cementerio' Y 'del tope de tu
	# Castillo', ambas con posesivo — solo las propias) que ActionPipeline
	# no resuelve solo (solo sabe jugar la carta que ya tienes en mano).
	var is_ouija_pattern: bool = ("jugar una carta de tu cementerio" in ability_lower
		and "tope de tu castillo" in ability_lower)
	if is_ouija_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._hand_cementerio_handler._activate_ouija_play_from_cemetery_or_deck_top(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	return false
