<p><aside class="note">

Note: I am not a 'browser engine' person, nor a 'data structures' person. I'm certain that an even better implementation than what I came up with is very possible.

</aside></p>

A while back, for <span style="border-bottom: 1px dotted; cursor: default;" title="the actual reason will be detailed later">no real reason</span>, I tried writing an implementation of a data structure tailored to the specific use case of [the *Named character reference state*](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) of HTML tokenization (here's the [link to that experiment](https://github.com/squeek502/named-character-references)). Recently, I took that implementation, ported it to C++, and [used it to make some efficiency gains and fix some spec compliance issues](https://github.com/LadybirdBrowser/ladybird/pull/3011) in the [Ladybird browser](https://ladybird.org/).

Throughout this, I never actually looked at the implementations used in any of the major browser engines (no reason for this, just me being dumb). However, now that I *have* looked at Blink/WebKit/Gecko (Chrome/Safari/Firefox, respectively), I've realized that my implementation seems to be either on-par or better across the metrics that the browser engines care about:

- Efficiency (at least as fast, if not slightly faster)
- Compactness of the data (uses ~60% of the data size of Chrome's/Firefox's implementation)
- Ease of use

<p><aside class="note">

Note: I'm singling out these metrics because, in [the python script](https://github.com/chromium/chromium/blob/8469b0ca44e36be251999cc819ff96dc3ac43290/third_party/blink/renderer/build/scripts/make_html_entity_table.py#L29-L32) that generates the data structures used for named character reference tokenization in Blink (the browser engine of Chrome/Chromium), it contains this docstring (emphasis mine):

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

Note: I'm not sure if it's feasible to implement an HTML parser that tries to resolve `<script>` tags upfront and then only fully tokenizes the resulting (immutable) input after that. If it is feasible, it might not be worth it since (unless I'm thinking about it wrong) it would probably involve multiple passes, since it's possible for a `<script>` tag to `document.write` a `<script>` tag, and for that `<script>` tag to write another, etc.

Here's a tiny glimpse of that possible nightmare:

```html
<script>
for (let char of "<script>document.write('&not');<\/script>") {
  document.write(char);
}
</script>in;
```

(this is expected to be parsed into <code>&notin;</code>, the same as the other examples above)

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
  <aside class="note" style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; margin-bottom: 1.5rem;"><div>Note the lack of a semicolon at the end of <code>&amp;not</code>. This is a real variant, and it was chosen over <code>&amp;not;</code> to simplify the example</div></aside>
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

You'll notice that the mapped code point (&notinvc;) is present on the diagram above as well. This is because it is trivial to use a trie as a map to look up an associated value, since each word in the set *must* end at a distinct node in the trie (e.g. no two words can share an end-of-word node). Conveniently, using the trie as a map is exactly what we want to be able to do for named character references, since ultimately we need to convert the longest matched named character reference into the relevant code point(s).

## A brief detour: Representing a trie in memory

<p><aside class="note">

Note: The code examples in this section will be using [Zig](https://www.ziglang.org/) syntax. 

</aside></p>

One way to represent a trie node is to use an array of optional pointers for its children (where each index into the array represents a child node with that byte value as its character), like so:

```zig
const Node = struct {
  // This example supports all `u8` byte values.
  children: [256]?*Node,
  end_of_word: bool,
};
```

Earlier, I said that trie visualizations typically put the letters on the connections between nodes rather than the nodes themselves, and, with *this* way of representing the trie, I think that makes a lot of sense, since the *connections* are the information being stored on each node.

<p><aside class="note">

Note: For the examples in this section, we'll use a trie that only contains the words `GG`, `GL`, and `HF`.

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

One way to mitigate the wasted space would be to switch from an array of children to a linked list of children, where the parent stores an optional pointer to its first child, and each child stores an optional pointer to its next sibling:

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
    // It's safe to represent this with the minimum number of bits,
    // e.g. there's 6 nodes in our example so it can be represented in 3 bits.
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

<p><aside class="note">

The code I'm using for the benchmarks below is available [here](https://gist.github.com/squeek502/e1627d2e7e2ac115ce7d9f6d5cc01df0).

</aside></p>

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

That is, the 'flattened' version is <sup>1</sup>/<sub>514</sub> the size of the 'connections' version, and <sup>1</sup>/<sub>6</sub> the size of the 'linked list' version.

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

When using the 'flattened' representation for this particular task, we're trading off a ~20% difference in lookup speed for 2-3 orders of magnitude difference in data size. This seems pretty okay, especially for what we're ultimately interested in implementing: a fully static and unchanging data structure, so there's no need to worry about how easy it is to modify after construction.

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

During the talk, I thought back to when [I contributed to an HTML parser implementation](https://github.com/watzon/zhtml/pulls?q=is%3Apr+is%3Aclosed+author%3Asqueek502) and had to leave proper *named character reference tokenization* as a `TODO` because I wasn't sure how to approach it. I can't remember if a [*deterministic acyclic finite state automaton*](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton) (DAFSA) was directly mentioned in the talk, or if I heard about it from talking with Niles afterwards, or if I learned of it while looking into trie variations later on (since the talk was about a novel trie variation), but, in any case, after learning about the DAFSA, it sounded like a pretty good tool for the job of named character references, so I <span style="border-bottom: 1px dotted; cursor: default;" title="this is the reason for all of this that was glossed over in the intro">revisited named character reference tokenization with that tool in hand</span>.

<p><aside class="note">

In other words, the talk (at least partially) served its purpose for me in particular. I didn't come up with anything novel, but it got me to look into data structures more and I have Niles to thank for that.

</aside></p>

### What is a DAFSA?

<p><aside class="note">

Note: There are a few names for a [DAFSA](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton): [DAWG](https://web.archive.org/web/20220722224703/http://pages.pathcom.com/~vadco/dawg.html), [MA-FSA](https://pkg.go.dev/github.com/smartystreets/mafsa), etc.

</aside></p>

A DAFSA is essentially the 'flattened' representation of a trie, but, more importantly, certain types of redundant nodes are eliminated during its construction (the particulars of this aren't too relevant here so I'll skip them; see [here](https://stevehanov.ca/blog/?id=115) if you're interested).

Going back to the same subset of named character references as the example in the ["*Trie implementation*"](#trie-implementation) section above, a DAFSA would represent that set of words like so:

<div style="text-align: center;">
<svg id="mermaid-dafsa" width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 145.48333740234375px;" viewBox="0 0 145.48333740234375 438" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker id="mermaid-123_flowchart-v2-pointEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-pointStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="4.5" refY="5" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 5 L 10 10 L 10 0 z" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-circleEnd" class="marker flowchart-v2" viewBox="0 0 10 10" refX="11" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-circleStart" class="marker flowchart-v2" viewBox="0 0 10 10" refX="-1" refY="5" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><circle cx="5" cy="5" r="5" class="arrowMarkerPath" style="stroke-width: 1px; stroke-dasharray: 1px, 0px;"></circle></marker><marker id="mermaid-123_flowchart-v2-crossEnd" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="12" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><marker id="mermaid-123_flowchart-v2-crossStart" class="marker cross flowchart-v2" viewBox="0 0 11 11" refX="-1" refY="5.2" markerUnits="userSpaceOnUse" markerWidth="11" markerHeight="11" orient="auto"><path d="M 1,1 l 9,9 M 10,1 l -9,9" class="arrowMarkerPath" style="stroke-width: 2px; stroke-dasharray: 1px, 0px;"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path d="M73.483,38.5L73.4,39.25C73.317,40,73.15,41.5,73.067,43.083C72.983,44.667,72.983,46.333,72.983,47.167L72.983,48" id="L_root_n_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,87L72.983,87.833C72.983,88.667,72.983,90.333,72.983,92C72.983,93.667,72.983,95.333,72.983,96.167L72.983,97" id="L_n_letter_o_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,136L72.983,136.833C72.983,137.667,72.983,139.333,72.983,141C72.983,142.667,72.983,144.333,72.983,145.167L72.983,146" id="L_letter_o_t_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M88.533,181.918L89.809,183.265C91.085,184.612,93.636,187.306,94.912,189.486C96.187,191.667,96.187,193.333,96.187,194.167L96.187,195" id="L_t_i1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M57.433,181.918L56.158,183.265C54.882,184.612,52.331,187.306,51.055,189.486C49.779,191.667,49.779,193.333,49.779,194.167L49.779,195" id="L_t_n1_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,234L96.187,234.833C96.187,235.667,96.187,237.333,96.187,239C96.187,240.667,96.187,242.333,96.187,243.167L96.187,244" id="L_i1_n2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,234L49.779,234.833C49.779,235.667,49.779,237.333,49.779,239C49.779,240.667,49.779,242.333,49.779,243.167L49.779,244" id="L_n1_i2_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M49.779,283L49.779,283.833C49.779,284.667,49.779,286.333,50.931,288.383C52.083,290.433,54.387,292.866,55.54,294.082L56.692,295.299" id="L_i2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M96.187,283L96.187,283.833C96.187,284.667,96.187,286.333,95.035,288.383C93.883,290.433,91.579,292.866,90.427,294.082L89.275,295.299" id="L_n2_v_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M56.692,320.745L51.339,323.454C45.986,326.164,35.281,331.582,29.928,335.124C24.575,338.667,24.575,340.333,24.575,341.167L24.575,342" id="L_v_a_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,332L72.983,332.833C72.983,333.667,72.983,335.333,72.983,337C72.983,338.667,72.983,340.333,72.983,341.167L72.983,342" id="L_v_b_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M89.275,320.787L94.587,323.489C99.9,326.191,110.525,331.596,115.838,335.131C121.15,338.667,121.15,340.333,121.15,341.167L121.15,342" id="L_v_c_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M24.575,381L24.575,381.833C24.575,382.667,24.575,384.333,30.09,387.958C35.606,391.583,46.636,397.165,52.151,399.957L57.667,402.748" id="L_a_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M72.983,381L72.983,381.833C72.983,382.667,72.983,384.333,72.983,386C72.983,387.667,72.983,389.333,72.983,390.167L72.983,391" id="L_b_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path><path d="M121.15,381L121.15,381.833C121.15,382.667,121.15,384.333,115.675,387.952C110.2,391.57,99.25,397.139,93.775,399.924L88.3,402.709" id="L_c_semi_0" class=" edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" style=""></path></g><g class="edgeLabels"><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g><g class="edgeLabel"><g class="label" transform="translate(0, 0)"><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml" class="labelBkg"><span class="edgeLabel "></span></div></foreignObject></g></g></g><g class="nodes"><g class="node default  " id="flowchart-root-0" transform="translate(72.98332977294922, 23)"><polygon points="15,0 30,-15 15,-30 0,-15" class="label-container" transform="translate(-15,15)"></polygon><g class="label" style="" transform="translate(0, 0)"><rect></rect><foreignObject width="0" height="0"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n-1" transform="translate(72.98332977294922, 67.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-letter_o-3" transform="translate(72.98332977294922, 116.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.666664123535156" y="-19.5" width="33.33332824707031" height="39"></rect><g class="label" style="" transform="translate(-4.291664123535156, -12)"><rect></rect><foreignObject width="8.583328247070312" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>o</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-t-5" transform="translate(72.98332977294922, 165.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.550003051757812" y="-19.5" width="31.100006103515625" height="39"></rect><g class="label" style="" transform="translate(-3.1750030517578125, -12)"><rect></rect><foreignObject width="6.350006103515625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>t</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i1-7" transform="translate(49.7791633605957, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n1-8" transform="translate(96.18749618530273, 214.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-n2-10" transform="translate(49.7791633605957, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.75" y="-19.5" width="33.5" height="39"></rect><g class="label" style="" transform="translate(-4.375, -12)"><rect></rect><foreignObject width="8.75" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>n</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-i2-12" transform="translate(96.18749618530273, 263.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-14.658332824707031" y="-19.5" width="29.316665649414062" height="39"></rect><g class="label" style="" transform="translate(-2.2833328247070312, -12)"><rect></rect><foreignObject width="4.5666656494140625" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>i</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-v-14" transform="translate(72.98332977294922, 312.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.291664123535156" y="-19.5" width="32.58332824707031" height="39"></rect><g class="label" style="" transform="translate(-3.9166641235351562, -12)"><rect></rect><foreignObject width="7.8333282470703125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>v</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-a-18" transform="translate(24.574996948242188, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.574996948242188" y="-19.5" width="33.149993896484375" height="39"></rect><g class="label" style="" transform="translate(-4.1999969482421875, -12)"><rect></rect><foreignObject width="8.399993896484375" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>a</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-b-19" transform="translate(72.98332977294922, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.833335876464844" y="-19.5" width="33.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-4.458335876464844, -12)"><rect></rect><foreignObject width="8.916671752929688" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>b</p></span></div></foreignObject></g></g><g class="node default  " id="flowchart-c-20" transform="translate(121.1500015258789, 361.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-16.333335876464844" y="-19.5" width="32.66667175292969" height="39"></rect><g class="label" style="" transform="translate(-3.9583358764648438, -12)"><rect></rect><foreignObject width="7.9166717529296875" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>c</p></span></div></foreignObject></g></g><g class="node default end-of-word" id="flowchart-semi-22" transform="translate(72.98332977294922, 410.5)"><rect class="basic label-container" style="" rx="19.5" ry="19.5" x="-15.316665649414062" y="-19.5" width="30.633331298828125" height="39"></rect><g class="label" style="" transform="translate(-2.9416656494140625, -12)"><rect></rect><foreignObject width="5.883331298828125" height="24"><div style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;" xmlns="http://www.w3.org/1999/xhtml"><span class="nodeLabel "><p>;</p></span></div></foreignObject></g></g></g></g></g></svg>
</div>

As you can see, the `v`, `a`, `b`, `c` and `;` nodes are now shared between all the words that use them. This takes the number of nodes down to 13 in this example (compared to 22 for the trie).

The downside of this node consolidation is that we lose the ability to associate a given end-of-word node with a particular value. In this DAFSA example, *all words* except `not` end on the exact same node, so how can we know where to look for the associated value(s) for those words?

Here's an illustration of the problem when matching the word `&notinvc;`:

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

Ok, so now that we have two different data structures that seem pretty well suited for named character reference matching&mdash;a trie and a DAFSA&mdash;how do they compare? It's now (finally) time to start using the [full set of named character references and all of their mapped code point(s)](https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references) to see how they stack up.

Some numbers to keep in mind upfront:
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
    <div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem;" class="has-bg">byte index</div>
    <div style="height: 2rem; line-height: 2rem; margin-top: 1px;"></div>
    <div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem; margin-top: 1px;" class="has-bg">element index</div>
  </div>
  <div class="array-bits regular-array has-bg">
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
    .array-bits .element .first, .first-element-key {
      background: repeating-linear-gradient(
        -45deg,
        #C08EE7,
        #C08EE7 10px,
        #D7C7EF 10px,
        #D7C7EF 20px
      );
    }
    .array-bits .element .second, .second-element-key {
      background: repeating-linear-gradient(
        -45deg,
        #7DAFE7,
        #7DAFE7 10px,
        #B9D5F7 10px,
        #B9D5F7 20px
      );
    }
    .array-bits .element .padding, .padding-element-key {
      background: repeating-linear-gradient(
        -45deg,
        #BBB,
        #BBB 10px,
        #DDD 10px,
        #DDD 20px
      );
    }
@media (prefers-color-scheme: dark) {
    .array-bits .element .first, .first-element-key {
      background: repeating-linear-gradient(
        -45deg,
        #613583,
        #613583 10px,
        #251134 10px,
        #251134 20px
      );
    }
    .array-bits .element .second, .second-element-key {
      background: repeating-linear-gradient(
        -45deg,
        #142A43,
        #142A43 10px,
        #1A5FB4 10px,
        #1A5FB4 20px
      );
    }
    .array-bits .element .padding, .padding-element-key {
      background: repeating-linear-gradient(
        -45deg,
        #222,
        #222 10px,
        #333 10px,
        #333 20px
      );
    }
}
    </style>
  </div>
</div>

However, while using 21 bits to represent the mapped code point(s) does not automatically lead to any saved bytes over a 32 bit integer, it opens up the possibility to tightly pack an array of 21-bit elements in order to *actually* save some bytes. Yet, doing so means that storing/loading elements from the tightly packed array becomes trickier (both computationally and implementation-wise). Here's the same diagram as before, but with the elements tightly packed (no padding bits between elements):

<div style="display: grid; grid-template-columns: max-content 1fr;">
  <div>
    <div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem;" class="has-bg">byte index</div>
    <div style="height: 2rem; line-height: 2rem; margin-top: 1px;"></div>
    <div style="height: 2rem; line-height: 2rem; text-align: right; padding: 1px 0.75rem 1px 0.75rem; margin-top: 1px;" class="has-bg">element index</div>
  </div>
  <div class="array-bits bitpacked-array has-bg">
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
  </style>
  </div>
</div>

You'll notice that no elements past the first start or end on byte boundaries, meaning in order to load an element, a fair bit of bitwise operations are required (bit shifting, etc). This makes array accesses more expensive, but that isn't necessarily a big deal for our use case, since we only ever access the array of values once per named character reference, and only after we're certain we have a match. So, tightly bitpacking the value array is a viable way to save some extra bytes for our purposes.

<p><aside class="note">

Note: This is just context for the next section where I'll mention data sizes for versions that use the "regular array" representation or the "tightly bitpacked array" representation for the values.

</aside></p>

### Data size

For the DAFSA, the size calculation is pretty straightforward:

- The data of each node can fit into 4 bytes with a few bits to spare (expand below if you're interested in the details), and there are 3,872 nodes in the DAFSA, so that's 15,488 bytes total

<details class="box-border" style="padding: 1em; padding-bottom: 0;" id="nitty-gritty-dafsa-node-size-details">
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

Beyond that, the details aren't *super* relevant. Suffice it to say that each node will either take up 5 bytes or 3 bytes depending on which of the two 'value array' strategies you choose (note: I actually mean 5 bytes and 3 bytes, as they can be represented as one array of 2- or 4-byte values and one array of 1-byte values so padding between elements doesn't factor in).

The summary is that, depending on the particular representation, the trie will use between 57,993 bytes and 68,777 bytes (<span class="token_semigood">56.63 KiB</span> to <span class="token_error">67.16 KiB</span>) total, or, if the values array is tightly bitpacked, between 54,926 bytes and 55,227 bytes (<span class="token_semigood">53.64 KiB</span> to <span class="token_semigood">53.93 KiB</span>) total.

Ultimately, the data size of the trie is going to be at least **2x larger** than the equivalent DAFSA.

### Performance

Luckily, there's [an existing HTML parser implementation written in Zig called `rem`](https://github.com/chadwain/rem) that uses a trie for its named character reference tokenization, so getting [some relevant benchmark results from actual HTML parsing](https://github.com/chadwain/rem/pull/15) for a trie vs DAFSA comparison was pretty easy.

<p><aside class="note">

Note: The trie in `rem` uses the 'flattened' representation of a trie, with a value array that re-uses the index of the end-of-word node (so there are a lot of empty slots in the value array).

</aside></p>

From [my benchmarking](https://gist.github.com/squeek502/07b7dee1086f6e9dc38c4a880addfeca), it turns out that the DAFSA implementation uses more instructions than the trie implementation because it needs to do extra work to build up the unique index during iteration, but the DAFSA saves on cache misses (presumably due to the smaller overall size of the DAFSA and its node re-use) and everything just about evens out in terms of wall clock time:

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

<div style="float:right; margin-top: -2rem; margin-left: 1rem;"><img style="max-width: 96px;" src="/images/better-named-character-reference-tokenization/ladybird.png" /></div>

First, let's take a look at what the Ladybird implementation looked like before my changes: [state implementation](https://github.com/squeek502/ladybird/blob/c49dd2036bad3248a31b319df762d84f9235b7f2/Libraries/LibWeb/HTML/Parser/HTMLTokenizer.cpp#L1699-L1733), [matching implementation](https://github.com/squeek502/ladybird/blob/c49dd2036bad3248a31b319df762d84f9235b7f2/Libraries/LibWeb/HTML/Parser/Entities.cpp). Here's a rough summary of the approach, in pseudo-code:

```zig
var match = null;

// Lookahead at the rest of the input
var remaining_input = input.substring(current_offset, input.length - current_offset);

// Check against each named character reference one-by-one
for (var entity : entities) {
    if (remaining_input.starts_with(entity)) {
        if (match == null or entity.length > match.length) {
            match = entity;
        }
    }
}

// If there is a match
if (match != null) {
    // Consume up to the end of the match that was found
    consume_and_advance(match.length - 1);

    // ...
}
```

This has two major problems:

1. It is inefficient, since the input string is being compared against the entire list of named character references one-at-a-time
2. It does not handle `document.write` correctly, as previously discussed in [*The spectre of `document.write`*](#the-spectre-of-document-write). It's doing lookahead, but it does not account for insertion points, as it makes the mistake of looking *past* insertion points. So, if `document.write` is used to write one-character-at-a-time, it will attempt to resolve the named character reference before all the characters are available (e.g. in the case of <code class="language-html" style="min-width: 5em;"><span class="token_string insertion-point" id="not-insertion-point-2"></span><span class="token_identifer">in;</span></code>, it will erroneously try matching against `&in;` and then exit the named character reference state)

<script>
(function() {
  let i=0;
  let letters = '&not';
  let e = document.querySelector('#not-insertion-point-2');
  setInterval(function() {
    e.textContent = letters.substring(0,i);
    // + 3 to linger on the final result for a bit
    i = (i + 1) % (letters.length + 3);
  }, 500);
})();
</script>

[My pull request](https://github.com/LadybirdBrowser/ladybird/pull/3011) focused on fixing both of those problems. The data structure I used is exactly the DAFSA implementation as described so far, with a value array that is *not* bitpacked, because:

- As we've seen, it doesn't affect performance, so complicating the implementation didn't seem worth it
- Using an `enum` for the second code point would either mean using an extra bit (since enums are signed integers in C++) or using some workaround to keep it using the minimal number of bits

The last piece of the puzzle that I haven't mentioned yet is the [`NamedCharacterReferenceMatcher`](https://github.com/squeek502/ladybird/blob/ee5e3cb7d48abe2e46bb63e46a975df8520b9b6e/Libraries/LibWeb/HTML/Parser/Entities.h), which handles DAFSA traversal while providing an API well-tailored to the named character reference state, specifically. The details aren't too important, so here are the relevant bits of the exposed API:

```c
// If `c` is the code point of a child of the current `node_index`, the `node_index`
// is updated to that child and the function returns `true`.
// Otherwise, the `node_index` is unchanged and the function returns false.
bool try_consume_code_point(u32 c);

// Returns the number of code points consumed beyond the last full match.
u8 overconsumed_code_points();

// Returns the code points associated with the last match, if any.
Optional<NamedCharacterReferenceCodepoints> code_points();
```

So, with all that context, here's what the Ladybird implementation looks like after my changes (slightly simplified for clarity; [here's the full implementation](https://github.com/LadybirdBrowser/ladybird/blob/27ba216e3fd869e0a3bf1d78c3693e5c7993369c/Libraries/LibWeb/HTML/Parser/HTMLTokenizer.cpp#L1696-L1747)):

```c
BEGIN_STATE(NamedCharacterReference)
{
    if (matcher.try_consume_code_point(current_code_point)) {
        temporary_buffer.append(current_code_point);
        continue; // stay in the NamedCharacterReference state and go to the next code point
    } else {
        DONT_CONSUME_CHARACTER;
    }

    auto overconsumed_code_points = matcher.overconsumed_code_points();
    if (overconsumed_code_points > 0) {
        backtrack_to(current_offset - overconsumed_code_points);
        temporary_buffer.shrink_by(overconsumed_code_points);
    }

    auto mapped_code_points = matcher.code_points();
    // If there is a match
    if (mapped_code_points) {
        // ...
    } else {
        FLUSH_CODEPOINTS_CONSUMED_AS_A_CHARACTER_REFERENCE;
        SWITCH_TO(AmbiguousAmpersand);
    }
}
```

Note also that Ladybird follows ['spec-driven development'](https://youtu.be/9YM7pDMLvr4?t=1608), meaning that the goal is for its code to be implemented to match the text of the relevant specification as closely as possible. Here's what the [*named character reference state* specification](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) looks like for reference:

> **13.2.5.73 Named character reference state**
>
> Consume the maximum number of characters possible, where the consumed characters are one of the identifiers in the first column of the named character references table. Append each character to the temporary buffer when it's consumed.
>
> - If there is a match
>     + ...
> 
> - Otherwise
>     + Flush code points consumed as a character reference. Switch to the ambiguous ampersand state.

Overall, these changes made the Ladybird tokenizer:

- About <span class="token_semigood">1.23x faster</span> on [an arbitrary set of HTML files from real websites](https://github.com/AndreasMadsen/htmlparser-benchmark/tree/master/files) (albeit an old set of files)
- About <span class="token_addition">8x faster</span> on a *very* named-character-reference-specific benchmark (tokenizing an HTML file with nothing but tens of thousands of valid and invalid named character references)
- Roughly <span class="token_addition">95 KiB smaller</span> (very crude estimate, solely judged by the difference in the final binary size)
- Handle `document.write` emitting one-character-at-a-time correctly

But that's all pretty low-hanging fruit, as the previous Ladybird implementation had some obvious problems. In fact, we can actually improve on this some more (and will later on), but I think it's worth looking at the Firefox/Chrome/Safari implementations now to see how this DAFSA version stacks up against them.

## Comparison to the major browser engines

Before we get to the actual comparisons, there's (unfortunately) a lot that has to be discussed.

First, you'll notice from the Ladybird benchmarks above that an *8x improvement* in a very named-character-reference-specific benchmark only led to a *1.23x improvement* in the average case. This points to the fact that named character reference matching is not something that HTML tokenizers typically do very often, and that named character reference matching being *fast enough* is likely just fine, all things considered.

<p><aside class="note">

Note: I realize that this makes this whole endeavor rather pointless, but hopefully it's still interesting enough without the possibility of making a huge performance impact.

</aside></p>

Second, instead of going the route of putting my DAFSA implementation into the other browsers' engines to compare, I went with taking the other browsers' implementations and putting them into Ladybird. Not only that, though, I also made the Firefox/Chrome/Safari implementations conform to the API of `NamedCharacterReferenceMatcher` (for reasons that will be discussed soon). So, in order for my benchmarking to be accurate you'll have to trust that:

- I faithfully integrated the Firefox/Chrome/Safari implementations into Ladybird
- The performance characteristics exhibited would hold when going the other direction (putting my implementation into their tokenizer)
- The benchmarks I'm using can actually give useful/meaningful results in the first place

For the first point, the only real assurance I can give you is that the same number of [web platform tests](https://wpt.fyi/) within the `html/syntax/parsing` category were passing with each browser's implementation integrated. The second point will be discussed more later on. For the third point, we have to go on yet another detour...

### On the difficulty of benchmarking

My initial benchmarking setup was straightforward:

- Have a separate branch of the codebase for each implementation
- Compile separate benchmark binaries for each branch
- Run each version and compare the results

However, this approach ultimately left me with some inexplicable results. Here's an example of such results, where the benchmark that exclusively tests the relevant parts of the code shows the Blink (Chrome) implementation being slightly faster than mine:

```poopresults
Benchmark 1 (85 runs): ./TestHTMLTokenizerBlink --bench named_character_references
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           118ms ± 1.68ms     115ms …  121ms          0 ( 0%)        0%
Benchmark 2 (84 runs): ./TestHTMLTokenizerDafsa --bench named_character_references
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           120ms ± 1.50ms     117ms …  123ms          0 ( 0%)        💩+  2.1% ±  0.4%
```

Yet, when I ran a benchmark that only *occasionally* exercises the code that I changed (a benchmark using a sample of real HTML files), I got unexpected results. What we *should* expect is either a very slight difference in the same direction, or (more realistically) no discernible difference, as this effect size should not be noticeable in the average case. Instead, I got *the opposite result* and *a larger effect*:

```poopresults
Benchmark 1 (12 runs): ./TestHTMLTokenizerBlink --bench benchfiles
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.85s  ± 28.4ms    1.79s  … 1.88s           2 (17%)        0%
Benchmark 2 (12 runs): ./TestHTMLTokenizerDafsa --bench benchfiles
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.79s  ± 20.7ms    1.76s  … 1.84s           1 ( 8%)        ⚡-  3.2% ±  1.1%
```

Taken together, the only explanation for these sorts of results would be that *the parts of the code that I **didn't change** got faster* in one version, and not the other.

#### The elephant demands attention

Well, this explanation&mdash;that the code I didn't change got faster&mdash;is actually likely to be the correct one, and I've known about this possibility ever since I watched the excellent talk ["Performance Matters" by Emery Berger](https://www.youtube.com/watch?v=r-TLSBdHe1A). I recommend watching the talk, but the short explanation is that changes to one part of the codebase may inadvertently cause the compiler to reorganize unrelated parts of the compiled binary in ways that affect performance ('layout').

However, while I was aware of this possible confounder, up until now I have basically ignored it whenever doing benchmarking (and I'm assuming that's true for most programmers). This is the first time I've come face-to-face with the problem and *had* to reckon with its effects, and I think a large part of that is because I'm dealing with a *much* larger codebase than I typically would when benchmarking, so there's a lot of room for inadvertent layout changes to cascade and cause noticeable performance differences.

<p><aside class="note">

Note: Reducing the amount of code that's compiled in order to benchmark the tokenizer is not as easy as one might think, as the HTML tokenizer has a lot of interconnected dependencies (HTML parser, JavaScript library, countless other things), so when benchmarking the HTML tokenizer I'm pulling in all of Ladybird's `LibWeb` which is rather large.

</aside></p>

#### Elephant mitigation

Unfortunately, the solution presented in the talk ([Stabilizer](https://github.com/ccurtsinger/stabilizer), which allows you to constantly randomize a binary's layout during runtime to control for layout-based performance differences) has bitrotted and only works with an ancient version of LLVM. So, instead, I thought I'd try a different benchmarking setup to counteract the problem:

- Only compile one binary, and have it contain the code for all the different named character reference matching implementations
- Choose the named character reference matching implementation to use at *runtime*

This introduces some dynamic dispatch overhead into the mix which may muddy the results slightly, but, in theory, this should eliminate the effects of layout differences, as whatever the binary layout happens to be, all implementations will share it. In practice, this did indeed work, but introduced another unexplained anomaly that we'll deal with afterwards. After moving all the implementations into the same binary, I got these results for the 'average case' benchmark:

<p><aside class="note">

Note: Remember that we're expecting this benchmark to show no meaningful difference across the board, as it mostly tests code that hasn't been changed (i.e. named character reference matching has little effect on this benchmark, as mentioned earlier).

</aside></p>

```poopresults
Benchmark 1 (12 runs): ./BenchHTMLTokenizerFiles dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.78s  ± 29.8ms    1.75s  … 1.87s           1 ( 8%)        0%
  peak_rss           88.7MB ± 59.2KB    88.7MB … 88.8MB          0 ( 0%)        0%
  cpu_cycles         6.71G  ±  127M     6.62G  … 7.10G           1 ( 8%)        0%
  instructions       16.1G  ± 99.2K     16.1G  … 16.1G           0 ( 0%)        0%
  cache_references    324M  ± 2.87M      319M  …  331M           2 (17%)        0%
  cache_misses       10.2M  ± 66.4K     10.1M  … 10.3M           3 (25%)        0%
  branch_misses      8.69M  ± 2.99M     7.82M  … 18.2M           1 ( 8%)        0%
Benchmark 3 (12 runs): ./BenchHTMLTokenizerFiles blink
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.79s  ± 24.8ms    1.73s  … 1.82s           1 ( 8%)          +  1.0% ±  1.3%
  peak_rss           89.1MB ±  234KB    89.0MB … 89.8MB          1 ( 8%)          +  0.5% ±  0.2%
  cpu_cycles         6.70G  ± 57.7M     6.62G  … 6.79G           0 ( 0%)          -  0.2% ±  1.2%
  instructions       16.1G  ±  128K     16.1G  … 16.1G           1 ( 8%)          -  0.0% ±  0.0%
  cache_references    325M  ± 1.90M      321M  …  328M           0 ( 0%)          +  0.2% ±  0.6%
  cache_misses       10.3M  ± 54.3K     10.2M  … 10.4M           0 ( 0%)          +  0.8% ±  0.5%
  branch_misses      7.86M  ± 24.6K     7.79M  … 7.89M           3 (25%)          -  9.6% ± 20.6%
Benchmark 4 (12 runs): ./BenchHTMLTokenizerFiles gecko
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.72s  ± 9.79ms    1.70s  … 1.74s           0 ( 0%)        ⚡-  3.2% ±  1.1%
  peak_rss           88.8MB ± 83.8KB    88.7MB … 89.0MB          4 (33%)          +  0.1% ±  0.1%
  cpu_cycles         6.69G  ± 41.1M     6.63G  … 6.76G           0 ( 0%)          -  0.4% ±  1.2%
  instructions       16.1G  ± 72.3K     16.1G  … 16.1G           0 ( 0%)          -  0.1% ±  0.0%
  cache_references    323M  ± 1.53M      320M  …  325M           1 ( 8%)          -  0.2% ±  0.6%
  cache_misses       10.2M  ± 35.8K     10.1M  … 10.2M           0 ( 0%)          +  0.0% ±  0.4%
  branch_misses      7.79M  ± 49.1K     7.76M  … 7.95M           2 (17%)          - 10.4% ± 20.6%
```

The remaining Gecko (Firefox) `wall_time` difference is consistently reproducible, but not readily explainable using the other metrics measured, as there is no significant difference in CPU cycles, instructions, cache usage, etc. After attempting some profiling and trying to use `strace` to understand the difference, my guess is that this comes down to coincidental allocation patterns being friendlier when choosing the Gecko version.

<p><aside class="note">

Note: There is no heap allocation in any of the named character reference matching implementations, but the size of each `NamedCharacterReferenceMatcher` subclass is different (the Gecko version is 32 bytes while the others are either 16 or 48 bytes), and an instance of the chosen subclass *is* heap allocated at the start of the program.

</aside></p>

If we use `strace -e %memory -c`, the `dafsa` and `blink` versions consistently use more `brk`/`mmap`/`munmap` syscalls (especially `brk`):

```
Dafsa
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 47.18    0.012463         113       110           brk
 31.90    0.008427         443        19           munmap
 18.25    0.004822           9       508           mmap
  2.66    0.000703           5       134           mprotect
------ ----------- ----------- --------- --------- ----------------
100.00    0.026415          34       771           total

Blink
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 55.95    0.018094         138       131           brk
 28.81    0.009318         490        19           munmap
 12.93    0.004181           8       508           mmap
  2.32    0.000749           5       134           mprotect
------ ----------- ----------- --------- --------- ----------------
100.00    0.032342          40       792           total
```

The Gecko version, even though it uses roughly the same amount of memory overall, consistently has fewer of these syscalls:

```
Gecko
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 37.07    0.006560         385        17           munmap
 31.73    0.005615          75        74           brk
 26.50    0.004689           9       506           mmap
  4.70    0.000831           6       134           mprotect
------ ----------- ----------- --------- --------- ----------------
100.00    0.017695          24       731           total
```

I don't know enough about the `glibc`/`libstdc++` allocator implementation(s) to know why this would be the case, and the magnitude of the difference reported by `strace` doesn't seem large enough to explain the results, but I'm at least a little bit confident that this *is* the cause, since, after inserting padding to each `NamedCharacterReferenceMatcher` subclass to ensure they are all the same size, the `wall_time` difference went away:

```poopresults
Benchmark 1 (12 runs): ./BenchHTMLTokenizerFiles dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.81s  ± 29.8ms    1.73s  … 1.85s           1 ( 8%)        0%
  peak_rss           89.7MB ±  203KB    89.5MB … 90.3MB          1 ( 8%)        0%
  cpu_cycles         6.74G  ± 58.0M     6.68G  … 6.87G           0 ( 0%)        0%
  instructions       16.1G  ±  142K     16.1G  … 16.1G           1 ( 8%)        0%
  cache_references    322M  ± 2.45M      316M  …  325M           1 ( 8%)        0%
  cache_misses       10.2M  ± 25.1K     10.1M  … 10.2M           0 ( 0%)        0%
  branch_misses      7.84M  ± 26.1K     7.77M  … 7.87M           1 ( 8%)        0%
Benchmark 2 (12 runs): ./BenchHTMLTokenizerFiles blink
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.80s  ± 23.0ms    1.74s  … 1.83s           1 ( 8%)          -  0.1% ±  1.2%
  peak_rss           89.6MB ±  205KB    89.2MB … 90.1MB          2 (17%)          -  0.1% ±  0.2%
  cpu_cycles         6.74G  ± 37.0M     6.68G  … 6.82G           0 ( 0%)          -  0.0% ±  0.6%
  instructions       16.1G  ±  194K     16.1G  … 16.1G           0 ( 0%)          -  0.0% ±  0.0%
  cache_references    321M  ± 1.93M      317M  …  324M           0 ( 0%)          -  0.3% ±  0.6%
  cache_misses       10.3M  ± 47.5K     10.2M  … 10.3M           0 ( 0%)          +  0.7% ±  0.3%
  branch_misses      7.87M  ± 23.3K     7.82M  … 7.91M           1 ( 8%)          +  0.4% ±  0.3%
Benchmark 3 (12 runs): ./BenchHTMLTokenizerFiles gecko
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.80s  ± 29.0ms    1.71s  … 1.82s           1 ( 8%)          -  0.4% ±  1.4%
  peak_rss           89.7MB ±  265KB    89.5MB … 90.5MB          1 ( 8%)          +  0.1% ±  0.2%
  cpu_cycles         6.73G  ± 43.3M     6.65G  … 6.78G           0 ( 0%)          -  0.2% ±  0.6%
  instructions       16.1G  ±  156K     16.1G  … 16.1G           2 (17%)          -  0.1% ±  0.0%
  cache_references    321M  ± 3.29M      316M  …  329M           0 ( 0%)          -  0.2% ±  0.8%
  cache_misses       10.2M  ± 52.9K     10.1M  … 10.2M           2 (17%)          -  0.2% ±  0.3%
  branch_misses      7.83M  ± 22.2K     7.76M  … 7.86M           2 (17%)          -  0.2% ±  0.3%
```

No meaningful differences across the board, which is what we expect. What this (tentatively) means is that heap allocation is another potential confounder, and that something as inconsequential as a single allocation being a different size (in our case the `NamedCharacterReferenceMatcher` instance) may have knock-on effects that last for the rest of the program (or I'm wrong about the cause and this is a red herring).

<p><aside class="note">

Note: I also wrote [a version of the same benchmark](https://github.com/squeek502/ladybird/blob/all-in-one/Tests/LibWeb/BenchHTMLTokenizerFilesBumpAlloc.cpp) using a (very simple and janky) bump allocator and that, too, got rid of the difference (even when the `NamedCharacterReferenceMatcher` implementations have different sizes).

<details class="box-border" style="padding: 1em; margin-bottom: 1em;">
<summary>Bump allocation details/results</summary>

Bump allocation in this case means that a single large chunk of memory is allocated upfront and then all heap allocations afterward are satisfied by doling out a portion of that initial chunk. This means that each named character reference implementation will use the same memory syscalls. Here's the results:

```poopresults
Benchmark 1 (11 runs): ./BenchHTMLTokenizerFilesBumpAlloc dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.87s  ± 39.4ms    1.84s  … 1.99s           1 ( 9%)        0%
  peak_rss            338MB ±  168KB     338MB …  338MB          0 ( 0%)        0%
  cpu_cycles         7.02G  ±  158M     6.91G  … 7.48G           1 ( 9%)        0%
  instructions       16.1G  ± 77.1K     16.1G  … 16.1G           0 ( 0%)        0%
  cache_references    334M  ± 1.89M      332M  …  338M           0 ( 0%)        0%
  cache_misses       10.8M  ±  110K     10.7M  … 11.0M           0 ( 0%)        0%
  branch_misses      8.25M  ± 3.12M     7.29M  … 17.7M           1 ( 9%)        0%
Benchmark 2 (12 runs): ./BenchHTMLTokenizerFilesBumpAlloc blink
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.86s  ± 9.05ms    1.84s  … 1.87s           1 ( 8%)          -  0.8% ±  1.3%
  peak_rss            338MB ±  113KB     338MB …  338MB          0 ( 0%)          +  0.0% ±  0.0%
  cpu_cycles         6.97G  ± 31.8M     6.92G  … 7.03G           0 ( 0%)          -  0.8% ±  1.4%
  instructions       16.1G  ± 66.1K     16.1G  … 16.1G           0 ( 0%)          -  0.0% ±  0.0%
  cache_references    335M  ±  966K      333M  …  337M           1 ( 8%)          +  0.2% ±  0.4%
  cache_misses       10.8M  ± 39.9K     10.8M  … 10.9M           0 ( 0%)          +  0.5% ±  0.7%
  branch_misses      7.35M  ± 75.4K     7.30M  … 7.51M           2 (17%)          - 10.9% ± 22.7%
Benchmark 3 (12 runs): ./BenchHTMLTokenizerFilesBumpAlloc gecko
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.85s  ± 6.66ms    1.84s  … 1.86s           1 ( 8%)          -  1.0% ±  1.3%
  peak_rss            338MB ±  158KB     338MB …  338MB          1 ( 8%)          +  0.0% ±  0.0%
  cpu_cycles         6.96G  ± 27.3M     6.91G  … 7.01G           0 ( 0%)          -  0.9% ±  1.4%
  instructions       16.1G  ± 96.6K     16.1G  … 16.1G           0 ( 0%)          -  0.1% ±  0.0%
  cache_references    334M  ± 1.35M      332M  …  337M           0 ( 0%)          +  0.1% ±  0.4%
  cache_misses       10.7M  ± 60.7K     10.7M  … 10.9M           0 ( 0%)          -  0.3% ±  0.7%
  branch_misses      7.29M  ± 22.6K     7.27M  … 7.35M           1 ( 8%)          - 11.7% ± 22.7%
```

</details>

</aside></p>

Consequently, this means that I won't bother with the 'average case' benchmarking moving forward. In other words, spoiler alert: nothing in this article will move the needle on this 'average case' benchmark.

### Side note: conforming to one API

Something worth mentioning here is that I've made the choice to convert the Firefox/Chrome/Safari implementations to conform to the `NamedCharacterReferenceMatcher` API used by Ladybird (instead of porting the full named character reference tokenizer state implementation from the other browsers' into Ladybird). This was done for two reasons:

- First, to rule out differences in the tokenizer state implementation itself (tangential to the matching strategy) affecting the matching speed. This might seem strange now, but the logic behind this will be discussed in detail later.
- Second, it made it so compiling one binary that can switch between all the different implementations at runtime (for the purposes of removing the confounding effect of layout differences) was very convenient.

I'm mentioning this now because it means that I've introduced another possible source of error into my benchmarks; the Firefox/Chrome/Safari implementations that I'm testing are *not* 1:1 ports, as they had to be transformed to conform to the `NamedCharacterReferenceMatcher` API (Firefox much more than Chrome/Safari).

<p><aside class="note">

My converted implementations that I'll be using for benchmarking are available in [this branch](https://github.com/squeek502/ladybird/tree/all-in-one).

</aside></p>

### Lessons learned

I think the big takeaway here is that there is a *lot* that can go wrong when benchmarking.

Aside from the more esoteric stuff mentioned above, there are also countless simple/dumb mistakes that can be made that can completely ruin a benchmark's integrity. As an example, for a good while when writing this article, I accidentally left a loop in the Chrome version that I only put there for debugging purposes. That loop was just eating CPU cycles for no reason and skewed my benchmark results pretty significantly. Luckily, I found and fixed that particular mistake, but that sort of thing could have easily gone unnoticed and caused me to draw totally invalid conclusions. Beyond that, there's other stuff I haven't mentioned like CPU architecture, compiler flags, etc, etc, etc.

What I'm really trying to get across is something like:

- You should definitely be skeptical of the benchmarking results I'm providing throughout this article.
- You might want to be skeptical of *all* benchmarking results, generally.

With all that out of the way, let's get into it.

### Comparison with Gecko (Firefox)

<div style="float:right; margin-top: -2rem;"><img style="max-width: 96px;" src="/images/better-named-character-reference-tokenization/firefox.svg" /></div>

The current implementation of named character reference tokenization in the Gecko engine (Firefox's browser engine) [was introduced in 2010](https://github.com/validator/htmlparser/commit/531dbda0a10b6b7c55cb1f054777c8c5e6f61fec), and refined during the rest of 2010. It has [remained unchanged since then](https://github.com/validator/htmlparser/commits/master/translator-src/nu/validator/htmlparser/generator/GenerateNamedCharactersCpp.java).

<p><aside class="note">

Note: Firefox's HTML tokenizer is actually [written in Java](https://github.com/validator/htmlparser) which is then [translated to C++](https://github.com/mozilla-firefox/firefox/tree/main/parser/html/java)

</aside></p>

It does not use any form of a trie, but instead uses a number of arrays (48 in total) to progressively narrow down the possible candidates within the set of named character references until there's no more possible candidates remaining. Here's an overview:

- The first character is checked to ensure that it is within the `a-z` or `A-Z` range and the first character is saved [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5Tokenizer.cpp#L2036-L2039)]

<p><aside class="note">

Note: This is one property of all named character references that the Firefox implementation takes advantage of: *all* named character references start with a character within the `a-z` or `A-Z` range&mdash;no exceptions.

</aside></p>

- The second character is then used as an index into a `HILO_ACCEL` array in order to get the 'row' to use for the first character (there are 44 possible rows; the second character is also always within `a-z` and `A-Z`, but there happens to be 8 missing characters from the `A-Z` range) [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5Tokenizer.cpp#L2072-L2073)]
- If a valid row exists, the first character is then transformed into an index between `0` and `51` (inclusive) and that is used as an index into the 'row' that was retrieved from the second character [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5Tokenizer.cpp#L2074-L2076)]
- The value obtained by the combination of the first two characters contains a 32-bit number:
    + The "lo" bits (the least significant 16 bits) gives you an index into the `NAMES` array starting at the first possible matching name [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5Tokenizer.cpp#L2094)]
    + The "hi" bits (the most significant 16 bits) gives you an index into the `NAMES` array starting at the last possible matching name [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5Tokenizer.cpp#L2095)]
- The values in the `NAMES` array are `struct`'s that contain two pieces of information [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5NamedCharacters.h#L31-L39)]:
    + An index to the start of the remaining characters in the name, within the `ALL_NAMES` array (an array of bytes)
    + The length of the remaining characters in the name
- The "lo" and "hi" indexes are then incremented/decremented as candidates get ruled out, while taking note of any fully matching candidates. This happens until there are no possible candidates left (`hi < lo` or `;` is seen). [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5Tokenizer.cpp#L2111-L2158)]
- The most recently matching candidate's index (if any) is then re-used to look up the mapped code point(s) within the `VALUES` array (the `NAMES` and `VALUES` arrays are the same length) [[src](https://github.com/mozilla-firefox/firefox/blob/1f3f57e2c0f0f0a8cfaf532c9b63f722135e83b8/parser/html/nsHtml5Tokenizer.cpp#L2173-L2174)]

In the very likely scenario that the above description is hard to take in, here's my best attempt at visually illustrating how it works, matching against the valid named character reference `&notinvc;`:

<div style="text-align: center; position: relative; margin-bottom: 2rem;" id="gecko-explanation">
  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;"><b>n</b>otinvc;</code>
    <code style="grid-area: b;" class="token_selector">^</code>
  </div>

  <p class="box-border explanation-note"><span class="token_addition" style="font-size: 150%; vertical-align: middle;">&#x2611;</span> the first character (<code>n</code>) is within the <code>a-z</code> or <code>A-Z</code> range</p>

  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;">n<b>o</b>tinvc;</code>
    <code style="grid-area: b; white-space: pre;" class="token_selector"> ^</code>
  </div>

  <p class="box-border explanation-note">Use the second character (<code>o</code>) to get the array to use with the first character (<code>n</code>)</p>
  
  <div class="hilo-arrays">
  <table>
    <thead>
      <tr class="has-bg">
        <th colspan=3>
          <code><b>HILO_ACCEL</b></code>
        </th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>0</td>
        <td><code>'\x00'</code></td>
        <td>N/A</td>
      </tr>
      <tr>
        <td colspan=3>...</td>
      </tr>
      <tr>
        <td>65</td>
        <td><code>'A'</code></td>
        <td><code>HILO_ACCEL_65</code></td>
      </tr>
      <tr>
        <td colspan=3>...</td>
      </tr>
      <tr>
        <td>110</td>
        <td><code>'n'</code></td>
        <td><code>HILO_ACCEL_110</code></td>
      </tr>
      <tr class="row-highlight" style="position: relative;">
        <td>111</td>
        <td><code>'o'</code></td>
        <td style="position: relative;">
          <div class="arrow-from1"></div>
          <code>HILO_ACCEL_111</code>
        </td>
      </tr>
      <tr>
        <td>110</td>
        <td><code>'p'</code></td>
        <td><code>HILO_ACCEL_112</code></td>
      </tr>
      <tr>
        <td colspan=3>...</td>
      </tr>
      <tr>
        <td>122</td>
        <td><code>'z'</code></td>
        <td><code>HILO_ACCEL_122</code></td>
      </tr>
    </tbody>
  </table>
  <div></div>
  <table>
    <thead>
      <tr class="has-bg">
        <th colspan=3 style="position: relative;">
          <div class="arrow-right"></div>
          <code><b>HILO_ACCEL_111</b></code>
        </th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>0</td>
        <td><code>'A'</code></td>
        <td><code>0x<span class="token_keyword">0011</span><span class="token_function">0010</span></code></td>
      </tr>
      <tr>
        <td colspan=3>...</td>
      </tr>
      <tr>
        <td>25</td>
        <td><code>'Z'</code></td>
        <td>...</td>
      </tr>
      <tr>
        <td>26</td>
        <td><code>'a'</code></td>
        <td>...</td>
      </tr>
      <tr>
        <td colspan=3>...</td>
      </tr>
      <tr class="row-highlight">
        <td style="position: relative;">
          <div class="arrow-hilo"></div>
          39
        </td>
        <td><code>'n'</code></td>
        <td style="position: relative;">
          <div class="arrow-hilo-vertical"></div>
          <code>0x<span class="token_keyword">0602</span><span class="token_function">05F6</span></code>
        </td>
      </tr>
      <tr>
        <td colspan=3>...</td>
      </tr>
      <tr>
        <td>51</td>
        <td><code>'z'</code></td>
        <td><code title="there's only 1 named character reference that starts with 'z' and then 'o' (&amp;zopf;)" style="cursor: default;">0x<span class="token_keyword">08B3</span><span class="token_function">08B3</span></code></td>
      </tr>
    </tbody>
  </table>
</div>

<div style="display: grid; grid-template-columns: 1fr 1fr; max-width: 300px; margin: auto; margin-top: 2rem;">
  <div style="grid-column: span 2;"><code>0x<span class="token_keyword">0602</span><span class="token_function">05F6</span></code></div>
  <div style="grid-column: span 2; font-size: 125%;">&nbsp;&nbsp; &LowerLeftArrow; &nbsp;&nbsp;&nbsp;&nbsp; &LowerRightArrow;</div>
  <div><code>hi</code></div>
  <div><code>lo</code></div>
  <div><code>0x<span class="token_keyword">0602</span></code> or 1538</div>
  <div><code>0x<span class="token_function">05F6</span></code> or 1526</div>
</div>

<p class="box-border explanation-note">Any possible matches must be between indexes 1526 and 1538 (inclusive)</p>

<div><p class="box-border explanation-note">The possible matches are:</p></div>

<div style="margin: 1rem; margin-top: 0">
<table style="margin: auto;">
  <thead>
    <tr class="has-bg">
      <th colspan=2>
        <code><b>NAMES</b></code>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>1526</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>pf;</code></td>
    </tr>
    <tr>
      <td>1527</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>t</code></td>
    </tr>
    <tr>
      <td>1528</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>t;</code></td>
    </tr>
    <tr>
      <td>1529</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tin;</code></td>
    </tr>
    <tr>
      <td>1530</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tinE;</code></td>
    </tr>
    <tr>
      <td>1531</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tindot;</code></td>
    </tr>
    <tr>
      <td>1532</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tinva;</code></td>
    </tr>
    <tr>
      <td>1533</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tinvb;</code></td>
    </tr>
    <tr>
      <td>1534</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tinvc;</code></td>
    </tr>
    <tr>
      <td>1535</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tni;</code></td>
    </tr>
    <tr>
      <td>1536</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tniva;</code></td>
    </tr>
    <tr>
      <td>1537</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tnivb;</code></td>
    </tr>
    <tr>
      <td>1538</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span>tnivc;</code></td>
    </tr>
  </tbody>
</table>
</div>

<div><p class="box-border explanation-note">Now we start to narrow those possibilities down:</p></div>

  <style scoped>
    .explanation-note {
      display: inline-block; padding: 1rem; margin: 1rem;
    }
    table {
      text-align: center; border: 1px solid; border-collapse: collapse;
    }
    table, th, td {
      border: 1px solid #BBC; 
    }
@media (prefers-color-scheme: dark) {
    table, th, td {
      border: 1px solid #0A0514FF; 
    }
}
    th, td {
      padding: 0.25rem;
    }
    .row-highlight {
      background: #E5C0FF; outline: 1px dashed #613583;
    }
@media (prefers-color-scheme: dark) {
    .row-highlight {
      background: #251134; outline: 1px dashed #613583;
    }
}
    .ruled-out {
      opacity: 0.5;
    }
    .hilo-arrays {
      display: grid; grid-template-columns: 1fr 300px 1fr; grid-gap: 1rem; padding: 1rem;
    }
    .arrow-from1 {
      position:absolute; left: calc(100% + 1px); bottom: 50%; width: calc(75px + 1rem); height: calc(600%); border-right: 2px solid #613583FF; border-bottom: 2px solid #613583FF;
    }
    .arrow-right {
      position:absolute; right: calc(100% + 1px + 10px); top: 50%; width: calc(225px + 1rem - 10px); border-top: 2px solid #613583FF;
    }
@media (min-width: 600px) {
    .arrow-hilo::after {
      content: '';
      width: 0; 
      height: 0; 
      border-right: 7px solid transparent;
      border-left: 7px solid transparent;
      border-top: 20px solid #613583FF;
      position: absolute;
      left: -8px;
      bottom: -10px;
      z-index: 5;
    }
    .arrow-hilo {
      position:absolute; right: calc(100% + 1px); height: calc(300% + 1rem); top: 50%; width: calc(150px + 1rem); border-top: 2px dashed #613583FF; border-left: 2px dashed #613583FF; border-top-left-radius: 75%;
    }
}
@media (max-width: 800px) {
    .hilo-arrays {
      grid-template-columns: 1fr 150px 1fr;
    }
    .arrow-from1 {
      width: calc(25px + 1rem);
    }
    .arrow-right {
      width: calc(125px + 1rem - 10px);
    }
    .arrow-hilo {
      width: calc(75px + 1rem);
    }
}
@media (max-width: 700px) {
    .hilo-arrays {
      grid-template-columns: 1fr 100px 1fr;
    }
    .arrow-from1 {
      width: calc(25px + 1rem);
    }
    .arrow-right {
      width: calc(75px + 1rem - 10px);
    }
    .arrow-hilo {
      width: calc(50px + 1rem);
    }
}
@media (max-width: 600px) {
    .hilo-arrays {
      grid-template-columns: 1fr;
      padding-right: 5rem;
    }
    .arrow-from1 {
      position:absolute; left: calc(100% + 1px); top: 50%; width: 3rem; height: calc(400% + 2rem); border-right: 2px solid #613583FF; border-top: 2px solid #613583FF; border-radius: 0 2rem 2rem 0;
    }
    .arrow-from1::after, .arrow-hilo-vertical::after {
      content: '';
      width: 0; 
      height: 0; 
      border-top: 7px solid transparent;
      border-bottom: 7px solid transparent;
      border-right: 20px solid #613583FF;
      position: absolute;
      left: -10px;
      bottom: -8px;
      z-index: 5;
    }
    .arrow-hilo-vertical::after {
      left: -20px;
    }
    .arrow-right {
      display: none;
    }
    .arrow-hilo {
      display: none;
    }
    .arrow-hilo-vertical {
      position:absolute; left: calc(100% + 1px); top: 50%; width: 3rem; height: calc(300% + 2.5rem); border: 2px dashed #613583FF; border-left: 0; border-radius: 0 2rem 2rem 0;
    }
}
    .arrow-right::after {
      content: '';
      width: 0; 
      height: 0; 
      border-top: 7px solid transparent;
      border-bottom: 7px solid transparent;
      border-left: 20px solid #613583FF;
      position: absolute;
      right: -10px;
      top: -8px;
      z-index: 5;
    }

    .gecko-narrow #next-char {
      position:absolute; width: 50px; height: 50px; border-radius: 50%; right: 50px; top: calc(50% - 25px); line-height: 50px; font-size: 25px; color: #666; display: block; text-decoration: none;
    }
    .gecko-narrow #prev-char {
      position:absolute; width: 50px; height: 50px; border-radius: 50%; left: 50px; top: calc(50% - 25px); line-height: 50px; font-size: 25px; color: #666; display: block; text-decoration: none;
    }

    .gecko-narrow #next-char.disabled, .gecko-narrow #prev-char.disabled {
      opacity: 0.25; cursor: default; pointer-events: none;
    }
  </style>

<div style="position: relative;" class="gecko-narrow" id="gecko-t">
<div class="two-column-collapse" style="grid-template-columns: 2fr 1fr; grid-gap: 0.5rem;">
  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;">no<b>t</b>invc;</code>
    <code style="grid-area: b; white-space: pre;" class="token_selector">  ^</code>
  </div>
  <div class="has-bg" style="display: flex; align-items: center; justify-content: center;"><a id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">off</span></a></div>
</div>
<a class="has-bg" href="#" id="next-char">&#x27A4;</a>
<a class="has-bg disabled" href="#" id="prev-char">&#x2B9C;</a>

<div style="margin: 1rem;">
<table style="margin: auto;">
  <thead>
    <tr class="has-bg">
      <th colspan=2>
        <code><b>NAMES</b></code>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr class="ruled-out">
      <td><s>1526</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_error">p</span>f;</code></td>
    </tr>
    <tr>
      <td>1527</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span></code></td>
    </tr>
    <tr>
      <td>1528</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>;</code></td>
    </tr>
    <tr>
      <td>1529</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>in;</code></td>
    </tr>
    <tr>
      <td>1530</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>inE;</code></td>
    </tr>
    <tr>
      <td>1531</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>indot;</code></td>
    </tr>
    <tr>
      <td>1532</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>inva;</code></td>
    </tr>
    <tr>
      <td>1533</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>invb;</code></td>
    </tr>
    <tr>
      <td>1534</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>invc;</code></td>
    </tr>
    <tr>
      <td>1535</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>ni;</code></td>
    </tr>
    <tr>
      <td>1536</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>niva;</code></td>
    </tr>
    <tr>
      <td>1537</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>nivb;</code></td>
    </tr>
    <tr>
      <td>1538</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span>nivc;</code></td>
    </tr>
  </tbody>
</table>
</div>
</div>


<div style="position: relative;" class="gecko-narrow" id="gecko-i">
<div class="two-column-collapse" style="grid-template-columns: 2fr 1fr; grid-gap: 0.5rem;">
  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;">not<b>i</b>nvc;</code>
    <code style="grid-area: b; white-space: pre;" class="token_selector">   ^</code>
  </div>
  <div class="has-bg" style="display: flex; align-items: center; justify-content: center;"><a id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">off</span></a></div>
</div>
<a class="has-bg" href="#" id="next-char">&#x27A4;</a>
<a class="has-bg" href="#" id="prev-char">&#x2B9C;</a>

<div style="margin: 1rem;">
<table style="margin: auto;">
  <thead>
    <tr class="has-bg">
      <th colspan=2>
        <code><b>NAMES</b></code>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr class="ruled-out">
      <td><s>1526</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_error">p</span>f;</code></td>
    </tr>
    <tr class="row-highlight">
      <td><s>1527</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1528</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">;</span></code></td>
    </tr>
    <tr>
      <td>1529</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">ti</span>n;</code></td>
    </tr>
    <tr>
      <td>1530</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">ti</span>nE;</code></td>
    </tr>
    <tr>
      <td>1531</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">ti</span>ndot;</code></td>
    </tr>
    <tr>
      <td>1532</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">ti</span>nva;</code></td>
    </tr>
    <tr>
      <td>1533</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">ti</span>nvb;</code></td>
    </tr>
    <tr>
      <td>1534</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">ti</span>nvc;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1535</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>i;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1536</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>iva;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1537</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivb;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1538</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivc;</code></td>
    </tr>
  </tbody>
</table>
</div>
</div>

<div style="position: relative;" class="gecko-narrow" id="gecko-n">
<div class="two-column-collapse" style="grid-template-columns: 2fr 1fr; grid-gap: 0.5rem;">
  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;">noti<b>n</b>vc;</code>
    <code style="grid-area: b; white-space: pre;" class="token_selector">    ^</code>
  </div>
  <div class="has-bg" style="display: flex; align-items: center; justify-content: center;"><a id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">off</span></a></div>
</div>
<a class="has-bg" href="#" id="next-char">&#x27A4;</a>
<a class="has-bg" href="#" id="prev-char">&#x2B9C;</a>

<div style="margin: 1rem;">
<table style="margin: auto;">
  <thead>
    <tr class="has-bg">
      <th colspan=2>
        <code><b>NAMES</b></code>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr class="ruled-out">
      <td><s>1526</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_error">p</span>f;</code></td>
    </tr>
    <tr class="row-highlight">
      <td><s>1527</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1528</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">;</span></code></td>
    </tr>
    <tr>
      <td>1529</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span>;</code></td>
    </tr>
    <tr>
      <td>1530</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span>E;</code></td>
    </tr>
    <tr>
      <td>1531</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span>dot;</code></td>
    </tr>
    <tr>
      <td>1532</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span>va;</code></td>
    </tr>
    <tr>
      <td>1533</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span>vb;</code></td>
    </tr>
    <tr>
      <td>1534</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span>vc;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1535</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>i;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1536</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>iva;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1537</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivb;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1538</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivc;</code></td>
    </tr>
  </tbody>
</table>
</div>
</div>

<div style="position: relative;" class="gecko-narrow" id="gecko-v">
<div class="two-column-collapse" style="grid-template-columns: 2fr 1fr; grid-gap: 0.5rem;">
  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;">notin<b>v</b>c;</code>
    <code style="grid-area: b; white-space: pre;" class="token_selector">     ^</code>
  </div>
  <div class="has-bg" style="display: flex; align-items: center; justify-content: center;"><a id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">off</span></a></div>
</div>
<a class="has-bg" href="#" id="next-char">&#x27A4;</a>
<a class="has-bg" href="#" id="prev-char">&#x2B9C;</a>

<div style="margin: 1rem;">
<table style="margin: auto;">
  <thead>
    <tr class="has-bg">
      <th colspan=2>
        <code><b>NAMES</b></code>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr class="ruled-out">
      <td><s>1526</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_error">p</span>f;</code></td>
    </tr>
    <tr class="row-highlight">
      <td><s>1527</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1528</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">;</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1529</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">;</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1530</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">E</span>;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1531</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">d</span>ot;</code></td>
    </tr>
    <tr>
      <td>1532</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinv</span>a;</code></td>
    </tr>
    <tr>
      <td>1533</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinv</span>b;</code></td>
    </tr>
    <tr>
      <td>1534</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinv</span>c;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1535</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>i;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1536</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>iva;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1537</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivb;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1538</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivc;</code></td>
    </tr>
  </tbody>
</table>
</div>
</div>

<div style="position: relative;" class="gecko-narrow" id="gecko-c">
<div class="two-column-collapse" style="grid-template-columns: 2fr 1fr; grid-gap: 0.5rem;">
  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;">notinv<b>c</b>;</code>
    <code style="grid-area: b; white-space: pre;" class="token_selector">      ^</code>
  </div>
  <div class="has-bg" style="display: flex; align-items: center; justify-content: center;"><a id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">off</span></a></div>
</div>
<a class="has-bg" href="#" id="next-char">&#x27A4;</a>
<a class="has-bg" href="#" id="prev-char">&#x2B9C;</a>

<div style="margin: 1rem;">
<table style="margin: auto;">
  <thead>
    <tr class="has-bg">
      <th colspan=2>
        <code><b>NAMES</b></code>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr class="ruled-out">
      <td><s>1526</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_error">p</span>f;</code></td>
    </tr>
    <tr class="row-highlight">
      <td><s>1527</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1528</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">;</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1529</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">;</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1530</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">E</span>;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1531</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">d</span>ot;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1532</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinv</span><span class="token_error">a</span>;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1533</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinv</span><span class="token_error">b</span>;</code></td>
    </tr>
    <tr>
      <td>1534</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinvc</span>;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1535</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>i;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1536</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>iva;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1537</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivb;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1538</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivc;</code></td>
    </tr>
  </tbody>
</table>
</div>
</div>

<div style="position: relative;" class="gecko-narrow" id="gecko-semicolon">
<div class="two-column-collapse" style="grid-template-columns: 2fr 1fr; grid-gap: 0.5rem;">
  <div class="has-bg" style="padding: 0.5rem; display: grid; grid-template-rows: 1fr 1fr; grid-template-columns: 1fr min-content 1fr; grid-template-areas: '. a .' '. b .';">
    <code style="grid-area: a;">notinvc<b>;</b></code>
    <code style="grid-area: b; white-space: pre;" class="token_selector">       ^</code>
  </div>
  <div class="has-bg" style="display: flex; align-items: center; justify-content: center;"><a id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">off</span></a></div>
</div>
<a class="has-bg" href="#" id="next-char">&#x27A4;</a>
<a class="has-bg" href="#" id="prev-char">&#x2B9C;</a>

<div style="margin: 1rem;">
<table style="margin: auto;">
  <thead>
    <tr class="has-bg">
      <th colspan=2>
        <code><b>NAMES</b></code>
      </th>
    </tr>
  </thead>
  <tbody>
    <tr class="ruled-out">
      <td><s>1526</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_error">p</span>f;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1527</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1528</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">;</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1529</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">;</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1530</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">E</span>;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1531</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tin</span><span class="token_error">d</span>ot;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1532</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinv</span><span class="token_error">a</span>;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1533</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinv</span><span class="token_error">b</span>;</code></td>
    </tr>
    <tr class="row-highlight">
      <td>1534</td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">tinvc;</span></code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1535</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>i;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1536</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>iva;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1537</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivb;</code></td>
    </tr>
    <tr class="ruled-out">
      <td><s>1538</s></td>
      <td style="text-align: left;"><code><span class="token_comment">no</span><span class="token_addition">t</span><span class="token_error">n</span>ivc;</code></td>
    </tr>
  </tbody>
</table>
</div>
</div>

<script>
(function(){
  let root = document.getElementById("gecko-explanation");
  let step_ids = [
    'gecko-t',
    'gecko-i',
    'gecko-n',
    'gecko-v',
    'gecko-c',
    'gecko-semicolon',
  ];
  let step_i = 0;
  let stop;
  let apply = function() {
    for (let i=0; i<step_ids.length; i++) {
      let e = root.querySelector("#"+step_ids[i]);
      if (step_i == 0) {
        e.querySelector('#prev-char').classList.add('disabled');
      } else {
        e.querySelector('#prev-char').classList.remove('disabled');
      }
      if (step_i == step_ids.length - 1) {
        e.querySelector('#next-char').classList.add('disabled');
        stop();
      } else {
        e.querySelector('#next-char').classList.remove('disabled');
      }
      if (i == step_i) {
        e.style.display = 'block';
        continue;
      }
      e.style.display = 'none';
    }
  }

  apply();
  let next = function() {
    step_i = Math.min(step_ids.length - 1, step_i + 1);
    apply();
  };
  let prev = function() {
    step_i = Math.max(0, step_i - 1);
    apply();
  };
  let auto;
  let start = function() {
    step_i = 0;
    apply();
    auto = setInterval(next, 2250);
    for (let i=0; i<step_ids.length; i++) {
      let step = root.querySelector('#'+step_ids[i]);
      step.querySelector('#autoplay-status').textContent = 'on';
    }
  }
  stop = function() {
    clearInterval(auto);
    auto = undefined;
    for (let i=0; i<step_ids.length; i++) {
      let step = root.querySelector('#'+step_ids[i]);
      step.querySelector('#autoplay-status').textContent = 'off';
    }
  }
  let toggle = function() {
    if (auto !== undefined) {
      stop();
    } else {
      start();
    }
  }

  for (let i=0; i<step_ids.length; i++) {
    let step = root.querySelector('#'+step_ids[i]);
    step.querySelector('#next-char').onclick = function(e) {
      e.preventDefault();
      stop();
      next();
    }
    step.querySelector('#prev-char').onclick = function(e) {
      e.preventDefault();
      stop();
      prev();
    }
    step.querySelector('#autoplay-toggle').onclick = function(e) {
      e.preventDefault();
      toggle();
    }
  }
})();
</script>

</div>

I'm glossing over how *exactly* the possibilities are narrowed down because it's not super relevant (if you're interested, [here's the responsible tokenizer code](https://github.com/mozilla-firefox/firefox/blob/ec7f9e0771ff44a5d22cfa26f4a819b739ef027b/parser/html/nsHtml5Tokenizer.cpp#L2036-L2233)), but I will note that the 'lo' and 'hi' cursors always move linearly (i.e. each possible match is ruled out one-by-one; there's no binary search or anything like that going on).

This approach works well because the first two characters alone fairly reliably narrow down the possibilities to a pretty small range. Out of 2288 possible combinations of the first two characters, 1658 of them (72.5%) lead to zero possible matches. Out of the remaining combinations (those with &ge; 1 possible match), the mean number of matches is 3.54 with a standard deviation of 29.8, and the median number of possible matches is 2. Here's what the full distribution looks like (with the combinations that lead to zero matches included):

<div style="text-align: center;">
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100%;" style="overflow:hidden;max-width:600px" viewBox="30 100 525 325" aria-label="A chart." id="gecko-freq-chart"><defs id="_ABSTRACT_RENDERER_ID_1864"><clipPath id="_ABSTRACT_RENDERER_ID_1865"><rect x="127" y="83" width="412" height="268"></rect></clipPath></defs><rect x="0" y="0" width="666.6666666666664" height="433.33333333333337" stroke="none" stroke-width="0" fill="transparent"></rect><g><rect x="127" y="83" width="412" height="268" stroke="none" stroke-width="0" fill-opacity="0" fill="#ffffff"></rect><g clip-path="url(#_ABSTRACT_RENDERER_ID_1865)"><g><rect x="127" y="350" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-major"></rect><rect x="127" y="283" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-major"></rect><rect x="127" y="217" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-major"></rect><rect x="127" y="150" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-major"></rect><rect x="127" y="317" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-minor"></rect><rect x="127" y="250" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-minor"></rect><rect x="127" y="183" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-minor"></rect><rect x="127" y="116" width="412" height="1" stroke="none" stroke-width="0" class="y-axis-line-minor"></rect></g><g><rect x="128.5" y="130" width="4" height="220" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="136.5" y="315" width="4" height="35" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="143.5" y="332" width="4" height="18" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="150.5" y="343" width="4" height="7" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="158.5" y="345" width="4" height="5" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="165.5" y="347.83000000000004" width="4" height="2.669999999999959" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="172.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="180.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="187.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="194.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="202.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="209.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="216.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="224.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="231.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="238.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="246.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="253.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="261.5" y="349" width="4" height="1" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="268.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="275.5" y="349" width="4" height="1" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="283.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="290.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="297.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="305.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="312.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="319.5" y="349" width="4" height="1" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="327.5" y="349" width="4" height="1" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="334.5" y="349" width="4" height="1" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="341.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="349.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="356.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="363.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="371.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="378.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="385.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="393.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="400.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="407.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="415.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="422.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="429.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="437.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="444.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="451.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="459.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="466.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="473.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="481.5" y="349" width="4" height="1" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="488.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="495.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="503.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="510.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="517.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="525.5" y="350" width="4" height="0" stroke="none" stroke-width="0" class="bar-value"></rect><rect x="532.5" y="348" width="4" height="2" stroke="none" stroke-width="0" class="bar-value"></rect></g><g><rect x="127" y="350" width="412" height="1" stroke="none" stroke-width="0" class="x-axis"></rect></g></g><g></g><g><g><text text-anchor="end" x="133.44464285714287" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 133.44464285714287 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">0</text></g><g><text text-anchor="end" x="170.14107142857145" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 170.14107142857145 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">5</text></g><g><text text-anchor="end" x="206.8375" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 206.8375 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">10</text></g><g><text text-anchor="end" x="243.53392857142856" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 243.53392857142856 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">15</text></g><g><text text-anchor="end" x="280.2303571428571" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 280.2303571428571 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">20</text></g><g><text text-anchor="end" x="316.9267857142857" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 316.9267857142857 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">25</text></g><g><text text-anchor="end" x="353.62321428571425" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 353.62321428571425 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">30</text></g><g><text text-anchor="end" x="390.31964285714287" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 390.31964285714287 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">35</text></g><g><text text-anchor="end" x="427.0160714285714" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 427.0160714285714 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">40</text></g><g><text text-anchor="end" x="463.7125" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 463.7125 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">45</text></g><g><text text-anchor="end" x="500.40892857142853" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 500.40892857142853 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">50</text></g><g><text text-anchor="end" x="537.1053571428571" y="369.4404155872192" font-family="Arial" font-size="13" transform="rotate(-30 537.1053571428571 369.4404155872192)" stroke="none" stroke-width="0" class="x-axis-label">55</text></g><g><text text-anchor="end" x="114" y="355.05" font-family="Arial" font-size="13" stroke="none" stroke-width="0" class="y-axis-label">0</text></g><g><text text-anchor="end" x="114" y="288.3" font-family="Arial" font-size="13" stroke="none" stroke-width="0" class="y-axis-label">500</text></g><g><text text-anchor="end" x="114" y="221.55" font-family="Arial" font-size="13" stroke="none" stroke-width="0" class="y-axis-label">1,000</text></g><g><text text-anchor="end" x="114" y="154.8" font-family="Arial" font-size="13" stroke="none" stroke-width="0" class="y-axis-label">1,500</text></g></g></g><g><g><text text-anchor="middle" x="333" y="410.2166666666667" font-family="Arial" font-size="13" font-style="italic" stroke="none" stroke-width="0" class="x-axis-title">Number of possible matches after the first two characters</text></g><g><text text-anchor="middle" x="30.05" y="217" font-family="Arial" font-size="13" font-style="italic" transform="rotate(-90 45.05 217)" stroke="none" stroke-width="0" class="y-axis-title">Frequency</text></g></g><g></g></svg>

<style scoped>

#gecko-freq-chart .x-axis {
  fill: #bbb;
}
#gecko-freq-chart .y-axis-line-major {
  fill: #ccc;
}
#gecko-freq-chart .y-axis-line-minor {
  fill: #ddd;
}
#gecko-freq-chart .x-axis-label, #gecko-freq-chart .y-axis-label {
  fill: #444;
}
#gecko-freq-chart .x-axis-title, #gecko-freq-chart .y-axis-title {
  fill: #333;
}
#gecko-freq-chart .bar-value {
  fill: #613583FF;
}

@media (prefers-color-scheme: dark) {
#gecko-freq-chart .x-axis {
  fill: #555;
}
#gecko-freq-chart .y-axis-line-major {
  fill: #444;
}
#gecko-freq-chart .y-axis-line-minor {
  fill: #333;
}
#gecko-freq-chart .x-axis-label, #gecko-freq-chart .y-axis-label {
  fill: #ccc;
}
#gecko-freq-chart .x-axis-title, #gecko-freq-chart .y-axis-title {
  fill: #ddd;
}
}

</style>

</div>

<p><aside class="note">

Note: There are 2 first-two-character-combinations that lead to 55 possible matches: `No` and `su`.

</aside></p>

Now that we have an understanding of how the Firefox implementation works, let's see how it compares using the three metrics that were mentioned at the start.

#### Performance

Performance between the Firefox version and the Ladybird DAFSA version is basically a wash in the primary benchmark I'm using ([tokenizing a file with tens of thousands of valid and invalid named character references](https://github.com/squeek502/ladybird/blob/1a2a2774a251782f22eb6f1597ee743adf856db7/Tests/LibWeb/BenchHTMLTokenizer.cpp#L10)):

```poopresults
Benchmark 1 (89 runs): ./BenchHTMLTokenizer gecko
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           113ms ± 1.12ms     111ms …  115ms          0 ( 0%)        0%
  peak_rss           83.4MB ± 93.7KB    83.0MB … 83.5MB          2 ( 2%)        0%
  cpu_cycles          226M  ±  877K      224M  …  230M           3 ( 3%)        0%
  instructions        438M  ± 10.6K      438M  …  438M           7 ( 8%)        0%
  cache_references   9.54M  ±  130K     9.40M  … 10.5M           6 ( 7%)        0%
  cache_misses        427K  ± 11.1K      406K  …  458K           2 ( 2%)        0%
  branch_misses       578K  ± 1.79K      575K  …  585K           5 ( 6%)        0%
Benchmark 2 (88 runs): ./BenchHTMLTokenizer dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           114ms ± 1.38ms     110ms …  116ms          5 ( 6%)          +  0.7% ±  0.3%
  peak_rss           83.3MB ± 94.6KB    83.0MB … 83.5MB          1 ( 1%)          -  0.1% ±  0.0%
  cpu_cycles          229M  ±  856K      227M  …  232M           3 ( 3%)        💩+  1.4% ±  0.1%
  instructions        450M  ± 10.4K      450M  …  450M           3 ( 3%)        💩+  2.7% ±  0.0%
  cache_references   9.42M  ±  128K     9.25M  … 10.5M           3 ( 3%)          -  1.2% ±  0.4%
  cache_misses        418K  ± 9.03K      400K  …  443K           2 ( 2%)        ⚡-  2.0% ±  0.7%
  branch_misses       575K  ± 3.01K      570K  …  600K           5 ( 6%)          -  0.5% ±  0.1%
```

However, if we tailor some benchmarks to test the scenarios where each should theoretically perform the worst, we can see some clearer differences.

I believe the worst case for the Firefox implementation is successfully matching the named character reference `&supsetneqq;`. As mentioned earlier, `su` as the first two characters narrows down the possibilities the least, with 55 remaining possibilities, and `&supsetneqq;` should take the longest to match out of the remaining possibilities.

Here are the results for [tokenizing a file with nothing but 30,000 `&supsetneqq;` sequences in a row](https://github.com/squeek502/ladybird/blob/1a2a2774a251782f22eb6f1597ee743adf856db7/Tests/LibWeb/BenchHTMLTokenizer.cpp#L12):

```poopresults
Benchmark 1 (197 runs): ./BenchHTMLTokenizer gecko gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          50.6ms ± 1.11ms    48.3ms … 53.2ms          0 ( 0%)        0%
  peak_rss           53.0MB ± 85.4KB    52.7MB … 53.2MB          1 ( 1%)        0%
  cpu_cycles          137M  ±  816K      135M  …  140M           3 ( 2%)        0%
  instructions        278M  ± 9.06K      278M  …  278M           7 ( 4%)        0%
  cache_references   3.27M  ± 58.4K     3.13M  … 3.55M          17 ( 9%)        0%
  cache_misses        361K  ± 10.0K      342K  …  396K           2 ( 1%)        0%
  branch_misses       314K  ± 5.29K      306K  …  335K           5 ( 3%)        0%
Benchmark 2 (218 runs): ./BenchHTMLTokenizer dafsa gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          45.9ms ±  805us    43.6ms … 47.5ms         22 (10%)        ⚡-  9.3% ±  0.4%
  peak_rss           53.0MB ± 83.9KB    52.7MB … 53.2MB          1 ( 0%)          -  0.0% ±  0.0%
  cpu_cycles          117M  ±  635K      116M  …  119M           3 ( 1%)        ⚡- 14.5% ±  0.1%
  instructions        259M  ± 5.16K      259M  …  259M           5 ( 2%)        ⚡-  7.0% ±  0.0%
  cache_references   3.27M  ±  128K     3.15M  … 4.10M          20 ( 9%)          -  0.0% ±  0.6%
  cache_misses        357K  ± 7.06K      344K  …  384K           5 ( 2%)          -  1.1% ±  0.5%
  branch_misses       183K  ± 1.95K      179K  …  193K          21 (10%)        ⚡- 41.8% ±  0.2%
```

On the flipside, the scenario where the Firefox implementation likely outperforms the Ladybird implementation the most is an invalid named character reference that can be rejected from the first two characters alone (I've arbitrarily chosen `&cz`).

Here are the results for [tokenizing a file with nothing but 30,000 `&cz` sequences in a row](https://github.com/squeek502/ladybird/blob/1a2a2774a251782f22eb6f1597ee743adf856db7/Tests/LibWeb/BenchHTMLTokenizer.cpp#L13):

```poopresults
Benchmark 1 (163 runs): ./BenchHTMLTokenizer gecko ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          61.4ms ±  958us    59.2ms … 63.6ms          1 ( 1%)        0%
  peak_rss           65.1MB ± 85.5KB    64.9MB … 65.3MB         24 (15%)        0%
  cpu_cycles          104M  ±  525K      102M  …  106M           4 ( 2%)        0%
  instructions        194M  ± 4.18K      194M  …  194M           2 ( 1%)        0%
  cache_references   5.89M  ±  125K     5.79M  … 6.92M           8 ( 5%)        0%
  cache_misses        374K  ± 4.44K      367K  …  385K           0 ( 0%)        0%
  branch_misses       163K  ± 1.24K      160K  …  166K           3 ( 2%)        0%
Benchmark 2 (159 runs): ./BenchHTMLTokenizer dafsa ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          63.0ms ± 1.00ms    60.1ms … 65.0ms          0 ( 0%)        💩+  2.6% ±  0.3%
  peak_rss           65.1MB ± 74.3KB    64.8MB … 65.2MB          1 ( 1%)          -  0.1% ±  0.0%
  cpu_cycles          112M  ±  673K      111M  …  117M           8 ( 5%)        💩+  7.6% ±  0.1%
  instructions        214M  ± 4.26K      214M  …  214M           1 ( 1%)        💩+ 10.4% ±  0.0%
  cache_references   5.87M  ± 54.9K     5.77M  … 6.19M           5 ( 3%)          -  0.4% ±  0.4%
  cache_misses        375K  ± 4.52K      364K  …  391K           2 ( 1%)          +  0.2% ±  0.3%
  branch_misses       164K  ±  751       161K  …  166K           2 ( 1%)          +  0.4% ±  0.1%
```

However, neither of these scenarios are likely to be all that common in reality. My hunch (but I don't have any data to back this up) is that there are two scenarios that are common in real HTML:

- Valid and complete named character references
- Invalid named character references that come from accidentally putting `&` directly in the markup instead of `&amp;` (and therefore the `&` is probably surrounded by whitespace)

In the second scenario where an `&` character is surrounded by whitespace, the tokenizer will never actually enter the named character reference state, since that requires `&` to be followed by an ASCII alphanumeric character, so all implementations will perform the same there.

We can test the first scenario, though. Here are the results for [a file with nothing but 30,000 valid named character references (chosen at random) in a row](https://github.com/squeek502/ladybird/blob/1a2a2774a251782f22eb6f1597ee743adf856db7/Tests/LibWeb/BenchHTMLTokenizer.cpp#L11):

```poopresults
Benchmark 1 (229 runs): ./BenchHTMLTokenizer gecko all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.6ms ±  713us    41.3ms … 45.2ms         13 ( 6%)        0%
  peak_rss           54.4MB ± 84.8KB    54.1MB … 54.5MB          5 ( 2%)        0%
  cpu_cycles          103M  ±  545K      102M  …  105M           2 ( 1%)        0%
  instructions        188M  ± 10.6K      188M  …  188M          17 ( 7%)        0%
  cache_references   3.63M  ± 91.6K     3.54M  … 4.35M          15 ( 7%)        0%
  cache_misses        361K  ± 8.92K      347K  …  386K           0 ( 0%)        0%
  branch_misses       383K  ± 1.57K      379K  …  387K           0 ( 0%)        0%
Benchmark 2 (233 runs): ./BenchHTMLTokenizer dafsa all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.0ms ±  770us    40.8ms … 44.3ms         30 (13%)        ⚡-  1.3% ±  0.3%
  peak_rss           54.4MB ± 80.6KB    54.0MB … 54.5MB          1 ( 0%)          -  0.1% ±  0.0%
  cpu_cycles          102M  ±  452K      101M  …  104M           4 ( 2%)        ⚡-  1.3% ±  0.1%
  instructions        191M  ± 8.04K      191M  …  191M          11 ( 5%)        💩+  2.0% ±  0.0%
  cache_references   3.54M  ± 63.5K     3.45M  … 4.09M          13 ( 6%)        ⚡-  2.6% ±  0.4%
  cache_misses        355K  ± 5.23K      344K  …  370K           1 ( 0%)        ⚡-  1.7% ±  0.4%
  branch_misses       344K  ± 1.24K      341K  …  348K          17 ( 7%)        ⚡- 10.1% ±  0.1%
```

Something worth noting about why Firefox fares better here than in the `&supsetneqq;` benchmark above is that the distribution of possible matches after two characters is very uneven (as mentioned previously). In 42.7% of cases (269 out of 630) where there is at least 1 possible match after the first two characters, there is *only* 1 possible match. This makes the 'narrowing down the matches' portion of the Firefox implementation essentially just a string comparison.

Something else we can look at is raw matching speed in isolation (i.e. not within the context of HTML tokenization). In [my benchmarking](https://github.com/squeek502/ladybird/blob/named-character-references-test/Tests/LibWeb/BenchMatcher.cpp), the Firefox implementation wins out in this category:

```poopresults
Benchmark 1 (95 runs): ./BenchMatcherGecko
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           105ms ± 1.14ms     102ms …  108ms          5 ( 5%)        0%
  peak_rss           4.56MB ± 72.7KB    4.33MB … 4.72MB          0 ( 0%)        0%
  cpu_cycles          426M  ± 1.40M      424M  …  430M           9 ( 9%)        0%
  instructions        745M  ± 81.5       745M  …  745M           0 ( 0%)        0%
  cache_references   8.03M  ± 81.6K     7.89M  … 8.54M           3 ( 3%)        0%
  cache_misses       28.0K  ± 5.70K     21.2K  … 46.5K           7 ( 7%)        0%
  branch_misses      5.41M  ± 2.49K     5.41M  … 5.42M           0 ( 0%)        0%
Benchmark 2 (84 runs): ./BenchMatcherDafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           120ms ± 1.46ms     116ms …  123ms          0 ( 0%)        💩+ 13.8% ±  0.4%
  peak_rss           4.50MB ± 61.6KB    4.46MB … 4.59MB          0 ( 0%)          -  1.3% ±  0.4%
  cpu_cycles          487M  ± 4.39M      477M  …  496M           2 ( 2%)        💩+ 14.3% ±  0.2%
  instructions       1.02G  ± 66.2      1.02G  … 1.02G          14 (17%)        💩+ 36.7% ±  0.0%
  cache_references   6.11M  ± 90.5K     5.98M  … 6.81M           2 ( 2%)        ⚡- 23.9% ±  0.3%
  cache_misses       26.0K  ± 4.02K     20.3K  … 39.8K           5 ( 6%)        ⚡-  7.1% ±  5.2%
  branch_misses      6.01M  ± 20.5K     5.98M  … 6.06M           0 ( 0%)        💩+ 11.1% ±  0.1%
```

Two things to note:

- It's unclear how applicable this 'raw matching speed' benchmark is for HTML tokenization (this will be discussed more later).
- We'll make some improvements to the DAFSA implementation later that will flip these results.

#### Data size

As noted earlier, Firefox uses a total of 48 arrays for its named character reference data:

- `HILO_ACCEL` is an array of 123 pointers, so that's 984 bytes on a 64-bit architecture
- There are 44 `HILO_ACCEL_n` arrays, each containing 52 32-bit integers, so that's 9,152 bytes
- `ALL_NAMES` is an array of bytes containing the complete set of characters in all named character references, excluding the first two characters of each. This adds up to 12,183 bytes in total
- `NAMES` is an array of 2,231 32-bit structs, so that's 8,924 bytes
- `VALUES` is also an array of 2,231 32-bit structs, so that's 8,924 bytes

<p><aside class="note">

Note: The `VALUES` array does something pretty clever. As mentioned earlier, the largest mapped first code point requires 17 bits to encode, and the largest second code point is `U+FE00` so that needs 16 bits to encode. Therefore, to encode both code points directly you'd need at minimum 33 bits.

However, all mappings that have a first code point with a value &gt; the `u16` max also happen to be mappings that do not have a second code point. So, if you store all the mapped values encoded as [UTF-16](https://en.wikipedia.org/wiki/UTF-16), you *can* get away with using two 16-bit integers to store all the possible values (i.e. the &gt; `u16` max code points get stored as a surrogate pair, while all the other mappings get stored as two UTF-16 code units).

(this is not an improvement over how I store this data, but I thought it was still worth noting)

</aside></p>

So, in total, the Firefox implementation uses 40,167 bytes (<span class="token_semigood">39.23 KiB</span>) for its named character reference data, while Ladybird uses 24,412 bytes (<span class="token_addition">23.84 KiB</span>). That's a difference of 15,755 bytes (<span class="token_error">15.39 KiB</span>), or, in other words, the Ladybird implementation uses <span class="token_addition">60.8%</span> of the data size of the Firefox implementation.

<p><aside class="note">

Note: As mentioned previously, an additional 3,067 bytes (2.99 KiB) could be saved if the values array in the Ladybird implementation was bitpacked.

</aside></p>

#### Ease-of-use

Since, for the purposes of my benchmarking, the Firefox implementation was made to conform to the API of the `NamedCharacterReferenceMatcher` that is used in the Ladybird implementation, there's no meaningful difference in terms of ease-of-use.

However, I'll take this opportunity to talk about what changes were made to make that happen and how the real Firefox implementation differs.

- The [real Firefox implementation](https://github.com/mozilla-firefox/firefox/blob/ec7f9e0771ff44a5d22cfa26f4a819b739ef027b/parser/html/nsHtml5Tokenizer.cpp#L2036-L2233) uses 3 different tokenizer states and multiple complicated loops with `goto` statements to move between them
- The [`NamedCharacterReferenceMatcher` version](https://github.com/squeek502/ladybird/blob/1a2a2774a251782f22eb6f1597ee743adf856db7/Libraries/LibWeb/HTML/Parser/Entities.cpp#L84-L148) moves the tokenizer states into the `Matcher` and replaces the complicated loops with 2 simple loops

Very crudely approximated, the implementation went from ~200 SLoC to ~110 SLoC. So, the `NamedCharacterReferenceMatcher` abstraction may represent a marginal improvement in terms of ease-of-use.

#### Summary

Overall, the Firefox implementation fares quite well in this comparison.

- It's at least as fast, with some potential performance benefits and some potential weaknesses
- It uses more data to store the named character reference mappings, but saving 15 KiB might not be much of a concern
- The implementation is a fair bit more complicated, but not necessarily in a meaningful way

### Comparison with Blink/WebKit (Chrome/Safari)

<div style="float:right; margin-top: -2rem; margin-left: 1em;"><img alt="Chromium logo" style="max-width: 64px;" src="/images/better-named-character-reference-tokenization/chromium.png" /> <img alt="WebKit logo (Safari's engine)" style="max-width: 64px;" src="/images/better-named-character-reference-tokenization/webkit.svg" /></div>

[Blink](https://www.chromium.org/blink/) (the browser engine of Chrome/Chromium) started as a fork of [WebKit](https://webkit.org/) (the browser engine of Safari), which itself started as a fork of [KHTML](https://en.wikipedia.org/wiki/KHTML). There are some differences that have emerged between the two since Blink was forked from WebKit, but for the purposes of this article I'm only going to benchmark against the Blink implementation and assume the results would be roughly the same for the WebKit implementation (the difference mostly comes down to data size, which I'll mention in the "*Data size*" section later).

<p><aside class="note">

Note: I'll double check that the Safari implementation has the same performance characteristics and update this article with my findings once I do.

</aside></p>

Like Firefox, the Chrome/Safari named character reference tokenization does not use a trie. For the 'matching' portion, the Chrome/Safari implementation is actually quite similar in concept to the Firefox implementation:

- Use the first character to lookup the initial range of possible matches within a sorted array of all named character references [[src](https://github.com/chromium/chromium/blob/f7116e9d191f673257ca706d3bc998dd468ab79f/third_party/blink/renderer/core/html/parser/html_entity_search.cc#L37-L38)]
- For each character after that, use [`std::ranges::equal_range`](https://en.cppreference.com/w/cpp/algorithm/ranges/equal_range) to narrow the possibilities within the current range (`std::ranges::equal_range` uses binary searches to get both the [`std::ranges::lower_bound`](https://en.cppreference.com/w/cpp/algorithm/ranges/lower_bound) and [`std::ranges::upper_bound`](https://en.cppreference.com/w/cpp/algorithm/ranges/upper_bound)) [[src](https://github.com/chromium/chromium/blob/f7116e9d191f673257ca706d3bc998dd468ab79f/third_party/blink/renderer/core/html/parser/html_entity_search.cc#L40-L52)]
- If the first possible match in the resulting range is the same length as the current number of characters being matched, mark it as the most recent match [[src](https://github.com/chromium/chromium/blob/f7116e9d191f673257ca706d3bc998dd468ab79f/third_party/blink/renderer/core/html/parser/html_entity_search.cc#L57-L61)]
- Continue until there are no more possible matches (the range is empty) [[src](https://github.com/chromium/chromium/blob/f7116e9d191f673257ca706d3bc998dd468ab79f/third_party/blink/renderer/core/html/parser/html_entity_search.cc#L54-L56)]

The main differences from the Firefox implementation are that the Chrome/Safari version (a) only uses the first character to narrow the initial possible matches, and (b) uses binary searches to narrow the possibilities after that instead of linearly moving the `lo` and `hi` indexes.

#### Performance

Similar to Firefox, the performance difference in the 'tens of thousands of valid and invalid named character references' benchmark is basically a wash:

```poopresults
Benchmark 1 (88 runs): ./BenchHTMLTokenizer blink
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           115ms ±  943us     113ms …  117ms          0 ( 0%)        0%
  peak_rss           83.3MB ± 99.6KB    83.0MB … 83.5MB          2 ( 2%)        0%
  cpu_cycles          232M  ±  754K      230M  …  234M           0 ( 0%)        0%
  instructions        461M  ± 4.73K      461M  …  461M           0 ( 0%)        0%
  cache_references   9.95M  ±  299K     9.71M  … 12.3M           6 ( 7%)        0%
  cache_misses        412K  ± 5.68K      401K  …  425K           0 ( 0%)        0%
  branch_misses       747K  ± 1.78K      744K  …  757K           2 ( 2%)        0%
Benchmark 2 (88 runs): ./BenchHTMLTokenizer dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           114ms ± 1.26ms     110ms …  117ms          1 ( 1%)          -  0.6% ±  0.3%
  peak_rss           83.3MB ± 77.5KB    83.1MB … 83.5MB          0 ( 0%)          +  0.0% ±  0.0%
  cpu_cycles          228M  ±  882K      227M  …  233M           5 ( 6%)        ⚡-  1.4% ±  0.1%
  instructions        450M  ± 7.33K      450M  …  450M           4 ( 5%)        ⚡-  2.4% ±  0.0%
  cache_references   9.48M  ±  402K     9.29M  … 13.1M           8 ( 9%)        ⚡-  4.7% ±  1.1%
  cache_misses        412K  ± 7.21K      398K  …  432K           0 ( 0%)          -  0.0% ±  0.5%
  branch_misses       575K  ± 6.48K      571K  …  633K           6 ( 7%)        ⚡- 23.0% ±  0.2%
```

The DAFSA is faster than Chrome in the all-`&supsetneqq;` benchmark, but the difference is not as big as it was with Firefox, since Chrome uses binary searches to narrow down the possible matches whereas Firefox uses linear scans:

```poopresults
Benchmark 1 (211 runs): ./BenchHTMLTokenizer blink gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          47.3ms ±  782us    45.0ms … 49.6ms         19 ( 9%)        0%
  peak_rss           53.0MB ± 94.4KB    52.7MB … 53.2MB          2 ( 1%)        0%
  cpu_cycles          123M  ±  807K      122M  …  126M           4 ( 2%)        0%
  instructions        290M  ± 7.46K      290M  …  290M          17 ( 8%)        0%
  cache_references   3.31M  ±  200K     3.19M  … 5.79M           7 ( 3%)        0%
  cache_misses        358K  ± 8.15K      345K  …  401K           1 ( 0%)        0%
  branch_misses       182K  ± 1.82K      178K  …  194K           3 ( 1%)        0%
Benchmark 2 (218 runs): ./BenchHTMLTokenizer dafsa gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          45.9ms ±  663us    43.6ms … 47.3ms         11 ( 5%)        ⚡-  3.0% ±  0.3%
  peak_rss           53.0MB ± 82.6KB    52.7MB … 53.2MB          1 ( 0%)          +  0.1% ±  0.0%
  cpu_cycles          117M  ±  677K      116M  …  120M           4 ( 2%)        ⚡-  5.0% ±  0.1%
  instructions        259M  ± 7.78K      259M  …  259M           9 ( 4%)        ⚡- 10.8% ±  0.0%
  cache_references   3.26M  ± 99.4K     3.17M  … 4.00M          18 ( 8%)          -  1.4% ±  0.9%
  cache_misses        358K  ± 8.14K      342K  …  386K           8 ( 4%)          -  0.2% ±  0.4%
  branch_misses       183K  ± 3.07K      179K  …  214K          17 ( 8%)          +  0.9% ±  0.3%
```

The DAFSA is once again worse at detecting `&cz` as invalid, and the results are similar to what they were with Firefox:

```poopresults
Benchmark 1 (160 runs): ./BenchHTMLTokenizer blink ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          62.6ms ± 1.08ms    60.6ms … 64.3ms          0 ( 0%)        0%
  peak_rss           65.1MB ± 79.4KB    64.8MB … 65.2MB          1 ( 1%)        0%
  cpu_cycles          108M  ±  640K      107M  …  111M           3 ( 2%)        0%
  instructions        203M  ± 11.3K      203M  …  203M           7 ( 4%)        0%
  cache_references   5.92M  ± 51.5K     5.82M  … 6.30M          10 ( 6%)        0%
  cache_misses        384K  ± 8.88K      366K  …  409K           0 ( 0%)        0%
  branch_misses       164K  ± 1.44K      160K  …  169K           2 ( 1%)        0%
Benchmark 2 (157 runs): ./BenchHTMLTokenizer dafsa ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          63.9ms ± 1.10ms    61.8ms … 65.5ms          0 ( 0%)        💩+  2.0% ±  0.4%
  peak_rss           65.1MB ± 92.8KB    64.8MB … 65.2MB          4 ( 3%)          -  0.0% ±  0.0%
  cpu_cycles          113M  ±  707K      112M  …  117M           1 ( 1%)        💩+  4.4% ±  0.1%
  instructions        214M  ± 10.9K      214M  …  214M           7 ( 4%)        💩+  5.6% ±  0.0%
  cache_references   5.89M  ± 63.4K     5.76M  … 6.31M           5 ( 3%)          -  0.5% ±  0.2%
  cache_misses        387K  ± 9.20K      367K  …  412K           2 ( 1%)          +  0.7% ±  0.5%
  branch_misses       165K  ± 2.77K      162K  …  197K           5 ( 3%)          +  0.6% ±  0.3%
```

For the '30,000 valid named character references' benchmark, the DAFSA is *slightly* faster (similar results as Firefox):

```poopresults
Benchmark 1 (228 runs): ./BenchHTMLTokenizer blink all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.9ms ±  844us    41.7ms … 47.0ms         21 ( 9%)        0%
  peak_rss           54.3MB ± 89.2KB    54.0MB … 54.5MB          2 ( 1%)        0%
  cpu_cycles          105M  ±  959K      104M  …  112M           5 ( 2%)        0%
  instructions        204M  ± 6.18K      204M  …  204M           7 ( 3%)        0%
  cache_references   3.78M  ±  137K     3.67M  … 5.37M          13 ( 6%)        0%
  cache_misses        359K  ± 11.2K      345K  …  457K          13 ( 6%)        0%
  branch_misses       466K  ± 1.43K      463K  …  472K           4 ( 2%)        0%
Benchmark 2 (232 runs): ./BenchHTMLTokenizer dafsa all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.1ms ±  592us    41.1ms … 44.3ms         13 ( 6%)        ⚡-  1.8% ±  0.3%
  peak_rss           54.4MB ± 79.6KB    54.1MB … 54.5MB          0 ( 0%)          +  0.0% ±  0.0%
  cpu_cycles          102M  ±  487K      101M  …  104M           2 ( 1%)        ⚡-  3.3% ±  0.1%
  instructions        191M  ± 5.33K      191M  …  191M           4 ( 2%)        ⚡-  6.0% ±  0.0%
  cache_references   3.55M  ± 74.9K     3.46M  … 4.21M          10 ( 4%)        ⚡-  6.3% ±  0.5%
  cache_misses        355K  ± 5.67K      344K  …  373K           2 ( 1%)          -  1.0% ±  0.5%
  branch_misses       345K  ± 2.12K      342K  …  374K           2 ( 1%)        ⚡- 26.0% ±  0.1%
```

In the raw matching speed benchmark, the DAFSA comes out ahead:

```poopresults
Benchmark 1 (70 runs): ./BenchHTMLTokenizerBlink
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           144ms ± 1.33ms     141ms …  148ms          1 ( 1%)        0%
  peak_rss           4.55MB ± 65.8KB    4.33MB … 4.72MB          0 ( 0%)        0%
  cpu_cycles          590M  ± 2.33M      585M  …  604M           4 ( 6%)        0%
  instructions       1.07G  ± 83.4      1.07G  … 1.07G           0 ( 0%)        0%
  cache_references   12.3M  ±  162K     12.1M  … 13.0M           6 ( 9%)        0%
  cache_misses       27.6K  ± 5.79K     21.1K  … 67.6K           2 ( 3%)        0%
  branch_misses      8.71M  ± 21.1K     8.68M  … 8.79M           1 ( 1%)        0%
Benchmark 2 (85 runs): ./BenchMatcherDafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           119ms ± 1.47ms     116ms …  122ms          0 ( 0%)        ⚡- 17.6% ±  0.3%
  peak_rss           4.52MB ± 65.7KB    4.46MB … 4.59MB          0 ( 0%)          -  0.8% ±  0.5%
  cpu_cycles          484M  ± 4.33M      477M  …  496M           0 ( 0%)        ⚡- 17.8% ±  0.2%
  instructions       1.02G  ± 80.6      1.02G  … 1.02G           0 ( 0%)        ⚡-  4.4% ±  0.0%
  cache_references   6.10M  ±  177K     5.99M  … 7.66M           2 ( 2%)        ⚡- 50.5% ±  0.4%
  cache_misses       25.4K  ± 3.42K     20.4K  … 38.8K           4 ( 5%)        ⚡-  7.9% ±  5.3%
  branch_misses      6.02M  ± 21.7K     5.98M  … 6.06M           0 ( 0%)        ⚡- 30.9% ±  0.1%
```

#### Data size

The Chrome implementation uses four arrays:

- `kStaticEntityStringStorage`, an array of all the bytes in every named character reference, with some de-duplication techniques (e.g. the sequence `'b', 'n', 'o', 't', ';'` in the array is used for `&bnot;`, `&not;`, and `&not`). It uses 14,485 bytes total.
- `kStaticEntityTable`, an array of 2,231 12-byte wide structs containing information about each named character reference (its location in the `kStaticEntityStringStorage` array, the length of its name, the code point(s) it should be transformed into). It uses 26,722 bytes.
- `kUppercaseOffset` and `kLowercaseOffset` are each arrays of offsets into `kStaticEntityTable`, and both are used as lookup tables for the first character. Getting `kUppercaseOffset[char - 'A']` gives you the initial lower bound's offset and `kUppercaseOffset[char - 'A' + 1]` gives you the initial upper bound's offset (and the same sort of thing for `kLowercaseOffset`). Each uses 54 bytes, so that's 108 bytes total.

All together, the Chrome implementation uses 41,167 bytes (<span class="token_semigood">40.39 KiB</span>) for its named character reference data, while Ladybird uses 24,412 bytes (<span class="token_addition">23.84 KiB</span>). That's a difference of 16,953 bytes (<span class="token_error">16.56 KiB</span>), or <span class="token_addition">59.0%</span> of the data size of the Chrome implementation.

The Safari implementation uses the same four arrays, but [has made a few more data size optimizations](https://github.com/WebKit/WebKit/commit/3483dcf98d883183eb0621479ed8f19451533722):

- `kStaticEntityStringStorage` does not include semicolons, and instead that information was moved to a boolean flag within the elements of the `kStaticEntityTable` array. This brings down the total bytes used by this array to 11,127 (-3,358 compared to the Chrome version)
- The `HTMLEntityTableEntry` struct (used in the `kStaticEntityTable` array) was converted to [use a bitfield](https://github.com/WebKit/WebKit/blob/bde3bff51de25b231de2b22517438a911e2e8e3a/Source/WebCore/html/parser/HTMLEntityTable.h#L34-L43) to reduce the size of the struct from 12 bytes to 8 bytes (57 bits). However, Clang seems to insert padding bits into the `struct` which brings it back up to 12 bytes anyway (it wants to align the `optionalSecondCharacter` and `nameLengthExcludingSemicolon` fields). So, this data size optimization may or may not actually have an effect (I'm not very familiar with the rules around C++ bitfield padding, so I feel like I can't say anything definitive). If the size *is* reduced to 8 bytes, then `kStaticEntityTable` uses 8,924 less bytes (17,798 instead of 26,722).

So, the Safari implementation uses either 30,040 bytes (<span class="token_addition">29.34 KiB</span>) if `HTMLEntityTableEntry` uses 12 bytes, or 21,116 bytes (<span class="token_addition">20.62 KiB</span>) if `HTMLEntityTableEntry` uses 8 bytes. This means that Safari's data size optimizations (or at least their intended effect) makes its data size *smaller* than Ladybird's (even if the Ladybird implementation tightly bitpacked its values array, it'd still use 229 bytes more than the 8-byte-`HTMLEntityTableEntry` Safari version). This also shows that the larger data size of the Chrome implementation is not inherent to the approach that it uses.

#### Ease-of-use

For now I'll just say there's no meaningful difference, but there's a caveat that will be discussed later.

#### Summary

Overall, the Chrome implementation as-it-is-now fares about as well as the Firefox implementation in this comparison, but has some potential strengths/weaknesses of its own. That is, it covers one weakness of the Firefox implementation by using binary searches instead of linear scans, but it always has to narrow down the possibilities from a larger initial range (since it only uses the first character to get the range of possible matches whereas Firefox uses the first two characters).

The Safari version fares much better in terms of data size (potentially beating out my DAFSA version), and its size optimizations could be applied to the Chrome version as well since the core approach is the same between them.

At this point, though, you might be asking yourself, why don't we try...

## Combining Firefox, Chrome, and Safari together

In theory, the best ideas from the Firefox and Chrome/Safari implementations could be combined into one new implementation:

- Use the combination of the first two characters to get the initial range of possible matches (like Firefox)
- Use binary searches to narrow down the possible matches (like Chrome/Safari)
- Don't store the first two characters in the `kStaticEntityStringStorage`/`ALL_NAMES` array (like Firefox)
- Re-use indexes into `kStaticEntityStringStorage`/`ALL_NAMES` when possible (like Chrome/Safari, see the `&bnot;`/`&not;`/`&not` example above)
- Don't store semicolons in the `kStaticEntityStringStorage`/`ALL_NAMES` array (like Safari)
- Reduce the size of the `HTMLEntityTableEntry`/`nsHtml5CharacterName` struct (like Safari intends to do)

I haven't tested this combination to see how exactly it stacks up, but I would assume it'd be quite good overall.

## Something I didn't mention about the Chrome implementation

Since I converted the Chrome implementation to use Ladybird's `NamedCharacterReferenceMacher` API in an effort to improve the accuracy of my benchmarking, one major aspect of the Chrome implementation was lost in translation: the Chrome implementation doesn't actually use the character-by-character tokenization strategy we've discussed so far.

Instead, it uses the "lookahead (but never beyond an insertion point) until we're certain we have enough characters ..." strategy mentioned back in the [*Named character reference tokenization overview*](#what-this-all-means-implementation-wise). The very high-level summary of the approach (as it is actually implemented in Chrome) is very similar to the description of it in that section:

- Starting after the ampersand, lookahead as far as possible without looking beyond the end of an insertion point
- Try to match a full named character reference
- If you run out of characters because you hit the end of an insertion point while matching, backtrack and try again on the next tokenizer iteration (always starting the lookahead from just after the ampersand, i.e. no state is saved between attempts)

<p><aside class="note">

Note: It's only possible to 'run out of characters while matching' when there is an active insertion point. If there isn't one (the common case), then this difference in strategy doesn't matter since 'backtrack and try again' will never come into play.

Note also that this strategy doesn't inherently require any particular implementation for the 'try to match a full named character reference' part; a trie, or a DAFSA, or Firefox's `HILO_ACCEL` implementation, or any other approach could be slotted in there with no change in functionality.

</aside></p>

The downside of the Chrome implementation in particular is actually a choice that was made that's not inherent to the overall approach: they don't preserve any matching state between tokenizer iterations and always backtrack to the `&` before trying to match again. For example, when matching against something like `&notin;` that's being written one-character-at-a-time (via `document.write`), the matching algorithm described in the "*[Comparison with Blink/WebKit (Chrome/Safari)](#comparison-with-blink-webkit-chrome-safari)*" section will be executed for each of:

- `&n`, `&no`, `&not`, `&noti`, and `&notin`, each resulting in the 'not enough characters' flag being set
- Finally, `&notin;` will be matched fully (the semicolon acts as a definitive delimiter)

In theory, the redundant work that's performed in these sorts of scenarios should have a noticeable effect on performance, but, in practice, I wasn't able to prove that out with benchmarking.

<details class="box-border" style="padding: 1em;">
<summary>Details and results of my benchmarking</summary>

- [The test file](https://gist.github.com/squeek502/29ec1404b54cff461d6fe47d539009ed) (inserting lots of valid named character references one-character-at-a-time using `document.write`)
- [The branch containing the code under test](https://github.com/squeek502/ladybird/tree/blink-preserve-state) (a faithful adaptation of Blink's lookahead strategy and a runtime flag to switch to an implementation that preserves matching state between retry attempts due to 'not enough characters')

```poopresults
Benchmark 1 (14 runs): ./headless-browser --dump-text pathological-write-valid.html
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.46s  ± 8.11ms    1.45s  … 1.48s           0 ( 0%)        0%
  peak_rss           62.1MB ±  123KB    61.9MB … 62.3MB          0 ( 0%)        0%
  cpu_cycles         5.90G  ± 33.5M     5.88G  … 5.99G           1 ( 7%)        0%
  instructions       29.1G  ±  562K     29.1G  … 29.1G           1 ( 7%)        0%
  cache_references    210M  ±  988K      208M  …  211M           0 ( 0%)        0%
  cache_misses       8.53M  ±  322K     7.92M  … 9.09M           0 ( 0%)        0%
  branch_misses      5.03M  ± 19.2K     5.01M  … 5.07M           0 ( 0%)        0%
Benchmark 2 (14 runs): ./headless-browser --blink-preserve-state --dump-text pathological-write-valid.html
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.46s  ± 4.52ms    1.45s  … 1.47s           0 ( 0%)          -  0.3% ±  0.3%
  peak_rss           62.0MB ±  164KB    61.7MB … 62.4MB          0 ( 0%)          -  0.1% ±  0.2%
  cpu_cycles         5.88G  ± 18.1M     5.86G  … 5.93G           0 ( 0%)          -  0.3% ±  0.4%
  instructions       29.1G  ±  422K     29.1G  … 29.1G           0 ( 0%)          -  0.1% ±  0.0%
  cache_references    209M  ± 1.26M      207M  …  212M           1 ( 7%)          -  0.5% ±  0.4%
  cache_misses       8.55M  ±  425K     8.19M  … 9.78M           1 ( 7%)          +  0.3% ±  3.4%
  branch_misses      5.00M  ± 27.0K     4.97M  … 5.07M           0 ( 0%)          -  0.6% ±  0.4%
```

</details>

So, despite `HTMLEntitySearch::Advance` being called 4.5x more in the 'no state preserved' benchmark, no difference shows up in the results. I believe this is because the actual matching is a small part of the work being done in this benchmark, or, in other words, there *is* a difference but it's being drowned out by all the work being done elsewhere (JavaScript being run, tokenizer input being updated, etc). I have a hunch that Ladybird in particular might be greatly exacerbating this effect and making all this tangential work slower than it theoretically needs to be, especially in the case of updating the tokenizer input. For example, Chrome uses a [rope](https://en.wikipedia.org/wiki/Rope_(data_structure))-like [SegmentedString](https://github.com/chromium/chromium/blob/f7116e9d191f673257ca706d3bc998dd468ab79f/third_party/blink/renderer/platform/text/segmented_string.h) to mitigate the cost of inserting into the middle of the input, while Ladybird currently [reallocates the entire modified input on each insertion](https://github.com/LadybirdBrowser/ladybird/blob/3171d5763959b1a597f65d0be3a34a5ade40d789/Libraries/LibWeb/HTML/Parser/HTMLTokenizer.cpp#L2874-L2894).

To sum up what I'm trying to say:

- The Chrome implementation demonstrably does more work than necessary in the '`document.write` one-character-at-a-time' scenario because it doesn't preserve matching state between retries due to 'not enough characters'
- I am unable to create a relevant benchmark using Ladybird, likely due to some inefficiencies in the Ladybird tokenizer implementation, but a clear difference might show up when benchmarking the Chrome tokenizer itself (i.e. if you made the Chrome implementation preserve state in this scenario and benchmarked its tokenizer, I expect it might show *some* measurable difference)

This is important to note because it is the reason I included the following point in my 'list of things you'll need to trust in order for my benchmarking to be accurate' in the intro to the ["*Comparison to the major browser engines*"](#comparison-to-the-major-browser-engines) section:

> - The performance characteristics exhibited would hold when going the other direction (putting my implementation into their tokenizer)

That is, I have some reason to believe 'going the other direction' may actually be slightly *more* favorable to my DAFSA implementation, as all the code *outside* of the named character reference tokenization state itself likely will do less that will muddy benchmarking results.

### A benefit of the 'lookahead' strategy

An upside of the 'lookahead' strategy is that, when you know there's no active insertion point, you can *always* match against the full remaining input in one go. This is potentially an improvement over the 'tokenize-one-character-at-a-time' strategy if there is any significant amount of work that's done between tokenizer iterations. Here's some simple diagrams to illustrate the point:

<div class="two-column-collapse" style="grid-gap: 1em;">
<div style="text-align:center; padding-bottom: 1em;" class="box-border">
<svg aria-roledescription="flowchart-v2" role="graphics-document document" class="mermaid-flowchart flowchart" xmlns="http://www.w3.org/2000/svg" width="100%" id="graph-2642" style="max-width: 350px;" viewBox="100 125 400 600" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events"><g id="viewport-20250626001053133" class="svg-pan-zoom_viewport" transform="matrix(1.048317551612854,0,0,1.048317551612854,185.09927368164062,151.5854949951172)" style="transform: matrix(1.04832, 0, 0, 1.04832, 185.099, 151.586);"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2642_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2642_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2642_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2642_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2642_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2642_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-2642_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_A_B_0" d="M108,62L108,70.167C108,78.333,108,94.667,108,110.333C108,126,108,141,108,148.5L108,156"></path><path marker-end="url(#graph-2642_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_B_C_0" d="M108,214L108,222.167C108,230.333,108,246.667,108,262.333C108,278,108,293,108,300.5L108,308"></path><path marker-end="url(#graph-2642_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_C_D_0" d="M108,366L108,374.167C108,382.333,108,398.667,108,414.333C108,430,108,445,108,452.5L108,460"></path></g><g class="edgeLabels"><g transform="translate(108, 111)" class="edgeLabel"><g transform="translate(-100, -24)" class="label"><foreignObject height="48" width="200"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table; white-space: break-spaces; line-height: 1.5; max-width: 200px; text-align: center; width: 200px;"><span class="edgeLabel noRadius"><p>work done to move to the next character</p></span></div></foreignObject></g></g><g transform="translate(108, 263)" class="edgeLabel"><g transform="translate(-100, -24)" class="label"><foreignObject height="48" width="200"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table; white-space: break-spaces; line-height: 1.5; max-width: 200px; text-align: center; width: 200px;"><span class="edgeLabel noRadius"><p>work done to move to the next character</p></span></div></foreignObject></g></g><g transform="translate(108, 415)" class="edgeLabel"><g transform="translate(-100, -24)" class="label"><foreignObject height="48" width="200"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table; white-space: break-spaces; line-height: 1.5; max-width: 200px; text-align: center; width: 200px;"><span class="edgeLabel noRadius"><p>work done to move to the next character</p></span></div></foreignObject></g></g></g><g class="nodes"><g transform="translate(108, 35)" id="flowchart-A-0" class="node default"><rect height="54" width="68.89999389648438" y="-27" x="-34.44999694824219" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>a</p></span></div></foreignObject></g></g><g transform="translate(108, 187)" id="flowchart-B-1" class="node default"><rect height="54" width="68.89999389648438" y="-27" x="-34.44999694824219" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>b</p></span></div></foreignObject></g></g><g transform="translate(108, 339)" id="flowchart-C-3" class="node default"><rect height="54" width="64.44999694824219" y="-27" x="-32.224998474121094" style="" class="basic label-container"></rect><g transform="translate(-2.2249984741210938, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>c</p></span></div></foreignObject></g></g><g transform="translate(108, 491)" id="flowchart-D-5" class="node default"><rect height="54" width="73.35000610351562" y="-27" x="-36.67500305175781" style="" class="basic label-container"></rect><g transform="translate(-6.6750030517578125, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="13.350006103515625"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>...</p></span></div></foreignObject></g></g></g></g></g></g></svg>
<div><i class="caption">When using the 'character-by-character' approach, any work that's done to move the input cursor is repeated before each character is matched against</i></div>
</div>

<div style="text-align:center; padding-bottom: 1em;" class="box-border">
<svg aria-roledescription="flowchart-v2" role="graphics-document document" class="mermaid-flowchart flowchart" xmlns="http://www.w3.org/2000/svg" width="100%" id="graph-2080" style="max-width: 300px;" viewBox="290 25 600 850" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events"><g id="viewport-20250625235739215" class="svg-pan-zoom_viewport" transform="matrix(1.839534878730774,0,0,1.839534878730774,388.2588806152344,56.50001907348633)" style="transform: matrix(1.83953, 0, 0, 1.83953, 388.259, 56.5);"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2080_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2080_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2080_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2080_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2080_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2080_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-2080_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_A_B_0" d="M108,62L108,66.167C108,70.333,108,78.667,108,86.333C108,94,108,101,108,104.5L108,108"></path><path marker-end="url(#graph-2080_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_B_C_0" d="M108,166L108,170.167C108,174.333,108,182.667,108,190.333C108,198,108,205,108,208.5L108,212"></path><path marker-end="url(#graph-2080_flowchart-v2-pointEnd)" style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_C_D_0" d="M108,270L108,278.167C108,286.333,108,302.667,108,318.333C108,334,108,349,108,356.5L108,364"></path></g><g class="edgeLabels"><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g transform="translate(108, 319)" class="edgeLabel"><g transform="translate(-100, -24)" class="label"><foreignObject height="48" width="200"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table; white-space: break-spaces; line-height: 1.5; max-width: 200px; text-align: center; width: 200px;"><span class="edgeLabel noRadius"><p>work done to skip to the end of the match</p></span></div></foreignObject></g></g></g><g class="nodes"><g transform="translate(108, 35)" id="flowchart-A-0" class="node default"><rect height="54" width="68.89999389648438" y="-27" x="-34.44999694824219" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>a</p></span></div></foreignObject></g></g><g transform="translate(108, 139)" id="flowchart-B-1" class="node default"><rect height="54" width="68.89999389648438" y="-27" x="-34.44999694824219" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>b</p></span></div></foreignObject></g></g><g transform="translate(108, 243)" id="flowchart-C-3" class="node default"><rect height="54" width="64.44999694824219" y="-27" x="-32.224998474121094" style="" class="basic label-container"></rect><g transform="translate(-2.2249984741210938, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="12.4499969482421875"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>c</p></span></div></foreignObject></g></g><g transform="translate(108, 395)" id="flowchart-D-5" class="node default"><rect height="54" width="73.35000610351562" y="-27" x="-36.67500305175781" style="" class="basic label-container"></rect><g transform="translate(-6.6750030517578125, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="13.350006103515625"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>...</p></span></div></foreignObject></g></g></g></g></g></g></svg>
<div><i class="caption">When using the 'lookahead' approach, matching happens in a tight loop and any work done to move the input cursor only happens once, after the matching is complete</i></div>
</div>
</div>

There are two theoretical benefits I can think of with this:

- Avoiding the work done between each character may lead to better CPU cache usage/branch prediction
- Moving the cursor ahead by `N` in one go may be more efficient than moving it ahead by one, `N` times

Luckily, we don't actually need to change much about our 'character-by-character tokenization' approach to get these benefits, as we only need to make it so we use lookahead whenever there's no active insertion point. In Ladybird, that might look something like this ([full implementation](https://github.com/squeek502/ladybird/blob/1a2a2774a251782f22eb6f1597ee743adf856db7/Libraries/LibWeb/HTML/Parser/HTMLTokenizer.cpp#L1703-L1731)):

```c
BEGIN_STATE(NamedCharacterReference)
{
    if (stop_at_insertion_point == StopAtInsertionPoint::No) {
        // Use the 'lookahead' approach without needing to worry about insertion points
    } else {
        // Use the character-by-character tokenization approach
    }

    // ...
}
```

In practice, this seems to give up to a 1.13x speedup in our Ladybird benchmarks essentially for free:

<details class="box-border" style="padding: 1em;">
<summary>Benchmark results</summary>

```poopresults
Benchmark 1 (44 runs): ./BenchHTMLTokenizer dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           114ms ±  934us     112ms …  115ms          3 ( 7%)        0%
  peak_rss           83.5MB ± 74.9KB    83.3MB … 83.6MB          0 ( 0%)        0%
  cpu_cycles          226M  ±  964K      223M  …  229M           2 ( 5%)        0%
  instructions        452M  ± 6.81K      452M  …  452M           0 ( 0%)        0%
  cache_references   9.64M  ± 86.1K     9.51M  … 9.86M           4 ( 9%)        0%
  cache_misses        418K  ± 10.5K      399K  …  448K           3 ( 7%)        0%
  branch_misses       573K  ± 2.51K      570K  …  584K           3 ( 7%)        0%
Benchmark 2 (47 runs): ./BenchHTMLTokenizer dafsa-lookahead
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           108ms ± 1.05ms     106ms …  111ms          0 ( 0%)        ⚡-  5.1% ±  0.4%
  peak_rss           83.5MB ± 81.5KB    83.3MB … 83.6MB          0 ( 0%)          -  0.0% ±  0.0%
  cpu_cycles          203M  ±  869K      201M  …  205M           0 ( 0%)        ⚡- 10.5% ±  0.2%
  instructions        377M  ± 10.8K      377M  …  377M           1 ( 2%)        ⚡- 16.6% ±  0.0%
  cache_references   9.57M  ± 71.3K     9.42M  … 9.77M           1 ( 2%)          -  0.7% ±  0.3%
  cache_misses        415K  ± 7.59K      401K  …  429K           0 ( 0%)          -  0.7% ±  0.9%
  branch_misses       553K  ± 2.04K      547K  …  556K           0 ( 0%)        ⚡-  3.5% ±  0.2%
```

```poopresults
Benchmark 1 (109 runs): ./BenchHTMLTokenizer dafsa gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          45.8ms ±  866us    43.7ms … 47.2ms         11 (10%)        0%
  peak_rss           53.2MB ± 67.6KB    53.0MB … 53.4MB         29 (27%)        0%
  cpu_cycles          117M  ±  601K      116M  …  118M           3 ( 3%)        0%
  instructions        261M  ± 6.10K      261M  …  261M           2 ( 2%)        0%
  cache_references   3.27M  ± 62.6K     3.19M  … 3.69M           4 ( 4%)        0%
  cache_misses        354K  ± 4.17K      345K  …  368K           2 ( 2%)        0%
  branch_misses       182K  ± 4.28K      178K  …  213K          10 ( 9%)        0%
Benchmark 2 (124 runs): ./BenchHTMLTokenizer dafsa-lookahead gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          40.4ms ±  756us    38.3ms … 42.0ms         13 (10%)        ⚡- 11.8% ±  0.5%
  peak_rss           53.2MB ± 77.2KB    52.9MB … 53.4MB         40 (32%)          +  0.0% ±  0.0%
  cpu_cycles         93.4M  ±  546K     92.5M  … 95.8M           3 ( 2%)        ⚡- 19.9% ±  0.1%
  instructions        190M  ± 5.41K      190M  …  190M           3 ( 2%)        ⚡- 27.1% ±  0.0%
  cache_references   3.31M  ± 42.2K     3.23M  … 3.48M           3 ( 2%)          +  1.4% ±  0.4%
  cache_misses        354K  ± 5.07K      345K  …  372K           5 ( 4%)          -  0.1% ±  0.3%
  branch_misses       153K  ± 10.5K      146K  …  215K          17 (14%)        ⚡- 16.1% ±  1.2%
```

```poopresults
Benchmark 1 (79 runs): ./BenchHTMLTokenizer dafsa ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          63.2ms ±  964us    61.6ms … 65.7ms          0 ( 0%)        0%
  peak_rss           65.3MB ± 79.1KB    65.0MB … 65.4MB          0 ( 0%)        0%
  cpu_cycles          112M  ±  606K      111M  …  115M           2 ( 3%)        0%
  instructions        215M  ± 8.83K      215M  …  215M           0 ( 0%)        0%
  cache_references   5.91M  ±  107K     5.78M  … 6.50M           1 ( 1%)        0%
  cache_misses        372K  ± 4.43K      363K  …  390K           2 ( 3%)        0%
  branch_misses       162K  ± 1.17K      160K  …  165K           0 ( 0%)        0%
Benchmark 2 (80 runs): ./BenchHTMLTokenizer dafsa-lookahead ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          62.8ms ± 1.08ms    61.3ms … 64.3ms          0 ( 0%)          -  0.6% ±  0.5%
  peak_rss           65.2MB ± 88.6KB    64.9MB … 65.4MB          1 ( 1%)          -  0.0% ±  0.0%
  cpu_cycles          111M  ±  454K      110M  …  112M           0 ( 0%)        ⚡-  1.4% ±  0.1%
  instructions        209M  ± 7.60K      209M  …  209M           2 ( 3%)        ⚡-  2.7% ±  0.0%
  cache_references   5.91M  ± 68.1K     5.78M  … 6.09M           5 ( 6%)          -  0.1% ±  0.5%
  cache_misses        374K  ± 5.24K      365K  …  397K           1 ( 1%)          +  0.6% ±  0.4%
  branch_misses       164K  ±  964       162K  …  168K           1 ( 1%)          +  1.0% ±  0.2%
```

```poopresults
Benchmark 1 (115 runs): ./BenchHTMLTokenizer dafsa all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.3ms ±  843us    40.9ms … 45.6ms          6 ( 5%)        0%
  peak_rss           54.5MB ± 83.6KB    54.3MB … 54.6MB          1 ( 1%)        0%
  cpu_cycles          100M  ±  744K     98.4M  …  103M           2 ( 2%)        0%
  instructions        193M  ± 11.0K      193M  …  193M          12 (10%)        0%
  cache_references   3.58M  ± 40.3K     3.47M  … 3.70M           3 ( 3%)        0%
  cache_misses        363K  ± 11.3K      344K  …  398K           1 ( 1%)        0%
  branch_misses       344K  ± 1.99K      341K  …  349K           0 ( 0%)        0%
Benchmark 2 (127 runs): ./BenchHTMLTokenizer dafsa-lookahead all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          39.4ms ±  849us    37.2ms … 40.8ms         14 (11%)        ⚡-  9.0% ±  0.5%
  peak_rss           54.5MB ± 84.3KB    54.3MB … 54.6MB          1 ( 1%)          +  0.0% ±  0.0%
  cpu_cycles         84.8M  ±  521K     84.0M  … 87.4M           5 ( 4%)        ⚡- 15.5% ±  0.2%
  instructions        148M  ± 6.20K      148M  …  148M           7 ( 6%)        ⚡- 23.2% ±  0.0%
  cache_references   3.56M  ± 51.3K     3.47M  … 3.82M           4 ( 3%)          -  0.4% ±  0.3%
  cache_misses        356K  ± 7.44K      342K  …  384K           7 ( 6%)        ⚡-  2.0% ±  0.7%
  branch_misses       316K  ± 3.08K      313K  …  347K           3 ( 2%)        ⚡-  8.1% ±  0.2%
```

</details>

This also explains a few things that I glossed over or deferred until later throughout the article:

- It's the primary reason I made all the browsers' implementations conform to the `NamedCharacterReferenceMatcher` API and thereby converted them all to use the 'character-by-character tokenization' strategy (to rule out stuff like this from affecting the results without me realizing it).
- It's the reason that the inexplicable benchmark results at the start of the ["*On the difficulty of benchmarking*"](#on-the-difficulty-of-benchmarking) section showed the Chrome implementation being faster than the DAFSA implementation. I was using a faithful 1:1 port of the Chrome named character reference state at that point, and so the difference was due to the 'lookahead' strategy rather than the matching implementation.
- It's a partial explanation for why the results of the 'raw matching speed' benchmark (the one that just tests `NamedCharacterReferenceMatcher` directly without involving the tokenizer) don't fully translate to equivalent differences in the tokenizer benchmarks.

### Another difference I didn't mention

Something else that I've failed to mention until now regards exactly how backtracking is performed.

<p><aside class="note">

Note: This tangent on backtracking is not really related to anything else; I'm only mentioning it now because I had nowhere else to put it.

</aside></p>

In Ladybird, backtracking is very straightforward: modify the input cursor's position by subtracting `N` from the current position (where `N` is the number of overconsumed code points). This is safe to do from a code point boundary perspective because the input is always UTF-8 encoded, and named character reference matching will only ever consume ASCII characters, so going back `N` bytes is guaranteed to be equivalent to going back `N` code points.

In all the other major browsers, though, backtracking is done by re-inserting the overconsumed code points back into the input stream, at the position just after the current code point. That is, it modifies the input stream such that the next code points to-be-tokenized will be those that were just re-inserted.

As of now, I'm unsure if the way that Firefox/Chrome/Safari do it is *necessary* (and therefore whether or not Ladybird will need to adopt the same strategy to be fully compliant with the spec). If it *is* necessary, I'm either unaware of the relevant [web platform test](https://wpt.fyi/), or there is a missing web platform test that checks whatever it's necessary for. If it's not necessary, then there may be an opportunity in the other browser engines to simplify backtracking when dealing with named character references.

## Further improvements to the DAFSA implementation

As of the writing of this article, the DAFSA implementation that's been described so far is exactly what's in Ladybird. During the process of writing this, though, I came up with some ideas (largely inspired by the Firefox/Chrome/Safari implementations) to improve my implementation by utilizing every last possible bit I could get my hands on. This came in the form of two independent optimizations, with one of them just so happening to *barely* make the other possible.

<p><aside class="note">

Note: The code examples in this section will be using [Zig](https://www.ziglang.org/) syntax. 

</aside></p>

### 'First layer' acceleration

A property of named character references that I missed, but that the major browser engines all take advantage of, is that the first character of a named character reference is *always* within the range of `a-z` or `A-Z` (inclusive). In terms of the DAFSA, we can take advantage of this property to accelerate the search for the first character: instead of linearly scanning across the child nodes, we can:

- Check if the character is an alphabetic ASCII character, and immediately reject any that aren't
- Create a lookup table for alphabetic ASCII characters that has the resulting DAFSA state pre-computed

This would turn the `O(n)` search within the 'first layer' of the DAFSA into an `O(1)` lookup. As for what needs to be stored in the lookup table, remember that we build up a 'unique index' when traversing a list of children, with any child that we iterate over adding its `number` field to the total:

<div style="text-align: center;">
<svg width="100%" xmlns="http://www.w3.org/2000/svg" class="mermaid-flowchart flowchart" style="max-width: 200px;" viewBox="0 0 200 100" role="graphics-document document" aria-roledescription="flowchart-v2"><g><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-pointEnd"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker><marker orient="auto" markerHeight="8" markerWidth="8" markerUnits="userSpaceOnUse" refY="5" refX="4.5" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-pointStart"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 5 L 10 10 L 10 0 z"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="11" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-circleEnd"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5" refX="-1" viewBox="0 0 10 10" class="marker flowchart-v2" id="graph-2326_flowchart-v2-circleStart"><circle style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" r="5" cy="5" cx="5"></circle></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="12" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2326_flowchart-v2-crossEnd"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><marker orient="auto" markerHeight="11" markerWidth="11" markerUnits="userSpaceOnUse" refY="5.2" refX="-1" viewBox="0 0 11 11" class="marker cross flowchart-v2" id="graph-2326_flowchart-v2-crossStart"><path style="stroke-width: 2px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 1,1 l 9,9 M 10,1 l -9,9"></path></marker><g class="root"><g class="clusters"></g><g class="edgePaths"><path marker-end="url(#graph-2326_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_a_b_0" d="M44,68L53,68"></path><path marker-end="url(#graph-2326_flowchart-v2-pointEnd)" class="edge-thickness-normal edge-pattern-dotted flowchart-link" id="L_a_b_0" d="M93,68L102,68"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_a_0" d="M86.309,26.735L76.062,29.445C65.815,32.156,45.32,37.578,35.072,41.122C24.825,44.667,24.825,46.333,24.825,47.167L24.825,48"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_b_0" d="M89.878,30.303L87.144,32.419C84.41,34.535,78.943,38.768,76.209,41.717C73.475,44.667,73.475,46.333,73.475,47.167L73.475,48"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_c_0" d="M106.272,30.303L108.839,32.419C111.407,34.535,116.541,38.768,119.108,41.717C121.675,44.667,121.675,46.333,121.675,47.167L121.675,48"></path><path style="" class="edge-thickness-normal edge-pattern-solid edge-thickness-normal edge-pattern-solid flowchart-link" id="L_root_d_0" d="M109.825,26.75L119.833,29.459C129.841,32.167,149.858,37.583,159.867,41.125C169.875,44.667,169.875,46.333,169.875,47.167L169.875,48"></path></g><g class="edgeLabels"><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g><g class="edgeLabel"><g transform="translate(0, 0)" class="label"><foreignObject height="0" width="0"><div class="labelBkg" xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="edgeLabel"></span></div></foreignObject></g></g></g><g class="nodes"><g transform="translate(97.57498931884766, 23)" id="flowchart-root-0" class="node default"><polygon transform="translate(-15,15)" class="label-container" points="15,0 30,-15 15,-30 0,-15"></polygon><g transform="translate(0, 0)" style="" class="label"><rect></rect><foreignObject height="0" width="0"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"></span></div></foreignObject></g></g><g transform="translate(24.824996948242188, 67.5)" id="flowchart-a-1" class="node default iterated-node"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>a</p></span></div></foreignObject></g></g><g transform="translate(73.47499084472656, 67.5)" id="flowchart-b-2" class="node default iterated-node"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>b</p></span></div></foreignObject></g></g><g transform="translate(121.67498779296875, 67.5)" id="flowchart-c-3" class="node default selected-path"><rect height="39" width="32.75" y="-19.5" x="-16.375" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>c</p></span></div></foreignObject></g></g><g transform="translate(169.87498474121094, 67.5)" id="flowchart-d-4" class="node default"><rect height="39" width="33.649993896484375" y="-19.5" x="-16.824996948242188" ry="19.5" rx="19.5" style="" class="basic label-container"></rect><g transform="translate(-4.4499969482421875, -12)" style="" class="label"><rect></rect><foreignObject height="24" width="8.899993896484375"><div xmlns="http://www.w3.org/1999/xhtml" style="display: table-cell; white-space: nowrap; line-height: 1.5; max-width: 200px; text-align: center;"><span class="nodeLabel"><p>d</p></span></div></foreignObject></g></g></g></g></g></svg>
<div><i class="caption">The <code>number</code> field of the <code>a</code> and <code>b</code> nodes contribute to the unique index when searching for <code>c</code></i></div>
</div>

So, we can pre-compute the accumulated unique index that would result when matching a character in the 'first layer,' and then store that in the lookup table. For example, the relevant data for the first four nodes in the first layer of our DAFSA looks like this:

```zig
    .{ .char = 'A', .number = 27 },
    .{ .char = 'B', .number = 12 },
    .{ .char = 'C', .number = 36 },
    .{ .char = 'D', .number = 54 },
    // ...
```

so the corresponding lookup table entries could look like this:

```zig
    0,
    27,
    39, // 27 + 12
    75, // 27 + 12 + 36
    // ...
```

We can then use `char - 'A'` (for uppercase characters) to index into the lookup table and instantly get the final unique index that would have resulted from successfully searching for that character normally (for lowercase characters you'd get the index using `char - 'a' + 26` to allow for using a lookup array with exactly 52 values).

This change alone provides quite a big improvement to raw matching speed, since the 'first layer' represents the largest list of children in the DAFSA (by a significant margin):

```poopresults
Benchmark 1 (44 runs): ./bench-master
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           114ms ± 1.28ms     112ms …  116ms          0 ( 0%)        0%
  cpu_cycles          469M  ± 2.40M      466M  …  482M           5 (11%)        0%
  instructions        740M  ± 1.25       740M  …  740M           0 ( 0%)        0%
  cache_references   6.27M  ± 60.6K     6.14M  … 6.48M           1 ( 2%)        0%
  cache_misses       2.05K  ± 5.11K      979   … 34.8K           4 ( 9%)        0%
  branch_misses      5.69M  ± 13.0K     5.67M  … 5.75M           8 (18%)        0%
Benchmark 2 (74 runs): ./bench-first-layer-accel
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          68.1ms ± 1.26ms    66.6ms … 70.3ms          0 ( 0%)        ⚡- 40.2% ±  0.4%
  cpu_cycles          278M  ±  416K      277M  …  279M           3 ( 4%)        ⚡- 40.7% ±  0.1%
  instructions        385M  ± 1.42       385M  …  385M           0 ( 0%)        ⚡- 47.9% ±  0.0%
  cache_references   6.24M  ± 51.2K     6.14M  … 6.38M           1 ( 1%)          -  0.6% ±  0.3%
  cache_misses       1.38K  ±  346      1.02K  … 2.40K           0 ( 0%)          - 32.8% ± 57.4%
  branch_misses      4.79M  ± 4.33K     4.78M  … 4.80M           4 ( 5%)        ⚡- 15.9% ±  0.1%
```

### Linear scan &rarr; binary search

The second improvement is a theoretical one for now: what if we could take the time complexity of searching a list of children from `O(n)` to `O(log n)` by using a [binary search](https://en.wikipedia.org/wiki/Binary_search)? Let's think about what changes we'd need to make for that to be possible:

1. Every list of children would need to be sorted
2. We'd need a way to know the length of a list of children upfront (right now we'd have to iterate through them until we find one with the `last_sibling` flag set to know where a list of children ends)
3. We'd need a way to avoid needing to iterate a list of children to build up the unique index

For the first point, this is actually already the case&mdash;all lists of children *are* sorted (note: I'm unsure if this is a coincidental artifact of how I'm constructing my DAFSA, or if it's a common property of a DAFSA generally). For the second point, we could remove the `last_sibling` flag and replace it with a `children_len` field. For the third, we already have a model available for this with the lookup table approach we used for the first layer: we could just store an accumulated `number` in each `Node` struct instead of a per-node number.

<p><aside class="note">

Note: This is feasible because building the unique index does not actually rely on iterating over each node, we only need to know the cumulative result of the preceding siblings' `number` fields and the `end_of_word` flag of the matching node.

</aside></p>

#### The problem

The problem with all this is that there just aren't enough bits available to store all the information required. For context, here's the DAFSA `Node` representation being used currently:

```zig
const Node = packed struct(u32) {
    char: u8,
    number: u8,
    end_of_word: bool,
    last_sibling: bool,
    _extra: u2 = 0,
    first_child_index: u12,
};
```

Things to note:

- We *really* want to retain the 32-bit size
- We currently have 2 bits to spare (`_extra`)
- `number` and `first_child_index` are currently using the minimum bits required to encode their largest value

And we want to:

- Remove the `last_sibling` flag and replace it with a `children_len` field
    + The longest list of children has a length of 52 (the root node's children), but we can ignore that since we now use a lookup table to 'search' the first layer
    + The longest list of children excluding the first layer has a length of 24, so that requires 5 bits to store
    + So, we'll need to store 4 more bits to make this change (replacing a 1-bit field with a 5-bit field)
- Store cumulative numbers per-layer instead of storing per-node numbers (e.g. each node should store the number that would be accumulated by searching the list of children and matching that node's character)
    + For this, we would need the `number` field to be 12 bits wide, since the largest cumulative number is `2218`
    + So, we'll need to store 4 more bits to make this change (replacing an 8-bit field with a 12-bit field)

Overall, we need to store 8 more bits of information but only have 2 bits to spare, so somehow we'll need to eek out 6 extra bits.

Let's see what we can do...

##### A free spare bit

As mentioned earlier, named character references only contain characters within the ASCII range. This means that we can use a `u7` instead of a `u8` for the `char` field. This gives us an extra spare bit essentially for free (well, it will make the CPU have to do some extra work to retrieve the value of the field, but we'll ignore that for now).

5 bits to go.

##### Zeroing the first layer numbers

Since we're using a lookup table for the cumulative numbers of the first layer of nodes, there's no reason to store real values in the `number` fields of those nodes in the DAFSA. Removing those values is also extremely helpful because that's where the largest values appear; the largest cumulative number outside of the first layer is 163 which can be stored in 8 bits (4 bits fewer than we thought we needed for this field).

1 bit to go.

##### The final bit

The last bit is the trickiest, as they say. Instead of jumping straight to an approach that works well, though, let's try out some interesting approaches that *also* work but are sub-optimal.

###### 6-bit `char`

From the expandable ["Nitty-gritty DAFSA node size details"](#nitty-gritty-dafsa-node-size-details) section earlier:

> [The `char` field] can technically be represented in 6 bits, since the actual alphabet of characters used in the list of named character references only includes 61 unique characters ('1'...'8', ';', 'a'...'z', 'A'...'Z'). However, to do so you'd need to convert between the 6 bit representation and the actual ASCII value of each character to do comparisons.

Having to do this extra work when performing any comparison against the `char` field is not ideal, to the point that it makes the binary search version perform quite a bit worse than the linear scan version (at least with the conversion function I came up with).

###### Build the unique index during the binary search

One quite-cool-but-also-not-worth-it approach is to avoid storing full cumulative `number` fields, and instead store incremental numbers that will result in the correct cumulative number if they are combined together in a specific way while performing a binary search. In practice, what that means is:

- While performing the binary search:
    - If the character we're searching for is &ge; the current node's character, add the current node's `number` value to the total
    - If the character we're searching for is &lt; the current node's character, do not modify the total

Here's a visualization showing how/why this can work, using a particularly relevant list of children (to be discussed afterwards):

<div style="text-align: center; position: relative; margin-bottom: 2rem;" id="incremental-binary-search-explanation">
  <div class="inc-binary-search">
  <table style="position:relative;" id="inc-bs-search">
    <thead>
      <tr class="has-bg">
        <th>
          <code><b>char</b></code>
        </th>
        <th>
          <code><b>number</b></code>
        </th>
      </tr>
    </thead>
    <tbody>
      <tr id="a"><td><code>'a'</code></td><td>0</td></tr>
      <tr id="b"><td><code>'b'</code></td><td>1</td></tr>
      <tr id="c"><td><code>'c'</code></td><td>2</td></tr>
      <tr id="d"><td><code>'d'</code></td><td>14</td></tr>
      <tr id="e" class="row-contributor"><td><code>'e'</code></td><td>19</td></tr>
      <tr id="f" class="row-highlight"><td><code>'f'</code></td><td>11</td></tr>
      <tr id="h"><td><code>'h'</code></td><td>13</td></tr>
      <tr id="i"><td><code>'i'</code></td><td>20</td></tr>
      <tr id="l"><td><code>'l'</code></td><td>14</td></tr>
      <tr id="m"><td><code>'m'</code></td><td>54</td></tr>
      <tr id="o"><td><code>'o'</code></td><td>8</td></tr>
      <tr id="p"><td><code>'p'</code></td><td>13</td></tr>
      <tr id="q"><td><code>'q'</code></td><td>16</td></tr>
      <tr id="r"><td><code>'r'</code></td><td>16</td></tr>
      <tr id="s"><td><code>'s'</code></td><td>33</td></tr>
      <tr id="t"><td><code>'t'</code></td><td>4</td></tr>
      <tr id="u"><td><code>'u'</code></td><td>9</td></tr>
      <tr id="w"><td><code>'w'</code></td><td>64</td></tr>
      <tr id="z"><td><code>'z'</code></td><td>5</td></tr>
    </tbody>
  </table>
  <div style="position: relative;">
    <div class="has-bg" style="top: 0; width: 75%; margin-left: 12.5%; margin-right: 12.5%; padding: 0.25rem; position: absolute;"><a id="autoplay-toggle" href="#">Autoplay: <span id="autoplay-status">on</span></a></div>
    <svg style="height: 100%; position: absolute; left: -1rem; top: 0;" viewBox="0 0 100 500" class="mermaid-flowchart flowchart" id="inc-bs-svg">
      <g>
        <marker orient="auto" markerHeight="6" markerWidth="6" markerUnits="userSpaceOnUse" refY="5" refX="5" viewBox="0 0 10 10" class="marker flowchart-v2" id="inc-binary-search-arrow-end"><path style="stroke-width: 1px; stroke-dasharray: 1px, 0px;" class="arrowMarkerPath" d="M 0 0 L 10 5 L 0 10 z"></path></marker>
        <g style="display: none;" id="inc-bs-a">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 50,200 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 25,110 3,90"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,90 Q 15,80 3,65"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,65 Q 15,55 3,40"></path>
          </g>
        </g>
        <g style="display:none;" id="inc-bs-b">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 50,200 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 25,110 3,90"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,90 Q 15,80 3,65"></path>
          </g>
        </g>
        <g style="display:none;" id="inc-bs-c">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 50,200 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 25,110 3,90"></path>
          </g>
        </g>
        <g style="display:none;" id="inc-bs-d">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 50,200 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 30,130 25,100 Q 20,80 3,87"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,90 Q 15,100 3,110"></path>
          </g>
        </g>
        <g style="display:none;" id="inc-bs-e">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 50,200 3,140"></path>
          </g>
        </g>
        <g id="inc-bs-f">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 40,250 40,200 Q 40,140 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 45,180 3,213"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,213 Q 15,200 3,188"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,188 Q 15,178 3,164"></path>
          </g>
        </g>
        <g style="display:none;" id="inc-bs-h">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 40,250 40,200 Q 40,140 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 45,180 3,213"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,213 Q 15,200 3,188"></path>
          </g>
        </g>
        <g style="display:none;" id="inc-bs-i">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 40,250 40,200 Q 40,140 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 45,180 3,213"></path>
          </g>
        </g>
        <g style="display:none;" id="inc-bs-l">
          <g class="edgePaths">
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,263 Q 40,250 40,200 Q 40,140 3,140"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,140 Q 45,180 3,213"></path>
            <path marker-end="url(#inc-binary-search-arrow-end)" class="edge-thickness-normal edge-pattern-dashed flowchart-link" d="M0,213 Q 20,224 3,238"></path>
          </g>
        </g>
      </g>
    </svg>
    <table id="inc-bs-tally-table">
      <thead style="visibility: hidden;">
        <tr class="has-bg">
          <th>tally</th>
        </tr>
      </thead>
      <tbody>
        <tr id="a"><td>+0</td></tr>
        <tr id="b"><td>+1</td></tr>
        <tr id="c"><td>+2</td></tr>
        <tr id="d"><td>+14</td></tr>
        <tr id="e" class="contributor"><td>+19</td></tr>
        <tr id="f" class="contributor">
          <td>+11<div style="position: absolute; top: calc(100% + 5px); right: 0px; padding: 5px; width: 30px; text-align: right; border-top: 1px solid;" class="unique-index-total">30</div></td>
        </tr>
        <tr id="h"><td>+13</td></tr>
        <tr id="i"><td>+20</td></tr>
        <tr id="l"><td>+14</td></tr>
        <tr id="m"><td>+54</td></tr>
        <tr id="o"><td>+8</td></tr>
        <tr id="p"><td>+13</td></tr>
        <tr id="q"><td>+16</td></tr>
        <tr id="r"><td>+16</td></tr>
        <tr id="s"><td>+33</td></tr>
        <tr id="t"><td>+4</td></tr>
        <tr id="u"><td>+9</td></tr>
        <tr id="w"><td>+64</td></tr>
        <tr id="z"><td>+5</td></tr>
      </tbody>
    </table>
  </div>
  <table id="inc-bs-expected">
    <thead>
      <tr class="has-bg">
        <th style="font-weight:normal; font-size: 90%;">expected total</th>
      </tr>
    </thead>
    <tbody>
      <tr id="a"><td>0</td></tr>
      <tr id="b"><td>1</td></tr>
      <tr id="c"><td>2</td></tr>
      <tr id="d"><td>16</td></tr>
      <tr id="e"><td>19</td></tr>
      <tr id="f" class="row-highlight"><td>30</td></tr>
      <tr id="h"><td>32</td></tr>
      <tr id="i"><td>39</td></tr>
      <tr id="l"><td>53</td></tr>
      <tr id="m"><td>54</td></tr>
      <tr id="o"><td>62</td></tr>
      <tr id="p"><td>67</td></tr>
      <tr id="q"><td>70</td></tr>
      <tr id="r"><td>86</td></tr>
      <tr id="s"><td>87</td></tr>
      <tr id="t"><td>91</td></tr>
      <tr id="u"><td>96</td></tr>
      <tr id="w"><td>151</td></tr>
      <tr id="z"><td>156</td></tr>
    </tbody>
  </table>
  </div>

  <style scoped>

    .inc-binary-search {
      display: grid; grid-template-columns: 1fr 1.5fr 1fr; grid-gap: 1rem; padding: 1rem;
    }
    #inc-bs-tally-table {
      margin-left: auto; margin-right: auto; height: 100%;
    }
    #inc-bs-tally-table td, #inc-bs-tally-table th {
      border-color: transparent; text-align: right;
    }
    #inc-bs-tally-table tr {
      visibility: hidden; position: relative;
    }
    #inc-bs-tally-table tr.contributor {
      visibility: visible;
    }
    #inc-bs-search tr {
      cursor: pointer;
    }
    #inc-bs-search tr:hover td {
      background: rgba(0,0,0,0.25);
    }
    .row-contributor {
      background: #A4EBE0;
    }
    @media (prefers-color-scheme: dark) {
      .row-contributor {
        background: #153F3B;
      }
    }
    #inc-bs-svg .mirrored-vertically {
      transform: scaleY(-1); transform-origin: left 52.5%;
    }
    #inc-bs-svg {
      pointer-events: none;
    }

  </style>

<script>
(function(){
  let root = document.getElementById("incremental-binary-search-explanation");
  let search_table = root.querySelector("#inc-bs-search");
  let tally_table = root.querySelector("#inc-bs-tally-table");
  let expected_table = root.querySelector("#inc-bs-expected");
  let total_el = root.querySelector(".unique-index-total");
  let chars = [
    {char: 'a', contributors: []},
    {char: 'b', contributors: []},
    {char: 'c', contributors: []},
    {char: 'd', contributors: ['c']},
    {char: 'e', contributors: []},
    {char: 'f', contributors: ['e']},
    {char: 'h', contributors: ['e']},
    {char: 'i', contributors: ['e']},
    {char: 'l', contributors: ['e','i']},
    {char: 'm', contributors: []},
    {char: 'o', contributors: ['m']},
    {char: 'p', contributors: ['m',]},
    {char: 'q', contributors: ['m','p']},
    {char: 'r', contributors: ['m','p','q']},
    {char: 's', contributors: ['m']},
    {char: 't', contributors: ['m','s']},
    {char: 'u', contributors: ['m','s']},
    {char: 'w', contributors: ['m','s','u']},
    {char: 'z', contributors: ['m','s','u','w']}
  ];
  let char_i = 0;
  let apply = function() {
    for (let i=0; i<chars.length; i++) {
      let svg = root.querySelector("#inc-bs-"+chars[i].char);
      if (svg) {
        svg.style.display = 'none';
        svg.classList.remove('mirrored-vertically');
      }
      let selector = '#'+chars[i].char;
      search_table.querySelector(selector).classList.remove('row-contributor');
      search_table.querySelector(selector).classList.remove('row-highlight');
      expected_table.querySelector(selector).classList.remove('row-highlight');
      tally_table.querySelector(selector).classList.remove('contributor');
    }
    let cur = chars[char_i];
    let selector = '#'+cur.char;
    search_table.querySelector(selector).classList.add('row-highlight');
    expected_table.querySelector(selector).classList.add('row-highlight');
    tally_table.querySelector(selector).classList.add('contributor');
    tally_table.querySelector(selector + " > td").appendChild(total_el);
    total_el.textContent = expected_table.querySelector(selector).textContent;
    for (let i=0; i<cur.contributors.length; i++) {
      let contributor = '#'+cur.contributors[i];
      search_table.querySelector(contributor).classList.add('row-contributor');
      tally_table.querySelector(contributor).classList.add('contributor');
    }
    if (cur.char < 'm') {
      root.querySelector("#inc-bs-"+cur.char).style.display = 'block';
    } else if (cur.char != 'm') {
      let mirrored_char_i = chars.length - char_i - 1;
      console.log(mirrored_char_i);
      let mirrored_char = chars[mirrored_char_i];
      root.querySelector("#inc-bs-"+mirrored_char.char).style.display = 'block';
      root.querySelector("#inc-bs-"+mirrored_char.char).classList.add('mirrored-vertically');
    }
  }
  apply();

  let next = function() {
    char_i = (char_i + 1) % chars.length;
    apply();
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

  root.querySelector('#autoplay-toggle').onclick = function(e) {
    e.preventDefault();
    toggle();
  };
  for (let i=0; i<chars.length; i++) {
    search_table.querySelector('#'+chars[i].char).onclick = function(e) {
      e.preventDefault();
      char_i = i;
      stop();
      apply();
    }
  }
})();
</script>

</div>

This specific list of children was chosen because 64 (the `number` value of the node with the character `'w'` here) is actually the largest `number` value in the entire DAFSA after transforming the `number` fields in this way. This means that instead of 8 bits to store the number field, we only need 7, thus saving the 1 bit that we're looking for.

Yet again, though, this extra work being done while performing the binary search cancels out the benefit of the binary search, and it ends up being marginally slower than the linear scan version.

###### An actually good approach

The approach I found that works the best is actually quite straightforward to summarize: entirely remove the first layer of nodes from the DAFSA. We can get away with this because we already have a lookup table available for the first layer, so we could theoretically just stuff all the necessary information in there instead of keeping it in the DAFSA.

In practice, it's not quite as simple as that, though. If you're interested in the details, expand below:

<details class="box-border" style="padding: 1em;">
<summary>Nitty-gritty details of removing the first layer from the DAFSA</summary>

After adding the lookup table for the first layer, `NamedCharacterReferenceMatcher` uses this approach:

- Start with `node_index` set to 0
- If `node_index` is currently 0, verify that the current character is within `a-z` or `A-Z`, and, if so, look up the cumulative unique index in the lookup table. Set the `node_index` to the `<lookup table index> + 1` (since the first layer of nodes in the DAFSA always follow the root node)
- If `node_index` is not 0, do DAFSA traversal as normal (search the node's children starting at `nodes[node_index].first_child_index`)

This means that we're currently relying on the first layer of nodes being in the DAFSA in order to allow for `node_index` to be used as a universal 'cursor' that tracks where we are in the DAFSA. If we simply remove the first layer of nodes, then we'd need two separate cursors: 1 that we would use for the lookup table, and 1 that we would use for the DAFSA nodes array. That might not be a bad approach, but what I went for instead is this:

- Instead of storing a `node_index` in `NamedCharacterReferenceMatcher`, store an optional slice of children to check (`?[]const Node`) that starts as `null`
- If `children_to_check` is `null`, use the first layer lookup table to get three pieces of information: (1) the cumulative unique index number, (2) the index of the node's first child in the DAFSA array, and (3) the length of the node's list of children. Set `children_to_check` to a slice of the DAFSA array with the retrieved length, and starting at the retrieved first child index
- If `children_to_check` is not `null`, search within the `children_to_check` slice as normal

</details>

It might not be completely obvious how this saves us a bit, but removing the first layer also happens to remove the largest values of our added `children_len` field. Somewhat miraculously, the new largest value is 13 (down from 24), so instead of needing 5 bits, we now only need 4 bits for that field.

#### Putting it all together

After all that, we end up with two `struct` representations for the data we're looking to store:

One for the first layer lookup table:

```zig
const FirstLayerNode = packed struct {
    number: u12,
    child_index: u10,
    children_len: u5,
};
```

and one for the rest of the DAFSA nodes:

```zig
const Node = packed struct(u32) {
    char: u7,
    number: u8,
    end_of_word: bool,
    children_len: u4,
    child_index: u12,
};
```

<p><aside class="note">

Note: This approach actually uses the exact same amount of data to store everything, all things told. The `@sizeOf(FirstLayerNode)` is 4 bytes, which is the same as the `@sizeOf(Node)`, so moving the first layer of nodes out of the DAFSA means that the total data size stays the same (`52 * 4` bytes removed from the DAFSA array, `52 * 4` bytes added for the first layer lookup table).

</aside></p>

With this, we can accelerate the search time for the first character drastically, and make it possible to use a binary search for all the rest of the searches we perform. In terms of raw matching speed, this provides another decent improvement over the first layer lookup table alone:

```poopresults
Benchmark 1 (44 runs): ./bench-master
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           115ms ± 1.73ms     112ms …  118ms          0 ( 0%)        0%
  peak_rss            754KB ±  617       750KB …  754KB          1 ( 2%)        0%
  cpu_cycles          471M  ± 2.35M      467M  …  478M           0 ( 0%)        0%
  instructions        740M  ± 1.65       740M  …  740M           0 ( 0%)        0%
  cache_references   6.30M  ± 53.8K     6.14M  … 6.38M           1 ( 2%)        0%
  cache_misses       6.81K  ± 5.18K     1.19K  … 19.4K           6 (14%)        0%
  branch_misses      5.70M  ± 14.3K     5.68M  … 5.74M           1 ( 2%)        0%
Benchmark 2 (73 runs): ./bench-first-layer-accel
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          69.0ms ± 1.70ms    66.7ms … 71.3ms          0 ( 0%)        ⚡- 40.0% ±  0.6%
  cpu_cycles          279M  ± 1.18M      277M  …  282M           0 ( 0%)        ⚡- 40.7% ±  0.1%
  instructions        385M  ± 2.77       385M  …  385M           1 ( 1%)        ⚡- 47.9% ±  0.0%
  cache_references   6.29M  ± 73.4K     6.14M  … 6.51M           1 ( 1%)          -  0.1% ±  0.4%
  cache_misses       8.70K  ± 6.54K     1.13K  … 21.8K           0 ( 0%)          + 27.8% ± 33.7%
  branch_misses      4.79M  ± 9.12K     4.78M  … 4.82M           4 ( 5%)        ⚡- 15.9% ±  0.1%
Benchmark 3 (83 runs): ./bench-first-layer-accel-binary-search-u7-char-u8-number
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          60.6ms ± 3.40ms    58.3ms … 81.0ms          2 ( 2%)        ⚡- 47.3% ±  0.9%
  cpu_cycles          244M  ± 1.35M      242M  …  251M           1 ( 1%)        ⚡- 48.1% ±  0.1%
  instructions        431M  ± 3.45       431M  …  431M           2 ( 2%)        ⚡- 41.8% ±  0.0%
  cache_references   6.30M  ± 87.0K     6.12M  … 6.47M           0 ( 0%)          +  0.1% ±  0.4%
  cache_misses       6.66K  ± 3.61K     1.19K  … 16.4K           1 ( 1%)          -  2.2% ± 22.6%
  branch_misses      4.92M  ± 18.7K     4.89M  … 5.00M          15 (18%)        ⚡- 13.6% ±  0.1%
```

<p><aside class="note">

These benchmarks were run using a version of the DAFSA written in Zig and the code for each is available here:

- [bench-master](https://github.com/squeek502/named-character-references/tree/4a0c4b4ed5b0397890510fc96e2ace4b5b8e2a83)
- [bench-first-layer-accel](https://github.com/squeek502/named-character-references/tree/1d109635043f4f9faa365798cec8cc783a692a9a)
- [bench-first-layer-accel-binary-search-u7-char-u8-number](https://github.com/squeek502/named-character-references/tree/d9ae6d6741bdb97609432f039ce1558604827b5a)

</aside></p>

Taken together (the Benchmark 3 results), these two optimizations make raw matching speed about 1.9x faster than it was originally.

<p><aside class="note">

Note: We can't easily check how much the 'binary search' optimization on its own would improve the matching speed, since the 'first layer acceleration' optimization was required to allow fitting all the necessary information into the 32-bit nodes.

</aside></p>

As mentioned, though, these raw matching speed improvements don't translate to nearly the same improvement when benchmarking this [new implementation within the Ladybird tokenizer](https://github.com/squeek502/ladybird/tree/dafsa-binary-search) (note also that these benchmarks don't use the 'lookahead when outside of an insertion point' optimization).

```poopresults
Benchmark 1 (89 runs): ./BenchHTMLTokenizer dafsa
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           113ms ± 1.10ms     112ms …  115ms          0 ( 0%)        0%
  peak_rss           83.3MB ± 78.1KB    83.1MB … 83.5MB         30 (34%)        0%
  cpu_cycles          228M  ±  827K      227M  …  231M           3 ( 3%)        0%
  instructions        450M  ± 4.99K      450M  …  450M           0 ( 0%)        0%
  cache_references   9.43M  ±  266K     9.28M  … 11.9M           1 ( 1%)        0%
  cache_misses        404K  ± 4.56K      393K  …  417K           0 ( 0%)        0%
  branch_misses       574K  ± 7.43K      570K  …  641K           2 ( 2%)        0%
Benchmark 2 (92 runs): ./BenchHTMLTokenizer dafsa-binary-search
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           109ms ± 1.10ms     107ms …  111ms          0 ( 0%)        ⚡-  3.8% ±  0.3%
  peak_rss           83.3MB ± 74.0KB    83.1MB … 83.5MB         31 (34%)          +  0.0% ±  0.0%
  cpu_cycles          210M  ±  778K      209M  …  212M           0 ( 0%)        ⚡-  7.9% ±  0.1%
  instructions        417M  ± 4.75K      417M  …  417M           0 ( 0%)        ⚡-  7.3% ±  0.0%
  cache_references   9.39M  ±  124K     9.21M  … 10.4M           4 ( 4%)          -  0.4% ±  0.6%
  cache_misses        407K  ± 5.47K      395K  …  423K           1 ( 1%)          +  0.8% ±  0.4%
  branch_misses       533K  ± 1.50K      530K  …  542K           7 ( 8%)        ⚡-  7.0% ±  0.3%
```

```poopresults
Benchmark 1 (218 runs): ./BenchHTMLTokenizer dafsa gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          45.8ms ±  658us    43.6ms … 47.0ms         12 ( 6%)        0%
  peak_rss           53.0MB ± 84.2KB    52.7MB … 53.2MB          2 ( 1%)        0%
  cpu_cycles          117M  ±  581K      116M  …  119M           7 ( 3%)        0%
  instructions        259M  ± 5.32K      259M  …  259M           3 ( 1%)        0%
  cache_references   3.25M  ± 82.1K     3.16M  … 4.05M          16 ( 7%)        0%
  cache_misses        355K  ± 5.76K      345K  …  376K           1 ( 0%)        0%
  branch_misses       182K  ± 2.45K      178K  …  200K          16 ( 7%)        0%
Benchmark 2 (236 runs): ./BenchHTMLTokenizer dafsa-binary-search gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          42.4ms ±  921us    40.2ms … 43.8ms          7 ( 3%)        ⚡-  7.5% ±  0.3%
  peak_rss           53.0MB ± 77.8KB    52.7MB … 53.2MB          1 ( 0%)          +  0.0% ±  0.0%
  cpu_cycles          103M  ±  771K      101M  …  106M           6 ( 3%)        ⚡- 12.3% ±  0.1%
  instructions        220M  ± 8.52K      220M  …  220M          13 ( 6%)        ⚡- 15.1% ±  0.0%
  cache_references   3.27M  ±  109K     3.18M  … 4.16M          16 ( 7%)          +  0.4% ±  0.5%
  cache_misses        360K  ± 8.94K      345K  …  394K           1 ( 0%)          +  1.3% ±  0.4%
  branch_misses       189K  ± 7.40K      179K  …  215K           2 ( 1%)        💩+  3.8% ±  0.6%
```

```poopresults
Benchmark 1 (158 runs): ./BenchHTMLTokenizer dafsa ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          63.2ms ±  859us    61.3ms … 64.6ms          1 ( 1%)        0%
  peak_rss           65.1MB ± 85.1KB    64.8MB … 65.2MB          2 ( 1%)        0%
  cpu_cycles          112M  ±  550K      111M  …  115M           1 ( 1%)        0%
  instructions        214M  ± 7.62K      214M  …  214M           5 ( 3%)        0%
  cache_references   5.87M  ± 82.4K     5.77M  … 6.52M           5 ( 3%)        0%
  cache_misses        374K  ± 4.78K      365K  …  405K           4 ( 3%)        0%
  branch_misses       164K  ± 4.62K      160K  …  219K           1 ( 1%)        0%
Benchmark 2 (163 runs): ./BenchHTMLTokenizer dafsa-binary-search ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          61.4ms ±  833us    59.3ms … 62.8ms          0 ( 0%)        ⚡-  2.9% ±  0.3%
  peak_rss           65.1MB ± 76.6KB    64.8MB … 65.2MB          1 ( 1%)          +  0.0% ±  0.0%
  cpu_cycles          105M  ±  573K      104M  …  107M           1 ( 1%)        ⚡-  6.6% ±  0.1%
  instructions        195M  ± 7.30K      195M  …  195M           1 ( 1%)        ⚡-  8.8% ±  0.0%
  cache_references   5.87M  ± 94.8K     5.79M  … 6.87M           6 ( 4%)          +  0.1% ±  0.3%
  cache_misses        375K  ± 4.47K      365K  …  388K           2 ( 1%)          +  0.1% ±  0.3%
  branch_misses       164K  ± 3.11K      162K  …  202K           3 ( 2%)          +  0.3% ±  0.5%
```

```poopresults
Benchmark 1 (230 runs): ./BenchHTMLTokenizer dafsa all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.3ms ±  635us    41.1ms … 44.9ms         13 ( 6%)        0%
  peak_rss           54.4MB ± 90.7KB    54.0MB … 54.5MB          1 ( 0%)        0%
  cpu_cycles          102M  ±  651K      101M  …  106M           3 ( 1%)        0%
  instructions        191M  ± 8.94K      191M  …  191M          14 ( 6%)        0%
  cache_references   3.55M  ± 48.8K     3.48M  … 3.88M          10 ( 4%)        0%
  cache_misses        358K  ± 8.22K      342K  …  387K           9 ( 4%)        0%
  branch_misses       344K  ± 4.30K      340K  …  405K           2 ( 1%)        0%
Benchmark 2 (247 runs): ./BenchHTMLTokenizer dafsa-binary-search all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          40.4ms ±  754us    38.1ms … 42.3ms         13 ( 5%)        ⚡-  6.7% ±  0.3%
  peak_rss           54.4MB ± 73.5KB    54.1MB … 54.5MB         76 (31%)          +  0.0% ±  0.0%
  cpu_cycles         90.1M  ±  522K     88.8M  … 92.3M           2 ( 1%)        ⚡- 11.8% ±  0.1%
  instructions        170M  ± 7.36K      170M  …  170M          13 ( 5%)        ⚡- 11.0% ±  0.0%
  cache_references   3.54M  ± 32.2K     3.46M  … 3.68M           7 ( 3%)          -  0.3% ±  0.2%
  cache_misses        356K  ± 6.32K      344K  …  379K           1 ( 0%)          -  0.6% ±  0.4%
  branch_misses       314K  ± 1.08K      311K  …  319K           8 ( 3%)        ⚡-  8.8% ±  0.2%
```

However, it's enough to put this new DAFSA implementation ahead of the Firefox and Chrome/Sarafi implementations in all of the benchmarks I'm using.

```poopresults
Benchmark 1 (91 runs): ./BenchHTMLTokenizer dafsa-binary-search
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           110ms ±  956us     108ms …  111ms          0 ( 0%)        0%
  peak_rss           83.5MB ± 79.4KB    83.2MB … 83.6MB          1 ( 1%)        0%
  cpu_cycles          212M  ± 1.31M      209M  …  217M           3 ( 3%)        0%
  instructions        420M  ± 9.03K      420M  …  420M           5 ( 5%)        0%
  cache_references   9.57M  ±  186K     9.36M  … 10.9M           2 ( 2%)        0%
  cache_misses        405K  ± 5.61K      394K  …  421K           0 ( 0%)        0%
  branch_misses       535K  ± 1.70K      532K  …  540K           0 ( 0%)        0%
Benchmark 2 (89 runs): ./BenchHTMLTokenizer gecko
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           113ms ± 1.02ms     111ms …  115ms          0 ( 0%)        💩+  2.6% ±  0.3%
  peak_rss           83.6MB ± 70.9KB    83.3MB … 83.6MB          0 ( 0%)          +  0.1% ±  0.0%
  cpu_cycles          225M  ± 1.28M      223M  …  234M           2 ( 2%)        💩+  5.8% ±  0.2%
  instructions        441M  ± 7.17K      441M  …  441M           7 ( 8%)        💩+  5.0% ±  0.0%
  cache_references   9.85M  ±  227K     9.64M  … 11.3M           4 ( 4%)        💩+  2.9% ±  0.6%
  cache_misses        411K  ± 5.54K      402K  …  431K           2 ( 2%)        💩+  1.5% ±  0.4%
  branch_misses       581K  ± 19.0K      575K  …  758K           7 ( 8%)        💩+  8.5% ±  0.7%
Benchmark 3 (88 runs): ./BenchHTMLTokenizer blink
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           115ms ±  856us     113ms …  117ms          0 ( 0%)        💩+  4.5% ±  0.2%
  peak_rss           83.5MB ± 72.4KB    83.2MB … 83.6MB         26 (30%)          -  0.0% ±  0.0%
  cpu_cycles          232M  ±  940K      230M  …  235M           0 ( 0%)        💩+  9.4% ±  0.2%
  instructions        463M  ± 8.80K      463M  …  463M           6 ( 7%)        💩+ 10.4% ±  0.0%
  cache_references   10.2M  ±  141K     9.94M  … 10.9M           2 ( 2%)        💩+  6.1% ±  0.5%
  cache_misses        410K  ± 5.40K      398K  …  424K           0 ( 0%)          +  1.1% ±  0.4%
  branch_misses       751K  ± 1.90K      747K  …  755K           0 ( 0%)        💩+ 40.3% ±  0.1%
```

```poopresults
Benchmark 1 (234 runs): ./BenchHTMLTokenizer dafsa-binary-search gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          42.6ms ±  717us    40.3ms … 44.2ms         17 ( 7%)        0%
  peak_rss           53.2MB ± 90.0KB    52.8MB … 53.4MB         88 (38%)        0%
  cpu_cycles          103M  ±  604K      101M  …  105M           2 ( 1%)        0%
  instructions        222M  ± 6.94K      222M  …  222M           9 ( 4%)        0%
  cache_references   3.27M  ± 96.0K     3.19M  … 3.98M          15 ( 6%)        0%
  cache_misses        356K  ± 5.77K      344K  …  377K           1 ( 0%)        0%
  branch_misses       182K  ± 3.18K      178K  …  215K          11 ( 5%)        0%
Benchmark 2 (198 runs): ./BenchHTMLTokenizer gecko gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          50.5ms ±  831us    48.5ms … 52.4ms         20 (10%)        💩+ 18.7% ±  0.3%
  peak_rss           53.2MB ± 84.3KB    53.0MB … 53.4MB          1 ( 1%)          +  0.1% ±  0.0%
  cpu_cycles          138M  ±  610K      136M  …  139M           3 ( 2%)        💩+ 33.8% ±  0.1%
  instructions        280M  ± 7.27K      280M  …  280M           6 ( 3%)        💩+ 26.3% ±  0.0%
  cache_references   3.34M  ±  118K     3.22M  … 4.58M           9 ( 5%)        💩+  2.1% ±  0.6%
  cache_misses        356K  ± 5.10K      344K  …  372K           3 ( 2%)          -  0.1% ±  0.3%
  branch_misses       315K  ± 5.57K      305K  …  346K           4 ( 2%)        💩+ 72.8% ±  0.5%
Benchmark 3 (213 runs): ./BenchHTMLTokenizer blink gecko-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          47.1ms ±  620us    44.9ms … 48.3ms         18 ( 8%)        💩+ 10.6% ±  0.3%
  peak_rss           53.2MB ± 84.0KB    52.8MB … 53.4MB          1 ( 0%)          -  0.0% ±  0.0%
  cpu_cycles          122M  ±  745K      121M  …  127M           2 ( 1%)        💩+ 18.5% ±  0.1%
  instructions        292M  ± 5.64K      292M  …  292M           4 ( 2%)        💩+ 31.7% ±  0.0%
  cache_references   3.30M  ±  139K     3.19M  … 4.78M          24 (11%)          +  0.9% ±  0.7%
  cache_misses        355K  ± 5.58K      343K  …  371K           7 ( 3%)          -  0.4% ±  0.3%
  branch_misses       183K  ±  710       180K  …  185K           3 ( 1%)          +  0.2% ±  0.2%
```

```poopresults
Benchmark 1 (160 runs): ./BenchHTMLTokenizer dafsa-binary-search ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          62.4ms ± 1.16ms    60.4ms … 64.8ms          0 ( 0%)        0%
  peak_rss           65.3MB ± 81.8KB    64.9MB … 65.4MB         45 (28%)        0%
  cpu_cycles          107M  ±  850K      105M  …  114M           3 ( 2%)        0%
  instructions        196M  ± 12.0K      196M  …  196M          14 ( 9%)        0%
  cache_references   5.92M  ± 73.9K     5.81M  … 6.21M           3 ( 2%)        0%
  cache_misses        386K  ± 7.90K      369K  …  409K           1 ( 1%)        0%
  branch_misses       164K  ± 1.74K      161K  …  179K           9 ( 6%)        0%
Benchmark 2 (161 runs): ./BenchHTMLTokenizer gecko ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          62.3ms ±  988us    59.7ms … 64.1ms          0 ( 0%)          -  0.1% ±  0.4%
  peak_rss           65.3MB ± 79.2KB    65.0MB … 65.4MB          2 ( 1%)          +  0.1% ±  0.0%
  cpu_cycles          106M  ±  618K      104M  …  108M           3 ( 2%)          -  0.8% ±  0.2%
  instructions        195M  ± 12.6K      195M  …  195M          13 ( 8%)          -  0.8% ±  0.0%
  cache_references   6.03M  ±  169K     5.84M  … 6.99M           2 ( 1%)        💩+  1.9% ±  0.5%
  cache_misses        386K  ± 7.61K      370K  …  413K           2 ( 1%)          -  0.1% ±  0.4%
  branch_misses       165K  ± 1.02K      163K  …  169K           2 ( 1%)          +  0.4% ±  0.2%
Benchmark 3 (158 runs): ./BenchHTMLTokenizer blink ladybird-worst-case
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          63.4ms ± 1.22ms    61.0ms … 65.3ms          0 ( 0%)        💩+  1.7% ±  0.4%
  peak_rss           65.2MB ± 78.2KB    65.0MB … 65.4MB          1 ( 1%)          -  0.0% ±  0.0%
  cpu_cycles          109M  ±  789K      107M  …  115M           2 ( 1%)        💩+  2.0% ±  0.2%
  instructions        204M  ± 11.7K      203M  …  204M           4 ( 3%)        💩+  3.7% ±  0.0%
  cache_references   6.00M  ± 90.0K     5.85M  … 6.25M           0 ( 0%)        💩+  1.4% ±  0.3%
  cache_misses        388K  ± 8.11K      371K  …  409K           0 ( 0%)          +  0.6% ±  0.5%
  branch_misses       165K  ± 1.24K      162K  …  173K           1 ( 1%)          +  0.4% ±  0.2%
```

```poopresults
Benchmark 1 (244 runs): ./BenchHTMLTokenizer dafsa-binary-search all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          41.0ms ±  843us    38.3ms … 42.2ms         21 ( 9%)        0%
  peak_rss           54.5MB ± 87.9KB    54.3MB … 54.6MB          4 ( 2%)        0%
  cpu_cycles         90.6M  ±  591K     89.6M  … 92.6M           2 ( 1%)        0%
  instructions        172M  ± 9.67K      172M  …  172M          19 ( 8%)        0%
  cache_references   3.56M  ±  117K     3.47M  … 5.05M          14 ( 6%)        0%
  cache_misses        359K  ± 9.17K      343K  …  399K           1 ( 0%)        0%
  branch_misses       316K  ± 4.49K      312K  …  382K           1 ( 0%)        0%
Benchmark 2 (229 runs): ./BenchHTMLTokenizer gecko all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          43.7ms ±  735us    41.4ms … 44.9ms         18 ( 8%)        💩+  6.6% ±  0.3%
  peak_rss           54.6MB ± 85.1KB    54.3MB … 54.8MB          2 ( 1%)          +  0.1% ±  0.0%
  cpu_cycles          103M  ±  460K      102M  …  105M           5 ( 2%)        💩+ 13.6% ±  0.1%
  instructions        189M  ± 4.69K      189M  …  189M           4 ( 2%)        💩+ 10.1% ±  0.0%
  cache_references   3.65M  ± 93.4K     3.54M  … 4.77M          14 ( 6%)        💩+  2.5% ±  0.5%
  cache_misses        356K  ± 5.90K      344K  …  377K           5 ( 2%)          -  0.9% ±  0.4%
  branch_misses       385K  ±  861       383K  …  388K           2 ( 1%)        💩+ 21.8% ±  0.2%
Benchmark 3 (224 runs): ./BenchHTMLTokenizer blink all-valid
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          44.6ms ±  885us    42.1ms … 46.2ms         23 (10%)        💩+  8.9% ±  0.4%
  peak_rss           54.5MB ± 87.3KB    54.1MB … 54.6MB         88 (39%)          -  0.1% ±  0.0%
  cpu_cycles          106M  ±  654K      105M  …  109M           2 ( 1%)        💩+ 17.2% ±  0.1%
  instructions        205M  ± 9.02K      205M  …  205M          10 ( 4%)        💩+ 19.4% ±  0.0%
  cache_references   3.80M  ±  103K     3.69M  … 5.07M           9 ( 4%)        💩+  6.5% ±  0.6%
  cache_misses        361K  ± 9.82K      345K  …  396K           3 ( 1%)          +  0.5% ±  0.5%
  branch_misses       464K  ± 1.33K      460K  …  469K           6 ( 3%)        💩+ 46.7% ±  0.2%
```

```poopresults
Benchmark 1 (67 runs): ./BenchMatcherDafsaBinarySearch
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          74.6ms ± 1.32ms    72.1ms … 76.4ms          0 ( 0%)        0%
  peak_rss           4.57MB ± 70.4KB    4.46MB … 4.72MB         20 (30%)        0%
  cpu_cycles          299M  ± 1.18M      296M  …  301M           1 ( 1%)        0%
  instructions        471M  ± 79.5       471M  …  471M           0 ( 0%)        0%
  cache_references   6.03M  ± 49.6K     5.90M  … 6.18M           2 ( 3%)        0%
  cache_misses       26.0K  ± 4.18K     20.5K  … 37.4K           1 ( 1%)        0%
  branch_misses      5.28M  ± 53.2K     5.14M  … 5.37M           3 ( 4%)        0%
Benchmark 2 (48 runs): ./BenchMatcherGecko
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           105ms ± 1.18ms     103ms …  107ms          0 ( 0%)        💩+ 40.8% ±  0.6%
  peak_rss           4.57MB ± 60.4KB    4.46MB … 4.72MB         11 (23%)          -  0.1% ±  0.5%
  cpu_cycles          426M  ± 1.48M      424M  …  430M           2 ( 4%)        💩+ 42.4% ±  0.2%
  instructions        745M  ± 68.8       745M  …  745M           8 (17%)        💩+ 58.2% ±  0.0%
  cache_references   8.04M  ± 77.0K     7.95M  … 8.48M           1 ( 2%)        💩+ 33.3% ±  0.4%
  cache_misses       27.1K  ± 5.19K     21.3K  … 44.7K           6 (13%)          +  4.3% ±  6.7%
  branch_misses      5.41M  ± 2.77K     5.41M  … 5.42M           2 ( 4%)        💩+  2.5% ±  0.3%
Benchmark 3 (36 runs): ./BenchMatcherBlink
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           140ms ± 1.66ms     138ms …  146ms          1 ( 3%)        💩+ 88.2% ±  0.8%
  peak_rss           4.60MB ± 75.3KB    4.46MB … 4.72MB         12 (33%)          +  0.7% ±  0.6%
  cpu_cycles          573M  ± 4.44M      568M  …  594M           4 (11%)        💩+ 91.6% ±  0.4%
  instructions       1.07G  ± 70.5      1.07G  … 1.07G           7 (19%)        💩+126.3% ±  0.0%
  cache_references   12.3M  ±  107K     12.2M  … 12.7M           2 ( 6%)        💩+104.6% ±  0.5%
  cache_misses       28.3K  ± 5.50K     21.3K  … 43.8K           3 ( 8%)        💩+  9.1% ±  7.4%
  branch_misses      8.78M  ± 10.3K     8.75M  … 8.80M           1 ( 3%)        💩+ 66.2% ±  0.3%
```

So, at long last, we're at the point where the title (hopefully) becomes justified: this improved DAFSA implementation seems to be slightly better across the board.

## Future possibilities

One funny aspect of this whole thing is that the problem is actually quite simple once you understand it, and there are probably a lot of different ways one could approach it. If you've read this far, it's very likely that you have some ideas of your own on how to make something better: either a whole different approach, or an improvement to some part of one of the approaches detailed so far.

I'll outline some avenues I think might warrant some further attention, but I also expect that I'll miss things that someone else may consider obvious.

### DAFSA with first-two-character acceleration

In the last section, I took inspiration from the other browsers' implementations by adding a lookup table to accelerate the search for the first character, but it'd also be possible to take one more page from the Firefox implementation and do the same thing for the *second* character, too.

I actually [have tried this out](https://github.com/squeek502/named-character-references/tree/8222d9ec403076524073c601441df67b74b7d5c5), and the implementation that I came up with:

- Uses exactly 8 KiB more data (+28.7%)
- Frees up 2 bits from the `number` field since the largest `number` value remaining in the DAFSA is 51 (down from 163)
- Allows using a `u8` for the `char` field instead of a `u7` (this should reduce the number of instructions needed to access that field)
- Makes the binary search no longer worth it; the remaining lists of children are short enough that a linear search wins out

Overall, these changes cut the raw lookup time by around -16% (as measured by the benchmark I'm using, at least):

```poopresults
Benchmark 1 (169 runs): ./bench-first-layer-accel-binary-search
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          59.4ms ± 1.20ms    58.0ms … 61.4ms          0 ( 0%)        0%
  cpu_cycles          242M  ±  797K      241M  …  250M          14 ( 8%)        0%
  instructions        431M  ± 1.28       431M  …  431M           0 ( 0%)        0%
  cache_references   6.21M  ± 74.9K     6.10M  … 6.99M           2 ( 1%)        0%
  cache_misses       1.53K  ±  629      1.01K  … 5.03K          16 ( 9%)        0%
  branch_misses      4.88M  ± 4.28K     4.87M  … 4.90M           6 ( 4%)        0%
Benchmark 2 (201 runs): ./bench-two-layer-accel-linear-search
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          49.7ms ± 2.64ms    47.4ms … 76.2ms         10 ( 5%)        ⚡- 16.2% ±  0.7%
  cpu_cycles          198M  ± 1.20M      197M  …  207M          11 ( 5%)        ⚡- 18.2% ±  0.1%
  instructions        332M  ± 4.83       332M  …  332M          26 (13%)        ⚡- 22.8% ±  0.0%
  cache_references   7.29M  ± 48.6K     7.19M  … 7.44M           1 ( 0%)        💩+ 17.3% ±  0.2%
  cache_misses       1.56K  ±  442      1.09K  … 3.45K           7 ( 3%)          +  1.8% ±  7.2%
  branch_misses      3.96M  ± 7.41K     3.95M  … 4.00M           7 ( 3%)        ⚡- 18.7% ±  0.0%
```

So, for 8 KiB more data you can get another decent performance improvement, but so far I've only implemented this version in Zig so I can't report more information on this yet (would need to port it to C++ to test it with Ladybird). This also represents my first attempt at this 'two layer acceleration' strategy, so it's possible there's more juice to squeeze here.

<p><aside class="note">

Note: I've put this here instead of the ["*Further improvements ...*"](#further-improvements-to-the-dafsa-implementation) section because this doesn't feel like the final form of this idea, and I still kinda like saving that extra 8 KiB of data.

Also, I've already taken way too long in writing this article, so I'm not letting myself pull on this thread anymore right now.

</aside></p>

### SIMD

[Single instruction, multiple data (SIMD)](https://en.wikipedia.org/wiki/Single_instruction,_multiple_data) is something I have had very little experience with using up to this point, and [my naive attempts at using SIMD to accelerate my DAFSA implementation](https://github.com/squeek502/named-character-references/commit/040d3e104941344dc97d7e2d2179d49650de6120) were not fruitful. However, it seems like there's potential to take advantage of SIMD for this type of problem (if not with a DAFSA, then with some totally different approach that takes better advantage of what SIMD is good at).

### Data-oriented design

As I understand it, the core idea of [data-oriented design](https://en.wikipedia.org/wiki/Data-oriented_design) is: instead of using an 'array of structs', use a 'struct of arrays' where each array holds segments of data that are frequently accessed together. If applied well, this can both cut down on wasted padding bits between elements and make your code much more CPU-cache-friendly.

<details class="box-border" style="padding: 1em;">
<summary>Example for those unfamiliar with data-oriented design</summary>

For example:

```zig
const Struct = struct {
  foo: u8,
  bar: u16,
}
const array_of_structs = [100]Struct{ ... };
```

With the above, each element will have 8 bits of padding (the fields of `Struct` use 3 bytes, but `@sizeOf(Struct)` is 4 bytes), and `array_of_structs` will use 400 bytes. Additionally, if you have a loop where you're only accessing one field like this:

```zig
for (&array_of_structs) |element| {
  if (element.foo == '!') return true;
}
```

then you're accidentally paying the cost of the larger `Struct` size since fewer will fit into cache. If we move to a 'struct of arrays' approach instead like so:

```zig
const StructOfArrays = struct {
  foos: [100]u8 = { ... },
  bars: [100]u16 = { ... },
};
```

then we're only using 300 bytes for these two arrays, and if we write a loop that only looks at `foos` like so:

```zig
for (&StructOfArrays.foos) |foo| {
  if (foo == '!') return true;
}
```

it will be able to benefit from each element being contiguous in memory and from the fact that more elements of the array will fit into cache at a time.

<p><aside class="note">

For more details, see [this talk](https://vimeo.com/649009599)

</aside></p>

</details>

This is something I [experimented](https://github.com/squeek502/named-character-references/commit/3e06d491b3191632860bc29ea8841175fe39e05d) quite [a bit](https://github.com/squeek502/named-character-references/commit/764e9db8aafbab7919a0e5f2725128a41ed5e330) with, but never got results from. I believe the problem is that the access patterns of the DAFSA don't really benefit from the 'struct of arrays' approach, even though it seems like they might. The `char` field *is* accessed repeatedly while searching a list of children, but all the other fields of the `Node` are almost always accessed after that search is finished, so any benefit we get from having the `char` fields contiguous, we lose just as much from having the other fields farther away from their associated `char`. As far as I can tell, it's overall equally-or-more efficient to just use a plain old array-of-structs for our DAFSA nodes.

### Entirely different data structures

I effectively pulled the DAFSA out of a hat, without surveying the possibilities much. Someone more well versed in the field of data structures will likely have some ideas about what's out there that could work better.

## Wrapping up

This article continually and relentlessly grew in scope, and has ended up quite a bit more in-depth than I originally imagined (this is something that's [familiar to me, unfortunately](https://www.ryanliptak.com/blog/every-rc-exe-bug-quirk-probably/)). If you've read this far, thank you, and I hope you were able to get something out of it.

Throughout the process of writing, I've accrued a number of improvements that I can make on top of my original [Ladybird pull request](https://github.com/LadybirdBrowser/ladybird/pull/3011):

- First-layer acceleration (`O(1)` lookup table)
- Binary searches over lists of child nodes
- (Potentially) second-layer acceleration  (`O(1)` lookup table)
- Use the 'lookahead' approach when there's no active insertion point
- More efficient insertion into the tokenizer input than a full reallocation of the entire buffer

So, a new pull request (or a few) to Ladybird will be forthcoming with some combination of these changes. However, I expect that exactly what those future PR(s) will look like may be shaped by the feedback I receive from this post, as I remain confident that better approaches than mine are out there, and, if you've read this article, you have all the knowledge necessary (and then some) to come up with an implementation of your own.

Finally, I'll leave you with some links:

- [Repository for the Zig implementation of my named character reference data structure](https://github.com/squeek502/named-character-references/)
- [Branch of my Ladybird fork that I used for benchmarking the different implementations](https://github.com/squeek502/ladybird/tree/all-in-one)

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

.mermaid-flowchart{font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:16px;fill:#ccc;}@keyframes edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}.mermaid-flowchart .edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear infinite;stroke-linecap:round;}.mermaid-flowchart .edge-animation-fast{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}.mermaid-flowchart .error-icon{fill:#a44141;}.mermaid-flowchart .error-text{fill:#ddd;stroke:#ddd;}.mermaid-flowchart .edge-thickness-normal{stroke-width:1px;}.mermaid-flowchart .edge-thickness-thick{stroke-width:3.5px;}.mermaid-flowchart .edge-pattern-solid{stroke-dasharray:0;}.mermaid-flowchart .edge-thickness-invisible{stroke-width:0;fill:none;}.mermaid-flowchart .edge-pattern-dashed{stroke-dasharray:3;}.mermaid-flowchart .edge-pattern-dotted{stroke-dasharray:2;}.mermaid-flowchart svg{font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:16px;}.mermaid-flowchart p{margin:0;}.mermaid-flowchart .label{font-family:"trebuchet ms",verdana,arial,sans-serif;color:#ccc;}.mermaid-flowchart .cluster-label text{fill:#F9FFFE;}.mermaid-flowchart .cluster-label span{color:#F9FFFE;}.mermaid-flowchart .cluster-label span p{background-color:transparent;}.mermaid-flowchart .rough-node .label text,.mermaid-flowchart .node .label text,.mermaid-flowchart .image-shape .label,.mermaid-flowchart .icon-shape .label{text-anchor:middle;}.mermaid-flowchart .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}.mermaid-flowchart .rough-node .label,.mermaid-flowchart .node .label,.mermaid-flowchart .image-shape .label,.mermaid-flowchart .icon-shape .label{text-align:center;}.mermaid-flowchart .node.clickable{cursor:pointer;}.mermaid-flowchart .edgeLabel{background-color:hsl(0, 0%, 34.4117647059%);text-align:center;border-radius: 100%;}.mermaid-flowchart .edgeLabel p{background-color:hsl(0, 0%, 84.4117647059%);border-radius:100%;}.mermaid-flowchart .edgeLabel.noRadius p{border-radius:0;}.mermaid-flowchart .edgeLabel rect{opacity:0.5;background-color:hsl(0, 0%, 84.4117647059%);fill:hsl(0, 0%, 84.4117647059%);}.mermaid-flowchart .labelBkg{background-color:rgba(87.75, 87.75, 87.75, 0.5); border-radius:100%;}.mermaid-flowchart .cluster rect{fill:hsl(180, 1.5873015873%, 28.3529411765%);stroke:rgba(255, 255, 255, 0.25);stroke-width:1px;}.mermaid-flowchart .cluster text{fill:#F9FFFE;}.mermaid-flowchart .cluster span{color:#F9FFFE;}.mermaid-flowchart div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:"trebuchet ms",verdana,arial,sans-serif;font-size:12px;background:hsl(20, 1.5873015873%, 12.3529411765%);border:1px solid rgba(255, 255, 255, 0.25);border-radius:2px;pointer-events:none;z-index:100;}.mermaid-flowchart .flowchartTitleText{text-anchor:middle;font-size:18px;fill:#ccc;}.mermaid-flowchart rect.text{fill:none;stroke-width:0;}.mermaid-flowchart .icon-shape,.mermaid-flowchart .image-shape{background-color:hsl(0, 0%, 34.4117647059%);text-align:center;}.mermaid-flowchart .icon-shape p,.mermaid-flowchart .image-shape p{background-color:hsl(0, 0%, 34.4117647059%);padding:2px;}.mermaid-flowchart .icon-shape rect,.mermaid-flowchart .image-shape rect{opacity:0.5;background-color:hsl(0, 0%, 34.4117647059%);fill:hsl(0, 0%, 34.4117647059%);}.mermaid-flowchart :root{--mermaid-font-family:"trebuchet ms",verdana,arial,sans-serif;}

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

.caption {
  background-color: rgba(0,0,0, .1);
  margin:0; padding: .25em;
  width: auto;
  max-width: 75%; display: inline-block;
  margin-left: auto; margin-right: auto;
}
</style>

</div>