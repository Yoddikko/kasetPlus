# KasetPlus website

Static landing page for GitHub Pages. It has no build step or runtime dependencies.

## Run locally

From the repository root:

```bash
python3 -m http.server 4173 --directory website
```

Then open <http://localhost:4173>.

## Deployment

`.github/workflows/pages.yml` publishes this directory when changes reach `main` or when the workflow is started manually.

The download buttons include a verified fallback release and update themselves from the latest public GitHub release when the page loads.
