# Screenshot requirements checklist

Source: Apple, [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) (fetched 2026-10-28; re-check in App Store Connect before uploading, Apple adds sizes with each device generation).

General: 1 to 10 screenshots per device size and localization; `.jpeg`, `.jpg` or `.png`; **no alpha/transparency**; use the same Apple Watch size in every localization. If you supply only the largest required size, App Store Connect scales it down for smaller devices.

## iPhone (the iOS target is iPhone-only: `TARGETED_DEVICE_FAMILY = 1`, so **no iPad screenshots**)

* **Mandatory:** at least one screenshot for the **6.1"/6.3" "Dynamic Island (medium)"** class: **1179 × 2556** or **1206 × 2622** px portrait (landscape: swap). Other accepted sizes (not required if a larger one is given), among others: 1260 × 2736, 1290 × 2796, 1320 × 2868 (Dynamic Island, large); 1284 × 2778 and 1242 × 2688 (Face ID, large); 1170 × 2532; 1125 × 2436; 750 × 1334.
* **Face ID (large display)** 1284 × 2778 or 1242 × 2688 is required **only** if you do not provide a Dynamic Island (large) size. Simplest: provide **1320 × 2868** (or 1290 × 2796) and **1206 × 2622** (or 1179 × 2556).

## Apple Watch (required, because the app has a watch app)

Provide **one** of these sizes (pick the newest device you can capture, use it in every language):

| Pixels | Devices |
|---|---|
| 422 × 514 | Ultra 4, Ultra 3 |
| 410 × 502 | Ultra 2, Ultra |
| 416 × 496 | Series 12, 11, 10 |
| 396 × 484 | Series 9, 8, 7 |
| 368 × 448 | Series 6, 5, 4, SE 3, SE 2, SE |
| 312 × 390 | Series 3, 2, 1 |

The app's deployment target is watchOS 9, so older sizes remain valid; one size is enough.

## Suggested content (no Mac needed: use real devices, or simulator screenshots from a CI job later)

1. Watch: reading view with a paragraph of public-domain text.
2. Watch: word lookup with a definition.
3. Watch: library list.
4. iPhone: Library with a book and "watch connected" status.
5. iPhone: Reading (typography) tab with live preview.
6. iPhone: Sync tab with a **demo server and fake username** (never real credentials).

Rules: use only public-domain or your own book text and covers; do not show KOReader/Readest logos or UI; no status bars with real names/carrier; no claims that are not in the app (e.g. "free dictionary offline"). An optional app preview video is not required.

Getting screenshots without a Mac: take them on your iPhone (Side + Volume Up; they come out at the device's native size, e.g. 1206 × 2622 on iPhone 16/17 Pro) and on the watch (Settings → General → Screenshots enabled, then Side + Digital Crown; they sync to the iPhone Photos app). Check the pixel size against the table before uploading.
