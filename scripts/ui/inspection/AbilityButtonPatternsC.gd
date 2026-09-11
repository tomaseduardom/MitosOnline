extends RefCounted
## AbilityButtonPatternsC — tercer cuarto (por posición en el archivo
## original) de los patrones especiales de botones de habilidad ACTIVADA
## extraídos de CardInspectionLayer._build_ability_buttons() (2026-09-06,
## "módulos gordos", Fase 2). Ver AbilityButtonPatternsA.gd para la
## explicación completa del mecanismo try_build()/orden de evaluación.
##
## Frankenstein (silencio), Perla de Sangre (x2), Líder del Comité,
## Almirante Akari, Tótem Dragón Ancestral, Torre de Babel, Lanza Argenta,
## Skofnung, Espada de O'Higgins (barajar/buscar), Nu Galahad (x2),
## Visión Heroica, Shub-Niggurath (x2), Piruquina, Akari, quimera voragh
## (anular talismán).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func try_build(ability_lower: String, btn: Button, panel: Control, card_for_glow: Node, captured: Dictionary) -> bool:
	var is_frankenstein_silence_pattern: bool = "para que una carta pierda su habilidad por el turno" in ability_lower
	if is_frankenstein_silence_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_frankenstein_discard_silence_turn(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_perla_sangre_search_pattern: bool = "buscar en tu castillo un aliado y ponerlo en tu mano o jugarlo reduciendo su coste" in ability_lower
	if is_perla_sangre_search_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_perla_de_sangre_search_hand_or_play(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_perla_sangre_convert_pattern: bool = "para barajar y/o desterrar hasta cuatro cartas de los cementerios" in ability_lower
	if is_perla_sangre_convert_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_perla_de_sangre_convert_barajar_desterrar_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de akuma el terrible (2026-09-04): "Una vez por
	# turno, puedes Desterrar hasta dos cartas de los Cementerio o Roba
	# una carta" — elección A/B, ActionPipeline no resuelve un "o" entre
	# dos efectos de forma tan distinta (desterrar de Cementerio vs robar).
	var is_lider_comite_pattern: bool = "descartar una carta para mirar la mano de tu oponente y nombrar una carta" in ability_lower
	if is_lider_comite_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._search_handler._activate_lider_del_comite_discard_look_name_lock(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Almirante Akari removida de acá (2026-09-09, "sistema de respuestas" —
	# corregido a pedido del usuario): ya no es un botón con elección A/B
	# proactiva — son DOS disparadores reactivos distintos que comparten un
	# candado de una vez por turno (EffectController._prevention_registry
	# para "prevenir"; EffectController.offer_counter_annul() para "anular
	# cuando el rival juega una carta").

	var is_totem_dragon_pattern: bool = "en tu turno, puedes barajarlo para anular un aliado o cancelar una habilidad" in ability_lower
	if is_totem_dragon_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_totem_dragon_ancestral_shuffle_self_annul_or_cancel(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_torre_babel_pattern: bool = "para barajar y/o desterrar hasta cinco cartas de los cementerios y robar dos cartas" in ability_lower
	if is_torre_babel_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_torre_babel_shuffle_hand_for_cemeteries_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_lanza_argenta_pattern: bool = "puedes destruir esta arma para cancelar una habilidad o robar tres cartas" in ability_lower
	if is_lanza_argenta_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_lanza_argenta_destroy_self_cancel_or_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_skofnung_pattern: bool = "puedes barajarla de tu mano para buscar un oro en tu castillo" in ability_lower
	if is_skofnung_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_skofnung_shuffle_self_search_gold(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_espada_ohiggins_pattern: bool = "puedes barajar una carta que no sea oro o buscar un oro en tu castillo" in ability_lower
	if is_espada_ohiggins_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_espada_ohiggins_shuffle_or_search_gold(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_nu_galahad_look_play_pattern: bool = "mira tantas cartas del tope de tu castillo como armas controles" in ability_lower
	if is_nu_galahad_look_play_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_nu_galahad_look_play_weapon_and_ally_free(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_vision_heroica_pattern: bool = "para subir esta carta de tu cementerio a tu mano" in ability_lower
	if is_vision_heroica_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_vision_heroica_pay_raise_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_nu_galahad_wear_pattern: bool = "porta hasta tres cartas de un cementerio como armas sin habilidad" in ability_lower
	if is_nu_galahad_wear_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_nu_galahad_wear_cemetery_as_weapons(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_shub_shuffle_pattern: bool = "tu oponente bota dos cartas por cada aliado y/o tótem que controles" in ability_lower
	if is_shub_shuffle_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_shub_niggurath_shuffle_or_mill_opponent(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_shub_totem_pattern: bool = "generar un oro para jugar un tótem de coste 2 o más y robar una carta" in ability_lower
	if is_shub_totem_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_shub_niggurath_gold_for_totem_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_piruquina_pattern: bool = "ponerlo en el fondo de tu castillo para reducir a cero el próximo daño" in ability_lower
	if is_piruquina_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_piruquina_pay_bottom_deck_prevent(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_akari_pattern: bool = "puedes desterrarlo para anular una carta de coste 1 o menos que no sea aliado" in ability_lower
	if is_akari_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_akari_banish_annul_non_ally(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_quimera_voragh_pattern: bool = "puedes desterrarlo para anular un talismán de coste 1 o menos y roba una carta" in ability_lower
	if is_quimera_voragh_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_quimera_voragh_banish_annul_talisman_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	return false
