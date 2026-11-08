import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { homeFor, type AccountStatus, type AppRole, type Database } from "@stem/shared";

/**
 * Optimistic route protection only (Next 16 `proxy`, formerly middleware). It refreshes the session
 * cookies and redirects obvious mismatches; real authorisation is RLS plus the server-component
 * re-check in `getSessionProfile()`.
 */

// Which roles may open each staff area. Owner is a superset of admin.
const AREAS: Record<string, readonly AppRole[]> = {
  "/owner": ["owner"],
  "/admin": ["admin", "owner"],
  "/teacher": ["teacher"],
  "/tutor": ["tutor"],
  "/corrector": ["corrector"],
  // Mock sample-data areas: nobody may open them until their part of the build; visitors go home.
  "/student": [],
  "/parent": [],
  "/examiner": [],
};

function areaOf(pathname: string): string | null {
  for (const area of [...Object.keys(AREAS), "/account"]) {
    if (pathname === area || pathname.startsWith(area + "/")) return area;
  }
  return null;
}

export async function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const area = areaOf(pathname);
  if (!area) return NextResponse.next();

  let response = NextResponse.next({ request });
  const supabase = createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll(list) {
          list.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  const redirectTo = (path: string) => {
    const res = NextResponse.redirect(new URL(path, request.url));
    response.cookies.getAll().forEach((c) => res.cookies.set(c));
    return res;
  };

  const { data: claims } = await supabase.auth.getClaims();
  const uid = claims?.claims?.sub;
  if (!uid) return redirectTo("/login");

  const { data: profile } = await supabase
    .from("profiles")
    .select("role, status")
    .eq("id", uid)
    .maybeSingle();
  if (!profile) return redirectTo("/login");

  const role: AppRole = profile.role;
  const status: AccountStatus = profile.status;
  const home = homeFor(role, status, "web-staff");

  // Each account holds exactly one valid /account page (its status page); everything else goes there.
  if (area === "/account") return pathname === home ? response : redirectTo(home);

  const allowed = AREAS[area].includes(role) && status !== "suspended";
  return allowed ? response : redirectTo(home);
}

export const config = {
  matcher: ["/owner/:path*", "/admin/:path*", "/teacher/:path*", "/tutor/:path*", "/corrector/:path*", "/student/:path*", "/parent/:path*", "/examiner/:path*", "/account/:path*"],
};
