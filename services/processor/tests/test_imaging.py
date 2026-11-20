"""Image operations, on scans and photos made from the 1A fixture copies by tests/synth.py."""
import io
import math

import cv2
import numpy as np
import pytest
import zxingcpp
from PIL import Image

import synth
from processor import imaging
from processor.imaging import A4_PX, Area, UnreadableFile

W, H = A4_PX


def tilt_of(read: imaging.CodeRead) -> float:
    """Direction of the code's top edge in degrees, clockwise positive (0 = printed upright)."""
    tl, tr, br, bl = read.corners
    v = (tr - tl) + (br - bl)
    return math.degrees(math.atan2(v[1], v[0]))


def centre(read: imaging.CodeRead) -> np.ndarray:
    return read.corners.mean(axis=0)


def likeness(a: np.ndarray, b: np.ndarray, width: int = 400) -> float:
    """Correlation of two pictures shrunk to `width` px wide (1 = the same page in the same place)."""

    def small(x):
        g = cv2.cvtColor(x, cv2.COLOR_RGB2GRAY)
        return cv2.resize(g, (width, round(width * H / W)), interpolation=cv2.INTER_AREA).astype(np.float32).ravel()

    return float(np.corrcoef(small(a), small(b))[0, 1])


@pytest.fixture(scope="module")
def printed_centre() -> np.ndarray:
    """Where the code sits on a clean A4 picture of a copy page."""
    read = imaging.read_code(synth.render("copy-a.pdf", 0))
    assert read is not None
    return centre(read)


def test_scan_page_reads_code_and_page(printed_centre):
    assert printed_centre[0] > 0.85 * W and printed_centre[1] > 0.9 * H  # bottom right, as printed
    for i in range(5):
        read = imaging.read_code(synth.scan(synth.render("copy-a.pdf", i), seed=i))
        assert read is not None
        assert (read.code, read.page) == (synth.CODE_A, i + 1)
        assert read.corners.shape == (4, 2)
        assert np.allclose(centre(read), printed_centre, atol=4)
    other = imaging.read_code(synth.scan(synth.render("copy-b.pdf", 2), seed=9))
    assert other is not None and (other.code, other.page) == (synth.CODE_B, 3)


def test_small_code_read_from_enlarged_corner():
    page = synth.render("copy-a.pdf", 1)
    low = cv2.resize(page, (298, 421), interpolation=cv2.INTER_AREA)  # a 36 dpi picture: modules about 1.2 px
    grey = cv2.cvtColor(low, cv2.COLOR_RGB2GRAY)
    assert not zxingcpp.read_barcodes(grey) and not zxingcpp.read_barcodes(np.ascontiguousarray(grey[280:]))
    read = imaging.read_code(low)
    assert read is not None and (read.code, read.page) == (synth.CODE_A, 2)
    c = centre(read)
    assert c[0] > 0.85 * low.shape[1] and c[1] > 0.9 * low.shape[0]


def test_scan_upside_down_turned_upright(printed_centre):
    page = synth.render("copy-a.pdf", 1)
    img = synth.scan(page, turn=180, seed=1)
    read = imaging.read_code(img)
    assert read is not None and read.page == 2
    assert imaging.rotation(read) == 180
    out = imaging.upright(img, read)
    assert out.shape == page.shape
    again = imaging.read_code(out)
    assert again is not None and abs(tilt_of(again)) < 0.5
    assert np.allclose(centre(again), printed_centre, atol=6)
    assert likeness(out, page) > 0.95


@pytest.mark.parametrize("turn", [90, 270])
def test_scan_sideways_turned_upright(turn, printed_centre):
    page = synth.render("copy-a.pdf", 2)
    img = synth.scan(page, turn=turn, seed=2)
    assert img.shape == (W, H, 3)
    read = imaging.read_code(img)
    assert read is not None and read.page == 3
    assert imaging.rotation(read) == 360 - turn
    out = imaging.upright(img, read)
    assert out.shape == (H, W, 3)
    again = imaging.read_code(out)
    assert again is not None and abs(tilt_of(again)) < 0.5
    assert np.allclose(centre(again), printed_centre, atol=6)
    assert likeness(out, page) > 0.95


@pytest.mark.parametrize("tilt", [3.0, -3.0])
def test_scan_tilted_3_degrees_straightened(tilt, printed_centre):
    page = synth.render("copy-a.pdf", 3)
    img = synth.scan(page, tilt=tilt, seed=3)
    read = imaging.read_code(img)
    assert read is not None and read.page == 4
    assert abs(tilt_of(read) - tilt) < 0.6
    assert imaging.rotation(read) == 0
    out = imaging.upright(img, read)
    assert out.shape == page.shape
    again = imaging.read_code(out)
    assert again is not None and abs(tilt_of(again)) < 0.5
    assert np.allclose(centre(again), printed_centre, atol=8)
    assert likeness(out, page) > 0.9


def test_tilt_correction_stops_at_10_degrees():
    page = synth.render("copy-a.pdf", 0)
    img = synth.scan(page, tilt=14.0, margin=0.1, seed=4)  # a scanner bed larger than the page
    read = imaging.read_code(img)
    assert read is not None
    again = imaging.read_code(imaging.upright(img, read))
    assert again is not None and abs(tilt_of(again) - 4.0) < 0.7


def test_blank_back_detected():
    for name, count in (("copy-a.pdf", 5), ("copy-landscape.pdf", 1)):
        for i in range(count):
            assert not imaging.is_blank(synth.scan(synth.render(name, i), seed=i)), (name, i)
    assert imaging.is_blank(synth.blank_back(seed=1))
    assert imaging.is_blank(synth.blank_back(synth.render("copy-a.pdf", 3), seed=2))  # front shows through
    assert not imaging.is_blank(synth.with_writing(synth.blank_back(seed=3)))  # one line of writing


def test_marking_image_blanks_top_band_and_areas():
    page = synth.render("copy-a.pdf", 1)
    band = math.ceil(imaging.TOP_BAND_FRACTION * H)
    assert band == 95
    assert page[:band].min() < 100  # the name and index number are printed there
    area = Area(page=2, x=0.12, y=0.14, w=0.33, h=0.07)
    x0, x1 = math.ceil(0.12 * W), math.floor(0.45 * W)
    y0, y1 = math.ceil(0.14 * H), math.floor(0.21 * H)
    assert page[y0:y1, x0:x1].min() < 100  # "Question page 2" is inside the area
    read = imaging.read_code(page)
    qx0, qy0 = np.floor(read.corners.min(axis=0)).astype(int) - 2
    qx1, qy1 = np.ceil(read.corners.max(axis=0)).astype(int) + 2
    fit = imaging.fit_page(page, read)
    assert fit.expected

    out = imaging.marking_image(page, [area], fit)

    assert out.shape == page.shape
    for x, y in ((5, 5), (W // 2, 40), (W - 5, band - 1), (x0 + 3, y0 + 3), ((x0 + x1) // 2, (y0 + y1) // 2), (x1 - 1, y1 - 1)):
        assert tuple(out[y, x]) == (255, 255, 255), (x, y)
    assert (out[:band] == 255).all()
    assert (out[y0:y1, x0:x1] == 255).all()
    assert np.array_equal(out[qy0:qy1, qx0:qx1], page[qy0:qy1, qx0:qx1])  # the code is untouched
    margin = math.ceil(imaging.PREDICTED_MARGIN_PT * W / imaging.PAGE_PT[0]) + 1  # placed through the fit, 3 pt larger
    assert imaging.PREDICTED_MARGIN_PT >= 3  # ruling R19
    assert np.array_equal(out[band + margin:y0 - margin], page[band + margin:y0 - margin])
    assert np.array_equal(out[y1 + margin:], page[y1 + margin:])
    assert page[:band].min() < 100  # the input is not changed
    with pytest.raises(ValueError):
        imaging.marking_image(page, [area], imaging.PageFit(None, None, None, (0.0, 0.0), math.inf, 1.0, 0.0))


def test_fit_page_finds_both_rules_on_a_clean_copy():
    px_per_pt = W / imaging.PAGE_PT[0]
    for i in range(5):
        page = synth.render("copy-a.pdf", i)
        fit = imaging.fit_page(page, imaging.read_code(page))
        assert fit.expected and min(fit.coverage) >= 0.98 and fit.error_mm < 0.3
        assert fit.top_offset_mm < 1.0 and fit.bottom_offset_mm < 1.0 and not fit.ambiguous and fit.identity
        assert fit.paint_rule == fit.top_rule  # no lower rule-like line near the top rule
        slope, intercept = fit.top_rule
        assert abs(slope) < 0.001 and abs(intercept - imaging.TOP_RULE_PT * px_per_pt) < 1.5  # 30 pt down
        placed = cv2.perspectiveTransform(np.array([[[18.0, 750.39], [577.28, 750.39]]]), fit.homography)[0]
        assert np.allclose(placed, np.array([[18.0, 750.39], [577.28, 750.39]]) * px_per_pt, atol=2)


def test_print_fit_on_a_copy_at_actual_size():
    for i in range(5):
        read = imaging.read_code(synth.render("copy-a.pdf", i))
        fit = imaging.print_fit(read, (H, W, 3))
        assert read.modules == 21
        assert abs(fit.scale - 1.0) < 0.01 and fit.offset_mm < 0.5 and fit.expected
    corners = imaging.printed_code_corners(21) * (W / imaging.PAGE_PT[0])
    assert np.allclose(corners, read.corners, atol=2)  # 1A's qrLayout, in this picture's pixels


def test_hidden_area_follows_scale():
    page = synth.render("copy-a.pdf", 1)
    region = (slice(int(0.1 * H), int(0.3 * H)), slice(int(0.05 * W), int(0.6 * W)))
    ys, xs = np.nonzero(cv2.cvtColor(page, cv2.COLOR_RGB2GRAY)[region] < 140)  # "Question page 2"
    y0, y1 = (ys.min() + region[0].start - 2) / H, (ys.max() + region[0].start + 3) / H
    x0, x1 = (xs.min() + region[1].start - 2) / W, (xs.max() + region[1].start + 3) / W
    area = Area(page=2, x=x0, y=y0, w=x1 - x0, h=y1 - y0)  # drawn tightly round the text at 100%

    sheet = synth.printed(page, scale=0.93)  # printed "fit to page" at 93%: the text moves down and right
    read = imaging.read_code(sheet)
    fit = imaging.print_fit(read, sheet.shape)
    assert abs(fit.scale - 0.93) < 0.01 and fit.expected
    grey = cv2.cvtColor(sheet, cv2.COLOR_RGB2GRAY)
    text = np.zeros_like(grey, bool)
    text[region] = grey[region] < 140
    outside = text.copy()
    outside[math.floor(y0 * H):math.ceil(y1 * H), math.floor(x0 * W):math.ceil(x1 * W)] = False
    assert outside.sum() > 500  # the area as a fraction of the picture alone would miss much of the text

    out = imaging.marking_image(sheet, [area], imaging.fit_page(sheet, read))

    assert (out[text] == 255).all()
    assert np.array_equal(out[-300:], sheet[-300:])  # the code band is untouched


def test_password_pdf_raises_unreadable():
    locked = synth.encrypted_pdf("secret")
    with pytest.raises(UnreadableFile) as caught:
        imaging.render_pdf(locked)
    assert "secret" not in str(caught.value) and "PDFium" not in str(caught.value)
    assert caught.value.__cause__ is None and caught.value.__suppress_context__
    with pytest.raises(UnreadableFile):
        list(imaging.render_pdf(b"%PDF-1.7\nthis is not really a pdf"))
    with pytest.raises(UnreadableFile) as bad_photo:
        imaging.load_photo(b"\xff\xd8\xff\xe0 this is not really a photo")
    assert "really" not in str(bad_photo.value)


def test_render_pdf_gives_a4_rgb_pages():
    pages = list(imaging.render_pdf(synth.fixture_bytes("copy-a.pdf")))
    assert len(pages) == 5
    for img in pages:
        assert img.shape == (H, W, 3) and img.dtype == np.uint8
    assert np.array_equal(pages[0], synth.render("copy-a.pdf", 0))


def test_photo_exif_orientation_applied():
    upright = np.full((120, 80, 3), 255, np.uint8)
    upright[:30, :20] = (220, 30, 30)  # red block at the top left
    stored = np.ascontiguousarray(np.rot90(upright, 1))  # the camera stored it turned anticlockwise
    img = imaging.load_photo(synth.jpeg(stored, orientation=6))
    assert img.shape == (120, 80, 3) and img.dtype == np.uint8
    assert img[10, 8, 0] > 180 and img[10, 8, 1] < 90
    assert img[-10, -8].min() > 230


def test_heic_photo_loads():
    # pi-heif only decodes, so the HEIC is a committed 583-byte fixture: 64 x 96, dark top half (see README).
    img = imaging.load_photo(synth.fixture_bytes("two-tone.heic"))
    assert img.shape == (96, 64, 3)
    assert img[10, 32].max() < 90 and img[80, 32].min() > 190
    with pytest.raises(KeyError):  # no HEIF encoder is installed (ruling R20)
        Image.fromarray(img).save(io.BytesIO(), format="HEIF")


def test_huge_picture_refused_before_decoding():
    big = synth.png_header_only(10_000, 6_000)  # says 60 megapixels; holds no picture data at all
    with pytest.raises(UnreadableFile):
        imaging.load_photo(big)
    assert imaging.MAX_DECODE_PIXELS < 10_000 * 6_000


def test_to_a4_never_stretches_unevenly():
    page = synth.render("copy-a.pdf", 0)
    taller = cv2.copyMakeBorder(page, 30, 0, 0, 0, cv2.BORDER_CONSTANT, value=(255, 255, 255))  # +1.3%
    out = imaging.to_a4(taller)
    assert out.shape == (H, W, 3)
    s = H / taller.shape[0]  # one scale both ways, centred on white
    margin = (W - round(W * s)) // 2
    assert margin > 5 and out[:, :margin - 1].min() == 255 and out[:, W - margin + 1:].min() == 255
    nearly = cv2.resize(page, (W + 4, H + 4))  # 0.07% off A4's shape: just resized
    assert imaging.to_a4(nearly).shape == (H, W, 3) and imaging.A4_RATIO_TOLERANCE <= 0.005


def test_encode_jpeg_round_trips():
    page = synth.render("copy-a.pdf", 0)
    data = imaging.encode_jpeg(page)
    assert data[:2] == b"\xff\xd8"
    back = imaging.load_photo(data)
    assert back.shape == page.shape
    assert likeness(back, page) > 0.98
