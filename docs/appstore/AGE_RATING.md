# Age rating questionnaire

Based on the categories in Apple's [age ratings reference](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions) (re-read the live questionnaire in App Store Connect: wording and tiers change). The app ships no content of its own; users import their own books.

| Category | Answer |
|---|---|
| Parental controls | No |
| Age assurance | No |
| Unrestricted web access | **No** (no web view or browser; only fixed dictionary API calls and the user's sync server) |
| User-generated content | **No** (nothing is shared with other users) |
| Social media | No |
| Messaging and chat | No |
| Advertising | No |
| Profanity or crude humor | None |
| Horror / fear themes | None |
| Alcohol, tobacco, drugs | None |
| Medical or treatment information | None |
| Health or wellness topics | No |
| Mature / suggestive themes | None |
| Sexual content or nudity (incl. graphic) | None |
| Cartoon/fantasy violence, realistic violence, graphic violence, guns/weapons | None |
| Gambling, simulated gambling, contests, loot boxes | None / No |

Expected result: **4+**.

Caveats for the owner: (1) the app can display whatever EPUB the user imports and shows dictionary definitions from Wiktionary, which may contain vulgar words; the app itself does not curate or ship content. Many e-reader apps answer "None" for the same reason; if you want to be conservative, answer "Infrequent" for profanity (→ 9+). (2) Also set a Korea/Brazil/Australia-specific answer only if the questionnaire asks.
