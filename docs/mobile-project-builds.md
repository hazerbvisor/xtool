# On-device app builds and unsigned IPA export

XTool Mobile can build a declared app graph using the embedded Swift frontend,
Clang frontend and Mach-O LLD. It compiles Swift modules in dependency order,
links the objects, creates `Payload/<Name>.app`, writes Info.plist, copies
resources and exports an unsigned IPA. It never invokes codesign or provisions
an app. Sign the exported IPA using your existing signing app.

## First device test

1. Install the updated XToolMobileApp IPA built with the one-shot script.
2. Open the Build inspector and choose **New Example App**.
3. Choose **Build Unsigned IPA** (or the toolbar Build button / Command-B).
4. Choose **Export Unsigned IPA…** and save or share the result.

The example contains a `Greeting` dependency and two Swift app source files.
It exercises module emission, cross-module imports, SwiftUI linking and IPA
packaging. The previously successful Hello.swift object probe alone does not
validate this complete app pipeline; the first device build remains necessary.

Every build has its own output folder and `build.log` under Documents/Builds.
Compiler/linker errors stop the build. Failed builds do not publish an IPA.
Cancellation takes effect between compiler/linker calls, because native frontend
calls cannot be safely interrupted inside the app process.

## A mobile project

Open a folder containing `xtool-mobile.json`. Source paths are relative to that
folder; directories are expanded into source files. A minimal project is:

```json
{
  "schemaVersion": 1,
  "name": "MyApp",
  "bundleIdentifier": "com.example.myapp",
  "deploymentTarget": "16.0",
  "executableTarget": "MyApp",
  "frameworks": ["SwiftUI", "UIKit", "Foundation"],
  "targets": [
    {"name": "Utilities", "sources": ["Sources/Utilities"]},
    {"name": "MyApp", "sources": ["Sources/MyApp"], "dependencies": ["Utilities"]}
  ],
  "resources": [{"path": "Resources/message.txt", "destination": "message.txt"}]
}
```

Optional target settings:

- `headerSearchPaths`: project-relative include directories.
- `moduleMap`: a Clang module map exposing C/Objective-C/C++ declarations to Swift.
- `swiftFlags`: **frontend** flags, not Swift driver flags.
- `cFlags`: **cc1** flags, not Clang driver flags.
- `parseAsLibrary`: override the normal library / `@main` heuristic. A file named
  `main.swift` defaults to top-level entry-point semantics.

Optional app settings:

- `linkFiles`: existing object/static-library files to pass to LLD.
- `librarySearchPaths`, `moduleSearchPaths`, `libraries`, `frameworks`.
- `resources`: files or directory trees and their destinations within the app.
- `infoPlist`: project-relative custom plist (privacy strings, URL schemes, etc.).
  Executable identity and deployment target still come from the build manifest.
- `shortVersion`, `buildVersion`.

Compiler flags may use `${PROJECT}`, `${BUILD}`, `${SDK}` and `${SWIFT_RESOURCES}`.
These are expanded to the current device paths. Source/resource inputs must stay
inside the imported project. Missing dependencies, cycles, invalid archive paths
and collisions with the executable or Info.plist are rejected.

Swift targets emit one object and one module each. Native `.c`, `.m`, `.mm`,
`.cc`, `.cpp`, `.cxx` files emit separate objects. Dependency objects are linked
into the app. Swift's Mach-O autolink records supply its runtime/framework links.
The current build runs sequentially and recompiles the selected source targets
on each attempt; it does not rebuild XTool's installed compiler engine.

## SwiftPM projects

Arbitrary `Package.swift` evaluation, dependency fetching, build-tool plugins and
macro executables are **not yet available on-device**. Use the existing host
SwiftPM installation to resolve/build a product once, then export its build graph:

```bash
python3 scripts/prepare-mobile-project.py \
  --project /path/to/project \
  --product MyApp \
  --bundle-id com.example.myapp \
  --output /path/to/MyApp-Mobile \
  --zip
```

The host must have the working Swift 6.3.2 Darwin cross SDK setup. The tool uses
`description.json`, `Objects.LinkFileList` and the real driver's `-###` frontend
jobs from a successful iOS build. It does not approximate SwiftPM's manifest
language with a text parser. Use `--target` when the product and executable
module names differ. `--skip-build` reuses an already successful host build.

The exported project includes:

- Swift source modules and their resolved dependency order;
- native dependency objects from the host build;
- generated sources, resource bundles and Clang header/module-map inputs;
- `Package.resolved` when present and a preparation record.

Swift modules are rebuilt on iPad. The imported native dependency objects and
generated files stay frozen until preparation is run again. Updating package
dependencies, native dependency code, build generators or the SDK requires a
new preparation. Runtime macro executables and explicit-module build plans are
rejected with an error. Hand-authored mobile projects can compile native source
targets directly.

For custom static libraries not present in Objects.LinkFileList, supply
`--link-file /path/to/library.a`; `--framework` and `--library` are repeatable.
Custom dynamic libraries must be available under the host build directory with
their `@rpath` name. Asset catalogs, storyboards, Metal shaders and other resources
requiring Apple build tools must be compiled on the host and supplied as assets;
this exporter is not an Xcode project or build-plugin runner.

## Preparing an XTool app rebuild

After building the updated app successfully in Debian:

```bash
cd /root/xtool-ios
python3 scripts/prepare-mobile-project.py \
  --product XToolMobileApp \
  --bundle-id sh.xtool.mobile \
  --skip-build \
  --output /sdcard/Download/XToolSelfBuild \
  --zip
```

Transfer the ZIP to the iPad, extract it in Files, and open the extracted project
folder in XTool. Choose a fresh output name if that host export folder exists.
The exporter marks XToolMobileApp to reuse the installed
`libXToolCompilerEngine.dylib` and `MobileRuntime.tar`. Thus the output includes
the compiler engine and SDK archive required by the rebuilt app.

This implements an experimental route to rebuild XTool's Swift app and Swift
dependencies on-device with prepared native dependency objects. It does not
rebuild the Swift/LLVM compiler engine, run CMake/Ninja on iPad, or establish that
the full self-build has succeeded on a device. Keep the working installed IPA
while testing the new output.

## Verification

Run `bash scripts/test-mobile-project.sh` on a host with Swift installed. It
compiles the portable builder/packager and checks dependency ordering, multi-file
jobs, unsigned linking arguments, IPA output, failure handling and archive paths
using a recording compiler. Python tests exercise graph export, path relocation,
header/module-map copying and Mach-O dependency parsing. These tests do not
replace compiling, linking, signing externally and launching the example on iPad.
