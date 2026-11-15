import { AnalysisDemo } from "./AnalysisDemo";
import { Ringed } from "./Top";
import s from "./home.module.css";

/** The student analysis: what parents look at most, shown working. */
export function Analysis() {
  return (
    <section id="analysis" className={`${s.section} ${s.soft}`} aria-labelledby="analysis-title">
      <div className={s.container}>
        <h2 id="analysis-title" className={`${s.h2} ${s.center}`}>
          Detailed <Ringed>analysis</Ringed> after every mock
        </h2>
        <p className={`${s.lede} ${s.center}`}>
          Every paper is broken down by question and topic, compared with the cohort and tracked over time, so you can see exactly where marks
          are being gained and lost.
        </p>
        <AnalysisDemo />
      </div>
    </section>
  );
}
