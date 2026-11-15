import type { Metadata } from "next";
import { connection } from "next/server";
import { Suspense, cache } from "react";
import { Analysis } from "@/components/home/Analysis";
import { Closing, Families, Footer } from "@/components/home/Closing";
import { IndexCard } from "@/components/home/ExamDay";
import { Marking } from "@/components/home/Marking";
import { Faq } from "@/components/home/Faq";
import { Forecast } from "@/components/home/Forecast";
import { Papers, PapersFallback } from "@/components/home/Papers";
import { Header, Hero, HowItWorks, bookHrefFor } from "@/components/home/Top";
import { jakarta, kalam } from "@/components/home/fonts";
import s from "@/components/home/home.module.css";
import { DEMO_EXAMS } from "@/lib/home-demo";
import { PUBLIC_EXAM_COLUMNS, daysUntil, pickNextPaper, type PublicExam } from "@/lib/home-exams";
import { createClient, getSessionProfile } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Stem Examspace · GCSE and A level mock exams",
  description:
    "Sit a GCSE or A level mock in a real exam hall, timed like the real paper and marked question by question. See upcoming papers, seats left and prices, and book a seat.",
};

type Search = Promise<{ demo?: string | string[] }>;

/** `/?demo=1` previews the page with sample papers, on the development server only. */
async function isDemo(searchParams: Search): Promise<boolean> {
  const { demo } = await searchParams;
  return process.env.NODE_ENV !== "production" && demo === "1";
}

/** Seats left and the next paper are live, so these parts render per request. */
async function requestNow(): Promise<Date> {
  await connection();
  return new Date();
}

/** The published papers still to come. One query per request, shared by every section that needs it. */
const loadExams = cache(async (demo: boolean): Promise<{ exams: PublicExam[]; error: boolean }> => {
  await connection();
  if (demo) return { exams: DEMO_EXAMS, error: false };
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("exams_public")
    .select(PUBLIC_EXAM_COLUMNS)
    .gt("starts_at", new Date().toISOString())
    .order("starts_at", { ascending: true })
    .limit(60);
  return { exams: ((data ?? []) as unknown as PublicExam[]).filter((e) => e.id), error: !!error };
});

async function HeaderWithData({ searchParams }: { searchParams: Search }) {
  const [{ exams }, me] = await Promise.all([loadExams(await isDemo(searchParams)), getSessionProfile()]);
  return <Header signedIn={!!me} bookHref={bookHrefFor(exams, await requestNow())} />;
}

async function HeroWithData({ searchParams }: { searchParams: Search }) {
  const { exams } = await loadExams(await isDemo(searchParams));
  const now = await requestNow();
  const next = pickNextPaper(exams, now);
  return <Hero next={next} days={next ? daysUntil(next.starts_at, now) : undefined} bookHref={bookHrefFor(exams, now)} />;
}

async function PapersWithData({ searchParams }: { searchParams: Search }) {
  const { exams, error } = await loadExams(await isDemo(searchParams));
  return <Papers exams={exams} now={await requestNow()} error={error} />;
}

async function ClosingWithData({ searchParams }: { searchParams: Search }) {
  const { exams } = await loadExams(await isDemo(searchParams));
  return <Closing bookHref={bookHrefFor(exams, await requestNow())} />;
}

export default function Home({ searchParams }: { searchParams: Search }) {
  return (
    <div className={`${s.home} ${jakarta.variable} ${kalam.variable}`}>
      <a href="#main" className={s.skip}>
        Skip to content
      </a>
      <Suspense fallback={<Header signedIn={false} bookHref="/exams" />}>
        <HeaderWithData searchParams={searchParams} />
      </Suspense>
      <main id="main">
        <Suspense fallback={<Hero next={undefined} bookHref="/exams" />}>
          <HeroWithData searchParams={searchParams} />
        </Suspense>
        <Analysis />
        <Suspense fallback={<PapersFallback />}>
          <PapersWithData searchParams={searchParams} />
        </Suspense>
        <HowItWorks />
        <Marking />
        <Forecast />
        <IndexCard />
        <Families />
        <Faq />
        <Suspense fallback={<Closing bookHref="/exams" />}>
          <ClosingWithData searchParams={searchParams} />
        </Suspense>
      </main>
      <Footer />
    </div>
  );
}
