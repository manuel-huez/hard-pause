# Hard Pause website

The website is a static product page for the native Hard Pause apps. It explains the product and its limits. It does not simulate, store, or enforce blocks.

The selected Low Light design uses locally bundled Recursive typography, deep blue surfaces, cool cloud shading, and an ivory crescent moon. `mascot/` is the shared SVG renderer used by the website and native apps. Preserve its `LICENSE.txt` and `NOTICE.txt` files when packaging it.

Run `python3 -m http.server 8080 --bind 127.0.0.1` from this folder, then open `http://127.0.0.1:8080`.

From the repository root, run `npm run check` and `npm run test:browser`. The checks cover formatting, lint, local-only assets, content security policy, narrow layouts, reduced motion, and the shared mascot renderer.

The `Deploy website to GitHub Pages` workflow builds and publishes this folder when `main` changes. GitHub Pages uses the workflow source and serves the site at `https://manuel-huez.github.io/hard-pause/`. The packaging script checks project-relative asset paths before upload.
