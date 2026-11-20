/**
 * The quick blur check on the family's phone or computer, with the processing server's own measure and threshold
 * (services/processor/processor/imaging.py `quality`): the variance of the Laplacian of a greyscale copy 1000 px
 * wide, a photo below 60 being blurred. The server checks again on the straightened page; this only spares the
 * family a retake later.
 */

/** Width of the greyscale copy the measure is taken on (the server's MEASURE_WIDTH). */
export const MEASURE_WIDTH = 1000;
/** Below this variance of the Laplacian a page is blurred (the server's BLURRED_BELOW). */
export const BLURRED_BELOW = 60;

/** An RGBA picture, as ImageData holds it. */
export type GreyImage = { width: number; height: number; data: Uint8ClampedArray | Uint8Array };

/**
 * Variance of the Laplacian (kernel 0 1 0 / 1 -4 1 / 0 1 0, edges mirrored without repeating the edge pixel) of the
 * picture's grey levels, grey taken as OpenCV's RGB to grey (rounded fixed point). OpenCV's cv2.Laplacian(img,
 * cv2.CV_64F).var() gives the same number for the same pixels.
 */
export function blurScore(img: GreyImage): number {
  const { width: w, height: h, data } = img;
  const n = w * h;
  if (n === 0) return 0;
  const grey = new Int32Array(n);
  for (let i = 0; i < n; i++) {
    grey[i] = (data[i * 4] * 4899 + data[i * 4 + 1] * 9617 + data[i * 4 + 2] * 1868 + 8192) >> 14;
  }
  // BORDER_REFLECT_101: the pixel before the first is the second (for a single pixel, itself).
  const at = (x: number, y: number) => {
    const xx = x < 0 ? Math.min(-x, w - 1) : x >= w ? Math.max(2 * w - 2 - x, 0) : x;
    const yy = y < 0 ? Math.min(-y, h - 1) : y >= h ? Math.max(2 * h - 2 - y, 0) : y;
    return grey[yy * w + xx];
  };
  let sum = 0;
  let sumSq = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const v = at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1) - 4 * grey[y * w + x];
      sum += v;
      sumSq += v * v;
    }
  }
  const mean = sum / n;
  return Math.max(0, sumSq / n - mean * mean);
}

export function isBlurred(score: number): boolean {
  return score < BLURRED_BELOW;
}

/** One canvas for every measure (a phone keeps one 1000 px picture in memory, not one per photo). */
let measuring: HTMLCanvasElement | null = null;

/**
 * The blur score of part of a picture (by default all of it) in the browser: drawn MEASURE_WIDTH px wide on a
 * canvas, then measured. Null when the browser cannot draw it (a HEIC photo outside Safari, or no canvas).
 */
export function measureBlur(
  source: CanvasImageSource,
  sourceWidth: number,
  sourceHeight: number,
  crop: { x: number; y: number; w: number; h: number } = { x: 0, y: 0, w: sourceWidth, h: sourceHeight },
): number | null {
  if (typeof document === "undefined" || crop.w <= 0 || crop.h <= 0) return null;
  measuring ??= document.createElement("canvas");
  const canvas = measuring;
  canvas.width = MEASURE_WIDTH;
  canvas.height = Math.max(1, Math.round((crop.h * MEASURE_WIDTH) / crop.w));
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) return null;
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  try {
    ctx.drawImage(source, crop.x, crop.y, crop.w, crop.h, 0, 0, canvas.width, canvas.height);
    return blurScore(ctx.getImageData(0, 0, canvas.width, canvas.height));
  } catch {
    return null;
  } finally {
    canvas.width = 1; // lets the picture go
    canvas.height = 1;
  }
}

/** A photo file decoded straight to MEASURE_WIDTH px wide where the browser can (no full-size picture in memory),
 * else at full size. Null when the browser cannot decode it. */
async function decodeSmall(file: Blob): Promise<ImageBitmap | null> {
  if (typeof createImageBitmap !== "function") return null;
  try {
    return await createImageBitmap(file, { resizeWidth: MEASURE_WIDTH, resizeQuality: "medium" });
  } catch {
    try {
      return await createImageBitmap(file);
    } catch {
      return null;
    }
  }
}

/** The blur score of a photo file, or null when the browser cannot decode it. */
export async function measureFileBlur(file: Blob): Promise<number | null> {
  return (await inspectPhoto(file, 0)).score;
}

/**
 * Looks at a photo once, decoded small: its blur score and a small JPEG thumbnail `thumbWidth` px wide (none for 0),
 * each null when the browser cannot decode the photo. Callers run these one at a time.
 */
export async function inspectPhoto(file: Blob, thumbWidth = 240): Promise<{ score: number | null; thumbnail: Blob | null }> {
  const bitmap = await decodeSmall(file);
  if (!bitmap) return { score: null, thumbnail: null };
  try {
    const score = measureBlur(bitmap, bitmap.width, bitmap.height);
    let thumbnail: Blob | null = null;
    if (thumbWidth > 0 && bitmap.width > 0) {
      const canvas = document.createElement("canvas");
      canvas.width = thumbWidth;
      canvas.height = Math.max(1, Math.round((bitmap.height * thumbWidth) / bitmap.width));
      canvas.getContext("2d")?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      thumbnail = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.7));
    }
    return { score, thumbnail };
  } finally {
    bitmap.close();
  }
}
