/* Peony — where the app finds its database.
   The anon key is designed to be public: every table is behind row level
   security, and the tests in platform/ prove one studio cannot read another's
   bookings with it. The service_role key is the secret one and must never
   appear in anything served to a browser. */
window.PEONY = {
  SUPABASE_URL: "PASTE_YOUR_PROJECT_URL",      // https://xxxx.supabase.co
  SUPABASE_ANON_KEY: "PASTE_YOUR_ANON_KEY",
  // where a client page lives, shown in the app and used to build her link
  PAGE_HOST: "peony.uk",
  // where the edge functions are deployed, e.g. https://<ref>.functions.supabase.co
  FUNCTIONS_URL: ""
};
