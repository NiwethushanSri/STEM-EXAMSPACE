// Children linked to parents. The sheet label (son or daughter) comes from gender.
export type Child = {
  id: string;
  name: string;
  indexNumber: string;
  gender: "Female" | "Male";
  grade: string;
  parent: string;
  parentEmail: string;
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
  },
  {
    id: "kasun-silva",
    name: "Kasun Silva",
    indexNumber: "SE-2026-0187",
    gender: "Male",
    grade: "Year 12",
    parent: "Dinesh Silva",
    parentEmail: "dinesh.silva@example.com",
  },
  {
    id: "lena-fernando",
    name: "Lena Fernando",
    indexNumber: "SE-2026-0201",
    gender: "Female",
    grade: "Year 13",
    parent: "Shalini Fernando",
    parentEmail: "shalini.fernando@example.com",
  },
];

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
