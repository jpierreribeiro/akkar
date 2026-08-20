#!/usr/bin/env bash
# A decompression bomb against akkar's body_limit boundary.
#
# RESULT, on the benchmark box, 2026-08-20:
#
#   Content-Encoding: gzip   -> not inflated at all. akkar honours
#                               Transfer-Encoding for request bodies, not
#                               Content-Encoding, so a `Content-Encoding: gzip`
#                               body reaches the JSON parser as raw gzip bytes
#                               and is rejected 400/415. The bomb never runs.
#
#   Transfer-Encoding: gzip  -> the path that DOES inflate. A 200 MB-inflated
#                               body (203 KB on the wire, 1000x) is refused
#                               400 Bad Request, RSS stays flat at 13.2 MB
#                               (+250 KB, not +200 MB), and the server answers
#                               the next request. `read_body`'s loop
#                               (init.lua:2190) counts INFLATED bytes and stops
#                               at the first chunk past the 1 MB limit.
#
# So the boundary the external audit worried about holds, and it holds on the
# path that actually decompresses. The `bomb-sink.lua` app it drives is beside
# this file.
# The path akkar ACTUALLY inflates: Transfer-Encoding, not Content-Encoding.
#
# h1_stream.lua:496 enables inflate on `Transfer-Encoding: gzip`. TE is
# hop-by-hop and chunked, so a raw `--data-binary` gzip will not do; the body
# must be gzip-then-chunked. curl will not build that, so this speaks raw HTTP
# over a socket with python: chunked framing, each chunk a slice of the gzip
# stream, and TE: gzip, chunked in the header.
cd "$HOME/akkar-git" || exit 1
export LUA_PATH="./?.lua;./?/init.lua;/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua;;"
export LUA_CPATH="/usr/local/lib/lua/5.4/?.so;;"

lua5.4 bench/study/apps/bomb-sink.lua &
SRV=$!
sleep 2
peak() { awk '/VmRSS/{print $2}' "/proc/$SRV/status" 2>/dev/null; }
echo "RSS before:           $(peak) KB"

python3 - <<'PY'
import socket, gzip, io, time

# 200 MB of JSON, gzipped, then chunk-framed.
buf = io.BytesIO()
with gzip.GzipFile(fileobj=buf, mode="wb") as g:
    g.write(b'{"x":"')
    block = b"a" * (1024 * 1024)
    for _ in range(200):
        g.write(block)
    g.write(b'"}')
gz = buf.getvalue()
print("gzip stream: %d bytes on the wire, ~200 MB inflated" % len(gz))

s = socket.create_connection(("127.0.0.1", 18090), timeout=30)
head = (
    "POST /sink HTTP/1.1\r\n"
    "Host: x\r\n"
    "Content-Type: application/json\r\n"
    "Transfer-Encoding: gzip, chunked\r\n"
    "\r\n"
).encode()
s.sendall(head)

# Frame the gzip stream as chunks of 16 KB.
try:
    for i in range(0, len(gz), 16384):
        piece = gz[i:i+16384]
        s.sendall(("%x\r\n" % len(piece)).encode() + piece + b"\r\n")
    s.sendall(b"0\r\n\r\n")
except Exception as e:
    print("send stopped:", e)

s.settimeout(10)
resp = b""
try:
    while len(resp) < 512:
        d = s.recv(512)
        if not d:
            break
        resp += d
except Exception as e:
    print("recv:", e)
line = resp.split(b"\r\n", 1)[0].decode(errors="replace") if resp else "<nothing>"
print("server said:", line)
s.close()
PY

sleep 1
echo "RSS after:            $(peak) KB"
STILL=$(curl -s -m 5 -X POST -H "Content-Type: application/json" -d '{}' \
  http://127.0.0.1:18090/sink)
echo "still serves:         ${STILL:-<dead>}"
kill $SRV 2>/dev/null
