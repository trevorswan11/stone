# stone [![Zig](https://img.shields.io/badge/zig-0.15.2-orange)](https://ziglang.org/) [![License](https://img.shields.io/github/license/trevorswan11/stone)](LICENSE) [![Last commit](https://img.shields.io/github/last-commit/trevorswan11/stone)](https://github.com/trevorswan11/stone) [![Formatting](https://github.com/trevorswan11/stone/actions/workflows/format.yml/badge.svg)](https://github.com/trevorswan11/stone/actions/workflows/format.yml) [![CI](https://github.com/trevorswan11/stone/actions/workflows/ci.yml/badge.svg)](https://github.com/trevorswan11/stone/actions/workflows/ci.yml)

<p align="center">
  <img src="/.github/resources/logo.jpg" alt="stone logo" width="250"/>
</p>

<p align="center">
  A 3D Fluid Simulation Engine Written in Zig.
</p>

# Getting Started
For a quick build of the project (assuming you have the dependencies listed below), simply run:
```sh
git clone https://github.com/trevorswan11/stone
cd stone
zig build run --release=fast
```

## Build Tools
- [Zig 0.15.2](https://ziglang.org/download/) - other versions _will not_ work due to 'Writergate' and other potentially breaking changes
- [Vulkan](https://vulkan.lunarg.com/) - This is the single dependency not included with the repository and is required for running any GPU-facing code
- [cloc](https://github.com/AlDanial/cloc) for the cloc step (optional)

### Important Considerations
- Stone is developed with Vulkan v1.4.309.0, but other versions likely work
- It goes without saying that you need a system capable of handling Vulkan
- Stone currently supports MacOS, Windows, and Linux (X11 only). Wayland support is planned but is not a priority

## All Build Steps
| **Step**    | Description                                                                                      |
|:------------|:-------------------------------------------------------------------------------------------------|
| `build`     | Builds `stone`. Pass `--release=fast` for ReleaseFast.                                           |
| `run`       | Build and run `stone`. Pass `--release=fast` for ReleaseFast.                                    |
| `test`      | Run all unit tests.                                                                              |
| `lint`      | Checks formatting of all source files excluding `build.zig`.                                     |
| `fmt`       | Format all source code excluding `build.zig`.                                                    |
| `cloc`      | Count the total lines of zig code. Requires [cloc](https://github.com/AlDanial/cloc).            |
| `clean`     | Recursively delete the `zig-out` directory. This a workaround for the buggy `uninstall` command. |

Once wayland is supported, Linux users can specify their graphics backend by using the `-Dwayland` flag during the build process. When this flag is not passed, X11 is chosen as the backend. Windows users are also able to disable the console which pops up when running the bare executable by passing the `-Dwindow` flag when building. This flag is automatically enabled for ReleaseFast and ReleaseSmall builds.

# Contributing
While this is mainly a solo project, contributors are always welcome! This is my second project involving graphics rendering, so I have a lot to learn and would benefit from any external contributions. Checkout [CONTRIBUTING.md](.github/CONTRIBUTING.md) for the project's guidelines.

_This project's logo was created by Google Gemini 2.5_