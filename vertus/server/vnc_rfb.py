"""Pure-stdlib VNC (RFB 3.8) framebuffer client + PNG encoder.

Why this exists: the guest path's "see its screen" promise must work with
zero installs on the host. QEMU exposes the guest display over VNC; this
module speaks just enough RFB 3.8 to request and decode raw framebuffer
rectangles (plus the desktop-resize pseudo-rectangle), and encodes the
resulting RGB pixels into a PNG with nothing but ``struct`` + ``zlib``. No
Pillow, no vncdotool, no external viewer — the hub turns a running guest's
screen into bytes any client can render (the /stream endpoint serves these
as multipart MJPEG-style frames).

Scope: framebuffer OUTPUT only. No input injection (keyboard/mouse) yet —
that is a small, well-defined follow-up (the same socket can carry
PointerEvent/KeyEvent messages once agents need to click inside their
guest).
"""

from __future__ import annotations

import socket
import struct
import zlib

RFB_VERSION = b"RFB 003.008\n"

# Pseudo-encodings (client interest list + server announcements).
ENC_RAW = 0
ENC_DESKTOP_SIZE = -223  # 0xFFFFFF21 as signed int32

# Pixel format we request: 32bpp little-endian (RFB integers are big-endian
# per spec; the byte ORDER of each pixel is little-endian B,G,R,X).
PIXEL_FORMAT = struct.pack(
    ">BBBBHHHBBBxxx",  # 16-byte SetPixelFormat payload
    32,  # bits per pixel
    24,  # depth
    0,   # big-endian flag: pixels are little-endian
    1,   # true colour
    255, 255, 255,  # red/green/blue max
    16, 8, 0,  # red/green/blue shift
)

# 32bpp little-endian: byte order B,G,R,X per pixel.
_PIX_BYTES = 4


class RfbError(Exception):
    """Protocol-level failure talking to the VNC server."""


class VncFramebuffer:
    """One VNC connection that can grab the guest's current screen.

    Usage::

        fb = VncFramebuffer("127.0.0.1", 5911, timeout=5)
        fb.connect()
        width, height, rgb = fb.grab()   # rgb is bytes, row-major, 3 bytes/px
        fb.close()

    ``grab()`` requests a FULL (non-incremental) framebuffer update, so each
    call returns the complete current screen — exactly what a poll-based
    frame stream needs. Multiple rectangles (and desktop resizes) are
    composited into the full buffer.
    """

    def __init__(self, host: str, port: int, timeout: float = 5.0) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self.width = 0
        self.height = 0
        self._fb: bytearray | None = None

    # ------------------------------------------------------------------
    # Connection setup
    # ------------------------------------------------------------------

    def connect(self) -> None:
        sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self._sock = sock
        try:
            self._handshake()
            self._set_pixel_format()
        except Exception:
            sock.close()
            self._sock = None
            raise

    def _read_exact(self, n: int) -> bytes:
        assert self._sock is not None
        chunks = bytearray()
        while len(chunks) < n:
            part = self._sock.recv(n - len(chunks))
            if not part:
                raise RfbError(f"VNC closed mid-message (wanted {n}, got {len(chunks)})")
            chunks += part
        return bytes(chunks)

    def _handshake(self) -> None:
        assert self._sock is not None
        self._sock.sendall(RFB_VERSION)
        server_version = self._read_exact(12)
        if server_version != RFB_VERSION:
            raise RfbError(f"unexpected VNC version: {server_version!r}")
        ntypes = self._read_exact(1)[0]
        if ntypes == 0:
            reason = self._read_exact(4)
            raise RfbError(f"VNC server refused connection: {reason!r}")
        types = self._read_exact(ntypes)
        if 1 not in types:  # security type 1 = no authentication
            raise RfbError(f"VNC requires auth (types {list(types)!r}); "
                           "start qemu with an unauthenticated -vnc")
        self._sock.sendall(b"\x01")            # pick "None"
        result = struct.unpack(">I", self._read_exact(4))[0]
        if result != 0:
            raise RfbError(f"VNC security handshake failed (result {result})")
        self._sock.sendall(b"\x01")            # ClientInit: shared
        self.width, self.height = struct.unpack(">HH", self._read_exact(4))
        # Skip the server's pixel format (16 bytes) and name (4 + len).
        self._read_exact(16)
        name_len = struct.unpack(">I", self._read_exact(4))[0]
        self._read_exact(name_len)
        self._fb = bytearray(self.width * self.height * _PIX_BYTES)

    def _set_pixel_format(self) -> None:
        assert self._sock is not None
        # SetPixelFormat: type 0, padding 3, then our 16-byte pixel format.
        self._sock.sendall(b"\x00" + b"\x00\x00\x00" + PIXEL_FORMAT)
        # SetEncodings: type 2, padding 1, count 2 (raw + desktop-size).
        self._sock.sendall(b"\x02\x00" + struct.pack(">H", 2)
                           + struct.pack(">i", ENC_RAW)
                           + struct.pack(">i", ENC_DESKTOP_SIZE))

    # ------------------------------------------------------------------
    # Framebuffer grabs
    # ------------------------------------------------------------------

    def grab(self) -> tuple[int, int, bytes]:
        """Request a full update and return ``(width, height, rgb)``."""
        assert self._sock is not None
        if self.width == 0 or self.height == 0:
            raise RfbError("VNC framebuffer has zero size")
        # FramebufferUpdateRequest: type 3, incremental 0, x, y, w, h.
        self._sock.sendall(b"\x03\x00" + struct.pack(">HHHH",
                                                     0, 0, self.width, self.height))
        msg_type = self._read_exact(1)[0]
        if msg_type != 0:  # 0 = FramebufferUpdate
            raise RfbError(f"unexpected VNC message type {msg_type}")
        self._read_exact(1)  # padding
        nrects = struct.unpack(">H", self._read_exact(2))[0]
        for _ in range(nrects):
            x, y, w, h = struct.unpack(">HHHH", self._read_exact(8))
            encoding = struct.unpack(">i", self._read_exact(4))[0]
            if encoding == ENC_DESKTOP_SIZE:
                self._resize(w, h)
                continue
            if encoding != ENC_RAW:
                raise RfbError(f"unsupported VNC encoding {encoding} (only raw)")
            data = self._read_exact(w * h * _PIX_BYTES)
            self._blit(x, y, w, h, data)
        return self.width, self.height, self._to_rgb()

    def _resize(self, width: int, height: int) -> None:
        self.width, self.height = width, height
        self._fb = bytearray(width * height * _PIX_BYTES)

    def _blit(self, x: int, y: int, w: int, h: int, data: bytes) -> None:
        assert self._fb is not None
        row_bytes = w * _PIX_BYTES
        for row in range(h):
            src = row * row_bytes
            dst = ((y + row) * self.width + x) * _PIX_BYTES
            self._fb[dst:dst + row_bytes] = data[src:src + row_bytes]

    def _to_rgb(self) -> bytes:
        """Convert the BGRX framebuffer to packed RGB (3 bytes per pixel)."""
        assert self._fb is not None
        fb = self._fb
        n = len(fb) // 4
        out = bytearray(n * 3)
        for i in range(n):
            j = i * 4
            k = i * 3
            out[k] = fb[j + 2]      # R
            out[k + 1] = fb[j + 1]  # G
            out[k + 2] = fb[j]      # B
        return bytes(out)

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None

    def __enter__(self) -> "VncFramebuffer":
        self.connect()
        return self

    def __exit__(self, *exc) -> None:  # noqa: ANN002
        self.close()


def encode_png_rgb(width: int, height: int, rgb: bytes) -> bytes:
    """Encode packed RGB24 pixels into a PNG (pure stdlib: struct + zlib)."""
    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body \
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = bytearray()
    stride = width * 3
    for row in range(height):
        raw.append(0)  # filter type 0 (None) per scanline
        raw += rgb[row * stride:(row + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )