# Relay server — MitosOnline multiplayer

Servidor WebSocket chico y ciego: junta a 2 clientes de Godot por un código de sala corto y
reenvía cualquier mensaje de un lado al otro. No sabe nada de las reglas de Mitos y Leyendas —
solo agrupa y reenvía. Ver `docs/plans/2026-09-09-multiplayer-remoto-design.md` en la raíz del
proyecto para el diseño completo.

## Correr local

```
cd relay-server
npm install
npm start
```

Por defecto escucha en `ws://localhost:8080`. Cambiar el puerto con la variable de entorno
`PORT` (ej. `PORT=9000 npm start`).

Para probar de punta a punta con 2 instancias de Godot en la misma máquina, apuntar el
`NetworkClient` de ambas a `ws://localhost:8080` — no hace falta desplegar nada todavía.

## Desplegar gratis (para jugar con alguien en otra red)

Cualquier hosting que corra un proceso Node.js persistente con un puerto expuesto sirve
(Railway, Render, Fly.io). Pasos generales:

1. Subir esta carpeta (`relay-server/`) como su propio proyecto/servicio en el hosting elegido.
2. Comando de arranque: `npm install && npm start`.
3. El hosting expone una URL pública (`https://...`) — el WebSocket queda en `wss://` sobre esa
   misma URL (no `ws://`, sin TLS el navegador/Godot lo rechazaría en producción).
4. Apuntar el `NetworkClient` de Godot a esa URL `wss://` en vez de `ws://localhost:8080`.

No hace falta base de datos ni almacenamiento persistente — todo el estado (qué salas existen,
quién está en cada una) vive en memoria del proceso y se pierde si se reinicia, lo cual es
aceptable: si el relay se cae, la partida en curso también termina (regla ya decidida en el
diseño — sin reconexión en la v1).

## Protocolo

Ver los comentarios al principio de `server.js` — es el único documento fuente de verdad del
protocolo de control (`create_room`/`join_room`/reenvío ciego).
