const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** True for a canonical 8-4-4-4-12 hex id (any version); used before an id from a URL reaches a query. */
export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID.test(v);
}
