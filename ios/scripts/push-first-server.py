#!/usr/bin/env python3
"""Offline sink for pong-check: a WebSocket server that pushes call audio the
moment the stream opens (a reconnect during an active call) and answers pings
like gorilla/websocket. Standard library only; prints its port, serves one client."""
import base64, hashlib, socket, struct, sys, threading, time

def handshake(conn):
    data = b''
    while b'\r\n\r\n' not in data:
        data += conn.recv(4096)
    headers = {k.lower(): v.strip() for k, _, v in (l.partition(':') for l in data.decode().split('\r\n')[1:] if l)}
    accept = base64.b64encode(hashlib.sha1((headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    proto = headers.get('sec-websocket-protocol', '').split(',')[0].strip()
    conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                  f'Sec-WebSocket-Accept: {accept}\r\n' + (f'Sec-WebSocket-Protocol: {proto}\r\n' if proto else '') + '\r\n').encode())

def frame(opcode, payload):
    n = len(payload)
    head = bytes([0x80 | opcode]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n))
    return head + payload

def main():
    server = socket.socket(); server.bind(('127.0.0.1', 0)); server.listen(1)
    print(server.getsockname()[1], flush=True)
    server.settimeout(30)
    conn, _ = server.accept(); handshake(conn)
    lock = threading.Lock(); done = threading.Event()
    def push():
        while not done.is_set():
            with lock:
                try: conn.sendall(frame(0x2, bytes(320)))
                except OSError: return
            time.sleep(0.02)
    threading.Thread(target=push, daemon=True).start()
    try:
        while True:
            b = conn.recv(2)
            if len(b) < 2: break
            opcode, n = b[0] & 0x0F, b[1] & 0x7F
            if n == 126: n = struct.unpack('>H', conn.recv(2))[0]
            mask = conn.recv(4); data = b''
            while len(data) < n: data += conn.recv(n - len(data))
            data = bytes(x ^ mask[i % 4] for i, x in enumerate(data))
            if opcode == 0x9:
                with lock: conn.sendall(frame(0xA, data))
            elif opcode == 0x8: break
    finally:
        done.set(); conn.close()

main()
