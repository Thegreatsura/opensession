// The per-person switches for the composer's predicted reply and typing
// autocomplete (lib/composer-prediction.ts). They follow you across devices
// like the quick-replies switch. Autocomplete is off until you turn it on:
// each suggestion is a paid model call on the instance's OpenAI key.

import * as userPref from "./user-pref";

const pref = userPref.makeUserPref<boolean>({
  localKey: "opensession-composer-predictions",
  prefKey: "composer-predictions",
  changeEvent: "opensession-composer-predictions-changed",
  defaultValue: true,
  decode: (v) => (v === "on" ? true : v === "off" ? false : null),
  encode: (on) => (on ? "on" : "off"),
});

export const getComposerPredictionsPref = pref.get;
export const setComposerPredictionsPref = pref.set;
export const onComposerPredictionsChanged = pref.onChanged;

const autocompletePref = userPref.makeUserPref<boolean>({
  localKey: "opensession-composer-autocomplete",
  prefKey: "composer-autocomplete",
  changeEvent: "opensession-composer-autocomplete-changed",
  defaultValue: false,
  decode: (v) => (v === "on" ? true : v === "off" ? false : null),
  encode: (on) => (on ? "on" : "off"),
});

export const getComposerAutocompletePref = autocompletePref.get;
export const setComposerAutocompletePref = autocompletePref.set;
export const onComposerAutocompleteChanged = autocompletePref.onChanged;
