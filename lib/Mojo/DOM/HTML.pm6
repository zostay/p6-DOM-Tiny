unit module Mojo::DOM::HTML;
use v6;

use Mojo::DOM::Entities;

grammar Tokenizer {
    token TOP { <html-token>* }

    token html-token { <markup> }

    proto token markup { * }
    token markup:sym<doctype> {
        '<!DOCTYPE' $<doctype> = [
        \s+ \w+                                                          # Doctype
        [ [ \s+ \w+ ]? [ \s+ [ '"' <-["]>* '"' | "'" <-[']>* "'" ] ]+ ]? # External ID
        [ \s+ "[" .+? "]" ]?                                             # Int Subset
        \s* ] '>'
    }
    token markup:sym<comment> { '<--' $<comment> = [ .*? ] '--' \s* '>' }
    token markup:sym<cdata> { '<[CDATA[' .*? ']]>' }
    token markup:sym<pi> { '<?' $<pi> = [ .*? ] '?>' }
    token markup:sym<tag> { '<' \s* <end-mark>? \s* <tag-name> [ \s+ <attr> ** 0..32766 ]? <empty-tag-mark>? '>' }
    token markup:sym<text> { <-[ < ]>+ }
    token markup:sym<runaway-lt> { '<' }

    token end-mark { '/' }
    token empty-tag-mark { '/' }
    token tag-name { <-[ < > \s ]>+ }

    rule attr { <attr-key> [ '=' <attr-value> ]? }
    token attr-key { <-[ < > = \s \/ ]>+ }
    token attr-value {
        | [ '"' $<raw-value> = [ .*? ] '"'  ]
        | [ "'" $<raw-value> = [ .*? ] "'" ]
        | [ $<raw-value> = <-[ > \s ]>* ]
    }
}

# HTML elements that only contain raw text
my %RAW = set <script stype>;

# HTML elements that only contain raw text and entities
my %RCDATA = set <title textarea>;

# HTML elements with optional end tags
my %END = body => 'head', optgroup => 'optgroup', option => 'option';

# HTML elements that break paragraphs
%END{$_} = 'p' for <
  address article aside blockquote dir div dl fieldset footer form h1 h2
  h3 h4 h5 h6 header hr main menu nav ol p pre section table ul
>;

# HTML table elements with optional end tags
my %TABLE = set <colgroup tbody td tfoot th thead tr>;

# HTML elements with optional end tags and scoping rules
my %CLOSE
  = li => [set <li>, set <ul ol>], tr => [set <tr>, set <table>];
%CLOSE{$_} = [%TABLE, set <table>] for <colgroup tbody tfoot thead>;
%CLOSE{$_} = [set <dd dt>, set <dl>] for <dd dt>;
%CLOSE{$_} = [set <rp rt>, set <ruby>] for <rp rt>;
%CLOSE{$_} = [set <th td>, set <table>] for <td th>;

# HTML elements without end tags
my %EMPTY = set <
  area base br col embed hr img input keygen link menuitem meta param
  source track wbr
>;

# HTML elements categorized as phrasing content (and obsolete inline elements)
my @PHRASING = <
  a abbr area audio b bdi bdo br button canvas cite code data datalist
  del dfn em embed i iframe img input ins kbd keygen label link map mark
  math meta meter noscript object output picture progress q ruby s samp
  script select slot small span strong sub sup svg template textarea time u
  var video wbr
>;
my @OBSOLETE = < acronym applet basefont big font strike tt >;
my %PHRASING = set @OBSOLETE, @PHRASING;

# HTML elements that don't get their self-closing flag acknowledged
my %BLOCK = set <
  a address applet article aside b big blockquote body button caption
  center code col colgroup dd details dialog dir div dl dt em fieldset
  figcaption figure font footer form frameset h1 h2 h3 h4 h5 h6 head
  header hgroup html i iframe li listing main marquee menu nav nobr
  noembed noframes noscript object ol optgroup option p plaintext pre rp
  rt s script section select small strike strong style summary table
  tbody td template textarea tfoot th thead title tr tt u ul xmp
>;

my class Runaway { }
class Node is export {
    method render(:$xml) { ... }
    method Str { self.render }
}

class Root { ... }
role HasChildren { ... }

class DocumentNode is export is Node {
    has HasChildren $.parent is rw;

    method root(DocumentNode:D:) {
        given $!parent {
            when not .defined { Nil }
            when Root         { $!parent }
            default           { $!parent.root }
        }
    }

    method ancestor-nodes(DocumentNode:D: Bool :$root = False, Bool :$context = False) {
        return () if $context && $*TREE-CONTEXT && self === $*TREE-CONTEXT;

        my $parent = $!parent;
        gather repeat {
            take $parent if $parent ~~ DocumentNode || $root;
            last if $context && $parent === $*TREE-CONTEXT;
        } while $parent ~~ DocumentNode &&
              ?($parent = $parent.parent);
    }

    method trimmable(DocumentNode:D:) returns Bool {
        !self.ancestor-nodes.first({ .tag eq 'pre' })
    }

    method siblings(DocumentNode:D: Bool :$tags-only = False, Bool :$including-self = True) {
        my $siblings = $!parent.child-nodes(:$tags-only);
        $siblings.grep({ $_ !=== self }) unless $including-self;
        $siblings
    }

    method split-siblings(DocumentNode:D: Bool :$tags-only) {
        my @us = $!parent.child-nodes(:$tags-only);
        my $pos = @us.first({ $_ === self }, :k);

        % = before => @us[0 .. $pos - 1],
            after  => @us[$pos + 1 .. *],
    }
}

class Tag { ... }
class Text { ... }
role TextNode { ... }

role HasChildren is export {
    has DocumentNode @.children is rw;

    method descendent-nodes(HasChildren:D: Bool :$tags-only = False) {
        flat self.child-nodes(:$tags-only).map(-> $node {
            if $node.WHAT ~~ Tag {
                ($node, $node.descendants(:$tags-only))
            }
            else {
                $node
            }
        });
    }

    method child-nodes(HasChildren:D: Bool :$tags-only = False) {
        if $tags-only {
            @!children.grep(Tag);
        }
        else {
            @!children;
        }
    }

    method content(HasChildren:D:) is rw {
        my $tree = self;
        Proxy.new(
            FETCH => method () { $tree.render },
            STORE => method ($html) {
                $tree.children = Mojo::DOM::HTML::_parse($html).children;
            },
        );
    }

    method !read-text(:$recurse, :$trim is copy) {
        $trim &&= self.trimmable;

        my $which-children = $recurse ?? TextNode | HasChildren !! TextNode;

        my $previous-chunk = '';
        [~] gather for self.child-nodes.grep($which-children)\
                                       .map({ .text(:$trim, :$recurse) })\
                                       .grep({ / \S+ / or !$trim }) -> $chunk {

            if $previous-chunk ~~ / \S $ / && $chunk ~~ /^ <-[ . ! ? , ; : \s ]>+ / {
                take " $chunk";
            }
            else {
                take $chunk;
            }

            $previous-chunk = $chunk;
        }
    }

    multi method text(HasChildren:D: Bool :$recurse = False, Bool :$trim = False) is rw {
        my $tree = self;
        Proxy.new(
            FETCH => method ()   { $tree!read-text(:$recurse, :$trim) },
            STORE => method ($t) {
                @!children = Text.new(text => $t);
            },
        );
    }

    method render-children(:$xml) { [~] @!children.map({ .render(:$xml) }); }
}

role TextNode is export {
    has Str $.text is rw = '';

    method !squished-text { $!text.trim.subst(/\s+/, ' ', :global) }

    multi method text(TextNode:D: Bool :$trim = False) {
        $trim &&= self.trimmable;
        $trim ?? self!squished-text !! $!text
    }

    multi method text(TextNode:D:) is rw { return-rw $!text }

    method content() is rw { $!text }
}

class CDATA is export is DocumentNode does TextNode {
    method render(:$xml) { '<![CDATA[' ~ $.text ~ ']]>' }
}

class Comment is export is DocumentNode {
    has Str $.comment is rw = '';

    method content() is rw { $!comment }

    method render(:$xml) { '<!--' ~ $!comment ~ '-->' }
}

class Doctype is export is DocumentNode {
    has Str $.doctype is rw = '';

    method content() is rw { $!doctype }

    method render(:$xml) { '<!DOCTYPE' ~ $!doctype ~ '>' }
}

class PI is export is DocumentNode {
    has Str $.pi is rw = '';

    method content() is rw { $!pi }

    method render(:$xml) { '<?' ~ $!pi ~ '?>' }
}

class Raw is export is DocumentNode does TextNode {
    method render(:$xml) { $!text }
}

class Tag is export is DocumentNode does HasChildren {
    has Str $.tag is rw is required;
    has %.attrs is rw;

    method render(:$xml) {
        # Start tag
        my $result = "<$!tag";

        # Attributes
        $result ~= [~] gather for %!attrs.sort».kv -> ($key, $value) {
            with $value {
                take qq{ $key="} ~ html-escape($value) ~ '"';
            }
            elsif $xml {
                take qq{ $key="$key"};
            }
            else {
                take " $key";
            }
        }

        # No children
        return $xml          ?? "$result />"
            !! %EMPTY{$!tag} ?? "$result>"
            !!                  "$result></$!tag>"
                unless @!children.elems > 0;

        # Children
        $result ~= '>' ~ self.render-children(:$xml);

        # End tag
        "$result\</$!tag>";
    }
}

class Text is export is DocumentNode does TextNode {
    method render(:$xml) { html-escape $!text; }
}

class Root is export is Node does HasChildren {
    method render(:$xml) { self.render-children(:$xml) }
}

class TreeMaker {
    has $.xml;

    my sub _end($end, $xml, $current is rw) {

        # Search stack for start tag
        my $next = $current;
        repeat {

            # Ignore useless end tag
            return if $next ~~ Root;

            # Right tag
            return $current = $next.parent if $next.tag eq $end;

            # Phrasing content can only cross phrasing content
            return if !$xml && %PHRASING{$end} && !%PHRASING{$next.tag};

        } while ?($next = $next.parent);

        # The above loop runs not without this? WTH?
        return;
    }

    my sub _start($start, %attrs, $xml, $current is rw) {

        # Autoclose optional HTML elements
        if !$xml && $current ~~ Root {
            if %END{$start} -> $end {
                _end($end, False, $current);
            }
            elsif %CLOSE{$start} -> $close {
                my (%allowed, %scope) = |$close;

                # Close allowed parent elements in scope
                my $parent = $current;
                while $parent !~~ Root && %scope ∌ $parent.tag {
                    _end($parent.tag, False, $current) if %scope ∋ $parent.tag;
                    $parent = $parent.parent;
                }
            }
        }

        # New tag
        $current.children.push: my $new = Tag.new(
            tag    => $start,
            attrs  => %attrs,
            parent => $current,
        );
        $current = $new;
    }

    method TOP($/) {
        my $current = my $tree = Root.new;

        my $xml = $.xml // False;
        for $<html-token>».made -> %markup {
            given %markup<type> {
                when Tag {

                    # End
                    if %markup<end> {
                        _end(%markup<tag>, $xml, $current);
                    }

                    # Start
                    else {
                        my $start   = %markup<tag>;
                        my %attrs   = %markup<attrs>;
                        my $closing = %markup<empty>;

                        # "image" is an alias for "img"
                        $start = 'img' if !$xml && $start eq 'image';
                        _start($start, %attrs, $xml, $current);

                        # Element without end tag (self-closing)
                        _end($start, $xml, $current)
                            if (!$xml && %EMPTY ∋ $start)
                                || (($xml || %BLOCK ∌ $start) && $closing);

                        # FIXME Raw text elements (NYI)
                        # CODE NEEDED SOMEWHERE...
                    }

                }

                when Doctype {
                    $current.children.push: Doctype.new(
                        doctype => %markup<doctype>,
                        parent => $current,
                    );
                }

                when Comment {
                    $current.children.push: Comment.new(
                        comment => %markup<comment>,
                        parent  => $current,
                    );
                }

                when Text {
                    $current.children.push: Text.new(
                        text   => %markup<text>,
                        parent => $current,
                    );
                }

                when PI {
                    $current.children.push: PI.new(
                        pi     => %markup<pi>,
                        parent => $current,
                    );
                }

                when Runaway {
                    $current.children.push: Text.new(
                        text   => '<',
                        parent => $current,
                    );
                }
            }
        }

        make $tree;
    }

    method html-token($/) {
        make $<markup>.made;
    }

    method markup:sym<text>($/) {
        make {
            type => Text,
            text => ~$/,
        }
    }

    method markup:sym<tag>($/) {
        make {
            type  => Tag,
            end   => ?$<end-mark>,
            tag   => $.xml ?? ~$<tag-name> !! (~$<tag-name>).lc,
            attrs => Hash.new($<attr>».made),
            empty => ?$<empty-tag-mark>,
        }
    }

    method markup:sym<doctype>($/) {
        make {
            type    => Doctype,
            doctype => ~$<doctype>,
        }
    }

    method markup:sym<comment>($/) {
        make {
            type    => Comment,
            comment => ~$<comment>,
        }
    }

    method markup:sym<cdata>($/) {
        make {
            type  => CDATA,
            cdata => ~$<cdata>,
        }
    }

    method markup:sym<pi>($/) {
        $!xml = True if !defined $!xml && (~$<pi>) ~~ /^ xml >>/;
        make {
            type => PI,
            pi   => ~$<pi>,
        }
    }

    method markup:sym<runaway-lt>($/) {
        make { type => Runaway }
    }

    method attr($/) {
        if $<attr-value> {
            make $<attr-key>.made => $<attr-value>.made;
        }
        else {
            make $<attr-key>.made => Nil;
        }
    }

    # TODO It would be nicer if we had a case-insensitive hash
    method attr-key($/)   { make $!xml ?? ~$/ !! (~$/).lc }
    method attr-value($/) { make html-unescape ~$<raw-value> }
}

our sub _parse($html, :$xml) {
    Mojo::DOM::HTML::Tokenizer.parse($html,
        actions => Mojo::DOM::HTML::TreeMaker.new(:$xml),
    ).made;
}

