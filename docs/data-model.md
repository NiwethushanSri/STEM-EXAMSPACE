# Stem Examspace data model

Source: the "Mock Exam System" UML diagram (use case, class, and sequence diagrams).

## Roles
`UserRole`: PARENT, STUDENT, ADMIN, EXAMINER

## Entities
- **User**: userId, name, email, password, role. Subtypes: Parent (view results, receive notifications), Student (take exam, view graph and comments, receive notifications), Admin (manage subjects, create exam, manage users, view reports), Examiner (mark exam, upload answers).
- **Subject**: subjectId, name. Current list: Maths, Further Maths, Physics, Chemistry, Biology, CS.
- **Exam**: examId, title, month, type (`ExamType`: ONLINE, FACE_TO_FACE), dateTime. Has 1..* Question.
- **Question**: questionId, content, marks, type.
- **Submission**: submissionId, status, submittedAt. Belongs to an Exam per student. Has 0..* Answer.
- **Answer**: answerId, content, fileUrl, submittedAt. Physical papers are scanned and stored as fileUrl.
- **Marking**: markingId, marks, comment, markedAt, markedBy (the examiner). One per answer or question.
- **Result**: resultId, totalMarks, percentage, grade, highLowAvg. One per submission.
- **Report**: reportId, examId, subjectId, highScore, lowScore, averageScore. Generated per exam.
- **Notification**: notificationId, userId, message, type, isRead, createdAt.

## Added from the handwritten notes (not in the UML)
- **User profile fields:** DOB, school, gender, grade, index number, and parent details (linked parent to student).
- **Registration and approval:** student self-registration, admin approval before login.
- **Exam format:** online or physical (`ExamType`). Physical papers need paper allocation.
- **Paper allocation:** admin assigns physical or online papers to examiners.
- **Timetable and calendar:** exam schedule per subject, shown to students and parents.
- **Attendance:** exam attendance records and index-number scanning check. Entity: AttendanceRecord (studentId, examId, status). Admin sees attendance sheet and "attendance not marked" list.
- **Booking and payment:** exam booking and payment per student or per exam.
- **Results analytics:** per-test marks, class average, highest and lowest. Weak areas identified from the student's exam paper (per-question performance by topic).
- **Automatic exam alert:** notification sent to student before an exam.
- **Student messaging:** student receives notifications and messages.
- **Notices:** latest notice (all users) and special notice (targeted).
- **Feedback:** student feedback sent to admin after all papers are marked. Parent sees child's feedback.
- **Marking progress:** tutor marking progress tracking. Admin view per examiner.
- **Grid marking view:** grid of responses with marking comments, shown in the examiner tool.
- **Audit log:** record of admin and examiner actions.
- **University entrance exams:** TMUA, FSAT, UCAT, plus "add subject" for custom exams. Exam practice mode.
- **Subjects:** add Computer Science (confirmed in notes), Maths, Further Maths, Physics, Chemistry, Biology.

## Key flows
1. Online exam: student logs in, gets exam, starts, submits answers, submission is saved, student gets a confirmation.
2. Manual marking: examiner marks the submission, marks and comments are saved, then the student and parent are notified.
3. Parent results: parent logs in, views child results (high, low, average), sees graph and comments. If the exam is complete, the parent is notified.

## Notes
- The Examiner screen mirrors the marking workflow: worklist, response viewer, per-question marks, annotations, and standardisation against seed responses. Stem Examspace branding only.
- Mock data lives in `src/lib/mock-data.ts` until a database is chosen.
