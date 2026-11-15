import { TickIcon } from "./Icons";
import { PhoneResult } from "./PhoneResult";
import { Ringed } from "./Top";
import s from "./home.module.css";

const POINTS = [
  { title: "Marks for every question", body: "Exactly where marks were gained, and where they were lost." },
  { title: "The marker’s notes", body: "Specific comments on the answers that need attention." },
  { title: "Forecasts that show where you are heading", body: "Each mock extends the history, and the forecast follows the trend." },
];

/** A plain phone outline: stands in for store logos, which may only be used once the app is live. */
function PhoneGlyph() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="6.5" y="2.5" width="11" height="19" rx="2.5" fill="none" stroke="currentColor" strokeWidth="1.8" />
      <path d="M10.5 18.5h3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  );
}

/** Results arrive on the family's phone: the score, every question, the marker's note and the forecast. */
export function Forecast() {
  return (
    <section id="forecast" className={`${s.section} ${s.soft}`} aria-labelledby="forecast-title">
      <div className={`${s.container} ${s.split}`}>
        <div>
          <h2 id="forecast-title" className={s.h2}>
            Results and analysis in the <Ringed>app</Ringed>
          </h2>
          <p className={`${s.lede} ${s.ledeStart}`}>
            Students and parents receive every result in the Stem Examspace app: the score, marks for each question, the marker’s notes and the
            forecast.
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
          <div className={s.stores} role="group" aria-label="The app is coming soon">
            <span className={s.store}>
              <PhoneGlyph />
              <span>
                <small>Coming soon to</small>
                App Store
              </span>
            </span>
            <span className={s.store}>
              <PhoneGlyph />
              <span>
                <small>Coming soon to</small>
                Google Play
              </span>
            </span>
          </div>
          <p className={s.forecastNote}>A forecast is an estimate from the mocks so far, not a guarantee.</p>
        </div>
        <PhoneResult />
      </div>
    </section>
  );
}
