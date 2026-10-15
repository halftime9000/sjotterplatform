// Gedeelde configuratie voor alle Sjotter-modules.
// Eén Supabase-project = één login voor tornooi, coach, training en playernation.
window.SJOTTER = {
  SUPABASE_URL: "https://equmwyvxbjjocwetwfcw.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_wLF8ZNLFbiWM8YGrEnzjXQ_Aon8llxh",
  PLATFORM: "Sjotter",
  CONTACT_EMAIL: "sjotter.be@gmail.com",
  // supabase-js bewaart de sessie standaard onder deze sleutel (zelfde origin = gedeeld)
  AUTH_STORAGE_KEY: "sb-equmwyvxbjjocwetwfcw-auth-token"
};

// Lichte sessie-check zonder supabase-js te laden (voor de hub).
window.SJOTTER.huidigeGebruiker = function () {
  try {
    var raw = localStorage.getItem(window.SJOTTER.AUTH_STORAGE_KEY);
    if (!raw) return null;
    var s = JSON.parse(raw);
    if (!s || !s.user) return null;
    if (s.expires_at && s.expires_at * 1000 < Date.now() && !s.refresh_token) return null;
    return { email: s.user.email || "", id: s.user.id };
  } catch (e) { return null; }
};
