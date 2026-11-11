# UMP → first ad request without TCF signals (iOS)

Minimal Flutter project to reproduce a timing issue between the User Messaging
Platform SDK and the Google Mobile Ads SDK on iOS: the **first** ad request
issued right after the `requestConsentInfoUpdate` completion callback carries
**no TCF signals** in Ad Inspector (no `IABTCF_TCString`, no
`IABTCF_gdprApplies`), while a request issued about one second later carries
them all. Consent was already *obtained* in a previous session.

Only Google's sample app ID and test ad units are used.

## Versions

| Component | Version |
| --- | --- |
| Flutter | 3.47.9 |
| google_mobile_ads (Flutter) | 9.2.0 |
| Google Mobile Ads SDK (iOS) | 13.12.0 |
| User Messaging Platform (iOS) | 3.1.0 |
| Mediation | none |

## Steps

1. `flutter run` on an iOS simulator (or device).
2. First run: tap **Run sequence**. Status is `required`, the consent form
   appears (debug geography EEA); accept it. If the UMP SDK refuses the debug
   geography, copy the hashed device id it prints in the console into
   `kUmpTestDeviceIds` in `lib/main.dart`.
3. **Kill the app and launch it again** (consent is now persisted, as in a
   real second session).
4. Leave `delay 0 ms` and tap **Run sequence**. The log shows the UMP callback,
   `MobileAds.initialize`, then the ad request, each line with the IABTCF keys
   as read from `UserDefaults.standard` at that moment. A monitor logs every
   change of those keys for 5 s after the callback.
5. Tap **pollAd (refill)** so that the preloader issues a second request.
6. Tap **Ad Inspector** → the ad unit → the two requests → *Privacy signals*.

Expected: both requests carry the TCF signals.
Observed on device (iPhone 13 Pro, iOS 27.0.1, release build of a production
app): the first request shows "TCF signals are missing", the refill request
one second later shows `gdprApplies = true` and the full TC string.

## Knobs

- **Preloader / AppOpenAd.load**: the request path (`AppOpenAdPreloader.start`
  with `bufferSize: 1`, or a plain `AppOpenAd.load`).
- **delay**: extra wait between `MobileAds.initialize` and the ad request
  (0, 300, 1000, 2000 ms). In the production app, 300 ms was not enough and
  ~1.4 s was.
- **Reset consent**: `ConsentInformation.reset()` to simulate a fresh install.

## What the log tells

- `UMP callback … keys: no IABTCF keys` followed later by `keys changed
  (+N ms …)`: the UMP SDK writes the IABTCF keys *after* its completion
  callback; any request issued in between goes out without consent signals.
- `UMP callback … keys: gdprApplies=1 TCString=… chars` and the first request
  still has no signals in Ad Inspector: the Mobile Ads SDK does not pick the
  keys up for its first request.
