# Photographs — the one manual check

Everything in this feature is tested automatically **except** the part that only
exists on a real Supabase project: the bucket row, its size and mime limits, and
the signed-URL flow. `supabase/tests/photos.sql` proves the four storage policies
isolate one school from another, because those policies are ordinary SQL and can
be exercised against a faithful stub. It cannot prove that Supabase's storage API
consults them, because there is no storage API in a test database.

So there is exactly one thing to check by hand, once, on the live project. It
takes about ten minutes. Do it before a school's photographs matter.

## Before you start

You need **two** logins in **two different schools**. If you only have one
school, sign up a second throwaway school first — a single-school test cannot
detect a cross-school leak, which is the whole point of this check. Call them
**School A** and **School B**.

Have ready:

- one ordinary photo from a phone (2–5 MB is ideal — that is the normal case)
- one file larger than 2 MB that is **not** an image (any PDF will do)

---

## 1. The bucket exists and is private

Supabase dashboard → **Storage**.

- [ ] A bucket named **`school-files`** is listed.
- [ ] It is marked **Private**, not Public.

If it says Public, stop. A public bucket means anyone holding a link can see a
child's photograph, forever, with no login, including after they have left the
school. Fix it before going further: the bucket is created by migration 0057, so
the likeliest cause is that somebody changed it afterwards in the dashboard.

## 2. A photograph uploads and appears

Signed in as **School A** (owner, principal or clerk):

- [ ] Students → open any pupil → **Add photograph** → choose the phone photo.
- [ ] The face appears within a few seconds.
- [ ] Reload the page. The face is still there.
- [ ] Reports → **Class Photo Sheet** → that pupil's class. The same face is in
      the grid, and the header says how many pupils still have no photograph.

## 3. The limits are enforced by the SERVER, not the browser

- [ ] Try to add the **PDF** as a pupil's photograph. It is refused, with a
      message naming what to use instead.

That one is refused by the browser. The server-side limit is the one that
matters, and you can check it from the Storage screen:

- [ ] Storage → `school-files` → **Configuration** (or the bucket's settings).
- [ ] Allowed MIME types are exactly `image/jpeg`, `image/png`, `image/webp`.
- [ ] File size limit is **2 MB** (2097152 bytes).

`image/svg+xml` must **not** be there. An SVG can carry script and would be
served from the same origin as the app.

## 4. THE IMPORTANT ONE — School B cannot reach School A's photographs

Still with School A's pupil photographed:

- [ ] Copy the pupil's photo URL. In the browser, right-click the face →
      *Copy image address*. It will look like
      `…/storage/v1/object/sign/school-files/students/<uuid>/<uuid>.jpg?token=…`
- [ ] Note the two UUIDs in the path. The **first** is School A's id, the second
      the pupil's.

Now, in a **private/incognito window**, sign in as **School B**:

- [ ] Paste the copied URL. It **should still work** — a signed URL is a bearer
      token and works for whoever holds it until it expires. That is expected,
      and it is why the app never stores one and why they last 30 minutes.
- [ ] Now strip the `?token=…` part and load just
      `…/storage/v1/object/school-files/students/<A-school-uuid>/<pupil-uuid>.jpg`.
      This **must fail** with a permission error, not show the photograph.

That second request is the real test: it is School B's session asking storage
directly for School A's object, which is exactly what a curious or malicious
customer would try.

- [ ] Also confirm the reverse: photograph a pupil in **School B**, then from
      **School A** try the same trick against School B's path. It must fail too.

Testing one direction only would pass on a policy that happened to be scoped to
whichever school was created first.

## 5. School B cannot WRITE into School A's folder

This needs the browser console, and it is worth the two minutes because a write
is worse than a read: it would replace a child's photograph.

Signed in as **School B**, open the browser console on any app page and run:

```js
// Substitute School A's school-uuid and one of its pupil-uuids.
const { error } = await window.supabase.storage
  .from('school-files')
  .upload('students/<A-school-uuid>/<A-pupil-uuid>.jpg', new Blob(['x']), { upsert: true })
console.log(error)
```

- [ ] `error` is **not** null. A permission error is the pass.

If `window.supabase` is not exposed in your build, skip this box — the SQL
suite covers the same policy, in both directions, and step 4 already proves the
read side end to end.

## 6. The logo reaches the printed documents

Signed in as **School A** as owner or principal:

- [ ] Settings → School profile → **Add logo** (a PNG with a transparent
      background is best).
- [ ] Fees → print any challan. The logo is above the school name on **all three
      copies**.
- [ ] Print a fee receipt. The logo is there.
- [ ] Exams → print a result card. The logo is there.
- [ ] Certificates → issue or reprint a leaving certificate. The logo is there.
- [ ] Certificates → print a student ID card. The logo is in the header and the
      pupil's photograph is in the photo box.
- [ ] Staff → ID card. Same two things.

Then check the empty case, which is the one most schools will be in on day one:

- [ ] Remove the logo. Print a challan again. The school's **name** is there in
      type and there is no empty box, no broken-image icon, and no gap.

## 7. A clerk cannot change the logo

- [ ] Sign in as an **admin/clerk** login. Settings → School profile.
- [ ] The logo buttons are disabled, with a line saying only the office can
      change it.

The database enforces this too (`fn_set_school_logo` refuses anyone who is not
owner or principal), so a clerk who found a way to send the request would still
be refused. The disabled button exists so nobody is shown a control that would
fail.

---

## If anything above fails

Do not work around it in the app. Write down which box failed and fix it in the
database or the bucket, because every one of these is a rule the app relies on
being enforced somewhere it cannot be bypassed. The app's own checks are a
courtesy to the user; a crafted request skips them entirely.
