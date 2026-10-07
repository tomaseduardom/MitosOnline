extends Control
## ShadowForgeLogin — pantalla de inicio de sesión real contra ShadowForge
## (2026-09-22, a pedido del usuario: reemplaza tener que editar
## user://shadowforge_credentials.json a mano). Escribe las credenciales con
## ExternalApiClient.save_credentials() y llama a ExternalApiClient.login()
## — mismo autoload/token que ya usan fetch_my_decks()/fetch_public_decks().
## Estilo y estructura calcados de OnlineConnect.gd (misma familia de
## pantalla: campos, botón, estado de carga/error).

@onready var username_edit: LineEdit = %UsernameEdit if has_node("%UsernameEdit") else $VBoxContainer/UsernameEdit
@onready var password_edit: LineEdit = %PasswordEdit if has_node("%PasswordEdit") else $VBoxContainer/PasswordEdit
@onready var login_button: Button = %LoginButton if has_node("%LoginButton") else $VBoxContainer/LoginButton
@onready var logout_button: Button = %LogoutButton if has_node("%LogoutButton") else $VBoxContainer/LogoutButton
@onready var status_label: Label = %StatusLabel if has_node("%StatusLabel") else $VBoxContainer/StatusLabel
@onready var back_button: Button = %BackButton if has_node("%BackButton") else $VBoxContainer/BackButton


func _ready() -> void:
	for btn in [login_button, logout_button, back_button]:
		if btn:
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			btn.mouse_entered.connect(func():
				var tw = btn.create_tween()
				tw.tween_property(btn, "modulate", Color(1.15, 1.15, 1.15, 1.0), 0.12)
			)
			btn.mouse_exited.connect(func():
				var tw = btn.create_tween()
				tw.tween_property(btn, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.12)
			)

	login_button.pressed.connect(_on_login_pressed)
	logout_button.pressed.connect(_on_logout_pressed)
	back_button.pressed.connect(_on_back_pressed)

	ExternalApiClient.login_succeeded.connect(_on_login_succeeded)
	ExternalApiClient.login_failed.connect(_on_login_failed)
	ExternalApiClient.profile_received.connect(_on_profile_received)
	ExternalApiClient.profile_failed.connect(_on_profile_failed)

	_refresh_connected_state()


func _refresh_connected_state() -> void:
	if ExternalApiClient.is_authenticated():
		status_label.text = "Verificando sesión..."
		logout_button.visible = true
		ExternalApiClient.fetch_my_profile()
	else:
		status_label.text = "Conectá tu cuenta de ShadowForge para ver tus mazos privados."
		logout_button.visible = false


func _on_login_pressed() -> void:
	var username := username_edit.text.strip_edges()
	var password := password_edit.text
	if username.is_empty() or password.is_empty():
		status_label.text = "Ingresa tu usuario y contraseña."
		return

	_set_busy(true)
	status_label.text = "Conectando con ShadowForge..."
	ExternalApiClient.save_credentials(username, password)
	ExternalApiClient.login()


func _on_login_succeeded() -> void:
	password_edit.text = ""
	status_label.text = "Conectado. Cargando tu perfil..."
	ExternalApiClient.fetch_my_profile()


func _on_login_failed(reason: String) -> void:
	_set_busy(false)
	status_label.text = "No se pudo conectar: %s" % reason


func _on_profile_received(profile: Dictionary) -> void:
	_set_busy(false)
	var display_name := str(profile.get("username", profile.get("email", "tu cuenta")))
	status_label.text = "Conectado como %s. Tus mazos privados ya aparecen en el selector de mazos." % display_name
	logout_button.visible = true


func _on_profile_failed(_reason: String) -> void:
	# Sesión conectada (el login ya emitió login_succeeded) pero no se pudo
	# traer el perfil — no es un error bloqueante, solo no hay nombre para
	# mostrar. El resto de la integración (mazos privados) igual funciona.
	_set_busy(false)
	status_label.text = "Conectado. Tus mazos privados ya aparecen en el selector de mazos."
	logout_button.visible = true


func _on_logout_pressed() -> void:
	ExternalApiClient.logout()
	username_edit.text = ""
	password_edit.text = ""
	_refresh_connected_state()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")


func _set_busy(busy: bool) -> void:
	login_button.disabled = busy
	username_edit.editable = not busy
	password_edit.editable = not busy
