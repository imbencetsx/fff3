# [rgb] for macOS

The Mac app, [rgb], controls your ELK-BLEDOM and MELK strips over Bluetooth, and makes them follow the music this Mac plays or the room hears. You need macOS 14 or later, and 14.2 or later to sync with the Mac's own sound.

![The Mac app with 2 strips connected and music sync locked on the beat at 97 BPM](../docs/macos.png)

## Install

Download `fff3-<version>-macos.zip` from the [releases page](https://github.com/kernoeb/fff3/releases), unzip it and move `[rgb].app` to Applications. It runs on Apple silicon Macs.

The app is not notarised by Apple, so macOS blocks it the first time. To open it:

1. Open it once and close the warning.
2. Go to System Settings, then Privacy and Security.
3. Next to the message about [rgb], select Open Anyway.

To build it yourself, use the Xcode command line tools, from the repo root:

```sh
cd macos
./build.sh                      # -> [rgb].app, signed ad hoc
./build.sh install              # also replaces /Applications/[rgb].app
```

Always remove the old app before you copy a new one over it: a copy over the old bundle keeps a stale signature, and macOS refuses to start it. The app is signed ad hoc, so macOS may ask again for Bluetooth, system audio or microphone access after each new build.

A new build also changes the app's signature, so macOS may ask whether [rgb] can read its saved Spotify sign-in from Keychain. The app waits for that answer, so a hidden prompt can look like a frozen app. It only reads Keychain when the Spotify account source is selected.

Each strip accepts one Bluetooth connection at a time. While the Mac app runs it holds every strip it knows, so the phone cannot reach them. Quit the Mac app to give them back.

### Menu bar

Closing the window, or Cmd-Q, leaves [rgb] running as a lightbulb in the menu bar, with no Dock icon, so album colours and music sync keep going. The window's views are freed when it closes, so in the background [rgb] uses no CPU while idle and about 40 MB of memory. The menu shows how many strips are connected and the current song, starts or stops album colours, stops music sync and reopens the window; opening [rgb] again does too. **Quit [rgb]** in that menu really quits and frees the strips. Logging out or shutting down also quits.

## What it does

The Light page has:

- On and Off buttons, as on Android: the strips cannot report their state
- a colour wheel that sends while you drag
- brightness, and 3 whites (2700 K, 4000 K and 6500 K) made from the RGB LEDs
- the family's built-in effects and scenes, with their speed

The Music page has:

- 2 sources: this Mac's sound, through a Core Audio process tap (macOS 14.2 or later), and the microphone
- the 5 styles: Pulse, Spectrum, Energy, Calm and Beat lock
- for Beat lock: tap tempo, ×2 and ÷2, the colour choice (each bar, tempo or strip) and the light delay fine-tune, from -100 to +200 ms

macOS hides Bluetooth addresses, so a strip added on the phone must be added again on the Mac. Strips are saved in `~/Library/Application Support/fff3/data.json`.

Beat lock corrects the delay between the sound and the light by itself: it reads the output and capture delays from macOS, and uses a strip delay measured once with a camera (38 ms). The light delay slider, 0 by default, is for fine-tuning by eye.

## Calibrate each strip

On the Light page, choose **Calibrate colours…**, then select the affected strip. Select a test colour to edit only that colour's settings:

- **White balance:** red, green and blue channel levels. To fix blue-tinted white, choose White and lower Blue. Red, green, blue, grey and your other calibration colours keep their own settings.
- **Colour:** an independent hue offset and saturation for the selected colour.
- **Brightness:** independent brightness and gamma for the selected colour. Gamma changes intermediate channel levels; it does not change pure white or pure primary colours.

The colour row includes White, Grey, Dark, Red, Green, Blue, Orange, Yellow, Cyan and Magenta. Use **Custom colour** and **Add colour** to add any other colour you want to calibrate. Switching colours keeps all your draft adjustments. Colours between the calibration points blend their corrections smoothly. Greys follow a separate brightness curve through the saved grey/white calibrations, keeping your hardware white balance while excluding corrections from coloured points. Very dark and Dim grey tests let you adjust low-level tint without changing White; almost-grey colours fade smoothly into this curve.

**Save calibration** saves all the colours for the selected strip to disk. **Cancel** discards the draft. Save or cancel before selecting another strip. **Reset this colour** resets only the selected colour; save to keep the reset.

Saved calibrations load automatically on future launches and connections. Earlier profiles preserve their previous output until you edit individual colours. Uncalibrated mixed colours inherit the saved White hardware balance, so lighter pinks and purples do not bypass its blue reduction. Explicit colour overrides take precedence and are not corrected twice. Other strips are unaffected. The correction applies to colours sent by [rgb], including whites, the colour wheel, music sync and Spotify. Built-in effects generate their own colours and are unaffected. Closing calibration restores its previous saved colour or effect and power setting when known. Music and Spotify stop before the test starts.

## Export and import settings

The Light page has **Export settings…** and **Import settings…**. Exports are JSON files containing known strips, all per-colour calibration points, remembered light states and app settings. Spotify access and refresh tokens are never included.

Import previews the strip count before applying it. Matching strip IDs get their imported settings, missing strips are added, and other strips are kept. App settings are restored from the file. The app automatically saves the current configuration to `~/Library/Application Support/fff3/backups/` before importing. Damaged or unsupported files are rejected without replacing existing settings. Strip IDs belong to the Mac where they were discovered, so another Mac may need to add its strips again.

## Spotify album colours

The Spotify page sets the selected strips to a dominant colour from the current song's album cover. **Cover from** picks where the song comes from:

- **Spotify account** follows your Spotify account, including playback on another device. It needs your own Spotify app (below) and checks every 5 seconds.
- **This Mac's Now Playing** follows music apps that show in Control Centre's Now Playing: Spotify, Music, a terminal player and so on. It needs no sign-in or network, and the colour changes as soon as the song does.

No microphone or system-audio permission is needed for either.

### Now Playing

Since macOS 15.4, only Apple-signed programs can read Now Playing. [rgb] builds a small helper, `Helpers/NowPlaying.m`, into `Contents/Frameworks/libfff3nowplaying.dylib` and runs it inside `/usr/bin/perl`, which is Apple-signed and can load it. Other apps use the same method. The helper lists every app with a Now Playing session, not only the one Control Centre shows, and prints one JSON line whenever any of them changes: per player its title, artist, album, app, media type, play state, and the cover bytes only when the cover changes. It wakes on MediaRemote notifications and looks again every second, because background players do not always post changes. [rgb] follows a playing music player first, preferring the one Control Centre shows, then paused music. So a video that starts in a browser while music keeps playing does not take the lights. It exits when [rgb] closes its input, so it stops with the app even after a crash. If it stops on its own, [rgb] restarts it with a growing wait. Only music changes the lights: browsers (a known list plus every app that opens web links, matched on the player and on its parent app, since web audio plays from a helper), anything MediaRemote marks as video, and podcasts are ignored and hold the last colour. Pausing, an app with no cover and a cover that cannot be read hold it too.

### Spotify account

1. Create your own app in the [Spotify developer dashboard](https://developer.spotify.com/dashboard), selecting Web API.
2. In its settings, register this exact redirect URI: `http://127.0.0.1:43821/spotify/callback`.
3. Copy its **Client ID** into [rgb]'s Spotify page and select **Connect Spotify**. A client secret is not needed: sign-in uses [Authorization Code with PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow).
4. Finish signing in in your browser, return to [rgb], select your strips and press **Start**.

Spotify currently requires the owner of a development-mode app to have Premium. Other accounts need to be added to its allowlist in User Management; see [Spotify's quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes). A 403 error can indicate an account that is not allowed. If sign-in cannot start, close another [rgb] sign-in using local port 43821. `localhost` is not interchangeable with `127.0.0.1`.

With the Spotify account source, [rgb] checks the current song every 5 seconds and downloads artwork when it changes. Both sources then select an actual sRGB cover pixel from a substantial colour region while discounting black and white borders. It groups neighbouring shades so tiny saturated logos do not beat large gradients, ranks colour families using coverage, perceived lightness/chroma in Oklab and contrast with the rest of the palette, then seeks brighter shades within the selected family. Strong hue majorities are preserved and tiny accents are rejected. A small orange accent cannot displace a mostly blue cover just because the blue is dark. Coloured picks keep their hue, receive a gentle 15% saturation boost without a forced saturation floor, and have at least 90% HSV brightness; muted colours stay muted. Neutral covers stay neutral, with a 65% brightness floor so black artwork does not turn the lights off. The Spotify page shows both the sampled cover hex and the richer light hex; your strip calibration is applied afterwards. Changes between songs fade over about a second. Pausing, ads, podcasts and unavailable artwork leave the last colour in place. Spotify's rate-limit retry delay is respected, and temporary failures retry with a longer wait. **Stop** restores the strips' previous settings; changing the selected strips or starting audio sync also stops Spotify mode. Only one light mode runs at a time.

Spotify mode contacts Spotify for sign-in and current-track details, and downloads the supplied cover image. It does not capture or upload audio. The public Client ID is saved in preferences; access and refresh tokens are saved in macOS Keychain, refreshed automatically, and removed by **Disconnect**. The local callback listener runs only during sign-in and binds to `127.0.0.1`. No developer credentials are bundled with the app.

Run the Spotify tests with `swift test` from this directory. Tests cover PKCE, callback validation, artwork colours, current-track responses, token refresh and rate-limit handling without contacting Spotify or writing Keychain tokens.

## Not on the Mac

These are Android only, or need the phone's hardware:

- widgets, the Quick Settings tile and app shortcuts
- camera light delay calibration per strip: the Mac uses one strip delay measured once
- measuring the speaker delay with the microphone: the Mac reads it from macOS instead
- companion device pairing and haptics

These exist on Android and are not on the Mac yet:

- groups (the Mac has one strip or all strips) and favourites
- per-strip settings: on and off timers, wire order and its test, pixel count
- the controller's own microphone modes

## For developers

Run the protocol checks with `./tools/test.sh`: every frame, with its exact hex.

### How the code is split

- `Sources/Fff3Core/Protocol`: commands, families, frames and catalogues, ported from `protocol/`.
- `Sources/Fff3Core/Music`: `Fft`, `MusicAnalyzer`, `BeatDetector`, `BeatTracker`, `SongEnergy`, `LightRenderer`, `LightTiming` and `PcmConverter`, ported line for line from `music/`. `JMath` gives Kotlin's maths: Float functions computed in Double and rounded once, and rounding that goes half up.
- `Sources/Fff3`: the app. `WriteQueue` keeps the Android write pacing: one frame every 35 ms per strip, drag values coalesced, newest wins. `Bluetooth` holds one link per strip on one serial queue, reconnects with the same backoff, and sends the Mac's time on each connect. `MusicEngine` is `MusicEngine.kt` on a thread.
- `Sources/Fff3Bench`: the Swift twin of `BeatBenchTest.kt`.

### Check that Beat lock matches Android

The bench takes the same input and prints the same lines as `BeatBenchTest.kt`:

```sh
swift build -c release --product Fff3Bench
FFF3_BENCH="song.f32=114;other.f32=92@40" FFF3_BENCH_LOCKS=1 .build/release/Fff3Bench
```

Songs are 48 kHz mono f32le: `ffmpeg -i song.mp3 -ac 1 -ar 48000 -f f32le song.f32`. Run the Kotlin bench with the same `FFF3_BENCH` and compare the lines. `FFF3_BEATS_DIR=dir` writes every beat time, for a closer check.

On 80 runs (11 songs, clean, microphone and quiet versions, from the start and from 40 s), the Swift and Kotlin benches print the same `BENCH` and `LOCK` lines, and the same 24,813 beat times but one, which differs in the last printed digit. Run this check again after any change to `music/`.

### Test switches

These environment variables help to check the app without clicking through it:

- `FFF3_PAGE=light`, `music`, `spotify` or `add` opens that page
- `FFF3_AUDIO_FILE=song.f32` plays a decoded song into the analyser in real time instead of capturing, so music sync can run on the strips without audio permissions
- `FFF3_BLE_LOG=1` prints each frame as it goes to a strip, with the time in milliseconds
- `FFF3_BEAT_LOG=1` prints one Beat lock line a second, like `adb logcat -s fff3-beat`, plus the loudness
- `FFF3_TIMING_LOG=1` prints, on one millisecond clock, when each click was captured, analysed and turned into a beat, to measure the delay inside the app
- `FFF3_STYLE=BeatLock` (or `Pulse`, `Spectrum`, `Energy`, `Calm`) sets the style for this run without saving it
- `FFF3_AUTOSTART=1` starts music sync once every strip is connected; `FFF3_AUTOSTART=album` starts album colours instead, from the saved source

Start the app with `open -n --env FFF3_BEAT_LOG=1 --stderr log.txt '[rgb].app'`, so it keeps its own audio permission: a binary started from a shell captures silence. Each `open -n` starts another copy, and only one copy can hold the strips: quit the old one first. `tools/screenshot.sh out.png` captures the window.

### How late the lights are

Measured on 10 November 2026 with the Scarlett 2i2 as output, clicks played straight into it at known times, and the Mac camera filming the room lit by both strips at 30 fps:

| Step | Time |
|---|---|
| Write to the strip lighting (camera, 15 flashes, with and without a 35 ms stream) | median 36 to 39 ms |
| Click played to the capture stamp of a process tap | 37 ms after the sound (the tap stamps late) |
| Click played to the app having the audio | 60 to 65 ms |
| Pulse: click played to light | about 100 ms (no prediction is possible) |
| Beat lock before the fix: click played to beat sent, then to light | +100 ms, then about +140 ms |
| Beat lock after the fix: click played to beat sent, then to light | +13 ms, then about +55 ms |

Beat lock aims at the click plus the light delay setting, which is 0 by default, as on Android. Raise it if the lights look early. With a Bluetooth headset the output timing is not tested.

### Things to know

- An output device with inputs, such as a USB audio interface, adds its own input buffers before the tap's in the capture callback. The code reads the tap's buffers, which come last. Reading the first buffer gave near silence with a Scarlett 2i2 as output.
- CoreBluetooth reports a write without response as done when it is queued, not when the strip shows it. Beat lock uses the write-to-light time filmed once (`LightTiming.macStripDelayMs`, 38 ms) for every strip.
- CoreBluetooth does not hold a deep queue of writes without response to these strips: a read sent while writing 23 frames a second comes back in 42 to 80 ms, as when idle.
- A process tap stamps its audio when it reaches the capture device, about the aggregate device's output latency, safety offset and one buffer after the sound (34.8 ms computed, 37 ms measured). `SystemAudioSource` moves the stamps back by that much, so the output delay is only the device's own latency.
- A process tap gets no callbacks at all while nothing plays on the output device. The capture then hands out silence at the real rate, so music sync keeps running between videos or songs instead of stopping with "The sound stopped".
- After the app is killed, it reconnects to both strips in under a second on the next start.


### Bluetooth connection recovery

Connection and discovery timeouts request cancellation, then wait for CoreBluetooth's disconnect/failure callback before retrying. Completed connections invalidate their old timeout. Write acknowledgements have separate tokens; an expired acknowledgement triggers recovery instead of marking the command as delivered. Short-lived connections retain the failure backoff; it resets after a connection has lasted 30 seconds. Calibration and remembered colours are unchanged.

Connection events and the signal measured after connecting are logged under subsystem `com.kernoeb.fff3.mac`, category `Bluetooth`. Inspect them with `/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.kernoeb.fff3.mac" AND category == "Bluetooth"'`. Radio link failures, weak signal, competing controllers and power interruptions can still disconnect a strip independently of the app.
