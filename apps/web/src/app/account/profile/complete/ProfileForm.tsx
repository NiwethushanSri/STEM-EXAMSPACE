"use client";

import { useRouter } from "next/navigation";
import { useState, type ChangeEvent, type FormEvent } from "react";
import { messageFor } from "@stem/shared";
import { inputClass, labelClass } from "@/components/AuthLayout";
import { createClient } from "@/lib/supabase/client";

const YEAR_GROUPS = ["Year 10", "Year 11", "Year 12", "Year 13", "University applicant"];
const GENDERS = ["Female", "Male", "Prefer not to say"];
const MAX_PHOTO_BYTES = 5 * 1024 * 1024;

export function ProfileForm({ userId, subjects }: { userId: string; subjects: { id: number; name: string }[] }) {
  const router = useRouter();
  const [picked, setPicked] = useState<number[]>([]);
  const [photo, setPhoto] = useState<File | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  function onPhoto(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0] ?? null;
    if (file && (file.type !== "image/jpeg" || file.size > MAX_PHOTO_BYTES)) {
      e.target.value = "";
      setPhoto(null);
      setError("Photo must be a JPEG under 5 MB");
      return;
    }
    setError(null);
    setPhoto(file);
  }

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (picked.length === 0) {
      setError("Choose at least one subject.");
      return;
    }
    const form = new FormData(e.currentTarget);
    const supabase = createClient();
    setBusy(true);
    setError(null);

    let photoPath: string | undefined;
    if (photo) {
      photoPath = `${userId}/photo.jpg`;
      const { error: upErr } = await supabase.storage
        .from("student-photos")
        .upload(photoPath, photo, { contentType: photo.type, upsert: true });
      if (upErr) {
        setBusy(false);
        setError("The photo could not be uploaded. Try again or leave it out.");
        return;
      }
    }

    const { error: rpcErr } = await supabase.rpc("complete_profile", {
      p_gender: String(form.get("gender") ?? ""),
      p_year_group: String(form.get("year") ?? ""),
      p_subject_ids: picked,
      p_parent_phone: String(form.get("phone") ?? ""),
      ...(photoPath ? { p_photo_path: photoPath } : {}),
    });
    if (rpcErr) {
      setBusy(false);
      setError(rpcErr.code === "P0001" ? messageFor("invalid_input") : messageFor("internal"));
      return;
    }
    router.replace("/account/home");
    router.refresh();
  }

  return (
    <form onSubmit={submit} className="space-y-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label htmlFor="gender" className={labelClass}>Gender</label>
          <select id="gender" name="gender" required defaultValue="" className={inputClass}>
            <option value="" disabled>Select</option>
            {GENDERS.map((g) => <option key={g}>{g}</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="year" className={labelClass}>Year group</label>
          <select id="year" name="year" required defaultValue="" className={inputClass}>
            <option value="" disabled>Select</option>
            {YEAR_GROUPS.map((g) => <option key={g}>{g}</option>)}
          </select>
        </div>
      </div>

      <fieldset>
        <legend className={labelClass}>Subjects you plan to sit</legend>
        <div className="mt-2 flex flex-wrap gap-2">
          {subjects.map((s) => {
            const on = picked.includes(s.id);
            return (
              <label
                key={s.id}
                className={`cursor-pointer rounded-full focus-within:ring-2 focus-within:ring-blue-300 px-3 py-1.5 text-sm transition ${
                  on ? "bg-blue-600 text-white" : "border border-slate-300 text-slate-700 hover:border-blue-400"
                }`}
              >
                <input
                  type="checkbox"
                  className="sr-only"
                  checked={on}
                  onChange={() => setPicked((p) => (on ? p.filter((x) => x !== s.id) : [...p, s.id]))}
                />
                {s.name}
              </label>
            );
          })}
        </div>
      </fieldset>

      <div>
        <label htmlFor="phone" className={labelClass}>Parent phone</label>
        <input id="phone" name="phone" type="tel" required autoComplete="tel" className={inputClass} />
      </div>

      <div>
        <label htmlFor="photo" className={labelClass}>Photo (optional)</label>
        <input id="photo" type="file" accept="image/jpeg" onChange={onPhoto} className="mt-1 block w-full text-sm text-slate-600" />
        <p className="mt-1 text-xs text-slate-500">JPEG, up to 5 MB.</p>
      </div>

      {error && <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}

      <button
        type="submit"
        disabled={busy}
        className="w-full rounded-lg bg-blue-600 px-4 py-3 font-semibold text-white shadow-md transition hover:bg-blue-700 disabled:opacity-60"
      >
        {busy ? "Saving..." : "Save and continue"}
      </button>
    </form>
  );
}
