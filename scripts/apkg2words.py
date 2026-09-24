#!/usr/bin/env python3
"""Convert an Anki .apkg deck to the WordBar vocabulary format:
word|meaning|example|exampleTranslation

Usage: python3 apkg2words.py deck.apkg [output.txt] [--full]
Meanings are shortened by default (up to 2 senses per part of speech);
use --full to keep the complete dictionary text.
Default output: ~/.config/wordbar/words.txt

Note: the field mapping is adapted for the CET-4 deck shared at
    https://ankiweb.net/shared/info/1378032490
(3-field and 9-field note layouts). Other decks use different
field layouts and may need adjustments in convert().
"""
import sqlite3
import re
import html as htmlmod
import sys
import zipfile
import tempfile
import os


def clean(s):
    s = re.sub(r"(?i)<\s*/?\s*br[^>]*>", " ", s)
    s = re.sub(r"(?i)<\s*hr[^>]*>", " ", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = htmlmod.unescape(s)
    return re.sub(r"\s+", " ", s).strip()


def first_numbered(field):
    parts = re.split(r"(?i)<\s*br[^>]*>", field)
    first = clean(parts[0]) if parts else ""
    return re.sub(r"^\(\d+\)\s*", "", first).strip()


def cap_chars(s, n=60):
    return s if len(s) <= n else s[:n].rstrip() + "…"


def shorten_meaning(m):
    """Group senses by part of speech, keep at most 2 per group, cap total length.
    e.g. 'vt. 放弃；抛弃；离弃 n. 放纵；屈从' -> 'vt. 放弃；抛弃 n. 放纵；屈从'"""
    if not m:
        return m
    parts = re.split(
        r"(?i)((?:vt|vi|v|n|adj|adv|prep|conj|pron|num|art|int|aux|abbr)\.)", m)
    if len(parts) <= 2:
        return cap_chars(m)
    out = [parts[0].strip()] if parts[0].strip() else []
    for i in range(1, len(parts) - 1, 2):
        pos, gloss = parts[i], parts[i + 1]
        senses = [s.strip() for s in re.split(r"[;；]", gloss) if s.strip()][:2]
        out.append(pos + " " + "；".join(senses))
    if len(parts) % 2 == 0 and parts[-1].strip():
        out.append(parts[-1].strip())
    return cap_chars(" ".join(out))


def convert(db_path, full=False):
    conn = sqlite3.connect(db_path)
    rows = conn.execute("SELECT flds FROM notes").fetchall()
    out_lines = []
    seen = set()
    for (flds,) in rows:
        f = flds.split("\x1f")
        word = f[0].strip()
        if not word or word in seen:
            continue

        if len(f) >= 8:
            # 9-field compact cards: F4=phonetic F5=meaning F6=EN example F7=ZH example
            ph_raw = clean(f[4])
            m = re.search(r"\[[^\]]+\]", ph_raw)
            ph = m.group(0).replace("'", "ˈ") if m else ""
            meaning = clean(f[5])
            if not full:
                meaning = shorten_meaning(meaning)
            meaning = (ph + " " + meaning).strip() if ph else meaning
            example = first_numbered(f[6])
            translation = first_numbered(f[7])
        elif len(f) >= 3:
            # 3-field dictionary cards: F0=word F1=front(phonetic) F2=back(meaning+examples)
            front, back = f[1], f[2]
            ph = ""
            m = re.search(r"color:blue;'>\s*(\[[^\]]+\])", front)
            if m:
                ph = m.group(1).strip()
            meaning = ""
            m = re.search(r"<div style='color:BlueViolet[^>]*>(.*?)</div>", back, re.S)
            if m:
                meaning = clean(m.group(1))
            if not full:
                meaning = shorten_meaning(meaning)
            meaning = (ph + " " + meaning).strip() if ph else meaning
            example = translation = ""
            for b in re.findall(r'<div style="display:block; margin-left:7pt;">(.*?)</div>', back, re.S):
                te = re.search(r"<font color=#008080>(.*?)</font></font>", b, re.S)
                gr = re.search(r'<font style="color:gray;margin-left:12pt;" ?>(.*?)</font>', b, re.S)
                if te and gr:
                    e, t = clean(te.group(1)), clean(gr.group(1))
                    if e and t:
                        example, translation = e, t
                        break
        else:
            continue

        seen.add(word)
        fields = [x.replace("|", "/") for x in (word, meaning, example, translation)]
        out_lines.append("|".join(fields).rstrip("|"))
    return len(rows), out_lines


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    args = [a for a in sys.argv[1:] if a != "--full"]
    full = len(args) != len(sys.argv) - 1
    apkg = args[0]
    out = args[1] if len(args) > 1 else os.path.expanduser(
        "~/.config/wordbar/words.txt")

    with tempfile.TemporaryDirectory() as td:
        with zipfile.ZipFile(apkg) as z:
            name = "collection.anki21" if "collection.anki21" in z.namelist() \
                else "collection.anki2"
            z.extract(name, td)
            db_path = os.path.join(td, name)
            # anki21 is the newer format; sqlite3 reads both
            total, lines = convert(db_path, full=full)

    with open(out, "w", encoding="utf-8") as fp:
        fp.write("# Converted from Anki deck: " + os.path.basename(apkg) + "\n")
        fp.write("# Format: word|meaning|example|exampleTranslation\n")
        fp.write("\n".join(lines) + "\n")
    print(f"notes: {total}, written: {len(lines)} -> {out}")


if __name__ == "__main__":
    main()
