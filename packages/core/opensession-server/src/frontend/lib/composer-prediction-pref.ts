// The per-person switch for the composer's predicted reply
// (lib/composer-prediction.ts). It follows you across devices like the
// quick-replies switch.

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
