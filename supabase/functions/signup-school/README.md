# signup-school

Creates a school, its 14-day trial, and the owner's login — in that order,
because `handle_new_user` needs the school to exist before it can attach the
owner's profile to it.

## Deploy

```bash
supabase functions deploy signup-school --no-verify-jwt
```

`--no-verify-jwt` is required and deliberate: a school signing up has no login
yet, so this is the one endpoint that must be reachable without a JWT.

## Why it needs the service key

Two things here cannot be done from a browser:

- **Minting an auth user.** Only the service_role key can create a login.
- **Creating a school.** `fn_signup_school` is `SECURITY DEFINER` and is
  explicitly revoked from `anon` and `authenticated`, so the service role is the
  only caller that can reach it. Without that, anyone could create unlimited
  schools by calling the RPC directly.

The service_role key is supplied automatically to deployed functions via
`SUPABASE_SERVICE_ROLE_KEY`. It must never appear in the web bundle.

## Rollback behaviour

If creating the login fails — almost always "email already registered" — the
school row is deleted again before returning the error. Without that, a
mistyped signup would strand an empty school in the operator console that the
owner cannot reach and you would have to clean up by hand.
