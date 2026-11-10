# lapentor360

Downloads every panorama of a public [Lapentor](https://lapentor.com) tour as 360° images.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/lapentor360 https://app.lapentor.com/sphere/<slug> [out-dir]
```

Needs Zig 0.17 and, for stitching, `ffmpeg` on `PATH`.

Each scene ends up in `out-dir` (default: the tour slug) as:

- `NN-title.jpg`: equirectangular panorama with GPano metadata, so photo apps open it as 360°
- `faces/NN-title/{r,l,u,d,f,b}.jpg`: the original cube faces

Without ffmpeg only the faces are saved. Re-running skips finished files.
