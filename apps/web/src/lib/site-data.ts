import type { TestResult } from "@stem/shared";

export type { TestResult };

export const results: TestResult[] = [
  { subject: "Physics", test: "Mock 2 · Mechanics", mark: 71, classAverage: 62, highest: 94, lowest: 38, date: "12 Oct 2026", weakAreas: ["Circular motion", "Energy transfer"] },
  { subject: "Maths", test: "Mock 2 · Calculus", mark: 84, classAverage: 68, highest: 98, lowest: 41, date: "13 Oct 2026", weakAreas: ["Integration by parts"] },
  { subject: "Chemistry", test: "Mock 1 · Organic", mark: 58, classAverage: 65, highest: 91, lowest: 33, date: "20 Sep 2026", weakAreas: ["Reaction mechanisms", "Isomerism"] },
  { subject: "Biology", test: "Mock 1 · Cells", mark: 77, classAverage: 64, highest: 89, lowest: 40, date: "22 Sep 2026", weakAreas: [] },
];

// Children linked to parents. The sheet label (son or daughter) comes from gender.
export type Child = {
  id: string;
  name: string;
  indexNumber: string;
  gender: "Female" | "Male";
  grade: string;
  parent: string;
  parentEmail: string;
  results: TestResult[];
};

export const children: Child[] = [
  {
    id: "amara-perera",
    name: "Amara Perera",
    indexNumber: "SE-2026-0142",
    gender: "Female",
    grade: "Year 13",
    parent: "Nimal Perera",
    parentEmail: "nimal.perera@example.com",
    results: [],
  },
  {
    id: "kasun-silva",
    name: "Kasun Silva",
    indexNumber: "SE-2026-0187",
    gender: "Male",
    grade: "Year 12",
    parent: "Dinesh Silva",
    parentEmail: "dinesh.silva@example.com",
    results: [
      { subject: "Maths", test: "Mock 2 · Algebra", mark: 66, classAverage: 68, highest: 98, lowest: 41, date: "13 Oct 2026", weakAreas: ["Quadratic inequalities"] },
      { subject: "Biology", test: "Mock 1 · Cells", mark: 52, classAverage: 64, highest: 89, lowest: 40, date: "22 Sep 2026", weakAreas: ["Enzymes", "Genetics"] },
    ],
  },
  {
    id: "lena-fernando",
    name: "Lena Fernando",
    indexNumber: "SE-2026-0201",
    gender: "Female",
    grade: "Year 13",
    parent: "Shalini Fernando",
    parentEmail: "shalini.fernando@example.com",
    results: [
      { subject: "Chemistry", test: "Mock 1 · Organic", mark: 81, classAverage: 65, highest: 91, lowest: 33, date: "20 Sep 2026", weakAreas: [] },
      { subject: "Physics", test: "Mock 2 · Mechanics", mark: 74, classAverage: 62, highest: 94, lowest: 38, date: "12 Oct 2026", weakAreas: ["Waves"] },
    ],
  },
];

// Amara's results come from the shared results list.
children[0].results = results;

export const notices = [
  { id: 1, title: "Mock exam timetable published", date: "1 Nov 2026", type: "Latest notice", body: "The June 2027 mock timetable is now live. Check your subject and exam slot in the timetable." },
  { id: 2, title: "Physical exam venue change", date: "29 Oct 2026", type: "Special notice", body: "Biology physical exams on 14 Nov move to Hall B. Bring your index number card." },
  { id: 3, title: "Results review window open", date: "27 Oct 2026", type: "Latest notice", body: "Results enquiries are open until 30 Oct 2026 16:00." },
];

export const paperAllocations = [
  { paper: "Physics Mock 2 · Paper 1", mode: "Physical", examiner: "M Venables", papers: 270, marked: 260 },
  { paper: "Maths Mock 2 · Paper 1", mode: "Online", examiner: "A Pathmanathan", papers: 180, marked: 180 },
  { paper: "Chemistry Mock 1 · Paper 2", mode: "Physical", examiner: "K Cheung", papers: 120, marked: 40 },
];

export const auditLog = [
  { time: "1 Nov 2026 19:04", user: "M Venables", action: "Submitted 10 papers", target: "Physics Mock 2" },
  { time: "1 Nov 2026 18:20", user: "Admin", action: "Approved student", target: "Dilan Jayawardena" },
  { time: "31 Oct 2026 14:55", user: "Admin", action: "Published notice", target: "Mock exam timetable" },
  { time: "30 Oct 2026 10:12", user: "K Cheung", action: "Changed status", target: "Standardisation" },
];
