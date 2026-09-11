// Relay WebSocket ciego para MitosOnline (Fase A del multiplayer remoto).
//
// No sabe NADA de las reglas de Mitos y Leyendas. Su unico trabajo:
//   1. Agrupar 2 conexiones bajo un codigo de sala corto.
//   2. Reenviar cualquier mensaje que llegue de un lado, tal cual, al otro
//      lado de la misma sala.
//
// Protocolo de control (el unico que este servidor entiende):
//   Cliente -> Servidor:
//     {"op": "create_room"}                  -> crea sala, quien la crea es el Anfitrion
//     {"op": "join_room", "code": "ABCDE"}    -> se une como Remoto a una sala existente
//     cualquier otro mensaje                  -> se reenvia ciego al otro peer de la sala
//   Servidor -> Cliente:
//     {"op": "room_created", "code": "ABCDE"}
//     {"op": "room_joined", "code": "ABCDE"}
//     {"op": "peer_joined"}                   -> avisa al Anfitrion que el Remoto ya esta
//     {"op": "peer_disconnected"}
//     {"op": "error", "message": "..."}
//     cualquier otro mensaje                  -> lo que el otro peer mando, reenviado tal cual
//
// Correr local: npm install && npm start (por defecto puerto 8080, override con PORT).

const { WebSocketServer } = require("ws");

const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 8080;
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // sin 0/O/1/I/L, para leerlo por voz/chat sin confundir
const CODE_LENGTH = 5;

/** @type {Map<string, {host: import("ws").WebSocket, remote: import("ws").WebSocket|null}>} */
const rooms = new Map();

function generateRoomCode() {
	let code;
	do {
		code = "";
		for (let i = 0; i < CODE_LENGTH; i++) {
			code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
		}
	} while (rooms.has(code));
	return code;
}

function send(ws, payload) {
	if (ws && ws.readyState === ws.OPEN) {
		ws.send(JSON.stringify(payload));
	}
}

function otherPeer(room, ws) {
	if (room.host === ws) return room.remote;
	if (room.remote === ws) return room.host;
	return null;
}

function findRoomByPeer(ws) {
	for (const [code, room] of rooms) {
		if (room.host === ws || room.remote === ws) return { code, room };
	}
	return null;
}

const wss = new WebSocketServer({ port: PORT });

wss.on("connection", (ws) => {
	ws.on("message", (raw) => {
		let msg;
		try {
			msg = JSON.parse(raw.toString());
		} catch (err) {
			send(ws, { op: "error", message: "JSON invalido" });
			return;
		}

		if (msg.op === "create_room") {
			const code = generateRoomCode();
			rooms.set(code, { host: ws, remote: null });
			ws._roomCode = code;
			ws._roomRole = "host";
			send(ws, { op: "room_created", code });
			return;
		}

		if (msg.op === "join_room") {
			const code = String(msg.code || "").toUpperCase();
			const room = rooms.get(code);
			if (!room) {
				send(ws, { op: "error", message: "Sala no encontrada" });
				return;
			}
			if (room.remote) {
				send(ws, { op: "error", message: "Esa sala ya tiene 2 jugadores" });
				return;
			}
			room.remote = ws;
			ws._roomCode = code;
			ws._roomRole = "remote";
			send(ws, { op: "room_joined", code });
			send(room.host, { op: "peer_joined" });
			return;
		}

		// Cualquier otro mensaje: reenvio ciego al otro lado de la misma sala.
		const found = findRoomByPeer(ws);
		if (!found) {
			send(ws, { op: "error", message: "No estas en ninguna sala todavia" });
			return;
		}
		const peer = otherPeer(found.room, ws);
		if (!peer) {
			send(ws, { op: "error", message: "Todavia no hay nadie del otro lado" });
			return;
		}
		send(peer, msg);
	});

	ws.on("close", () => {
		const found = findRoomByPeer(ws);
		if (!found) return;
		const peer = otherPeer(found.room, ws);
		send(peer, { op: "peer_disconnected" });
		rooms.delete(found.code);
	});
});

console.log(`[relay] escuchando en ws://0.0.0.0:${PORT}`);
