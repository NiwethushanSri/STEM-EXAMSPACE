"""remask(): a new marking picture made from a stored full picture only, with the page's turn, its paper version's
hidden areas and the staff hidden areas, on pages made from the 1A fixture copies by tests/synth.py. Every check is
on real pixels: the name and the hidden areas are white in the marking picture and still show in the full picture."""
import io
import math

import cv2
import numpy as np
import pytest
from PIL import Image

import synth
from processor import imaging, pipeline
from processor.imaging import A4_PX, TOP_BAND_FRACTION
from processor.pipeline import Area, CopyRef, JobContext, PaperLayout

W, H = A4_PX
A, B = synth.CODE_A, synth.CODE_B
PAPER = "paper-1"
PDF = "application/pdf"
BAND = math.ceil(TOP_BAND_FRACTION * H)

# Copy A page 2 with its identity line (the candidate's name) printed red and its question text printed blue.
TAGGED = synth.tagged(synth.render("copy-a.pdf", 1))
_qy, _qx = np.nonzero(synth.blue(TAGGED))
_MM = synth.DPI / 25.4
# The hidden area an admin draws round the question text on the 100% page, after the scripts came in.
QUESTION_AREA = Area(page=2, x=(_qx.min() - _MM) / W, y=(_qy.min() - _MM) / H,
                     w=(_qx.max() - _qx.min() + 2 * _MM) / W, h=(_qy.max() - _qy.min() + 2 * _MM) / H)


def ctx() -> JobContext:
    layout = PaperLayout(page_count=3, roles={1: "answer", 2: "answer", 3: "answer"}, areas=[])
    return JobContext(copies={A: CopyRef(copy_id="copy-a", paper_id=PAPER, booking_id="booking-a", page_count=5)},
                      papers={PAPER: layout})


def decode(data: bytes) -> np.ndarray:
    return np.asarray(Image.open(io.BytesIO(data)).convert("RGB"))


def white(img: np.ndarray) -> np.ndarray:
    return img.min(axis=2) > 225  # give or take JPEG


def staff_area_over(mask: np.ndarray, margin: int = 12) -> Area:
    """The rectangle staff draw over a mask's pixels on a picture, `margin` px larger all round, as fractions of it."""
    ys, xs = np.nonzero(mask)
    h, w = mask.shape
    x0, y0 = max(0, xs.min() - margin), max(0, ys.min() - margin)
    x1, y1 = min(w, xs.max() + 1 + margin), min(h, ys.max() + 1 + margin)
    return Area(page=0, x=x0 / w, y=y0 / h, w=(x1 - x0) / w, h=(y1 - y0) / h)


def prepared(sheet: np.ndarray, seed: int) -> pipeline.PreparedPage:
    [p] = pipeline.prepare(synth.scan_pdf([synth.scan(sheet, seed=seed)]), "scan_file", PDF, ctx())
    assert (p.code, p.copy_page) == (A, 2)
    return p


@pytest.fixture(scope="module")
def stored() -> bytes:
    """Copy A page 2, scanned and prepared before the question's hidden area was drawn: its stored full picture."""
    p = prepared(TAGGED, 31)
    assert p.marking is not None and p.quality.flags == []
    return p.full


@pytest.fixture(scope="module")
def unproved() -> pipeline.PreparedPage:
    """Copy A page 2 printed at 80%: the code is read, but the page's geometry is not proved (layout unexpected), and
    the name lies below the nominal band, so the band alone would not hide it."""
    p = prepared(synth.printed(TAGGED, scale=0.8), 32)
    assert p.marking is None and p.quality.flags == [pipeline.LAYOUT_UNEXPECTED]
    name = synth.red(decode(p.full))
    assert name[BAND:].sum() > 1000
    return p


def test_remask_applies_rotation_and_areas(stored):
    before = bytes(stored)
    marking = pipeline.remask(stored, 0, [QUESTION_AREA], code=A, copy_page=2)
    assert marking is not None
    full, m = decode(stored), decode(marking)
    name, question = synth.red(full), synth.blue(full)
    assert name.sum() > 1000 and question.sum() > 1000
    assert not (name & ~white(m)).any(), f"{int((name & ~white(m)).sum())} name pixels show"
    assert not (question & ~white(m)).any(), f"{int((question & ~white(m)).sum())} hidden-area pixels show"
    assert m[:BAND].min() > 225  # the nominal band
    assert m[-300:].min() < 100  # the code band stays: the page is still there to mark
    # The full picture is untouched: the name and the question still show in it.
    assert stored == before and full[name].min() < 100 and full[question].min() < 100

    # The same page stored upside down: turned first, then proved and painted.
    upside = synth.jpeg(np.ascontiguousarray(np.rot90(full, 2)), quality=95)
    marking = pipeline.remask(upside, 180, [QUESTION_AREA], code=A, copy_page=2)
    assert marking is not None
    m = decode(marking)
    upright = np.ascontiguousarray(np.rot90(decode(upside), 2))
    name, question = synth.red(upright), synth.blue(upright)
    assert m.shape == (H, W, 3) and name.sum() > 1000 and question.sum() > 1000
    assert not (name & ~white(m)).any() and not (question & ~white(m)).any()
    assert m[:BAND].min() > 225 and m[-300:, -400:].min() < 100  # upright: the band on top, the code bottom right


def test_staff_area_only_confirmed_page_hides_the_name(unproved):
    """A page whose geometry is not proved, confirmed by staff after hiding the name: the nominal band, the paper's
    areas and the staff area."""
    full = decode(unproved.full)
    name = synth.red(full)
    area = staff_area_over(name)
    marking = pipeline.remask(unproved.full, 0, [QUESTION_AREA], staff_areas=[area], code=A, copy_page=2, provable=False,
                              confirmed=True)
    assert marking is not None
    m = decode(marking)
    assert not (name & ~white(m)).any(), f"{int((name & ~white(m)).sum())} name pixels show"
    assert m[:BAND].min() > 225  # the nominal band
    box = (slice(math.ceil(QUESTION_AREA.y * H), math.floor((QUESTION_AREA.y + QUESTION_AREA.h) * H)),
           slice(math.ceil(QUESTION_AREA.x * W), math.floor((QUESTION_AREA.x + QUESTION_AREA.w) * W)))
    assert m[box].min() > 225  # the paper's area, as a fraction of the picture
    assert full[name].min() < 100  # staff still see the name in the full picture


def test_a_page_whose_fit_fails_gets_no_marking_picture_without_confirmation(unproved, stored):
    area = staff_area_over(synth.red(decode(unproved.full)))
    # Proving is tried (the prepare's checks) and fails: not confirmed, so no marking picture, staff area or not.
    assert pipeline.remask(unproved.full, 0, [QUESTION_AREA], code=A, copy_page=2) is None
    assert pipeline.remask(unproved.full, 0, [QUESTION_AREA], staff_areas=[area], code=A, copy_page=2) is None
    # A page flagged layout_unexpected when it was prepared is never proved again.
    assert pipeline.remask(stored, 0, [QUESTION_AREA], code=A, copy_page=2, provable=False) is None
    # The code must read as the page's own code and copy page.
    assert pipeline.remask(stored, 0, [QUESTION_AREA], code=B, copy_page=2) is None
    assert pipeline.remask(stored, 0, [QUESTION_AREA], code=A, copy_page=3) is None
    # A page with no code is never proved.
    assert pipeline.remask(stored, 0, [QUESTION_AREA]) is None


def test_a_turned_confirmed_page_hides_the_staff_area_drawn_on_the_stored_picture(stored):
    """Staff draw areas on the full picture as it is stored; turning the page later keeps them over the name."""
    full = decode(stored)
    area = staff_area_over(synth.red(full))
    marking = pipeline.remask(stored, 90, [], staff_areas=[area], confirmed=True)
    assert marking is not None
    m = decode(marking)
    turned = imaging.to_a4(np.ascontiguousarray(np.rot90(full, -1)))  # the stored picture turned a quarter clockwise
    name = synth.red(turned)
    assert m.shape == (H, W, 3) and name.sum() > 300
    assert not (name & ~white(m)).any(), f"{int((name & ~white(m)).sum())} name pixels show"
    assert not white(m)[synth.blue(turned)].all()  # the rest of the page still shows


def test_no_name_confirmed_page_still_gets_the_band(unproved):
    """'There is no name on this page': confirmed without any area, the nominal band is still painted."""
    m = decode(pipeline.remask(unproved.full, 0, [], code=A, copy_page=2, provable=False, confirmed=True))
    assert m[:BAND].min() > 225
    assert not white(m)[BAND:].all()


def test_remask_refuses_a_turn_that_is_not_a_quarter(stored):
    with pytest.raises(ValueError):
        pipeline.remask(stored, 45, [])


# Ruling R31 -----------------------------------------------------------------------------------------------------


def codeless_sheet() -> np.ndarray:
    """An extra sheet with no 1A code (a family's continuation page): the candidate's name in red near its top, below
    the nominal band, and a line of working in the middle."""
    sheet = np.full((H, W, 3), 255, np.uint8)
    cv2.putText(sheet, "Sam One  SE-2097-6601", (120, 260), cv2.FONT_HERSHEY_SIMPLEX, 2.0, (230, 0, 0), 5, cv2.LINE_AA)
    return synth.with_writing(sheet, "q4 continued: x = 7")


def test_a_codeless_staff_confirmed_page_gets_a_marking_picture_with_the_staff_area_white():
    [p] = pipeline.prepare(synth.scan_pdf([synth.scan(codeless_sheet(), seed=41)]), "scan_file", PDF, ctx())
    assert p.code is None and p.marking is None and not p.blank  # no code: no marking picture from the prepare
    full = decode(p.full)
    name = synth.red(full)
    assert name.sum() > 1000 and name[:BAND].sum() == 0  # the band alone would not hide it
    area = staff_area_over(name)

    # Not confirmed: nothing to prove it by, so no marking picture (staff area or not).
    assert pipeline.remask(p.full, 0, [], staff_areas=[area], provable=False) is None
    # Staff hid the name (and assigned or accepted the page): the nominal band, the paper's areas and the staff area.
    paper_area = Area(page=5, x=0.6, y=0.8, w=0.3, h=0.1)
    m = decode(pipeline.remask(p.full, 0, [paper_area], staff_areas=[area], provable=False, confirmed=True))
    assert not (name & ~white(m)).any(), f"{int((name & ~white(m)).sum())} name pixels show"
    assert m[:BAND].min() > 225
    assert m[math.ceil(0.8 * H):math.floor(0.9 * H), math.ceil(0.6 * W):math.floor(0.9 * W)].min() > 225
    assert not white(m)[H // 2 - 60:H // 2 + 20, W // 3:W // 3 + 400].all()  # the working still shows
    assert full[name].min() < 100  # and the full picture is untouched


def test_a_page_proved_before_that_cannot_be_proved_now_gets_no_marking_picture(stored):
    """The prepare proved this page (it had a marking picture). Turned a quarter by staff it can no longer be proved:
    the remask makes none (the database then takes the old one away and tells staff), until staff confirm it."""
    assert pipeline.remask(stored, 0, [QUESTION_AREA], code=A, copy_page=2) is not None
    assert pipeline.remask(stored, 90, [QUESTION_AREA], code=A, copy_page=2) is None
    full = decode(stored)
    area = staff_area_over(synth.red(full))
    m = decode(pipeline.remask(stored, 90, [QUESTION_AREA], staff_areas=[area], code=A, copy_page=2, confirmed=True))
    turned = imaging.to_a4(np.ascontiguousarray(np.rot90(full, -1)))
    assert not (synth.red(turned) & ~white(m)).any()
