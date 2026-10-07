extends RefCounted
## PreventionAbilityHandler — Facade de Patrones especiales de habilidades
## ACTIVADAS de protección/prevención y descuentos ligados a un Arma (Legión
## Paladín, Estaca — prevención, Drácula — autoconvertirse, Paladín
## Bestiarium — 2 habilidades, y todas las cartas agregadas 2026-09-06 en
## adelante). Detectados en CardInspectionLayer._build_ability_buttons() y
## ruteados aquí en vez de al pipeline genérico de habilidades activadas.
##
## Dividido en tres archivos por tamaño (2026-09-06, "módulos gordos" — mismo
## corte que ya separó SearchAbilityHandler.gd en SearchAbilityHandler_AI.gd/
## SearchAbilityHandler_JV.gd): PreventionAbilityHandler_AE.gd (A-E),
## PreventionAbilityHandler_EP.gd (E-P) y PreventionAbilityHandler_PV.gd
## (P-V). Este archivo queda como FACADE — cada función de abajo es un
## reenvío de una sola línea a la parte que corresponda, con el mismo nombre
## y firma de siempre, así que CardInspectionLayer.gd (único llamador, vía
## `_prevention_handler._activate_X(...)`) no necesitó cambiar una sola línea
## por este split.

const PreventionAbilityHandlerAEScript = preload("res://scripts/ui/inspection/PreventionAbilityHandler_AE.gd")
const PreventionAbilityHandlerEPScript = preload("res://scripts/ui/inspection/PreventionAbilityHandler_EP.gd")
const PreventionAbilityHandlerPVScript = preload("res://scripts/ui/inspection/PreventionAbilityHandler_PV.gd")

var _inspector: CardInspectionLayer
var _ae: RefCounted
var _ep: RefCounted
var _pv: RefCounted


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector
	_ae = PreventionAbilityHandlerAEScript.new()
	_ae.setup(inspector)
	_ep = PreventionAbilityHandlerEPScript.new()
	_ep.setup(inspector)
	_pv = PreventionAbilityHandlerPVScript.new()
	_pv.setup(inspector)


func _activate_akari_banish_annul_non_ally(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_akari_banish_annul_non_ally(source_card, ability)


func _activate_akuma_banish_or_draw(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_akuma_banish_or_draw(source_card, ability)


func _activate_atenea_grant_double_damage_exile(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_atenea_grant_double_damage_exile(source_card, ability)


func _activate_belta_barajar_desterrar(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_belta_barajar_desterrar(source_card, ability)


func _activate_belta_self_banish_revive(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_belta_self_banish_revive(source_card, ability)


func _activate_campanita_banish_cancel_or_draw(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_campanita_banish_cancel_or_draw(source_card, ability)


func _activate_crono_diamante_discard_ally_discount(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_crono_diamante_discard_ally_discount(source_card, ability)


func _activate_dulce_canasta(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_dulce_canasta(source_card, ability)


func _activate_ereshkigal_banish_cost1_or_cemeteries(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_ereshkigal_banish_cost1_or_cemeteries(source_card, ability)


func _activate_espada_ohiggins_shuffle_or_search_gold(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_espada_ohiggins_shuffle_or_search_gold(source_card, ability)


func _activate_espiritu_maquina_shuffle_or_banish_cemetery(source_card: Node, ability: Dictionary) -> void:
	await _ae._activate_espiritu_maquina_shuffle_or_banish_cemetery(source_card, ability)


func _activate_frankenstein_discard_silence_turn(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_frankenstein_discard_silence_turn(source_card, ability)


func _activate_frankenstein_pay_shuffle_cancel(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_frankenstein_pay_shuffle_cancel(source_card, ability)


func _activate_gran_kraken_discard_destroy(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_gran_kraken_discard_destroy(source_card, ability)


func _activate_kuchiku_kan_discard_to_disable(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_kuchiku_kan_discard_to_disable(source_card, ability)


func _activate_lanza_argenta_destroy_self_cancel_or_draw(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_lanza_argenta_destroy_self_cancel_or_draw(source_card, ability)


func _activate_nu_galahad_look_play_weapon_and_ally_free(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_nu_galahad_look_play_weapon_and_ally_free(source_card, ability)


func _activate_nu_galahad_wear_cemetery_as_weapons(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_nu_galahad_wear_cemetery_as_weapons(source_card, ability)


func _activate_paladin_bestiarium_discard_weapon_discount(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_paladin_bestiarium_discard_weapon_discount(source_card, ability)


func _activate_paladin_bestiarium_weapon_annul(source_card: Node, ability: Dictionary) -> void:
	await _ep._activate_paladin_bestiarium_weapon_annul(source_card, ability)


func _activate_perla_de_sangre_convert_barajar_desterrar_draw(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_perla_de_sangre_convert_barajar_desterrar_draw(source_card, ability)


func _activate_perla_de_sangre_search_hand_or_play(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_perla_de_sangre_search_hand_or_play(source_card, ability)


func _activate_piruquina_pay_bottom_deck_prevent(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_piruquina_pay_bottom_deck_prevent(source_card, ability)


func _activate_quantum_megumi(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_quantum_megumi(source_card, ability)


func _activate_quimera_voragh_banish_annul_talisman_draw(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_quimera_voragh_banish_annul_talisman_draw(source_card, ability)


func _activate_sake(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_sake(source_card, ability)


func _activate_shub_niggurath_gold_for_totem_draw(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_shub_niggurath_gold_for_totem_draw(source_card, ability)


func _activate_shub_niggurath_shuffle_or_mill_opponent(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_shub_niggurath_shuffle_or_mill_opponent(source_card, ability)


func _activate_skofnung_shuffle_self_search_gold(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_skofnung_shuffle_self_search_gold(source_card, ability)


func _activate_sumi_discard_grant_exhumar(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_sumi_discard_grant_exhumar(source_card, ability)


func _activate_torre_babel_shuffle_hand_for_cemeteries_draw(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_torre_babel_shuffle_hand_for_cemeteries_draw(source_card, ability)


func _activate_totem_dragon_ancestral_shuffle_self_annul_or_cancel(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_totem_dragon_ancestral_shuffle_self_annul_or_cancel(source_card, ability)


func _activate_uriel_shuffle_banish_draw_discard(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_uriel_shuffle_banish_draw_discard(source_card, ability)


func _activate_vision_heroica_pay_raise_draw(source_card: Node, ability: Dictionary) -> void:
	await _pv._activate_vision_heroica_pay_raise_draw(source_card, ability)
