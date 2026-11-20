import { Upload } from "tus-js-client";

/** Supabase Storage takes resumable uploads in 6 MB chunks (it must be exactly this). */
export const CHUNK_SIZE = 6 * 1024 * 1024;
/** Waits between tries after a lost connection, in ms; after the last the upload fails and can be started again. */
const RETRY_DELAYS = [0, 1000, 3000, 5000, 10000, 20000, 30000];

export type ResumableOptions = {
  bucket: string;
  /** The object's path: the storage policy allows exactly the path of a pending upload row of this user. */
  path: string;
  /** The signed-in user's access token (the anon key alone may add nothing). */
  accessToken: string;
  /** The content type declared for the upload row (a HEIC photo often has none in the browser). */
  contentType?: string;
  onProgress?: (sent: number, total: number) => void;
};

/**
 * Uploads a file straight to private Storage with tus (`${SUPABASE_URL}/storage/v1/upload/resumable`), in 6 MB
 * chunks, never overwriting (`x-upsert: false`). A lost connection is retried from where it stopped; an upload
 * started again for the same file and path (after it failed, or a reload with the file chosen again) resumes from
 * the fingerprint tus keeps in the browser, so nothing is sent twice. The fingerprint includes the path, so a
 * file chosen again for a new upload row never continues an old one. Resolves once the whole file is stored.
 */
export function uploadResumable(file: File | Blob, opts: ResumableOptions): Promise<void> {
  const base = (process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").replace(/\/+$/, "");
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const contentType = opts.contentType || file.type || "application/octet-stream";
  return new Promise<void>((resolve, reject) => {
    const upload = new Upload(file, {
      endpoint: `${base}/storage/v1/upload/resumable`,
      retryDelays: RETRY_DELAYS,
      headers: {
        authorization: `Bearer ${opts.accessToken}`,
        "x-upsert": "false",
        ...(anonKey ? { apikey: anonKey } : {}),
      },
      uploadDataDuringCreation: true,
      removeFingerprintOnSuccess: true,
      chunkSize: CHUNK_SIZE,
      metadata: { bucketName: opts.bucket, objectName: opts.path, contentType, cacheControl: "3600" },
      fingerprint: async (f: File) =>
        ["stem-upload", opts.bucket, opts.path, f.size, (f as Partial<File>).lastModified ?? 0].join("|"),
      onProgress: (sent, total) => opts.onProgress?.(sent, total),
      onError: (error) => reject(error),
      onSuccess: () => resolve(),
    });
    upload
      .findPreviousUploads()
      .then((previous) => {
        if (previous.length > 0) upload.resumeFromPreviousUpload(previous[0]);
        upload.start();
      })
      .catch(reject);
  });
}
