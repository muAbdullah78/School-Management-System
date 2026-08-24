# Photographs and the school logo — the design, and the arguments against it

Every decision below is written with its strongest objection, because the failure
mode here is not a broken screen. It is one school fetching another school's
pupils' photographs, and a photograph of a child is the most sensitive thing this
system will ever hold.

---

## 1. One bucket with a school folder, not a bucket per school

**Decision.** A single private bucket, `school-files`, with the school id as the
**second** path segment:

```
students/<school_id>/<student_id>.jpg
staff/<school_id>/<staff_id>.jpg
logos/<school_id>/logo.png
```

**The objection.** With one bucket, a single wrong policy exposes *every* school
at once. Per-school buckets fail closed: if a bucket does not exist, nothing can
be read from it, so a policy bug is contained to one tenant.

**Why one bucket wins anyway.** Per-school buckets have to be *created*, which
needs the service_role key or an Edge Function on the signup path — a new
privileged code path on the most security-sensitive flow in the product, to
protect against a bug in a policy I can test. One bucket needs one policy whose
only variable is the school segment, and that policy is ordinary SQL I can
execute against a faithful stub of `storage.objects`. A guard I can test beats a
structure I cannot.

**What makes it safe.** The school segment is at a *fixed* position in every
path, so the policy is one comparison with no branches. Which brings us to:

## 2. The school is ALWAYS the second segment. No exceptions.

**Decision.** Even the logo, which needs no per-object id, is stored at
`logos/<school_id>/logo.png` rather than `logos/<school_id>.png`.

**Why.** `storage.foldername()` returns the *folders* of a path. For
`logos/<school_id>.png` the school id is in the filename, not a folder, so it
would need a different check from every other file — and a special case inside a
security policy is exactly where a hole lives. One extra path segment buys a
policy with no `case` in it.

## 3. Private bucket, signed URLs. Never public.

**Decision.** The bucket is private. The app mints short-lived signed URLs.

**The objection.** Signed URLs cost a round trip and expire, so a photo can go
blank while a page is open, and a class list of 40 pupils needs 40 URLs.

**Why private anyway.** A public bucket means anyone holding the URL sees the
photograph, forever, with no login — including after the pupil leaves the school.
That is not a trade worth making for page speed. The round-trip objection is
answered by `createSignedUrls` (plural), which signs a whole class in one call.

## 4. The database column holds a PATH, never a URL

**Decision.** Rename the dead columns: `students.photo_url` →
`students.photo_path`, `school_settings.logo_url` → `logo_path`.

**Why.** A signed URL expires. If anything ever writes one into a column called
`photo_url`, it works in testing and turns into a broken image days later —
which looks exactly like data loss and is impossible to distinguish from it.
Naming the column `photo_path` makes the wrong thing obviously wrong. Both
columns are currently unused, so the rename costs nothing.

## 5. Office uploads. Staff view. Parents do not.

**Decision.**

| Who | Read | Upload / replace / delete |
|---|---|---|
| owner, principal, admin_clerk | yes | yes |
| class_teacher, subject_teacher, accountant | yes | no |
| parent | **no** | no |

**Why teachers can read.** Identifying the children in front of you is the whole
point of the feature. A teacher sees every pupil's photograph in their own
school, not only their class — a narrower rule would mean parsing a student id
out of a file path inside a security policy, and a policy that parses strings is
a policy I do not trust.

**Why teachers cannot upload.** Replacing a child's photograph is a records
change, not a classroom action.

**Why parents get nothing, even their own child.** A parent seeing their child's
photo in the portal would be a nice touch. Scoping it correctly means deriving
the child from the file path and joining to the parent's family *inside* a
storage policy. The cheap version — letting a parent read their school's folder —
would show them **every child in the school**. That is the leak this whole
document exists to prevent, so the feature waits until it can be done properly.

## 6. Limits are enforced on the server, not in the browser

**Decision.** The bucket carries `file_size_limit` (2 MB) and
`allowed_mime_types` (jpeg, png, webp). The browser *also* downscales to 512 px
before upload.

**Why both.** The browser downscale is what keeps a 4 MB phone photograph from
becoming 4 MB of storage — 500 pupils at ~60 KB each is about 30 MB, comfortable
on the 1 GB free tier and trivial on Pro. But a downscale in the browser is a
courtesy, not a control: a crafted request skips it entirely. The bucket limits
are the actual enforcement.

**On cost.** At ~60 KB per pupil, 1 GB holds roughly 16,000 photographs — far
past the point where the Pro plan is affordable. Storage is not the constraint
this feature has to be designed around; isolation is.

## 7. A missing photograph is a normal state, not an error

**Decision.** Every screen has an initials avatar fallback, and the printed
challan and result card fall back to the school's *name* in text when no logo is
set.

**Why.** Most schools will not photograph every pupil on day one, and a school
that has not uploaded a logo is not misconfigured. A blank box on a printed
challan a parent takes to the bank looks like a defect in the school, not in the
software.

## 8. What I can and cannot prove in this environment

This is the honest part.

**Can prove.** `storage.objects` policies are ordinary SQL. The tests create a
faithful stub — the same table shape and the same `storage.foldername()`
behaviour Supabase uses — and then exercise the real policy bodies as
`authenticated`, from two schools, in both directions. The isolation guarantee is
tested, not asserted.

**Cannot prove here.** That Supabase's own storage API enforces those policies
the way the SQL says. The bucket row, the mime and size limits, and the signed
URL flow only exist on a real project. Those need one manual check on your live
project, and the check is written out in `docs/PHOTOS-CHECKLIST.md`.

I would rather say that plainly than let a green test suite imply more than it
covers.
