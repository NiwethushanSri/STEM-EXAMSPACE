export const subjects = [
  "Maths",
  "Further Maths",
  "Physics",
  "Chemistry",
  "Biology",
  "Computer Science",
];

export const entranceExams = ["TMUA", "FSAT", "UCAT"];

export type TestResult = {
  subject: string;
  test: string;
  mark: number;
  classAverage: number;
  highest: number;
  lowest: number;
  date: string;
  weakAreas: string[];
};

export const student = {
  name: "Amara Perera",
  indexNumber: "SE-2026-0142",
  grade: "Year 13",
  school: "Colombo International School",
  dob: "12/03/2009",
  parent: "Nimal Perera",
};

export const results: TestResult[] = [
  { subject: "Physics", test: "Mock 2 · Mechanics", mark: 71, classAverage: 62, highest: 94, lowest: 38, date: "12 Oct 2026", weakAreas: ["Circular motion", "Energy transfer"] },
  { subject: "Maths", test: "Mock 2 · Calculus", mark: 84, classAverage: 68, highest: 98, lowest: 41, date: "13 Oct 2026", weakAreas: ["Integration by parts"] },
  { subject: "Chemistry", test: "Mock 1 · Organic", mark: 58, classAverage: 65, highest: 91, lowest: 33, date: "20 Sep 2026", weakAreas: ["Reaction mechanisms", "Isomerism"] },
  { subject: "Biology", test: "Mock 1 · Cells", mark: 77, classAverage: 64, highest: 89, lowest: 40, date: "22 Sep 2026", weakAreas: [] },
];

// Mark history per subject, oldest first. Mock data for the analysis and forecast charts.
export const markHistory: Record<string, { label: string; mark: number }[]> = {
  Physics: [
    { label: "Jun", mark: 52 },
    { label: "Jul", mark: 55 },
    { label: "Sep", mark: 61 },
    { label: "Oct", mark: 71 },
  ],
  Maths: [
    { label: "Jun", mark: 66 },
    { label: "Jul", mark: 72 },
    { label: "Sep", mark: 78 },
    { label: "Oct", mark: 84 },
  ],
  Chemistry: [
    { label: "Jun", mark: 49 },
    { label: "Jul", mark: 54 },
    { label: "Aug", mark: 57 },
    { label: "Sep", mark: 58 },
  ],
  Biology: [
    { label: "Jun", mark: 70 },
    { label: "Jul", mark: 74 },
    { label: "Sep", mark: 77 },
  ],
};

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

export const upcomingExams = [
  { subject: "Physics", date: "14 Nov 2026", time: "09:00", type: "Physical", venue: "Hall B" },
  { subject: "Maths", date: "18 Nov 2026", time: "13:00", type: "Online", venue: "Online" },
  { subject: "UCAT", date: "2 Dec 2026", time: "08:30", type: "Online", venue: "Online" },
];

export const attendance = [
  { date: "14 Oct 2026", exam: "Physics Mock 2", status: "Present" },
  { date: "13 Oct 2026", exam: "Maths Mock 2", status: "Present" },
  { date: "20 Sep 2026", exam: "Chemistry Mock 1", status: "Late" },
  { date: "22 Sep 2026", exam: "Biology Mock 1", status: "Absent" },
];

export const bookings = [
  { id: "BK-2041", student: "Amara Perera", exam: "Physics Mock 3", amount: "£25", status: "Paid" },
  { id: "BK-2042", student: "Kasun Silva", exam: "UCAT Practice", amount: "£40", status: "Pending" },
  { id: "BK-2043", student: "Lena Fernando", exam: "TMUA Practice", amount: "£35", status: "Paid" },
  { id: "BK-2044", student: "Ravi Kumar", exam: "Maths Mock 3", amount: "£25", status: "Refund requested" },
];

export const pendingApprovals = [
  { name: "Dilan Jayawardena", role: "Student", school: "Royal College", submitted: "31 Oct 2026" },
  { name: "Sachini Ranasinghe", role: "Student", school: "St. Joseph's", submitted: "30 Oct 2026" },
];

export const accounts = [
  { name: "Amara Perera", role: "Student", status: "Active" },
  { name: "Nimal Perera", role: "Parent", status: "Active" },
  { name: "M Venables", role: "Examiner", status: "Active" },
  { name: "A Pathmanathan", role: "Examiner", status: "Active" },
  { name: "K Cheung", role: "Examiner", status: "Suspended" },
];

export const paperAllocations = [
  { paper: "Physics Mock 2 · Paper 1", mode: "Physical", examiner: "M Venables", papers: 270, marked: 260 },
  { paper: "Maths Mock 2 · Paper 1", mode: "Online", examiner: "A Pathmanathan", papers: 180, marked: 180 },
  { paper: "Chemistry Mock 1 · Paper 2", mode: "Physical", examiner: "K Cheung", papers: 120, marked: 40 },
];

export const examinerProgress = [
  { name: "M Venables", assigned: 270, marked: 260, accuracy: "In tolerance" },
  { name: "A Pathmanathan", assigned: 180, marked: 180, accuracy: "In tolerance" },
  { name: "K Cheung", assigned: 120, marked: 40, accuracy: "Inaccurate" },
];

export const auditLog = [
  { time: "1 Nov 2026 19:04", user: "M Venables", action: "Submitted 10 papers", target: "Physics Mock 2" },
  { time: "1 Nov 2026 18:20", user: "Admin", action: "Approved student", target: "Dilan Jayawardena" },
  { time: "31 Oct 2026 14:55", user: "Admin", action: "Published notice", target: "Mock exam timetable" },
  { time: "30 Oct 2026 10:12", user: "K Cheung", action: "Changed status", target: "Standardisation" },
];

export const timetable = [
  { date: "14 Nov 2026", subject: "Physics", time: "09:00–11:00", type: "Physical" },
  { date: "18 Nov 2026", subject: "Maths", time: "13:00–15:00", type: "Online" },
  { date: "21 Nov 2026", subject: "Chemistry", time: "10:00–12:00", type: "Online" },
  { date: "2 Dec 2026", subject: "UCAT", time: "08:30–10:30", type: "Online" },
];
