export type Question = {
  id: string;
  label: string;
  max: number;
};

export type Response = {
  id: string;
  subject: string;
  status: "not_started" | "in_progress" | "submitted";
  questions: Question[];
};

export const questions: Question[] = [
  { id: "1", label: "1", max: 1 },
  { id: "2", label: "2", max: 1 },
  { id: "3", label: "3", max: 2 },
  { id: "4", label: "4", max: 3 },
  { id: "5a", label: "5a", max: 2 },
  { id: "5b", label: "5b", max: 4 },
  { id: "6", label: "6", max: 6 },
];

export const responses: Response[] = [
  { id: "6165313553", subject: "Physics", status: "not_started", questions },
  { id: "6165491992", subject: "Physics", status: "not_started", questions },
  { id: "6158805295", subject: "Physics", status: "in_progress", questions },
];
