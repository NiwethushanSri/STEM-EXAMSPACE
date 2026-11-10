import Link from "next/link";
import type { ReactNode } from "react";

/** Plain page frame for the public timetable and the family booking pages. */
export function Frame({ signedIn, children }: { signedIn: boolean; children: ReactNode }) {
  return (
    <div className="min-h-screen bg-slate-50 text-slate-900">
      <header className="flex items-center justify-between bg-blue-700 px-6 py-4 text-white">
        <Link href="/" className="text-lg font-semibold tracking-tight">Stem Examspace</Link>
        <nav className="flex gap-5 text-sm">
          <Link href="/exams" className="hover:underline">Exams</Link>
          {signedIn ? (
            <Link href="/account/bookings" className="hover:underline">My bookings</Link>
          ) : (
            <Link href="/login" className="hover:underline">Sign in</Link>
          )}
        </nav>
      </header>
      <main className="mx-auto max-w-5xl px-6 py-10">{children}</main>
    </div>
  );
}
