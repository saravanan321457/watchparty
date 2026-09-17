const WebSocket = require("ws");

const PORT = 8091;

const wss = new WebSocket.Server({
    port: PORT,
});

const rooms = new Map();

console.log(`Signaling server running on ws://0.0.0.0:${PORT}`);

wss.on("connection", (ws) => {
    console.log("Client connected");

    let currentRoom = null;
    let role = null;

    ws.on("message", (message) => {
        let data;
        try {
            data = JSON.parse(message.toString());
        } catch (error) {
            console.log("Invalid JSON");
            return;
        }

        console.log("Received:", data.type);

        if (data.type === "create_room") {
            const roomId = data.roomId;
            if (rooms.has(roomId)) {
                ws.send(JSON.stringify({ type: "error", message: "Room already exists" }));
                return;
            }
            rooms.set(roomId, { host: ws, viewer: null });
            currentRoom = roomId;
            role = "host";
            ws.send(JSON.stringify({ type: "room_created", roomId: roomId, role: "host" }));
            console.log(`Room created: ${roomId}`);
        }

        else if (data.type === "join_room") {
            const roomId = data.roomId;
            const room = rooms.get(roomId);
            if (!room) {
                ws.send(JSON.stringify({ type: "error", message: "Room not found" }));
                return;
            }
            if (room.viewer) {
                ws.send(JSON.stringify({ type: "error", message: "Room already has a viewer" }));
                return;
            }
            room.viewer = ws;
            currentRoom = roomId;
            role = "viewer";
            ws.send(JSON.stringify({ type: "room_joined", roomId: roomId }));
            room.host.send(JSON.stringify({ type: "viewer_joined" }));
            console.log(`Viewer joined room: ${roomId}`);
        }

        else if (data.type === "offer" || data.type === "answer" || data.type === "ice_candidate") {
            const room = rooms.get(currentRoom);
            if (!room) return;
            const target = role === "host" ? room.viewer : room.host;
            if (target) target.send(JSON.stringify(data));
        }
    });

    ws.on("close", () => {
        console.log("Client disconnected");
        if (currentRoom) {
            const room = rooms.get(currentRoom);
            if (!room) return;
            
            if (role === "host") {
                console.log(`Host left room: ${currentRoom}`);
                if (room.viewer) {
                    room.viewer.send(JSON.stringify({ type: "host_left" }));
                    room.viewer.close();
                }
                rooms.delete(currentRoom);
            } else if (role === "viewer") {
                console.log(`Viewer left room: ${currentRoom}`);
                room.viewer = null;
                if (room.host) {
                    room.host.send(JSON.stringify({ type: "viewer_left" }));
                }
            }
        }
    });
});
