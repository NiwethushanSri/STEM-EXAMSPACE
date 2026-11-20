import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/** A stand-in for tus-js-client: keeps every Upload made, answers findPreviousUploads with `previous`, and on
 * start reports progress and then success or `failWith`. */
const tus = vi.hoisted(() => ({
  made: [] as { file: unknown; options: Record<string, unknown>; resumedFrom: unknown; started: boolean }[],
  previous: [] as unknown[],
  failWith: null as Error | null,
}));

vi.mock("tus-js-client", () => ({
  Upload: class {
    record: (typeof tus.made)[number];
    constructor(file: unknown, options: Record<string, unknown>) {
      this.record = { file, options, resumedFrom: null, started: false };
      tus.made.push(this.record);
    }
    findPreviousUploads() {
      return Promise.resolve(tus.previous);
    }
    resumeFromPreviousUpload(p: unknown) {
      this.record.resumedFrom = p;
    }
    start() {
      this.record.started = true;
      const o = this.record.options as {
        onProgress: (a: number, b: number) => void;
        onSuccess: () => void;
        onError: (e: Error) => void;
      };
      o.onProgress(3, 10);
      if (tus.failWith) o.onError(tus.failWith);
      else o.onSuccess();
    }
  },
}));

import { CHUNK_SIZE, uploadResumable } from "./resumable-upload";

const file = () => new File([new Uint8Array(10)], "page-1.jpg", { type: "image/jpeg", lastModified: 1_700_000_000_000 });

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "http://127.0.0.1:54321");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key");
  tus.made.length = 0;
  tus.previous = [];
  tus.failWith = null;
});
afterEach(() => vi.unstubAllEnvs());

describe("uploadResumable", () => {
  it("resumable_upload_uses_6mb_chunks_and_no_upsert", async () => {
    const progress: [number, number][] = [];
    await uploadResumable(file(), {
      bucket: "script-uploads",
      path: "home/b-1/u-1.jpg",
      accessToken: "user-jwt",
      onProgress: (sent, total) => progress.push([sent, total]),
    });
    expect(tus.made).toHaveLength(1);
    const o = tus.made[0].options as Record<string, unknown> & { headers: Record<string, string>; metadata: Record<string, string> };
    expect(CHUNK_SIZE).toBe(6 * 1024 * 1024);
    expect(o.chunkSize).toBe(6 * 1024 * 1024);
    expect(o.endpoint).toBe("http://127.0.0.1:54321/storage/v1/upload/resumable");
    expect(o.headers["x-upsert"]).toBe("false");
    expect(o.headers.authorization).toBe("Bearer user-jwt");
    expect(o.headers.apikey).toBe("anon-key");
    expect(o.metadata).toMatchObject({ bucketName: "script-uploads", objectName: "home/b-1/u-1.jpg", contentType: "image/jpeg" });
    expect(o.uploadDataDuringCreation).toBe(true);
    expect(o.removeFingerprintOnSuccess).toBe(true);
    expect(Array.isArray(o.retryDelays) && (o.retryDelays as number[]).length).toBeGreaterThan(2);
    expect(progress).toEqual([[3, 10]]);
    expect(tus.made[0].started).toBe(true);
  });

  it("resumes from the stored fingerprint of the same file and path", async () => {
    const earlier = { size: 10, metadata: {}, creationTime: "x", urlStorageKey: "tus::k" };
    tus.previous = [earlier];
    await uploadResumable(file(), { bucket: "script-uploads", path: "home/b-1/u-1.jpg", accessToken: "t" });
    expect(tus.made[0].resumedFrom).toBe(earlier);
  });

  it("starts afresh when nothing was stored", async () => {
    await uploadResumable(file(), { bucket: "script-uploads", path: "home/b-1/u-1.jpg", accessToken: "t" });
    expect(tus.made[0].resumedFrom).toBeNull();
    expect(tus.made[0].started).toBe(true);
  });

  it("keys the fingerprint by the storage path, so another upload of the same file never resumes this one", async () => {
    await uploadResumable(file(), { bucket: "script-uploads", path: "home/b-1/u-1.jpg", accessToken: "t" });
    await uploadResumable(file(), { bucket: "script-uploads", path: "home/b-1/u-2.jpg", accessToken: "t" });
    const fp = (i: number) => (tus.made[i].options.fingerprint as (f: File) => Promise<string>)(file());
    const [a, b] = await Promise.all([fp(0), fp(1)]);
    expect(a).toContain("home/b-1/u-1.jpg");
    expect(a).not.toBe(b);
  });

  it("uses the declared content type when the browser gives none (a HEIC photo)", async () => {
    const heic = new File([new Uint8Array(4)], "IMG_1.HEIC", { type: "" });
    await uploadResumable(heic, { bucket: "script-uploads", path: "home/b-1/u-3.heic", accessToken: "t", contentType: "image/heic" });
    expect((tus.made[0].options.metadata as Record<string, string>).contentType).toBe("image/heic");
  });

  it("sets the token on every request from a fresh session (a long upload outlives the first token)", async () => {
    let token = "first";
    await uploadResumable(file(), {
      bucket: "script-uploads",
      path: "home/b-1/u-1.jpg",
      accessToken: "first",
      getAccessToken: async () => token,
    });
    const before = tus.made[0].options.onBeforeRequest as (req: { setHeader: (k: string, v: string) => void }) => Promise<void>;
    const headers: Record<string, string> = {};
    const req = { setHeader: (k: string, v: string) => (headers[k] = v) };
    token = "refreshed";
    await before(req);
    expect(headers.authorization).toBe("Bearer refreshed");
    // No session to read: the token given at the start is used.
    token = "";
    await before(req);
    expect(headers.authorization).toBe("Bearer first");
  });

  it("uses the given token on every request without a session to read", async () => {
    await uploadResumable(file(), { bucket: "script-uploads", path: "home/b-1/u-1.jpg", accessToken: "only" });
    const before = tus.made[0].options.onBeforeRequest as (req: { setHeader: (k: string, v: string) => void }) => Promise<void>;
    const headers: Record<string, string> = {};
    await before({ setHeader: (k, v) => (headers[k] = v) });
    expect(headers.authorization).toBe("Bearer only");
  });

  it("rejects when the upload fails for good", async () => {
    tus.failWith = new Error("tus: failed to upload chunk");
    await expect(uploadResumable(file(), { bucket: "script-uploads", path: "home/b-1/u-1.jpg", accessToken: "t" })).rejects.toThrow(
      "tus: failed to upload chunk",
    );
  });
});
