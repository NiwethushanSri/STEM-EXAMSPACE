"""prepare(): uploads in, page pictures out, on files made from the 1A fixture copies by tests/synth.py."""
import io
import math

import cv2
import numpy as np
import pytest
from PIL import Image

import synth
from processor import imaging, pipeline
from processor.imaging import A4_PX, UnreadableFile
from processor.pipeline import Area, CopyRef, JobContext, PaperLayout

W, H = A4_PX
A, B = synth.CODE_A, synth.CODE_B
PAPER = "paper-1"
PDF = "application/pdf"


def make_ctx(roles=None, areas=(), codes=(A, B), page_count=3, copy_pages=5) -> JobContext:
    if roles is None:
        roles = {p: "answer" for p in range(1, page_count + 1)}
    layout = PaperLayout(page_count=page_count, roles=roles, areas=list(areas))
    copies = {c: CopyRef(copy_id=f"copy-{c}", paper_id=PAPER, booking_id=f"booking-{c}", page_count=copy_pages) for c in codes}
    return JobContext(copies=copies, papers={PAPER: layout})


def decode(data: bytes) -> np.ndarray:
    return np.asarray(Image.open(io.BytesIO(data)).convert("RGB"))


def tilt_of(read) -> float:
    tl, tr, br, bl = read.corners
    v = (tr - tl) + (br - bl)
    return math.degrees(math.atan2(v[1], v[0]))


def likeness(a: np.ndarray, b: np.ndarray, width: int = 200) -> float:
    """Correlation of the printing on two pictures (dark detail against its surroundings, so uneven light
    does not count), shrunk to `width` px wide. Measured on these photos: the same page in the same place
    0.72 to 0.89, another copy page about 0.5, the same page upside down about 0."""

    def ink(x):
        g = cv2.cvtColor(x, cv2.COLOR_RGB2GRAY).astype(np.float32)
        detail = np.clip(cv2.GaussianBlur(g, (0, 0), 25) - g, 0, None)
        return cv2.resize(detail, (width, round(width * H / W)), interpolation=cv2.INTER_AREA).ravel()

    return float(np.corrcoef(ink(a), ink(b))[0, 1])


@pytest.fixture(scope="module")
def printed_centre() -> np.ndarray:
    read = imaging.read_code(synth.render("copy-a.pdf", 0))
    assert read is not None
    return read.corners.mean(axis=0)


@pytest.mark.parametrize("turn,angle,seed", [(180, 7.0, 4), (90, -6.0, 5), (270, 9.0, 6), (0, -8.0, 8)])
def test_photo_rotated_skewed_dark_background_reads(turn, angle, seed, printed_centre):
    page = synth.render("copy-a.pdf", 1)
    img, corners = synth.photo(page, turn=turn, angle=angle, skew=0.06, seed=seed)

    found = imaging.find_page(img)
    assert found is not None and found.shape == (4, 2)
    for corner in corners:  # every corner of the page is found, within 1% of the photo's height
        assert np.linalg.norm(found - corner, axis=1).min() < 24

    [p] = pipeline.prepare(synth.jpeg(img), "home_photo", "image/jpeg", make_ctx())

    assert (p.source_index, p.code, p.copy_page) == (0, A, 2)
    assert p.rotation == (360 - turn) % 360
    assert not p.blank
    assert p.quality.flags == [] and not p.quality.cut_off
    full = decode(p.full)
    assert full.shape == (H, W, 3)
    again = imaging.read_code(full)
    assert again is not None and abs(tilt_of(again)) < 1.0
    assert np.allclose(again.corners.mean(axis=0), printed_centre, atol=24)
    assert likeness(full, page) > 0.65
    assert p.marking is not None and decode(p.marking).shape == (H, W, 3)


def test_blurred_photo_flagged():
    page = synth.render("copy-a.pdf", 1)
    sharp, _ = synth.photo(page, angle=4.0, seed=11)
    soft, _ = synth.photo(page, angle=4.0, seed=11, blur=3.0)
    [p] = pipeline.prepare(synth.jpeg(sharp), "home_photo", "image/jpeg", make_ctx())
    [q] = pipeline.prepare(synth.jpeg(soft), "home_photo", "image/jpeg", make_ctx())
    assert "blurred" not in p.quality.flags
    assert "blurred" in q.quality.flags
    assert q.quality.sharpness < imaging.BLURRED_BELOW < p.quality.sharpness


def test_dark_photo_flagged():
    page = synth.render("copy-a.pdf", 1)
    dim, _ = synth.photo(page, angle=-3.0, seed=12, light=0.3)
    [p] = pipeline.prepare(synth.jpeg(dim), "home_photo", "image/jpeg", make_ctx())
    assert "dark" in p.quality.flags
    assert p.quality.brightness < imaging.DARK_BELOW
    assert p.code == A  # still read


def test_cut_off_photo_flagged():
    page = synth.render("copy-a.pdf", 1)
    cut, _ = synth.photo(page, angle=2.0, seed=13, crop_top=0.12)
    [p] = pipeline.prepare(synth.jpeg(cut), "home_photo", "image/jpeg", make_ctx())
    assert p.quality.cut_off and "cut_off" in p.quality.flags
    assert (p.code, p.copy_page) == (A, 2)
    assert decode(p.full).shape == (H, W, 3)

    empty = synth.table(1800, 2400, seed=14)  # no page in the photo at all: still kept
    [q] = pipeline.prepare(synth.jpeg(empty), "home_photo", "image/jpeg", make_ctx())
    assert q.quality.cut_off and "cut_off" in q.quality.flags
    assert q.code is None and q.marking is None
    assert decode(q.full).shape == (H, W, 3)


def test_cover_page_gets_no_marking_image():
    hidden = Area(page=2, x=0.12, y=0.14, w=0.33, h=0.07)  # over "Question page 2"
    ctx = make_ctx(roles={1: "cover", 2: "answer", 3: "information"}, areas=[hidden])
    pages = pipeline.prepare(synth.fixture_bytes("copy-a.pdf"), "scan_file", PDF, ctx)

    assert [p.source_index for p in pages] == [0, 1, 2, 3, 4]
    assert [(p.code, p.copy_page) for p in pages] == [(A, n) for n in range(1, 6)]
    assert [p.marking is not None for p in pages] == [False, True, False, True, True]
    for p in pages:
        assert not p.blank and p.rotation == 0 and p.quality.flags == []
        assert decode(p.full).shape == (H, W, 3)
    full, marking = decode(pages[1].full), decode(pages[1].marking)
    box = (slice(math.ceil(0.14 * H), math.floor(0.21 * H)), slice(math.ceil(0.12 * W), math.floor(0.45 * W)))
    assert full[box].min() < 100 and marking[box].min() > 240
    assert full[:90].min() < 100 and marking[:90].min() > 240
    assert full[-300:].min() < 100 and marking[-300:].min() < 100  # the code band stays


def test_spare_page_gets_marking_image():
    ctx = make_ctx(roles={1: "cover", 2: "information", 3: "blank"})
    pages = pipeline.prepare(synth.fixture_bytes("copy-a.pdf"), "scan_file", PDF, ctx)
    assert [p.copy_page for p in pages] == [1, 2, 3, 4, 5]
    assert [p.marking is not None for p in pages] == [False, False, False, True, True]
    assert decode(pages[3].marking)[:90].min() > 240


def test_unknown_code_gets_no_marking_image():
    only_b = make_ctx(codes=(B,))
    pages = pipeline.prepare(synth.jpeg(synth.scan(synth.render("copy-a.pdf", 1))), "scan_file", "image/jpeg", only_b)
    assert [(p.code, p.copy_page, p.marking) for p in pages] == [(A, 2, None)]
    known = pipeline.prepare(synth.jpeg(synth.scan(synth.render("copy-b.pdf", 1))), "scan_file", "image/jpeg", only_b)
    assert [(p.code, p.copy_page) for p in known] == [(B, 2)] and known[0].marking is not None


def test_landscape_master_page_reads():
    ctx = make_ctx(codes=(A,), page_count=1, copy_pages=1)
    [p] = pipeline.prepare(synth.fixture_bytes("copy-landscape.pdf"), "scan_file", PDF, ctx)
    assert (p.code, p.copy_page, p.rotation) == (A, 1, 0)
    assert p.marking is not None and decode(p.full).shape == (H, W, 3)

    page = synth.render("copy-landscape.pdf", 0)
    img, _ = synth.photo(page, turn=90, angle=4.0, seed=15)
    [q] = pipeline.prepare(synth.jpeg(img), "home_photo", "image/jpeg", ctx)
    assert (q.code, q.copy_page, q.rotation) == (A, 1, 270)
    full = decode(q.full)
    assert full.shape == (H, W, 3) and likeness(full, page) > 0.65


def test_duplex_batch_skips_blank_backs():
    one, two = synth.render("copy-a.pdf", 0), synth.render("copy-a.pdf", 1)
    batch = synth.scan_pdf([
        synth.scan(one, seed=1),
        synth.blank_back(one, seed=2),
        synth.scan(two, turn=180, seed=3),
        synth.blank_back(two, seed=4),
    ])
    pages = pipeline.prepare(batch, "scan_file", PDF, make_ctx())
    assert [p.blank for p in pages] == [False, True, False, True]
    assert [(p.code, p.copy_page) for p in pages] == [(A, 1), (None, None), (A, 2), (None, None)]
    assert [p.rotation for p in pages] == [0, 0, 180, 0]
    assert [p.marking is not None for p in pages] == [True, False, True, False]
    assert all(p.quality.flags == [] for p in pages)


def test_unreadable_files_raise():
    for data, kind, mime in (
        (synth.encrypted_pdf("secret"), "scan_file", PDF),
        (b"%PDF-1.7\nthis is not really a pdf", "home_pdf", PDF),
        (b"\xff\xd8\xff\xe0 this is not really a photo", "home_photo", "image/jpeg"),
    ):
        with pytest.raises(UnreadableFile) as caught:
            pipeline.prepare(data, kind, mime, make_ctx())
        assert "really" not in str(caught.value) and "secret" not in str(caught.value)
