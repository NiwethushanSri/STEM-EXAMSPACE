export type ErrorCode =
  | "unauthenticated"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "invalid_input"
  | "parent_email_is_staff"
  | "email_in_use"
  | "rate_limited"
  | "invalid_credentials"
  | "internal";

export class HttpError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  constructor(code: ErrorCode, status: number, message: string) {
    super(message);
    this.name = "HttpError";
    this.code = code;
    this.status = status;
  }
}

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function errorResponse(code: ErrorCode, message: string, status: number): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Wraps an Edge Function handler: CORS preflight, HttpError mapping, generic 500s. */
export function handle(
  fn: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }
    try {
      const res = await fn(req);
      const headers = new Headers(res.headers);
      for (const [k, v] of Object.entries(corsHeaders)) headers.set(k, v);
      return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
    } catch (err) {
      if (err instanceof HttpError) return errorResponse(err.code, err.message, err.status);
      // Log only the error name/message; never request data or headers.
      console.error(
        "unhandled error:",
        err instanceof Error ? `${err.name}: ${err.message}` : "non-error thrown",
      );
      return errorResponse("internal", "Something went wrong. Please try again.", 500);
    }
  };
}
