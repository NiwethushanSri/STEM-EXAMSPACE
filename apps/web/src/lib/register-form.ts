/** Client-side checks for the public registration form. The server checks the same rules again. */

export type RegisterFields = {
  first: string;
  last: string;
  dob: string;
  school: string;
  email: string;
  pname: string;
  pemail: string;
  pphone: string;
};

export type FieldErrors = Partial<Record<keyof RegisterFields, string>>;

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Same rule as the server: 10 to 15 digits, an optional leading +, and spaces, brackets, dots or hyphens. */
export function validPhone(v: string): boolean {
  const t = v.trim().replace(/\s+/g, " ");
  if (t.length > 30 || !/^\+?[\d ().-]+$/.test(t)) return false;
  const digits = t.replace(/\D/g, "").length;
  return digits >= 10 && digits <= 15;
}

/** Whole years between a YYYY-MM-DD date of birth and today's date (UTC). Null for an unreal date. */
export function ageOn(dob: string, today: Date): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dob);
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const date = new Date(Date.UTC(y, mo - 1, d));
  if (date.getUTCFullYear() !== y || date.getUTCMonth() !== mo - 1 || date.getUTCDate() !== d) return null;
  if (date >= today) return null;
  let age = today.getUTCFullYear() - y;
  if (today.getUTCMonth() < mo - 1 || (today.getUTCMonth() === mo - 1 && today.getUTCDate() < d)) age--;
  return age;
}

/** Every problem with the form, keyed by field, in plain words. Empty when the form can be sent. */
export function checkRegistration(f: RegisterFields, today: Date): FieldErrors {
  const e: FieldErrors = {};
  if (!f.first) e.first = "Enter the student’s first name.";
  else if (f.first.length > 80) e.first = "The first name can be at most 80 characters.";
  if (!f.last) e.last = "Enter the student’s last name.";
  else if (f.last.length > 80) e.last = "The last name can be at most 80 characters.";

  if (!f.dob) e.dob = "Enter the student’s date of birth.";
  else {
    const age = ageOn(f.dob, today);
    if (age === null) e.dob = "Enter a real date of birth in the past.";
    else if (age < 8 || age > 25) e.dob = "The student must be between 8 and 25 years old.";
  }

  if (!f.school) e.school = "Enter the student’s school.";
  else if (f.school.length > 120) e.school = "The school name can be at most 120 characters.";

  if (!f.email) e.email = "Enter the student’s email address.";
  else if (!EMAIL.test(f.email)) e.email = "Enter a valid email address, like name@example.com.";

  if (!f.pname) e.pname = "Enter the parent or guardian’s name.";
  else if (f.pname.length > 120) e.pname = "The name can be at most 120 characters.";

  if (!f.pemail) e.pemail = "Enter the parent or guardian’s email address.";
  else if (!EMAIL.test(f.pemail)) e.pemail = "Enter a valid email address, like name@example.com.";
  else if (f.email && f.pemail.toLowerCase() === f.email.toLowerCase())
    e.pemail = "Use a different email from the student’s. The parent gets their own account.";

  if (!f.pphone) e.pphone = "Enter the parent or guardian’s phone number.";
  else if (!validPhone(f.pphone)) e.pphone = "Enter a valid phone number, like 07700 900123.";

  return e;
}
