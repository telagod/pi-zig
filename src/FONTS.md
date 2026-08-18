# snapcompact fonts

- `font8x13.bin` — X.Org misc-fixed 8x13 (ISO10646). Latin, box drawing, halfwidth kana.
- `snapcjk.bin` — 16×16 1-bit CJK / kana / hangul extracted from Droid Sans Fallback.

Format: magic + count + sorted codepoints + packed rows. See `snapfont.zig`.
