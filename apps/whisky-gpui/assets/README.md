# Original procedural game-cover illustrations

These ten illustrations were authored specifically for this demo with custom geometric drawing code. They depict fictional environments, not real games or copyrighted game artwork. No stock images, downloaded textures, fonts, generative-image services, network requests, or external art inputs are used. Titles are deliberately absent so the UI can overlay them.

## Reproduce offline

From the repository root:

```sh
python3 apps/whisky-gpui/tools/generate_covers.py
```

Requires Python 3.9+, Pillow, and NumPy. The environment used to generate the checked-in images already contained **Python 3.9.6, Pillow 11.3.0, and NumPy 2.0.2**; no packages were installed. The script uses fixed, scene-specific seeds for both Python's RNG and NumPy's RNG. Repeated generation with these dependency versions is byte-for-byte deterministic. Other dependency versions may change resampling or PNG encoding slightly.

Optional single-image generation or output override:

```sh
python3 apps/whisky-gpui/tools/generate_covers.py --only astral
python3 apps/whisky-gpui/tools/generate_covers.py --output /tmp/whisky-covers
```

## Artwork and dimensions

All files are **1000 × 700 pixels**, RGB, lossless PNG, landscape format. Shapes are first rendered at 1500 × 1050, then finished with subtle fixed-seed fine grain, a cinematic vignette, and Lanczos downsampling. Geometric foregrounds, layered atmospheric gradients, reflections, and tiny architectural details create a coherent visual language with distinct scene palettes.

| File | Original scene | Palette |
| --- | --- | --- |
| [astral.png](astral.png) | Ringed moon over a mountain lake | Indigo, lavender, muted silver |
| [ember.png](ember.png) | Smoking volcanic summit and incandescent lava river | Charcoal, terracotta, amber |
| [tide.png](tide.png) | Lighthouse above rippling sunset ocean | Deep teal, sea glass, warm cream |
| [verdant.png](verdant.png) | Forest gorge, waterfall, and narrow bridge | Forest green, jade, mist gold |
| [neon.png](neon.png) | Rainy futuristic waterfront skyline | Midnight blue, dusty rose, cyan |
| [orbit.png](orbit.png) | Orbital station beside a banded gas giant | Ink blue, steel, pale sand |
| [dune.png](dune.png) | Eclipsed desert, sweeping dunes, and distant obelisk | Plum shadow, copper, ochre |
| [frost.png](frost.png) | Aurora-lit ice mountains and fractured fjord | Polar blue, mint, icy white |
| [echo.png](echo.png) | Ruined monumental gate and floating fragments | Violet, mauve, soft blush |
| [lumen.png](lumen.png) | Sunlit stepped sanctuary in an alpine valley | Slate, sandstone, luminous gold |

## Provenance and scope

The complete source is [the cover generator](../tools/generate_covers.py). Every pixel comes from its mathematical gradients, Pillow primitives, seeded stochastic details, and NumPy grain. These original assets were created for this repository and may be used and modified with the project; no additional third-party artwork attribution is needed. This note does not change the repository's licensing terms.
