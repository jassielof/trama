# Trama

Trama is a text templating library for generating structured plain-text output, including CLI reference pages, AsciiDoc/Markdown documentation, configuration files, source files, and task-runner command strings. It uses familiar `{{ ... }}` template blocks while keeping the design explicit and predictable: typed data contexts, custom functions, configurable escaping, and a rendering model suited for Zig.

## Syntax

Trama uses `{{ ... }}` delimiters. This is intentionally different from Zkittle's slash-style command blocks: double braces are familiar from Go templates, Jinja, Django, Handlebars, and Taskfile, while avoiding AsciiDoc's single-brace attributes, shell `${VAR}` syntax, and slash/comment conflicts.

The v0 renderer supports:

- Interpolation: `{{ name }}`, `{{ command.display_path }}`
- Raw output: `{{ @raw usage }}`
- Conditionals: `{{ if description }}...{{ else }}...{{ end }}`
- Loops: `{{ range commands }}{{ .display_path }}{{ end }}`
- Fallbacks and helpers: `{{ default value "-" }}`, `{{ join values ", " }}`
- Escape modes: `none`, `asciidoc`, `html`, and `url`

AsciiDoc escaping currently protects rendered braces by converting `{` to `\{` and `}` to `\}`. Trusted template-controlled markup can opt out with `@raw`.

## Credits, inspiration & acknowledgements

- [Go templates](https://go.dev/pkg/text/template/)
- [Zkittle](https://codeberg.org/bcrist/zkittle)
