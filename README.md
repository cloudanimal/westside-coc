# Westside church of Christ — Website

A simple, welcoming one-page site for Westside church of Christ (Newberry, FL),
built from the congregation's public Facebook information.

## Edit the content
Everything lives in `index.html`. Common edits:
- **Service / Bible-class times** — the "Times of Worship & Study" section and hero pills.
- **Phone & email** — placeholder note in the Contact section (`#contact`).
- **Photos** — swap the illustrated hero placeholder for a real building photo.
- **Events** — update or remove the "Gospel Meeting" section (`#event`).

## Run locally
```bash
python3 -m http.server 8000 --directory .
# open http://localhost:8000
```

## Deploy to GitHub Pages
Push to a repo, then Settings → Pages → Deploy from branch → main / (root).
`.nojekyll` is included so asset folders serve as-is.

## Placeholders to fill before going public
- Wednesday Bible study time
- Phone number and email
- A real photo of the building
