# UA seasonal evaluation — May 2026

**Current pack:** v6 · 3 ingredients
**Proposed:** v7 · 7 ingredients · **+5 / ~0 / −1**

Baseline catalog is small (test seeds — Полуниця, Кавун, Огірок).
Today's run focuses on the obvious May-UA additions every Ukrainian
shopper sees on Сільпо / АТБ / market shelves right now, plus one
clearly-out-of-season removal (watermelon).

Cadence note: subsequent runs (next: ~Aug 2026) will swap these
spring rows for summer ones.

---

## ➕ Additions (5)

### 1. Редиска 🫜 (radish) — `seed.UA.radish.v7`

| | |
|---|---|
| Macros (per 100 g) | **16 kcal** · F 0.1 · P 0.7 · C 3.4 |
| Category | `VEGETABLE` |
| Citation | [foodplus.in.ua – Редис](https://foodplus.in.ua/composition-calorie/radish-vegetables.html) |

**Rationale:** Peak season May UA — fresh local радіска з пучками
з'являється в Сільпо/АТБ. The 5.ua and ukranews seasonal-guides
explicitly call out радіска as a May "must-buy".

---

### 2. Зелений горошок (fresh green peas) — `seed.UA.peas-green.v7`

| | |
|---|---|
| Macros (per 100 g) | **76 kcal** · F 0.2 · P 5.0 · C 13.8 |
| Category | `VEGETABLE` |
| Citation | [calorizator.ru – Зелений горошок свіжий](https://calorizator.ru/product/vegetable/green-peas-2) |

**Rationale:** Травневий сезон — молодий зелений горошок у стручках
поступає на ринки в кінці травня. Sanity-check: 5×4 + 0.2×9 + 13.8×4
= 77 kcal ≈ 76 ✓.

---

### 3. Черешня (sweet cherry) — `seed.UA.cherry-sweet.v7`

| | |
|---|---|
| Macros (per 100 g) | **50 kcal** · F 0.4 · P 1.1 · C 11.5 |
| Category | `FRUIT` |
| Citation | [calorizator.ru – Черешня](https://calorizator.ru/product/fruit/cherries) |

**Rationale:** Пізній травень — перші черешні з південних регіонів
України (Херсонська, Одеська). Підтверджено сезонним календарем
5.ua. Sanity: 1.1×4 + 0.4×9 + 11.5×4 = 54 kcal ≈ 50 ✓.

---

### 4. Молода картопля (new potato) — `seed.UA.potato-young.v7`

| | |
|---|---|
| Macros (per 100 g) | **61 kcal** · F 0.4 · P 2.4 · C 12.4 |
| Category | `VEGETABLE` |
| Citation | [tablycjakalorijnosti.com.ua – Картопля молода](https://www.tablycjakalorijnosti.com.ua/stravy/kartoplya-moloda) |

**Rationale:** Травень = початок сезону молодої картоплі (тонка
шкірка, низький вміст крохмалю). The depo.ua / NV / znaimo.gov.ua
articles all flag молода картопля as the iconic May vegetable in UA.
Sanity: 2.4×4 + 0.4×9 + 12.4×4 = 63 kcal ≈ 61 ✓.

---

### 5. Спаржа зелена (green asparagus) — `seed.UA.asparagus-green.v7`

| | |
|---|---|
| Macros (per 100 g) | **28 kcal** · F 0.6 · P 2.9 · C 1.9 |
| Category | `VEGETABLE` |
| Citation | [tablycjakalorijnosti.com.ua – Спаржа зелена](https://www.tablycjakalorijnosti.com.ua/stravy/sparzha-zelena) |

**Rationale:** Спаржа має дуже короткий сезон в Україні —
квітень-травень. Якщо її не додати в травневий пак, вона взагалі
не з'явиться на полицях бібліотеки до наступного року. Sanity:
2.9×4 + 0.6×9 + 1.9×4 = 25 kcal ≈ 28 (fiber accounts for the
small gap) ✓.

---

## 🔄 Updates (0)

The two existing rows we're keeping (Полуниця, Огірок) have
plausible macros (32 kcal and 16 kcal respectively) — no
material divergence vs the cited sources to be worth a rewrite.

---

## 🗑 Removals (1)

### Кавун (watermelon) — `seed.UA.watermelon.v1`

**Rationale:** Out of season in Ukraine in May. The local
watermelon harvest runs **late July – September**; anything on
Ukrainian shelves in May is imported (Greek / Spanish / Turkish).
The seasonal-pack feature is about what's *locally fresh right
now*, so this row belongs in the late-summer pack, not May.

**Effect on users who logged Кавун:** their FoodLog entries keep
their data and render the v0.6 "Шаблон видалено" tag — no history
loss. If the user wants to keep logging watermelon, editing any
log entry will sever the source link and they can save it as
their own ingredient via "Save to Library".

---

## What's NOT proposed (and why)

A few candidates I considered and dropped:

- **Малина (raspberry)** — UA open-field raspberry season starts
  late June, not May. Greenhouse / imported раз is borderline. Wait
  for the August pack.
- **Кріп / петрушка / зелена цибуля (dill / parsley / green
  onion)** — all genuinely in season, but I couldn't ground the
  macros against a UA-specific source within the time budget, and
  I'd rather be conservative than cite a Russian-language source
  for a Ukrainian-locale catalogue. Add in a follow-up run.
- **Salad greens / рукола / spring lettuce** — same as above.

---

## Pack.json shape

The accompanying `pack.json` in this folder is the FULL ingredient
list for v7 — the 2 kept rows (Полуниця, Огірок) plus the 5 new
ones. Кавун is excluded (= the removal). The server replaces the
catalog wholesale on publish; "removal" is "this row is no longer
in the new pack body". The client's reconciler diffs by
`external_id` and soft-hides the missing rows.
