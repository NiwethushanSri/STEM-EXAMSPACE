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
    """Every page of an upload. Scanner files and home PDFs: each PDF page or picture is one page. Home
    photos: the page is found in the photo and flattened first; a photo with no page found is kept, flagged
    `cut_off`. Raises UnreadableFile for a broken or password-protected PDF or an undecodable picture."""
    return list(iter_prepare(data, kind, mime, ctx))


def iter_prepare(data: bytes, kind: str, mime: str, ctx: JobContext) -> Iterator[PreparedPage]:
    """prepare(), one page at a time, so a long scanner file never holds all its pictures at once."""
    if kind not in KINDS:
        raise ValueError("unknown upload kind")
    pictures = imaging.render_pdf(data) if mime == "application/pdf" else iter((imaging.load_photo(data),))
    for index, img in enumerate(pictures):
        yield _prepare_page(index, img, kind == "home_photo", ctx)


def _prepare_page(index: int, img: np.ndarray, photo: bool, ctx: JobContext) -> PreparedPage:
    quad = imaging.find_page(img) if photo else None
    cut_off = photo and (quad is None or imaging.touches_edge(quad, img.shape))
    page = img if quad is None else imaging.warp_to_a4(img, quad)
    read = imaging.read_code(page)
    turn = 0
    if read is not None:
        turn = imaging.rotation(read)
        if quad is not None:
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
        page = imaging.upright(page, read)
    page = imaging.to_a4(page)

    blank = read is None and imaging.is_blank(page)
    q = imaging.quality(page, cut_off=cut_off)
    if blank:  # an empty page has no detail to judge sharpness by
        q = replace(q, flags=[f for f in q.flags if f != "blurred"])

    marking = None
    if read is not None and is_answer_page(ctx, read.code, read.page):
        layout = ctx.papers[ctx.copies[read.code].paper_id]
        areas = [a for a in layout.areas if a.page == read.page]
        marking = imaging.encode_jpeg(imaging.marking_image(page, areas))
    return PreparedPage(
        source_index=index,
        code=read.code if read else None,
        copy_page=read.page if read else None,
        blank=blank,
        quality=q,
        rotation=turn,
        full=imaging.encode_jpeg(page),
        marking=marking,
    )
