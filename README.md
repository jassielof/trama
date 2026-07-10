# Trama

Trama is a text templating library for generating structured plain-text output
(CLI reference pages, AsciiDoc/Markdown, config files, and similar). It uses
Go [`text/template`](https://pkg.go.dev/text/template)–compatible `{{ ... }}`
syntax, with a small set of documented Trama extensions.

## Go-compatible features

- Interpolation and pipelines: `{{ .name }}`, `{{ .x | default "-" | printf "%s" }}`
- Whitespace trim: `{{-` and `-}}`
- Comments: `{{/* ... */}}`
- Conditionals: `{{ if }}` / `{{ else if }}` / `{{ else }}` / `{{ end }}`
- Loops: `{{ range }}` / `{{ else }}` / `{{ end }}`, plus `{{ break }}` / `{{ continue }}`
- Range variables: `{{ range $i, $v := .items }}`
- `{{ with }}` / `{{ else }}` / `{{ end }}`
- Variables: `{{ $x := pipeline }}`, `{{ $x = pipeline }}`
- Named templates: `{{ define "name" }}` / `{{ template "name" pipeline }}` / `{{ block "name" pipeline }}`
- Dot and root: `.`, `$`, `$.field`
- Builtins: `and`, `or`, `not`, `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `len`, `index`, `slice`, `print`, `printf`, `println`, `default`, `join`

## Trama extensions (not in Go)

- Raw output (skip escape mode): `{{ @raw usage }}`
- AsciiDoc helpers: `{{ anchor path }}`, `{{ adoc_escape value }}`
- `Options.escape_mode`: `none`, `asciidoc`, `html`, `url` (content escaping for interpolations)

## API

```zig
const trama = @import("trama");

// One-shot
const out = try trama.renderAlloc(allocator, template, context_struct, .{ .escape_mode = .asciidoc });
defer allocator.free(out);

// Parse once, execute many
var tmpl = try trama.Template.parse(allocator, template);
defer tmpl.deinit();
const out2 = try tmpl.executeStruct(allocator, context_struct, .{});
defer allocator.free(out2);
```

Custom functions can be registered via `FuncMap` and passed in `Options.funcs`.

## Credits

- [Go text/template](https://pkg.go.dev/text/template/)
- [Zkittle](https://codeberg.org/bcrist/zkittle)
