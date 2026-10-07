extends RefCounted
class_name LookAndPlayResolver
## LookAndPlayResolver — Familia de patrones "mira/muestra N cartas del tope
## de tu Castillo y [elige qué hacer con ellas]": Signo Amarillo (1 a mano, 1
## a Cementerio), Tangata Manu (juega una gratis), Presente (juega una gratis
## o llévate todas a la mano), Perder la Razón (juega una gratis o un Oro
## directo a Oro Pagado). Opera sobre TriggerSystem via _main.
## Extraído de TargetedEffectExecutor.gd (2026-08-28, "módulos gordos" —
## a pedido del usuario, mismo tipo de corte que separó TriggerResolution/
## TriggerRestrictions/TemporaryBuffSystem de TriggerSystem.gd).
##
## Dividido en 7 archivos por tamaño (2026-09-06, "módulos gordos" —
## el archivo llegó a ~3200 líneas, el más grande del proyecto). Este
## archivo queda como FACADE — cada función de abajo es un reenvío de una
## sola línea a la mitad que corresponda, con el mismo nombre y firma de
## siempre, así que TriggerResolution.gd (único llamador, vía
## `_main._look_and_play.try_execute_X(...)`) no necesitó cambiar una sola
## línea por este split. Mismo idioma que SearchAbilityHandler.gd/
## SearchAbilityHandler_AI.gd/SearchAbilityHandler_JV.gd.
##
## Las 7 mitades, por mecánica dominante:
## - LookRevealPatterns.gd: familia "mira/muestra N... elige destino(s)".
## - SearchOwnZonePatterns.gd: busca/relocaliza/convierte en zonas propias.
## - BanishOpponentPatterns.gd: destierra/destruye/anula/bota al oponente.
## - ShuffleDrawPatterns.gd: combos de Barajar/Robar sobre recursos propios.
## - GoldConversionPatterns.gd: genera Oro Virtual / convierte carta-a-carta.
## - PlayFromCemeteryPatterns.gd: juega un Aliado del Cementerio con descuento.
## - MiscUniquePatterns.gd: 4 patrones únicos (burbuja+Fase Final, respuesta+
##   exilio+elección, robo de control+renombrado, candado de nombre).

const LookRevealPatternsScript = preload("res://scripts/core/effects/triggers/LookRevealPatterns.gd")
const SearchOwnZonePatternsScript = preload("res://scripts/core/effects/triggers/SearchOwnZonePatterns.gd")
const BanishOpponentPatternsScript = preload("res://scripts/core/effects/triggers/BanishOpponentPatterns.gd")
const ShuffleDrawPatternsScript = preload("res://scripts/core/effects/triggers/ShuffleDrawPatterns.gd")
const GoldConversionPatternsScript = preload("res://scripts/core/effects/triggers/GoldConversionPatterns.gd")
const PlayFromCemeteryPatternsScript = preload("res://scripts/core/effects/triggers/PlayFromCemeteryPatterns.gd")
const MiscUniquePatternsScript = preload("res://scripts/core/effects/triggers/MiscUniquePatterns.gd")

var _main: Node
var _look_reveal: RefCounted
var _search_own_zone: RefCounted
var _banish_opponent: RefCounted
var _shuffle_draw: RefCounted
var _gold_conversion: RefCounted
var _play_from_cemetery: RefCounted
var _misc_unique: RefCounted


func setup(main: Node) -> void:
	_main = main
	_look_reveal = LookRevealPatternsScript.new()
	_look_reveal.setup(main)
	_search_own_zone = SearchOwnZonePatternsScript.new()
	_search_own_zone.setup(main)
	_banish_opponent = BanishOpponentPatternsScript.new()
	_banish_opponent.setup(main)
	_shuffle_draw = ShuffleDrawPatternsScript.new()
	_shuffle_draw.setup(main)
	_gold_conversion = GoldConversionPatternsScript.new()
	_gold_conversion.setup(main)
	_play_from_cemetery = PlayFromCemeteryPatternsScript.new()
	_play_from_cemetery.setup(main)
	_misc_unique = MiscUniquePatternsScript.new()
	_misc_unique.setup(main)


# =============================================================================
# LookRevealPatterns
# =============================================================================
func try_execute_look_pick_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_look_pick_pattern(ability_text, controller_id, card)


func try_execute_look_play_free_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	return await _look_reveal.try_execute_look_play_free_pattern(ability_text, source_card, controller_id)


func try_execute_look_play_or_hand_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	return await _look_reveal.try_execute_look_play_or_hand_pattern(ability_text, source_card, controller_id)


func try_execute_look_play_or_gold_pattern(ability_text: String, source_card: Node, controller_id: int) -> bool:
	return await _look_reveal.try_execute_look_play_or_gold_pattern(ability_text, source_card, controller_id)


func try_execute_look_dynamic_gold_count_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_look_dynamic_gold_count_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_distinct_cost_allies_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_until_distinct_cost_allies_pattern(ability_text, controller_id, card)


func try_execute_look_two_hand_convert_gold_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _look_reveal.try_execute_look_two_hand_convert_gold_pattern(ability_text, card, controller_id)


func try_execute_reveal_until_ally_and_gold_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_until_ally_and_gold_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_weapon_or_totem_and_ally_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_until_weapon_or_totem_and_ally_pattern(ability_text, controller_id, card)


func try_execute_peek_hand_banish_search_castillo_cemetery_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _look_reveal.try_execute_peek_hand_banish_search_castillo_cemetery_draw_pattern(ability_text, card, controller_id)


func try_execute_name_reveal_until_match_then_gold_to_pagado_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_name_reveal_until_match_then_gold_to_pagado_pattern(ability_text, controller_id, card)


func try_execute_reveal_gold_to_pagado_weapon_or_totem_to_hand_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_gold_to_pagado_weapon_or_totem_to_hand_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_ally_and_weapon_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_until_ally_and_weapon_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_ally_and_talisman_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_until_ally_and_talisman_pattern(ability_text, controller_id, card)


func try_execute_reveal_gold_weapon_totem_split_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_gold_weapon_totem_split_pattern(ability_text, controller_id, card)


func try_execute_reveal_until_three_cost1_allies_play_one_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _look_reveal.try_execute_reveal_until_three_cost1_allies_play_one_pattern(ability_text, controller_id, card)


func try_execute_look_opponent_hand_discard_then_search_ally_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _look_reveal.try_execute_look_opponent_hand_discard_then_search_ally_pattern(ability_text, card, controller_id)


# =============================================================================
# SearchOwnZonePatterns
# =============================================================================
func try_execute_search_ally_castillo_or_cementerio_then_buff_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_search_ally_castillo_or_cementerio_then_buff_pattern(ability_text, card, controller_id)


func try_execute_search_ally_cost_max_free_play_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_search_ally_cost_max_free_play_pattern(ability_text, card, controller_id)


func try_execute_search_oro_castillo_or_cementerio_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_search_oro_castillo_or_cementerio_pattern(ability_text, card, controller_id)


func try_execute_raise_up_to_one_ally_or_gold_from_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _search_own_zone.try_execute_raise_up_to_one_ally_or_gold_from_cemetery_pattern(ability_text, controller_id, card)


func try_execute_raise_same_type_gold_and_search_banish_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_raise_same_type_gold_and_search_banish_pattern(ability_text, card, controller_id)


func try_execute_search_azi_ally_to_hand_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _search_own_zone.try_execute_search_azi_ally_to_hand_pattern(ability_text, controller_id, card)


func try_execute_search_castillo_or_cemetery_to_pagado_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_search_castillo_or_cemetery_to_pagado_pattern(ability_text, card, controller_id)


func try_execute_search_each_castillo_two_to_cemetery_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_search_each_castillo_two_to_cemetery_pattern(ability_text, card, controller_id)


func try_execute_optional_search_totem_castillo_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_optional_search_totem_castillo_pattern(ability_text, card, controller_id)


func try_execute_search_two_oros_split_destination_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_search_two_oros_split_destination_pattern(ability_text, card, controller_id)


func try_execute_primer_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_primer_sello_pattern(ability_text, card, controller_id)


func try_execute_segundo_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_segundo_sello_pattern(ability_text, card, controller_id)


func try_execute_tercer_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_tercer_sello_pattern(ability_text, card, controller_id)


func try_execute_cuarto_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_cuarto_sello_pattern(ability_text, card, controller_id)


func try_execute_quinto_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_quinto_sello_pattern(ability_text, card, controller_id)


func try_execute_sexto_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_sexto_sello_pattern(ability_text, card, controller_id)


func try_execute_septimo_sello_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _search_own_zone.try_execute_septimo_sello_pattern(ability_text, card, controller_id)


# =============================================================================
# BanishOpponentPatterns
# =============================================================================
func try_execute_banish_opponent_ally_search_ignis_titan_discount_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_banish_opponent_ally_search_ignis_titan_discount_pattern(ability_text, card, controller_id)


func try_execute_banish_two_from_one_cemetery_then_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_banish_two_from_one_cemetery_then_draw_pattern(ability_text, card, controller_id)


func try_execute_banish_opponent_castillo_by_titan_ignis_cost_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_banish_opponent_castillo_by_titan_ignis_cost_draw_pattern(ability_text, card, controller_id)


func try_execute_banish_opponent_cost_sum_six_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_banish_opponent_cost_sum_six_pattern(ability_text, card, controller_id)


func try_execute_pay_x_banish_opponent_castillo_draw_per_talisman_totem_pattern(ability_text: String, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_pay_x_banish_opponent_castillo_draw_per_talisman_totem_pattern(ability_text, controller_id)


func try_execute_opponent_hand_cost_max_to_bottom_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _banish_opponent.try_execute_opponent_hand_cost_max_to_bottom_pattern(ability_text, controller_id, card)


func try_execute_opponent_mill_six_exile_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _banish_opponent.try_execute_opponent_mill_six_exile_pattern(ability_text, controller_id, card)


func try_execute_search_three_opponent_castillo_banish_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_search_three_opponent_castillo_banish_draw_pattern(ability_text, card, controller_id)


func try_execute_raise_opponent_cemetery_or_destroy_cost1_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_raise_opponent_cemetery_or_destroy_cost1_draw_pattern(ability_text, card, controller_id)


func try_execute_annul_non_ally_banish_or_cancel_ability_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_annul_non_ally_banish_or_cancel_ability_pattern(ability_text, card, controller_id)


func try_execute_annul_cost_max_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_annul_cost_max_pattern(ability_text, card, controller_id)


func try_execute_annul_then_shuffle_hand_by_cost_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_annul_then_shuffle_hand_by_cost_pattern(ability_text, card, controller_id)


func try_execute_opponent_mill_four_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _banish_opponent.try_execute_opponent_mill_four_pattern(ability_text, controller_id, card)


func try_execute_draw_discard_opponent_mill_exile_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _banish_opponent.try_execute_draw_discard_opponent_mill_exile_pattern(ability_text, controller_id, card)


func try_execute_shuffle_or_banish_opponent_cost_max_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_shuffle_or_banish_opponent_cost_max_pattern(ability_text, card, controller_id)


func try_execute_search_two_distinct_names_banish_or_cemetery_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_search_two_distinct_names_banish_or_cemetery_pattern(ability_text, card, controller_id)


func try_execute_banish_cost_or_search_two_banish_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_banish_cost_or_search_two_banish_pattern(ability_text, card, controller_id)


func try_execute_banish_opponent_non_gold_and_talisman_surcharge_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _banish_opponent.try_execute_banish_opponent_non_gold_and_talisman_surcharge_pattern(ability_text, card, controller_id)


# =============================================================================
# ShuffleDrawPatterns
# =============================================================================
func try_execute_shuffle_or_draw_choice_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _shuffle_draw.try_execute_shuffle_or_draw_choice_pattern(ability_text, controller_id, card)


func try_execute_cain_damage_shuffle_search_pattern(isolated_text: String, card: Node, controller_id: int) -> bool:
	return await _shuffle_draw.try_execute_cain_damage_shuffle_search_pattern(isolated_text, card, controller_id)


func try_execute_shuffle_cost_max_three_pattern(ability_text: String, controller_id: int) -> bool:
	return await _shuffle_draw.try_execute_shuffle_cost_max_three_pattern(ability_text, controller_id)


func try_execute_shuffle_cost_max_two_draw_two_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _shuffle_draw.try_execute_shuffle_cost_max_two_draw_two_pattern(ability_text, controller_id, card)


func try_execute_attacks_alone_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _shuffle_draw.try_execute_attacks_alone_draw_pattern(ability_text, controller_id, card)


func try_execute_shuffle_one_in_play_and_four_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _shuffle_draw.try_execute_shuffle_one_in_play_and_four_cemetery_pattern(ability_text, controller_id, card)


func try_execute_shuffle_any_cemetery_or_exile_into_castillo_then_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _shuffle_draw.try_execute_shuffle_any_cemetery_or_exile_into_castillo_then_draw_pattern(ability_text, controller_id, card)


func try_execute_shuffle_banish_four_cemeteries_pattern(ability_text: String, controller_id: int) -> bool:
	return await _shuffle_draw.try_execute_shuffle_banish_four_cemeteries_pattern(ability_text, controller_id)


func try_execute_shuffle_banish_cemeteries_then_destroy_or_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _shuffle_draw.try_execute_shuffle_banish_cemeteries_then_destroy_or_draw_pattern(ability_text, card, controller_id)


func try_execute_draw_or_raise_cemetery_ally_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _shuffle_draw.try_execute_draw_or_raise_cemetery_ally_pattern(ability_text, controller_id, card)


func try_execute_shuffle_up_to_one_ally_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _shuffle_draw.try_execute_shuffle_up_to_one_ally_pattern(ability_text, card, controller_id)


func try_execute_draw_then_discard_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _shuffle_draw.try_execute_draw_then_discard_pattern(ability_text, controller_id, card)


func try_execute_shuffle_non_gold_or_draw_two_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _shuffle_draw.try_execute_shuffle_non_gold_or_draw_two_pattern(ability_text, card, controller_id)


func try_execute_draw_or_search_ally_or_gold_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _shuffle_draw.try_execute_draw_or_search_ally_or_gold_pattern(ability_text, card, controller_id)


# =============================================================================
# GoldConversionPatterns
# =============================================================================
func try_execute_convert_then_reveal_until_same_type_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _gold_conversion.try_execute_convert_then_reveal_until_same_type_pattern(ability_text, card, controller_id)


func try_execute_wielder_attack_gold_or_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _gold_conversion.try_execute_wielder_attack_gold_or_draw_pattern(ability_text, card, controller_id)


func try_execute_gold_for_allies_or_shuffle_cost_max_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _gold_conversion.try_execute_gold_for_allies_or_shuffle_cost_max_pattern(ability_text, card, controller_id)


func try_execute_convert_two_top_castillo_to_allies_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _gold_conversion.try_execute_convert_two_top_castillo_to_allies_pattern(ability_text, card, controller_id)


func try_execute_convert_gold_or_opponent_cost_max_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _gold_conversion.try_execute_convert_gold_or_opponent_cost_max_draw_pattern(ability_text, card, controller_id)


func try_execute_gold_for_allies_or_weapons_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _gold_conversion.try_execute_gold_for_allies_or_weapons_pattern(ability_text, controller_id, card)


func try_execute_espiritu_maquina_conditional_gold_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _gold_conversion.try_execute_espiritu_maquina_conditional_gold_pattern(ability_text, controller_id, card)


# =============================================================================
# PlayFromCemeteryPatterns
# =============================================================================
func try_execute_titan_abismal_conditional_play_or_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _play_from_cemetery.try_execute_titan_abismal_conditional_play_or_draw_pattern(ability_text, controller_id, card)


func try_execute_play_cemetery_ally_discounted_min1_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _play_from_cemetery.try_execute_play_cemetery_ally_discounted_min1_pattern(ability_text, card, controller_id)


func try_execute_play_cemetery_ally_free_or_draw_three_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _play_from_cemetery.try_execute_play_cemetery_ally_free_or_draw_three_pattern(ability_text, controller_id, card)


# =============================================================================
# MiscUniquePatterns
# =============================================================================
func try_execute_bubble_protection_and_schedule_final_phase_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	return await _misc_unique.try_execute_bubble_protection_and_schedule_final_phase_pattern(ability_text, controller_id, card)


func try_execute_transformacion_pattern(ability_text: String, controller_id: int) -> bool:
	return await _misc_unique.try_execute_transformacion_pattern(ability_text, controller_id)


func try_execute_gain_control_ally_rename_titan_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _misc_unique.try_execute_gain_control_ally_rename_titan_pattern(ability_text, card, controller_id)


func try_execute_malleus_name_lock_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	return await _misc_unique.try_execute_malleus_name_lock_pattern(ability_text, card, controller_id)
