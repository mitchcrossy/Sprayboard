# Sprayboard

Trace holds on a photo of your home spray wall, set problems, and log sends with your crew.

- **Website:** published from `www/` by the *Website* workflow to GitHub Pages.
- **Android app:** built by the *Android app* workflow. Download `sprayboard.apk` from the **Releases** section.
- **Backend:** Supabase (accounts, crews, walls, problems, logbooks, wall photos). The database setup is in `supabase/setup.sql`.

The key in `www/index.html` is the Supabase *publishable* key, which is meant to be public. Access is controlled by the row-level security rules in `supabase/setup.sql`. Never commit the `service_role` / secret key.
