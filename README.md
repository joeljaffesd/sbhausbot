# hausbot

Daily rental listing monitor for the Santa Barbara, CA area. Scrapes five property management companies, detects new listings, and delivers a consolidated iMessage report.

## Usage

Run all bots and send a single consolidated iMessage:

```bash
./run.sh <recipient> [--dry-run]
```

`recipient` is an iMessage-compatible address (phone number or Apple ID). `--dry-run` prints the message to stdout without sending.

Run a single bot:

```bash
cd wolfebot
./run.sh [recipient] [--dry-run]
```

## Bots

| Bot | Source | Fetch method |
|---|---|---|
| **bartbot** | [bartlein.com](https://www.bartlein.com/rentals/) | PDF download → OCR (`pdftoppm` + `tesseract`) |
| **meribot** | [meridiangrouprem.com](https://meridiangrouprem.com) | HTML scraping |
| **sandpiperbot** | [sandpiperpropertymanagement.com](https://www.sandpiperpropertymanagement.com) | JSON API |
| **sierrabot** | [sierrapropsb.com](https://sierrapropsb.com) | HTML scraping |
| **wolfebot** | [rlwa.com](https://www.rlwa.com) | [r.jina.ai](https://r.jina.ai) rendered markdown |

## Pipeline

Each bot runs the same four-stage pipeline:

```
fetch.sh → parse.sh → compare.sh → report.sh
```

1. **`fetch.sh`** — downloads raw data into `output/YYYY-MM-DD_intermediate/`
2. **`parse.sh`** — extracts structured listings into `YYYY-MM-DD.md`
3. **`compare.sh`** — diffs today's snapshot against the previous run, producing `YYYY-MM-DD_comp.md`
4. **`report.sh`** — formats new listings and sends an iMessage via AppleScript

## Automation

A launchd plist at `~/Library/LaunchAgents/com.joeljaffesd.hausbot.daily.plist` schedules the consolidated run daily at 9:00 AM. Logs are written to `logs/`.

## Dependencies

- `bash` 4+, `python3`, `curl` or `wget`
- **bartbot only:** `pdftoppm` (poppler) and `tesseract`
- macOS Messages app (for iMessage delivery)

## License

MIT — see [LICENSE](LICENSE).