# Photo prompts — parseFoodImage (vision surface)

The photo suite is the one folder whose stimuli can't be checked in
as text: the cases are the operator's own photos. Production parity
matters here more than anywhere — the app routes photos to the
**vision model** (`VISION_MODEL` in `AnthropicNutritionApi.kt`,
currently Sonnet) with `max_tokens` 1536 and thinking disabled, and
the eval runner mirrors exactly that (see `scripts/eval/run-eval.sh`).

## Workflow

1. Drop `.jpg` / `.png` / `.webp` / `.gif` files into `images/`
   (gitignored — personal food photos never get published).
2. Run the eval as normal. The runner auto-discovers the files in
   alphabetical order and assigns IDs `P1, P2, …` (capped at 10 per
   run). Photos run after the text suite.
3. Grade with the photo protocol below.

## The standard probe set

Keep at least one photo of each kind in `images/` — each probes a
distinct failure mode of the image rules in `basePrompt`:

| Kind | Probes | Expected |
|---|---|---|
| Plated home-cooked meal | mass-first `reasoning`, specific-ingredient caution | `reasoning` filled (items + gram estimates from visible scale references) BEFORE macros; generic sauce/prep names unless visually unambiguous |
| Branded package, legible logo | brand recognition | Brand named only when clearly readable; macros plausible for the product |
| Branded package, obscure/foreign brand | brand-substitution caution | GENERIC category name ("chocolate-covered biscuit") — never a more-famous brand swapped in, never a garbled brand |
| Nutrition-facts label | verbatim label read | Per-100g column transcribed exactly, grams=100; hard-to-read digits → `low_confidence=true` |
| Non-food (fridge interior, appliance, pet, screenshot) | non-food gate | `foods=[]` — a confident food answer for a non-food image is a hard fail |
| Barcode close-up | barcode gate | `foods=[]` + `refusal_reason="barcode_only"` |
| Low-kcal supplement label (e.g. glycine, 4 kcal) | zero-nutrition overfire | Parsed with its real values — `zero_nutrition` refusal for a >0 kcal product is a FAIL (regression seen 2026-05-06) |

## ⚠ Photo grading — non-negotiable protocol

A well-formed `log_food` call does **not** mean the model saw the
photo correctly. Past runs confidently returned "pears" for a
refrigerator. For every P-row:

1. **Open the actual image file** (`Read` the file in Claude Code).
   Never trust the filename.
2. Compare the model's `name` / `grams` / `kcal` / `emoji` against
   what is actually visible. Brand only if legible; sauce only if
   evident; non-food must round-trip to `foods=[]`.
3. Cite a one-line description of the photo's content in the graded
   sheet so future readers can sanity-check without re-opening it.

The Tool-use axis and the Photo-identification axis are graded
independently — a valid tool call with a hallucinated food passes
the first and fails the second.

## Not yet exercised

- Photo **with a caption** (production `parseImage(caption)` sends
  the caption as an extra text block). The runner sends images
  caption-less; add sidecar-caption support if a caption-dependent
  regression ever shows up.
- LIBRARY-hints block on the photo path (photo + saved-library
  echo). Covered on the text path by V1-V3.
