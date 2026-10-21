const assert = require("node:assert/strict")
const test = require("node:test")
const T = require("../Translations.js")

test("system language follows Norwegian locales with English fallback and explicit overrides", () => {
  for (const locale of ["nb_NO", "nn-NO", "no_NO.UTF-8", "NB"]) assert.equal(T.language("system", locale), "nb")
  for (const locale of ["en_US", "de_DE", "C", ""]) assert.equal(T.language("system", locale), "en")
  assert.equal(T.language("en", "nb_NO"), "en")
  assert.equal(T.language("nb", "en_US"), "nb")
  assert.equal(T.language("invalid", "nb_NO"), "nb")
})

test("labels, counts and sender-supplied query strings translate without interpreting replacement tokens", () => {
  assert.equal(T.text("Notifications", "nb"), "Varsler")
  assert.equal(T.text("%1 unread", "nb", 2), "2 uleste")
  assert.equal(T.text("1 unread", "nb", 1), "1 ulest")
  assert.equal(T.text("Dismiss 1 notification", "nb"), "Fjern 1 varsel")
  assert.equal(T.text("Dismiss %1 notifications", "nb", 3), "Fjern 3 varsler")
  assert.equal(T.text("Nothing matches “%1”", "nb", "$& <hello>"), "Ingen treff for «$& <hello>»")
  assert.equal(T.text("Missing label", "nb"), "Missing label")
  assert.equal(T.text("Notifications", "en"), "Notifications")
})

test("relative ages translate at minute, hour and day boundaries", () => {
  const cases = [[-1,"now","nå"],[59999,"now","nå"],[60000,"1m ago","1 min siden"],[3599999,"59m ago","59 min siden"],[3600000,"1h ago","1 t siden"],[86400000,"1d ago","1 d siden"]]
  for (const [now,en,nb] of cases) {
    assert.equal(T.relativeTime(0,now,"en"),en)
    assert.equal(T.relativeTime(0,now,"nb"),nb)
  }
})
