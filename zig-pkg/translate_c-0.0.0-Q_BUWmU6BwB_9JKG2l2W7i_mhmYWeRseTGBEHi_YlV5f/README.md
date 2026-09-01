# Translate-C

A Zig package for translating C code into Zig code, intended to replace
`@cImport` and `zig translate-c`.

This branch tracks Zig 0.16.x. Other branches track other versions of Zig.

## Usage

Add `translate-c` to your `build.zig.zon` with this command:

```
$ zig fetch --save git+https://codeberg.org/ziglang/translate-c
```

Then, within your `build.zig`, write something like this:

```zig
// An abstraction to make using translate-c as simple as possible.
const Translator = @import("translate_c").Translator;

const translate_c = b.dependency("translate_c", .{});

const t: Translator = .init(translate_c, .{
    .c_source_file = b.path("to_translate.h"),
    .target = target,
    // This is the optimization mode of the C code being translated and
    // the resulting Zig code.
    .optimize = optimize,
    // more options go here (see below)
});
// If you want, you can now call methods on `Translator` to add include paths (etc).

// Depend on the translated C code as a Zig module.
some_module.addImport("translated", t.mod);
// ...or, if you want to, just use the output file directly.
const translated_to_zig: LazyPath = t.output_file;
```

For a more complete usage, take a look at the `examples/` directory.

## Options

The options for the [`build/Translator.zig`](build/Translator.zig) abstraction
are in heavy development. Please see the file directly for more details.
