extends Node
class_name MulliganController
## MulliganController — Gestiona la fase de mulligan inicial (DAR 4.3).
## Se instancia como hijo de Main en _ready().

var _main: Node = null
var is_in_mulligan: bool = false
var mulligan_count: int = 0
var mulligan_hand_data: Array = []

func setup(main: Node) -> void:
	_main = main
	_main.keep_hand_button.pressed.connect(on_keep_hand_pressed)
	_main.mulligan_button.pressed.connect(on_mulligan_pressed)


func start_mulligan_phase() -> void:
	print("[Mulligan] === Iniciando ===")
	_main._bootstrap._setup_oro_inicial()
	print("[Mulligan] Cartas en mazo jugador: %d" % _main.player_deck.size())
	is_in_mulligan = true
	mulligan_count = 0
	UIManager.set_phase_text("Mulligan")
	_main.mulligan_overlay.visible = true
	await get_tree().process_frame
	print("[Mulligan] Overlay visible, robando mano...")
	_draw_mulligan_hand(_main.INITIAL_HAND_SIZE)
	_update_mulligan_ui()
	print("[Mulligan] Mulligan listo con %d cartas" % mulligan_hand_data.size())


func _draw_mulligan_hand(count: int) -> void:
	_main.mulligan_hand.clear_cards_instant()
	mulligan_hand_data.clear()
	var castillo_pos = _main.get_node("GameBoard/PlayerArea/PlayerCastillo").global_position
	_main.mulligan_hand.set_deck_position(_main.mulligan_hand.get_global_transform().affine_inverse() * castillo_pos)
	for i in range(count):
		if _main.player_deck.is_empty():
			break
		var card_data = _main.player_deck.pop_front()
		mulligan_hand_data.append(card_data)
	_main.mulligan_hand.add_cards_with_animation(mulligan_hand_data, _main._create_card)
	_main._zone_manager._update_castillo_counts()


func _update_mulligan_ui() -> void:
	var current_hand_size = mulligan_hand_data.size()
	_main.mulligan_cards_label.text = "Mano actual: %d cartas" % current_hand_size
	var next_hand_size = current_hand_size - 1
	if next_hand_size <= 0:
		_main.mulligan_button.disabled = true
		_main.mulligan_button.text = "No puedes hacer mas mulligan"
	else:
		_main.mulligan_button.disabled = false
		_main.mulligan_button.text = "Mulligan (robar %d)" % next_hand_size


func on_keep_hand_pressed() -> void:
	print("[Mulligan] Jugador se queda con la mano de %d cartas" % mulligan_hand_data.size())
	_end_mulligan_phase()


func on_mulligan_pressed() -> void:
	var next_hand_size = mulligan_hand_data.size() - 1
	if next_hand_size <= 0:
		return
	print("[Mulligan] Jugador hace mulligan (mano anterior: %d, nueva: %d)" % [mulligan_hand_data.size(), next_hand_size])
	mulligan_count += 1
	_main.keep_hand_button.disabled = true
	_main.mulligan_button.disabled = true
	_main.mulligan_hand.clear_cards()
	await get_tree().create_timer(0.5).timeout
	for card_data in mulligan_hand_data:
		_main.player_deck.append(card_data)
	_main._zone_manager.shuffle_deck(0)
	_draw_mulligan_hand(next_hand_size)
	_update_mulligan_ui()
	_main.keep_hand_button.disabled = false


func _end_mulligan_phase() -> void:
	print("[Mulligan] Fin de fase. Mulligans realizados: %d" % mulligan_count)
	is_in_mulligan = false
	_main.mulligan_hand.clear_cards()
	await get_tree().create_timer(0.4).timeout
	_main.mulligan_overlay.visible = false
	for card_data in mulligan_hand_data:
		var card = _main._create_card(card_data)
		_main.player_hand.add_card(card)
		_main._connect_card_signals(card)
	mulligan_hand_data.clear()
	await _main._zone_manager.draw_initial_hand(1, _main.INITIAL_HAND_SIZE)
	# DEBUG TEMPORAL (2026-09-02, "solo por ahora" — ver el comentario
	# completo en GameBootstrap._debug_spawn_opponent_test_allies()): 3
	# Aliados rivales ya en juego para poder probar efectos "carta
	# oponente" (Estaca, etc.) sin jugar una partida entera antes.
	_main._bootstrap._debug_spawn_opponent_test_allies(3)
	GameManager.start_game(_main._dice_winner)
	CardManager.sync_from_main()
	_main._gold_manager._update_gold_display()
	_main._zone_manager._update_castillo_counts()
	_main._sync_oro_ui()
	_main._update_debug("Partida iniciada! Mano: %d cartas" % _main.player_hand.get_child_count())
