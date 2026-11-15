import { PersonSilhouette, TickIcon } from "./Icons";
import { Ringed } from "./Top";
import { QrSvg } from "./Qr";
import s from "./home.module.css";

const EXAMPLE_INDEX = "SE-2027-0142";

const POINTS = [
  { title: "Scanned on arrival", body: "The QR code records attendance as the student enters the hall." },
  { title: "Anonymous marking", body: "Scripts carry the index number, never the student’s name." },
  { title: "Printed in advance", body: "Students print the card from their account before each exam." },
];

/** The index card: the student's ticket into the hall. */
export function IndexCard() {
  return (
    <section id="exam-day" className={s.section} aria-labelledby="card-title">
      <div className={`${s.container} ${s.split} ${s.splitReverse}`}>
        <figure className={s.cardStage} style={{ margin: 0 }}>
          <div className={s.indexCard}>
            <span className={s.cardBrand}>Stem Examspace</span>
            <span className={s.cardPhoto}>
              <PersonSilhouette />
            </span>
            <div>
              <p className={s.cardName}>Alex Example</p>
              <p className={s.cardIndex}>{EXAMPLE_INDEX}</p>
            </div>
            <QrSvg text={EXAMPLE_INDEX} className={s.cardQr} />
            <span className={s.cardFoot}>Bring this card to your exam.</span>
          </div>
          <figcaption className={s.caption}>An example card. Each student prints their own.</figcaption>
        </figure>
        <div>
          <h2 id="card-title" className={s.h2}>
            The candidate <Ringed>index</Ringed> card
          </h2>
          <p className={`${s.lede} ${s.ledeStart}`}>
            Every student is issued an index number and a printed card, as in public examinations. The card is required for entry on exam
            day.
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
      </div>
    </section>
  );
}
