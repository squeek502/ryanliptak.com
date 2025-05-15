<p><aside class="note">

Note: I am not a 'browser engine' person, nor a 'data structures' person; this corner of the major browsers just hasn't received any attention for a *very* long time. I'm certain that an even better implementation than what I came up with is very possible.

</aside></p>

A while back, for <span style="border-bottom: 1px dotted; cursor: default;" title="the actual reason will be detailed later">no real reason\*</span>, I tried writing an implementation of a data structure tailored to the specific use case of [the *Named character reference state*](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) of HTML tokenization (here's the [link to that experiment](https://github.com/squeek502/named-character-references)). Recently, I took that implementation, ported it to C++, and [used it to make some efficiency gains and fix some spec compliance issues](https://github.com/LadybirdBrowser/ladybird/pull/3011) in the [Ladybird browser](https://ladybird.org/).

Throughout this, I never actually looked at the implementations used in any of the major browser engines. However, now that I *have* looked at Blink/WebKit/Gecko, I've realized that my implementation seems to be either on-par or better across the metrics that the browser engines care about:

- Efficiency (just as fast, if not *slightly* faster)
- Compactness of the data (uses ~60% of the data size)
- Ease of use

<p><aside class="note">

Note: I'm singling out these metrics because, in [the python script](https://github.com/chromium/chromium/blob/8469b0ca44e36be251999cc819ff96dc3ac43290/third_party/blink/renderer/build/scripts/make_html_entity_table.py#L29-L32) that generates the data structures used for named character reference tokenization in Blink (the browser engine of Chromium), it contains this docstring (emphasis mine):

<pre><code class="language-python"><span class="token_string">"""This python script creates the raw data that is our entity
database. The representation is one string database containing all
strings we could need, and then a mapping from offset+length -> entity
data.</span> <b>That is compact, easy to use and efficient.</b><span class="token_string">"""</span>
</code></pre>

</aside></p>

So, I thought I'd take you through what I came up with and how it compares to the implementations in the major browser engines. Mostly, though, I just think the data structure I used is neat and want to tell you about it (fair warning: it's not novel).

## What is a named character reference?

A named character reference is an HTML entity specified using an ampersand (`&`) followed by an ASCII alphanumeric name. An ordained set of names will get transformed during HTML parsing into particular code point(s). For example, `&bigcirc;` is a valid named character reference that gets transformed into the symbol &bigcirc;, while `&amp;` will get transformed into &amp;.

<p><aside class="note">

Note: The &bigcirc; symbol is the Unicode code point `U+25EF`, which means it could also be specified as a *numeric* character reference using either `&#x25EF;` or `&#9711;`. We're only focusing on *named* character references, though.

</aside></p>

Here's a few properties of named character references that are relevant for what we'll ultimately be aiming to implement:

- Always start with `&`
- Only contain characters in the ASCII range
- Case-sensitive
- Usually, but not always, end with `;`
- Are transformed into either 1 or 2 code points
  + Irrelevant side note: those code point(s) usually make up one [grapheme](https://www.unicode.org/glossary/#grapheme) (i.e. most second code points are combining code points), but not always (e.g. `&fjlig;` maps to `U+0066 U+006A` which are just the ASCII letters `fj`)

Most crucially, though, the mappings of named character references are *fixed*. The [HTML standard](https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references) contains this note about named character references:

> **Note:** This list is static and [will not be expanded or changed in the future](https://github.com/whatwg/html/blob/main/FAQ.md#html-should-add-more-named-character-references).

This means that it's now safe to represent the data in the minimum amount of bits possible without any fear of needing to accommodate more named character reference mappings in the future.

<p><aside class="note">

Note: This is a big part of why I think better solutions than mine should be very possible. I feel like I've only scratched the surface in terms of a purpose-built data structure for this particular task.

</aside></p>

## Named character reference tokenization overview

I'm specifically going to be talking about the [*Named character reference state* of HTML tokenization](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state). You can read the spec for it if you want (it's fairly short) but there's really only one sentence we're interested in:

> Consume the maximum number of characters possible, where the consumed characters are one of the identifiers in the first column of the named character references table.

This sentence is really the crux of the implementation, but the spec is quite hand-wavy here and conceals a lot of complexity. The example given a bit later in the spec hints at why the above sentence is not so straightforward (edited to exclude irrelevant details; for context, <code><span class="token_keyword">&amp;not</span></code> is a valid named character reference, as is <code><span class="token_keyword">&amp;notin;</span></code>):

> **Example:** If the markup contains the string <code>I'm <span class="token_keyword">&amp;not</span>it; I tell you</code>, the character reference is parsed as "not", as in, `I'm ¬it; I tell you`. But if the markup was <code>I'm <span class="token_keyword">&amp;notin;</span> I tell you</code>, the character reference would be parsed as "notin;", resulting in `I'm ∉ I tell you`.

That is, with the string `&notit;`, the characters up to and including `&noti` can still lead to a valid named character reference (`&notin;`, among others), so we only know that `&notit;` is invalid once we've reached `&notit` which can no longer lead to a valid named character reference. What this means is that there needs to be some amount of backtracking involved, as the goal is to consume only the characters that are part of the longest valid named character reference.

That's not the only complication, though...

### The spectre of `document.write`

Due to `<script>` tags, the input to HTML tokenization is *mutable while it is being tokenized*, meaning looking ahead is not always reliable/possible since we might not yet know what comes next. Consider this example:

```html
<script>
document.write("&not");
</script>in;
```

The expected result after parsing is <code>&notin;</code>, meaning the resolved character reference is `&notin;`. Let's go through why that is the case.

<p><aside class="note">

Note: I'm not super familiar with the [tree construction side of HTML parsing](https://html.spec.whatwg.org/multipage/parsing.html#tree-construction), so don't expect my explanation below to be fully accurate from that point of view. My explanation is solely focused on the tokenizer's side of things.

</aside></p>

After the closing script tag is tokenized, the parser adds an "insertion point" after it, and then the script within the tag itself is executed. So, right *before* the script is executed, the tokenizer input can be visualized as (where <code><span class="token_string insertion-point"></span></code> is the insertion point):

<pre><code class="language-html"><span class="token_string insertion-point"></span><span class="token_identifer">in;</span></code></pre>

And then after the `<script>` is executed and the `document.write` call has run, it can be visualized as:

<pre><code class="language-html"><span class="token_string insertion-point">&amp;not</span><span class="token_identifer">in;</span></code></pre>

What happens from the tokenizer's perspective is that after the closing `</script>` tag, `&not` comes next in the input stream (which was inserted by `document.write`), and then the characters after `&not` are `in;`, so ultimately a tokenizer going character-by-character should see an unbroken `&notin;`, recognize that as a valid character reference, and translate it to <code>&notin;</code>.

<p><aside class="note">

Note: The ordering here matters. For example, if you put `&not` first and use `document.write` to add a trailing `in;` like so:

```html
&not<script>
document.write("in;");
</script>
```

then it does not result in <code>&notin;</code> (the result of `&notin;`), but instead <code>&not;in;</code>, since from the tokenizer's point of view it sees `&not<`, and therefore treats `&not` as a character reference since the `<` cannot lead to any other valid character references. Then, after the `<script>` tag is parsed and runs, `&not` has already been converted to <code>&not;</code> so the `in;` is just appended after it.

</aside></p>

To further show why this can be tricky to handle, consider also the possibility of `document.write` writing one character at a time, like so:

```html
<script>
for (let char of "&not") {
  document.write(char);
}
</script>in;
```

This, too, is expected to result in <code>&notin;</code> (i.e. `&notin;`). Keep in mind that the tokenizer will advance after each `document.write` call, so if the tokenizer tries to lookahead past the insertion point at any point before the full script is run, it will resolve the wrong string as a character reference (`&in;`, `&nin;`, or `&noin;`). Here's a visualization that shows the insertion point and the various states of the input stream after each `document.write` call:

<pre><code class="language-html"><span class="token_string insertion-point" id="not-insertion-point"></span><span class="token_identifer">in;</span></code></pre>

<script>
(function() {
	let i=0;
	let letters = '&not';
	let e = document.querySelector('#not-insertion-point');
	setInterval(function() {
		e.textContent = letters.substring(0,i);
		// + 3 to linger on the final result for a bit
		i = (i + 1) % (letters.length + 3);
	}, 500);
})();
</script>

Therefore, while HTML tokenizers *can* theoretically look ahead, they can never look past the end of an insertion point.

### What this all means, implementation-wise

All of this is to say that a "consume the longest valid named character reference" implementation probably needs to use one of two strategies:

- Lookahead (but never beyond an insertion point) until we're certain that we have enough characters to rule out a longer named character reference. If we do not yet have enough characters to be *certain*, backtrack and try again until we can be certain.
- Never lookahead, and instead match character-by-character until we're certain it's no longer possible to match a longer valid named character reference. Backtrack to the end of longest full match found.

The second strategy seems like the better approach to me, so that's what my implementation will be focused on. We'll see both strategies later on, though.

<p><aside class="note">

Maybe TODO: Proper explanation of why tokenization has to run while the script is being executed, i.e. you can't just resolve all script tags upfront and then tokenize the immutable result. Otherwise, some acknowledgment that I can't explain why that's the case, but that's how parsers/tokenizers are implemented and link to the relevant parts of the spec if possible.

Maybe an explanation: Would need a multi-pass tokenizer? Tokenize once, but only run all script tags. Repeat until all script tags have been resolved fully. Then, finally, you can tokenize a final time with full lookahead capabilities.

Consider this nightmare of an example:

```html
<script>
for (let char of "<script>document.write('&not');<\/script>") {
  document.write(char);
}
</script>in;
```

</aside></p>

## Trie implementation

So, we want an implementation that can iterate character-by-character and (at any point) efficiently determine if it's possible for the next character to lead to a longer valid named character reference.

A data structure that seems pretty good for this sort of thing is a [trie](https://en.wikipedia.org/wiki/Trie). A trie is a specialized tree where each node contains a character that can come after the character of its parent node in a set of words. Below is a representation of a trie containing this small subset of named character references:

<div class="two-column-collapse" style="grid-template-columns: 1.5fr 1fr;">
	<div class="has-bg" style="padding: 0.5rem 5rem; margin-bottom: 1.5rem; display: grid;">
		<div style="display: grid; grid-template-columns: max-content max-content max-content; margin-left: auto; margin-right: auto; grid-column-gap: 1em; text-align: center; ">
			<div><code>&amp;not</code></div><div>&rarr;</div><div>&not;</div>
			<div><code>&amp;notinva;</code></div><div>&rarr;</div><div>&notinva;</div>
			<div><code>&amp;notinvb;</code></div><div>&rarr;</div><div>&notinvb;</div>
			<div><code>&amp;notinvc;</code></div><div>&rarr;</div><div>&notinvc;</div>
			<div><code>&amp;notniva;</code></div><div>&rarr;</div><div>&notniva;</div>
			<div><code>&amp;notnivb;</code></div><div>&rarr;</div><div>&notnivb;</div>
			<div><code>&amp;notnivc;</code></div><div>&rarr;</div><div>&notnivc;</div>
		</div>
	</div>
	<aside class="note" style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; margin-bottom: 1.5rem;"><div>Note the lack of a semicolon at the end of <code>&amp;not</code>. This variant was chosen over <code>&amp;not;</code> to simplify the example</div></aside>
</div>

<div style="text-align: center;">
<svg id="mermaid-trie" width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 289.9666748046875px;" viewBox="0 0 289.9666748046875 438" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker id="mermaid-123_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-circleStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="-1" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-crossStart" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="-1" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path d="M145.725,38.5L145.642,39.25C145.558,40,145.392,41.5,145.308,43.083C145.225,44.667,145.225,46.333,145.225,47.167L145.225,48" id="L_root_n_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M145.225,87L145.225,87.833C145.225,88.667,145.225,90.333,145.225,92C145.225,93.667,145.225,95.333,145.225,96.167L145.225,97" id="L_n_letter_o_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M145.225,136L145.225,136.833C145.225,137.667,145.225,139.333,145.225,141C145.225,142.667,145.225,144.333,145.225,145.167L145.225,146" id="L_letter_o_t_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M129.675,170.774L120.226,173.978C110.778,177.182,91.881,183.591,82.432,187.629C72.983,191.667,72.983,193.333,72.983,194.167L72.983,195" id="L_t_i1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M160.775,170.774L170.224,173.978C179.672,177.182,198.569,183.591,208.018,187.629C217.467,191.667,217.467,193.333,217.467,194.167L217.467,195" id="L_t_n1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,234L72.983,234.833C72.983,235.667,72.983,237.333,72.983,239C72.983,240.667,72.983,242.333,72.983,243.167L72.983,244" id="L_i1_n2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,234L217.467,234.833C217.467,235.667,217.467,237.333,217.467,239C217.467,240.667,217.467,242.333,217.467,243.167L217.467,244" id="L_n1_i2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,283L217.467,283.833C217.467,284.667,217.467,286.333,217.467,288C217.467,289.667,217.467,291.333,217.467,292.167L217.467,293" id="L_i2_v1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,283L72.983,283.833C72.983,284.667,72.983,286.333,72.983,288C72.983,289.667,72.983,291.333,72.983,292.167L72.983,293" id="L_n2_v2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M201.175,320.745L195.822,323.454C190.469,326.164,179.764,331.582,174.411,335.124C169.058,338.667,169.058,340.333,169.058,341.167L169.058,342" id="L_v1_a1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,332L217.467,332.833C217.467,333.667,217.467,335.333,217.467,337C217.467,338.667,217.467,340.333,217.467,341.167L217.467,342" id="L_v1_b1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M233.758,320.787L239.071,323.489C244.383,326.191,255.008,331.596,260.321,335.131C265.633,338.667,265.633,340.333,265.633,341.167L265.633,342" id="L_v1_c1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M56.692,320.745L51.339,323.454C45.986,326.164,35.281,331.582,29.928,335.124C24.575,338.667,24.575,340.333,24.575,341.167L24.575,342" id="L_v2_a2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,332L72.983,332.833C72.983,333.667,72.983,335.333,72.983,337C72.983,338.667,72.983,340.333,72.983,341.167L72.983,342" id="L_v2_b2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M89.275,320.787L94.587,323.489C99.9,326.191,110.525,331.596,115.838,335.131C121.15,338.667,121.15,340.333,121.15,341.167L121.15,342" id="L_v2_c2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M169.058,381L169.058,381.833C169.058,382.667,169.058,384.333,169.058,386C169.058,387.667,169.058,389.333,169.058,390.167L169.058,391" id="L_a1_semi1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,381L217.467,381.833C217.467,382.667,217.467,384.333,217.467,386C217.467,387.667,217.467,389.333,217.467,390.167L217.467,391" id="L_b1_semi2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M265.633,381L265.633,381.833C265.633,382.667,265.633,384.333,265.633,386C265.633,387.667,265.633,389.333,265.633,390.167L265.633,391" id="L_c1_semi3_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M24.575,381L24.575,381.833C24.575,382.667,24.575,384.333,24.575,386C24.575,387.667,24.575,389.333,24.575,390.167L24.575,391" id="L_a2_semi4_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,381L72.983,381.833C72.983,382.667,72.983,384.333,72.983,386C72.983,387.667,72.983,389.333,72.983,390.167L72.983,391" id="L_b2_semi5_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.15,381L121.15,381.833C121.15,382.667,121.15,384.333,121.15,386C121.15,387.667,121.15,389.333,121.15,390.167L121.15,391" id="L_c2_semi6_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default  " id="flowchart-root-0" transform="translate(145.2249984741211, 23)"><polygon points="15,0 30,-15 15,-30 0,-15" class="label-container" transform="translate(-15,15)"></polygon><g class="label" style="" transform="translate(0, 0)"><rect></rect><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n-1" transform="translate(145.2249984741211, 67.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-letter_o-3" transform="translate(145.2249984741211, 116.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.666664123535156" y="-19.5" width="33.33332824707031" height="39"></rect><g class="label" style="" transform="translate(-4.291664123535156, -12)"><rect></rect><foreignObject width="8.583328247070312" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>o</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-t-5" transform="translate(145.2249984741211, 165.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.550003051757812" y="-19.5" width="31.100006103515625" height="39"></rect><g class="label" style="" transform="translate(-3.1750030517578125, -12)"><rect></rect><foreignObject width="6.350006103515625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>t</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i1-7" transform="translate(72.98332977294922, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n1-8" transform="translate(217.46666717529297, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n2-10" transform="translate(72.98332977294922, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i2-12" transform="translate(217.46666717529297, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-v1-14" transform="translate(217.46666717529297, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>v</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-v2-16" transform="translate(72.98332977294922, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>v</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a1-18" transform="translate(169.05833435058594, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>a</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b1-19" transform="translate(217.46666717529297, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>b</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-c1-20" transform="translate(265.63333892822266, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>c</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a2-22" transform="translate(24.574996948242188, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>a</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b2-23" transform="translate(72.98332977294922, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>b</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-c2-24" transform="translate(121.1500015258789, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>c</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi1-26" transform="translate(169.05833435058594, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi2-28" transform="translate(217.46666717529297, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi3-30" transform="translate(265.63333892822266, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi4-32" transform="translate(24.574996948242188, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi5-34" transform="translate(72.98332977294922, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi6-36" transform="translate(121.1500015258789, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g></g></g></g></svg>
</div>

<p><aside class="note">

Notes:
- The `&` is excluded from the trie since it's the first character of *every* named character reference.
- The nodes with a red outline are those marked as the end of a valid word in the set.
- Typically, trie visualizations put the letters on the connections between nodes rather than on the nodes themselves. I'm putting them on the nodes themselves for reasons that will be discussed later.

</aside></p>

With such a trie, you search for the next character within the list of the current node's children (starting from the root). If the character is found within the children, you then set that child node as the current node and continue on for the character after that, etc.

For invalid words, this means that you naturally stop searching as soon as possible (after the first character that cannot lead to a longer match). For valid words, you trace a path through the trie and end up on an end-of-word node (and you may also pass end-of-word nodes on the way there). Here's what the path through the trie would look like for the named character reference `&notinvc;`:

<div style="text-align: center;">
<svg id="mermaid-trie-with-value" width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 289.9666748046875px;" viewBox="0 0 289.9666748046875 500" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker id="mermaid-123_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-circleStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="-1" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-crossStart" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="-1" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path d="M145.725,38.5L145.642,39.25C145.558,40,145.392,41.5,145.308,43.083C145.225,44.667,145.225,46.333,145.225,47.167L145.225,48" id="L_root_n_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M145.225,87L145.225,87.833C145.225,88.667,145.225,90.333,145.225,92C145.225,93.667,145.225,95.333,145.225,96.167L145.225,97" id="L_n_letter_o_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M145.225,136L145.225,136.833C145.225,137.667,145.225,139.333,145.225,141C145.225,142.667,145.225,144.333,145.225,145.167L145.225,146" id="L_letter_o_t_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M129.675,170.774L120.226,173.978C110.778,177.182,91.881,183.591,82.432,187.629C72.983,191.667,72.983,193.333,72.983,194.167L72.983,195" id="L_t_i1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M160.775,170.774L170.224,173.978C179.672,177.182,198.569,183.591,208.018,187.629C217.467,191.667,217.467,193.333,217.467,194.167L217.467,195" id="L_t_n1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,234L72.983,234.833C72.983,235.667,72.983,237.333,72.983,239C72.983,240.667,72.983,242.333,72.983,243.167L72.983,244" id="L_i1_n2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,234L217.467,234.833C217.467,235.667,217.467,237.333,217.467,239C217.467,240.667,217.467,242.333,217.467,243.167L217.467,244" id="L_n1_i2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,283L217.467,283.833C217.467,284.667,217.467,286.333,217.467,288C217.467,289.667,217.467,291.333,217.467,292.167L217.467,293" id="L_i2_v1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,283L72.983,283.833C72.983,284.667,72.983,286.333,72.983,288C72.983,289.667,72.983,291.333,72.983,292.167L72.983,293" id="L_n2_v2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M201.175,320.745L195.822,323.454C190.469,326.164,179.764,331.582,174.411,335.124C169.058,338.667,169.058,340.333,169.058,341.167L169.058,342" id="L_v1_a1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,332L217.467,332.833C217.467,333.667,217.467,335.333,217.467,337C217.467,338.667,217.467,340.333,217.467,341.167L217.467,342" id="L_v1_b1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M233.758,320.787L239.071,323.489C244.383,326.191,255.008,331.596,260.321,335.131C265.633,338.667,265.633,340.333,265.633,341.167L265.633,342" id="L_v1_c1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M56.692,320.745L51.339,323.454C45.986,326.164,35.281,331.582,29.928,335.124C24.575,338.667,24.575,340.333,24.575,341.167L24.575,342" id="L_v2_a2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,332L72.983,332.833C72.983,333.667,72.983,335.333,72.983,337C72.983,338.667,72.983,340.333,72.983,341.167L72.983,342" id="L_v2_b2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M89.275,320.787L94.587,323.489C99.9,326.191,110.525,331.596,115.838,335.131C121.15,338.667,121.15,340.333,121.15,341.167L121.15,342" id="L_v2_c2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M169.058,381L169.058,381.833C169.058,382.667,169.058,384.333,169.058,386C169.058,387.667,169.058,389.333,169.058,390.167L169.058,391" id="L_a1_semi1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M217.467,381L217.467,381.833C217.467,382.667,217.467,384.333,217.467,386C217.467,387.667,217.467,389.333,217.467,390.167L217.467,391" id="L_b1_semi2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M265.633,381L265.633,381.833C265.633,382.667,265.633,384.333,265.633,386C265.633,387.667,265.633,389.333,265.633,390.167L265.633,391" id="L_c1_semi3_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M24.575,381L24.575,381.833C24.575,382.667,24.575,384.333,24.575,386C24.575,387.667,24.575,389.333,24.575,390.167L24.575,391" id="L_a2_semi4_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,381L72.983,381.833C72.983,382.667,72.983,384.333,72.983,386C72.983,387.667,72.983,389.333,72.983,390.167L72.983,391" id="L_b2_semi5_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.15,381L121.15,381.833C121.15,382.667,121.15,384.333,121.15,386C121.15,387.667,121.15,389.333,121.15,390.167L121.15,391" id="L_c2_semi6_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.008,420L121.008,451" id="L_semi3_notinvc_0" class=" edge-thickness-normal edge-pattern-dotted edge-thickness-normal edge-pattern-solid flowchart-link" style="" marker-end="url(#mermaid-123_flowchart-v2-pointEnd)"></path></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default  " id="flowchart-root-0" transform="translate(145.2249984741211, 23)"><polygon points="15,0 30,-15 15,-30 0,-15" class="label-container" transform="translate(-15,15)"></polygon><g class="label" style="" transform="translate(0, 0)"><rect></rect><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-n-1" transform="translate(145.2249984741211, 67.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-letter_o-3" transform="translate(145.2249984741211, 116.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.666664123535156" y="-19.5" width="33.33332824707031" height="39"></rect><g class="label" style="" transform="translate(-4.291664123535156, -12)"><rect></rect><foreignObject width="8.583328247070312" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>o</p></span></div></foreignObject></g></g><g class="node default selected-path end-of-word" id="flowchart-t-5" transform="translate(145.2249984741211, 165.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.550003051757812" y="-19.5" width="31.100006103515625" height="39"></rect><g class="label" style="" transform="translate(-3.1750030517578125, -12)"><rect></rect><foreignObject width="6.350006103515625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>t</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-i1-7" transform="translate(72.98332977294922, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n1-8" transform="translate(217.46666717529297, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-n2-10" transform="translate(72.98332977294922, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i2-12" transform="translate(217.46666717529297, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-v1-14" transform="translate(217.46666717529297, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>v</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-v2-16" transform="translate(72.98332977294922, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>v</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a1-18" transform="translate(169.05833435058594, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>a</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b1-19" transform="translate(217.46666717529297, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>b</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-c1-20" transform="translate(265.63333892822266, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>c</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a2-22" transform="translate(24.574996948242188, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>a</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b2-23" transform="translate(72.98332977294922, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>b</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-c2-24" transform="translate(121.1500015258789, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>c</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi1-26" transform="translate(169.05833435058594, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi2-28" transform="translate(217.46666717529297, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi3-30" transform="translate(265.63333892822266, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi4-32" transform="translate(24.574996948242188, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi5-34" transform="translate(72.98332977294922, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default selected-path end-of-word" id="flowchart-semi6-36" transform="translate(121.1500015258789, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default transformed-value" id="flowchart-notinvc-42" transform="translate(121.5083236694336, 475.2249984741211)"><g class="basic label-container" style=""><circle class="outer-circle" style="" r="18.224998474121094" cx="0" cy="0"></circle><circle class="inner-circle" style="" r="13.224998474121094" cx="0" cy="0"></circle></g><g class="label" style="" transform="translate(-5.724998474121094, -12)"><rect></rect><foreignObject width="11.449996948242188" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>&notinvc;</p></span></div></foreignObject></g></g></g></g></g></svg>
</div>

You'll notice that the mapped code point (&notinvc;) is present on the diagram above as well. This is because it is trivial to use a trie as a map to look up an associated value, since each word in the set *must* end at a distinct node in the trie (e.g. no two words can share an end-of-word node). Conveniently, that's exactly what we want to be able to do for named character references, since ultimately we need to convert the longest matched named character reference into the relevant code point(s).

<p><aside class="note">

TODO this is just random rewordings of the above

This is trivial to use as a map to look up the associated code points that the named character reference should be transformed into.

Each node can only be the end of exactly one word (if it is an end-of-word node).

aka

No two words can share an end-of-word node.

aka

Each end of word is a distinct node, so we can either:
- Index into a value array using the same index as the end node (this potentially leaves you with a lot of unused gaps in the value array)
- Within each end-of-word node, store an index into value array (this makes the node size larger but the value array smaller)

</aside></p>

## A brief detour: Representing a trie in memory

<p><aside class="note">

Note: The code examples in this section will be using [Zig](https://www.ziglang.org/) syntax.	

</aside></p>

One way to represent a trie node is to use an array of optional pointers for its children (each index into the array represents a child node with that byte value as its character), like so:

```zig
const Node = struct {
	// This example supports all `u8` byte values.
	children: [256]?*Node,
	end_of_word: bool,
};
```

Earlier, I said that trie visualizations typically put the letters on the connections between nodes rather than the nodes themselves, and, with *this* way of representing the trie, I think that makes a lot of sense, since the *connections* are the information being stored on each node.

<p><aside class="note">

For the examples in this section, we'll use a trie that only contains the words `GG`, `GL`, and `HF`.

</aside></p>

So, this representation can be visualized like so:

<div style="text-align: center;">
<svg aria-roledescription="flowchart-v2" role="graphics-document document" style="max-width: 200px;" viewBox="0 0 150 230" class="mermaid-flowchart flowchart" xmlns="http://www.w3.org/2000/svg" id="graph-3490" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-4529_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-4529_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-4529_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-4529_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-4529_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-4529_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-4529_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_g_0" d="M70.218,32.418L66.715,37.348C63.212,42.278,56.206,52.139,52.703,60.403C49.2,68.667,49.2,75.333,49.2,78.667L49.2,82"></path><path marker-end="url(#graph-4529_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_h_0" d="M84.955,29.845L92.296,35.204C99.637,40.563,114.318,51.282,121.659,59.974C129,68.667,129,75.333,129,78.667L129,82"></path><path marker-end="url(#graph-4529_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_g_g2_0" d="M40.276,110L34.83,119C32.384,123,27.492,141,25.046,148.333C22.6,155.667,22.6,162.333,22.6,165.667L22.6,169"></path><path marker-end="url(#graph-4529_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_g_l_0" d="M58.124,110L63.57,119C66.016,123,70.908,141,73.354,148.333C75.8,155.667,75.8,162.333,75.8,165.667L75.8,169"></path><path marker-end="url(#graph-4529_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_h_f_0" d="M129,115L129,129C129,133,129,141,129,148.333C129,155.667,129,162.333,129,165.667L129,169"></path></g><g class="edgeLabels"><g transform="translate(52, 52)" class="edgeLabel"><g transform="translate(-6.224998474121094, -12)" class="label"><foreignObject height="24" width="24"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(110, 52)" class="edgeLabel"><g transform="translate(-5.775001525878906, -12)" class="label"><foreignObject height="24" width="24"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"><p>H</p></span></div></foreignObject></g></g><g transform="translate(22, 140)" class="edgeLabel"><g transform="translate(-6.224998474121094, -12)" class="label"><foreignObject height="24" width="24"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(65, 140)" class="edgeLabel"><g transform="translate(-4.4499969482421875, -12)" class="label"><foreignObject height="24" width="24"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"><p>L</p></span></div></foreignObject></g></g><g transform="translate(122, 140)" class="edgeLabel"><g transform="translate(-4.883331298828125, -12)" class="label"><foreignObject height="24" width="24"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"><p>F</p></span></div></foreignObject></g></g></g><g class="nodes"><g transform="translate(75.79999542236328, 23)" id="flowchart-root-0" class="node default"><polygon transform="translate(-15,15)" class="label-container" points="15,0 30,-15 15,-30 0,-15"></polygon><g transform="translate(0, 0)" style="" class="label"><rect></rect><foreignObject height="0" width="0"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"></span></div></foreignObject></g></g><g transform="translate(49.19999694824219, 105.5)" id="flowchart-g-1" class="node default"><rect height="30" width="29.199996948242188" y="-19.5" x="-14.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-2.2249984741210938, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="4.4499969482421875"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>&nbsp;</p></span></div></foreignObject></g></g><g transform="translate(128.99999237060547, 105.5)" id="flowchart-h-3" class="node default"><rect height="30" width="29.199996948242188" y="-19.5" x="-14.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-2.2249984741210938, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="4.4499969482421875"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>&nbsp;</p></span></div></foreignObject></g></g><g transform="translate(22.599998474121094, 192.5)" id="flowchart-g2-5" class="node default end-of-word"><rect height="30" width="29.199996948242188" y="-19.5" x="-14.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-2.2249984741210938, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="4.4499969482421875"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>&nbsp;</p></span></div></foreignObject></g></g><g transform="translate(75.79999542236328, 192.5)" id="flowchart-l-7" class="node default end-of-word"><rect height="30" width="29.199996948242188" y="-19.5" x="-14.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-2.2249984741210938, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="4.4499969482421875"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>&nbsp;</p></span></div></foreignObject></g></g><g transform="translate(128.99999237060547, 192.5)" id="flowchart-f-9" class="node default end-of-word"><rect height="30" width="29.199996948242188" y="-19.5" x="-14.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-2.2249984741210938, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="4.4499969482421875"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>&nbsp;</p></span></div></foreignObject></g></g></g></g></g></g></svg>
</div>

With this, checking if a character can come after the current node is a straightforward `O(1)` array access:

```zig
if (node.children[c] != null) {
    // found child
}
```

but it comes at the cost of a lot of potentially wasted space, since most nodes will have many `null` children.

One way to mitigate the wasted space would be to switch from an array of children to a linked list of children, where the parent instead stores an optional pointer to its first child, and each child stores an optional pointer to its next sibling:

```zig
const Node = struct {
	char: u8,
	first_child: ?*Node,
	next_sibling: ?*Node,
	end_of_word: bool,
};
```

Now that `char` is stored *on* each node directly, I (in turn) think it makes sense to visualize the trie with the characters shown on the nodes themselves, like so:

<div style="text-align: center;">
<svg aria-roledescription="flowchart-v2" role="graphics-document document" style="max-width: 200px;" viewBox="0 0 175 170" class="mermaid-flowchart flowchart" xmlns="http://www.w3.org/2000/svg" id="graph-3490" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-6396_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-6396_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-6396_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-6396_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-6396_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-6396_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-6396_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_g_0" d="M78.143,29.455L74.504,31.713C70.866,33.97,63.589,38.485,59.951,41.576C56.312,44.667,56.312,46.333,56.312,48C56.312,49.667,56.312,51.333,56.312,52.333C56.312,53.333,56.312,53.667,56.312,53.833L56.312,54"></path><path marker-end="url(#graph-6396_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-dotted edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_root_h_0" d="M75,77L123,77"></path><path marker-end="url(#graph-6396_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_g_g2_0" d="M37.712,92.837L35.86,94.364C34.008,95.891,30.304,98.946,28.452,101.306C26.6,103.667,26.6,105.333,26.6,107C26.6,108.667,26.6,110.333,26.6,111.333C26.6,112.333,26.6,112.667,26.6,112.833L26.6,113"></path><path marker-end="url(#graph-6396_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-dotted edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_g_l_0" d="M45,135L65,135"></path><path marker-end="url(#graph-6396_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_h_f_0" d="M145.442,97L145.442,97.833C145.442,98.667,145.442,100.333,145.442,102C145.442,103.667,145.442,105.333,145.442,107C145.442,108.667,145.442,110.333,145.442,111.333C145.442,112.333,145.442,112.667,145.442,112.833L145.442,113"></path></g><g class="edgeLabels"><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g></g><g class="nodes"><g transform="translate(86.68749618530273, 23)" id="flowchart-root-0" class="node default"><polygon transform="translate(-15,15)" class="label-container" points="15,0 30,-15 15,-30 0,-15"></polygon><g transform="translate(0, 0)" style="" class="label"><rect></rect><foreignObject height="0" width="0"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"></span></div></foreignObject></g></g><g transform="translate(56.312496185302734, 77.5)" id="flowchart-g-1" class="node default"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(145.44165802001953, 77.5)" id="flowchart-h-2" class="node default"><rect height="39" width="36.30000305175781" y="-19.5" x="-18.150001525878906" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-5.775001525878906, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="11.550003051757812"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>H</p></span></div></foreignObject></g></g><g transform="translate(26.599998474121094, 136.5)" id="flowchart-g2-4" class="node default end-of-word"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(86.02499389648438, 136.5)" id="flowchart-l-5" class="node default end-of-word"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>L</p></span></div></foreignObject></g></g><g transform="translate(145.44165802001953, 136.5)" id="flowchart-f-7" class="node default end-of-word"><rect height="39" width="34.51666259765625" y="-19.5" x="-17.258331298828125" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.883331298828125, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="9.76666259765625"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>F</p></span></div></foreignObject></g></g></g></g></g></g></svg>
</div>

While this 'linked list' representation saves on memory, it transforms the search for a particular child into a `O(n)` linear scan across the children:

```zig
var node = starting_node.first_child orelse return null;
while (true) {
    if (node.char == c) {
        // found child
    }
    node = node.next_sibling orelse return null;
}
```

This linear search can be slow, especially if the nodes are individually heap-allocated and therefore could be very spread out in memory, leading to a lot of random memory accesses and cache misses. Additionally, pointers themselves take up quite a bit of space (8 bytes on 64-bit machines). If we ultimately want to decrease the size of the node, getting rid of the pointer fields would be helpful as well.

We can solve multiple of these problems at once by:

- Enforcing that all nodes are proximate in memory by storing them all in one array
- Replace all pointers with indexes into that array
- Ensure that children are always contiguous (i.e. to access a sibling you just increment the index by 1)

With this approach, `Node` could look like this:

```zig
const Node = packed struct {
    char: u8,
    // It's safe to represent this with the minimum number of bits.
    // There's 6 nodes in our example so it can be represented in 3 bits.
    first_child_index: u3,
    // `last_sibling` replaces the need for the `next_sibling` field, since
    // accessing the next sibling is just an index increment.
    last_sibling: bool,
    end_of_word: bool,
};
```

And the array of nodes for this particular example trie would look like this:

```zig
const nodes = [6]Node{
    .{ .first_child_index = 1, .char = 0,   .last_sibling = true,  .end_of_word = false },
    .{ .first_child_index = 3, .char = 'G', .last_sibling = false, .end_of_word = false },
    .{ .first_child_index = 5, .char = 'H', .last_sibling = true,  .end_of_word = false },
    .{ .first_child_index = 0, .char = 'G', .last_sibling = false, .end_of_word = true  },
    .{ .first_child_index = 0, .char = 'L', .last_sibling = true,  .end_of_word = true  },
    .{ .first_child_index = 0, .char = 'F', .last_sibling = true,  .end_of_word = true  },
};
```

<p><aside class="note">

Note: `first_child_index` having the value 0 doubles as a 'no children' indicator, since index 0 is always the root node and therefore can never be a valid child node.

</aside></p>

This representation can be visualized like so:

<div style="text-align: center;">
<div style="display: grid; grid-template-columns: repeat(6, 1fr); max-width: 350px; margin: 0 auto;">
	<span>0</span><span>1</span><span>2</span><span>3</span><span>4</span><span>5</span>
</div>
<svg aria-roledescription="flowchart-v2" role="graphics-document document" style="max-width: 345px;" viewBox="0 0 345 80" class="mermaid-flowchart flowchart" xmlns="http://www.w3.org/2000/svg" id="graph-3490" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-5112_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-5112_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_g_0" d="M23,43 Q 40,70 65,45"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-solid flowchart-link" id="L_g_g2_0" d="M90,45 Q 130,80 185,45"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-solid flowchart-link" id="L_h_f_0" d="M145,45 Q 230,100 305,45"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_g_h_0" d="M100,27L120,27"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_g_l_0" d="M220,27L240,27"></path></g><g class="edgeLabels"></g><g class="nodes"><g transform="translate(23, 27.5)" id="flowchart-root-0" class="node default"><polygon transform="translate(-15,15)" class="label-container" points="15,0 30,-15 15,-30 0,-15"></polygon><g transform="translate(0, 0)" style="" class="label"><rect></rect><foreignObject height="0" width="0"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"></span></div></foreignObject></g></g><g transform="translate(80.5999984741211, 27.5)" id="flowchart-g-1" class="node default"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(141.3499984741211, 27.5)" id="flowchart-h-2" class="node default"><rect height="39" width="36.30000305175781" y="-19.5" x="-18.150001525878906" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-5.775001525878906, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="11.550003051757812"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>H</p></span></div></foreignObject></g></g><g transform="translate(202.0999984741211, 27.5)" id="flowchart-g2-3" class="node default end-of-word"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(261.5249938964844, 27.5)" id="flowchart-l-4" class="node default end-of-word"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>L</p></span></div></foreignObject></g></g><g transform="translate(319.6083221435547, 27.5)" id="flowchart-f-5" class="node default end-of-word"><rect height="39" width="34.51666259765625" y="-19.5" x="-17.258331298828125" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.883331298828125, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="9.76666259765625"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>F</p></span></div></foreignObject></g></g></g></g></g></g></svg>
</div>

<p><aside class="note">

You might find it interesting to note that this diagram is functionally the same as the previous ('children as a linked list') one; the connections are exactly the same, the nodes have just been rearranged.

</aside></p>

This still means that searching a child list uses a `O(n)` linear scan, but this representation makes those searches *much* more friendly to the CPU, and greatly reduces the size of each node.

### Some hard numbers

To get an idea of how the different representations compare, here's a breakdown for a trie containing the full set of named character references (2,231 words).

TODO: Link to the benchmark code here

#### Data size

<p><aside class="note">

Note: The sizes below assume a 64-bit architecture, i.e. pointers are 8 bytes wide.

</aside></p>

- **Representation 1** ('connections'):
  - Each node contains a fixed-size array of optional child node pointers
  - Each node is <span class="token_error">2056</span> bytes wide (using `[256]?*Node` as the `children` field)
  - There are 9,854 nodes in the trie, so 2,056 * 9,854 = 20,259,824 bytes total for the full trie (<span class="token_error">19.32 MiB</span>)
- **Representation 2** ('linked list'):
  - Each node contains a pointer to its first child and its next sibling
  - Each node is <span class="token_semigood">24</span> bytes wide
  - There are 9,854 nodes in the trie, so 24 * 9,854 = 236,496 bytes total for the full trie (<span class="token_semigood">230.95 KiB</span>)
- **Representation 3** ('flattened'):
  - Each node contains the index of its first child, and all nodes are allocated in one contiguous array
  - Each node is <span class="token_addition">4</span> bytes wide
  - There are 9,854 nodes in the trie, so 4 * 9,854 = 39,416 bytes total for the full trie (<span class="token_addition">38.49 KiB</span>)

That is, the 'flattened' version is <sup>1</sup>/<sub>514</sub> of the size of the 'connections' version, and <sup>1</sup>/<sub>6</sub> the size of the 'linked list' version.

<p><aside class="note">

Note: I went with `[256]?*Node` to keep the representations similar in what information they are capable of storing. Instead, you could make the trie only support ASCII characters and use `[128]?*Node` for the `children` field, which would roughly cut the size of the trie in half (from <span class="token_error">19.32 MiB</span> to <span class="token_error">9.70 MiB</span>).

In the 'linked list' and 'flattened' representations, restricting the characters to the ASCII set would only decrease the size of the nodes by 1 bit (`char` field would go from a `u8` to a `u7`).

</aside></p>

#### Performance

As mentioned, the 'linked list' and 'flattened' versions sacrifice the `O(1)` lookup of the 'connections' version in favor of reducing the data size, so while the 'flattened' version claws some performance back from the 'linked list' version, the 'connections' version is the fastest:

- **Representation 1** ('connections'):
  - <code><span class="token_addition">501.596ms</span> (<span class="token_addition">50ns</span> per `contains` call)</code>
- **Representation 2** ('linked list'):
  - <code><span class="token_error">965.138ms</span> (<span class="token_error">96ns</span> per `contains` call)</code>
- **Representation 3** ('flattened'):
  - <code><span class="token_semigood">609.215ms</span> (<span class="token_semigood">60ns</span> per `contains` call)</code>

One interesting thing to note is that the above results for representations 1 & 2 rely on a friendly allocation pattern for the nodes (i.e. the memory addresses of the nodes happening to end up fairly close to eachother) This is admittedly pretty likely when constructing a trie all at once, but, if we *intentionally force* a **horrendous** allocation pattern, where each allocated node gets put on an entirely separate [page](https://en.wikipedia.org/wiki/Page_(computer_memory)), we can see the effects very clearly:

- **Representation 1** ('connections'):
  - <code><span class="token_error">1.025s</span> (<span class="token_error">102ns</span> per `contains` call)</code> (each `contains` call takes ~2x longer than it did)
- **Representation 2** ('linked list'):
  - <code><span class="token_error">4.372s</span> (<span class="token_error">437ns</span> per `contains` call)</code> (each `contains` call takes ~4x longer than it did)
- **Representation 3** ('flattened'):
  - No difference since it always allocates one contiguous chunk of memory

If we run the relevant benchmarks through [`poop`](https://github.com/andrewrk/poop), we can confirm the cause of the slowdown (these results are from the 'connections' version):

```poopresults
Benchmark 1 (11 runs): ./trie-friendly-allocations
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           496ms ± 24.1ms     440ms …  518ms          1 ( 9%)        0%
  cpu_cycles         2.01G  ±  100M     1.78G  … 2.11G           1 ( 9%)        0%
  instructions       1.94G  ± 26.3K     1.94G  … 1.94G           0 ( 0%)        0%
  cache_references    107M  ± 3.40M     98.8M  …  109M           2 (18%)        0%
  cache_misses       33.1M  ± 1.15M     30.3M  … 34.0M           2 (18%)        0%
  branch_misses      21.7M  ± 20.7K     21.7M  … 21.7M           0 ( 0%)        0%
Benchmark 2 (5 runs): ./trie-horrendous-allocations
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.07s  ± 21.9ms    1.05s  … 1.11s           0 ( 0%)        💩+116.4% ±  5.5%
  cpu_cycles         4.17G  ± 92.4M     4.09G  … 4.33G           0 ( 0%)        💩+106.9% ±  5.6%
  instructions       1.92G  ± 38.4      1.92G  … 1.92G           0 ( 0%)          -  1.0% ±  0.0%
  cache_references    145M  ± 1.63M      144M  …  147M           0 ( 0%)        💩+ 35.3% ±  3.3%
  cache_misses       62.2M  ±  839K     61.8M  … 63.7M           0 ( 0%)        💩+ 88.3% ±  3.7%
  branch_misses      21.5M  ± 51.6K     21.4M  … 21.5M           1 (20%)          -  1.1% ±  0.2%
```

Note that the instruction counts are roughly the same between the 'friendly' and 'horrendous' versions, so the increased `cpu_cycles` and `wall_time` can presumably be attributed to the increase in cache misses and pointer chasing (the trie code itself is identical between the two versions).

#### Takeaways

The tradeoff between a ~20% difference in lookup speed for 2-3 orders of magnitude difference in data size seems pretty good, especially for what we're ultimately interested in implementing.

TODO

https://www.hytradboi.com/2025/05c72e39-c07e-41bc-ac40-85e8308f2917-programming-without-pointers

<p><aside class="note">

For completeness, I'll also note that it's possible to eliminate pointers while still using the 'connections' representation. For example, it could be done by allocating all nodes into an array, and then making the `children` field something like `[256]u16` where the values are indexes into the array of nodes (`u16` because it needs to be able to store an index to one of the 9,854 nodes in the trie, but it's not `?u16` because the index 0 can double as `null` since the root can never be a child)

This would keep the `O(1)` complexity to find a particular child *and* decrease the data size, but it would still be 2 orders of magnitude larger than the 'flattened' version (using `[256]u16` would make the trie take up 4.81 MiB, `[128]u16` would be 2.41 MiB).

</aside></p>

### An important note moving forward

<p><aside class="important">

In the next section, I will show diagrams that look like this in an effort to make them easier to understand:

<div style="text-align: center;">
<svg aria-roledescription="flowchart-v2" role="graphics-document document" style="max-width: 175px;" viewBox="0 0 175 160" class="mermaid-flowchart flowchart" xmlns="http://www.w3.org/2000/svg" id="graph-3490" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-1_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-1_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-1_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-1_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-1_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-1_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_g_0" d="M78.143,29.455L74.504,31.713C70.866,33.97,63.589,38.485,59.951,41.576C56.312,44.667,56.312,46.333,56.312,48C56.312,49.667,56.312,51.333,56.312,52.333C56.312,53.333,56.312,53.667,56.312,53.833L56.312,54"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_h_0" d="M98.378,27.309L106.222,29.924C114.066,32.54,129.754,37.77,137.598,41.218C145.442,44.667,145.442,46.333,145.442,48C145.442,49.667,145.442,51.333,145.442,52.333C145.442,53.333,145.442,53.667,145.442,53.833L145.442,54"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_g_g2_0" d="M37.712,92.837L35.86,94.364C34.008,95.891,30.304,98.946,28.452,101.306C26.6,103.667,26.6,105.333,26.6,107C26.6,108.667,26.6,110.333,26.6,111.333C26.6,112.333,26.6,112.667,26.6,112.833L26.6,113"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_g_l_0" d="M74.912,92.837L76.765,94.364C78.617,95.891,82.321,98.946,84.173,101.306C86.025,103.667,86.025,105.333,86.025,107C86.025,108.667,86.025,110.333,86.025,111.333C86.025,112.333,86.025,112.667,86.025,112.833L86.025,113"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_h_f_0" d="M145.442,97L145.442,97.833C145.442,98.667,145.442,100.333,145.442,102C145.442,103.667,145.442,105.333,145.442,107C145.442,108.667,145.442,110.333,145.442,111.333C145.442,112.333,145.442,112.667,145.442,112.833L145.442,113"></path></g><g class="edgeLabels"><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g></g><g class="nodes"><g transform="translate(86.68749618530273, 23)" id="flowchart-root-0" class="node default"><polygon transform="translate(-15,15)" class="label-container" points="15,0 30,-15 15,-30 0,-15"></polygon><g transform="translate(0, 0)" style="" class="label"><rect></rect><foreignObject height="0" width="0"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"></span></div></foreignObject></g></g><g transform="translate(56.312496185302734, 77.5)" id="flowchart-g-1" class="node default"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(145.44165802001953, 77.5)" id="flowchart-h-2" class="node default"><rect height="39" width="36.30000305175781" y="-19.5" x="-18.150001525878906" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-5.775001525878906, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="11.550003051757812"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>H</p></span></div></foreignObject></g></g><g transform="translate(26.599998474121094, 136.5)" id="flowchart-g2-4" class="node default end-of-word"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(86.02499389648438, 136.5)" id="flowchart-l-5" class="node default end-of-word"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>L</p></span></div></foreignObject></g></g><g transform="translate(145.44165802001953, 136.5)" id="flowchart-f-7" class="node default end-of-word"><rect height="39" width="34.51666259765625" y="-19.5" x="-17.258331298828125" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.883331298828125, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="9.76666259765625"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>F</p></span></div></foreignObject></g></g></g></g></g></g></svg>
</div>

but keep in mind that *really* the 'flattened' representation (representation 3) is being used, i.e. the most accurate visualization of the representation would look like this:

<div style="text-align: center;">
<div style="display: grid; grid-template-columns: repeat(6, 1fr); max-width: 350px; margin: 0 auto;">
	<span>0</span><span>1</span><span>2</span><span>3</span><span>4</span><span>5</span>
</div>
<svg aria-roledescription="flowchart-v2" role="graphics-document document" style="max-width: 345px;" viewBox="0 0 345 80" class="mermaid-flowchart flowchart" xmlns="http://www.w3.org/2000/svg" id="graph-3490" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-5112_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-5112_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-5112_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_g_0" d="M23,43 Q 40,70 65,45"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-solid flowchart-link" id="L_g_g2_0" d="M90,45 Q 130,80 185,45"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-solid flowchart-link" id="L_h_f_0" d="M145,45 Q 230,100 305,45"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_g_h_0" d="M100,27L120,27"></path><path marker-end="url(#graph-5112_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_g_l_0" d="M220,27L240,27"></path></g><g class="edgeLabels"></g><g class="nodes"><g transform="translate(23, 27.5)" id="flowchart-root-0" class="node default"><polygon transform="translate(-15,15)" class="label-container" points="15,0 30,-15 15,-30 0,-15"></polygon><g transform="translate(0, 0)" style="" class="label"><rect></rect><foreignObject height="0" width="0"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"></span></div></foreignObject></g></g><g transform="translate(80.5999984741211, 27.5)" id="flowchart-g-1" class="node default"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(141.3499984741211, 27.5)" id="flowchart-h-2" class="node default"><rect height="39" width="36.30000305175781" y="-19.5" x="-18.150001525878906" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-5.775001525878906, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="11.550003051757812"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>H</p></span></div></foreignObject></g></g><g transform="translate(202.0999984741211, 27.5)" id="flowchart-g2-3" class="node default end-of-word"><rect height="39" width="37.19999694824219" y="-19.5" x="-18.599998474121094" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-6.224998474121094, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.449996948242188"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>G</p></span></div></foreignObject></g></g><g transform="translate(261.5249938964844, 27.5)" id="flowchart-l-4" class="node default end-of-word"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>L</p></span></div></foreignObject></g></g><g transform="translate(319.6083221435547, 27.5)" id="flowchart-f-5" class="node default end-of-word"><rect height="39" width="34.51666259765625" y="-19.5" x="-17.258331298828125" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.883331298828125, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="9.76666259765625"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>F</p></span></div></foreignObject></g></g></g></g></g></g></svg>
</div>

</aside></p>

## DAFSA implementation

A while back at the same Zig meetup where I gave [a talk about my Windows resource compiler](https://www.youtube.com/watch?v=RZczLb_uI9E), Niles Salter aka [Validark](https://validark.dev/) gave a talk titled ***Better data structures and where to find them***. It was nominally about [his novel autocomplete data structure](https://validark.dev/DynSDT/), but the stated purpose of the talk was to get people interested in learning about data structures and potentially inventing their own.

<p><aside class="note">

Unfortunately, the recording/audio quality didn't end up being good enough to warrant uploading the talk anywhere (see the recording of my talk to get a sense of that).

</aside></p>

During the talk, I thought back to when [I contributed to an HTML parser implementation](https://github.com/watzon/zhtml/pulls?q=is%3Apr+is%3Aclosed+author%3Asqueek502) and had to leave proper *named character reference tokenization* as a `TODO` because I wasn't sure how to approach it. I can't remember if a [*deterministic acyclic finite state automaton*](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton) (DAFSA) was directly mentioned in the talk, or if I heard about it from talking with Niles afterwards, or if I learned of it while looking into trie variations later on (since the talk was about a novel trie variation). In any case, after learning about the DAFSA, it sounded like a pretty good tool for the job of named character references, so I <span style="border-bottom: 1px dotted; cursor: default;" title="this is the reason for all of this that was glossed over in the intro">revisited named character reference tokenization with that tool in hand</span>.

<p><aside class="note">

In other words, the talk (at least partially) served its purpose for me in particular. I didn't come up with anything novel, but it got me to look into data structures more and I have Niles to thank for that.

</aside></p>

### What is a DAFSA?

<p><aside class="note">

Note: There are a few names for a [DAFSA](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton): [DAWG](https://web.archive.org/web/20220722224703/http://pages.pathcom.com/~vadco/dawg.html), [MA-FSA](https://pkg.go.dev/github.com/smartystreets/mafsa), etc.

</aside></p>

A DAFSA is essentially the 'flattened' representation of a trie, but, more importantly, certain types of redundant nodes are eliminated during its construction (the particulars of this aren't too relevant here so I'll skip them; see [here](https://stevehanov.ca/blog/?id=115) if you're interested).

Going back to the same subset of named character references as the example in the *Trie implementation* section above, a DAFSA would represent that set of words like so:

<div style="text-align: center;">
<svg id="mermaid-dafsa" width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 145.48333740234375px;" viewBox="0 0 145.48333740234375 438" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker id="mermaid-123_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-circleStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="-1" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-crossStart" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="-1" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path d="M73.483,38.5L73.4,39.25C73.317,40,73.15,41.5,73.067,43.083C72.983,44.667,72.983,46.333,72.983,47.167L72.983,48" id="L_root_n_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,87L72.983,87.833C72.983,88.667,72.983,90.333,72.983,92C72.983,93.667,72.983,95.333,72.983,96.167L72.983,97" id="L_n_letter_o_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,136L72.983,136.833C72.983,137.667,72.983,139.333,72.983,141C72.983,142.667,72.983,144.333,72.983,145.167L72.983,146" id="L_letter_o_t_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M88.533,181.918L89.809,183.265C91.085,184.612,93.636,187.306,94.912,189.486C96.187,191.667,96.187,193.333,96.187,194.167L96.187,195" id="L_t_i1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M57.433,181.918L56.158,183.265C54.882,184.612,52.331,187.306,51.055,189.486C49.779,191.667,49.779,193.333,49.779,194.167L49.779,195" id="L_t_n1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,234L96.187,234.833C96.187,235.667,96.187,237.333,96.187,239C96.187,240.667,96.187,242.333,96.187,243.167L96.187,244" id="L_i1_n2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,234L49.779,234.833C49.779,235.667,49.779,237.333,49.779,239C49.779,240.667,49.779,242.333,49.779,243.167L49.779,244" id="L_n1_i2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,283L49.779,283.833C49.779,284.667,49.779,286.333,50.931,288.383C52.083,290.433,54.387,292.866,55.54,294.082L56.692,295.299" id="L_i2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,283L96.187,283.833C96.187,284.667,96.187,286.333,95.035,288.383C93.883,290.433,91.579,292.866,90.427,294.082L89.275,295.299" id="L_n2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M56.692,320.745L51.339,323.454C45.986,326.164,35.281,331.582,29.928,335.124C24.575,338.667,24.575,340.333,24.575,341.167L24.575,342" id="L_v_a_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,332L72.983,332.833C72.983,333.667,72.983,335.333,72.983,337C72.983,338.667,72.983,340.333,72.983,341.167L72.983,342" id="L_v_b_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M89.275,320.787L94.587,323.489C99.9,326.191,110.525,331.596,115.838,335.131C121.15,338.667,121.15,340.333,121.15,341.167L121.15,342" id="L_v_c_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M24.575,381L24.575,381.833C24.575,382.667,24.575,384.333,30.09,387.958C35.606,391.583,46.636,397.165,52.151,399.957L57.667,402.748" id="L_a_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,381L72.983,381.833C72.983,382.667,72.983,384.333,72.983,386C72.983,387.667,72.983,389.333,72.983,390.167L72.983,391" id="L_b_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.15,381L121.15,381.833C121.15,382.667,121.15,384.333,115.675,387.952C110.2,391.57,99.25,397.139,93.775,399.924L88.3,402.709" id="L_c_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default  " id="flowchart-root-0" transform="translate(72.98332977294922, 23)"><polygon points="15,0 30,-15 15,-30 0,-15" class="label-container" transform="translate(-15,15)"></polygon><g class="label" style="" transform="translate(0, 0)"><rect></rect><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n-1" transform="translate(72.98332977294922, 67.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-letter_o-3" transform="translate(72.98332977294922, 116.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.666664123535156" y="-19.5" width="33.33332824707031" height="39"></rect><g class="label" style="" transform="translate(-4.291664123535156, -12)"><rect></rect><foreignObject width="8.583328247070312" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>o</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-t-5" transform="translate(72.98332977294922, 165.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.550003051757812" y="-19.5" width="31.100006103515625" height="39"></rect><g class="label" style="" transform="translate(-3.1750030517578125, -12)"><rect></rect><foreignObject width="6.350006103515625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>t</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i1-7" transform="translate(49.7791633605957, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n1-8" transform="translate(96.18749618530273, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n2-10" transform="translate(49.7791633605957, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i2-12" transform="translate(96.18749618530273, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-v-14" transform="translate(72.98332977294922, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>v</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a-18" transform="translate(24.574996948242188, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>a</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b-19" transform="translate(72.98332977294922, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>b</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-c-20" transform="translate(121.1500015258789, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>c</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi-22" transform="translate(72.98332977294922, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g></g></g></g></svg>
</div>

As you can see, the `v`, `a`, `b`, `c` and `;` nodes are now shared between all the words that use them. This takes the number of nodes down to 13 in this example (compared to 22 for the trie).

The downside of this node consolidation is that we lose the ability to associate a given end-of-word node with a particular value. In this DAFSA example, *all words* except `not` end on the exact same node, so how can we know where to look for the associated value(s) for those words?

I'm not sure how useful it is, but here's an illustration of the problem when matching the word `&notinvc;`:

<div style="text-align: center;">
<svg id="mermaid-dafsa" width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 145.48333740234375px;" viewBox="0 0 145.48333740234375 500" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker id="mermaid-123_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-circleStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="-1" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-crossStart" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="-1" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path d="M73.483,38.5L73.4,39.25C73.317,40,73.15,41.5,73.067,43.083C72.983,44.667,72.983,46.333,72.983,47.167L72.983,48" id="L_root_n_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,87L72.983,87.833C72.983,88.667,72.983,90.333,72.983,92C72.983,93.667,72.983,95.333,72.983,96.167L72.983,97" id="L_n_letter_o_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,136L72.983,136.833C72.983,137.667,72.983,139.333,72.983,141C72.983,142.667,72.983,144.333,72.983,145.167L72.983,146" id="L_letter_o_t_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M88.533,181.918L89.809,183.265C91.085,184.612,93.636,187.306,94.912,189.486C96.187,191.667,96.187,193.333,96.187,194.167L96.187,195" id="L_t_i1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M57.433,181.918L56.158,183.265C54.882,184.612,52.331,187.306,51.055,189.486C49.779,191.667,49.779,193.333,49.779,194.167L49.779,195" id="L_t_n1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,234L96.187,234.833C96.187,235.667,96.187,237.333,96.187,239C96.187,240.667,96.187,242.333,96.187,243.167L96.187,244" id="L_i1_n2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,234L49.779,234.833C49.779,235.667,49.779,237.333,49.779,239C49.779,240.667,49.779,242.333,49.779,243.167L49.779,244" id="L_n1_i2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,283L49.779,283.833C49.779,284.667,49.779,286.333,50.931,288.383C52.083,290.433,54.387,292.866,55.54,294.082L56.692,295.299" id="L_i2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,283L96.187,283.833C96.187,284.667,96.187,286.333,95.035,288.383C93.883,290.433,91.579,292.866,90.427,294.082L89.275,295.299" id="L_n2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M56.692,320.745L51.339,323.454C45.986,326.164,35.281,331.582,29.928,335.124C24.575,338.667,24.575,340.333,24.575,341.167L24.575,342" id="L_v_a_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,332L72.983,332.833C72.983,333.667,72.983,335.333,72.983,337C72.983,338.667,72.983,340.333,72.983,341.167L72.983,342" id="L_v_b_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M89.275,320.787L94.587,323.489C99.9,326.191,110.525,331.596,115.838,335.131C121.15,338.667,121.15,340.333,121.15,341.167L121.15,342" id="L_v_c_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M24.575,381L24.575,381.833C24.575,382.667,24.575,384.333,30.09,387.958C35.606,391.583,46.636,397.165,52.151,399.957L57.667,402.748" id="L_a_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,381L72.983,381.833C72.983,382.667,72.983,384.333,72.983,386C72.983,387.667,72.983,389.333,72.983,390.167L72.983,391" id="L_b_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.15,381L121.15,381.833C121.15,382.667,121.15,384.333,115.675,387.952C110.2,391.57,99.25,397.139,93.775,399.924L88.3,402.709" id="L_c_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,420L72.983,451" id="L_semi3_notinvc_0" class=" edge-thickness-normal edge-pattern-dotted edge-thickness-normal edge-pattern-solid flowchart-link unknown-value" style="" marker-end="url(#mermaid-123_flowchart-v2-pointEnd)"></path></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default  " id="flowchart-root-0" transform="translate(72.98332977294922, 23)"><polygon points="15,0 30,-15 15,-30 0,-15" class="label-container" transform="translate(-15,15)"></polygon><g class="label" style="" transform="translate(0, 0)"><rect></rect><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-n-1" transform="translate(72.98332977294922, 67.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-letter_o-3" transform="translate(72.98332977294922, 116.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.666664123535156" y="-19.5" width="33.33332824707031" height="39"></rect><g class="label" style="" transform="translate(-4.291664123535156, -12)"><rect></rect><foreignObject width="8.583328247070312" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>o</p></span></div></foreignObject></g></g><g class="node default selected-path end-of-word" id="flowchart-t-5" transform="translate(72.98332977294922, 165.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.550003051757812" y="-19.5" width="31.100006103515625" height="39"></rect><g class="label" style="" transform="translate(-3.1750030517578125, -12)"><rect></rect><foreignObject width="6.350006103515625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>t</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-i1-7" transform="translate(49.7791633605957, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n1-8" transform="translate(96.18749618530273, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-n2-10" transform="translate(49.7791633605957, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i2-12" transform="translate(96.18749618530273, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-v-14" transform="translate(72.98332977294922, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>v</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a-18" transform="translate(24.574996948242188, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>a</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b-19" transform="translate(72.98332977294922, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>b</p></span></div></foreignObject></g></g><g class="node default selected-path" id="flowchart-c-20" transform="translate(121.1500015258789, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>c</p></span></div></foreignObject></g></g><g class="node default selected-path end-of-word" id="flowchart-semi-22" transform="translate(72.98332977294922, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g><g class="node default transformed-value unknown-value" id="flowchart-notinvc-42" transform="translate(72.983, 475.2249984741211)"><g class="basic label-container" style=""><circle class="outer-circle" style="" r="18.224998474121094" cx="0" cy="0"></circle><circle class="inner-circle" style="" r="13.224998474121094" cx="0" cy="0"></circle></g><g class="label" style="" transform="translate(-2.724998474121094, -12)"><rect></rect><foreignObject width="11.449996948242188" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>&nbsp;</p></span></div></foreignObject></g></g></g></g></g></svg>
</div>

To get around this downside, it'd be possible to use something like a separate hash map or devise some minimal perfect hashing scheme to lookup the associated code point(s) for a matching word after the fact, but, luckily, we don't have to worry too much about that because it turns out it is possible to do...

### Minimal perfect hashing using a DAFSA

First detailed in [*Applications of finite automata representing large vocabularies*](https://doi.org/10.1002/spe.4380230103) (Cláudio L. Lucchesi, Tomasz Kowaltowski, 1993) ([pdf](https://www.ic.unicamp.br/~reltech/1992/92-01.pdf)), the technique for minimal perfect hashing using a DAFSA is actually rather simple/elegant:

Within each node, store a count of all possible valid words from that node. For the example we've been using, those counts would look like this:

<div style="text-align: center;">
<svg id="mermaid-dafsa" width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 145.48333740234375px;" viewBox="0 0 145.48333740234375 438" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker id="mermaid-123_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-circleStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="-1" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-crossStart" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="-1" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path d="M73.483,38.5L73.4,39.25C73.317,40,73.15,41.5,73.067,43.083C72.983,44.667,72.983,46.333,72.983,47.167L72.983,48" id="L_root_n_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,87L72.983,87.833C72.983,88.667,72.983,90.333,72.983,92C72.983,93.667,72.983,95.333,72.983,96.167L72.983,97" id="L_n_letter_o_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,136L72.983,136.833C72.983,137.667,72.983,139.333,72.983,141C72.983,142.667,72.983,144.333,72.983,145.167L72.983,146" id="L_letter_o_t_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M88.533,181.918L89.809,183.265C91.085,184.612,93.636,187.306,94.912,189.486C96.187,191.667,96.187,193.333,96.187,194.167L96.187,195" id="L_t_i1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M57.433,181.918L56.158,183.265C54.882,184.612,52.331,187.306,51.055,189.486C49.779,191.667,49.779,193.333,49.779,194.167L49.779,195" id="L_t_n1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,234L96.187,234.833C96.187,235.667,96.187,237.333,96.187,239C96.187,240.667,96.187,242.333,96.187,243.167L96.187,244" id="L_i1_n2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,234L49.779,234.833C49.779,235.667,49.779,237.333,49.779,239C49.779,240.667,49.779,242.333,49.779,243.167L49.779,244" id="L_n1_i2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,283L49.779,283.833C49.779,284.667,49.779,286.333,50.931,288.383C52.083,290.433,54.387,292.866,55.54,294.082L56.692,295.299" id="L_i2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,283L96.187,283.833C96.187,284.667,96.187,286.333,95.035,288.383C93.883,290.433,91.579,292.866,90.427,294.082L89.275,295.299" id="L_n2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M56.692,320.745L51.339,323.454C45.986,326.164,35.281,331.582,29.928,335.124C24.575,338.667,24.575,340.333,24.575,341.167L24.575,342" id="L_v_a_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,332L72.983,332.833C72.983,333.667,72.983,335.333,72.983,337C72.983,338.667,72.983,340.333,72.983,341.167L72.983,342" id="L_v_b_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M89.275,320.787L94.587,323.489C99.9,326.191,110.525,331.596,115.838,335.131C121.15,338.667,121.15,340.333,121.15,341.167L121.15,342" id="L_v_c_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M24.575,381L24.575,381.833C24.575,382.667,24.575,384.333,30.09,387.958C35.606,391.583,46.636,397.165,52.151,399.957L57.667,402.748" id="L_a_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,381L72.983,381.833C72.983,382.667,72.983,384.333,72.983,386C72.983,387.667,72.983,389.333,72.983,390.167L72.983,391" id="L_b_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.15,381L121.15,381.833C121.15,382.667,121.15,384.333,115.675,387.952C110.2,391.57,99.25,397.139,93.775,399.924L88.3,402.709" id="L_c_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default  " id="flowchart-root-0" transform="translate(72.98332977294922, 23)"><polygon points="15,0 30,-15 15,-30 0,-15" class="label-container" transform="translate(-15,15)"></polygon><g class="label" style="" transform="translate(0, 0)"><rect></rect><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "></span></div></foreignObject></g></g><g class="node default" id="flowchart-n-1" transform="translate(72.98332977294922, 67.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.775, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>7</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-letter_o-3" transform="translate(72.98332977294922, 116.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.666664123535156" y="-19.5" width="33.33332824707031" height="39"></rect><g class="label" style="" transform="translate(-4.291664123535156, -12)"><rect></rect><foreignObject width="8.583328247070312" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>7</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-t-5" transform="translate(72.98332977294922, 165.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.550003051757812" y="-19.5" width="31.100006103515625" height="39"></rect><g class="label" style="" transform="translate(-4.5750030517578125, -12)"><rect></rect><foreignObject width="9.350006103515625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>7</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-i1-7" transform="translate(49.7791633605957, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-3.2833328247070312, -12)"><rect></rect><foreignObject width="9.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n1-8" transform="translate(96.18749618530273, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-n2-10" transform="translate(49.7791633605957, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i2-12" transform="translate(96.18749618530273, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-4.2833328247070312, -12)"><rect></rect><foreignObject width="9.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-v-14" transform="translate(72.98332977294922, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a-18" transform="translate(24.574996948242188, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b-19" transform="translate(72.98332977294922, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-c-20" transform="translate(121.1500015258789, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi-22" transform="translate(72.98332977294922, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-3.5416656494140625, -12)"><rect></rect><foreignObject width="7.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g></g></g></g></svg>
</div>

Then, to get a unique index for a given word, traverse the DAFSA as normal, but:

- For any *non-matching* node that is iterated when searching a list of children, add their `number` to the unique index
- For nodes that *match* the current character, if the node is a valid end-of-word, add 1 to the unique index

<p><aside class="note">

Note that the "non-matching node that is iterated when searching a list of children" part of this algorithm effectively relies on the DAFSA using the `O(n)` search of the 'flattened' representation of a trie discussed earlier.

</aside></p>

For example, if we had a DAFSA with `a`, `b`, `c`, and `d` as possible first characters (in that order), and the word we're looking for starts with `c`, then we'll iterate over `a` and `b` when looking for `c` in the list of children, so we add the numbers of the `a` and `b` nodes (whatever they happen to be) to the unique index. Here's an illustration:

<div style="text-align: center;">
<svg width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 200px;" viewBox="0 0 200 100" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2326_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2326_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-2326_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_a_b_0" d="M44,68L53,68"></path><path marker-end="url(#graph-2326_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_a_b_0" d="M93,68L102,68"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_a_0" d="M86.309,26.735L76.062,29.445C65.815,32.156,45.32,37.578,35.072,41.122C24.825,44.667,24.825,46.333,24.825,47.167L24.825,48"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_b_0" d="M89.878,30.303L87.144,32.419C84.41,34.535,78.943,38.768,76.209,41.717C73.475,44.667,73.475,46.333,73.475,47.167L73.475,48"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_c_0" d="M106.272,30.303L108.839,32.419C111.407,34.535,116.541,38.768,119.108,41.717C121.675,44.667,121.675,46.333,121.675,47.167L121.675,48"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_d_0" d="M109.825,26.75L119.833,29.459C129.841,32.167,149.858,37.583,159.867,41.125C169.875,44.667,169.875,46.333,169.875,47.167L169.875,48"></path></g><g class="edgeLabels"><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g></g><g class="nodes"><g transform="translate(97.57498931884766, 23)" id="flowchart-root-0" class="node default"><polygon transform="translate(-15,15)" class="label-container" points="15,0 30,-15 15,-30 0,-15"></polygon><g transform="translate(0, 0)" style="" class="label"><rect></rect><foreignObject height="0" width="0"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"></span></div></foreignObject></g></g><g transform="translate(24.824996948242188, 67.5)" id="flowchart-a-1" class="node default iterated-node"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>a</p></span></div></foreignObject></g></g><g transform="translate(73.47499084472656, 67.5)" id="flowchart-b-2" class="node default iterated-node"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>b</p></span></div></foreignObject></g></g><g transform="translate(121.67498779296875, 67.5)" id="flowchart-c-3" class="node default selected-path"><rect height="39" width="32.75" y="-19.5" x="-16.375" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>c</p></span></div></foreignObject></g></g><g transform="translate(169.87498474121094, 67.5)" id="flowchart-d-4" class="node default"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>d</p></span></div></foreignObject></g></g></g></g></g></svg>
</div>

<p><aside class="note">

Note: If the `a` or `b` nodes were marked as valid end-of-words, we ignore that bit of information&mdash;we only add 1 to the unique index if a *matching node* (in this case `c`) is marked as an end-of-word.

</aside></p>

For a given word in the set, applying this algorithm will produce a number between 1 and the total number of words in the DAFSA (inclusive), and it's guaranteed that each word will end up with a unique number (i.e. this is a [minimal perfect hash](https://en.wikipedia.org/wiki/Perfect_hash_function#Minimal_perfect_hash_function)). Here's what that looks like for the example we've been using:

<div style="text-align: center; position: relative;" id="dafsa-mph-container">
<div class="two-column-collapse" style="grid-template-columns: 2fr 1fr;">
	<div class="dafsa-mph-header">Current Word: <code id="current-word">not</code></div>
	<a class="dafsa-mph-header" id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">on</span></a>
</div>
<a class="has-bg" style="position:absolute; width: 50px; height: 50px; border-radius: 50%; right: 50px; top: calc(50% - 25px); line-height: 50px; font-size: 25px; color: #666; display: block; text-decoration: none;" href="#" id="next-word">&#x27A4;</a>
<a class="has-bg" style="position:absolute; width: 50px; height: 50px; border-radius: 50%; left: 50px; top: calc(50% - 25px); line-height: 50px; font-size: 25px; color: #666; display: block; text-decoration: none;" href="#" id="prev-word">&#x2B9C;</a>
<div style="position: absolute; right: calc(50% + 35px + 50px); height: 100%;">
	<div style="position: absolute; top: 145px; right: 0px; padding: 5px;" id="row-4">+1</div>
	<div style="position: absolute; top: 195px; right: 0px; padding: 5px;" id="row-5">+3</div>
	<div style="position: absolute; top: 343px; right: 0px; padding: 5px;" id="row-8">+3</div>
	<div style="position: absolute; top: 395px; right: 0px; padding: 5px;" id="row-9">+1</div>
	<div style="position: absolute; top: 445px; right: 0px; padding: 5px; width: 30px; text-align: right; border-top: 1px solid;" class="unique-index-total">5</div>
</div>
<svg id="mermaid-dafsa-mph" width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 145.48333740234375px;" viewBox="0 0 145.48333740234375 480" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker id="mermaid-123_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-circleStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="-1" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-crossStart" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="-1" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#mermaid-123_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="sibling-i-n" d="M60,215L75,215"></path><path marker-end="url(#mermaid-123_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="sibling-a-b" d="M40,362L53,362"></path><path marker-end="url(#mermaid-123_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="sibling-b-c" d="M90,362L101,362"></path><path d="M73.483,38.5L73.4,39.25C73.317,40,73.15,41.5,73.067,43.083C72.983,44.667,72.983,46.333,72.983,47.167L72.983,48" id="L_root_n_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,87L72.983,87.833C72.983,88.667,72.983,90.333,72.983,92C72.983,93.667,72.983,95.333,72.983,96.167L72.983,97" id="L_n_letter_o_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,136L72.983,136.833C72.983,137.667,72.983,139.333,72.983,141C72.983,142.667,72.983,144.333,72.983,145.167L72.983,146" id="L_letter_o_t_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M88.533,181.918L89.809,183.265C91.085,184.612,93.636,187.306,94.912,189.486C96.187,191.667,96.187,193.333,96.187,194.167L96.187,195" id="L_t_i1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M57.433,181.918L56.158,183.265C54.882,184.612,52.331,187.306,51.055,189.486C49.779,191.667,49.779,193.333,49.779,194.167L49.779,195" id="L_t_n1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,234L96.187,234.833C96.187,235.667,96.187,237.333,96.187,239C96.187,240.667,96.187,242.333,96.187,243.167L96.187,244" id="L_i1_n2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,234L49.779,234.833C49.779,235.667,49.779,237.333,49.779,239C49.779,240.667,49.779,242.333,49.779,243.167L49.779,244" id="L_n1_i2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,283L49.779,283.833C49.779,284.667,49.779,286.333,50.931,288.383C52.083,290.433,54.387,292.866,55.54,294.082L56.692,295.299" id="L_i2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,283L96.187,283.833C96.187,284.667,96.187,286.333,95.035,288.383C93.883,290.433,91.579,292.866,90.427,294.082L89.275,295.299" id="L_n2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M56.692,320.745L51.339,323.454C45.986,326.164,35.281,331.582,29.928,335.124C24.575,338.667,24.575,340.333,24.575,341.167L24.575,342" id="L_v_a_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,332L72.983,332.833C72.983,333.667,72.983,335.333,72.983,337C72.983,338.667,72.983,340.333,72.983,341.167L72.983,342" id="L_v_b_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M89.275,320.787L94.587,323.489C99.9,326.191,110.525,331.596,115.838,335.131C121.15,338.667,121.15,340.333,121.15,341.167L121.15,342" id="L_v_c_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M24.575,381L24.575,381.833C24.575,382.667,24.575,384.333,30.09,387.958C35.606,391.583,46.636,397.165,52.151,399.957L57.667,402.748" id="L_a_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,381L72.983,381.833C72.983,382.667,72.983,384.333,72.983,386C72.983,387.667,72.983,389.333,72.983,390.167L72.983,391" id="L_b_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.15,381L121.15,381.833C121.15,382.667,121.15,384.333,115.675,387.952C110.2,391.57,99.25,397.139,93.775,399.924L88.3,402.709" id="L_c_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M180,220L180,251" id="L_semi3_notinvc_0" class=" edge-thickness-normal edge-pattern-dotted edge-thickness-normal edge-pattern-solid flowchart-link" style="" marker-end="url(#mermaid-123_flowchart-v2-pointEnd)"></path></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default  " id="flowchart-root-0" transform="translate(72.98332977294922, 23)"><polygon points="15,0 30,-15 15,-30 0,-15" class="label-container" transform="translate(-15,15)"></polygon><g class="label" style="" transform="translate(0, 0)"><rect></rect><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "></span></div></foreignObject></g></g><g class="node default" id="flowchart-n-1" transform="translate(72.98332977294922, 67.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.775, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>7</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-letter_o-3" transform="translate(72.98332977294922, 116.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.666664123535156" y="-19.5" width="33.33332824707031" height="39"></rect><g class="label" style="" transform="translate(-4.291664123535156, -12)"><rect></rect><foreignObject width="8.583328247070312" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>7</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-t-5" transform="translate(72.98332977294922, 165.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.550003051757812" y="-19.5" width="31.100006103515625" height="39"></rect><g class="label" style="" transform="translate(-4.5750030517578125, -12)"><rect></rect><foreignObject width="9.350006103515625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>7</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-i1-7" transform="translate(49.7791633605957, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-3.2833328247070312, -12)"><rect></rect><foreignObject width="9.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n1-8" transform="translate(96.18749618530273, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-n2-10" transform="translate(49.7791633605957, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i2-12" transform="translate(96.18749618530273, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-4.2833328247070312, -12)"><rect></rect><foreignObject width="9.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-v-14" transform="translate(72.98332977294922, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>3</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a-18" transform="translate(24.574996948242188, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b-19" transform="translate(72.98332977294922, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g><g class="node default" id="flowchart-c-20" transform="translate(121.1500015258789, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi-22" transform="translate(72.98332977294922, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-3.5416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>1</p></span></div></foreignObject></g></g><g class="node default transformed-value" id="flowchart-notinvc-42" transform="translate(180, 275.2249984741211)"><g class="basic label-container" style=""><circle class="outer-circle" style="" r="18.224998474121094" cx="0" cy="0"></circle><circle class="inner-circle" style="" r="13.224998474121094" cx="0" cy="0"></circle></g><g class="label" style="" transform="translate(-5.724998474121094, -12)"><rect></rect><foreignObject width="11.449996948242188" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>??</p></span></div></foreignObject></g></g></g></g></g></svg>
<div class="dafsa-mph-header">Unique Index: <b class="unique-index">0</b></div>
</div>

<script>
(function(){
	let root = document.getElementById("dafsa-mph-container");
	let node_ids = [
		'flowchart-n-1',
		'flowchart-letter_o-3',
		'flowchart-t-5',
		'flowchart-i1-7',
		'flowchart-n1-8',
		'flowchart-n2-10',
		'flowchart-i2-12',
		'flowchart-v-14',
		'flowchart-a-18',
		'flowchart-b-19',
		'flowchart-c-20',
		'flowchart-semi-22'
	];
	let sibling_ids = [
		'sibling-i-n',
		'sibling-a-b',
		'sibling-b-c'
	];
	let clear = function() {
		for (let i=0; i<node_ids.length; i++) {
			let e = root.querySelector('#'+node_ids[i]);
			e.classList.remove('selected-path');
			e.classList.remove('iterated-node');
			e.querySelector('.nodeLabel').style.display = 'none';
		}
		for (let i=0; i<sibling_ids.length; i++) {
			let e = root.querySelector('#'+sibling_ids[i]);
			e.style.display = 'none';
		}
	}
	let apply = function(word, unique_index) {
		for (let i=0; i<word.selected.length; i++) {
			let e = root.querySelector('#flowchart-'+word.selected[i]);
			e.classList.add('selected-path');
			let label = e.querySelector('.nodeLabel');
			label.textContent = word.word[i];
			label.style.display = 'block';
		}
		for (let i=0; i<word.siblings.length; i++) {
			let e = root.querySelector('#sibling-'+word.siblings[i]);
			e.style.display = 'initial';
		}
		for (let i=0; i<word.iterated.length; i++) {
			let e = root.querySelector('#flowchart-'+word.iterated[i]);
			e.classList.add('iterated-node');
			let label = e.querySelector('.nodeLabel');
			label.textContent = word.numbers[i];
			label.style.display = 'block';
		}
		for (let i=0; i<word.ends.length; i++) {
			let e = root.querySelector('#flowchart-'+word.ends[i]);
			e.classList.add('iterated-node');
		}
		let row_lookup = [4,5,8,9];
		for (let i=0; i<row_lookup.length; i++) {
			let e = root.querySelector("#row-"+row_lookup[i]);
			e.textContent = word.rows[i] == 0 ? "" : "+"+word.rows[i];
		}
		root.querySelector('.transformed-value .nodeLabel').innerHTML = word.result;
		root.querySelector('.unique-index-total').textContent = unique_index;
		root.querySelector('.unique-index').textContent = unique_index;
		root.querySelector('#current-word').textContent = word.word;
	}
	let not = {
		selected: ['n-1', 'letter_o-3', 't-5'],
		siblings: [],
		word: 'not',
		iterated: [],
		numbers: [],
		ends: ['t-5'],
		rows: [1,0,0,0],
		result: '&not;'
	}
	let notinva = {
		selected: ['n-1', 'letter_o-3', 't-5', 'i1-7', 'n2-10', 'v-14', 'a-18', 'semi-22'],
		siblings: [],
		word: 'notinva;',
		iterated: [],
		numbers: [],
		ends: ['t-5', 'semi-22'],
		rows: [1,0,0,1],
		result: '&notinva;'
	}
	let notinvb = {
		selected: ['n-1', 'letter_o-3', 't-5', 'i1-7', 'n2-10', 'v-14', 'b-19', 'semi-22'],
		siblings: ['a-b'],
		word: 'notinvb;',
		iterated: ['a-18'],
		numbers: [1],
		ends: ['t-5', 'semi-22'],
		rows: [1,0,1,1],
		result: '&notinvb;'
	}
	let notinvc = {
		selected: ['n-1', 'letter_o-3', 't-5', 'i1-7', 'n2-10', 'v-14', 'c-20', 'semi-22'],
		siblings: ['a-b', 'b-c'],
		word: 'notinvc;',
		iterated: ['a-18', 'b-19'],
		numbers: [1, 1],
		ends: ['t-5', 'semi-22'],
		rows: [1,0,2,1],
		result: '&notinvc;'
	}
	let notniva = {
		selected: ['n-1', 'letter_o-3', 't-5', 'n1-8', 'i2-12', 'v-14', 'a-18', 'semi-22'],
		siblings: ['i-n'],
		word: 'notniva;',
		iterated: ['i1-7'],
		numbers: [3],
		ends: ['t-5', 'semi-22'],
		rows: [1,3,0,1],
		result: '&notniva;'
	}
	let notnivb = {
		selected: ['n-1', 'letter_o-3', 't-5', 'n1-8', 'i2-12', 'v-14', 'b-19', 'semi-22'],
		siblings: ['i-n', 'a-b'],
		word: 'notnivb;',
		iterated: ['i1-7', 'a-18'],
		numbers: [3, 1],
		ends: ['t-5', 'semi-22'],
		rows: [1,3,1,1],
		result: '&notnivb;'
	}
	let notnivc = {
		selected: ['n-1', 'letter_o-3', 't-5', 'n1-8', 'i2-12', 'v-14', 'c-20', 'semi-22'],
		siblings: ['i-n', 'a-b', 'b-c'],
		word: 'notnivc;',
		iterated: ['i1-7', 'a-18', 'b-19'],
		numbers: [3, 1, 1],
		ends: ['t-5', 'semi-22'],
		rows: [1,3,2,1],
		result: '&notnivc;'
	}
	let sequence = [not, notinva, notinvb, notinvc, notniva, notnivb, notnivc];
	let cur_word_i = 0;
	clear();
	apply(sequence[cur_word_i], cur_word_i + 1);
	let next = function() {
		clear();
		cur_word_i = (cur_word_i + 1) % sequence.length;
		apply(sequence[cur_word_i], cur_word_i + 1);
	};
	let prev = function() {
		clear();
		cur_word_i = cur_word_i - 1;
		if (cur_word_i < 0) cur_word_i = sequence.length - 1;
		apply(sequence[cur_word_i], cur_word_i + 1);
	};
	let auto;
	let start = function() {
		auto = setInterval(next, 2250);
		root.querySelector('#autoplay-status').textContent = 'on';
	}
	let stop = function() {
		clearInterval(auto);
		auto = undefined;
		root.querySelector('#autoplay-status').textContent = 'off';
	}
	let toggle = function() {
		if (auto !== undefined) {
			stop();
		} else {
			start();
		}
	}
	start();

	root.querySelector('#next-word').onclick = function(e) {
		e.preventDefault();
		stop();
		next();
	}
	root.querySelector('#prev-word').onclick = function(e) {
		e.preventDefault();
		stop();
		prev();
	}
	root.querySelector('#autoplay-toggle').onclick = function(e) {
		e.preventDefault();
		toggle();
	}
})()
</script>

After you have the unique index of a word, you can then use a lookup array for the associated values and index into it using `unique_index - 1`.

<p><aside class="note">

Note: It's not relevant here, but I think it's pretty cool that it's also possible to reconstruct the associated word if you have its unique index. You basically do the same thing as when you are calculating a unique index, but instead of adding to the unique index you're subtracting from it as you traverse the DAFSA. A tidbit that I accidentally ran into is that [this 'reverse lookup' only works if you include the end-of-word nodes themselves in their own 'counts of possible words from that node'](https://github.com/squeek502/named-character-references/commit/6619a3a8d1e86b1174269f73b413d957e56df975).

</aside></p>

## Trie vs DAFSA for named character references

Ok, so now we have two data structures that seem pretty well suited for named character reference matching&mdash;a trie and a DAFSA&mdash;but how do they compare? It's now (finally) time to start using the [full set of named character references and all of their mapped code point(s)](https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references) to see how the different data structures stack up.

Some numbers to keep in mind up front:
- There are 2,231 named character references total
- A trie will use 9,854 nodes to encode the set of named character references
- A DAFSA will use 3,872 nodes to encode the set of named character references

### Another brief detour: representing the mapped value(s)

As mentioned earlier, each named character reference is mapped to either one or two code points. Unicode code points have a range of `0x0`-`0x10FFFF`, but if we actually look at the [set of code points used by named character references](https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references), there are a few properties worth noting:

- The maximum value of the first code point is `U+1D56B`, which takes 17 bits to encode, so all first code point values can fit into a 17 bit wide unsigned integer.
- The set of distinct *second* code point values is actually very small, with only 8 unique code points. This means that an enum that's only 4 bits wide (3 bits for the 8 different values, 1 additional bit to encode 'no second code point') can be used to store all the information about the second code point.

With both of these properties taken together, it's possible to encode the mapped code point values for any given named character reference in 21 bits. With padding between the elements of an array of 21-bit integers, though, that will round up to 4 bytes per element (11 bits of padding), so it ends up being the same as if 32 bit integers were used.

Here's a diagram of a possible memory layout of an array using this representation, where <span class="first-element-key">&nbsp;&nbsp;&nbsp;&nbsp;</span> is the bits of the first code point, <span class="second-element-key">&nbsp;&nbsp;&nbsp;&nbsp;</span> is the bits of the second code point, and <span class="padding-element-key">&nbsp;&nbsp;&nbsp;&nbsp;</span> is the padding bits between elements:

<div style="display: grid; grid-template-columns: max-content 1fr;">
	<div>
		<div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem; background: #111;">byte index</div>
		<div style="height: 2rem; line-height: 2rem; margin-top: 1px;"></div>
		<div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem; margin-top: 1px; background: #111;">element index</div>
	</div>
	<div class="regular-array">
		<div class="byte-indexes">
			<span>0</span>
			<span>1</span>
			<span>2</span>
			<span>3</span>
			<span>4</span>
			<span>5</span>
			<span>6</span>
			<span>7</span>
			<span>8</span>
			<span>9</span>
			<span>10</span>
			<span>11</span>
		</div>
		<div class="elements">
			<div class="element">
				<span class="first"></span>
				<span class="second"></span>
				<span class="padding"></span>
			</div>
			<div class="element">
				<span class="first"></span>
				<span class="second"></span>
				<span class="padding"></span>
			</div>
			<div class="element">
				<span class="first"></span>
				<span class="second"></span>
				<span class="padding"></span>
			</div>
		</div>
		<div class="array-indexes">
			<span><span>0</span></span>
			<span><span>1</span></span>
			<span><span>2</span></span>
		</div>
		<style scoped>
		.regular-array .byte-indexes span, .regular-array .array-indexes > span, .regular-array .elements .element {
			border: 1px solid #777;
			height: 2rem;
			line-height: 2rem;
			background: #111;
		}
		.regular-array .array-indexes > span > span {
			width: 25%; text-align: center; display: inline-block;
		}
		.regular-array .byte-indexes {
			display: grid; grid-template-columns: repeat(12, 1fr); text-align: center;
		}
		.regular-array .array-indexes, .regular-array .elements {
			display: grid; grid-template-columns: repeat(3, 1fr);
		}
		.regular-array .element {
			display: grid; grid-template-columns: 53.125% 12.5% 34.375%;
		}
		.regular-array .element .first, .first-element-key {
			background: repeating-linear-gradient(
				-45deg,
				#613583,
				#613583 10px,
				#251134 10px,
				#251134 20px
			);
		}
		.regular-array .element .second, .second-element-key {
			background: repeating-linear-gradient(
				-45deg,
				#142A43,
				#142A43 10px,
				#1A5FB4 10px,
				#1A5FB4 20px
			);
		}
		.regular-array .element .padding, .padding-element-key {
			background: repeating-linear-gradient(
				-45deg,
				#222,
				#222 10px,
				#333 10px,
				#333 20px
			);
		}
		</style>
	</div>
</div>

However, while using 21 bits to represent the mapped code point(s) does not automatically lead to any saved bytes over a 32 bit integer, it opens up the possibility to tightly pack an array of 21-bit elements in order to *actually* save some bytes. Yet, doing so means that storing/loading elements from the tightly packed array becomes trickier (both computationally and implementation-wise). Here's the same diagram as before, but with the elements tightly packed (no padding bits between elements):

<div style="display: grid; grid-template-columns: max-content 1fr;">
	<div>
		<div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem; background: #111;">byte index</div>
		<div style="height: 2rem; line-height: 2rem; margin-top: 1px;"></div>
		<div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem; margin-top: 1px; background: #111;">element index</div>
	</div>
	<div class="bitpacked-array">
	<div class="byte-indexes">
		<span>0</span>
		<span>1</span>
		<span>2</span>
		<span>3</span>
		<span>4</span>
		<span>5</span>
		<span>6</span>
		<span>7</span>
		<span>8</span>
		<span>9</span>
		<span>10</span>
		<span>11</span>
	</div>
	<div class="elements">
		<div class="element">
			<span class="first"></span>
			<span class="second"></span>
		</div>
		<div class="element">
			<span class="first"></span>
			<span class="second"></span>
		</div>
		<div class="element">
			<span class="first"></span>
			<span class="second"></span>
		</div>
		<div class="element">
			<span class="first"></span>
			<span class="second"></span>
		</div>
		<div class="element trailing">
			<span class="first"></span>
		</div>
	</div>
	<div class="array-indexes">
		<span><span>0</span></span>
		<span><span>1</span></span>
		<span><span>2</span></span>
		<span><span>3</span></span>
		<span class="trailing"><span>4</span></span>
	</div>
	<style scoped>
	.bitpacked-array .byte-indexes span, .bitpacked-array .array-indexes > span, .bitpacked-array .elements .element {
		border: 1px solid #777;
		height: 2rem;
		line-height: 2rem;
		background: #111;
	}
	.bitpacked-array .array-indexes > span > span {
		width: 25%; text-align: center; display: inline-block;
	}
	.bitpacked-array .byte-indexes {
		display: grid; grid-template-columns: repeat(12, 1fr); text-align: center;
	}
	.bitpacked-array .elements, .bitpacked-array .array-indexes {
		display: grid; grid-template-columns: 21.875% 21.875% 21.875% 21.875% 12.5%;
	}
	.bitpacked-array .element {
		display: grid; grid-template-columns: 80.952381% 1fr;
	}
	.bitpacked-array .element.trailing {
		grid-template-columns: 1fr;
	}
	.bitpacked-array .trailing {
		border-right: 0 !important;
	}
	.bitpacked-array .element .first {
		background: repeating-linear-gradient(
			-45deg,
			#613583,
			#613583 10px,
			#251134 10px,
			#251134 20px
		);
	}
	.bitpacked-array .element .second {
		background: repeating-linear-gradient(
			-45deg,
			#142A43,
			#142A43 10px,
			#1A5FB4 10px,
			#1A5FB4 20px
		);
	}
	.bitpacked-array .element .padding {
		background: repeating-linear-gradient(
			-45deg,
			#222,
			#222 10px,
			#333 10px,
			#333 20px
		);
	}
	</style>
	</div>
</div>

You'll notice that no elements past the first start or end on byte boundaries, meaning in order to load an element, a fair bit of bitwise operations are required (bit shifting, etc). This makes array accesses more expensive, but that actually isn't a big deal for our use case, since we only ever access the array of values once per named character reference, and only after we're certain we have a match. So, tighly bitpacking the value array is a viable way to save some extra bytes for our purposes.

<p><aside class="note">

Note: This is just context for the next section where I'll mention data sizes for versions that use the "regular array" representation or the "tighly bitpacked array" representation for the values.

</aside></p>

### Data size

For the DAFSA, the size calculation is pretty straightforward:

- The data of each node can fit into 4 bytes with a few bits to spare (expand below if you're interested in the details), and there are 3,872 nodes in the DAFSA, so that's 15,488 bytes total

<details class="box-border" style="padding: 1em; padding-bottom: 0;">
<summary style="margin-bottom: 1em;">Nitty-gritty DAFSA node size details</summary>

Ultimately, the goal is to keep the node size less than or equal to 32 bits while storing the following data on each node:

- An ASCII character
  + This can technically be represented in 6 bits, since the actual alphabet of characters used in the list of named character references only includes 61 unique characters ('1'...'8', ';', 'a'...'z', 'A'...'Z'). However, to do so you'd need to convert between the 6 bit representation and the actual ASCII value of each character to do comparisons. We aren't desperate to save bits, though, so we can get away with representing this value as 8 bits, which makes comparisons with any byte value trivial.
- A "count of all possible valid words from that node"
  + Empirically, the highest value within our particular DAFSA for this field is `168`, which can fit into 8 bits.
- An "end of word" flag
  + 1 bit
- A "last sibling" flag
  + 1 bit
- An "index of first child" field
  + There are 3,872 nodes in our DAFSA, so all child indexes can fit into 12 bits.

In total, that's 8 + 8 + 1 + 1 + 12 = <span class="token_addition">30 bits</span>, so we have 2 bits to spare while remaining within the 32 bit target size with this representation.

</details>

- There are 2,231 named character references, and the mapped code points for each of them need either 4 bytes (if using a regular array) or 21 bits (if using a tightly bitpacked array)
  + For the regular array, that's 8,924 bytes total
  + For the tightly bitpacked array, that's 5,857 bytes total

So, the DAFSA *and* the lookup array for the values (together) will use either 24,412 bytes (<span class="token_addition">23.84 KiB</span>) or 21,345 bytes (<span class="token_addition">20.84 KiB</span>) total.

For the trie, there's slightly more to discuss around data representation before we can get to the data size calculations. It was glossed over in the *Trie implementation* section, but when using the 'flattened' representation of a trie there are effectively two ways to handle value lookups for each word:

1. Store an array of 2,231 values (one for each named character reference) and then also store an index into that array on each end-of-word node.
    - This increases the bit size needed for each node by 12 bits (since 2,231 can be encoded in 12 bits)
2. Store an array of 9,854 values (one for each node in the trie) and then index into the value array by re-using the index of the end-of-word node.
    - This makes the size of the value array 4.42 times larger, but does not affect the node size

Beyond that, the details aren't *super* relevant so I'll leave it up to you if you want to expand the following:

<details class="box-border" style="padding: 1em; padding-bottom: 0;">
<summary style="margin-bottom: 1em;">Nitty-gritty trie node size details</summary>

TODO

</details>

The summary is that, depending on the particular representation, the trie will use between 57,993 bytes and 68,777 bytes (<span class="token_semigood">56.63 KiB</span> to <span class="token_error">67.16 KiB</span>) total, or, if the values array is tightly bitpacked, between 54,926 bytes and 55,227 bytes (<span class="token_semigood">53.64 KiB</span> to <span class="token_semigood">53.93 KiB</span>) total.

Ultimately, the data size of the trie is going to be at least **2x larger** than the equivalent DAFSA.

### Performance

The DAFSA implementation uses more instructions than the trie implementation because it needs to build up the unique index during iteration, but the DAFSA saves on cache misses (presumably due to the smaller overall size of the DAFSA and its node re-use) and everything just about evens out in terms of wall clock time:

```poopresults
Benchmark 1 (449 runs): ./trie
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          44.4ms ± 1.57ms    43.0ms … 61.8ms          3 ( 1%)        0%
  peak_rss           61.8MB ± 62.5KB    61.6MB … 61.9MB          0 ( 0%)        0%
  cpu_cycles         49.5M  ±  463K     48.5M  … 51.9M          19 ( 4%)        0%
  instructions       76.2M  ± 2.95      76.2M  … 76.2M           5 ( 1%)        0%
  cache_references   2.54M  ± 21.6K     2.48M  … 2.63M          12 ( 3%)        0%
  cache_misses        119K  ± 1.64K      115K  …  128K          18 ( 4%)        0%
  branch_misses       322K  ± 1.02K      319K  …  328K          18 ( 4%)        0%
Benchmark 2 (451 runs): ./dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          44.3ms ±  561us    43.8ms … 48.4ms         19 ( 4%)          -  0.4% ±  0.3%
  peak_rss           61.6MB ± 66.6KB    61.5MB … 61.7MB          0 ( 0%)          -  0.2% ±  0.0%
  cpu_cycles         53.0M  ±  566K     52.3M  … 54.9M          11 ( 2%)        💩+  7.0% ±  0.1%
  instructions       78.7M  ± 2.59      78.7M  … 78.7M           6 ( 1%)        💩+  3.2% ±  0.0%
  cache_references   2.49M  ± 30.0K     2.43M  … 2.60M          29 ( 6%)        ⚡-  2.0% ±  0.1%
  cache_misses       90.9K  ± 1.32K     86.4K  … 95.4K          12 ( 3%)        ⚡- 23.5% ±  0.2%
  branch_misses       331K  ±  730       330K  …  337K          21 ( 5%)        💩+  2.9% ±  0.0%
```

<p><aside class="note">

Note: Bitpacking the value array of the trie doesn't seem to affect the overall performance, and we see the same sort of pattern: more instructions (due to the added bit shifting during value lookup), but fewer cache misses.

<details class="box-border" style="padding: 1em; margin-bottom: 1em;">
<summary>Benchmark results</summary>

```poopresults
Benchmark 1 (231 runs): ./trie
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.3ms ±  249us    43.1ms … 45.9ms         20 ( 9%)        0%
  peak_rss           61.8MB ± 63.5KB    61.6MB … 61.9MB          0 ( 0%)        0%
  cpu_cycles         49.4M  ±  159K     49.1M  … 50.3M           3 ( 1%)        0%
  instructions       76.2M  ± 2.61      76.2M  … 76.2M           6 ( 3%)        0%
  cache_references   2.52M  ± 13.6K     2.48M  … 2.57M           4 ( 2%)        0%
  cache_misses        118K  ±  933       116K  …  122K           2 ( 1%)        0%
  branch_misses       321K  ±  548       319K  …  325K           4 ( 2%)        0%
Benchmark 2 (231 runs): ./trie-bitpacked-values
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.3ms ±  504us    43.0ms … 46.2ms         19 ( 8%)          +  0.1% ±  0.2%
  peak_rss           61.6MB ± 64.0KB    61.5MB … 61.7MB          0 ( 0%)          -  0.2% ±  0.0%
  cpu_cycles         48.9M  ±  180K     48.6M  … 50.0M           4 ( 2%)          -  0.9% ±  0.1%
  instructions       77.4M  ± 2.56      77.4M  … 77.4M           0 ( 0%)        💩+  1.6% ±  0.0%
  cache_references   2.53M  ± 23.7K     2.48M  … 2.68M           1 ( 0%)          +  0.7% ±  0.1%
  cache_misses        104K  ± 1.18K      101K  …  107K           7 ( 3%)        ⚡- 12.5% ±  0.2%
  branch_misses       335K  ± 1.05K      333K  …  344K          10 ( 4%)        💩+  4.3% ±  0.0%
```

</details>

</aside></p>

### Takeaways

For the use-case of named character references, using a DAFSA instead of a trie cuts the size of the data *at least* in half while performing about the same.

## The Ladybird implementation

> **13.2.5.73 Named character reference state**
>
> Consume the maximum number of characters possible, where the consumed characters are one of the identifiers in the first column of the named character references table. Append each character to the temporary buffer when it's consumed.
>
> - If there is a match
>     + ...
> 
> - Otherwise
>     + Flush code points consumed as a character reference. Switch to the ambiguous ampersand state.

```c
BEGIN_STATE(NamedCharacterReference)
{
    if (matcher.try_consume(current_character)) {
        temporary_buffer.append(current_character);
        continue; // stay in the NamedCharacterReference state and go to the next character
    } else {
        DONT_CONSUME_CHARACTER;
    }

    auto overconsumed_code_points = matcher.overconsumed_code_points();
    if (overconsumed_code_points > 0) {
        backtrack_to(current_offset - overconsumed_code_points);
        temporary_buffer.shrink_by(overconsumed_code_points);
    }

    auto mapped_codepoints = matcher.code_points();
    // If there is a match
    if (mapped_codepoints) {
        // ...
    } else {
        FLUSH_CODEPOINTS_CONSUMED_AS_A_CHARACTER_REFERENCE;
        SWITCH_TO(AmbiguousAmpersand);
    }
}
```

## Comparison to the major browser engines

Instead of going the route of putting my implementation into the other browsers' engines to compare, I went with taking the other browsers' implementations and putting them in Ladybird. So, you'll probably want to take my benchmarks with at least a small grain of salt, as in order for them to be accurate you'll have to trust that:

- I faithfully integrated the Gecko/Blink/WebKit implementations into Ladybird
- The performance characteristics exhibited would hold when putting my implementation into their tokenizer

The only real assurance I can give you is that the same number of [web platform tests](https://wpt.fyi/) within the `html/syntax/parsing` category were passing with each browser's implementation integrated.

### Comparison with Gecko (Firefox)

### Comparison with Blink/WebKit (Chrome/Safari)

Blink started as a fork of WebKit, and while Blink has reorganized things a bit, the named character reference tokenization implementation remains identical between the two engines.

---

Random notes:

- there are two letter named character references (e.g. `&gt`)

---

size stuff

```
zig size: 15,488 + 5,857 = 21,345
ladybird size: 15,488 + (2,231 * 4) = 24,412

---

trie 1

{
	u12 for value index
	u1 for has_value
	u1 for has_children
	u14 for child index
}
4 * 9854 = 39,416
{
	u7 for char
	u1 for end of list
}
1 * 9853 = 9653
{
	u17 for first
	u4 for second
}
packed: (2231 * 21) / 8 + 1 = 5857
unpacked: 2231 * 4 = 8924

totals:
  packed: 39416 + 9653 + 5857 = 54,926
unpacked: 39416 + 9653 + 8924 = 57,993

---

trie 2

{
	u1 for has_children
	u1 for has_value
	u14 for child_index
}
2 * 9854 = 19,708
{
	u7 for char
	u1 for end of list
}
1 * 9853 = 9653
{
	u17 for first
	u4 for second
}
packed: (9854 * 21 + 1) / 8 = 25866
unpacked: 9854 * 4 = 39416

totals:
  packed: 19708 + 9653 + 25866 = 55,227
unpacked: 19708 + 9653 + 39416 = 68,777

---

blink
staticEntityStringStorage: 14,485 bytes
staticEntityTable: 2231 * 12 = 26,772 bytes
total: 41,257

diff to zig: 41,257 - 21,345 = 19,912
diff to ladybird: 16,845

---

https://chromium.googlesource.com/chromium/blink.git/+/refs/heads/main/Source/core/html/parser/create-html-entity-table
https://chromium.googlesource.com/chromium/blink.git/+/refs/heads/main/Source/wtf/text/WTFString.h
https://chromium.googlesource.com/chromium/blink.git/+/refs/heads/main/Source/core/html/parser/HTMLTokenizer.cpp
https://chromium.googlesource.com/chromium/blink.git/+/refs/heads/main/Source/core/html/parser/HTMLEntityTable.h

---

gecko
HILO_ACCEL[123] = 123 * 8 = 984
HILO_ACCEL_n[52]x44 = 44 * 52 * 4 = 9152
ALL_NAMES[12183]u8 = 12183
NAMES[2231] = 2231 * 4 = 8924
VALUES[2231] = 2231 * 4 = 8924
gecko total: 40,167

diff to zig: 40,167 - 21,345 = 18,822
diff to ladybird: 15,755

---

https://github.com/mozilla/gecko-dev/tree/master/parser/html
https://github.com/mozilla/gecko-dev/blob/master/parser/html/nsHtml5NamedCharactersInclude.h
https://github.com/mozilla/gecko-dev/blob/master/parser/html/nsHtml5NamedCharactersAccel.h
https://github.com/mozilla/gecko-dev/blob/master/parser/html/nsHtml5NamedCharactersAccel.cpp
https://github.com/mozilla/gecko-dev/blob/master/parser/html/nsHtml5NamedCharacters.h
https://github.com/mozilla/gecko-dev/blob/master/parser/html/nsHtml5NamedCharacters.cpp

---
```

<div>

<style scoped>
.insertion-point {
	outline: 2px dotted black; padding: 1px; margin: 4px;
}
@media (prefers-color-scheme: dark) {
	.insertion-point {
		outline-color: #AFADA5;
	}
}

.mermaid-flowchart{font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:16px;fill:#ccc;}@keyframes edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}.mermaid-flowchart .edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear infinite;stroke-linecap:round;}.mermaid-flowchart .edge-animation-fast{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}.mermaid-flowchart .error-icon{fill:#a44141;}.mermaid-flowchart .error-text{fill:#ddd;stroke:#ddd;}.mermaid-flowchart .edge-thickness-normal{stroke-width:1px;}.mermaid-flowchart .edge-thickness-thick{stroke-width:3.5px;}.mermaid-flowchart .edge-pattern-solid{stroke-dasharray:0;}.mermaid-flowchart .edge-thickness-invisible{stroke-width:0;fill:none;}.mermaid-flowchart .edge-pattern-dashed{stroke-dasharray:3;}.mermaid-flowchart .edge-pattern-dotted{stroke-dasharray:2;}.mermaid-flowchart svg{font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:16px;}.mermaid-flowchart p{margin:0;}.mermaid-flowchart .label{font-family:"trebuchet ms",verdana,arial,sans-serif;color:#ccc;}.mermaid-flowchart .cluster-label text{fill:#F9FFFE;}.mermaid-flowchart .cluster-label span{color:#F9FFFE;}.mermaid-flowchart .cluster-label span p{background-color:transparent;}.mermaid-flowchart .rough-node .label text,.mermaid-flowchart .node .label text,.mermaid-flowchart .image-shape .label,.mermaid-flowchart .icon-shape .label{text-anchor:middle;}.mermaid-flowchart .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}.mermaid-flowchart .rough-node .label,.mermaid-flowchart .node .label,.mermaid-flowchart .image-shape .label,.mermaid-flowchart .icon-shape .label{text-align:center;}.mermaid-flowchart .node.clickable{cursor:pointer;}.mermaid-flowchart .edgeLabel{background-color:hsl(0, 0%, 34.4117647059%);text-align:center;border-radius: 100%;}.mermaid-flowchart .edgeLabel p{background-color:hsl(0, 0%, 84.4117647059%);border-radius:100%;}.mermaid-flowchart .edgeLabel rect{opacity:0.5;background-color:hsl(0, 0%, 84.4117647059%);fill:hsl(0, 0%, 84.4117647059%);}.mermaid-flowchart .labelBkg{background-color:rgba(87.75, 87.75, 87.75, 0.5); border-radius:100%;}.mermaid-flowchart .cluster rect{fill:hsl(180, 1.5873015873%, 28.3529411765%);stroke:rgba(255, 255, 255, 0.25);stroke-width:1px;}.mermaid-flowchart .cluster text{fill:#F9FFFE;}.mermaid-flowchart .cluster span{color:#F9FFFE;}.mermaid-flowchart div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:12px;background:hsl(20, 1.5873015873%, 12.3529411765%);border:1px solid rgba(255, 255, 255, 0.25);border-radius:2px;pointer-events:none;z-index:100;}.mermaid-flowchart .flowchartTitleText{text-anchor:middle;font-size:18px;fill:#ccc;}.mermaid-flowchart rect.text{fill:none;stroke-width:0;}.mermaid-flowchart .icon-shape,.mermaid-flowchart .image-shape{background-color:hsl(0, 0%, 34.4117647059%);text-align:center;}.mermaid-flowchart .icon-shape p,.mermaid-flowchart .image-shape p{background-color:hsl(0, 0%, 34.4117647059%);padding:2px;}.mermaid-flowchart .icon-shape rect,.mermaid-flowchart .image-shape rect{opacity:0.5;background-color:hsl(0, 0%, 34.4117647059%);fill:hsl(0, 0%, 34.4117647059%);}.mermaid-flowchart :root{--mermaid-font-family:"trebuchet ms",verdana,arial,sans-serif;}

.mermaid-flowchart .marker{fill:#333;stroke:#333;}
.mermaid-flowchart .marker.cross{stroke:#333;}
.mermaid-flowchart .root .anchor path{fill:#333!important;stroke-width:0;stroke:#333;}
.mermaid-flowchart .arrowheadPath{fill:#333;}
.mermaid-flowchart .edgePath .path{stroke:#333;stroke-width:2.0px;}
.mermaid-flowchart .flowchart-link{stroke:#333;fill:none;}
.mermaid-flowchart .label text,.mermaid-flowchart span{fill:#333;color:#333;}
.mermaid-flowchart .node rect,.mermaid-flowchart .node circle,.mermaid-flowchart .node ellipse,.mermaid-flowchart .node polygon,.mermaid-flowchart .node path{fill:#DAE5E5;stroke:#333;stroke-width:1px;}
@media (prefers-color-scheme: dark) {
	.mermaid-flowchart .marker{fill:lightgrey;stroke:lightgrey;}
	.mermaid-flowchart .marker.cross{stroke:lightgrey;}
	.mermaid-flowchart .root .anchor path{fill:lightgrey!important;stroke-width:0;stroke:lightgrey;}
	.mermaid-flowchart .arrowheadPath{fill:lightgrey;}
	.mermaid-flowchart .edgePath .path{stroke:lightgrey;stroke-width:2.0px;}
	.mermaid-flowchart .flowchart-link{stroke:lightgrey;fill:none;}
	.mermaid-flowchart .label text,.mermaid-flowchart span{fill:#ccc;color:#ccc;}
	.mermaid-flowchart .node rect,.mermaid-flowchart .node circle,.mermaid-flowchart .node ellipse,.mermaid-flowchart .node polygon,.mermaid-flowchart .node path{fill:#1f2020;stroke:#ccc;stroke-width:1px;}
	.mermaid-flowchart .edgeLabel{background-color:hsl(0, 0%, 34.4117647059%);}.mermaid-flowchart .edgeLabel p{background-color:hsl(0, 0%, 34.4117647059%);}.mermaid-flowchart .edgeLabel rect{background-color:hsl(0, 0%, 34.4117647059%);fill:hsl(0, 0%, 34.4117647059%);}.mermaid-flowchart .labelBkg{background-color:rgba(87.75, 87.75, 87.75, 0.5);}
}

.mermaid-flowchart .node.transformed-value rect,
.mermaid-flowchart .node.transformed-value circle,
.mermaid-flowchart .node.transformed-value ellipse,
.mermaid-flowchart .node.transformed-value polygon,
.mermaid-flowchart .node.transformed-value path
{
  fill:#D4BFFF;stroke:#3B1B81;
}
@media (prefers-color-scheme: dark) {
	.mermaid-flowchart .node.transformed-value rect,
	.mermaid-flowchart .node.transformed-value circle,
	.mermaid-flowchart .node.transformed-value ellipse,
	.mermaid-flowchart .node.transformed-value polygon,
	.mermaid-flowchart .node.transformed-value path
	{
	  fill:#2F1743;stroke:#9570C5;
	}
}

.mermaid-flowchart .node.unknown-value rect,
.mermaid-flowchart .node.unknown-value circle,
.mermaid-flowchart .node.unknown-value ellipse,
.mermaid-flowchart .node.unknown-value polygon,
.mermaid-flowchart .node.unknown-value path
{
  stroke-dasharray: 5 5;
}
@media (prefers-color-scheme: dark) {
	.mermaid-flowchart .node.unknown-value rect,
	.mermaid-flowchart .node.unknown-value circle,
	.mermaid-flowchart .node.unknown-value ellipse,
	.mermaid-flowchart .node.unknown-value polygon,
	.mermaid-flowchart .node.unknown-value path
	{
	  fill:#2F1743;stroke:#9570C5;
	}
}

.mermaid-flowchart .unknown-value {
  animation: blinker 1s ease infinite;
}

@keyframes blinker {
  50% {
    opacity: 0.5;
  }
}

.mermaid-flowchart .node.selected-path rect,
.mermaid-flowchart .node.selected-path circle,
.mermaid-flowchart .node.selected-path ellipse,
.mermaid-flowchart .node.selected-path polygon,
.mermaid-flowchart .node.selected-path path
{
  fill:#FFE0BF;stroke:#814B1B;
}
@media (prefers-color-scheme: dark) {
	.mermaid-flowchart .node.selected-path rect,
	.mermaid-flowchart .node.selected-path circle,
	.mermaid-flowchart .node.selected-path ellipse,
	.mermaid-flowchart .node.selected-path polygon,
	.mermaid-flowchart .node.selected-path path
	{
	  fill:#433617;stroke:#C5A070;
	}
}

.mermaid-flowchart .node.iterated-node rect,
.mermaid-flowchart .node.iterated-node circle,
.mermaid-flowchart .node.iterated-node ellipse,
.mermaid-flowchart .node.iterated-node polygon,
.mermaid-flowchart .node.iterated-node path
{
  fill:#A4EBE0;stroke:#004B1B;
}
@media (prefers-color-scheme: dark) {
	.mermaid-flowchart .node.iterated-node rect,
	.mermaid-flowchart .node.iterated-node circle,
	.mermaid-flowchart .node.iterated-node ellipse,
	.mermaid-flowchart .node.iterated-node polygon,
	.mermaid-flowchart .node.iterated-node path
	{
	  fill:#153F3B;stroke:#00A070;
	}
}

.mermaid-flowchart .node.iterated-node.selected-path rect,
.mermaid-flowchart .node.iterated-node.selected-path circle,
.mermaid-flowchart .node.iterated-node.selected-path ellipse,
.mermaid-flowchart .node.iterated-node.selected-path polygon,
.mermaid-flowchart .node.iterated-node.selected-path path
{
  fill:#CDE290;
}
@media (prefers-color-scheme: dark) {
	.mermaid-flowchart .node.iterated-node.selected-path rect,
	.mermaid-flowchart .node.iterated-node.selected-path circle,
	.mermaid-flowchart .node.iterated-node.selected-path ellipse,
	.mermaid-flowchart .node.iterated-node.selected-path polygon,
	.mermaid-flowchart .node.iterated-node.selected-path path
	{
	  fill:#2A3F15;
	}
}

.mermaid-flowchart .node.end-of-word rect,
.mermaid-flowchart .node.end-of-word circle,
.mermaid-flowchart .node.end-of-word ellipse,
.mermaid-flowchart .node.end-of-word polygon,
.mermaid-flowchart .node.end-of-word path
{
  stroke:#811B1B; stroke-width: 2px;
}
@media (prefers-color-scheme: dark) {
	.mermaid-flowchart .node.end-of-word rect,
	.mermaid-flowchart .node.end-of-word circle,
	.mermaid-flowchart .node.end-of-word ellipse,
	.mermaid-flowchart .node.end-of-word polygon,
	.mermaid-flowchart .node.end-of-word path
	{
	  stroke:#C57070;
	}
}

.unique-index-result {
	background: #eee; width: 80px; position: absolute; left: calc(50% + 35px); bottom: calc(50% + 25px); padding: 5px;
}
@media (prefers-color-scheme: dark) {
	.unique-index-result {
		background: #111;
	}
}

.two-column-collapse {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
}

@media (max-width: 500px) {
  .two-column-collapse {
    grid-template-columns: 1fr !important;
  }
}

.dafsa-mph-header {
	background: #eee;
	margin: 0.25em;
	padding: 0.5em;
}
@media (prefers-color-scheme: dark) {
	.dafsa-mph-header {
		background: #111;
	}
}

.has-bg {
	background: #eee;
}
@media (prefers-color-scheme: dark) {
	.has-bg {
		background: #111;
	}
}

.box-border {
  border: 1px solid #eee;
}
@media (prefers-color-scheme: dark) {
.box-border {
  border-color: #111;
}
</style>

</div>