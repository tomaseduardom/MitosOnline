extends RefCounted
## AbilityButtonPatternsB — segundo cuarto (por posición en el archivo
## original) de los patrones especiales de botones de habilidad ACTIVADA
## extraídos de CardInspectionLayer._build_ability_buttons() (2026-09-06,
## "módulos gordos", Fase 2). Ver AbilityButtonPatternsA.gd para la
## explicación completa del mecanismo try_build()/orden de evaluación.
##
## Tyet (segunda habilidad), Ramón Freire, Espada de O'Higgins (Vigilia),
## Infernum Vox, Paladín Bestiarium (x2), Crono Diamante, Aho, Kuchiku Kan,
## Kuchiku El Cazador (x2), Quantum Megumi, Sake, Dulce Canasta, Belta (x2),
## Espíritu Máquina, Frankenstein (cancelar).

var _inspector: CardInspectionLayer


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func try_build(ability_lower: String, btn: Button, panel: Control, card_for_glow: Node, captured: Dictionary) -> bool:
	# Segundo patrón de Tyet (2026-08-30): "Puedes poner esta y otra
	# carta de tu mano en el fondo de tu Castillo y Robar dos cartas." —
	# usable DESDE LA MANO (ver _ability_is_hand_usable()). Costo:
	# esta carta + otra elegida de la mano, ambas al fondo del mazo.
	var is_tyet_mill_pattern: bool = ("esta y otra carta de tu mano" in ability_lower
		and "fondo de tu castillo" in ability_lower)
	if is_tyet_mill_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._hand_cementerio_handler._activate_tyet_mill_and_draw(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Ramón Freire (2026-08-30): "Si controlas
	# Aliados de coste 2 o más, puedes Desterrarlo de tu mano o en
	# juego para generar un Oro para jugar Armas." — usable DESDE LA
	# MANO o ya en juego, con una condición previa (controlar un Aliado
	# de coste ≥2) que ActionPipeline no sabe verificar.
	var is_ramon_freire_pattern: bool = ("desterrarlo de tu mano o en juego" in ability_lower
		and "generar un oro" in ability_lower)
	if is_ramon_freire_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._hand_cementerio_handler._activate_ramon_freire_banish_for_gold(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón de Espada de O'Higgins removido de acá (2026-09-07, bug real
	# encontrado en auditoría): este guard ("barajar una carta que no sea
	# oro" + "buscar un oro en tu castillo") es un subconjunto estricto del
	# guard de AbilityButtonPatternsC.gd ("puedes barajar una carta que no
	# sea oro o buscar un oro en tu castillo") — como el despacho es A→B→C→D
	# con el primer match ganando, este bloque SIEMPRE se adelantaba al de C
	# y dejaba _activate_espada_ohiggins_shuffle_or_search_gold() (el fix
	# correcto del 2026-09-04: registra el uso DESPUÉS de confirmar objetivo,
	# no antes) permanentemente inalcanzable. _activate_espada_ohiggins_
	# vigilia_choice() (SearchAbilityHandler_AI.gd) queda sin llamador —
	# handler viejo superado, no se borró por las dudas de que algo más lo
	# referencie a futuro.

	# Patrón especial de Infernum Vox (2026-08-30): "Una vez por turno,
	# puedes mirar seis cartas del tope de un Castillo y devolverlas en
	# cualquier orden en el tope y/o fondo del Castillo." — puro
	# reordenamiento (no es 'mirar y jugar/quedarte una', es 'mirar y
	# repartir+ordenar TODAS'), un concepto que ActionPipeline no tiene.
	var is_infernum_vox_pattern: bool = ("mirar" in ability_lower
		and "cartas del tope de un castillo" in ability_lower
		and "tope y/o fondo" in ability_lower)
	if is_infernum_vox_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._search_handler._activate_infernum_vox_look_reorder(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Paladín Bestiarium — habilidad 1 (2026-08-30):
	# "Una vez por turno, puedes Descartar una carta para jugar un Arma
	# de tu mano reduciendo su coste en un Oro, hasta un mínimo de 0." —
	# el costo (descartar CUALQUIER carta) y el efecto (jugar OTRA carta
	# distinta con descuento) no coinciden, ActionPipeline solo sabe
	# resolver costo+efecto sobre la MISMA carta.
	var is_paladin_bestiarium_discard_pattern: bool = ("descartar una carta para jugar un arma" in ability_lower
		and "reduciendo su coste" in ability_lower)
	if is_paladin_bestiarium_discard_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_paladin_bestiarium_discard_weapon_discount(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Crono Diamante (2026-09-02): "Una vez por
	# turno, si jugaste un Aliado de coste 2 o más este turno, puedes
	# Descartar una carta para jugar un Aliado reduciendo su coste en
	# un Oro, hasta un mínimo de 1." — mismo esqueleto que Paladín
	# Bestiarium (descartar + jugar otra con descuento) pero para
	# Aliados, con condición previa y piso 1 en vez de 0.
	var is_crono_diamante_pattern: bool = ("descartar una carta para jugar un aliado" in ability_lower
		and "reduciendo su coste" in ability_lower)
	if is_crono_diamante_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_crono_diamante_discard_ally_discount(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Paladín Bestiarium — habilidad 2 (2026-08-30):
	# "Una vez en tu turno, puedes Descartar o subir un Arma que
	# controles a la mano para Anular una carta de coste 1 o menos." —
	# costo con DOS mecanismos alternativos (descartar O devolver a la
	# mano) sobre un Arma EN JUEGO (no la propia carta), más un
	# objetivo con filtro de coste — nada de esto lo resuelve
	# ActionPipeline solo.
	var is_paladin_bestiarium_annul_pattern: bool = ("descartar o subir un arma que controles" in ability_lower
		and "anular una carta de coste" in ability_lower)
	if is_paladin_bestiarium_annul_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_paladin_bestiarium_weapon_annul(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Aho (2026-08-30): "Una vez por turno, Destierra
	# un Aliado o Tótem y cinco cartas del tope de un Castillo." — dos
	# destierros independientes (objetivo elegido + N del tope de un
	# mazo a elección) unidos por 'y', ninguno de los dos conceptos lo
	# resuelve ActionPipeline solo.
	var is_aho_banish_pattern: bool = ("destierra un aliado o" in ability_lower
		and "cartas del tope de un castillo" in ability_lower)
	if is_aho_banish_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._search_handler._activate_aho_banish_ally_and_deck(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Kuchiku Kan (2026-09-03): "Una vez por turno,
	# puedes Descartar una carta para que una carta pierda su habilidad
	# y no pueda atacar ni bloquear mientras este Aliado esté en
	# juego." — costo (descartar cualquiera) y objetivo (otra carta en
	# juego) no coinciden, y el efecto liga dos sistemas distintos
	# (KeywordManager + ContinuousEffectManager) a la duración
	# 'mientras esta carta esté en juego'.
	var is_kuchiku_kan_disable_pattern: bool = "pierda su habilidad y no pueda atacar ni bloquear" in ability_lower
	if is_kuchiku_kan_disable_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_kuchiku_kan_discard_to_disable(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Kuchiku El Cazador — habilidad 1 (2026-09-03):
	# "Una vez en tu turno, busca en tu Castillo o Cementerio un Aliado
	# y juégalo reduciendo su coste en un Oro, hasta un mínimo de 0." —
	# búsqueda con elección de zona + jugar con descuento, mismo
	# esqueleto que Miguel pero con un paso de búsqueda real antes.
	var is_kuchiku_cazador_search_pattern: bool = ("busca en tu castillo o cementerio un aliado" in ability_lower
		and "reduciendo su coste" in ability_lower)
	if is_kuchiku_cazador_search_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._search_handler._activate_kuchiku_cazador_search_and_play_discount(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Kuchiku El Cazador — habilidad 2 (2026-09-03):
	# "Una vez en tu turno, puedes Destruir hasta una carta de coste 3 o
	# menos y tu oponente Bota cartas igual a la Fuerza de este
	# Aliado." — destruir (objetivo opcional, tope de coste) + descarte
	# con cantidad dinámica (Fuerza actual), dos efectos independientes
	# que ActionPipeline no resuelve juntos.
	var is_kuchiku_cazador_destroy_pattern: bool = "bota cartas igual a la fuerza de este aliado" in ability_lower
	if is_kuchiku_cazador_destroy_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._search_handler._activate_kuchiku_cazador_destroy_and_discard(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Quantum Megumi (2026-09-04): "Una vez por
	# turno, Baraja una carta de tu mano para Barajar hasta tres cartas
	# de tu Cementerio y Robar una carta." — costo (barajar CUALQUIER
	# carta de la mano) y efecto (barajar del propio Cementerio +
	# robar) no coinciden, ActionPipeline no resuelve ambos juntos.
	var is_quantum_megumi_pattern: bool = ("baraja una carta de tu mano para barajar" in ability_lower
		and "cartas de tu cementerio" in ability_lower)
	if is_quantum_megumi_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_quantum_megumi(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrón especial de Sake (2026-09-04): "En tu Vigilia, una vez por
	# turno, si no controlas más Oros que tu oponente, puedes pagar un
	# Oro para poner un Oro en juego desde tu mano o Cementerio." —
	# condición dinámica (conteo de Oros de ambos jugadores) + costo +
	# 'poner en juego' (no 'jugar') desde dos zonas de origen a la vez.
	var is_sake_pattern: bool = ("no controlas más oros que tu oponente" in ability_lower
		and "poner un oro en juego desde tu mano o cementerio" in ability_lower)
	if is_sake_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_sake(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	# Patrones especiales de Oros (2026-09-04, tanda de checklist)
	var is_dulce_canasta_pattern: bool = "un aliado gana o pierde 2 de fuerza permanentemente" in ability_lower
	if is_dulce_canasta_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_dulce_canasta(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_belta_barajar_pattern: bool = ("baraja y/o destierra hasta dos cartas de los cementerios" in ability_lower
		and str(card_for_glow.get("card_name")).to_lower() == "belta")
	if is_belta_barajar_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_belta_barajar_desterrar(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_belta_revive_pattern: bool = "ponerlo en juego desde tu cementerio como un aliado sin habilidad de fuerza 2" in ability_lower
	if is_belta_revive_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_belta_self_banish_revive(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_espiritu_maquina_pattern: bool = "barajar o desterrar una carta de un cementerio" in ability_lower
	if is_espiritu_maquina_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_espiritu_maquina_shuffle_or_banish_cemetery(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	var is_frankenstein_cancel_pattern: bool = "para cancelar la habilidad de un oro o carta de coste 2 o menos" in ability_lower
	if is_frankenstein_cancel_pattern:
		btn.pressed.connect(func():
			_inspector.close_card_inspection()
			await _inspector._prevention_handler._activate_frankenstein_pay_shuffle_cancel(card_for_glow, captured)
		)
		panel.add_child(btn)
		return true

	return false
