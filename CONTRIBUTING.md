# Contributing

Thanks for looking. This is a small app with a narrow job, so the useful contributions are
fairly specific.

## What's most useful

**Parser fixes when a vendor changes their page.** This is the failure this project actually
has. The vendors redesign their usage pages without warning and the parsers stop matching.
If you hit it, the diagnostic output (below) captures what the page rendered, which is the
thing that changed.

**Translations.** Everything user-facing lives in one file,
[`Sources/UsageCore/L10n.swift`](Sources/UsageCore/L10n.swift). Adding a language means
extending `pick(_:_:)` into something with more than two branches, plus the language detection
above it. Happy to take that on if someone wants a third language.

**Page parsers for other locales.** `ClaudeWebParse` handles Korean and English; the Codex one
handles Korean dates and best-effort English. If your account language isn't covered, a real
sample of the page text is enough for me to add it — see the issue template.

## Getting set up

```sh
git clone https://github.com/dongha0312/TokenUsage.git
cd TokenUsage
swift test          # 93 tests, no signing needed
./build.sh --install
```

You don't need a paid Apple Developer account to build or test. Without a certificate the
build is ad-hoc signed, which means everything works except notifications.

## How this codebase is organized

`Sources/UsageCore/` is pure logic with no AppKit — parsers, the shared model, strings. This
is what the tests cover. `Sources/TokenUsage/` is the app: web views, menu bar, panel,
notifications.

Two rules that the design leans on, worth knowing before you change things:

**Parsers return meaning, not display text.** A parser gives back
`WindowKind.session(hours:)`, never `"5-hour limit"`. The vendor page follows the user's
*account* language; the UI follows their *system* language. Producing strings in the parser
collapses those and breaks one of them.

**Never present a stale number as current.** Every source is a snapshot. If a reset time has
passed, the window rolled over — show 0%, not the frozen value. If a live fetch fails, fall
back but say so. This is why `updatedAt` is threaded through everything.

## Tests

```sh
swift test                      # everything
REAL_FULL_SCAN=1 swift test     # also the slow real-data pass
```

Two kinds:

- **Unit tests** run against captured page text. When you fix a parser, paste the real page
  text you captured into a test. That's what makes the fix stick.
- **`RealDataTests`** runs the readers against the actual files on your machine and skips when
  they're absent. Unit tests only prove the parser handles the samples I wrote; this is what
  catches drift from the real formats.

If you assert on user-facing strings, inherit `LocalizedTestCase`. It pins the language in
`setUp`. Tests that don't do this pass only on machines set to the same language as the author's
— which is exactly how nine of them broke the first time CI ran.

## Diagnostics

A menu bar app has no stdout, and `NSLog` doesn't reach `log show`, so failures are invisible
by default:

```sh
pkill -x TokenUsage
TOKENUSAGE_DEBUG=1 /Applications/TokenUsage.app/Contents/MacOS/TokenUsage &
cat /tmp/tokenusage-debug.log
```

It logs each provider's fetch duration and parsed values, and on failure the URL it landed on
plus a snippet of what rendered. It writes nothing when the variable is unset.

## Regenerating artifacts

```sh
swift Xcode/make-icon.swift                 # app icon
.build/release/TokenUsage --snapshot docs   # README screenshots, both languages
```

The screenshots are rendered from the real views rather than captured by hand, so they can't
drift from the UI. If you change `PanelView`, regenerate them.

## Things that aren't wanted

**Reading credentials.** No Keychain access, no OAuth token extraction, no copying browser
cookies. It would be faster and it's what similar apps do, but an app that sits in the menu bar
all day shouldn't be handling account credentials. The web views keep their own cookies and the
user signs in inside the app.

**Estimated numbers.** If a limit isn't known, `usedPercent` stays `nil` and the UI shows
nothing rather than a guess. An earlier version inferred Claude's limit from rate-limit records
and was off by about 2× — plausible-looking and wrong is worse than absent.

## Commits

Say what changed and why it needed changing. If you fixed something subtle, the reasoning
belongs in the commit or a comment — the next person (often me, months later) won't reconstruct
it from the diff.
