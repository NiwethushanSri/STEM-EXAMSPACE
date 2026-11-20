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
    """The code's turn from upright in degrees, averaged over its four sides (as upright() measures it), so
    perspective left in a photo, which makes opposite sides converge, does not count as tilt."""
    tl, tr, br, bl = read.corners.astype(np.float64)
    left, right = bl - tl, br - tr
    v = (tr - tl) + (br - bl) + np.array([left[1], -left[0]]) + np.array([right[1], -right[0]])
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


# Copy page 2 with its identity line printed red and its question text printed blue (synth.tagged), and a
# hidden area drawn 1 mm round that question text, as an admin would draw it on the 100% page.
TAGGED = synth.tagged(synth.render("copy-a.pdf", 1))
_qy, _qx = np.nonzero(synth.blue(TAGGED))
_MM = synth.DPI / 25.4
QUESTION_AREA = Area(page=2, x=(_qx.min() - _MM) / W, y=(_qy.min() - _MM) / H,
                     w=(_qx.max() - _qx.min() + 2 * _MM) / W, h=(_qy.max() - _qy.min() + 2 * _MM) / H)


def tag_ctx(**kw) -> JobContext:
    return make_ctx(areas=[QUESTION_AREA], **kw)


def assert_hidden(p: pipeline.PreparedPage) -> None:
    """The page has a marking picture, and every pixel of the identity line (red) and of the hidden area's
    question text (blue) that the full picture shows is white in it."""
    assert p.marking is not None
    full, marking = decode(p.full), decode(p.marking)
    name, question = synth.red(full), synth.blue(full)
    assert name.sum() > 1000 and question.sum() > 1000  # both are printed and visible in the full picture
    white = marking.min(axis=2) > 225  # give or take JPEG
    assert not (name & ~white).any(), f"{int((name & ~white).sum())} name pixels show in the marking picture"
    assert not (question & ~white).any(), f"{int((question & ~white).sum())} hidden-area pixels show"


@pytest.mark.parametrize("turn,angle,seed", [(180, 7.0, 4), (90, -6.0, 5), (270, 9.0, 6), (0, -8.0, 8)])
def test_photo_rotated_skewed_dark_background_reads(turn, angle, seed, printed_centre):
    page = TAGGED
    img, corners = synth.photo(page, turn=turn, angle=angle, skew=0.06, seed=seed)

    found = imaging.find_page(img)
    assert found is not None and found.shape == (4, 2)
    for corner in corners:  # every corner of the page is found, within 1% of the photo's height
        assert np.linalg.norm(found - corner, axis=1).min() < 24

    [p] = pipeline.prepare(synth.jpeg(img), "home_photo", "image/jpeg", tag_ctx())

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
    assert decode(p.marking).shape == (H, W, 3)
    assert_hidden(p)


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


# Rulings R13 to R15: the name band located from the code, home PDFs of photos, light tables.


def name_pixels(sheet: np.ndarray) -> np.ndarray:
    """Where the candidate's name and index number print on a sheet: dark pixels in the top 300 rows."""
    mask = np.zeros(sheet.shape[:2], bool)
    mask[:300] = cv2.cvtColor(sheet, cv2.COLOR_RGB2GRAY)[:300] < 140
    return mask


def test_fit_to_page_95_percent_name_still_hidden():
    sheet = synth.printed(synth.render("copy-a.pdf", 1), scale=0.95)  # "fit to page", centred on A4
    name = name_pixels(sheet)
    band = math.ceil(imaging.TOP_BAND_FRACTION * H)
    assert name[band:].sum() > 1000  # the band as a fraction of the page alone would leave the name showing

    read = imaging.read_code(sheet)
    fit = imaging.fit_page(sheet, read)
    assert abs(fit.scale - 0.95) < 0.01 and fit.expected
    assert (imaging.marking_image(sheet, [], fit)[name] == 255).all()

    [p] = pipeline.prepare(synth.scan_pdf([synth.scan(sheet, seed=21)]), "scan_file", PDF, make_ctx())
    assert (p.code, p.copy_page, p.quality.flags) == (A, 2, [])
    assert p.marking is not None
    assert decode(p.marking)[name].min() > 225  # white, give or take JPEG
    assert decode(p.full)[name].min() < 100  # staff still see it

    [q] = pipeline.prepare(synth.scan_pdf([synth.scan(synth.printed(TAGGED, scale=0.95), seed=21)]), "scan_file",
                           PDF, tag_ctx())
    assert q.quality.flags == []
    assert_hidden(q)  # the hidden area moved with the print too


def test_far_off_layout_flags_and_no_marking():
    page = synth.render("copy-a.pdf", 1)
    for sheet, scale, offset in (
        (synth.printed(page, scale=0.8), 0.8, 30.0),  # shrunk well past "fit to page"
        (synth.printed(page, shift_mm=(-14.0, -12.0)), 1.0, 18.4),  # printed 18 mm off its place
    ):
        fit = imaging.print_fit(imaging.read_code(sheet), sheet.shape)
        assert abs(fit.scale - scale) < 0.01 and abs(fit.offset_mm - offset) < 1.5 and not fit.expected
        [p] = pipeline.prepare(synth.scan_pdf([synth.scan(sheet, seed=22)]), "scan_file", PDF, make_ctx())
        assert (p.code, p.copy_page) == (A, 2)
        assert p.quality.flags == [pipeline.LAYOUT_UNEXPECTED]
        assert p.marking is None
        assert decode(p.full).shape == (H, W, 3)


def test_home_pdf_of_uncropped_photo_is_found(printed_centre):
    page = TAGGED
    shot, _ = synth.photo(page, turn=180, angle=5.0, skew=0.05, seed=23)
    pdf = synth.scan_pdf([shot])  # a phone photo saved as a PDF, table and all

    [as_scan] = pipeline.prepare(pdf, "scan_file", PDF, tag_ctx())
    assert as_scan.code == A and pipeline.LAYOUT_UNEXPECTED in as_scan.quality.flags and as_scan.marking is None

    [p] = pipeline.prepare(pdf, "home_pdf", PDF, tag_ctx())
    assert (p.code, p.copy_page, p.rotation) == (A, 2, 180)
    assert p.quality.flags == []
    full = decode(p.full)
    again = imaging.read_code(full)
    assert np.allclose(again.corners.mean(axis=0), printed_centre, atol=24)
    assert likeness(full, page) > 0.65
    assert_hidden(p)


def test_photo_on_light_background_reads(printed_centre):
    page = TAGGED

    # A near-white table: the page's edges are faint, but found.
    light, corners = synth.photo(page, turn=90, angle=-7.0, skew=0.06, table_tone="light", seed=38)
    found = imaging.find_page(light)
    assert found is not None
    for corner in corners:
        assert np.linalg.norm(found - corner, axis=1).min() < 24
    [p] = pipeline.prepare(synth.jpeg(light), "home_photo", "image/jpeg", tag_ctx())
    assert (p.code, p.copy_page, p.rotation) == (A, 2, 270)
    assert p.quality.flags == []
    assert likeness(decode(p.full), page) > 0.65
    assert_hidden(p)

    # A table as white as the paper: no edges at all, so the page is placed by its code.
    white, _ = synth.photo(page, turn=180, angle=4.0, skew=0.03, table_tone="white", seed=39)
    assert imaging.find_page(white) is None
    [q] = pipeline.prepare(synth.jpeg(white), "home_photo", "image/jpeg", make_ctx())
    assert (q.code, q.copy_page, q.rotation) == (A, 2, 180)
    assert not q.quality.cut_off  # the placed page lies inside the photo
    assert q.quality.flags == [pipeline.LAYOUT_UNEXPECTED]  # where the name band lies is not confirmed
    assert q.marking is None
    full = decode(q.full)
    again = imaging.read_code(full)
    assert again is not None and abs(tilt_of(again)) < 1.0
    assert np.allclose(again.corners.mean(axis=0), printed_centre, atol=10)

    # The same, with the page running off the top of the photo.
    cut, _ = synth.photo(page, turn=180, angle=4.0, skew=0.03, table_tone="white", seed=39, crop_top=0.12)
    [r] = pipeline.prepare(synth.jpeg(cut), "home_photo", "image/jpeg", make_ctx())
    assert r.code == A and r.quality.cut_off and "cut_off" in r.quality.flags


# Fix round 1 (rulings R18, R19): the page fitted from its code and both printed rules, so a page that
# reaches the picture through perspective or uneven stretching still has its name and hidden areas painted.


@pytest.mark.parametrize("k", [0.03, 0.06])
def test_keystone_home_pdf_name_hidden(k):
    for tone in ("white", "dark"):  # a full-frame phone photo, top further away, saved straight into a PDF
        pdf = synth.scan_pdf([synth.keystone(TAGGED, k, tone=tone)])
        [p] = pipeline.prepare(pdf, "home_pdf", PDF, tag_ctx())
        assert (p.code, p.copy_page, p.quality.flags) == (A, 2, [])
        assert_hidden(p)
        [s] = pipeline.prepare(pdf, "scan_file", PDF, tag_ctx())  # the same picture without page finding
        assert s.code == A
        if s.marking is None:
            assert pipeline.LAYOUT_UNEXPECTED in s.quality.flags
        else:
            assert_hidden(s)  # the perspective fit follows the keystone


@pytest.mark.parametrize("mm", [5, 10, 15])
def test_photo_on_pile_name_hidden(mm):
    # The page lies on the pile: the sheet below shows `mm` above it, so the paper outline found is the
    # pile's, and flattening it stretches the page unevenly.
    for turn, angle, seed in ((0, 3.0, 40), (180, -4.0, 41)):
        img, _ = synth.photo(synth.on_pile(TAGGED, mm), turn=turn, angle=angle, skew=0.04, seed=seed)
        [p] = pipeline.prepare(synth.jpeg(img), "home_photo", "image/jpeg", tag_ctx())
        assert (p.code, p.copy_page) == (A, 2)
        if p.marking is None:
            assert pipeline.LAYOUT_UNEXPECTED in p.quality.flags
        else:
            assert_hidden(p)


def test_scan_with_lead_in_name_hidden():
    framed = synth.with_lead_in(TAGGED, 8.0)  # 8 mm of white above the page in the scanner's frame
    [p] = pipeline.prepare(synth.scan_pdf([synth.scan(framed, seed=1)]), "scan_file", PDF, tag_ctx())
    assert (p.code, p.copy_page, p.quality.flags) == (A, 2, [])
    assert_hidden(p)
    full = decode(p.full)  # letterboxed, never stretched one way more than the other
    assert full[:, :20].min() > 240 and full[:, -20:].min() > 240


def test_missing_top_rule_flags_layout():
    erased = TAGGED.copy()
    erased[78:90] = 255  # the top rule is not printed (or not visible)
    [p] = pipeline.prepare(synth.scan_pdf([synth.scan(erased, seed=22)]), "scan_file", PDF, tag_ctx())
    assert (p.code, p.copy_page) == (A, 2)
    assert p.quality.flags == [pipeline.LAYOUT_UNEXPECTED]
    assert p.marking is None
    read = imaging.read_code(decode(p.full))
    fit = imaging.fit_page(decode(p.full), read)
    assert fit.coverage[0] < imaging.RULE_COVERAGE and fit.coverage[1] >= imaging.RULE_COVERAGE


def test_shadow_above_page_not_taken_for_top_rule(monkeypatch):
    # A full-frame photo on a white table, saved as a scan: a lifted sheet casts a thin shadow line just
    # above its top edge, a straight dark line with bare paper-white beyond its ends, like a rule.
    pdf = synth.scan_pdf([synth.keystone(TAGGED, 0.03, shadow=True)])
    [p] = pipeline.prepare(pdf, "scan_file", PDF, tag_ctx())
    assert p.quality.flags == []
    assert_hidden(p)

    # Without the identity-line check the shadow is taken for the top rule; the perspective fit absorbs it
    # (within 1.5 mm) and the whole name shows. This is why the check exists.
    monkeypatch.setattr(imaging, "RULE_TEXT_INK", 0.0)
    [q] = pipeline.prepare(pdf, "scan_file", PDF, tag_ctx())
    full, marking = decode(q.full), decode(q.marking)
    assert q.quality.flags == [] and (synth.red(full) & (marking.min(axis=2) <= 225)).sum() > 1000
