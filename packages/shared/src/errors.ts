import type { ErrorCode } from "../../../supabase/functions/_shared/errors.ts";

export type { ErrorCode };

/** Shown when GoTrue rejects a sign-in with its "banned" error (suspended staff). */
export const bannedMessage = "Your account is suspended, contact the institution";

const messages: Record<ErrorCode, string> = {
  email_in_use: "An account with this email already exists. Sign in or reset your password.",
  conflict: "This registration was already handled",
  invalid_credentials: "Index number or password is incorrect.",
  rate_limited: "Too many attempts. Try again later.",
  parent_email_is_staff: "The parent email belongs to a staff account. Edit the parent email first.",
  forbidden: "You do not have permission to do that.",
  not_found: "Not found.",
  unauthenticated: "Please sign in again.",
  invalid_input: "Please check the details you entered.",
  internal: "Something went wrong. Please try again.",
  paper_missing: "Your paper is not ready yet. The institution has been told.",
  paper_held: "The paper is paused by the institution. Please wait.",
  roles_not_reviewed: "Your paper is not ready yet. Please contact the institution.",
  paper_not_released: "Your paper is not ready to download yet.",
  paper_closed: "Downloads for this paper have closed.",
  wrong_sitting: "Your booking is for the centre; your paper is handed out in the exam room",
  paper_unreadable: "The paper could not be prepared. Please try again.",
  paper_encrypted: "This PDF is password protected. Remove the password and upload it again.",
  paper_too_large: "This PDF is larger than 20 MB. Make it smaller and upload it again.",
};

/** Fallback copy; a server-provided message takes precedence when present. */
export function messageFor(code: ErrorCode): string {
  return messages[code] ?? messages.internal;
}

/** Failure codes returned by the booking RPCs (create_booking, request_cancellation). */
const bookingMessages: Record<string, string> = {
  choose_sitting: "Choose whether to sit this exam at the centre or at home.",
  choose_centre: "Choose which centre you will sit this exam at.",
  centre_full: "That centre is full. Choose another centre if there is one.",
  sitting_not_offered: "This exam is not offered that way.",
  deadline_passed: "The booking deadline for this exam has passed.",
  not_bookable: "This exam cannot be booked.",
  already_booked: "This student already has a booking for this exam.",
  too_many_unpaid: "You have 3 unpaid bookings. Pay or cancel one before booking another.",
  forbidden: "You do not have permission to do that.",
  invalid_input: "This student cannot be booked. Check that their account is active.",
  conflict: "This booking can no longer be changed. Refresh the page and check its status.",
  not_found: "Not found.",
};

/** Message for a booking RPC failure code; unknown codes get the generic message. */
export function bookingMessageFor(code: string | null | undefined): string {
  return code && Object.hasOwn(bookingMessages, code) ? bookingMessages[code] : messages.internal;
}

/** Which exam or venue RPC a failure code came from; the same code reads differently for each. */
export type ExamContext = "save_exam" | "save_venue" | "set_status";

const examMessages: Record<ExamContext, Record<string, string>> = {
  save_exam: {
    forbidden: "You do not have permission to change this exam. Teachers can only edit draft exams in their own subjects.",
    invalid_input:
      "Check the exam details: the title, start time, duration (15 to 600 minutes), price (up to £1,000) and a booking deadline no later than the start. A published exam cannot be moved into the past. An exam at the centre needs 1 to 20 centres, each with an active venue, one of its rooms and 1 to 1000 seats, and no room used twice; an exam at home has no centres.",
    conflict:
      "This exam cannot be changed that way. It may be cancelled or completed, its subject or price may be locked because it already has bookings, or a centre you removed or shrank still has bookings.",
    not_found: "This exam no longer exists. Refresh the page.",
  },
  save_venue: {
    forbidden: "You do not have permission to change venues.",
    invalid_input:
      "Check the venue: a name of up to 80 characters, and up to 50 rooms of up to 40 characters each, with no repeats.",
    conflict:
      "A venue with that name already exists, or an upcoming exam still uses this venue or a room you removed. Move or cancel those exams first.",
    not_found: "This venue no longer exists. Refresh the page.",
  },
  set_status: {
    forbidden: "You do not have permission to change an exam's status.",
    invalid_input:
      "This exam cannot be published yet: its start time and booking deadline must be in the future, and an exam at the centre needs a centre with an active venue and one of its rooms.",
    conflict: "This exam's status has already changed. Refresh the page to see where it stands.",
    not_found: "This exam no longer exists. Refresh the page.",
  },
};

/** Message for an exam or venue RPC failure code; unknown codes get the generic message. */
export function examMessageFor(code: string | null | undefined, context: ExamContext): string {
  const table = examMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Which admin booking or finance RPC a failure code came from; the same code reads differently for each. */
export type AdminBookingContext = "add" | "mark_paid" | "cancel" | "approve" | "decline" | "finance" | "change_sitting";

const FORBIDDEN = "You do not have permission to do that.";
const REFRESH = "This booking has already changed. Refresh the page to see where it stands.";

const adminBookingMessages: Record<AdminBookingContext, Record<string, string>> = {
  add: {
    forbidden: FORBIDDEN,
    invalid_input: "Check the student: they must be an active student account. A note can be up to 500 characters.",
    not_found: "This exam no longer exists. Refresh the page.",
    not_bookable: "This exam cannot be booked: it must be published, have a confirmed price and not have started.",
    deadline_passed: "The booking deadline has passed, so an unpaid booking cannot be added. Add it as paid instead.",
    already_booked: "This student already has a booking for this exam.",
    choose_sitting: "Choose whether the student sits at the centre or at home.",
    choose_centre: "Choose which centre the student sits at.",
    centre_full: "That centre is full. Choose another centre if there is one.",
    sitting_not_offered: "This exam is not offered that way.",
  },
  mark_paid: {
    forbidden: FORBIDDEN,
    invalid_input: "A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict: REFRESH,
  },
  cancel: {
    forbidden: FORBIDDEN,
    invalid_input: "A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict: REFRESH,
  },
  approve: {
    forbidden: FORBIDDEN,
    invalid_input: "Enter a refund between £0 and the amount still refundable. A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict: REFRESH,
  },
  decline: {
    forbidden: FORBIDDEN,
    invalid_input: "A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict:
      "This request cannot be declined: it may already be decided, or the exam was cancelled so the family is owed a refund. Refresh the page.",
  },
  change_sitting: {
    forbidden: FORBIDDEN,
    invalid_input: "Give a reason of up to 300 characters, and choose a centre of this exam.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict:
      "This booking cannot be moved there: it is already there, its exam is not running, or that register is closed. Refresh the page.",
    choose_centre: "Choose which centre the student sits at.",
    centre_full: "That centre is full. Choose another centre if there is one.",
    sitting_not_offered: "This exam is not offered that way.",
  },
  finance: {
    forbidden: FORBIDDEN,
    invalid_input: "Choose a valid date range: both dates are required and the start cannot be after the end.",
  },
};

/** Message for an admin booking or finance RPC failure code; unknown codes get the generic message. */
export function adminBookingMessageFor(code: string | null | undefined, context: AdminBookingContext): string {
  const table = adminBookingMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Which attendance RPC a failure code came from. */
export type AttendanceContext = "lookup" | "mark" | "close";

const attendanceMessages: Record<AttendanceContext, Record<string, string>> = {
  lookup: {
    not_found: "Not found",
    invalid_input: "Enter an index number.",
    forbidden: "You do not have permission to use this register.",
  },
  mark: {
    not_booked: "No paid booking",
    not_found: "Not found",
    conflict: "This register is closed. Only a published exam can be marked.",
    forbidden: "You do not have permission to use this register.",
  },
  close: {
    conflict: "The register cannot be closed yet. The exam must be published and already started.",
    not_found: "Not found",
    forbidden: "You do not have permission to use this register.",
  },
};

/** Message for an attendance RPC failure code; unknown codes get the generic message. */
export function attendanceMessageFor(code: string | null | undefined, context: AttendanceContext): string {
  const table = attendanceMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Failure codes returned by the home upload RPCs (home_submission_open, script_upload_begin, script_upload_stored,
 * home_submission_submit and the "Needs your attention" answers). */
const uploadMessages: Record<string, string> = {
  uploads_not_open: "You can upload your answers once the exam has started.",
  uploads_closed: "Uploads for this exam have closed. Please contact the institution.",
  too_many_files: "You can hand in at most 60 files. Delete some, or put the pages into one PDF.",
  too_many_files_total:
    "Too many files have been added and deleted in this hand-in (120 at most). Press Submit to send the pages you have; you can then replace pages.",
  file_too_large: "This file is too large. Photos can be up to 25 MB and PDFs up to 100 MB.",
  wrong_file_type: "This file cannot be used. Upload a PDF, or photos as JPEG, PNG or HEIC.",
  still_uploading: "Some files are still uploading. Wait until every file shows as uploaded, or delete it.",
  nothing_to_submit: "Add at least one photo or PDF before you submit.",
  wrong_sitting: "Your booking is for the centre; your answers are collected in the exam room.",
  script_locked: "Your answers are already being marked.",
  not_found: "The file did not arrive. Please try again.",
  invalid_input: "That did not work. Please check and try again.",
  conflict: "This has already changed. Refresh the page to see where it stands.",
  forbidden: "You do not have permission to do that.",
};

/** Message for a home upload RPC failure code; unknown codes get the generic message. */
export function uploadMessageFor(code: string | null | undefined): string {
  return code && Object.hasOwn(uploadMessages, code) ? uploadMessages[code] : messages.internal;
}

/** Which collection or custody RPC a failure code came from. */
export type CollectionContext = "record" | "manifest" | "custody";

const CENTRE_REMOVED = "This centre is no longer part of this exam. Refresh the page.";

const collectionMessages: Record<CollectionContext, Record<string, string>> = {
  record: {
    not_present: "Only a candidate marked present or late has sheets to count.",
    invalid_input: "Enter a whole number of extra sheets from 0 to 50.",
    not_found: "Not found",
    forbidden: "You do not have permission to use this register.",
    conflict: CENTRE_REMOVED,
  },
  manifest: {
    conflict: "This exam already has 99 manifests, or this centre is no longer part of this exam.",
    not_found: "Not found",
    forbidden: "You do not have permission to use this register.",
  },
  custody: {
    invalid_input: "Choose the step, say where, and name who or add a note. The place can be up to 120 characters and the note up to 300.",
    invalid_staff: "Choose staff members with an active account.",
    not_found: "Not found",
    forbidden: "You do not have permission to use this register.",
    conflict: CENTRE_REMOVED,
  },
};

/** Message for a collection, manifest or custody RPC failure code; unknown codes get the generic message. */
export function collectionMessageFor(code: string | null | undefined, context: CollectionContext): string {
  const table = collectionMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Which scan batch RPC a failure code came from. */
export type ScanContext = "create" | "upload" | "submit" | "complete";

const scanMessages: Record<ScanContext, Record<string, string>> = {
  create: {
    forbidden: FORBIDDEN,
    invalid_input: "Check the manifest number and try again.",
    not_found: "This centre is not part of this exam. Refresh the page.",
    conflict: "This centre is no longer part of this exam, or the exam already has 99 scan batches.",
    unknown_manifest: "No manifest has that number. Check the number printed on the manifest.",
    other_manifest: "That manifest belongs to another centre or exam.",
  },
  upload: {
    forbidden: FORBIDDEN,
    invalid_input: "That file could not be added. Please try again.",
    not_found: "The file did not arrive. Please try again.",
    conflict: "Processing has already started for this batch. Make a new scan batch for more files.",
    wrong_file_type: "This file cannot be used. Upload scans as PDF, JPEG or PNG.",
    file_too_large: "This file is larger than 1 GB. Split the scan into smaller files.",
  },
  submit: {
    forbidden: FORBIDDEN,
    not_found: "This batch no longer exists. Refresh the page.",
    nothing_to_submit: "Upload at least one file before you start processing.",
  },
  complete: {
    forbidden: FORBIDDEN,
    not_found: "This centre is not part of this exam. Refresh the page.",
    conflict: "This centre is no longer part of this exam. Refresh the page.",
    still_processing:
      "Some scans of this centre are still uploading or being processed. Start processing every batch and wait until it has finished.",
  },
};

/** Message for a scan batch RPC failure code; unknown codes get the generic message. */
export function scanMessageFor(code: string | null | undefined, context: ScanContext): string {
  const table = scanMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Failure codes of the exception queue (script_exception_* and script_late_decide, script_page_set_hidden_areas). A
 * conflict answer also names who resolved it and when; the screen adds that. */
const exceptionMessages: Record<string, string> = {
  forbidden: FORBIDDEN,
  reason_required: "Give a reason of 3 to 300 characters.",
  invalid_input: "Check the details: choose a page within the candidate's copy, or pages listed as missing, and areas inside the page.",
  not_found: "This could not be found. Refresh the page.",
  conflict: "This has already been resolved. Refresh the page to see how.",
  wrong_kind: "That action does not fit this kind of problem.",
  other_exam: "That candidate is booked for another exam.",
  booking_not_active: "That candidate's booking is not paid, or has been cancelled.",
  wrong_sitting: "That candidate sits this exam elsewhere: a scanned page goes to a candidate at the centre, a page handed in from home to a candidate at home.",
  not_present: "That candidate is not marked present or late on the register. Correct the register first.",
  in_other_script: "This page is already in another candidate's script.",
  script_locked: "That candidate's script is already being marked, so its pages cannot change here.",
  page_replaced: "This file has been processed again. Refresh the page.",
  still_mixed: "The script still shows pages from two versions of the paper. Make its pages one version first.",
  not_late: "This script was not handed in late.",
  name_not_hidden: "Hide the candidate's name on the page first, or tick \"There is no name on this page\".",
  name_area_required: "This page has a printed name box. Draw a box over the name before confirming.",
  other_family: "A page handed in by one family can only go to that family's own bookings, not to another family's.",
};

/** Message for an exception queue RPC failure code; unknown codes get the generic message. */
export function exceptionMessageFor(code: string | null | undefined): string {
  return code && Object.hasOwn(exceptionMessages, code) ? exceptionMessages[code] : messages.internal;
}

/** Failure codes of the script repository (script_page_rotate, script_upload_reprocess, script_void,
 * script_page_remove, scripts_list, script_detail). A conflict says why in `reason`. */
const scriptMessages: Record<string, string> = {
  forbidden: FORBIDDEN,
  reason_required: "Give a reason of 3 to 300 characters.",
  invalid_input: "Check the details and try again.",
  not_found: "This could not be found. Refresh the page.",
  page_replaced: "This file has been processed again. Refresh the page.",
  script_locked: "This script is being marked or has been marked, so its pages can no longer change.",
};
const scriptConflicts: Record<string, string> = {
  busy: "This file is already waiting to be processed, or is being processed now. Wait until it has finished.",
  void: "This script is already void.",
  changed: "This script changed while you were working. Refresh the page and try again.",
  // Taking a script back from the markers and handing it back (marking_script_take_back, marking_script_hand_back).
  not_marking: "This script is not being marked, so there is nothing to take back.",
  taken_back: "This script is already taken back from the markers.",
  not_taken_back: "This script is not taken back from the markers.",
  not_verified: "The script must be verified before it goes back to the markers. Settle its open problems first.",
  pictures_updating: "Its marking pictures are being made again. Hand it back when they are ready.",
};

/** Message for a script repository RPC failure code (and a conflict's reason); unknown codes get the generic message. */
export function scriptMessageFor(code: string | null | undefined, reason?: string | null): string {
  if (code === "conflict") return reason && Object.hasOwn(scriptConflicts, reason) ? scriptConflicts[reason] : scriptConflicts.changed;
  return code && Object.hasOwn(scriptMessages, code) ? scriptMessages[code] : messages.internal;
}

/** Which exam structure RPC a failure code came from: the questions and mark scheme (exam_structure_get and
 * exam_structure_save) or the mark scheme PDF (mark_scheme_file_*). Marking open (Task 4) also answers
 * structure_incomplete. */
export type StructureContext = "save" | "file";

const STRUCTURE_LOCKED = "Marking has started, so this can no longer be changed.";

const structureMessages: Record<StructureContext, Record<string, string>> = {
  save: {
    structure_locked: STRUCTURE_LOCKED,
    structure_incomplete: "Finish the questions and their marks first.",
    forbidden: FORBIDDEN,
    reason_required: "Give a reason of 3 to 300 characters.",
    invalid_input:
      "Check the questions: each needs a label and a maximum, on answer or spare pages of this paper, and optional questions must be out of the same total.",
    conflict: "A maximum cannot go below a mark a marker has already given.",
    not_found: "This exam no longer exists. Refresh the page.",
  },
  file: {
    structure_locked: STRUCTURE_LOCKED,
    forbidden: FORBIDDEN,
    reason_required: "Give a reason of 3 to 300 characters.",
    invalid_input: "That file could not be added. Please try again.",
    not_found: "The file did not arrive. Please try again.",
    conflict: "This PDF has already been replaced or removed. Refresh the page.",
    file_too_large: "This PDF is larger than 20 MB. Make it smaller and upload it again.",
  },
};

/** Message for an exam structure or mark scheme PDF RPC failure code; unknown codes get the generic message. */
export function structureMessageFor(code: string | null | undefined, context: StructureContext): string {
  const table = structureMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Failure codes of marker approvals, lead markers and declared conflicts (markers_list, marker_*). */
const markerMessages: Record<string, string> = {
  forbidden: FORBIDDEN,
  reason_required: "Give a reason of 3 to 300 characters.",
  invalid_input: "Check the details. A note can be up to 300 characters, and a conflict is about a candidate who is a student.",
  not_found: "This could not be found. Refresh the page.",
  not_approved: "This person cannot be approved to mark this subject.",
  conflict_of_interest: "This marker cannot mark this candidate.",
};

/** Message for a marker RPC failure code; unknown codes get the generic message. */
export function markerMessageFor(code: string | null | undefined): string {
  return code && Object.hasOwn(markerMessages, code) ? markerMessages[code] : messages.internal;
}

/** Failure codes of opening and closing marking for an exam (marking_settings_set, marking_exam_get, marking_open,
 * marking_close, marking_reopen); marking_not_open and marking_closed are also what hand-out answers. */
const markingMessages: Record<string, string> = {
  forbidden: FORBIDDEN,
  reason_required: "Give a reason of 3 to 300 characters.",
  invalid_input: "Check the details. The marking deadline must be after the exam finishes.",
  not_found: "This exam no longer exists. Refresh the page.",
  conflict: "Marking has opened, so how this exam is marked can no longer change.",
  structure_incomplete:
    "Finish the questions and their marks first. When marking by question, every question must be in a group.",
  no_markers: "Approve at least one marker for this subject first.",
  marking_not_open: "Marking has not opened for this exam.",
  marking_closed: "Marking has closed for this exam.",
};

/** Message for a marking open or close RPC failure code; unknown codes get the generic message. */
export function markingMessageFor(code: string | null | undefined): string {
  return code && Object.hasOwn(markingMessages, code) ? markingMessages[code] : messages.internal;
}

/** Who a marking allocation code is shown to: a marker ("Next script", giving a script back, their own list; the
 * marking screen's hold_expired) or an admin (assigning, taking back and reassigning scripts, and the codes of the
 * scripts an assignment skipped). */
export type AllocationContext = "marker" | "admin";

const allocationMessages: Record<AllocationContext, Record<string, string>> = {
  marker: {
    forbidden: FORBIDDEN,
    invalid_input: "Check the details. A reason can be 3 to 300 characters.",
    not_found: "This could not be found. Refresh the page.",
    not_approved: "You are not approved to mark this subject. Ask an admin.",
    marking_not_open: "Marking has not opened for this exam.",
    marking_closed: "Marking has closed for this exam.",
    nothing_left: "Nothing left to mark for now.",
    hold_expired: "Your hold on this script has ended. Press Next script to carry on.",
  },
  admin: {
    forbidden: FORBIDDEN,
    reason_required: "Give a reason of 3 to 300 characters.",
    invalid_input: "Choose 1 to 200 scripts and a marker.",
    not_found: "This could not be found. Refresh the page.",
    not_approved: "This marker is not approved to mark this subject.",
    conflict_of_interest: "This marker cannot mark this candidate.",
    marking_not_open: "Marking has not opened for this exam.",
    marking_closed: "Marking has closed for this exam.",
    taken: "A marker already has this script. Take it back or reassign it.",
    submitted: "This script has been marked. Take it back or reassign it.",
    on_hold: "This script is on hold.",
    not_ready: "This script cannot be handed out yet.",
    not_eligible: "This script cannot be given to this marker.",
  },
};

/** Message for a marking allocation RPC failure code (marking_next, marking_give_back, marking_assign,
 * marking_assign_some, marking_take_back, marking_reassign, marking_my_work, marking_units_list, marking_progress), or
 * the code of a script an assignment skipped; unknown codes get the generic message. */
export function allocationMessageFor(code: string | null | undefined, context: AllocationContext): string {
  const table = allocationMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Failure codes of the marking screen (marking_unit_open, marking_save, marking_submit). A conflict says why in
 * `reason`: rev (another screen saved first), set_aside (the script is no longer the marker's) or submitted (it
 * already was). */
const markingWorkMessages: Record<string, string> = {
  forbidden: FORBIDDEN,
  invalid_input: "This change could not be saved. Reload to carry on.",
  not_found: "This script could not be found. Go back to your list.",
  reason_required: "Give a reason of 3 to 300 characters.",
  hold_expired: "Your hold on this script has ended. Press Next script to carry on.",
  on_hold: "This script is on hold. The lead marker has been told.",
  pictures_updating: "This script's pictures are being updated. Your work is saved. Try again in a few minutes.",
  marking_closed: "Marking has closed for this exam.",
  incomplete: "Give every question a mark, or NR, before you submit.",
  mark_out_of_range: "That mark is not allowed for this question.",
};
const markingWorkConflicts: Record<string, string> = {
  rev: "This script was changed on another screen. Reload to carry on.",
  set_aside: "This script is no longer yours to mark. Press Next script to carry on.",
  submitted: "This script has already been submitted.",
};

/** Message for a marking screen RPC failure code (and a conflict's reason); unknown codes get the generic message, and
 * a conflict without a known reason is read as another screen's save. */
export function markingWorkMessageFor(code: string | null | undefined, reason?: string | null): string {
  if (code === "conflict") {
    return reason && Object.hasOwn(markingWorkConflicts, reason) ? markingWorkConflicts[reason] : markingWorkConflicts.rev;
  }
  return code && Object.hasOwn(markingWorkMessages, code) ? markingWorkMessages[code] : messages.internal;
}

/** The marking screen's one entry point for every code it can meet: opening, saving and submitting a piece
 * (marking_unit_open, marking_save, marking_submit), reporting a name (marking_name_visible: invalid_input, not_found,
 * forbidden) and the marker's allocation codes (marking_next, marking_give_back). A conflict says why in `reason`.
 * markingMessageFor stays the exam settings' messages (Task 4): its codes mean other things there. */
export function markingScreenMessageFor(code: string | null | undefined, reason?: string | null): string {
  if (code === "conflict" || (code && Object.hasOwn(markingWorkMessages, code))) return markingWorkMessageFor(code, reason);
  return allocationMessageFor(code, "marker");
}

/** Why an open picture_changed alert cannot be released yet: the reason marking_alert_can_release gives, which
 * marking_alerts_list returns as release_blocked and marking_alert_release answers as a conflict's reason. */
const releaseBlocked: Record<string, string> = {
  taken_back: "Release waits until staff hand the script back to the markers.",
  pictures_updating: "Release waits until the new marking pictures are made.",
  picture_missing: "Release waits until every page has a marking picture.",
  picture_unchecked: "Release waits for a staff check of the new marking picture.",
};

/** One plain sentence for why Release is not offered; an unknown reason gets a general one. */
export function releaseBlockedMessage(reason: string | null | undefined): string {
  return reason && Object.hasOwn(releaseBlocked, reason) ? releaseBlocked[reason] : "This cannot be released yet.";
}

/** Failure codes of releasing and noting marking alerts (marking_alert_release, marking_alerts_release_all,
 * marking_alert_note, marking_alerts_list). A conflict says why in `reason`: closed, or what holds a release back. */
const alertMessages: Record<string, string> = {
  forbidden: FORBIDDEN,
  reason_required: "Give a reason of 3 to 300 characters.",
  invalid_input: "Check the details and try again.",
  not_found: "This alert could not be found. Refresh the page.",
  wrong_kind: "That action does not fit this kind of alert.",
};

/** Message for a marking alert RPC failure code (and a conflict's reason); unknown codes get the generic message. */
export function alertMessageFor(code: string | null | undefined, reason?: string | null): string {
  if (code === "conflict") return reason === "closed" ? "This alert is already closed. Refresh the page." : releaseBlockedMessage(reason);
  return code && Object.hasOwn(alertMessages, code) ? alertMessages[code] : messages.internal;
}
