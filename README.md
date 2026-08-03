# West Newberry church of Christ Website

A simple, welcoming one-page site for West Newberry church of Christ (Newberry, FL),
built from the congregation's public Facebook information and its "Who We Are" deck.

## Edit the content
Everything lives in `index.html`. Common edits:
- **Service / Bible-class times**: the "Join Us in Worship & Study" schedule in the hero.
- **Phone & email**: the Contact section (`#contact`).
- **Beliefs**: the "What We Believe" section (`#beliefs`).
- **Photos**: swap the hero building photo in `assets/img/`.

## Run locally
```bash
python3 -m http.server 8000 --directory .
# open http://localhost:8000
```

## Deploy to GitHub Pages
Push to a repo, then Settings → Pages → Deploy from branch → main / (root).
`.nojekyll` is included so asset folders serve as-is.
