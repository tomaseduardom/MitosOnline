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
				if event.shift_pressed:
					if _main._combat_juice:
						_main._combat_juice.play_castle_damage(1, 4)
				else:
					_main._selection.open_exhume_selection(0)
			KEY_F8:
				if event.shift_pressed:
					if _main._combat_juice:
						_main._combat_juice.play_castle_damage(0, 3)
				else:
					var preview = _main.player_deck.slice(0, mini(3, _main.player_deck.size()))
					SelectionManager.open_reveal(preview, "Vista previa del Mazo")
			KEY_F9:
				CardDatabase.run_smoke_test()
			KEY_F10:
				# Previsualizar pantalla de Victoria (J0 gana)
				_main._on_game_ended(0)
			KEY_F11:
				# Previsualizar pantalla de Derrota (J1 gana)
				_main._on_game_ended(1)
			KEY_ENTER, KEY_KP_ENTER:
				# Si la pantalla de fin de partida está visible, es ella la
				# que debe manejar Enter (su propio _unhandled_input) — sin
				# este corte, _handle_enter_press() siempre corre primero
				# (los _input() de todos los nodos corren antes que cualquier
				# _unhandled_input()) y dispara el mismo botón enfocado dos
				# veces (una acá, otra en GameOverOverlay).
				if not (_main._game_over_overlay and is_instance_valid(_main._game_over_overlay) and _main._game_over_overlay.visible):
					_handle_enter_press()
			KEY_P:
				# 2026-10-01 (a pedido del usuario): atajo 'P' para el botón Pasar/Atacar/Daño del HUD
				if _main._game_hud and _main._game_hud.is_paso_button_ready():
					_main._phase_flow._on_paso_pressed()
					get_viewport().set_input_as_handled()
			KEY_F12:
				var dp = _main.get_node_or_null("UI/DebugPanel")
				if dp: dp.visible = !dp.visible
			KEY_L, KEY_H:
				# H también está ligada en DynamicHand a ocultar/mostrar la
				# mano — se marca el evento como manejado acá para que, si
				# de verdad hay drawer para abrir/cerrar, no dispare TAMBIÉN
				# el toggle de la mano con la misma tecla.
				if _main._action_log_drawer:
					_main._action_log_drawer.toggle_drawer()
					get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				# Igual que con Enter arriba: si la pantalla de fin de partida
				# está visible, que sea ella la que decida qué hacer con
				# Escape (ir al menú) en vez de abrir el Pausa Menu encima.
				if _main._game_over_overlay and is_instance_valid(_main._game_over_overlay) and _main._game_over_overlay.visible:
					return
				get_viewport().set_input_as_handled()
				if _main._card_inspector and _main._card_inspector.inspected_card:
					_main._card_inspector.close_card_inspection()
				elif _main._action_log_drawer and _main._action_log_drawer.is_open():
					_main._action_log_drawer.close_drawer()
				elif _main._card_interaction and _main._card_interaction.is_selecting_target:
					_main._card_interaction.cancel_target_selection()
				elif _main._card_interaction and _main._card_interaction.is_placing_gold:
					_main._card_interaction.is_placing_gold = false
					_main._update_debug("Modo Oro cancelado")
				elif _main._scene_setup and _main._scene_setup.pause_menu and _main._scene_setup.pause_menu.is_open():
					_main._scene_setup.pause_menu.handle_escape()
				elif _main._scene_setup:
					_main._scene_setup.toggle_pause_menu()


func _handle_enter_press() -> void:
	"""Accesibilidad por teclado con tecla Enter / Numpad Enter:
	Permite activar el botón contextual adecuado o el elemento bajo el cursor sin depender exclusivamente del mouse."""
	if not _main or not is_instance_valid(_main):
		return

	var viewport: Viewport = _main.get_viewport()

	# 1. Botón con foco GUI activo
	if viewport:
		var focus_owner: Control = viewport.gui_get_focus_owner()
		if focus_owner and is_instance_valid(focus_owner):
			if focus_owner is BaseButton and focus_owner.is_visible_in_tree() and not focus_owner.disabled:
				focus_owner.emit_signal("pressed")
				return

	# 2. Botón interactivo bajo el cursor del mouse (hover)
	if viewport and viewport.has_method("gui_get_hovered_control"):
		var hovered: Control = viewport.gui_get_hovered_control()
		var candidate: Control = hovered
		while candidate and not (candidate is BaseButton):
			candidate = candidate.get_parent() as Control
		if candidate and candidate is BaseButton and candidate.is_visible_in_tree() and not candidate.disabled:
			candidate.emit_signal("pressed")
			return

	# 3. Diálogos modales de elección activa (SelectionDialogs await_choice en capa 70)
	for child in _main.get_children():
		if child is CanvasLayer and child.layer == 70:
			var btn: Node = child.find_child("*Button*", true, false)
			if btn and btn is BaseButton and btn.is_visible_in_tree() and not btn.disabled:
				btn.emit_signal("pressed")
				return

	# 4. Capa de inspección de cartas abierta (activa habilidad disponible o cierra)
	if _main._card_inspector and _main._card_inspector.inspected_card:
		var panel = _main._card_inspector.get("_ability_buttons_panel")
		if panel and is_instance_valid(panel):
			for child in panel.get_children():
				if child is BaseButton and child.is_visible_in_tree() and not child.disabled:
					child.emit_signal("pressed")
					return
		_main._card_inspector.close_card_inspection()
		return

	# 5. Fase de Mulligan: 'Quedarse con la mano'
	if _main._mulligan_ctrl and _main._mulligan_ctrl.is_in_mulligan:
		if _main.keep_hand_button and is_instance_valid(_main.keep_hand_button) and _main.keep_hand_button.is_visible_in_tree() and not _main.keep_hand_button.disabled:
			_main._mulligan_ctrl.on_keep_hand_pressed()
			return

	# 6. Panel de selección de cartas activo (SelectionCanvas - Buscar, Descartar, etc.)
	# 2026-09-13, bug real reportado por el usuario: "Invalid access to property
	# or key 'is_active' on a base object of type 'Node (SelectionModule)'" —
	# _main._selection (SelectionModule) nunca tuvo is_active/confirm_button; el
	# panel real de selección vive en el autoload SelectionManager (is_open/
	# _confirm_button, con guion bajo).
	if SelectionManager.is_open:
		var sel_confirm = SelectionManager.get("_confirm_button")
		if sel_confirm and is_instance_valid(sel_confirm) and sel_confirm.is_visible_in_tree() and not sel_confirm.disabled:
			sel_confirm.emit_signal("pressed")
			return

	# 7. Diálogo de confirmación del oponente (OpponentUI)
	var opp_ui = _main.get_node_or_null("GameBoard/OpponentUI")
	if opp_ui and opp_ui.get("acknowledge_button") != null:
		var ack_btn = opp_ui.acknowledge_button
		if ack_btn and is_instance_valid(ack_btn) and ack_btn.is_visible_in_tree() and not ack_btn.disabled:
			ack_btn.emit_signal("pressed")
			return

	# 8. Diálogo de búsqueda de nombre (CardNameSearchDialog)
	for child in _main.get_tree().root.get_children():
		if child.name == "CardNameSearchLayer" and child.is_visible_in_tree():
			var btn = child.find_child("*Button*", true, false)
			if btn and btn is BaseButton and not btn.disabled:
				btn.emit_signal("pressed")
				return

	# 9. Botón principal del HUD (¿Paso? / Declarar Ataque / Atacar / Confirmar)
	if _main._game_hud and _main._game_hud.is_paso_button_ready():
		_main._phase_flow._on_paso_pressed()
		return


func _check_deselect() -> void:
	if _main._card_interaction: _main._card_interaction.check_deselect()
