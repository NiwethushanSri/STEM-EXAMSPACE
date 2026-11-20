"""Image operations for preparing script pages. Pure functions: no network, no database.

Pictures are numpy arrays, RGB, uint8, rows first (height, width, 3). "Upright" means the page as printed:
the 1A QR code sits in its bottom-right corner. A normalised page is A4 portrait at 200 dpi (A4_PX).

Thresholds are named constants below. Their values were calibrated on the synthetic scans and photos the
tests make from the 1A fixture copies (tests/synth.py) and are to be checked again on real files.
"""
from __future__ import annotations

import io
import math
from dataclasses import dataclass
from typing import Iterator

import cv2
import numpy as np
import pi_heif
import pypdfium2 as pdfium
import zxingcpp
from PIL import Image, ImageOps

from processor.codes import code_valid, parse_payload

pi_heif.register_heif_opener()  # decode only: pi-heif bundles libheif and libde265 (LGPL-3.0), no encoder

A4_PX = (1654, 2339)  # (width, height): A4 portrait, 595.28 x 841.89 pt, at 200 dpi
TOP_BAND_FRACTION = 34 / 841.89  # the 1A name band (TOP_BAND) as a share of the page height
WHITE = (255, 255, 255)

# Reading files.
MAX_RENDER_SIDE = 5000  # px; a PDF page larger than this at the asked dpi is rendered smaller
MAX_PHOTO_SIDE = 4000  # px; larger photos are scaled down when loaded (memory)
MAX_DECODE_PIXELS = 50_000_000  # larger pictures are refused before decoding (after a JPEG's reduced decode)

# Quality. Both measures are taken on a greyscale copy MEASURE_WIDTH px wide.
MEASURE_WIDTH = 1000
BLURRED_BELOW = 60.0  # variance of the Laplacian
DARK_BELOW = 90.0  # mean grey level, 0 to 255
EDGE_MARGIN = 0.01  # a found page this close to the photo's edge (share of width/height) is cut off

# Finding the page in a photo.
FIND_SIDE = 800  # px; the page is looked for on a copy whose longer side is this long
PAGE_MIN_AREA = 0.15  # the page covers at least this share of the photo
PAGE_FILL = 0.9  # the four-cornered shape covers at least this share of the bright shape's area
PAGE_ASPECT = (1.1, 2.0)  # long side / short side of the found page (A4 is 1.41)
CANNY = (15, 45)  # edge thresholds on the blurred copy: a white page on a near-white table still shows
EDGE_DILATE = 2  # px on the copy: edges are thickened this much to close gaps, then the outline moved back in
EDGE_STEP = 0.01  # share of the copy's longer side: how far inside and outside each side is sampled
EDGE_CONTRAST = 8  # grey levels the paper must be brighter than what lies outside, along every side

# Straightening by the code's corners.
REFINE_SCALE = 3.0  # the code is read again this much enlarged for finer corners
MAX_TILT = 10.0  # degrees; never straightened by more
MIN_TILT = 0.2  # degrees; smaller measured tilts are corner noise and are left alone

# Blank pages: ink is a pixel darker than its neighbourhood by INK_CONTRAST grey levels.
BLANK_MARGIN = 0.04  # share of each side ignored (scanner edge shadows)
INK_CONTRAST = 40
BLANK_INK_FRACTION = 0.0002  # a page with less ink than this share of its area is blank

# A picture whose height/width is within this share of A4's is resized to A4; others are letterboxed, so a
# page is never stretched more one way than the other by more than this (ruling R19).
A4_RATIO_TOLERANCE = 0.005

# The 1A print layout (supabase/functions/_shared/paper/stamp.ts: A4, TOP_BAND, SIDE, QR_SIZE, qrLayout),
# in points measured from the copy page's top-left.
PAGE_PT = (595.28, 841.89)
TOP_BAND_PT = 34.0
QR_PT = 52.0  # the symbol without its quiet zone
QR_RIGHT_PT = 18.0  # SIDE: from the page's right edge to the quiet zone
QR_BELOW_PT = 18.0  # CODE_TEXT_TOP: from the page's bottom edge to the quiet zone
QR_QUIET_MODULES = 4

# The two rules 1A draws across every copy page (stamp.ts drawLine, 0.5 pt, from SIDE to W - SIDE): one
# 4 pt above the name band's foot, one along the top of the bottom band (91.5 pt from the page's bottom).
RULE_X_PT = (18.0, PAGE_PT[0] - 18.0)
TOP_RULE_PT = TOP_BAND_PT - 4.0
BOTTOM_RULE_PT = PAGE_PT[1] - 91.5

# Checking where the copy was printed on the sheet (rulings R13, R18).
PRINT_SCALE_RANGE = (0.85, 1.05)  # printed size / actual size by the code; "fit to page" is about 0.94-0.97
MAX_CODE_OFFSET_MM = 15.0  # the code further than this from its printed place: the layout is unexpected
MAX_FIT_ERROR_MM = 1.5  # code corners and rule ends must all lie this close to the fitted perspective
PREDICTED_MARGIN_PT = 3.0  # band and areas placed through the fit are painted this much larger all round
BELOW_TOP_RULE_PT = 3.0  # everything above the measured top rule, and this much below it, is painted

# Finding the rules on a normalised page.
RULE_SEARCH_MM = (25.0, 12.0)  # top rule, bottom rule: searched this far above and below where the code says
RULE_SAMPLES = 160  # columns sampled along a rule's printed length
RULE_SIDE_PX = (2, 5)  # a rule is a thin line: somewhere this many px above it, and below it, is lighter
RULE_DEPTH = 0.15  # a rule is darker than the paper either side by this share of the paper's brightness
RULE_ON_PAPER = 0.6  # ... and lies on paper at least this share as bright as the page's paper
RULE_TOLERANCE_PX = 2.0  # a column's dark line within this of the fitted line counts
RULE_COVERAGE = 0.9  # a rule must be found along this share of its printed length (R18)
RULE_SLOPES = 0.06  # rules are looked for at slopes up to this (about 3.4 degrees)
RULE_GAP_PX = 6  # walking along a rule to its ends, gaps up to this are bridged
RULE_CLEAR_PT = (2.0, 12.0)  # beyond each end of a rule, this stretch of its line is bare paper (1A's margin)
RULE_CLEAR_SHARE = 0.8  # ... at least this share of it
# The identity line (name and index at the left end, exam and date at the right) prints 2 to 13 pt above
# the top rule: a line with no such ink above both its ends is not the top rule (a page edge, say).
RULE_TEXT_PT = (3.0, 14.0, 80.0)  # from, to above the rule; how far in from each end
RULE_TEXT_INK = 0.02  # share of each box that must be ink (darker than RULE_ON_PAPER of the paper)


class UnreadableFile(Exception):
    """The upload cannot be opened: a broken or password-protected PDF, or not a picture.

    The message is fixed text: it never carries file contents, names or library messages."""


@dataclass(frozen=True)
class Area:
    """A hidden area on copy page `page`: x, y, w, h are fractions (0 to 1) of the A4 copy page, from its top-left."""

    page: int
    x: float
    y: float
    w: float
    h: float


@dataclass(frozen=True, eq=False)
class CodeRead:
    """A 1A code read from a picture. `corners` (4 x 2, float32, x then y, in the picture's pixels) are the
    symbol's own top-left, top-right, bottom-right and bottom-left corners, wherever they lie in the picture.
    `modules` is the symbol's width in modules (21 for version 1), which sets the printed quiet zone."""

    code: str
    page: int
    corners: np.ndarray
    modules: int = 21


@dataclass(frozen=True, eq=False)
class PrintFit:
    """Where a copy page lies in a picture, judged by its code. `matrix` (2 x 3) maps copy-page points (pt,
    from the page's top-left) into the picture's pixels. On a normalised page, `scale` is the printed size
    over the actual size (1 = printed at 100%) and `offset_mm` how far the code sits from its printed place."""

    matrix: np.ndarray
    scale: float
    offset_mm: float

    @property
    def expected(self) -> bool:
        return PRINT_SCALE_RANGE[0] <= self.scale <= PRINT_SCALE_RANGE[1] and self.offset_mm <= MAX_CODE_OFFSET_MM


@dataclass(frozen=True, eq=False)
class PageFit:
    """Where the copy page lies on a normalised page picture, from its code and its two printed rules
    (ruling R18). `homography` (3 x 3) maps copy-page points (pt, from the top-left) to the picture's pixels,
    fitted to the code's corners and both rules' ends; `top_rule` is the measured top rule, y = a * x + b in
    the picture's pixels; `coverage` the share of each rule's printed length it was found along (top,
    bottom); `error_mm` the largest distance of a fitted point from where it was measured. `scale` and
    `offset_mm` are the code's own (PrintFit)."""

    homography: np.ndarray | None
    top_rule: tuple[float, float] | None
    coverage: tuple[float, float]
    error_mm: float
    scale: float
    offset_mm: float

    @property
    def expected(self) -> bool:
        return (
            self.homography is not None
            and self.top_rule is not None
            and min(self.coverage) >= RULE_COVERAGE
            and self.error_mm <= MAX_FIT_ERROR_MM
            and PRINT_SCALE_RANGE[0] <= self.scale <= PRINT_SCALE_RANGE[1]
            and self.offset_mm <= MAX_CODE_OFFSET_MM
        )


@dataclass(frozen=True)
class Quality:
    sharpness: float
    brightness: float
    cut_off: bool
    flags: list[str]


def _grey(img: np.ndarray) -> np.ndarray:
    return img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)


def _measure_copy(img: np.ndarray) -> np.ndarray:
    grey = _grey(img)
    h, w = grey.shape
    return cv2.resize(grey, (MEASURE_WIDTH, max(1, round(h * MEASURE_WIDTH / w))), interpolation=cv2.INTER_AREA)


# Reading files -------------------------------------------------------------------------------------------


def render_pdf(data: bytes, dpi: int = 200) -> Iterator[np.ndarray]:
    """The pages of a PDF as RGB pictures, one at a time. Opening happens now, so a broken or
    password-protected PDF raises UnreadableFile here; a page that fails later raises it when reached."""
    try:
        doc = pdfium.PdfDocument(data)
        count = len(doc)
    except Exception:
        raise UnreadableFile("The PDF could not be opened: it is broken or password protected.") from None
    if count == 0:
        doc.close()
        raise UnreadableFile("The PDF has no pages.")
    return _render_pages(doc, count, dpi)


def _render_pages(doc: pdfium.PdfDocument, count: int, dpi: int) -> Iterator[np.ndarray]:
    try:
        for i in range(count):
            try:
                page = doc[i]
                width, height = page.get_size()
                scale = min(dpi / 72, MAX_RENDER_SIDE / max(width, height, 1.0))
                bitmap = page.render(scale=scale, rev_byteorder=True)
                img = np.array(bitmap.to_numpy()[:, :, :3])
                bitmap.close()
                page.close()
            except Exception:
                raise UnreadableFile("A page of the PDF could not be read.") from None
            yield img
    finally:
        doc.close()


def load_photo(data: bytes) -> np.ndarray:
    """A JPEG, PNG, HEIC or HEIF photo as an RGB picture, turned as its EXIF orientation says, and scaled
    down to at most MAX_PHOTO_SIDE px on its longer side. A picture of more than MAX_DECODE_PIXELS (as
    its header says, after a JPEG's reduced decode) is refused before it is decoded."""
    try:
        with Image.open(io.BytesIO(data)) as im:
            im.draft("RGB", (MAX_PHOTO_SIDE, MAX_PHOTO_SIDE))  # JPEG: decode a huge photo at a smaller scale
            if im.size[0] * im.size[1] > MAX_DECODE_PIXELS:
                raise ValueError("too large")
            pic = ImageOps.exif_transpose(im).convert("RGB")
        if max(pic.size) > MAX_PHOTO_SIDE:
            pic.thumbnail((MAX_PHOTO_SIDE, MAX_PHOTO_SIDE), Image.Resampling.LANCZOS)
        return np.array(pic)
    except Exception:
        raise UnreadableFile("The picture could not be read.") from None


def encode_jpeg(img: np.ndarray, quality: int = 85) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(np.ascontiguousarray(img)).save(buf, "JPEG", quality=quality)
    return buf.getvalue()


# Finding the page in a photo -----------------------------------------------------------------------------


def find_page(img: np.ndarray) -> np.ndarray | None:
    """The corners (4 x 2, float32) of the largest paper-like quadrilateral in a photo. Candidates come from
    two masks: bright regions (Otsu; a page on a dark table) and closed edges (Canny; a page on a light
    table). A candidate counts only if every side is a real paper edge: brighter just inside than just
    outside (sides on the photo's border excepted). Ordered clockwise from the top-left as seen in the
    photo, starting on a short side, so warp_to_a4 gives a portrait page (upright or upside down; the code
    decides). None when there is no such shape."""
    h, w = img.shape[:2]
    f = FIND_SIDE / max(h, w)
    small = cv2.resize(_grey(img), (max(1, round(w * f)), max(1, round(h * f))), interpolation=cv2.INTER_AREA)
    small = cv2.GaussianBlur(small, (5, 5), 0)
    _, bright = cv2.threshold(small, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    bright = cv2.morphologyEx(bright, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    edges = cv2.dilate(cv2.Canny(small, *CANNY), np.ones((3, 3), np.uint8), iterations=EDGE_DILATE)
    best, best_area = None, 0.0
    for mask, inset in ((bright, 0.0), (edges, float(EDGE_DILATE))):
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for contour in sorted(contours, key=cv2.contourArea, reverse=True):
            if cv2.contourArea(contour) < PAGE_MIN_AREA * mask.size:
                break
            quad = _quadrilateral(contour)
            if quad is not None and inset:  # the outline of the thickened edges lies outside the paper's edge
                quad = _inset(quad, inset)
            if quad is not None and _paper_edges(small, quad):
                area = cv2.contourArea(quad)
                if area > best_area:
                    best, best_area = quad, area
                break
    return None if best is None else _portrait_order(best / f)


def _inset(quad: np.ndarray, d: float) -> np.ndarray:
    """The convex quadrilateral with every side moved `d` px inwards."""
    centre = quad.mean(axis=0)
    normals = []
    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        n = np.array([b[1] - a[1], a[0] - b[0]], np.float64)
        n /= max(float(np.linalg.norm(n)), 1e-6)
        normals.append(n if np.dot(n, centre - (a + b) / 2) > 0 else -n)
    out = quad.astype(np.float64).copy()
    for i in range(4):  # corner i joins side i - 1 and side i
        n1, n2 = normals[i - 1], normals[i]
        out[i] += d * (n1 + n2) / max(1.0 + float(np.dot(n1, n2)), 1e-6)
    return out.astype(np.float32)


def _paper_edges(grey: np.ndarray, quad: np.ndarray) -> bool:
    """True when along every side of `quad` the picture is brighter just inside than just outside, by at
    least EDGE_CONTRAST (median over the side). A side whose outside lies off the picture is not judged."""
    h, w = grey.shape
    step = EDGE_STEP * max(h, w)
    centre = quad.mean(axis=0)
    t = np.linspace(0.1, 0.9, 25)[:, None]
    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        along = b - a
        normal = np.array([along[1], -along[0]], np.float64) / max(float(np.linalg.norm(along)), 1e-6)
        if np.dot(normal, (a + b) / 2 - centre) < 0:
            normal = -normal
        points = a + along * t
        inside, outside = points - normal * step, points + normal * step
        keep = (outside[:, 0] >= 0) & (outside[:, 0] <= w - 1) & (outside[:, 1] >= 0) & (outside[:, 1] <= h - 1)
        if keep.sum() < 5:
            continue
        ix = np.clip(inside[keep, 0].round().astype(int), 0, w - 1)
        iy = np.clip(inside[keep, 1].round().astype(int), 0, h - 1)
        ins = grey[iy, ix]
        out = grey[outside[keep, 1].round().astype(int), outside[keep, 0].round().astype(int)]
        if float(np.median(ins.astype(np.int16) - out.astype(np.int16))) < EDGE_CONTRAST:
            return False
    return True


def _quadrilateral(contour: np.ndarray) -> np.ndarray | None:
    hull = cv2.convexHull(contour)
    perimeter = cv2.arcLength(hull, True)
    for eps in (0.01, 0.02, 0.03, 0.05, 0.08):
        approx = cv2.approxPolyDP(hull, eps * perimeter, True)
        if len(approx) == 4:
            break
    else:
        return None
    quad = approx.reshape(4, 2).astype(np.float32)
    if cv2.contourArea(quad) < PAGE_FILL * cv2.contourArea(hull):
        return None
    sides = [float(np.linalg.norm(quad[i] - quad[(i + 1) % 4])) for i in range(4)]
    a, b = sides[0] + sides[2], sides[1] + sides[3]
    if min(a, b) <= 0 or not PAGE_ASPECT[0] <= max(a, b) / min(a, b) <= PAGE_ASPECT[1]:
        return None
    return quad


def _portrait_order(quad: np.ndarray) -> np.ndarray:
    centre = quad.mean(axis=0)
    q = quad[np.argsort(np.arctan2(quad[:, 1] - centre[1], quad[:, 0] - centre[0]))]  # clockwise on screen
    q = np.roll(q, -int(np.argmin(q.sum(axis=1))), axis=0)  # start at the top-left
    across = np.linalg.norm(q[1] - q[0]) + np.linalg.norm(q[3] - q[2])
    down = np.linalg.norm(q[2] - q[1]) + np.linalg.norm(q[0] - q[3])
    if across > down:  # lying sideways: start one corner on, so the first side is a short one
        q = np.roll(q, -1, axis=0)
    return q.astype(np.float32)


def touches_edge(quad: np.ndarray, shape: tuple[int, ...]) -> bool:
    """True when a found page comes within EDGE_MARGIN of the photo's edge (part of it is probably outside)."""
    h, w = shape[:2]
    x, y = quad[:, 0], quad[:, 1]
    mx, my = EDGE_MARGIN * w, EDGE_MARGIN * h
    return bool((x < mx).any() or (x > w - 1 - mx).any() or (y < my).any() or (y > h - 1 - my).any())


def warp_to_a4(img: np.ndarray, quad: np.ndarray) -> np.ndarray:
    """The quadrilateral `quad` (corners in the order find_page gives) cut out and flattened to A4_PX."""
    w, h = A4_PX
    target = np.array([[0, 0], [w, 0], [w, h], [0, h]], np.float32)
    m = cv2.getPerspectiveTransform(quad.astype(np.float32), target)
    return cv2.warpPerspective(img, m, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=WHITE)


def to_a4(img: np.ndarray) -> np.ndarray:
    """The picture at A4_PX: resized when its shape is A4-like, else scaled to fit and centred on white."""
    w, h = A4_PX
    ih, iw = img.shape[:2]
    if (iw, ih) == (w, h):
        return img
    if abs((ih / iw) / (h / w) - 1) <= A4_RATIO_TOLERANCE:
        return cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA if iw > w else cv2.INTER_CUBIC)
    s = min(w / iw, h / ih)
    nw, nh = max(1, round(iw * s)), max(1, round(ih * s))
    out = np.full((h, w, 3), 255, np.uint8)
    x0, y0 = (w - nw) // 2, (h - nh) // 2
    out[y0:y0 + nh, x0:x0 + nw] = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_CUBIC)
    return out


# Reading the code and turning the page -------------------------------------------------------------------


def _codes(part: np.ndarray, x0: int, y0: int, scale: float) -> Iterator[tuple[str, int, str, np.ndarray, int]]:
    """Valid 1A codes in `part`, a piece of a picture cut at (x0, y0) and enlarged by `scale`, with the
    corners in the picture's pixels and the symbol's width in modules."""
    for found in zxingcpp.read_barcodes(np.ascontiguousarray(part), formats=zxingcpp.BarcodeFormat.QRCode):
        parsed = parse_payload(found.text)
        if parsed is None or not code_valid(parsed[0]):
            continue
        p = found.position
        corners = np.array([[pt.x, pt.y] for pt in (p.top_left, p.top_right, p.bottom_right, p.bottom_left)], np.float32)
        yield parsed[0], parsed[1], found.text, corners / scale + np.array([x0, y0], np.float32), _modules(found)


def _modules(found: zxingcpp.Barcode) -> int:
    try:
        return 17 + 4 * int(found.extra["Version"])
    except (AttributeError, KeyError, TypeError, ValueError):
        return 21


def read_code(img: np.ndarray) -> CodeRead | None:
    """The 1A code on a picture: tries the whole picture, then its bottom third, then its bottom-right
    quarter enlarged 2x. Only a valid `SX1.<code>.<page>` with a correct check character counts. The
    corners are then read again from the code's surroundings enlarged REFINE_SCALE times: zxing gives
    whole pixels, and the finer corners make straightening several times more exact."""
    grey = _grey(img)
    h, w = grey.shape
    tries = (
        lambda: (grey, 0, 0, 1.0),
        lambda: (grey[2 * h // 3:], 0, 2 * h // 3, 1.0),
        lambda: (_enlarge(grey[h // 2:, w // 2:], 2.0), w // 2, h // 2, 2.0),
    )
    for cut in tries:
        for code, page, text, corners, modules in _codes(*cut()):
            return CodeRead(code=code, page=page, corners=_refine(grey, text, corners), modules=modules)
    return None


def _enlarge(part: np.ndarray, scale: float) -> np.ndarray:
    return cv2.resize(part, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)


def _refine(grey: np.ndarray, text: str, corners: np.ndarray) -> np.ndarray:
    h, w = grey.shape
    lo, hi = corners.min(axis=0), corners.max(axis=0)
    pad = float((hi - lo).max()) * 0.5
    x0, y0 = max(0, int(lo[0] - pad)), max(0, int(lo[1] - pad))
    x1, y1 = min(w, int(hi[0] + pad) + 1), min(h, int(hi[1] + pad) + 1)
    for _, _, again, finer, _ in _codes(_enlarge(grey[y0:y1, x0:x1], REFINE_SCALE), x0, y0, REFINE_SCALE):
        if again == text:
            return finer
    return corners


def _direction(read: CodeRead) -> float:
    """Angle in degrees of the code's own left-to-right direction in the picture, clockwise positive,
    averaged over its four sides."""
    tl, tr, br, bl = read.corners.astype(np.float64)
    left, right = bl - tl, br - tr  # down the symbol; turned a quarter back they point across it
    v = (tr - tl) + (br - bl) + np.array([left[1], -left[0]]) + np.array([right[1], -right[0]])
    return math.degrees(math.atan2(v[1], v[0]))


def quarter_turn(dx: float, dy: float) -> int:
    """The clockwise quarter turn (0, 90, 180 or 270 degrees) that brings direction (dx, dy) nearest to
    pointing right."""
    return (-round(math.degrees(math.atan2(dy, dx)) / 90) * 90) % 360


def rotation(read: CodeRead) -> int:
    """The clockwise quarter turn (0, 90, 180 or 270 degrees) upright() gives this picture."""
    return (-round(_direction(read) / 90) * 90) % 360


def upright(img: np.ndarray, read: CodeRead) -> np.ndarray:
    """The picture turned by quarter turns so the code reads as printed (bottom right), then straightened by
    the tilt left in the code's corners, at most MAX_TILT degrees, about the picture's centre."""
    angle = _direction(read)
    k = round(angle / 90)
    out = np.rot90(img, k)  # k quarter turns anticlockwise undo a code turned k quarters clockwise
    tilt = max(-MAX_TILT, min(MAX_TILT, angle - 90 * k))
    if abs(tilt) >= MIN_TILT:
        h, w = out.shape[:2]
        m = cv2.getRotationMatrix2D((w / 2, h / 2), tilt, 1.0)  # positive turns anticlockwise
        return cv2.warpAffine(np.ascontiguousarray(out), m, (w, h), flags=cv2.INTER_LINEAR, borderValue=WHITE)
    return np.ascontiguousarray(out)


# Where the copy was printed, by its code -----------------------------------------------------------------


def printed_code_corners(modules: int = 21) -> np.ndarray:
    """The code's corners (top-left, top-right, bottom-right, bottom-left; 4 x 2) where 1A prints them on the
    copy page, in pt from the page's top-left (qrLayout: a 4-module quiet zone inside the bottom band)."""
    quiet = QR_PT / modules * QR_QUIET_MODULES
    x1 = PAGE_PT[0] - QR_RIGHT_PT - quiet
    y1 = PAGE_PT[1] - QR_BELOW_PT - quiet
    x0, y0 = x1 - QR_PT, y1 - QR_PT
    return np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], np.float64)


def page_transform(read: CodeRead) -> np.ndarray:
    """The similarity (scale, turn and shift; 2 x 3) that maps copy-page points (pt, from the top-left) into
    the picture, fitted by least squares to the code's four corners."""
    p = printed_code_corners(read.modules)
    q = read.corners.astype(np.float64)
    mp, mq = p.mean(axis=0), q.mean(axis=0)
    zp = (p[:, 0] - mp[0]) + 1j * (p[:, 1] - mp[1])
    zq = (q[:, 0] - mq[0]) + 1j * (q[:, 1] - mq[1])
    c = np.sum(np.conj(zp) * zq) / np.sum(np.abs(zp) ** 2)  # scale and turn as one complex number
    a, b = float(c.real), float(c.imag)
    return np.array([[a, -b, mq[0] - a * mp[0] + b * mp[1]], [b, a, mq[1] - b * mp[0] - a * mp[1]]])


def _map(matrix: np.ndarray, points: np.ndarray) -> np.ndarray:
    return points @ matrix[:, :2].T + matrix[:, 2]


def print_fit(read: CodeRead, shape: tuple[int, ...]) -> PrintFit:
    """How the copy page lies on a normalised page picture of this `shape` (A4 portrait, any size), judged
    by a code read on that picture."""
    m = page_transform(read)
    px_per_pt = shape[1] / PAGE_PT[0]
    printed = printed_code_corners(read.modules).mean(axis=0) * px_per_pt
    offset_pt = float(np.linalg.norm(read.corners.mean(axis=0) - printed)) / px_per_pt
    return PrintFit(matrix=m, scale=math.hypot(m[0, 0], m[1, 0]) / px_per_pt, offset_mm=offset_pt * 25.4 / 72)


def page_corners(read: CodeRead) -> np.ndarray:
    """Where the whole copy page lies in a picture, placed by its code alone (top-left, top-right,
    bottom-right, bottom-left as printed; float32), for warp_to_a4 when the page's edges cannot be found.
    A similarity cannot follow perspective, so far from the code this is approximate."""
    w, h = PAGE_PT
    return _map(page_transform(read), np.array([[0, 0], [w, 0], [w, h], [0, h]], np.float64)).astype(np.float32)


# Where the copy was printed, by its code and its two rules (ruling R18) ----------------------------------


@dataclass(frozen=True)
class _Rule:
    slope: float  # y = slope * x + intercept, in the picture's pixels
    intercept: float
    ends: np.ndarray  # left end, right end (2 x 2)
    coverage: float


def fit_page(page: np.ndarray, read: CodeRead) -> PageFit:
    """How the copy page lies on a normalised page picture: the code's own fit (PrintFit) gives a first
    guess, both printed rules are found near where it puts them, and a perspective (homography) is fitted
    to the code's four corners and the rules' four ends. `read` is the code as read on this picture."""
    first = print_fit(read, page.shape)
    grey = cv2.blur(_grey(page), (3, 1)).astype(np.float32)  # a 3 px wide average along each row
    paper = float(np.percentile(grey[::4, ::4], 95))
    px_per_mm = page.shape[1] / (PAGE_PT[0] / 72 * 25.4)
    top = _find_rule(grey, first, TOP_RULE_PT, RULE_SEARCH_MM[0] * px_per_mm, paper, topmost=True)
    bottom = _find_rule(grey, first, BOTTOM_RULE_PT, RULE_SEARCH_MM[1] * px_per_mm, paper, topmost=False)
    coverage = (top.coverage if top else 0.0, bottom.coverage if bottom else 0.0)
    top_line = (top.slope, top.intercept) if top else None
    if top is None or bottom is None:
        return PageFit(None, top_line, coverage, math.inf, first.scale, first.offset_mm)
    (x0, x1), (yt, yb) = RULE_X_PT, (TOP_RULE_PT, BOTTOM_RULE_PT)
    printed = np.vstack([printed_code_corners(read.modules), [[x0, yt], [x1, yt], [x0, yb], [x1, yb]]])
    found = np.vstack([read.corners.astype(np.float64), top.ends, bottom.ends])
    homography, _ = cv2.findHomography(printed, found, 0)
    if homography is None:
        return PageFit(None, top_line, coverage, math.inf, first.scale, first.offset_mm)
    placed = cv2.perspectiveTransform(printed[None], homography)[0]
    error_mm = float(np.linalg.norm(placed - found, axis=1).max()) / px_per_mm
    return PageFit(homography, top_line, coverage, error_mm, first.scale, first.offset_mm)


def _line_depth(grey: np.ndarray, xs: np.ndarray, ys: np.ndarray, paper: float) -> np.ndarray:
    """How strongly a thin dark line passes through each point (x, y): its darkness below the paper either
    side (the lighter of what lies RULE_SIDE_PX above, compared with the same below; the darker side counts),
    as a share of the paper's brightness; 0 where the point or its surroundings are off the picture or not
    on paper. A step from paper to a darker table is not a line: one side of it is dark."""
    h, w = grey.shape
    k0, k1 = RULE_SIDE_PX
    xi, yi = np.round(xs).astype(int), np.round(ys).astype(int)
    ok = (xi >= 0) & (xi < w) & (yi >= k1) & (yi < h - k1)
    xi, yi = np.clip(xi, 0, w - 1), np.clip(yi, k1, h - 1 - k1)
    above = np.max([grey[yi - k, xi] for k in range(k0, k1 + 1)], axis=0)
    below = np.max([grey[yi + k, xi] for k in range(k0, k1 + 1)], axis=0)
    around = np.minimum(above, below)
    depth = (around - grey[yi, xi]) / max(paper, 1.0)
    return np.where(ok & (around >= RULE_ON_PAPER * paper), depth, 0.0)


def _find_rule(grey: np.ndarray, first: PrintFit, y_pt: float, search: float, paper: float,
               topmost: bool) -> _Rule | None:
    """A printed rule near where `first` puts it: a straight thin dark line on paper, found along at least
    RULE_COVERAGE of the rule's printed length, with bare paper beyond both its ends. The top rule is the
    topmost such line with the identity line's ink above both its ends; the bottom rule the bottommost.
    Picking wrongly can only pick a lower top rule, which paints more of the page, never less."""
    h, w = grey.shape
    x0, x1 = RULE_X_PT
    inset = 0.05 * (x1 - x0)  # the measured span may differ a little from the code's guess (perspective)
    xs_pt = np.linspace(x0 + inset, x1 - inset, RULE_SAMPLES)
    guess = _map(first.matrix, np.column_stack([xs_pt, np.full(RULE_SAMPLES, y_pt)]))
    cols = np.round(guess[:, 0]).astype(int)
    inside = (cols >= 0) & (cols < w)
    if inside.sum() < RULE_SAMPLES // 2:
        return None
    cols, guess = cols[inside], guess[inside]
    centre_x = float(guess[:, 0].mean())
    lo = max(RULE_SIDE_PX[1], int(guess[:, 1].min() - search))
    hi = min(h - 1 - RULE_SIDE_PX[1], int(guess[:, 1].max() + search))
    if hi <= lo:
        return None
    rows = np.arange(lo, hi + 1)
    rr, cc = np.meshgrid(rows, cols, indexing="ij")
    depth = _line_depth(grey, cc.astype(float), rr.astype(float), paper)
    peak = (depth >= RULE_DEPTH) & (depth >= np.roll(depth, 1, axis=0)) & (depth >= np.roll(depth, -1, axis=0))
    ri, ci = np.nonzero(peak)
    if len(ri) == 0:
        return None
    py, px = rows[ri].astype(float), cols[ci].astype(float)

    # Vote for straight lines: for each slope, which columns have a dark line within tolerance of each height.
    n, best_cov, best_slope = len(cols), None, None
    for slope in np.arange(-RULE_SLOPES, RULE_SLOPES + 1e-9, 0.002):
        at_centre = py - slope * (px - centre_x)
        hits = np.zeros((n, hi - lo + 1), bool)
        for d in range(-int(RULE_TOLERANCE_PX), int(RULE_TOLERANCE_PX) + 1):
            b = np.clip(np.round(at_centre).astype(int) - lo + d, 0, hi - lo)
            hits[ci, b] = True
        cov = hits.mean(axis=0)
        if best_cov is None:
            best_cov, best_slope = cov, np.full_like(cov, slope)
        else:
            better = cov > best_cov
            best_cov, best_slope = np.where(better, cov, best_cov), np.where(better, slope, best_slope)

    # Candidate lines, one per run of qualifying heights, from the preferred side.
    good = np.nonzero(best_cov >= RULE_COVERAGE)[0]
    runs = np.split(good, np.nonzero(np.diff(good) > 1)[0] + 1) if len(good) else []
    for run in (runs if topmost else runs[::-1]):
        tops = run[best_cov[run] == best_cov[run].max()]
        b = tops[len(tops) // 2]  # the middle of the best heights
        rule = _measure_rule(grey, px, py, centre_x, lo + b, best_slope[b], cols, first, paper, topmost)
        if rule is not None:
            return rule
    return None


def _measure_rule(grey: np.ndarray, px: np.ndarray, py: np.ndarray, centre_x: float, y_centre: float,
                  slope: float, cols: np.ndarray, first: PrintFit, paper: float, identity_above: bool) -> _Rule | None:
    """Refines a voted line by least squares on its dark points (one per column, the nearest), walks along
    it to the rule's ends, checks the paper is bare just beyond both ends (the rule's 18 pt margins) and,
    for the top rule, that the identity line's ink lies just above both ends."""
    dist = np.abs(py - (y_centre + slope * (px - centre_x)))
    order = np.lexsort((dist, px))
    sx, sy, sd = px[order], py[order], dist[order]
    firsts = np.r_[0, np.nonzero(np.diff(sx))[0] + 1]
    pick = firsts[sd[firsts] <= RULE_TOLERANCE_PX + 3]
    xs_fit, ys_fit = sx[pick], sy[pick]
    for _ in range(2):  # fit, drop the points off the line, fit again
        if len(xs_fit) < 2:
            return None
        a, b = np.polyfit(xs_fit, ys_fit, 1)
        keep = np.abs(ys_fit - (a * xs_fit + b)) <= RULE_TOLERANCE_PX
        xs_fit, ys_fit = xs_fit[keep], ys_fit[keep]
    if len(xs_fit) < 2:
        return None
    a, b = np.polyfit(xs_fit, ys_fit, 1)
    coverage = len(xs_fit) / len(cols)
    h, w = grey.shape
    line_y = lambda x: a * x + b  # noqa: E731
    xs = np.arange(0, w, dtype=float)
    on = np.zeros(w, bool)
    for dy in (-1, 0, 1):
        on |= _line_depth(grey, xs, line_y(xs) + dy, paper) >= RULE_DEPTH
    # The rule is the run of line pixels (gaps up to RULE_GAP_PX bridged) that passes the middle.
    idx = np.nonzero(on)[0]
    if len(idx) == 0:
        return None
    breaks = np.nonzero(np.diff(idx) > RULE_GAP_PX + 1)[0]
    starts, stops = np.r_[idx[0], idx[breaks + 1]], np.r_[idx[breaks], idx[-1]]
    mid = centre_x
    through = np.nonzero((starts - RULE_GAP_PX <= mid) & (mid <= stops + RULE_GAP_PX))[0]
    if len(through) == 0:
        return None
    left, right = int(starts[through[0]]), int(stops[through[0]])
    px_per_pt = first.scale * w / PAGE_PT[0]
    near_pt, far_pt = RULE_CLEAR_PT
    for start, sign in ((left, -1), (right, 1)):
        beyond = start + sign * np.arange(round(near_pt * px_per_pt), round(far_pt * px_per_pt) + 1)
        if beyond.min() < 0 or beyond.max() >= w:
            return None
        bare = ~on[beyond] & (_paper_at(grey, beyond.astype(float), line_y(beyond)) >= RULE_ON_PAPER * paper)
        if bare.mean() < RULE_CLEAR_SHARE:
            return None
    if identity_above:
        up0, up1, across = (round(v * px_per_pt) for v in RULE_TEXT_PT)
        for x_lo, x_hi in ((left, left + across), (right - across, right)):
            xs_box = np.arange(max(0, x_lo), min(w, x_hi + 1))
            ys_box = np.arange(up0, up1 + 1)
            bx, by = np.meshgrid(xs_box, ys_box)
            values = _paper_at(grey, bx.astype(float), line_y(bx) - by)
            if (values < RULE_ON_PAPER * paper).mean() < RULE_TEXT_INK:
                return None
    ends = np.array([[left, line_y(left)], [right, line_y(right)]], np.float64)
    return _Rule(slope=float(a), intercept=float(b), ends=ends, coverage=float(coverage))


def _paper_at(grey: np.ndarray, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    """Grey values at (x, y); NaN off the picture, so a point there is neither paper nor ink."""
    h, w = grey.shape
    xi, yi = np.round(xs).astype(int), np.round(ys).astype(int)
    off = (xi < 0) | (xi >= w) | (yi < 0) | (yi >= h)
    values = grey[np.clip(yi, 0, h - 1), np.clip(xi, 0, w - 1)].astype(np.float64)
    return np.where(off, np.nan, values)


# Checks --------------------------------------------------------------------------------------------------


def is_blank(img: np.ndarray) -> bool:
    """True for a page with (almost) no ink: a blank back or a separator sheet. Faint show-through from the
    other side and a scanner's edge shadow are not ink. A copy page is never blank (its bands and code)."""
    small = _measure_copy(img)
    h, w = small.shape
    my, mx = round(h * BLANK_MARGIN), round(w * BLANK_MARGIN)
    inner = cv2.medianBlur(np.ascontiguousarray(small[my:h - my, mx:w - mx]), 3)
    ink = cv2.adaptiveThreshold(inner, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV, 31, INK_CONTRAST)
    return np.count_nonzero(ink) < BLANK_INK_FRACTION * ink.size


def quality(img: np.ndarray, cut_off: bool = False) -> Quality:
    """Sharpness (variance of the Laplacian) and brightness (mean grey) of a page picture, measured on a
    greyscale copy MEASURE_WIDTH px wide, with the flags `blurred`, `dark` and `cut_off` (the caller knows
    whether the page was cut off: see touches_edge)."""
    small = _measure_copy(img)
    sharpness = float(cv2.Laplacian(small, cv2.CV_64F).var())
    brightness = float(small.mean())
    flags = []
    if sharpness < BLURRED_BELOW:
        flags.append("blurred")
    if brightness < DARK_BELOW:
        flags.append("dark")
    if cut_off:
        flags.append("cut_off")
    return Quality(sharpness=round(sharpness, 1), brightness=round(brightness, 1), cut_off=cut_off, flags=flags)


# The marking picture -------------------------------------------------------------------------------------


def marking_image(page: np.ndarray, areas: list[Area], fit: PageFit) -> np.ndarray:
    """A copy of a normalised page with the 1A name band and every given hidden area painted white, as the
    union of (ruling R18):
    (a) the band as the picture's top TOP_BAND_FRACTION and the areas as fractions of the picture;
    (b) everything above the measured top rule, and BELOW_TOP_RULE_PT below it, following the rule's line;
    (c) the band and the areas mapped through the fitted perspective, PREDICTED_MARGIN_PT larger all round.
    `fit` is fit_page's result for this picture; the caller makes a marking picture only when it is
    expected. Raises ValueError for a fit without a perspective or a top rule."""
    if fit.homography is None or fit.top_rule is None:
        raise ValueError("no page fit")
    out = page.copy()
    h, w = out.shape[:2]
    out[: math.ceil(TOP_BAND_FRACTION * h)] = 255
    for a in areas:
        x0, y0 = max(0, math.floor(a.x * w)), max(0, math.floor(a.y * h))
        x1, y1 = min(w, math.ceil((a.x + a.w) * w)), min(h, math.ceil((a.y + a.h) * h))
        if x1 > x0 and y1 > y0:
            out[y0:y1, x0:x1] = 255
    slope, intercept = fit.top_rule
    below = BELOW_TOP_RULE_PT * fit.scale * w / PAGE_PT[0]
    _fill(out, np.array([[0, 0], [w, 0], [w, slope * w + intercept + below], [0, intercept + below]]))
    pw, ph = PAGE_PT
    e = PREDICTED_MARGIN_PT
    boxes = [(0.0, 0.0, pw, TOP_BAND_PT)] + [(a.x * pw, a.y * ph, a.w * pw, a.h * ph) for a in areas]
    for x, y, bw, bh in boxes:
        corners = np.array([[x - e, y - e], [x + bw + e, y - e], [x + bw + e, y + bh + e], [x - e, y + bh + e]])
        _fill(out, cv2.perspectiveTransform(corners[None].astype(np.float64), fit.homography)[0])
    return out


def _fill(out: np.ndarray, polygon: np.ndarray) -> None:
    """Paints a convex polygon (picture pixels, any float) white, with 4 bits of sub-pixel precision."""
    cv2.fillConvexPoly(out, np.round(polygon * 16).astype(np.int32), WHITE, lineType=cv2.LINE_8, shift=4)
