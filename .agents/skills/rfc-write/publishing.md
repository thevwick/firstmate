# Publishing to Confluence

## The three formats, and which one to use

| Format | What it is | Use it? |
|---|---|---|
| **HTML** | What `updateConfluencePage` documents and accepts | **Yes.** Always |
| **markdown** | Passed through `contentFormat: "markdown"` | No. It escapes markers rather than converting: `\*\*bold\*\*` |
| **storage XML** | `<ac:structured-macro>`, `<ac:rich-text-body>`, CDATA | No. The format guide forbids it. It renders as raw text |

Call `getContentFormatGuide` with `{toolName: "updateConfluencePage"}` before
authoring. It is the authority. It documents every node Confluence accepts and
is more current than anything written here.

## A read is not the stored format

**Every read returns markdown**, whatever the page actually holds. Expand
macros, panels, emoji nodes and layout sections are invisible in it.

Consequences:

- You cannot tell from a read whether a page has collapsible sections.
- You cannot reconstruct a page from a read. Everything the markdown cannot
  express is lost.
- `getConfluencePage` is for reading *content*. To inspect *structure*, fetch
  `?body-format=storage` from the REST API.

The tell that a read has dropped something: stray leading spaces where an inline
node was stripped, like `###   Mini DL 1:` with three spaces where an emoji node
used to be.

## The markup that matters

From the format guide, the pieces an RFC actually uses:

| Element | HTML |
|---|---|
| Expand | `<details><summary>Title</summary>…</details>` |
| Panel | `<div data-type="panel-info">…</div>` - types: `info`, `note`, `warning`, `success`, `error` |
| Code block | `<pre><code class="language-js">…</code></pre>` |
| Emoji | `<span data-type="emoji" data-shortname=":plus:" data-emoji-id="atlassian-plus" data-emoji-text=":plus:">:plus:</span>` |
| Status lozenge | `<span data-type="status" data-color="green">Done</span>` |
| Smart link | `<a href="URL" data-card-appearance="inline">URL</a>` |
| Wide expand | `<details data-breakout="wide" data-breakout-width="760">` |

Emoji: give `data-emoji-id` and `data-emoji-text` together or neither.

## Decision log markup

The house pattern, from the existing MOB pages:

```html
<h3><span data-type="emoji" data-shortname=":rainbow:" data-emoji-id="1f308" data-emoji-text="🌈">🌈</span> Mini DL 1: What starts the handler?</h3>
<p>One sentence framing the question.</p>

<details data-breakout="wide" data-breakout-width="760">
  <summary>Options considered</summary>
  <table>…Description / Pros / Cons / Risks per option…</table>
</details>

<div data-type="panel-success">
  <p><strong>Preferred: 1, check on every arrival.</strong> One line of why.</p>
</div>
```

The heading stays visible; only the options table collapses. The verdict sits
outside the expand so a reader gets the answer without expanding.

Pro and con markers inside the table are emoji spans with coloured text:
`:plus:` with `color: #006644`, `:minus:` with `color: #bf2600`.

## Size: when a page will not fit a tool call

An RFC page of 50KB+ cannot be emitted inside a tool call. The body is mostly
prose, so no format is smaller - ADF is roughly the same size as HTML, since
JSON node wrappers cost what tags do.

**The fallback is a script against the REST API**, with the captain's API token:

```python
# read the current version, then PUT the whole body
GET  /wiki/api/v2/pages/{id}            -> version.number
PUT  /wiki/api/v2/pages/{id}            payload below
{"id": id, "status": "current", "title": title,
 "body": {"representation": "storage", "value": body},
 "version": {"number": current + 1, "message": "..."}}
```

**The catch, and it is the one that caused the worst damage:** the REST API's
`representation: "storage"` means the body must be *real storage format*, not
the HTML the MCP accepts. So this path needs a converter, and a converter is
where content gets silently dropped.

What a converter must handle, with the failure if it does not:

| HTML | Storage | If missed |
|---|---|---|
| `<pre><code>` | `<ac:structured-macro ac:name="code">` with CDATA | Every line renders as a separate inline code pill |
| `<details><summary>` | `ac:name="expand"` with `ac:parameter title` | Sections render permanently expanded |
| `<div data-type="panel-info">` | `ac:name="info"` | Panels render as plain unstyled blocks |
| `<span data-type="emoji">` | `<ac:emoticon>` with the same ids | Markers render as literal `:plus:` text |
| `<br>`, `<hr>` | Self-closed | The document is not well-formed XML |

Panel type mapping: `info`→`info`, `note`→`note`, `warning`→`warning`,
`success`→`tip` (storage has no success panel; tip is the green one).

**Validate before sending.** Wrap the converted body and parse it:

```python
ET.fromstring('<root xmlns:ac="http://x" xmlns:ri="http://y">' + body + '</root>')
```

This catches unbalanced tags, undefined entities (`&mdash;` is not one of XML's
five) and anything the converter mangled. It caught a real bug where an emoji
substitution was corrupting attributes inside heading spans.

## Read-back verification

Not optional. After every publish:

```python
GET /wiki/api/v2/pages/{id}?body-format=storage
```

Count each element type and compare against what was sent:

```
expand / code / emoticon / panel macros / tables
```

Also count what should be **zero**: `<pre`, `<details`, `data-type="panel`.
Any of those in stored storage format means the converter passed HTML straight
through and Confluence ignored it.

This check is the only thing that catches a converter bug. It was skipped once
and eight panels shipped dead.

## What never to do

- **Never invent a parameter.** `contentRepresentation: "append"` is not real.
  It was silently ignored, every call did a full replace, and four sequential
  "append" calls left only the last quarter of the page.
- **Never assume a size limit** without testing. A 41KB body was abandoned as
  "too large" when the actual error was a terminal output limit on `cat`.
- **Never publish a page you have not read back.**
