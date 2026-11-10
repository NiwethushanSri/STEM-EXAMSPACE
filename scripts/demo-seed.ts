// Seeds (or removes) the private demo data on the dev Supabase project.
//
//   npm run demo:seed     removes any earlier demo data, then creates it again
//   npm run demo:remove   removes every demo user and everything that hangs off them
//
// Every demo email uses the domain demo.stemexamspace.test. Passwords are random and written only to
// demo-accounts.local.md (git-ignored); they are never printed. Runs on Node >= 22.9 with
// --env-file=.env.dev.local. Refuses to run against any project other than the dev one.
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const PROJECT_REF = "jmhjahwfskhlgagaqlrz";
const DOMAIN = "demo.stemexamspace.test";
const OUT = "demo-accounts.local.md";

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) fail("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (run with --env-file=.env.dev.local).");
if (!url.includes(PROJECT_REF)) fail("SUPABASE_URL is not the dev project. Nothing was changed.");

const svc = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
const must = <T>(r: { data: T; error: { message: string } | null }, what: string): T => {
  if (r.error) fail(`${what} failed: ${r.error.message}`);
  return r.data;
};
const password = () => randomBytes(18).toString("base64url");

async function removeDemo(): Promise<number> {
  const profs = must(await svc.from("profiles").select("id").ilike("email", `%@${DOMAIN}`), "list demo users");
  const ids = (profs as { id: string }[]).map((p) => p.id);
  for (const id of ids) {
    const { data: files } = await svc.storage.from("student-photos").list(id);
    if (files?.length) await svc.storage.from("student-photos").remove(files.map((f) => `${id}/${f.name}`));
  }
  must(await svc.from("pending_invites").delete().ilike("email", `%@${DOMAIN}`), "delete demo invites");
  if (ids.length) {
    const list = ids.join(",");
    must(await svc.from("parent_link_requests").delete().or(`parent_id.in.(${list}),student_id.in.(${list})`), "delete link requests");
    must(await svc.from("audit_log").delete().or(`actor_id.in.(${list}),target_id.in.(${list})`), "delete audit rows");
  }
  for (const id of ids) {
    const { error } = await svc.auth.admin.deleteUser(id);
    if (error && !/not found/i.test(error.message)) fail(`delete user failed: ${error.message}`);
  }
  return ids.length;
}

const removeOnly = process.argv.includes("--remove");
const removed = await removeDemo();
if (removeOnly) {
  console.log(`Removed ${removed} demo user(s).`);
  process.exit(0);
}

const { count: otherOwners } = await svc.from("profiles").select("*", { count: "exact", head: true }).eq("role", "owner");
if ((otherOwners ?? 0) > 0) fail("A different owner already exists on this project. Nothing was seeded.");

type Row = { role: string; name: string; email: string; password: string; index?: string };
const rows: Row[] = [];
const em = (s: string) => `${s}@${DOMAIN}`;

async function mk(o: {
  first: string; last: string; email: string; role?: string; status?: string; meta?: Record<string, string>; show?: boolean; label?: string; index?: string;
}): Promise<string> {
  const pw = password();
  const { data, error } = await svc.auth.admin.createUser({
    email: o.email,
    password: pw,
    email_confirm: true,
    user_metadata: { first_name: o.first, last_name: o.last, ...(o.meta ?? {}) },
  });
  if (error || !data.user) fail(`createUser ${o.email} failed: ${error?.message}`);
  const id = data.user.id;
  if (o.role) {
    must(await svc.from("profiles").update({ role: o.role, status: o.status ?? "active" }).eq("id", id), "profile update");
    if (o.role !== "student") must(await svc.from("student_details").delete().eq("profile_id", id), "details cleanup");
  }
  if (o.show !== false) rows.push({ role: o.label ?? o.role ?? "student", name: `${o.first} ${o.last}`, email: o.email, password: pw, index: o.index });
  return id;
}

const subjects = must(await svc.from("subjects").select("id,name").in("name", ["Maths", "Physics", "Chemistry"]), "subjects") as { id: number; name: string }[];
if (subjects.length !== 3) fail("Expected the Maths, Physics and Chemistry subjects.");

async function activeStudent(first: string, last: string, email: string, index: string, dob: string, year: string, parentName: string, parentEmail: string, phone: string) {
  const id = await mk({ first, last, email, role: "student", status: "active", index, label: "Student", meta: { school: "Demo Grammar School", date_of_birth: dob, parent_name: parentName, parent_email: parentEmail } });
  must(await svc.from("student_details").update({
    index_number: index, school: "Demo Grammar School", date_of_birth: dob, gender: "Female", year_group: year,
    parent_phone: phone, signup_parent_name: parentName, signup_parent_email: null,
  }).eq("profile_id", id), "student details");
  must(await svc.from("student_subjects").insert(subjects.map((s) => ({ student_id: id, subject_id: s.id }))), "student subjects");
  return id;
}

await mk({ first: "Sam", last: "Owner", email: em("owner"), role: "owner", label: "Super administrator" });
await mk({ first: "Alex", last: "Admin", email: em("admin"), role: "admin", label: "Admin" });
const tutor = await mk({ first: "Tara", last: "Tutor", email: em("tutor"), role: "tutor", label: "Tutor" });
const nimal = await mk({ first: "Nimal", last: "Perera", email: em("nimal.perera"), role: "parent", label: "Parent (linked to Amara)" });
const dilani = await mk({ first: "Dilani", last: "Silva", email: em("dilani.silva"), role: "parent", label: "Parent (requests link to Kasun)" });

const amara = await activeStudent("Amara", "Perera", em("amara.perera"), "SE-2026-9001", "2011-05-14", "Year 11", "Nimal Perera", em("nimal.perera"), "+94 77 123 4567");
const kasun = await activeStudent("Kasun", "Silva", em("kasun.silva"), "SE-2026-9002", "2010-09-03", "Year 12", "Dilani Silva", em("dilani.silva"), "+94 71 765 4321");
must(await svc.from("parent_children").insert({ parent_id: nimal, student_id: amara }), "parent link");
must(await svc.from("tutor_students").insert({ tutor_id: tutor, student_id: amara }), "tutor link");

const pending = (first: string, last: string, slug: string, parentName: string, parentEmail: string) =>
  mk({ first, last, email: em(slug), show: false, meta: { school: "Demo Grammar School", date_of_birth: "2010-02-20", parent_name: parentName, parent_email: parentEmail } });
await pending("Ishara", "Fernando", "ishara.fernando", "Ruwan Fernando", em("ruwan.fernando"));
await pending("Dinesh", "Perera", "dinesh.perera", "Nimal Perera", em("nimal.perera"));
const byParent = await pending("Maya", "Silva", "maya.silva", "Dilani Silva", em("dilani.silva"));
must(await svc.from("student_details").update({ requested_by_parent: dilani }).eq("profile_id", byParent), "requested_by");

must(await svc.from("parent_link_requests").insert({ parent_id: dilani, student_id: kasun }), "link request");

const md = `# Demo accounts (private, do not commit or share)

Preview site: the team-protected deployment URL you were given. Email sending is off, so nobody receives mail.
Generated by \`npm run demo:seed\`; \`npm run demo:remove\` deletes all of it.

| Role | Name | Sign in with | Password |
| --- | --- | --- | --- |
${rows.map((r) => `| ${r.role} | ${r.name} | ${r.index ? `index number ${r.index}` : r.email} | ${r.password} |`).join("\n")}

Pending registrations (no sign-in needed): Ishara Fernando (parent email matches no account), Dinesh Perera (parent email matches Nimal Perera, approval links him), Maya Silva (registered by parent Dilani Silva).

## Demo script
1. Sign in as the Super administrator. Open the pending approvals list: three registrations are waiting.
2. Approve Dinesh Perera: Nimal Perera is linked automatically. Approve Maya Silva: Dilani Silva is linked. Approve Ishara Fernando: an invitation for her parent is created (no email goes out).
3. Open the parent link requests: Dilani Silva asks to be linked to Kasun Silva. Approve it.
4. Open the accounts list to show roles, statuses and the account actions (edit, suspend).
5. Sign out. Sign in as Amara Perera using the index number and password: show the student view.
6. Sign out. Sign in as Nimal Perera: show the linked child.
7. Sign in as the Tutor: show the assigned student. Sign in as the Admin: show the admin view.
`;
writeFileSync(OUT, md);
console.log(`Seeded ${rows.length} sign-in accounts and 3 pending registrations. Details written to ${OUT}.`);
