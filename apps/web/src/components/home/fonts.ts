import { Kalam, Plus_Jakarta_Sans } from "next/font/google";

/** The one family for headings and body, as on the reference site the owner chose (Save My Exams). */
export const jakarta = Plus_Jakarta_Sans({ subsets: ["latin"], variable: "--font-jakarta", display: "swap" });

/** Handwriting on the example script only. */
export const kalam = Kalam({ subsets: ["latin"], weight: ["400", "700"], variable: "--font-kalam", display: "swap", preload: false });
