import { describe, expect, it } from "vitest";
import { BLURRED_BELOW, MEASURE_WIDTH, blurScore, isBlurred, type GreyImage } from "./blur-check";

/** An RGBA picture filled from a grey value per pixel. */
function picture(width: number, height: number, grey: (x: number, y: number) => number): GreyImage {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const v = grey(x, y);
      data[i] = data[i + 1] = data[i + 2] = v;
      data[i + 3] = 255;
    }
  }
  return { width, height, data };
}

/** Part of a page at the measured width: white paper with dark pen strokes 2 px wide on writing lines. */
function page(width = MEASURE_WIDTH, height = 700): GreyImage {
  let seed = 7;
  const rand = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  const ink = new Uint8Array(width * height);
  for (let line = 20; line < height - 20; line += 28) {
    for (let x = 40; x < width - 40; ) {
      const len = 6 + Math.floor(rand() * 20);
      if (rand() < 0.7) {
        // a letter: a short stroke along the line and an upright one
        for (let dx = 0; dx < len; dx++) for (let dy = 0; dy < 2; dy++) ink[(line + 12 + dy) * width + x + dx] = 1;
        for (let dy = 0; dy < 14; dy++) for (let dx = 0; dx < 2; dx++) ink[(line + dy) * width + x + dx] = 1;
      }
      x += len + 4 + Math.floor(rand() * 8);
    }
  }
  return picture(width, height, (x, y) => (ink[y * width + x] ? 40 : 230));
}

/** The same picture smoothed by a box filter r px each way, done along rows then columns (a photo out of focus). */
function blurred(img: GreyImage, r: number): GreyImage {
  const { width: w, height: h, data } = img;
  const g = Float64Array.from({ length: w * h }, (_, i) => data[i * 4]);
  const pass = (src: Float64Array, horizontal: boolean) => {
    const out = new Float64Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let sum = 0;
        for (let d = -r; d <= r; d++) {
          const xx = horizontal ? Math.min(w - 1, Math.max(0, x + d)) : x;
          const yy = horizontal ? y : Math.min(h - 1, Math.max(0, y + d));
          sum += src[yy * w + xx];
        }
        out[y * w + x] = sum / (2 * r + 1);
      }
    }
    return out;
  };
  const b = pass(pass(g, true), false);
  return picture(w, h, (x, y) => Math.round(b[y * w + x]));
}

describe("blurScore", () => {
  it("blur_score_sharp_vs_blurred", () => {
    const sharp = page();
    const soft = blurred(sharp, 5);
    expect(blurScore(sharp)).toBeGreaterThan(BLURRED_BELOW);
    expect(isBlurred(blurScore(sharp))).toBe(false);
    expect(blurScore(soft)).toBeLessThan(BLURRED_BELOW);
    expect(isBlurred(blurScore(soft))).toBe(true);
    expect(blurScore(soft)).toBeLessThan(blurScore(sharp) / 10);
  });

  it("uses the server's measure and threshold (OpenCV Laplacian variance, mirrored edges)", () => {
    expect(BLURRED_BELOW).toBe(60);
    expect(MEASURE_WIDTH).toBe(1000);
    // Values from the processing server's OpenCV: cv2.Laplacian(img, cv2.CV_64F).var().
    expect(blurScore(picture(3, 3, (x, y) => (x === 1 && y === 1 ? 255 : 0)))).toBeCloseTo(218355.5555556, 4);
    const grid = [
      [121, 131, 193, 243, 8, 36, 210],
      [242, 63, 79, 222, 108, 69, 211],
      [65, 104, 164, 140, 21, 7, 221],
      [192, 214, 137, 209, 84, 115, 201],
      [31, 77, 31, 116, 250, 34, 98],
    ];
    expect(blurScore(picture(7, 5, (x, y) => grid[y][x]))).toBeCloseTo(102283.714286, 4);
    expect(blurScore(picture(20, 10, () => 128))).toBe(0);
  });

  it("turns colour into grey as OpenCV does", () => {
    // (10, 200, 30) is grey 124 in cv2.COLOR_RGB2GRAY: a lone pixel of it scores (124/255)^2 of a white one.
    const data = new Uint8ClampedArray(9 * 4);
    data.set([10, 200, 30, 255], 4 * 4);
    expect(blurScore({ width: 3, height: 3, data })).toBeCloseTo((2 * 496 * 496) / 9 - (496 / 9) ** 2, 4);
  });

  it("scores nothing for an empty picture", () => {
    expect(blurScore({ width: 0, height: 0, data: new Uint8ClampedArray(0) })).toBe(0);
  });
});
