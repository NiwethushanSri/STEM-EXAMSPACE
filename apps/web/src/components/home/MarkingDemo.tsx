"use client";

import { useState } from "react";
import { Pencil } from "./Icons";
import { RedRing, RedTick } from "./Ink";
import s from "./home.module.css";

type Q = { id: string; label: string; got: number; of: number; onPage?: boolean };

const QUESTIONS: Q[] = [
  { id: "q1", label: "Question 1", got: 3, of: 3 },
  { id: "q2", label: "Question 2", got: 4, of: 5 },
  { id: "q3", label: "Question 3", got: 2, of: 4 },
  { id: "q4a", label: "4 (a)", got: 2, of: 2, onPage: true },
  { id: "q4b", label: "4 (b)", got: 1, of: 2, onPage: true },
];

const TOTAL = QUESTIONS.reduce((n, q) => n + q.got, 0);
const MAX = QUESTIONS.reduce((n, q) => n + q.of, 0);

/** The marking screen: the script on the left, the marks on the right. Tapping a mark finds its answer. */
export function MarkingDemo() {
  const [active, setActive] = useState("q4b");

  return (
    <figure className={`${s.tabletFigure} ${s.tabletStage}`}>
      <div className={s.tablet}>
        <Pencil className={s.pencilRest} />
        <div className={s.screen}>
          <div className={s.script}>
            <div className={s.scriptHead}>
              <span>
                Index <b>SE-2027-0142</b>
              </span>
              <span>Name hidden</span>
              <span>Page 3 of 12</span>
            </div>
            <div className={`${s.answerBlock} ${active === "q4a" ? s.answerActive : ""}`}>
              <p className={s.question}>
                <b>4 (a)</b>A car travels 150 m in 12 s. Work out its average speed.
              </p>
              <div className={s.answer}>
                speed = distance ÷ time
                <br />= 150 ÷ 12 = 12.5 m/s
                <RedTick />
                <span className={s.marginMark}>2</span>
              </div>
            </div>
            <div className={`${s.answerBlock} ${active === "q4b" ? s.answerActive : ""}`}>
              <p className={s.question}>
                <b>4 (b)</b>It then slows to a stop in 5 s. Work out its deceleration.
              </p>
              <div className={s.answer}>
                a = 12.5 ÷ 5 = <RedRing>2.5</RedRing>
                <span className={s.redNote}>units?</span>
                <span className={s.marginMark}>1</span>
              </div>
            </div>
          </div>
          <div className={s.panel}>
            <span className={s.panelTitle}>Marks</span>
            <ol>
              {QUESTIONS.map((q) => (
                <li key={q.id}>
                  {q.onPage ? (
                    <button type="button" className={s.markRow} aria-pressed={active === q.id} onClick={() => setActive(q.id)}>
                      <span>{q.label}</span>
                      <span>
                        {q.got} / {q.of}
                      </span>
                    </button>
                  ) : (
                    <span className={s.markRow} data-off="true">
                      <span>{q.label}</span>
                      <span>
                        {q.got} / {q.of}
                      </span>
                    </span>
                  )}
                </li>
              ))}
            </ol>
            <div className={s.panelTotal}>
              <span>Total</span>
              <span>
                {TOTAL} / {MAX}
              </span>
            </div>
          </div>
        </div>
      </div>
    </figure>
  );
}
