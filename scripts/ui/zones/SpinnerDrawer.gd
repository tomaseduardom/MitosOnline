extends Node2D
## SpinnerDrawer — dibuja el spinner místico dorado del loading de DeckSelector.
## Extraído (2026-08-30) de un script dinámico creado en tiempo de ejecución
## desde un string ("class _SpinnerDrawerScript extends GDScript: ... source_code
## = \"\"\"...\"\"\"; reload()") — esa técnica causaba "Failed to load script
## DeckSelector.gd... Parse error" al cargar el archivo. Un archivo .gd normal
## precargado con preload() es la misma técnica ya usada en el resto del
## proyecto (ver CardNameSearchDialogScript en TriggerSystem.gd) y no depende
## de compilar código en tiempo real.

func _draw() -> void:
	var gold = Color(1.0, 0.86, 0.42, 0.95)
	var dim = Color(0.7, 0.55, 0.25, 0.35)
	draw_arc(Vector2.ZERO, 22, 0, TAU, 32, dim, 2.0)
	draw_arc(Vector2.ZERO, 22, -PI * 0.5, PI * 0.7, 24, gold, 3.5)
	for i in range(4):
		var angle = i * (PI / 2.0)
		var p1 = Vector2.from_angle(angle) * 11.0
		var p2 = Vector2.from_angle(angle) * 18.0
		draw_line(p1, p2, gold, 2.0)
	draw_circle(Vector2.ZERO, 4.0, gold)
