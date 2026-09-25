# Einstein Ring

A live wallpaper for macOS. A black hole bends the light of the stars behind it, the Milky Way drifts across the sky, and somewhere in the lower left sits one small pale blue dot.

![A black hole with a glowing accretion disk, surrounded by lensed stars and the Milky Way](docs/hero.jpg)

## Install the wallpaper

**[Download Einstein Ring for Mac](https://github.com/danish-puri/einstein-ring/releases/latest/download/Einstein-Ring.dmg)**

For Apple silicon Macs (M1 or newer), with macOS Ventura 13 or later. The wallpaper video is included. **No Terminal, Xcode, Homebrew, or rendering required.**

1. Open the downloaded disk image and drag **Einstein Ring** into **Applications**.
2. Open **Einstein Ring** from Applications and choose **Start Wallpaper**.
3. Use the **✨ menu bar icon** to pause motion or enable **Open at Login**.
4. Eject the disk image. The installed app plays offline.

**First-open approval:** the current release is not signed with an Apple Developer ID or notarized. If macOS blocks it, first try opening the app, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. Only approve the download from this repository. See [Apple's instructions](https://support.apple.com/en-us/102445); you do not need to disable Gatekeeper or use Terminal.

A [ZIP download](https://github.com/danish-puri/einstein-ring/releases/latest/download/Einstein-Ring.zip) is also available: unzip it and move the app to Applications.

I wanted a desktop that quietly reminds me how big the universe is. My first version rendered a black hole shader live in a web view, and it kept the GPU of my fanless MacBook Air at 95 to 100 percent all day. This version does the heavy work once. A Metal ray tracer renders a seamless 48 second loop, and a small native player shows it behind the desktop icons using the Mac's hardware video decoder.

<p align="center">
  <img src="docs/loop.gif" width="480" alt="The accretion disk spinning while background stars stream around the black hole">
  <br>
  <sub>The loop at 8x speed</sub>
</p>

## What is in the picture

- **A black hole** with a thin accretion disk. The inner disk orbits faster than the outer disk, and the side moving toward the camera looks brighter and bluer because of Doppler beaming and gravitational redshift.
- **Gravitational lensing.** Every pixel follows a light ray through curved spacetime, so the far side of the disk shows up above and below the black hole, and background stars stream around it as the camera drifts. Stars almost directly behind it stretch into a thin circle of light called an Einstein ring, which gives the project its name.
- **The Milky Way**, a faint band of stars with dark dust lanes, bent into an arc where it passes behind the black hole.
- **Distant galaxies.** Each faint smudge is a whole galaxy. One small spiral sits in the upper left.
- **A pale blue dot** in a small clear patch with a faint beam of light through it. It is a nod to the photo Voyager 1 took of Earth in 1990 from about six billion kilometers away. I explain the idea [below](#why-a-pale-blue-dot).

| Black hole | Pale blue dot |
| --- | --- |
| ![Close-up of the black hole and its lensed accretion disk](docs/black-hole.jpg) | ![Close-up of the pale blue dot with a soft cyan glow](docs/pale-blue-dot.jpg) |

## Why a pale blue dot

Voyager 1 launched in 1977, flew past Jupiter and Saturn, and kept heading out of the solar system. On February 14, 1990, at Carl Sagan's urging, NASA turned its camera around one last time to photograph home. From about six billion kilometers away, roughly 40 times the distance from Earth to the Sun, Earth came out smaller than a single pixel. It happens to sit inside a streak of sunlight that scattered inside the camera, so by pure chance the whole planet looks caught in a beam of light.

Sagan named the photo Pale Blue Dot and later wrote a book with the same title. His point was that everyone we have ever loved, every person in history, every war and every discovery happened on that speck, which he called "a mote of dust suspended in a sunbeam." From far enough away, the things we fight over look very small. He did not mean that as a sad thought. He meant it as a reason to be kinder to each other and to take care of the only home we have.

That idea is why I built this wallpaper. The cyan dot in the lower left, in its faint beam, copies the photo. Around it is everything that dwarfs it, a black hole, a Milky Way full of stars, and galaxies that each hold billions more. The dot is easy to miss at first, and that is on purpose. I wanted it to show up on a second look, the same way Earth does in Voyager's photo.

## How it works

**Rendering** (`scene.metal`, `render.swift`). A Metal compute kernel traces one light ray per pixel, and four per pixel near the black hole where lensing stretches the stars. Rays follow the Schwarzschild photon equation x″ = −1.5 h² x / r⁵, integrated with leapfrog steps that shrink near the horizon. When a ray crosses the disk plane, I shade the disk with a blackbody color, a combined Doppler and gravitational shift, and turbulent noise. Rays that escape sample a procedural sky of stars, galaxies, and the Milky Way. A bloom pass built on Metal Performance Shaders and ACES tone mapping finish each frame. The frames go to ffmpeg as 16 bit RGB for hardware HEVC Main 10 encoding.

**A loop with no seam.** The camera moves on a closed path. The disk texture cannot simply repeat, because inner rings orbit faster than outer ones, so I blend two copies of the pattern one loop apart and correct the blend so its contrast stays constant. In the rendered frames, the jump from the last frame back to the first is the same size as any ordinary step between frames.

**Playback** (`wallpaper.swift`). A small AppKit app puts an `AVPlayerLayer` window on every display, just above the desktop picture and below the icons. It pauses when windows fully cover the desktop, when the displays sleep, and in Low Power Mode, and it never keeps the display awake. The app bundles the video and still, uses macOS's login-item controls for optional startup, and prevents duplicate app instances. It leaves the system desktop picture unchanged, so quitting reveals it again.

## Performance

Measured on my MacBook Air with an M2 chip and 8 GB of memory.

| | GPU busy | CPU | Memory |
| --- | --- | --- | --- |
| My earlier live shader wallpaper | 95 to 100% | about 20% of one core | about 145 MB |
| This wallpaper, playing | about 12%, against 5% with nothing playing | about 3% of one core | about 160 MB, mostly decoded frames |
| This wallpaper, paused behind windows | no added load | 0% | same |
| Rendering the loop, once | 100% for about 3.5 minutes | | |

The video is 2880 × 1864 at 30 frames per second, 48 seconds long, and about 130 MB.

## Controls and removal

- **Pause Motion / Resume Motion** in the ✨ menu controls animation.
- **Open at Login** starts the app when you sign in. This is off until you enable it.
- If macOS requires login-item approval, choose **Approve Login Startup…** in the same menu.
- **Quit Wallpaper** reveals your existing desktop picture. If Open at Login is enabled, the app returns the next time you sign in.
- To uninstall, turn off **Open at Login**, quit, then move Einstein Ring from Applications to the Trash.

**Upgrading from `wallpaper.sh`:** the app offers to stop the old player and remove its login item. Choose **Replace**, then enable Open at Login in the new app if desired. Your rendered files and current desktop picture stay in place.

## Troubleshooting

- **macOS blocks the app:** follow the first-open approval above. Avoiding the unidentified-developer warning requires a future Developer ID signed and notarized release.
- **The picture is still:** check Pause Motion and Low Power Mode. Animation also pauses while every wallpaper window is covered or the displays are asleep.
- **Open at Login does not work:** launch the app from Applications, then check **System Settings → General → Login Items**. A mixed mark in the app's menu means macOS approval is pending; clicking Open at Login again disables the pending registration.
- **Cannot find the controls:** look for ✨ in the menu bar. On a crowded menu bar, close another menu bar app to make room.
- **Missing video or playback error:** download a fresh copy and replace the entire app in Applications. The app reports errors in a dialog; playback details also appear in Console under `EinsteinRing`.

Built for macOS 13 and later; local playback is tested on macOS 26 with an M2 MacBook Air. CI builds and validates the package on macOS 15. Multi-monitor layouts, Spaces/fullscreen transitions, and login after a reboot still benefit from testing on more Macs. [Report a problem](https://github.com/danish-puri/einstein-ring/issues) with your macOS version and Mac model.

## Build or customize it (developers)

The instructions below are only for changing the source or producing a new render. Playing the downloaded app does not require development tools.

- Apple silicon Mac and Xcode Command Line Tools (`swiftc`).
- ffmpeg only if rendering a new video (`brew install ffmpeg`).

To build the app using the existing render:

```sh
git clone https://github.com/danish-puri/einstein-ring.git
cd einstein-ring
# Download cosmos.mp4 and cosmos.png from the v1.0 release into this folder.
./build-app.sh
./tests/verify-app.sh
```

The app is at `build/app-package/Einstein Ring.app`; the DMG, ZIP, and checksums are in `dist/`. The build is ad-hoc signed by default. [Packaging and signing instructions](app/RELEASING.md) explain Developer ID signing, notarization, and validation. GitHub Actions also builds downloadable artifacts on changes to `main` and pull requests.

To render your own wallpaper:

```sh
./render-video.sh        # renders cosmos.mp4 and cosmos.png, about 3.5 minutes of full GPU load
./build-app.sh           # bundles the new render into the app
```

The original raw media remain available in [release v1.0](https://github.com/danish-puri/einstein-ring/releases/tag/v1.0).

I render the loop at 2880 × 1864, the native resolution of my display. For a different screen, change `W` and `H` at the top of `render-video.sh`. The player scales the video to fill any display either way.

The older developer-only `./wallpaper.sh install`, `start`, `stop`, and `uninstall` commands remain available. That installer changes the system desktop picture, and its uninstall command sets plain gray; the new app does neither. Use one installation method at a time.

## Making it your own

The look lives in `scene.metal`. The constants at the top set the camera distance (`CAM_DIST`), where the black hole sits on screen (`TARGET`), and the size of the disk (`DISK_IN`, `DISK_OUT`). The three `starLayer` calls in `sky` set how many stars there are and how bright they look. After a change, run `./render-video.sh` and `./build-app.sh`, quit the installed app, and replace it with the new build.

## Credits

The blackbody color fit comes from Tanner Helland. The little blue dot comes from the Voyager 1 photograph and Carl Sagan's book *Pale Blue Dot*.

## License

MIT. See [LICENSE](LICENSE).
