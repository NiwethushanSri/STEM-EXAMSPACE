import { describe, expect, it } from "vitest";
import { attachStream, cycleFocus, guideRect } from "./CameraCapture";

/** A stand-in <video>: it has a picture (videoWidth) only while it shows a stream and plays. */
function fakeVideo() {
  const v = {
    srcObject: null as unknown,
    paused: true,
    plays: 0,
    get videoWidth() {
      return v.srcObject && !v.paused ? 1920 : 0;
    },
    play() {
      v.plays++;
      v.paused = false;
      return Promise.resolve();
    },
  };
  return v;
}
const stream = { id: "camera" } as unknown as MediaStream;

describe("attachStream", () => {
  it("a photo can be taken after a blurred-photo review: a video shown again gets the camera back", () => {
    const first = fakeVideo();
    attachStream(first, stream);
    expect(first.videoWidth).toBe(1920);
    // The review hides the video; a browser may pause it, or the element may be made again.
    first.paused = true;
    attachStream(first, stream);
    expect(first.videoWidth).toBe(1920);
    const remade = fakeVideo();
    attachStream(remade, stream);
    expect(remade.srcObject).toBe(stream);
    expect(remade.videoWidth).toBe(1920);
  });

  it("leaves a playing video alone, and does nothing without a stream or a video", () => {
    const v = fakeVideo();
    attachStream(v, stream);
    attachStream(v, stream);
    expect(v.plays).toBe(1);
    const none = fakeVideo();
    attachStream(none, null);
    expect(none.srcObject).toBeNull();
    expect(() => attachStream(null, stream)).not.toThrow();
  });
});

describe("cycleFocus (the camera dialog keeps the focus inside)", () => {
  const a = { id: "a" };
  const b = { id: "b" };
  const c = { id: "c" };
  it("Tab on the last control goes to the first, Shift+Tab on the first to the last", () => {
    expect(cycleFocus([a, b, c], c, false)).toBe(a);
    expect(cycleFocus([a, b, c], a, true)).toBe(c);
  });
  it("leaves Tab alone inside the dialog", () => {
    expect(cycleFocus([a, b, c], b, false)).toBeNull();
    expect(cycleFocus([a, b, c], b, true)).toBeNull();
  });
  it("brings the focus back in from outside (or from the dialog itself)", () => {
    expect(cycleFocus([a, b, c], { id: "outside" }, false)).toBe(a);
    expect(cycleFocus([a, b, c], null, true)).toBe(c);
    expect(cycleFocus([], a, false)).toBeNull();
  });
});

describe("guideRect", () => {
  it("is an A4 page as large as fits in 90% of the frame, centred", () => {
    const g = guideRect(1920, 1080);
    expect(g.h).toBeCloseTo(972);
    expect(g.w / g.h).toBeCloseTo(210 / 297);
    expect(g.x + g.w / 2).toBeCloseTo(960);
    const p = guideRect(1080, 1920);
    expect(p.w).toBeLessThanOrEqual(972 + 1e-9);
    expect(p.y + p.h / 2).toBeCloseTo(960);
  });
});
