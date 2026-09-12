// moon.mod for conglinyizhi/precss
// A pluggable CSS preprocessor compile facade for MoonBit.
//
// To add a dependency:
//   moon add <module>@<version>
name = "conglinyizhi/precss"

version = "0.1.4"

readme = "README.mbt.md"

repository = "https://github.com/conglinyizhi/precss"

license = "Apache-2.0"

keywords = [
  "css",
  "scss",
  "sass",
  "less",
  "preprocessor",
  "compiler",
  "facade",
]

preferred_target = "native"

description = "A pluggable CSS preprocessor compile facade: a single function turns SCSS / LESS / CSS source (or file) into CSS, routing to swappable backend engines."

import {
  "moonbitlang/async@0.21.2",
  "moonbitlang/x@0.5.1",
  "conglinyizhi/toml@0.1.0",
}
