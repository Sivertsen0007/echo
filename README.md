# Echo

Wispr Flow-stil push-to-talk dikteringsapp til macOS. Menubar-app skrevet i Swift.
Hold (eller double-tap) en modifier-tast, tal, slip - teksten transskriberes, efter-
behandles og indsættes hvor markøren står.

> Internt SPM-target og bundle hedder stadig `JarvisVoice` (build producerer
> `JarvisVoice.app`). Produktnavnet udadtil er **Echo**.

## Status

Aktivt i daglig brug. Langt forbi den oprindelige MVP - nu med lærende ordbog,
transforms, statistik og onboarding. Se "Arkitektur" for hvad der er bygget.

## Krav

- macOS 13+
- Swift 5.9+ (bygget/testet med Swift 6.2)
- API-nøgle til en transskriptions-provider (OpenAI eller Groq)
- Claude Code CLI (`claude`) for stil-efterbehandling - valgfrit; uden den bruges rå tekst

## Setup

1. Installer (bygger, signerer, installerer til `/Applications` og starter appen):
   ```bash
   ./install.sh
   ```
   Echo registrerer sig selv som login item (SMAppService) første gang den kører.
   Kun til udvikling: `./build.sh` + `open build/JarvisVoice.app`.

   **Aldrig launchd:** på macOS 26 får en launchd-exec'et proces sit event-tap
   auto-DENIED af TCC (Input Monitoring), hvilket dræber hotkeyen tavst. Rettes
   med `tccutil reset ListenEvent com.mathiassivertsen.jarvisvoice` + genstart.

2. Log: alt appen logger ender i `~/.jarvis-voice/logs/echo.log` (roteres ved 2 MB).
   Fejlede dikteringers lyd gemmes i `~/.jarvis-voice/failed/` (nyeste 10) i stedet
   for at blive slettet.

3. Første gang guider onboarding dig gennem:
   - **Mikrofon** - sig ja.
   - **Accessibility** (System Settings > Privacy & Security > Accessibility) - tilføj
     appen. Nødvendigt for både global hotkey og tekst-injektion. Genstart appen bagefter.
   - **Input Monitoring** - kræves separat for hotkey-tap'et på nyere macOS. Appen
     beder selv om det ved opstart og logger begge tilladelsers status.
   - **Provider + API-nøgle** - vælg OpenAI eller Groq og indsæt din nøgle.

Nøgler og data ligger i `~/.jarvis-voice/` (`config.json`, `db.sqlite`, samt JSON-backup
af vocab/snippets/transforms/style). Nøgler kan også sættes via env `OPENAI_API_KEY` /
`GROQ_API_KEY`, som har forrang over config-filen.

## Brug

- **Hold** modifieren nede, tal, **slip** - hold-to-talk. Default-modifier
  er Fn/Globe; kan skiftes i Settings (Fn, højre ⌥, højre ⌘, højre ⇧).
- Menubar-ikonet skifter tilstand: idle -> recording -> processing -> idle.
- Teksten indsættes hvor markøren stod da du stoppede.
- Venstre-klik på menubar-ikonet åbner hovedvinduet; højre-klik giver menu (transforms,
  Add Correction, Show Stats, Welcome Tour, Quit).

## Arkitektur

| Fil | Ansvar |
|---|---|
| `main.swift` | NSApplication bootstrap, `.accessory`-policy, single-instance guard |
| `LogFile.swift` | Persistent fil-log (`~/.jarvis-voice/logs/echo.log`, rotation ved 2 MB) |
| `AppDelegate.swift` | Menubar status item, state machine, hele record->transcribe->post-process->inject->log-kæden |
| `HotkeyMonitor.swift` | `CGEventTap` på flagsChanged; modifier-only push-to-talk med device-bit-check |
| `AudioRecorder.swift` | `AVAudioEngine`-tap -> WAV i temp-mappe |
| `Transcriber.swift` | Multipart POST til OpenAI/Groq `/v1/audio/transcriptions` |
| `TextInjector.swift` | Indsætter tekst hvor markøren står (paste + AX direct-insert) |
| `PostProcessor.swift` | Stil-efterbehandling via `claude -p --model haiku` (lokal CLI-auth) |
| `StyleStore.swift` | Stil-presets (Raw/Clean/Email/Bullets/British), default persisteres |
| `TransformsStore.swift` | One-shot transforms (Slack/Action items/Meeting note/Translate) |
| `VocabStore.swift` | Ordbog: regex-replacements (global + per-app) + prompt-bias |
| `SnippetsStore.swift` | Fraseudvidelser med hit-tælling |
| `CorrectionDetector.swift` | Observerer efterredigeringer via AX og lærer nye vocab-rettelser |
| `Database.swift` | SQLite-log af transskriptioner (WAL); stats/søgning/cost-queries |
| `ConfigStore.swift` | Provider + API-nøgler i `~/.jarvis-voice/config.json` (0600) |
| `Costs.swift` | Pris-estimering til Insights |
| `BackupManager.swift` | Export/import af JSON-bundle (vocab/snippets/transforms/style) |
| `AudioFeedback.swift` | Lyd-cues |
| `LoginItem.swift` | Login-at-startup toggle |
| `Onboarding.swift` | 5-trins onboarding (welcome -> mic -> accessibility -> provider+key -> done) |
| `MainWindow.swift` | Vindues-host (1100x700, on-demand) |
| `EchoMainView.swift` | SwiftUI-hovedvindue: Home, History, Insights, Dictionary, Snippets, Style, Transforms, Scratchpad, Settings |

## Post-processing-rækkefølge (i `stopRecording`)

1. Transform-override (one-shot) eller default-stil
2. `PostProcessor` (Claude Haiku via CLI) - passthrough hvis rå stil eller CLI mangler
3. Vocab-replacements (global + per-app)
4. Snippet-udvidelser
5. Indsæt -> `CorrectionDetector` lytter efter efterredigeringer og tilbyder at lære nye rettelser

## Stabilitet (indbygget selvhelbredelse)

- **Event-tap**: genaktiveres straks ved `tapDisabledByTimeout`/`ByUserInput` og
  af en 30s health-check-timer - hotkeyen kan ikke længere dø permanent.
- **Watchdog**: processing-fasen har et 60s-loft; appen vender altid tilbage til idle.
- **Synlige fejl**: overlay viser årsagen ("No speech detected", "Network error",
  "API key rejected", ...) i stedet for at forsvinde tavst.
- **Stilheds-gate**: optagelser der aldrig kommer over støjgulvet uploades ikke
  (Whisper ekkoer ellers vokabular-prompten tilbage). Fuzzy ekko-detektion fanger
  delvise ekkoer.
- **Retry + bevaret lyd**: netværks-/serverfejl prøves igen én gang; fejler det
  endeligt, flyttes lydfilen til `~/.jarvis-voice/failed/` i stedet for at slettes.
- **Pre-warmet audio-engine**: engine bygges før tastetryk, så første ord ikke klippes.
- **Max-optagelse**: 5 min auto-stop dækker mistede release-events.
- **Sleep/wake**: tap og engine revalideres ved wake.
- **Permission-diagnostik**: Accessibility- og Input Monitoring-status logges ved
  opstart sammen med tap'ets faktiske enabled-tilstand.
- **Login item + single-instance guard**: starter ved login; anden instans afviser
  selv at starte.

## Mulige næste skridt

- Signér + notarisér + auto-update hvis appen skal distribueres bredere.
- Skift til ML-organisationens OpenAI-nøgle før rigtig produktion (billing).
- Streaming-transkription (kun relevant med inkrementel live-indsættelse).
