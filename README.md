# Mitos y Leyendas - El Juego

Juego de cartas coleccionables digital basado en el TCG chileno Mitos y Leyendas.

## Requisitos

- **Godot 4.2+** (descargar desde https://godotengine.org/)

## Estructura del Proyecto

```
game/
├── project.godot          # Configuración del proyecto
├── icon.svg               # Icono del juego
├── scenes/
│   ├── game/              # Escenas del juego
│   │   └── Main.tscn      # Escena principal
│   ├── cards/             # Escenas de cartas
│   └── ui/                # Interfaces de usuario
├── scripts/
│   ├── core/              # Scripts principales
│   │   ├── Constants.gd   # Constantes (basadas en DAR)
│   │   ├── GameManager.gd # Gestor de partidas
│   │   ├── CardDatabase.gd# Base de datos de cartas
│   │   └── Main.gd        # Script de escena principal
│   ├── cards/             # Lógica de cartas
│   └── ui/                # Scripts de UI
├── assets/
│   ├── images/            # Imágenes y sprites
│   ├── fonts/             # Tipografías
│   └── audio/             # Sonidos y música
└── resources/             # Recursos de Godot (.tres)
```

## Cómo Abrir el Proyecto

1. Descargar e instalar Godot 4.2+
2. Abrir Godot
3. Click en "Import" o "Importar"
4. Navegar a esta carpeta `game/`
5. Seleccionar `project.godot`
6. Click en "Import & Edit"

## Singletons (Autoload)

El juego usa tres singletons globales:

- **GameManager**: Controla el flujo del juego, turnos y fases
- **CardDatabase**: Maneja la base de datos de cartas (conecta con El Grimorio)
- **Constants**: Constantes del juego basadas en el DAR

## Conexión con El Grimorio

El juego se conecta con la API de El Grimorio para:
- Descargar cartas (`/api/cartas`)
- Obtener imágenes (CDN Bunny)

Las cartas se cachean localmente para jugar offline.

## Controles de Debug

- **F1**: Mostrar fase actual
- **F2**: Mostrar turno y jugador
- **F3**: Mostrar cantidad de cartas cargadas
- **Enter**: Pasar de Fase Final al siguiente turno

## Roadmap

- [x] Estructura del proyecto
- [x] Constantes basadas en DAR
- [x] GameManager con fases del turno
- [x] CardDatabase con conexión a API
- [ ] Escena de carta (Card.tscn)
- [ ] Sistema de zonas de juego
- [ ] Drag & drop de cartas
- [ ] Sistema de combate completo
- [ ] IA básica
- [ ] Menú principal
- [ ] Selector de mazos
