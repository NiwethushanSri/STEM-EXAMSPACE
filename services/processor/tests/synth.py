"""Test helpers: turn the fixture PDFs into scans and phone photos.

Every picture is made while the tests run, from the committed PDFs, with seeded randomness, so the
results are the same on every run. Nothing made here is committed.
"""
from __future__ import annotations

import hashlib
import io
import json
import math
import struct
import zlib
from functools import lru_cache
from pathlib import Path

import cv2
import numpy as np
import pypdfium2 as pdfium
from PIL import Image

FIXTURES = Path(__file__).parent / "fixtures"
CODES = json.loads((FIXTURES / "codes.json").read_text())
CODE_A: str = CODES["codeA"]
CODE_B: str = CODES["codeB"]
DPI = 200
WHITE = (255, 255, 255)


def fixture_bytes(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


@lru_cache(maxsize=6)
def _render(name: str, index: int) -> np.ndarray:
    doc = pdfium.PdfDocument(fixture_bytes(name))
    try:
        img = doc[index].render(scale=DPI / 72, rev_byteorder=True).to_numpy()[:, :, :3].copy()
    finally:
        doc.close()
    img.setflags(write=False)
    return img


def render(name: str, index: int) -> np.ndarray:
    """Page `index` (0-based) of a fixture PDF as a clean RGB picture at 200 dpi."""
    return _render(name, index).copy()


def _noise(rng: np.random.Generator, img: np.ndarray, sigma: float, gain: float = 1.0) -> np.ndarray:
    out = img.astype(np.float32) * gain
    out += rng.standard_normal(img.shape, dtype=np.float32) * sigma
    return np.clip(out, 0, 255).astype(np.uint8)


def scan(page: np.ndarray, *, turn: int = 0, tilt: float = 0.0, margin: float = 0.0, seed: int = 0) -> np.ndarray:
    """A sheet-fed scan of a printed page: turned clockwise by `turn` degrees (90° steps), tilted clockwise
    by `tilt` degrees inside the scanner frame, with scanner noise. The frame is the page's size plus
    `margin` (a share of each side) of white all round; past about 4° a frame without a margin cuts the
    page's corners, code included, as a real scanner would."""
    img = np.ascontiguousarray(np.rot90(page, -(turn // 90)))
    if margin:
        h, w = img.shape[:2]
        my, mx = round(h * margin), round(w * margin)
        img = cv2.copyMakeBorder(img, my, my, mx, mx, cv2.BORDER_CONSTANT, value=WHITE)
    if tilt:
        h, w = img.shape[:2]
        m = cv2.getRotationMatrix2D((w / 2, h / 2), -tilt, 1.0)
        img = cv2.warpAffine(img, m, (w, h), flags=cv2.INTER_LINEAR, borderValue=WHITE)
    return _noise(np.random.default_rng(seed), img, 3.0, 0.97)


def blank_back(front: np.ndarray | None = None, *, seed: int = 0) -> np.ndarray:
    """The empty back of a sheet in a duplex scan: off-white paper, scanner noise, a faint mirror image of
    the printed front showing through, and a thin shadow along the leading edge."""
    h, w = 2339, 1654
    grey = np.full((h, w), 246.0, np.float32)
    if front is not None:
        ink = 255.0 - cv2.cvtColor(np.ascontiguousarray(front[:, ::-1]), cv2.COLOR_RGB2GRAY).astype(np.float32)
        grey -= cv2.GaussianBlur(cv2.resize(ink, (w, h)), (0, 0), 2.0) * 0.06
    grey[:, :8] *= 0.7
    rgb = np.repeat(grey[:, :, None], 3, axis=2)
    return _noise(np.random.default_rng(seed), rgb, 2.5)


def with_writing(page: np.ndarray, text: str = "see next page") -> np.ndarray:
    """A copy of `page` with one short line of handwriting-sized text in the middle."""
    out = page.copy()
    h, w = out.shape[:2]
    cv2.putText(out, text, (w // 3, h // 2), cv2.FONT_HERSHEY_SCRIPT_SIMPLEX, 1.6, (40, 40, 60), 3, cv2.LINE_AA)
    return out


# Where tagged() puts its colours on a clean 200 dpi copy page: the identity line ends 2 pt above the top
# rule (row 83); "Question page n" sits in this box (rows, columns) on the master's question pages.
IDENTITY_ROWS = slice(0, 80)
QUESTION_BOX = (slice(330, 460), slice(80, 760))
RED, BLUE = (255, 0, 0), (0, 0, 255)


def tagged(page: np.ndarray) -> np.ndarray:
    """A copy of a clean copy page with the candidate's identity line printed red and the question text
    printed blue, so tests can find exactly those pixels after any turn, warp or crop (red()/blue())."""
    out = page.copy()
    for rows_cols, colour in (((IDENTITY_ROWS, slice(None)), RED), (QUESTION_BOX, BLUE)):
        part = out[rows_cols]
        part[cv2.cvtColor(part, cv2.COLOR_RGB2GRAY) < 160] = colour
    return out


def _channels(img: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """The picture's channels scaled so its paper is white, so a dim photo's tags still show."""
    paper = max(float(np.percentile(img[::4, ::4].max(axis=2), 95)), 1.0)
    scaled = img.astype(np.float32) * (255.0 / paper)
    return scaled[:, :, 0], scaled[:, :, 1], scaled[:, :, 2]


def red(img: np.ndarray) -> np.ndarray:
    """Where a picture shows the red tag (the identity line), as a mask."""
    r, g, b = _channels(img)
    return (r > 120) & (r - g > 60) & (r - b > 60)


def blue(img: np.ndarray) -> np.ndarray:
    """Where a picture shows the blue tag (the question text), as a mask."""
    r, g, b = _channels(img)
    return (b > 120) & (b - r > 60) & (b - g > 60)


def keystone(page: np.ndarray, k: float, *, fill: float = 0.95, tone: str = "white", seed: int = 0,
             shadow: bool = False) -> np.ndarray:
    """A phone photo filling an A4-shaped frame (fill = share of it), taken from below the page so its top
    is `k` narrower and lower (keystone), on a table of `tone`, as saved straight into a home PDF. `shadow`
    draws a thin grey line just above the paper's top edge, the shadow a lifted sheet casts."""
    ph, pw = page.shape[:2]
    w, h = 1654, 2339
    out = table(w, h, tone=tone, seed=seed)
    s = fill * min(w / pw, h / ph)
    cx, cy, hw, hh = w / 2, h / 2, pw * s / 2, ph * s / 2
    drop = hh * k
    dst = np.float32([[cx - hw * (1 - k), cy - hh + drop], [cx + hw * (1 - k), cy - hh + drop],
                      [cx + hw, cy + hh], [cx - hw, cy + hh]])
    m = cv2.getPerspectiveTransform(np.float32([[0, 0], [pw, 0], [pw, ph], [0, ph]]), dst)
    cv2.warpPerspective(page, m, (w, h), dst=out, flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_TRANSPARENT)
    if shadow:
        y = int(dst[0, 1]) - 5
        cv2.line(out, (int(dst[0, 0]) - 6, y), (int(dst[1, 0]) + 6, y), (200, 200, 200), 3, cv2.LINE_AA)
    return _noise(np.random.default_rng(seed), out, 3.0)


def on_pile(page: np.ndarray, mm: float) -> np.ndarray:
    """The page lying on the rest of the pile: the sheet below shows `mm` above it, and the top sheet's
    edge casts a faint shadow line across it."""
    lead = round(mm * DPI / 25.4)
    stack = cv2.copyMakeBorder(page, lead, 0, 0, 0, cv2.BORDER_CONSTANT, value=(250, 250, 250))
    stack[lead - 2:lead + 1] = 215
    return stack


def with_lead_in(page: np.ndarray, mm: float) -> np.ndarray:
    """A sheet-fed scan frame with `mm` of white lead-in above the page."""
    lead = round(mm * DPI / 25.4)
    return cv2.copyMakeBorder(page, lead, 0, 0, 0, cv2.BORDER_CONSTANT, value=WHITE)


def table(width: int, height: int, *, tone: str = "dark", seed: int = 0) -> np.ndarray:
    """A table top. "dark" (the default): wood with low-frequency blotches, grain streaks and fine noise,
    brownish. "light": a near-white laminate, a little darker than paper. "white": as white as the paper,
    so a page on it shows no edge at all."""
    rng = np.random.default_rng(seed)
    coarse = rng.uniform(0, 1, (height // 60 + 2, width // 60 + 2)).astype(np.float32)
    coarse = cv2.resize(coarse, (width, height), interpolation=cv2.INTER_CUBIC)
    fine = rng.standard_normal((height, width), dtype=np.float32)
    if tone == "white":
        rgb = np.repeat((253.0 + fine * 2.0)[:, :, None], 3, axis=2)
    elif tone == "light":
        v = 228.0 + coarse * 10.0 + fine * 3.0
        rgb = np.stack([v * 1.0, v * 0.985, v * 0.96], axis=2)
    else:
        rows = np.arange(height, dtype=np.float32)[:, None]
        grain = np.sin(rows / 7.0 + coarse * 6.0) * 10.0
        v = 48.0 + coarse * 28.0 + grain + fine * 6.0
        rgb = np.stack([v * 1.0, v * 0.78, v * 0.58], axis=2)
    return np.clip(rgb, 0, 255).astype(np.uint8)


def printed(page: np.ndarray, *, scale: float = 1.0, shift_mm: tuple[float, float] = (0.0, 0.0)) -> np.ndarray:
    """The A4 sheet that comes out of a printer: the copy page printed at `scale` (0.95 is a typical "fit to
    page"), centred on the sheet, then moved by `shift_mm` (right, down)."""
    h, w = page.shape[:2]
    sw, sh = round(w * scale), round(h * scale)
    small = cv2.resize(page, (sw, sh), interpolation=cv2.INTER_AREA)
    px_per_mm = DPI / 25.4
    m = np.float32([[1, 0, (w - sw) / 2 + shift_mm[0] * px_per_mm], [0, 1, (h - sh) / 2 + shift_mm[1] * px_per_mm]])
    return cv2.warpAffine(small, m, (w, h), flags=cv2.INTER_LINEAR, borderValue=WHITE)


def photo(
    page: np.ndarray,
    *,
    turn: int = 0,
    angle: float = 0.0,
    skew: float = 0.05,
    fill: float = 0.82,
    size: tuple[int, int] = (1800, 2400),
    light: float = 1.0,
    blur: float = 0.0,
    crop_top: float = 0.0,
    table_tone: str = "dark",
    seed: int = 0,
) -> tuple[np.ndarray, np.ndarray]:
    """A phone photo of a printed page lying on a table (`table_tone`: dark, light or white; see table()).

    The page is turned clockwise by `turn` + `angle` degrees, scaled so it fills `fill` of the frame, and
    its corners are pushed about by up to `skew` of its width (a camera held at an angle). Uneven light is
    multiplied by `light`, the photo is blurred by `blur` (Gaussian sigma in pixels) and gets sensor noise;
    `crop_top` cuts that fraction off the top of the photo. `size` is (width, height).

    Returns the RGB photo and the page's corners in it, in the order top-left, top-right, bottom-right,
    bottom-left of the page as printed (before any crop is applied, shifted by it).
    """
    rng = np.random.default_rng(seed)
    width, height = size
    out = table(width, height, tone=table_tone, seed=seed + 1000)
    ph, pw = page.shape[:2]
    theta = math.radians(turn + angle)
    c, s = math.cos(theta), math.sin(theta)
    corners = np.array([[-pw / 2, -ph / 2], [pw / 2, -ph / 2], [pw / 2, ph / 2], [-pw / 2, ph / 2]])
    turned = corners @ np.array([[c, -s], [s, c]]).T
    span = turned.max(axis=0) - turned.min(axis=0)
    scale = fill * min(width / span[0], height / span[1])
    dst = turned * scale + (width / 2, height / 2)
    dst += rng.uniform(-skew, skew, (4, 2)) * pw * scale
    src = np.array([[0, 0], [pw, 0], [pw, ph], [0, ph]], np.float32)
    m = cv2.getPerspectiveTransform(src, dst.astype(np.float32))
    cv2.warpPerspective(page, m, (width, height), dst=out, flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_TRANSPARENT)

    xs = np.linspace(0.0, 1.0, width, dtype=np.float32)[None, :]
    ys = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    lamp = (0.80 + 0.12 * xs + 0.06 * ys) * light
    lit = out.astype(np.float32) * lamp[:, :, None]
    if blur:
        lit = cv2.GaussianBlur(lit, (0, 0), blur)
    img = _noise(rng, lit, 4.0)
    cut = int(round(crop_top * height))
    if cut:
        img = np.ascontiguousarray(img[cut:])
        dst = dst - (0, cut)
    return img, dst.astype(np.float32)


def jpeg(img: np.ndarray, *, quality: int = 90, orientation: int | None = None) -> bytes:
    """`img` as JPEG bytes; `orientation` sets the EXIF orientation tag (6 = turn 90° clockwise to view)."""
    buf = io.BytesIO()
    im = Image.fromarray(img)
    if orientation is None:
        im.save(buf, "JPEG", quality=quality)
    else:
        exif = Image.Exif()
        exif[0x0112] = orientation
        im.save(buf, "JPEG", quality=quality, exif=exif)
    return buf.getvalue()


def png_header_only(width: int, height: int) -> bytes:
    """A PNG whose header claims width x height pixels but which holds no picture data: opening it reads
    the size; decoding it would fail (or, were it real, take width x height x 3 bytes)."""

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"")) + chunk(b"IEND", b"")


def scan_pdf(pages: list[np.ndarray]) -> bytes:
    """A scanner's PDF: one JPEG picture per page, at 200 dpi (so each page is A4 sized)."""
    ims = [Image.fromarray(p) for p in pages]
    buf = io.BytesIO()
    ims[0].save(buf, "PDF", save_all=True, append_images=ims[1:], resolution=float(DPI), quality=85)
    return buf.getvalue()


# PDF standard security handler, revision 2 (40-bit RC4), enough to lock a file with a user password.
_PAD = bytes.fromhex("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A")


def _rc4(key: bytes, data: bytes) -> bytes:
    box = list(range(256))
    j = 0
    for i in range(256):
        j = (j + box[i] + key[i % len(key)]) % 256
        box[i], box[j] = box[j], box[i]
    i = j = 0
    out = bytearray()
    for byte in data:
        i = (i + 1) % 256
        j = (j + box[i]) % 256
        box[i], box[j] = box[j], box[i]
        out.append(byte ^ box[(box[i] + box[j]) % 256])
    return bytes(out)


def encrypted_pdf(password: str = "secret") -> bytes:
    """A one-page PDF that opens only with `password`."""

    def pad(p: str) -> bytes:
        return (p.encode("latin-1") + _PAD)[:32]

    perms = -4
    file_id = hashlib.md5(b"stem-examspace locked fixture").digest()
    owner = _rc4(hashlib.md5(pad(password + "-owner")).digest()[:5], pad(password))
    key = hashlib.md5(pad(password) + owner + struct.pack("<i", perms) + file_id).digest()[:5]
    user = _rc4(key, _PAD)
    objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] >>",
        f"<< /Filter /Standard /V 1 /R 2 /O <{owner.hex()}> /U <{user.hex()}> /P {perms} >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for n, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{n} 0 obj\n{body}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("latin-1")
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode("latin-1")
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R /Encrypt 4 0 R /ID [<{file_id.hex()}> <{file_id.hex()}>] >>\n"
        f"startxref\n{xref}\n%%EOF\n"
    ).encode("latin-1")
    return bytes(out)
