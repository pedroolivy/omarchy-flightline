# Third-party data and code

## Map data — `assets/earth.png`, the blue channel of `assets/lights.png`, `assets/places.json`

Derived from [Natural Earth](https://www.naturalearthdata.com/) 1:10m vector
data (land, minor islands, lakes, country boundaries, first-level
administrative boundaries and populated places). Natural Earth is in the
public domain. Coast and borders were baked into distance-field textures by
`tools/build-textures.sh` (`geo2bin.py`, `sdfbake.c`), which leaves out lakes
too thin to draw at that resolution; places were repacked by
`tools/build-geo.py`. No other source was used.

## Relief, sea depth and elevation — `assets/terrain.png`

Derived from NOAA's [ETOPO1 1 Arc-Minute Global Relief Model](https://www.ncei.noaa.gov/access/metadata/landing-page/bin/iso?id=gov.noaa.ngdc.mgg.dem:316)
(Ice Surface, cell-registered grid): NOAA National Geophysical Data Center,
2009, ETOPO1 1 Arc-Minute Global Relief Model, NOAA National Centers for
Environmental Information; Amante, C. and B.W. Eakins, 2009, ETOPO1 1
Arc-Minute Global Relief Model: Procedures, Data Sources and Analysis, NOAA
Technical Memorandum NESDIS NGDC-24, doi:10.7289/V5C8276M (accessed
2026-10-03). ETOPO1 is a work of the US federal government and not subject to
copyright in the United States; NCEI's metadata sets no use constraints
beyond a disclaimer of liability and asks for the citation above. The grid
was turned into a hillshade, a depth and an elevation channel and
downsampled by `tools/build-terrain.sh` (`terrainbake.c`); land and sea follow
the Natural Earth coast of `assets/earth.png`. NOAA does not endorse
Flightline.

## Night lights — red and green channels of `assets/lights.png`

Derived from NASA Earth Observatory's
[Black Marble 2016](https://earthobservatory.nasa.gov/features/NightLights)
global night-lights composite (3 km grayscale GeoTIFF), NASA Earth
Observatory images by Joshua Stevens, using Suomi NPP VIIRS data from Miguel
Román, NASA's Goddard Space Flight Center. NASA imagery is not copyrighted
([NASA media guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/));
the texture was downsampled and blurred by `tools/build-textures.sh`. NASA
does not endorse Flightline.

## Sun, Moon and planets — `SkyModel.js`

Computed at runtime from published formulas; no data files are bundled. The
algorithms follow Jean Meeus, *Astronomical Algorithms* (2nd ed., Willmann-Bell,
1998): the Sun (ch. 25), the Moon with its periodic terms (ch. 47), its phase
(ch. 48), nutation, sidereal time and refraction. The planets use the
approximate Keplerian elements published by NASA JPL's Solar System Dynamics
group (E. M. Standish, "Keplerian Elements for Approximate Positions of the
Major Planets", table 1, valid 1800–2050). JPL does not endorse Flightline.

## Code — `hash32()` in `shaders/globe.frag`

The star-field hash is "Hash without Sine" by David Hoskins
(<https://www.shadertoy.com/view/4djSRW>), used under the MIT License:

> Copyright (c) 2014 David Hoskins.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## Live services (queried at runtime, nothing is bundled)

| Service | Used for | Terms |
|---------|----------|-------|
| [adsb.lol](https://adsb.lol) | aircraft positions (primary), including circles wider than its documented 250 NM | API and data under the [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/) |
| [adsb.fi](https://adsb.fi) open data | aircraft positions (fallback), flight search | personal, non-commercial use only; adsb.fi must be cited with a link to its home page (this line and the README credits) |
| [adsbdb](https://www.adsbdb.com) | routes, airline codes | the flight route data is the work of David Taylor, Edinburgh and Jim Mason, Glasgow, and may not be copied, published or incorporated into other databases without permission: Flightline displays it and keeps it in memory only |
| [Open-Meteo](https://open-meteo.com) geocoding | city search | free for non-commercial use, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); location data based on GeoNames |
| [wttr.in](https://wttr.in) | IP-based location estimate | same request Omarchy's weather panel makes |
| [BeaconDB](https://beacondb.net) | opt-in Wi-Fi location | public-domain geolocation service |

Aircraft positions are turned into a data texture and a small index on tmpfs
(`$XDG_RUNTIME_DIR/flightline/`) for the current session only; Flightline
does not keep, publish or redistribute feed data.
