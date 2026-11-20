"""Prepares the pages of one upload: the orchestration of imaging.py, with the job's context.

Pure: no network, no database. Task 4 builds the JobContext from processing_job_claim's result, stores the
pictures and records the pages.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Iterator

import numpy as np

from processor import imaging
from processor.imaging import Area, Quality, UnreadableFile

__all__ = [
    "Area", "CopyRef", "JobContext", "PaperLayout", "PreparedPage", "Quality", "UnreadableFile",
    "is_answer_page", "iter_prepare", "prepare",
]

KINDS = ("home_photo", "home_pdf", "scan_file")
# Quality flag: the page's geometry is not confirmed, so no marking picture is made (rulings R13 to R19): a
# printed rule not found, the code and rules not agreeing with one perspective, the code off its printed
# place or size, or the page placed by its code alone.
LAYOUT_UNEXPECTED = "layout_unexpected"


@dataclass(frozen=True)
class CopyRef:
    """A candidate's 1A copy: page_count is the copy's pages (the paper's own pages plus spare pages)."""

    copy_id: str
    paper_id: str
    booking_id: str | None
    page_count: int


@dataclass(frozen=True)
class PaperLayout:
    """A paper version: its own page count, each page's role (answer, cover, blank, information) and its
    hidden areas."""

    page_count: int
    roles: dict[int, str]
    areas: list[Area]


@dataclass(frozen=True)
class JobContext:
    copies: dict[str, CopyRef]  # by copy code
    papers: dict[str, PaperLayout]  # by paper id


@dataclass(frozen=True)
class PreparedPage:
    """One page of an upload. source_index is its 0-based position in the upload; rotation the clockwise
    quarter turn (0, 90, 180, 270) that made it upright, measured on the file as uploaded; full and marking
    are JPEG pictures at A4_PX (marking: name band and hidden areas painted white)."""

    source_index: int
    code: str | None
    copy_page: int | None
    blank: bool
    quality: Quality
    rotation: int
    full: bytes
    marking: bytes | None


def is_answer_page(ctx: JobContext, code: str, page: int) -> bool:
    """True for a page of a known copy whose role is `answer`; copy pages after the paper's own pages are
    1A spare pages, always answer pages."""
    copy = ctx.copies.get(code)
    if copy is None or not 1 <= page <= copy.page_count:
        return False
    layout = ctx.papers.get(copy.paper_id)
    if layout is None:
        return False
    if page > layout.page_count:
        return True
    return layout.roles.get(page) == "answer"


def prepare(data: bytes, kind: str, mime: str, ctx: JobContext) -> list[PreparedPage]:
    """Every page of an upload. Raises UnreadableFile for a broken or password-protected PDF or an
    undecodable picture.

    Scanner files and home PDFs: each PDF page or picture is one page, turned upright by its code. A home
    PDF page is also looked at as a photo when the paper's edges can be found (a photo saved as a PDF).

    Home photos: the page's edges are found and the page flattened. When no edges are found the page is
    placed by its code: `cut_off` only if that placed page runs off the photo, and `layout_unexpected` (no
    marking picture) because the code alone cannot confirm where the name band lies. A photo with neither
    edges nor a code is kept as it is, `cut_off`.

    Every page with a code is then fitted to the 1A print layout by its code and its two printed rules
    (fit_page). A page whose fit is not confirmed gets the flag `layout_unexpected` and no marking picture."""
    return list(iter_prepare(data, kind, mime, ctx))


def iter_prepare(data: bytes, kind: str, mime: str, ctx: JobContext) -> Iterator[PreparedPage]:
    """prepare(), one page at a time, so a long scanner file never holds all its pictures at once."""
    if kind not in KINDS:
        raise ValueError("unknown upload kind")
    pictures = imaging.render_pdf(data) if mime == "application/pdf" else iter((imaging.load_photo(data),))
    for index, img in enumerate(pictures):
        yield _prepare_page(index, img, kind, ctx)


@dataclass(frozen=True)
class _Shot:
    """One way of making a normalised page from a picture. `read` is the code as first read (it names the
    page); `fit` is fit_page's result from the same code read again on the normalised page."""

    page: np.ndarray
    read: imaging.CodeRead | None
    fit: imaging.PageFit | None
    turn: int
    cut_off: bool
    placed_by_code: bool = False

    @property
    def layout_ok(self) -> bool:
        """The page's geometry is confirmed (ruling R18): both rules found, the code and the rules' ends
        agreeing with one perspective, and the code at about its printed size and place. A page placed by
        its code alone is never confirmed (ruling R15 follow-up)."""
        return not self.placed_by_code and self.fit is not None and self.fit.expected


def _finish(
    page: np.ndarray, read: imaging.CodeRead | None, turn: int, cut_off: bool, placed_by_code: bool = False
) -> _Shot:
    page = imaging.to_a4(page)
    fit = None
    if read is not None:
        again = imaging.read_code(page)
        if again is not None and (again.code, again.page) == (read.code, read.page):
            fit = imaging.fit_page(page, again)
    return _Shot(page=page, read=read, fit=fit, turn=turn, cut_off=cut_off, placed_by_code=placed_by_code)


def _as_scanned(img: np.ndarray) -> _Shot:
    read = imaging.read_code(img)
    if read is None:
        return _finish(img, None, 0, False)
    return _finish(imaging.upright(img, read), read, imaging.rotation(read), False)


def _as_photographed(img: np.ndarray, place_by_code: bool, quad: np.ndarray | None = None) -> _Shot:
    if quad is None:
        quad = imaging.find_page(img)
    if quad is not None:
        cut_off = imaging.touches_edge(quad, img.shape)
        page = imaging.warp_to_a4(img, quad)
        read = imaging.read_code(page)
        if read is None:
            return _finish(page, None, 0, cut_off)
        turn = imaging.rotation(read)
        # The page's own corners, top-left first: its top side gives the turn as photographed, and
        # flattening the photo again in this order gives an upright page with one resampling.
        quad = np.roll(quad, turn // 90, axis=0)
        if turn:
            flat = imaging.warp_to_a4(img, quad)
            again = imaging.read_code(flat)
            if again is not None and imaging.rotation(again) == 0:
                page, read = flat, again
        top = quad[1] - quad[0]
        turn = imaging.quarter_turn(float(top[0]), float(top[1]))
        return _finish(imaging.upright(page, read), read, turn, cut_off)

    read = imaging.read_code(img)
    if read is None:
        return _finish(img, None, 0, True)
    if place_by_code:  # no edges found (a table as white as the paper): the code places the page (R15)
        quad = imaging.page_corners(read)
        top = quad[1] - quad[0]
        turn = imaging.quarter_turn(float(top[0]), float(top[1]))
        cut_off = imaging.touches_edge(quad, img.shape)  # only if the placed page runs off the photo
        return _finish(imaging.warp_to_a4(img, quad), read, turn, cut_off, placed_by_code=True)
    return _finish(imaging.upright(img, read), read, imaging.rotation(read), True)


def _home_pdf_page(img: np.ndarray) -> _Shot:
    """A home PDF page: as scanned, and also as a photo when the paper's edges can be found (rulings R14,
    R19). Paper edges inside the frame mean a photo saved as a PDF, so that candidate comes first; the first
    candidate whose layout is confirmed is kept, else the first candidate."""
    scanned = _as_scanned(img)
    quad = imaging.find_page(img)
    if quad is None:
        return scanned
    photographed = _as_photographed(img, place_by_code=False, quad=quad)
    inside = not imaging.touches_edge(quad, img.shape)
    shots = [photographed, scanned] if inside else [scanned, photographed]
    return next((s for s in shots if s.layout_ok), shots[0])


def _prepare_page(index: int, img: np.ndarray, kind: str, ctx: JobContext) -> PreparedPage:
    if kind == "home_photo":
        shot = _as_photographed(img, place_by_code=True)
    elif kind == "home_pdf":
        shot = _home_pdf_page(img)
    else:
        shot = _as_scanned(img)
    page, read = shot.page, shot.read

    blank = read is None and imaging.is_blank(page)
    q = imaging.quality(page, cut_off=shot.cut_off)
    flags = [f for f in q.flags if not (blank and f == "blurred")]  # an empty page has no detail to judge
    if read is not None and not shot.layout_ok:
        flags.append(LAYOUT_UNEXPECTED)
    q = replace(q, flags=flags)

    marking = None
    if read is not None and shot.layout_ok and is_answer_page(ctx, read.code, read.page):
        layout = ctx.papers[ctx.copies[read.code].paper_id]
        areas = [a for a in layout.areas if a.page == read.page]
        marking = imaging.encode_jpeg(imaging.marking_image(page, areas, shot.fit))
    return PreparedPage(
        source_index=index,
        code=read.code if read else None,
        copy_page=read.page if read else None,
        blank=blank,
        quality=q,
        rotation=shot.turn,
        full=imaging.encode_jpeg(page),
        marking=marking,
    )
