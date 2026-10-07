extends Node
class_name GameStateBroadcaster
## GameStateBroadcaster — instanciado siempre en Main.gd, pero SOLO activo
## cuando esta instancia es el Anfitrión de una sala de red activa
## (NetworkClient.room_code != "" and NetworkClient.is_host). Traduce las
## señales que EffectController YA emite en cada transición de zona real
## (on_card_entered_play/on_card_left_play) a instrucciones de red
## ({"op":"move_card"/"remove_card",...}) para que RemoteMirrorController
## (del lado del cliente Remoto) pueda reflejar el tablero.
##
## Alcance de este incremento (2026-09-11, Fase B): solo las 5 zonas
## PÚBLICAS "en juego" (Constants.ZONES_IN_PLAY — Reserva de Oro, Oro
## Pagado, Línea de Defensa/Ataque/Apoyo), las únicas con Nodos Card
## visibles en el tablero (Cementerio/Destierro solo muestran un contador
## de texto, sin cartas individuales visibles — no hace falta streaming
## para eso todavía). Mano/Castillo (privados) quedan fuera a propósito: el
## Remoto ya ve su PROPIA mano vía los prompts de RemotePlayerController
## (mulligan/vigilia), y la mano/mazo del Anfitrión nunca deben viajar por
## aquí de todos modos (niebla de guerra) — mandar solo un card_id sin data
## para esos casos queda para un incremento posterior.

var _active: bool = false


func setup(_main: Node) -> void:
	_active = NetworkClient.room_code != "" and NetworkClient.is_host
	if not _active:
		return
	EffectController.on_card_entered_play.connect(_on_card_entered_play)
	EffectController.on_card_left_play.connect(_on_card_left_play)
	# ActionModule.return_to_deck() ("barajar de vuelta al mazo" — uno de
	# los efectos más comunes de todo el motor de triggers) no pasa por
	# on_card_left_play (no es un destroy/exile) — necesitaba su propia
	# señal, que estaba declarada pero nunca se emitía hasta hoy (ver el fix
	# en ActionReturnDiscard.gd).
	EffectController.on_card_returned_to_deck.connect(_on_card_returned_to_deck)


func _on_card_entered_play(player_id: int, card: Node, zone: int) -> void:
	if not is_instance_valid(card) or zone not in Constants.ZONES_IN_PLAY:
		return
	# "own" es relativo al RECEPTOR (el Remoto, que del lado del Anfitrión
	# siempre es el jugador 1) — ver "perspectiva relativa al receptor" en
	# docs/plans/2026-09-09-multiplayer-remoto-design.md.
	var own_for_remote: bool = (player_id == 1)
	var card_data: Dictionary = card.card_data.duplicate() if card.get("card_data") != null else {}
	NetworkClient.send_message({
		"op": "move_card",
		"card_id": str(card.get_instance_id()),
		"own": own_for_remote,
		"zone": zone,
		"data": card_data,
	})


func _on_card_left_play(_player_id: int, card: Node, from_zone: int) -> void:
	if from_zone not in Constants.ZONES_IN_PLAY:
		return
	_send_remove_card(card)


func _on_card_returned_to_deck(_player_id: int, card: Node, _to_top: bool) -> void:
	_send_remove_card(card)


func _send_remove_card(card: Node) -> void:
	var card_id: String = str(card.get_instance_id()) if is_instance_valid(card) else ""
	if card_id.is_empty():
		return
	NetworkClient.send_message({"op": "remove_card", "card_id": card_id})
