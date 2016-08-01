unit class DOM::Tiny;
use v6;

use DOM::Tiny::CSS;
use DOM::Tiny::HTML;

my package EXPORT::DEFAULT {
    for < Root Text Tag Raw PI Doctype Comment CDATA DocumentNode Node HasChildren TextNode > -> $type {
        OUR::{ "$type" } := DOM::Tiny::HTML::{ $type };
    }
}

has Node $.tree = Root.new;
has Bool $.xml = False;

multi method Bool(DOM::Tiny:U:) returns Bool:D { False }
multi method Bool(DOM::Tiny:D:) returns Bool:D { True }

method AT-POS(DOM::Tiny:D: Int:D $i) is rw { self.child-nodes[$i] }
method list(DOM::Tiny:D:) { self.child-nodes }

method AT-KEY(DOM::Tiny:D: Str:D $k) is rw {
    Proxy.new(
        FETCH => method ()   { self.attr($k) },
        STORE => method ($v) { self.attr($k, $v) },
    );
}
method hash(DOM::Tiny:D:) { self.attr }

multi method parse(DOM::Tiny:U: Str:D $html, Bool :$xml = False) returns DOM::Tiny:D {
    my $tree = DOM::Tiny::HTML::_parse($html, :$xml);
    DOM::Tiny.new(:$tree, :$xml);
}

multi method parse(DOM::Tiny:D: Str:D $html, Bool :$xml) returns DOM::Tiny:D {
    $!xml  = $xml with $xml;
    $!tree = DOM::Tiny::HTML::_parse($html, :$!xml);
    self
}

multi to-json(DOM::Tiny:D $dom) is export {
    my $xml = $dom.xml // False;
    DOM::Tiny::HTML::_render($dom.tree, :$xml)
}

method all-text(DOM::Tiny:D: Bool :$trim = True) {
    $!tree.text(:recurse, :$trim);
}

method ancestors(DOM::Tiny:D: Str $selector?) {
    self!select(self.tree.ancestor-nodes, $selector);
}

method append(DOM::Tiny:D: Str:D $html) returns DOM::Tiny:D {
    if $!tree ~~ DocumentNode {
        $!tree.parent.children.append:
            _link($!tree.parent, DOM::Tiny::HTML::_parse($html).child-nodes)
    }

    self;
}

method append-content(DOM::Tiny:D: Str:D $html) {
    if $!tree ~~ HasChildren {
        my @children = DOM::Tiny::HTML::_parse($html, :$!xml).children;
        $!tree.children.append:
            _link($!tree, DOM::Tiny::HTML::_parse($html, :$!xml).children);
        self;
    }
    elsif $!tree ~~ TextNode {
        my $parent = $!tree.parent;
        $parent.children.append:
            _link($parent, DOM::Tiny::HTML::_parse($html, :$!xml).children);
        $.parent;
    }
    else {
        self;
    }
}

method at(DOM::Tiny:D: Str:D $css) returns DOM::Tiny {
    if $.css.select-one($css) -> $tree {
        self.new(:$tree, :$!xml);
    }
    else {
        Nil
    }
}

multi method attr(DOM::Tiny:D: Str:D $name) returns Str {
    $.attr{ $name } // Str;
}

multi method attr(DOM::Tiny:D: Str:D $name, Str:D $value) returns DOM::Tiny:D {
    $.attr{ $name } = $value;
    self;
}

multi method attr(DOM::Tiny:D: *%values) {
    return $!tree !~~ Tag ?? {} !! $!tree.attr unless %values;
    $.attr{ keys %values } = values %values;
    self;
}

method child-nodes(DOM::Tiny:D: Bool :$tags-only = False) {
    return () unless $!tree ~~ HasChildren;
    self!select($!tree.child-nodes(:$tags-only));
}

method children(DOM::Tiny:D: Str $css?) {
    return () unless $!tree ~~ HasChildren;
    self!select($!tree.child-nodes(:tags-only), $css);
}

multi method content(DOM::Tiny:D: Str:D $html) returns DOM::Tiny:D {
    $!tree.content = $html;
    self;
}

multi method content(DOM::Tiny:D:) is rw returns Str:D { $!tree.content }

method descendant-nodes(DOM::Tiny:D:) {
    return () unless $!tree ~~ HasChildren;
    self!select($!tree.descendant-nodes);
}
method find(DOM::Tiny:D: Str:D $css) {
    $.css.select($css).map({
        DOM::Tiny.new(tree => $_, :$!xml)
    });
}
method following(DOM::Tiny:D: Str $css?) {
    self!select(self!siblings(:tags-only)<after>, $css)
}
method following-nodes(DOM::Tiny:D:) { self!siblings()<after> }

method matches(DOM::Tiny:D: Str:D $css) { $.css.matches($css) }

method namespace(DOM::Tiny:D:) returns Str {
    return Nil if $!tree !~~ Tag;

    # Extract namespace prefix and search parents
    my $ns = $!tree.tag ~~ /^ (.*?) ':' / ?? "xmlns:$/[0]" !! Str;
    for $!tree.ancestors -> $node {
        # Namespace for prefix
        with $ns {
            for $node.attr.kv -> $name, $value {
                return $value if $name ~~ $ns;
            }
        }
        orwith $node.attr<xmlns> {
            return $node.attr<xmlns>;
        }
    }

    return Str;
}

method next(DOM::Tiny:D:) {
    self!maybe(self!siblings(:tags-only, :pos(0))<after>);
}

method next-node(DOM::Tiny:D:) {
    self!maybe(self!siblings(:pos(0))<after>);
}

method parent(DOM::Tiny:D:) returns DOM::Tiny {
    if $!tree ~~ Root {
        Nil
    }
    else {
        self.new(:tree($!tree.parent), :$!xml);
    }
}

method preceding(DOM::Tiny:D: Str $css?) {
    self!select(self!siblings(:tags-only)<before>, $css);
}
method preceding-nodes(DOM::Tiny:D:) {
    self!siblings()<before>;
}

method prepend(DOM::Tiny:D: Str:D $html) returns DOM::Tiny:D {
    if $!tree ~~ DocumentNode {
        $!tree.parent.children.prepend:
            _link($!tree.parent, DOM::Tiny::HTML::_parse($html).child-nodes);
    }

    self;
}
method prepend-content(DOM::Tiny:D: Str:D $html) {
    if $!tree ~~ HasChildren {
        $!tree.children.prepend:
            _link($!tree, DOM::Tiny::HTML::_parse($html).child-nodes);
    }
    elsif $!tree ~~ TextNode {
        my $parent = $!tree.parent;
        $parent.children.prepend:
            _link($parent, DOM::Tiny::HTML::_parse($html, :$!xml).children);
        $.parent;
    }
    else {
        self;
    }
}

method previous(DOM::Tiny:D:) {
    self!maybe(self!siblings(:tags-only, :pos(*-1))<before>);
}
method previous-node(DOM::Tiny:D:) {
    self!maybe(self!siblings(:pos(*-1))<before>);
}

method remove(DOM::Tiny:D:) { self.replace('') }

method replace(DOM::Tiny:D: Str:D $html) {
    if $!tree ~~ Root {
        self.parse($html);
    }
    else {
        self!replace: $!tree.parent, $!tree,
            DOM::Tiny::HTML::_parse($html).child-nodes
    }
}

method root(DOM::Tiny:D:) {
    $!tree ~~ Root ?? self !! $!tree.root
}

method strip(DOM::Tiny:D:) {
    if $!tree ~~ Tag {
        self!replace: $!tree.children, $!tree, $!tree.child-nodes;
    }
    else {
        self;
    }
}

multi method tag(DOM::Tiny:D:) returns Str {
    $!tree ~~ Tag ?? $!tree.tag !! Nil
}

multi method tag(DOM::Tiny:D: Str:D $tag) returns DOM::Tiny:D {
    if $!tree ~~ Tag {
        $!tree.tag = $tag;
    }
    self;
}

method text(DOM::Tiny:D: Bool :$trim, Bool :$recurse) {
    $!tree.text(:$trim, :$recurse);
}
method render(DOM::Tiny:D:) {
    $!tree.render(:$!xml);
}
multi method Str(DOM::Tiny:D:) { self.render }

method type(DOM::Tiny:D:) { $!tree.WHAT }

my multi _val(Tag, 'option', $dom) { $dom<value> // $dom.text }
my multi _val(Tag, 'input', $dom) {
    if $dom<type> eq 'radio' | 'checkbox' {
        $dom<value> // 'on';
    }
    else {
        $dom<value>
    }
}
my multi _val(Tag, 'button', $dom) { $dom<value> }
my multi _val(Tag, 'textarea', $dom) { $dom.text }
my multi _val(Tag, 'select', $dom) {
    my $v = $dom.find('option:checked').map({ .val });
    $dom<multiple>:exists ?? $v !! $v[*]
}
my multi _val($, $, $dom) { Nil }

method val(DOM::Tiny:D:) returns Str {
    _val($.type, $.tag, self);
}

method wrap(DOM::Tiny:D: Str:D $html) {
    _wrap($!tree.parent, ($!tree,), $html);
    self
}
method wrap-content(DOM::Tiny:D: Str:D $html) {
    _wrap($!tree, $!tree.children, $html) if $!tree ~~ HasChildren;
    self
}

method css(DOM::Tiny:D:) { DOM::Tiny::CSS.new(:$!tree) }

my sub _link($parent, @children) {

    # Link parent to children
    for @children -> $node {
        $node.parent = $parent;
    }

    return @children;
}

method !maybe($tree) {
    $tree ?? DOM::Tiny.new(:$tree, :$!xml) !! Nil
}

method !replace($parent, $child, @nodes) {
    my $i = $parent.children.first({ $child === $_ }, :k);
    $parent.children.splice: $i, 1, _link($parent, @nodes);
    $.parent;
}

method !select($collection, $selector?) {
    my $list := $collection.map: { DOM::Tiny.new(:$^tree, :$!xml) };
    if $selector {
        $list.grep({ .matches($selector) });
    }
    else {
        $list
    }
}

method !siblings(:$tags-only = False, :$pos) {
    my %split = do if $!tree ~~ DocumentNode {
        $!tree.split-siblings(:$tags-only);
    }
    else {
        { before => [], after => [] },
    }

    with $pos {
        for <before after> -> $k {
            %split{$k} = %split{$k}[$pos] ?? %split{$k}[$pos] !! Nil;
        }
    }

    %split;
}

my sub _wrap($parent, @nodes, $html) {
    my $innermost = my $wrapper = DOM::Tiny::HTML::_parse($html);
    while $innermost.child-nodes(:tags-only)[0] -> $next-inner {
        $innermost = $next-inner;
    }

    $innermost.children.append: _link($innermost, @nodes);
    my $i = $parent.children.first({ $_ === any(|@nodes) }, :k) // *;
    $parent.children.splice: $i, 0, _link($parent, $wrapper.children);
    $parent.children .= grep({ $_ !=== any(|@nodes) });
}