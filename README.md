# macos-wordbar

<img src="icon.png" width="128" align="right">

A macOS menu bar vocabulary flashcard app — one word lives in your status bar, click `✓` when you've memorized it to move on. Learn passively in the gaps of your day.

Native Swift + AppKit, single-file source, zero dependencies, no Xcode project required.

[中文文档](README_CN.md)

## Features

- **Menu bar resident**: unified `word ✓` display, no Dock icon
- **Click `✓`**: mark as memorized and advance to the next word
- **Click the word**: menu with phonetic/meaning/example/translation, plus Memorized / Previous / Next / Unmark / Speak actions
- **Browse Words**: floating scrollable list of the whole vocabulary, auto-positioned at the current word — memorized rows show `✓`, double-click a row to jump to it
- **Optional in-bar meaning & example**: toggleable; long text scrolls horizontally on hover
- **TTS**: native `AVSpeechSynthesizer`, works offline
- **Sequential order**: walks the list in order, skipping memorized words; skipped words come back after a full cycle
- **Progress persistence**: memorized words saved to `memorized.txt`
- **Multiple word lists**: pick any `.txt` under `~/.config/wordbar` from the Vocabulary submenu, or Choose File… for a list anywhere else — the choice persists across launches
- **Hot reload**: edits to the active word list are picked up automatically
- **Anki import**: `scripts/apkg2words.py` converts `.apkg` decks into the vocabulary format

## Build & Run

```bash
./build.sh        # compiles and packages WordBar.app
open WordBar.app  # launch — appears in the menu bar
```

Requirements: macOS 13+, Xcode Command Line Tools (`swiftc`).

## Vocabulary Format

The active word list — `~/.config/wordbar/words.txt` by default, or any `.txt` chosen in the Vocabulary submenu — one word per line:

```text
abandon|[əˈbændən] v. to give up|Those who abandon themselves to despair can not succeed.|那些自暴自弃的人无法成功。
```

That is `word|meaning|example|exampleTranslation` — the last two columns are optional. Also accepts `word|meaning`, tab-separated, `word - meaning`, `word,meaning`, or plain words; `#` starts a comment.

Progress file: `~/.config/wordbar/memorized.txt`.

A ready-made CET-4 list (4,027 words with phonetics, POS, bilingual examples) is bundled at `data/cet4-words.txt` — copy it into place to start. `scripts/apkg2words.py` can also convert Anki `.apkg` decks into this format (see its usage docstring).

## Menu Bar Cheat Sheet

| Area | Action |
|---|---|
| `✓` | Memorized — advance to next word |
| Word (left/right click) | Open menu |
| Bar text | Scroll horizontally when it overflows |
| Cmd + drag | Dragging it off the menu bar quits the app |

## Project Layout

```text
macos-wordbar/
├── main.swift              # entire app source (single file)
├── Info.plist              # bundle config (LSUIElement, no Dock icon)
├── build.sh                # compile + package + sign
├── AppIcon.icns / icon.png # app icon
├── data/                   # vocabulary data (.apkg decks stay local, gitignored)
│   └── cet4-words.txt      #   converted CET-4 word list (4,027 words)
└── scripts/
    ├── apkg2words.py       #   Anki .apkg -> words.txt converter
    └── gen_icon.swift      #   icon generator
```

## License

MIT
