#!/usr/bin/env node
/**
 * OSA WhatsApp Bridge
 *
 * Standalone Node.js process that connects to WhatsApp via Baileys
 * and exposes HTTP endpoints for the Elixir channel adapter.
 *
 * Endpoints:
 *   GET  /messages       - Poll for new incoming messages
 *   POST /send           - Send a text message { chatId, message }
 *   POST /send-media     - Send media { chatId, filePath, mediaType?, caption? }
 *   POST /typing         - Send typing indicator { chatId }
 *   GET  /chat/:id       - Get chat info
 *   GET  /health         - Health check
 *
 * Usage:
 *   node bridge.js --port 3001 --session ~/.osa/whatsapp/session
 *   node bridge.js --pair-only  # QR pairing only, no HTTP server
 *
 * Environment:
 *   WHATSAPP_MODE          - "bot" or "self-chat" (default: self-chat)
 *   WHATSAPP_ALLOWED_USERS - Comma-separated phone numbers
 *   WHATSAPP_REPLY_PREFIX  - Prefix for outgoing messages (default: none)
 */

import { makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, downloadMediaMessage } from '@whiskeysockets/baileys';
import express from 'express';
import { Boom } from '@hapi/boom';
import pino from 'pino';
import path from 'path';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'fs';
import { randomBytes } from 'crypto';
import qrcode from 'qrcode-terminal';

// ── CLI Args ─────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
function getArg(name, defaultVal) {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : defaultVal;
}

const PORT = parseInt(getArg('port', process.env.WHATSAPP_BRIDGE_PORT || '3001'), 10);
const SESSION_DIR = getArg('session', path.join(process.env.HOME || '~', '.osa', 'whatsapp', 'session'));
const CACHE_DIR = path.join(process.env.HOME || '~', '.osa', 'whatsapp', 'cache');
const PAIR_ONLY = args.includes('--pair-only');
const MODE = getArg('mode', process.env.WHATSAPP_MODE || 'self-chat');
const REPLY_PREFIX = (process.env.WHATSAPP_REPLY_PREFIX || '').replace(/\\n/g, '\n');

const ALLOWED_USERS = new Set(
  (process.env.WHATSAPP_ALLOWED_USERS || '')
    .split(',')
    .map(s => s.trim().replace(/^\+/, '').replace(/:.*@/, '@').replace(/@.*/, ''))
    .filter(Boolean)
);

mkdirSync(SESSION_DIR, { recursive: true });
mkdirSync(CACHE_DIR, { recursive: true });

const logger = pino({ level: 'warn' });

// ── State ────────────────────────────────────────────────────────────────

const messageQueue = [];
const MAX_QUEUE = 200;
const recentSentIds = new Set();
let sock = null;
let connectionState = 'disconnected';

// ── WhatsApp Connection ──────────────────────────────────────────────────

async function startSocket() {
  const { state, saveCreds } = await useMultiFileAuthState(SESSION_DIR);
  const { version } = await fetchLatestBaileysVersion();

  sock = makeWASocket({
    version,
    auth: state,
    logger,
    printQRInTerminal: false,
    browser: ['OSA Agent', 'Chrome', '130.0'],
    syncFullHistory: false,
    markOnlineOnConnect: false,
    getMessage: async () => ({ conversation: '' }),
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      console.log('\n📱 Scan this QR code with WhatsApp:\n');
      qrcode.generate(qr, { small: true });
      console.log('\nWaiting for scan...\n');
    }

    if (connection === 'close') {
      const reason = new Boom(lastDisconnect?.error)?.output?.statusCode;
      connectionState = 'disconnected';

      if (reason === DisconnectReason.loggedOut) {
        console.log('❌ Logged out. Delete session and re-pair.');
        process.exit(1);
      } else {
        const delay = reason === 515 ? 1000 : 3000;
        console.log(`⚠️  Disconnected (${reason}). Reconnecting in ${delay}ms...`);
        setTimeout(startSocket, delay);
      }
    } else if (connection === 'open') {
      connectionState = 'connected';
      console.log('✅ WhatsApp connected');
      if (PAIR_ONLY) {
        console.log('✅ Pairing complete. Session saved.');
        setTimeout(() => process.exit(0), 2000);
      }
    }
  });

  // ── Incoming Messages ────────────────────────────────────────────────

  sock.ev.on('messages.upsert', async ({ messages, type }) => {
    if (type !== 'notify' && type !== 'append') return;

    for (const msg of messages) {
      if (!msg.message) continue;

      const chatId = msg.key.remoteJid;
      const senderId = msg.key.participant || chatId;
      const isGroup = chatId.endsWith('@g.us');
      const senderNumber = senderId.replace(/@.*/, '');

      // Skip bot echoes
      if (msg.key.fromMe) {
        if (MODE === 'bot' || isGroup) continue;
        // Self-chat: only process own self-chat
        const myNum = (sock.user?.id || '').replace(/:.*@/, '@').replace(/@.*/, '');
        const myLid = (sock.user?.lid || '').replace(/:.*@/, '@').replace(/@.*/, '');
        const chatNum = chatId.replace(/@.*/, '');
        if (!(myNum && chatNum === myNum) && !(myLid && chatNum === myLid)) continue;
      }

      // Allowlist check
      if (!msg.key.fromMe && ALLOWED_USERS.size > 0) {
        const normalized = senderNumber;
        if (!ALLOWED_USERS.has(normalized)) continue;
      }

      // Extract content
      let body = '';
      let hasMedia = false;
      let mediaType = '';
      const mediaUrls = [];

      const m = msg.message;
      if (m.conversation) {
        body = m.conversation;
      } else if (m.extendedTextMessage?.text) {
        body = m.extendedTextMessage.text;
      } else if (m.imageMessage) {
        body = m.imageMessage.caption || '';
        hasMedia = true;
        mediaType = 'image';
        try {
          const buf = await downloadMediaMessage(msg, 'buffer', {}, { logger, reuploadRequest: sock.updateMediaMessage });
          const ext = (m.imageMessage.mimetype || 'image/jpeg').includes('png') ? '.png' : '.jpg';
          const fp = path.join(CACHE_DIR, `img_${randomBytes(6).toString('hex')}${ext}`);
          writeFileSync(fp, buf);
          mediaUrls.push(fp);
        } catch (e) { console.error('[bridge] image download failed:', e.message); }
      } else if (m.audioMessage || m.pttMessage) {
        hasMedia = true;
        mediaType = m.pttMessage ? 'ptt' : 'audio';
        try {
          const buf = await downloadMediaMessage(msg, 'buffer', {}, { logger, reuploadRequest: sock.updateMediaMessage });
          const fp = path.join(CACHE_DIR, `aud_${randomBytes(6).toString('hex')}.ogg`);
          writeFileSync(fp, buf);
          mediaUrls.push(fp);
        } catch (e) { console.error('[bridge] audio download failed:', e.message); }
      } else if (m.documentMessage) {
        body = m.documentMessage.caption || '';
        hasMedia = true;
        mediaType = 'document';
        try {
          const buf = await downloadMediaMessage(msg, 'buffer', {}, { logger, reuploadRequest: sock.updateMediaMessage });
          const name = (m.documentMessage.fileName || 'doc').replace(/[^a-zA-Z0-9._-]/g, '_');
          const fp = path.join(CACHE_DIR, `doc_${randomBytes(6).toString('hex')}_${name}`);
          writeFileSync(fp, buf);
          mediaUrls.push(fp);
        } catch (e) { console.error('[bridge] doc download failed:', e.message); }
      } else if (m.videoMessage) {
        body = m.videoMessage.caption || '';
        hasMedia = true;
        mediaType = 'video';
      }

      if (hasMedia && !body) body = `[${mediaType}]`;

      // Skip agent echoes
      if (msg.key.fromMe && REPLY_PREFIX && body.startsWith(REPLY_PREFIX)) continue;
      if (recentSentIds.has(msg.key.id)) continue;
      if (!body && !hasMedia) continue;

      messageQueue.push({
        messageId: msg.key.id,
        chatId,
        senderId,
        senderName: msg.pushName || senderNumber,
        isGroup,
        body,
        hasMedia,
        mediaType,
        mediaUrls,
        timestamp: msg.messageTimestamp,
      });

      if (messageQueue.length > MAX_QUEUE) messageQueue.shift();
    }
  });
}

// ── HTTP API ─────────────────────────────────────────────────────────────

const app = express();
app.use(express.json());

app.get('/messages', (_req, res) => {
  res.json(messageQueue.splice(0, messageQueue.length));
});

app.post('/send', async (req, res) => {
  if (!sock || connectionState !== 'connected') return res.status(503).json({ error: 'Not connected' });
  const { chatId, message } = req.body;
  if (!chatId || !message) return res.status(400).json({ error: 'chatId and message required' });

  try {
    const text = REPLY_PREFIX ? `${REPLY_PREFIX}${message}` : message;
    const sent = await sock.sendMessage(chatId, { text });
    if (sent?.key?.id) {
      recentSentIds.add(sent.key.id);
      if (recentSentIds.size > 50) recentSentIds.delete(recentSentIds.values().next().value);
    }
    res.json({ success: true, messageId: sent?.key?.id });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/send-media', async (req, res) => {
  if (!sock || connectionState !== 'connected') return res.status(503).json({ error: 'Not connected' });
  const { chatId, filePath, mediaType, caption } = req.body;
  if (!chatId || !filePath) return res.status(400).json({ error: 'chatId and filePath required' });
  if (!existsSync(filePath)) return res.status(404).json({ error: 'File not found' });

  try {
    const buf = readFileSync(filePath);
    const ext = filePath.split('.').pop().toLowerCase();
    const type = mediaType || (['jpg','jpeg','png','webp','gif'].includes(ext) ? 'image' : ['mp4','mov'].includes(ext) ? 'video' : 'document');

    let payload;
    if (type === 'image') payload = { image: buf, caption, mimetype: `image/${ext === 'jpg' ? 'jpeg' : ext}` };
    else if (type === 'video') payload = { video: buf, caption, mimetype: 'video/mp4' };
    else payload = { document: buf, fileName: path.basename(filePath), caption, mimetype: 'application/octet-stream' };

    const sent = await sock.sendMessage(chatId, payload);
    if (sent?.key?.id) recentSentIds.add(sent.key.id);
    res.json({ success: true, messageId: sent?.key?.id });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/typing', async (req, res) => {
  if (!sock || connectionState !== 'connected') return res.json({ success: false });
  try { await sock.sendPresenceUpdate('composing', req.body.chatId); res.json({ success: true }); }
  catch { res.json({ success: false }); }
});

app.get('/chat/:id', async (req, res) => {
  const chatId = req.params.id;
  if (chatId.endsWith('@g.us') && sock) {
    try {
      const md = await sock.groupMetadata(chatId);
      return res.json({ name: md.subject, isGroup: true, participants: md.participants.map(p => p.id) });
    } catch { /* fall through */ }
  }
  res.json({ name: chatId.replace(/@.*/, ''), isGroup: false, participants: [] });
});

app.get('/health', (_req, res) => {
  res.json({ status: connectionState, queueLength: messageQueue.length, uptime: process.uptime() });
});

// ── Start ────────────────────────────────────────────────────────────────

if (PAIR_ONLY) {
  console.log('📱 WhatsApp pairing mode');
  console.log(`📁 Session: ${SESSION_DIR}\n`);
  startSocket();
} else {
  app.listen(PORT, '127.0.0.1', () => {
    console.log(`🌉 OSA WhatsApp bridge on port ${PORT} (mode: ${MODE})`);
    console.log(`📁 Session: ${SESSION_DIR}`);
    if (ALLOWED_USERS.size > 0) console.log(`🔒 Allowed: ${[...ALLOWED_USERS].join(', ')}`);
    console.log();
    startSocket();
  });
}
