/**
 * Not a unit test - a rendering harness for the three sign-in doors.
 *
 * WHAT CANNOT BE ASSERTED, AND IS THE WHOLE POINT
 *
 * Whether a parent opening this on a phone in Rawalpindi can tell that the page
 * is for them. That is a question about wording, weight and what the eye lands
 * on, and no assertion can hold it. What a test CAN hold is in
 * web/src/test/pages.smoke.test.tsx: that the price is absent from the parent
 * door, that the trial link is absent, and that the office door still points a
 * parent at theirs.
 *
 * The old page is rendered first, deliberately, because the critique is a
 * comparison. It showed every visitor a dashboard mockup, three selling points
 * and "From Rs 2,000 a month", and on a phone the price was the one thing that
 * survived the collapse. See web/src/auth/doors.ts.
 *
 * Run with `npm run harness -- doors`.
 */
import { it } from 'vitest'
import { Login } from '../src/pages/Login'
import { Signup } from '../src/pages/Signup'
import { OFFICE_DOOR, PARENT_DOOR, OPERATOR_DOOR } from '../src/auth/doors'
import { writePage } from './harness'

it('renders each door, at desktop and at phone width', () => {
  writePage('../scratch/doors.html', [
    {
      caption: 'THE OFFICE DOOR, /login. Unchanged address, because every bookmark, '
        + 'every ProtectedRoute redirect and every "Sign in" link on the website '
        + 'lands here. What changed: the column says what is BEHIND the door '
        + 'instead of what it costs, there is a sentence saying what to do if you '
        + 'do not know your details, the reset link carries the truth about '
        + 'invented addresses, and a full-width BUTTON opens the parent portal '
        + 'without turning anybody away. It was one line of 12px grey text at '
        + 'the foot of a stack of four others, and a school reported that '
        + 'parents sent to this door could not find it.',
      profile: null,
      node: <Login door={OFFICE_DOOR} />,
    },
    {
      caption: 'THE PARENT DOOR, /parents. No price anywhere on it, no dashboard '
        + 'mockup, and no trial link: that link was the only prominent alternative '
        + 'to the form, so it is what a parent who cannot get in presses, and it '
        + 'works - they get a whole new school and become its owner. In its place, '
        + 'the answer to the question parents actually ask the office: there is '
        + 'nothing here for you to buy. Under the form, the sentence that says '
        + 'where an account comes from at all, which is the school and only the '
        + 'school; at the foot, the way to the office door as a button.',
      profile: null,
      node: <Login door={PARENT_DOOR} />,
    },
    {
      caption: 'THE OPERATOR DOOR, /operator. Deliberately the plainest page in the '
        + 'product: no column at any width, no mockup, no price, no trial. There is '
        + 'nobody to persuade, and an austere page is also the one least likely to '
        + 'be mistaken for a school’s own sign-in. The one thing it adds is the '
        + 'way out for a school owner who found the address, because a person at '
        + 'the wrong door should be redirected by a signpost and never by a '
        + 'refusal.',
      profile: null,
      node: <Login door={OPERATOR_DOOR} />,
    },
    {
      // THE REAL SIGNUP PAGE, not the sign-in form wearing the signup door.
      // The first version of this harness rendered <Login door={SIGNUP_DOOR}>,
      // which put a "Sign in" button under "Start your free trial" and showed a
      // page that does not exist. A preview that shows something the product
      // cannot produce is worse than no preview: it is what somebody judges the
      // design by.
      caption: 'AND THE ONE PAGE THE SELLING COLUMN BELONGS ON: /signup, where a '
        + 'school buyer really is standing at the keyboard. The mockup, the three '
        + 'selling lines and the price table are unchanged here. That is the '
        + 'comparison the critique rests on: the same column, on the same layout, '
        + 'addressed for the first time to the person it was written for.',
      profile: null,
      node: <Signup />,
      // THE PRICE LIST, SEEDED, because the plan chooser is the thing this
      // page gained in 0127 and an unseeded query renders its "we could not
      // load the plans" fallback. Both states matter and both are worth
      // looking at, so the case below renders the same page without it.
      seeds: [[['signupPlans'], [
        { code: 'starter', name: 'Starter (up to 150 students)', student_limit: 150,
          terms: [{ months: 1, amount: 2000, saving: 0 },
                  { months: 3, amount: 5700, saving: 300 },
                  { months: 12, amount: 20000, saving: 4000 }] },
        { code: 'growth', name: 'Growth (151-350 students)', student_limit: 350,
          terms: [{ months: 1, amount: 3500, saving: 0 },
                  { months: 3, amount: 10000, saving: 500 },
                  { months: 12, amount: 35000, saving: 7000 }] },
        { code: 'institution', name: 'Institution (351-600 students)', student_limit: 600,
          terms: [{ months: 1, amount: 5500, saving: 0 },
                  { months: 3, amount: 15700, saving: 800 },
                  { months: 12, amount: 55000, saving: 11000 }] },
      ]]],
    },
    {
      caption: 'THE SAME PAGE WHEN THE PRICE LIST WILL NOT LOAD. A signup form '
        + 'that refuses to submit because a price could not be fetched loses a '
        + 'customer over a network blip, so it says what it can and gets out of '
        + 'the way: the school is created on a 14-day trial either way and can '
        + 'pick the plan from Settings.',
      profile: null,
      node: <Signup />,
    },
  ])
})
