Here's the full picture:

What's done

AST groundwork (9 files, +407/−136): the shared AST is now language-neutral — djot's reference/footnote tables moved into a new djot.Document wrapper, isBlock/isInline moved djot-side, the five generic markup kinds (element, comment, doctype, processing_instruction, cdata) are in with contract-style doc comments, KeyVal.value is optional with Attrs.find for the bare-vs-absent distinction, and content_span: ?Span is on Node with the editor-splice contract documented.

XML, Twig's second language (src/languages/xml/, ~1,070 lines): a recursive-descent parser for well-formed XML 1.0 with positioned diagnostics on malformed input, plus a serializer. Names, doctype guts, and namespace prefixes are stored as-written; predefined + numeric entities decode; whitespace-only text nodes are kept; every element gets a correct span and content_span (null for self-closing — which is also how the serializer decides <a/> vs <a></a>).

Verification

- zig build test --summary all: 53/53 tests pass (34 baseline + 19 new), djot conformance untouched at 265/271.
- My own end-to-end smoke test, outside the agent's suite: parsed the real /System/Library/CoreServices/SystemVersion.plist through twig.Xml.parse → serializeAlloc → byte-identical, 603 bytes in, 603 bytes out, and it reparses to an equal tree. The generic kinds, attrs, and doctype-with-internal-subset handling all work on real-world input.

Deviations to know about (all documented in xml.zig's module header)

- XML Name is ASCII-approximated (international names parse, just unvalidated); ]]> in plain text isn't flagged; <?XML?> as a non-declaration PI isn't rejected; DTD internal subsets are skipped as opaque bytes, so custom entities are always error.UnknownEntity.
- Byte-identical serialization holds only for already-canonical input — full fidelity for edited documents remains the span-splice editor layer's job, as designed.

Notes for the HTML phase

The XML agent confirmed the batch Builder API fits recursive descent perfectly — the one thing that may force a different construction pattern in HTML is implicit tag closing (<li>, <p> auto-close). That plus the forked tokenizer (RCDATA/RAWTEXT modes, entity refs) and the conservative tree-construction policy are the whole remaining HTML surface. Separately, the djot parser still leaves content_span null — a small follow-up worth doing before the editor layer.
