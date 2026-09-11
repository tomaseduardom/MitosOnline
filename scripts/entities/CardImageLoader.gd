extends RefCounted
class_name CardImageLoader
## CardImageLoader — Carga de imagen/placeholder de una carta: aplica los
## datos pendientes tras load_from_data(), muestra el dorso de carga y el
## placeholder legible (nombre/coste) mientras el arte frontal no está
## disponible, y gestiona la descarga async vía CardDatabase.card_image_loaded
## (cache hit inmediato o conexión de señal + callback). Opera sobre el nodo
## Card via _card. Ninguna de estas funciones tiene llamadores fuera de
## Card.gd (verificado por grep en todo scripts/), así que Card.gd NO expone
## wrappers públicos para ellas — solo las llama internamente vía
## _image_loader.X() en los 3 puntos donde antes se llamaban directo
## (esta_oculta.set(), actualizar_aspecto(), _exit_tree()).
## Extraído de Card.gd (2026-09-06, "módulos gordos" — mismo corte que ya
## separó CardInteraction.gd/CardAnimations.gd/CardTriggerRuntime.gd/
## CardBadges.gd, Fase 4 de reestructuración).

var _card: Card

var _image_signal_connected: bool = false


func setup(card: Card) -> void:
	_card = card


func _apply_pending_data() -> void:
	"""Aplica los datos que se asignaron antes de _ready"""
	_update_placeholder()
	# Siempre mostrar dorso como estado inicial (nunca el bloque negro)
	_show_loading_dorso()

	if not _card.card_image_path.is_empty() and _card.card_image_path != "/dorso_default.webp":
		# Hay imagen CDN: cargarla de forma asíncrona
		_load_card_image()
	else:
		# Sin imagen CDN: el dorso ES el aspecto final → señalizar listo
		if not _card._image_ready:
			_card._image_ready = true
			_card.image_ready.emit()


func _show_loading_dorso() -> void:
	"""Muestra el dorso de la carta mientras se descarga el arte frontal."""
	_show_placeholder(false)
	if _card.card_art:
		var back_tex = GameSettings.get_card_back_texture(_card.owner_id)
		if back_tex:
			_card.card_art.texture = back_tex
			_card.card_art.visible = true
			return
	# Fallback: placeholder si no hay dorso configurado
	_show_placeholder(true)


func _update_placeholder() -> void:
	"""Actualiza el contenido del placeholder"""
	if not _card.placeholder:
		return

	# Icono según tipo de carta
	if _card.placeholder_icon:
		match _card.card_type:
			Constants.CardType.ORO:
				_card.placeholder_icon.text = "💰"
				_card.placeholder_icon.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
			Constants.CardType.ALIADO:
				_card.placeholder_icon.text = "⚔"
				_card.placeholder_icon.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
			Constants.CardType.ARMA:
				_card.placeholder_icon.text = "🗡"
				_card.placeholder_icon.add_theme_color_override("font_color", Color(0.8, 0.5, 0.3))
			Constants.CardType.TALISMAN:
				_card.placeholder_icon.text = "✨"
				_card.placeholder_icon.add_theme_color_override("font_color", Color(0.6, 0.4, 0.8))
			Constants.CardType.TOTEM:
				_card.placeholder_icon.text = "🏛"
				_card.placeholder_icon.add_theme_color_override("font_color", Color(0.4, 0.7, 0.5))

	# Nombre de la carta
	if _card.placeholder_name:
		_card.placeholder_name.text = _card.card_name if not _card.card_name.is_empty() else "???"

	# Coste (solo si no es Oro)
	if _card.placeholder_cost:
		if _card.card_type == Constants.CardType.ORO:
			_card.placeholder_cost.text = "ORO"
		else:
			_card.placeholder_cost.text = "Coste: %d" % _card.card_cost


func _show_placeholder(show: bool) -> void:
	"""Muestra u oculta el placeholder"""
	if _card.placeholder:
		_card.placeholder.visible = show


func _load_card_image() -> void:
	"""Carga la imagen de la carta desde CardDatabase o ruta local"""
	# No cargar imagen si la carta está oculta (ahorra recursos)
	if _card.esta_oculta:
		return

	# Sin imagen o imagen de dorso por defecto → el dorso ya está mostrado, nada que hacer
	if _card.card_image_path.is_empty() or _card.card_image_path == "/dorso_default.webp":
		return

	# Carga directa de rutas locales (res:// o user://) para tokens de oro virtual y assets
	if _card.card_image_path.begins_with("res://") or _card.card_image_path.begins_with("user://"):
		if ResourceLoader.exists(_card.card_image_path):
			var local_tex = load(_card.card_image_path)
			if local_tex:
				_set_card_texture(local_tex)
				return

	if _card.card_id.is_empty():
		return

	print("[Card] Cargando imagen — id:%s path:%s" % [_card.card_id, _card.card_image_path])

	# Verificar si ya está en cache
	var texture = CardDatabase.get_card_image(_card.card_id)
	if texture:
		_set_card_texture(texture)
	else:
		# Conectar señal para cuando se descargue
		if not _image_signal_connected:
			CardDatabase.card_image_loaded.connect(_on_card_image_loaded)
			_image_signal_connected = true


func _on_card_image_loaded(loaded_card_id: String, texture: Texture2D) -> void:
	"""Callback cuando se carga una imagen (texture puede ser null si CDN falló)"""
	if loaded_card_id == _card.card_id:
		if texture:
			_set_card_texture(texture)
		else:
			# CDN falló: mostrar placeholder legible (nombre/coste) en vez del
			# dorso, porque el dorso no deja identificar qué carta es la que
			# no cargó — solo aplica si la carta está boca arriba.
			if not _card.esta_oculta:
				_update_placeholder()
				_show_placeholder(true)
			if not _card._image_ready:
				_card._image_ready = true
				_card.image_ready.emit()
		_disconnect_image_signal()


func _set_card_texture(texture: Texture2D) -> void:
	"""Aplica la textura frontal de la carta y señaliza que está lista."""
	if _card.card_art and texture and not _card.esta_oculta:
		_card.card_art.texture = texture
		_card.card_art.visible = true
		_show_placeholder(false)
	if not _card._image_ready:
		_card._image_ready = true
		_card.image_ready.emit()


func _disconnect_image_signal() -> void:
	"""Desconecta la señal de carga de imagen"""
	if _image_signal_connected and CardDatabase.card_image_loaded.is_connected(_on_card_image_loaded):
		CardDatabase.card_image_loaded.disconnect(_on_card_image_loaded)
		_image_signal_connected = false
