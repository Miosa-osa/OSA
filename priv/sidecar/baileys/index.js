const {
  default: makeWASocket,
  useMultiFileAuthState,
  DisconnectReason,
  makeCacheableSignalKeyStore,
} = require("@whiskeysockets/baileys");
const pino = require("pino");
const readline = require("readline");
const path = require("path");
const fs = require("fs");

const logger = pino({ level: "warn" }, pino.destination(2)); // stderr
const authDir =
  process.env.OSA_WA_AUTH_DIR ||
  path.join(process.env.HOME, ".osa", "channels", "whatsapp-web");

let sock = null;
let connectionState = "disconnected";
let qrData = null;
let userJid = null;

// Track whether connect() has already responded for a given request id
let connectRespondedIds = new Set();

// JSON-RPC response helpers
function respond(id, result) {
  if (id == null) return;
  process.stdout.write(JSON.stringify({ id, result }) + "\n");
}

function respondError(id, code, message) {
  if (id == null) return;
  process.stdout.write(JSON.stringify({ id, error: { code, message } }) + "\n");
}

function notify(method, params) {
  process.stdout.write(JSON.stringify({ method, params }) + "\n");
}

// WhatsApp connection
async function connect(id) {
  try {
    fs.mkdirSync(authDir, { recursive: true });
    const { state, saveCreds } = await useMultiFileAuthState(authDir);

    sock = makeWASocket({
      auth: {
        creds: state.creds,
        keys: makeCacheableSignalKeyStore(state.keys, logger),
      },
      printQRInTerminal: false,
      logger,
    });

    sock.ev.on("creds.update", saveCreds);

    sock.ev.on("connection.update", (update) => {
      const { connection, lastDisconnect, qr } = update;

      if (qr) {
        qrData = qr;
        connectionState = "qr";
        if (!connectRespondedIds.has(id)) {
          connectRespondedIds.add(id);
          respond(id, { status: "qr", qr });
        } else {
          notify("qr_update", { qr });
        }
      }

      if (connection === "open") {
        connectionState = "connected";
        userJid = sock.user?.id || null;
        if (!connectRespondedIds.has(id)) {
          connectRespondedIds.add(id);
          respond(id, { status: "connected", jid: userJid });
        } else {
          notify("connection_open", { jid: userJid });
        }
      }

      if (connection === "close") {
        const statusCode = lastDisconnect?.error?.output?.statusCode;
        connectionState = "disconnected";

        if (statusCode === DisconnectReason.loggedOut) {
          if (!connectRespondedIds.has(id)) {
            connectRespondedIds.add(id);
            respond(id, { status: "logged_out" });
          } else {
            notify("logged_out", {});
          }
        } else if (statusCode !== DisconnectReason.connectionClosed) {
          notify("connection_lost", { reason: statusCode });
        }
      }
    });

    sock.ev.on("messages.upsert", ({ messages }) => {
      for (const msg of messages) {
        if (!msg.key.fromMe && msg.message) {
          const text =
            msg.message.conversation ||
            msg.message.extendedTextMessage?.text ||
            "";

          if (text) {
            notify("message", {
              from: msg.key.remoteJid,
              text,
              timestamp: msg.messageTimestamp,
              push_name: msg.pushName || "",
            });
          }
        }
      }
    });
  } catch (err) {
    respondError(id, -1, err.message);
  }
}

async function sendMessage(id, params) {
  if (!sock || connectionState !== "connected") {
    respondError(id, -2, "Not connected");
    return;
  }

  try {
    const jid = params.to.includes("@")
      ? params.to
      : `${params.to}@s.whatsapp.net`;
    await sock.sendMessage(jid, { text: params.text });
    respond(id, { status: "sent", to: jid });
  } catch (err) {
    respondError(id, -3, err.message);
  }
}

async function logout(id) {
  try {
    if (sock) {
      await sock.logout();
      sock = null;
    }
    connectionState = "disconnected";
    userJid = null;

    // Clear auth state
    fs.rmSync(authDir, { recursive: true, force: true });

    respond(id, { status: "logged_out" });
  } catch (err) {
    respondError(id, -4, err.message);
  }
}

function health(id) {
  respond(id, {
    status: connectionState,
    jid: userJid,
    uptime: process.uptime(),
  });
}

function status(id) {
  respond(id, {
    connection: connectionState,
    jid: userJid,
    qr_available: qrData !== null,
    auth_dir: authDir,
  });
}

// JSON-RPC dispatcher
const rl = readline.createInterface({ input: process.stdin });

rl.on("line", async (line) => {
  try {
    const req = JSON.parse(line.trim());
    const { id, method, params } = req;

    switch (method) {
      case "connect":
        await connect(id);
        break;
      case "send_message":
        await sendMessage(id, params || {});
        break;
      case "health":
        health(id);
        break;
      case "status":
        status(id);
        break;
      case "logout":
        await logout(id);
        break;
      default:
        respondError(id, -32601, `Unknown method: ${method}`);
    }
  } catch (err) {
    logger.error({ err }, "Failed to process request");
  }
});

rl.on("close", () => {
  if (sock) sock.end();
  process.exit(0);
});

// Graceful shutdown
process.on("SIGTERM", () => {
  if (sock) sock.end();
  process.exit(0);
});
