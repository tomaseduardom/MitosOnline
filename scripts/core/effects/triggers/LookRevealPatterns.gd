extends RefCounted
## LookRevealPatterns — 1 de 7 mitades de LookAndPlayResolver.gd, dividido por
## tamaño el 2026-09-06 ("módulos gordos"). Esta cubre la familia "mira/muestra
## N cartas del tope de tu Castillo... elige destino(s)": Signo Amarillo,
## Tangata Manu, Presente, Perder la Razón, Tesoro de los Césares, Alicia en
## Wonderland, y toda la familia "reveal_until_X_and_Y" agregada 2026-09-04 en
## adelante (Cabeza de Mimir, atenea en wonderland, metalmorfo, akari, Duelo de
## Dragones, gran kraken, kitsune - sp, etc.). Llamada solo desde
## LookAndPlayResolver.gd (facade) — ver ese archivo para la lista completa de
## las 7 mitades hermanas (SearchOwnZonePatterns, BanishOpponentPatterns,
## ShuffleDrawPatterns, GoldConversionPatterns, PlayFromCemeteryPatterns,
## MiscUniquePatterns).
##
## Dividida a su vez en dos mitades por tamaño (2026-09-06, "módulos gordos",
## split anidado — facade de facade): LookRevealPatternsA.gd (alfabético
## dynamic_gold_count..play_or_hand, 6 patrones — concentra los 3
## try_execute_look_play_* con su filtro compartido, los más largos del
## grupo) y LookRevealPatternsB.gd (look_two_hand_convert_gold..
## weapon_or_totem_and_ally, 10 patrones). Este archivo queda como FACADE —
## cada función de abajo es un reenvío de una sola línea a la mitad que
## corresponda, con el mismo nombre y firma de siempre, así que
## LookAndPlayResolver.gd (único llamador, vía `_look_reveal.try_execute_X_pattern(...)`)
## no necesitó cambiar una sola línea por este split.

const LookRevealPatternsAScript = preload("res://scripts/core/effects/triggers/LookRevealPatternsA.gd")
const LookRevealPatternsBScript = preload("res://scripts/core/effects/triggers/LookRevealPatternsB.gd")

var _main: Node
var _a: RefCounted
var _b: RefCounted


func setup(main: Node) -> void:
	_main = main
	_a = LookRevealPatternsAScript.new()
	_a.setup(main)
	_b = LookRevealPatternsBScript.new()
	_b.setup(main)


func try_execute_look_pick_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _a.try_execute_look_pick_pattern(ability_text, controller_id, card)


func try_execute_look_play_free_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	return await _a.try_execute_look_play_free_pattern(ability_text, source_card, controller_id)


func try_execute_look_play_or_hand_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	return await _a.try_execute_look_play_or_hand_pattern(ability_text, source_card, controller_id)


func try_execute_look_play_or_gold_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	return await _a.try_execute_look_play_or_gold_pattern(ability_text, source_card, controller_id)


func try_execute_look_dynamic_gold_count_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _a.try_execute_look_dynamic_gold_count_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_distinct_cost_allies_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_reveal_until_distinct_cost_allies_pattern(ability_text, controller_id, card)


func try_execute_look_two_hand_convert_gold_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _b.try_execute_look_two_hand_convert_gold_pattern(ability_text, card, controller_id)


func try_execute_reveal_until_ally_and_gold_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_reveal_until_ally_and_gold_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_weapon_or_totem_and_ally_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_reveal_until_weapon_or_totem_and_ally_pattern(ability_text, controller_id, card)


func try_execute_peek_hand_banish_search_castillo_cemetery_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _b.try_execute_peek_hand_banish_search_castillo_cemetery_draw_pattern(ability_text, card, controller_id)


func try_execute_name_reveal_until_match_then_gold_to_pagado_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_name_reveal_until_match_then_gold_to_pagado_pattern(ability_text, controller_id, card)


func try_execute_reveal_gold_to_pagado_weapon_or_totem_to_hand_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_reveal_gold_to_pagado_weapon_or_totem_to_hand_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_ally_and_weapon_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_reveal_until_ally_and_weapon_pattern(ability_text, controller_id, card)


func try_execute_reveal_gold_weapon_totem_split_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_reveal_gold_weapon_totem_split_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_three_cost1_allies_play_one_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _b.try_execute_reveal_until_three_cost1_allies_play_one_pattern(ability_text, controller_id, card)


func try_execute_look_opponent_hand_discard_then_search_ally_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _a.try_execute_look_opponent_hand_discard_then_search_ally_pattern(ability_text, card, controller_id)
