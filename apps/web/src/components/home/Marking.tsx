import { TickIcon } from "./Icons";
import { MarkingDemo } from "./MarkingDemo";
import { Ringed } from "./Top";
import s from "./home.module.css";

const POINTS = [
  { title: "Anonymous", body: "Markers see the index number, never the student’s name." },
  { title: "Question by question", body: "Every question receives its own mark, with the marker’s notes on the script." },
  { title: "Against the mark scheme", body: "Each answer is judged against the mark scheme, as in the real exam." },
  { title: "Checked", body: "Marking is reviewed before any results are released." },
];

/** How scripts are marked: careful, anonymous and question by question. */
export function Marking() {
  return (
    <section id="marking" className={s.section} aria-labelledby="marking-title">
      <div className={`${s.container} ${s.split}`}>
        <div>
          <h2 id="marking-title" className={s.h2}>
            Every script marked <Ringed>question</Ringed> by question
          </h2>
          <p className={`${s.lede} ${s.ledeStart}`}>
            After the exam, every answer script is marked carefully and consistently, so families receive far more than a single score.
          </p>
          <ul className={s.checks}>
            {POINTS.map((p) => (
              <li key={p.title}>
                <span className={s.checkDot}>
                  <TickIcon />
                </span>
                <div>
                  <strong>{p.title}</strong>
                  <span>{p.body}</span>
                </div>
              </li>
            ))}
          </ul>
        </div>
        <MarkingDemo />
      </div>
    </section>
  );
}
