import { ArrowIcon } from "./Icons";
import { Ringed } from "./Top";
import s from "./home.module.css";

/** Only answers the product can stand behind today. */
const FAQ = [
  {
    q: "Who can book a seat?",
    a: "A parent or guardian books from their own parent account, which is linked to their child. Older students can also book for themselves from their own account.",
  },
  {
    q: "Do I need an account?",
    a: "Yes. Register, open the link we email you, and an admin checks and approves the account. After that you can book any paper with seats left.",
  },
  {
    q: "Can I cancel a booking?",
    a: "Yes. Before it is paid, you can cancel it yourself from My bookings and the seat is released. Once paid, use “Request cancellation” and we will take it from there.",
  },
  {
    q: "Is the exam in person or online?",
    a: "Each paper on the timetable says which. In-person papers are sat at a single desk in our exam hall, timed like the real exam.",
  },
  {
    q: "What should I bring on the day?",
    a: "Your index card, printed from your account: it is scanned at the door to check you in. Bring the same equipment you would take to the real exam.",
  },
  {
    q: "Who sees my child’s name while marking?",
    a: "No one marking the paper. Scripts carry the index number only, so marking is anonymous.",
  },
];

export function Faq() {
  return (
    <section id="faq" className={s.section} aria-labelledby="faq-title">
      <div className={`${s.container} ${s.faqWrap}`}>
        <h2 id="faq-title" className={`${s.h2} ${s.center}`}>
          Questions, <Ringed>answered</Ringed>
        </h2>
        <div className={s.faq}>
          {FAQ.map((item) => (
            <details key={item.q} className={s.faqItem}>
              <summary>
                {item.q}
                <span className={s.faqIcon} aria-hidden="true" />
              </summary>
              <p>{item.a}</p>
            </details>
          ))}
        </div>
        <p className={`${s.center} ${s.faqMore}`}>
          Anything else?{" "}
          <a href="mailto:hello@stemexamspace.co.uk" className={s.textLink}>
            Email hello@stemexamspace.co.uk <ArrowIcon />
          </a>
        </p>
      </div>
    </section>
  );
}
