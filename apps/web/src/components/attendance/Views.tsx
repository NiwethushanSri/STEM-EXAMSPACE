import Link from "next/link";
import { notFound } from "next/navigation";
import { Badge, Card } from "@/components/AppShell";
import { Register } from "@/components/attendance/Register";
import { loadPicker, loadRegister, type Area } from "@/lib/attendance";
import { formatLondon } from "@/lib/money";

/** The exam picker: published exams from today on, plus recently completed ones. */
export async function PickerView({ area }: { area: Area }) {
  const exams = await loadPicker(area);
  return (
    <Card title="Choose an exam">
      {exams.length === 0 ? (
        <p className="text-sm text-slate-500">No published exams today or later, and none completed recently.</p>
      ) : (
        <ul className="divide-y divide-slate-100">
          {exams.map((e) => (
            <li key={e.id} data-testid="attendance-exam" className="flex flex-wrap items-center justify-between gap-2 py-3 text-sm">
              <span>
                <Link href={`/${area}/attendance/${e.id}`} className="font-medium text-blue-700 underline">
                  {e.title}
                </Link>
                <span className="ml-2 text-slate-500">
                  {e.subject} · {e.paper} · {formatLondon(e.startsAt)}
                </span>
              </span>
              <Badge tone={e.status === "completed" ? "slate" : "green"}>{e.status === "completed" ? "Completed" : "Published"}</Badge>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

function NameList({ title, testId, rows, names, empty }: { title: string; testId: string; rows: { id: string; name: string }[]; names: boolean; empty: string }) {
  return (
    <Card title={`${title} (${rows.length})`}>
      <div data-testid={testId}>
        {rows.length === 0 ? (
          <p className="text-sm text-slate-500">{empty}</p>
        ) : names ? (
          <ul className="space-y-1 text-sm">
            {rows.map((r) => (
              <li key={r.id}>{r.name}</li>
            ))}
          </ul>
        ) : (
          <p className="text-sm text-slate-500">Names are shown to admins only.</p>
        )}
      </div>
    </Card>
  );
}

export async function RegisterView({ area, examId }: { area: Area; examId: string }) {
  const d = await loadRegister(area, examId);
  if (!d) notFound();
  const { exam } = d;
  const closed = !d.open;
  return (
    <div className="space-y-5">
      <p className="text-sm">
        <Link href={`/${area}/attendance`} className="text-blue-700 underline">
          All exams
        </Link>
      </p>
      <Card title="Exam">
        <dl className="grid gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
          <div>
            <dt className="text-slate-500">Exam</dt>
            <dd className="font-medium">{exam.title}</dd>
          </div>
          <div>
            <dt className="text-slate-500">Subject and paper</dt>
            <dd>
              {exam.subject} · {exam.paper}
            </dd>
          </div>
          <div>
            <dt className="text-slate-500">Starts (UK time)</dt>
            <dd data-testid="exam-start">{formatLondon(exam.startsAt)}</dd>
          </div>
          <div>
            <dt className="text-slate-500">Duration</dt>
            <dd>{exam.durationMinutes} minutes</dd>
          </div>
          <div>
            <dt className="text-slate-500">Where</dt>
            <dd>{exam.format === "online" ? "Online" : [exam.venue, exam.room].filter(Boolean).join(", ") || "Venue to be confirmed"}</dd>
          </div>
          <div>
            <dt className="text-slate-500">Register</dt>
            <dd>{closed ? "Closed" : "Open"}</dd>
          </div>
        </dl>
      </Card>

      <Card title="Counts">
        <div className="grid grid-cols-3 gap-3 text-center">
          <div>
            <p className="text-2xl font-semibold" data-testid="count-booked">{d.booked}</p>
            <p className="text-xs text-slate-500">Booked</p>
          </div>
          <div>
            <p className="text-2xl font-semibold" data-testid="count-marked">{d.marked}</p>
            <p className="text-xs text-slate-500">Marked</p>
          </div>
          <div>
            <p className="text-2xl font-semibold" data-testid="count-unmarked">{d.notMarked.length}</p>
            <p className="text-xs text-slate-500">Not yet marked</p>
          </div>
        </div>
      </Card>

      <Register examId={exam.id} open={d.open} startsAt={exam.startsAt} />

      {closed ? (
        <NameList title="Absent" testId="absent-list" rows={d.absent} names={d.names} empty="Nobody was absent." />
      ) : (
        <NameList title="Not marked yet" testId="unmarked-list" rows={d.notMarked} names={d.names} empty="Everyone booked has been marked." />
      )}
    </div>
  );
}
