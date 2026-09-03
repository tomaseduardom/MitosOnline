extends Node
class_name DebugInputModule
## DebugInputModule — Atajos de teclado de debug (F1-F9) y ESC (cerrar
## inspección/cancelar selección/pausa). Extraído de Main.gd (2026-08-28, a
## pedido del usuario: "el main es para arrancar la app", esto es tooling de
## runtime, no arranque). Se instancia como hijo de Main en _ready().

var _main: Node = null


func setup(main: Node) -> void:
	_main = main


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		call_deferred("_check_deselect")

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F1:
				_main._update_debug("Fase: %s" % Constants.PHASE_NAMES[GameManager.current_phase])
			KEY_F2:
				_main._update_debug("Turno: %d, Jugador: %d" % [GameManager.current_turn, GameManager.active_player_id + 1])
			KEY_F3:
				_main._update_debug("Cartas en DB: %d" % CardDatabase.cards.size())
			KEY_F4:
				_main._update_debug("Oro disponible: %d" % _main.gold_cards.size())
			KEY_F5:
				_main._zone_manager.draw_card(0)
			KEY_F6:
				_main._update_debug("Castillo: %d cartas | Mano: %d" % [_main.player_deck.size(), _main.player_hand.get_child_count()])
			KEY_F7:
				_main._selection.open_exhume_selection(0)
			KEY_F8:
				var preview = _main.player_deck.slice(0, mini(3, _main.player_deck.size()))
				SelectionManager.open_reveal(preview, "Vista previa del Mazo")
			KEY_F9:
				CardDatabase.run_smoke_test()
			KEY_F12:
				var dp = _main.get_node_or_null("UI/DebugPanel")
				if dp: dp.visible = !dp.visible
			KEY_ESCAPE:
				if _main._card_inspector and _main._card_inspector.inspected_card:
					_main._card_inspector.close_card_inspection()
				elif _main._card_interaction and _main._card_interaction.is_selecting_target:
					_main._card_interaction.cancel_target_selection()
				elif _main._card_interaction and _main._card_interaction.is_placing_gold:
					_main._card_interaction.is_placing_gold = false
					_main._update_debug("Modo Oro cancelado")
				else:
					_main._scene_setup.toggle_pause_menu()


func _check_deselect() -> void:
	if _main._card_interaction: _main._card_interaction.check_deselect()
