extends RefCounted
## SearchAbilityHandler — Facade de Patrones especiales de habilidades
## ACTIVADAS que buscan/miran/reordenan cartas del Castillo, generan Oro
## Virtual restringido, o juegan otra carta con descuento (Padre de la
## Patria, Don de Amma, Tesoro de los Césares, Miguel, Espada de O'Higgins,
## Infernum Vox, Aho, y todas las cartas agregadas 2026-09-06 en adelante).
## Detectados en CardInspectionLayer._build_ability_buttons() y ruteados acá
## en vez de al pipeline genérico de habilidades activadas.
##
## Dividido en dos archivos por tamaño (2026-09-06, "módulos gordos"):
## SearchAbilityHandler_AI.gd (nombres de carta A-I) y
## SearchAbilityHandler_JV.gd (J-V). Este archivo queda como FACADE — cada
## función de abajo es un reenvío de una sola línea a la mitad que
## corresponda, con el mismo nombre y firma de siempre, así que
## CardInspectionLayer.gd (único llamador, vía `_search_handler._activate_X(...)`)
## no necesitó cambiar una sola línea por este split.

const SearchAbilityHandlerAIScript = preload("res://scripts/ui/inspection/SearchAbilityHandler_AI.gd")
const SearchAbilityHandlerJVScript = preload("res://scripts/ui/inspection/SearchAbilityHandler_JV.gd")

var _inspector: CardInspectionLayer
var _ai: RefCounted
var _jv: RefCounted


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector
	_ai = SearchAbilityHandlerAIScript.new()
	_ai.setup(inspector)
	_jv = SearchAbilityHandlerJVScript.new()
	_jv.setup(inspector)


func _activate_aho_banish_ally_and_deck(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_aho_banish_ally_and_deck(source_card, ability)


func _activate_asmodeus_gold_and_banish_bottom(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_asmodeus_gold_and_banish_bottom(source_card, ability)


func _activate_belcebu_banish_bottom_and_steal(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_belcebu_banish_bottom_and_steal(source_card, ability)


func _activate_cetro_demoniaco_gold_and_banish(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_cetro_demoniaco_gold_and_banish(source_card, ability)


func _activate_chakram_look_and_lock(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_chakram_look_and_lock(source_card, ability)


func _activate_cuerno_titan_discard_search_cost_adjust(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_cuerno_titan_discard_search_cost_adjust(source_card, ability)


func _activate_don_de_amma(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_don_de_amma(source_card, ability)


func _activate_dyyavol_titan_draw_discard_mill(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_dyyavol_titan_draw_discard_mill(source_card, ability)


func _activate_espada_ohiggins_vigilia_choice(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_espada_ohiggins_vigilia_choice(source_card, ability)


func _activate_infernum_vox_look_reorder(source_card: Node, ability: Dictionary) -> void:
	await _ai._activate_infernum_vox_look_reorder(source_card, ability)


func _activate_jinete_peste_search_banish_two(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_jinete_peste_search_banish_two(source_card, ability)


func _activate_kotaix_draw_and_shuffle_opponent(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_kotaix_draw_and_shuffle_opponent(source_card, ability)


func _activate_kuchiku_cazador_search_and_play_discount(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_kuchiku_cazador_search_and_play_discount(source_card, ability)


func _activate_kuchiku_cazador_destroy_and_discard(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_kuchiku_cazador_destroy_and_discard(source_card, ability)


func _activate_lider_del_comite_discard_look_name_lock(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_lider_del_comite_discard_look_name_lock(source_card, ability)


func _activate_miguel_discount_play(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_miguel_discount_play(source_card, ability)


func _activate_padre_patria_gold(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_padre_patria_gold(source_card, ability)


func _activate_quimera_voragh_mill_and_revive(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_quimera_voragh_mill_and_revive(source_card, ability)


func _activate_tenshi_z_shuffle_hand_to_annul(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_tenshi_z_shuffle_hand_to_annul(source_card, ability)


func _activate_tesoro_cesares_name_tax(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_tesoro_cesares_name_tax(source_card, ability)


func _activate_voragh_devorador_search_to_cemetery(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_voragh_devorador_search_to_cemetery(source_card, ability)


func _activate_voragh_devorador_destroy_own_for_gold(source_card: Node, ability: Dictionary) -> void:
	await _jv._activate_voragh_devorador_destroy_own_for_gold(source_card, ability)
