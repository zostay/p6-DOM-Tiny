unit class Mojo::DOM::CSS;
use v6;

use Mojo::DOM::HTML;

my class Matcher {
    has @.joiners;

    multi method ACCEPTS(::?CLASS:D: DocumentNode:D $current) {
        $current ~~ any(|@!joiners);
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class Joiner {
    has @.combine;

    submethod BUILD(:@combine) {
        @!combine = @combine.reverse;
    }
}

my class AncestorJoiner is Joiner {
    method no-gaps { False }

    multi method ACCEPTS(::?CLASS:D: DocumentNode:D $current) {
        return False unless $current ~~ @.combine[0];

        COMBINATION: for @.combine[1 .. *] -> $selector {
            for $current.ancestor-nodes(:context) -> $current {
                if $current ~~ $selector {
                    next COMBINATION;
                }
                elsif self.no-gaps {
                    return False;
                }
            }

            return False;
        }

        True;
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class ParentJoiner is AncestorJoiner {
    method no-gaps { True }
}

my class CousinJoiner is Joiner {
    method no-gaps { False }

    multi method ACCEPTS(::?CLASS:D: DocumentNode:D $current) {
        return False unless $current ~~ @.combine[0];

        my @cousins = $current.split-siblings<before>.reverse;

        COMBINATION: for @.combine[1 .. *] -> $selector {
            for @cousins -> $current {
                if $current ~~ $selector {
                    next COMBINATION;
                }
                elsif self.no-gaps {
                    return False;
                }
            }

            return False;
        }

        True;
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class SiblingJoiner is CousinJoiner {
    method no-gaps { True }
}

my class HasAttr {
    has $.name;

    submethod BUILD(:$name) {
        my $unescaped-name = _unescape($name);
        $!name = regex { [ ^ | ':' ] $unescaped-name $ };
    }

    multi method ACCEPTS(::?CLASS:D: Tag:D $current) {
        $current.attrs ~~ $!name
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class AttrIs is HasAttr {
    has $!value;

    submethod BUILD(:$op!, :$value!, :$i = False) {
        my $unescaped = _unescape($value);

        my $rx = do given $op {
            when '~=' { rx{  [ ^ | \s+ ] $unescaped [ \s+ | $ ] } }
            when '*=' { rx{ $unescaped } }
            when '^=' { rx{ ^ $unescaped } }
            when '$=' { rx{ $unescaped $ } }
            default   { rx{ ^ $unescaped $ } }
        }

        $rx = rx:i{ $rx } if $i;
        $!value = $rx;
    }

    multi method ACCEPTS(::?CLASS:D: Tag:D $current) {
        return False unless callsame;
        my $name = $current.attrs.keys.first($.name);
        $current.attrs{ $name } ~~ $!value;
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class TagMatch {
    has $.name;

    multi method ACCEPTS(::?CLASS:D: Tag:D $current) {
        $current ~~ Tag && $current.tag ~~ $!name
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class Pseudo { }

my class PseudoNot is Pseudo {
    has @.groups;

    multi method ACCEPTS(::?CLASS:D: Node:D $current) {
        $current ~~ none(|@!groups);
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class PseudoNth is Pseudo {
    has $.end = False;
    has $.of-type = False;
    has $.coeff;
    has $.offset;

    multi method ACCEPTS(::?CLASS:D: Tag:D $current) {
        my $which = $!end ?? 'after' !! 'before';
        my @siblings = $current.split-siblings(:tags-only){$which};
        @siblings .= grep({ .tag eq $current.tag }) if $!of-type;

        if $!coeff != 0 {
            (@siblings.elems + 1 - $!offset) %% $!coeff;
        }
        else {
            @siblings.elems + 1 == $!offset
        }
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class PseudoOnly is Pseudo {
    has $.of-type = False;

    multi method ACCEPTS(::?CLASS:D: Tag:D $current) {
        my @siblings = $current.siblings(:tags-only, :!including-self);
        @siblings .= grep({ .tag eq $current.tag }) if $!of-type;
        @siblings.elems == 0
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class PseudoEmpty is Pseudo {
    multi method ACCEPTS(::?CLASS:D: Tag:D $current) {
        $current.children.grep(none(Comment, PI)).elems == 0
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class PseudoChecked is Pseudo {
    multi method ACCEPTS(::?CLASS:D: Tag:D $current) {
        $current.attrs ~~ / ^ [ checked | selected ] $ /
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

my class PseudoRoot is Pseudo {
    multi method ACCEPTS(::?CLASS:D: DocumentNode:D $current) {
        $current.parent ~~ Root
    }

    multi method ACCEPT(::?CLASS:D: $) { False }
}

grammar Selector {
    rule TOP { <ancestor-child> +% ',' }

    rule ancestor-child { <ancestors=.parent-child> + }
    rule parent-child   { <family=.cousins> +% '>' }
    rule cousins        { <clans=.brother-sister> +% '~' }
    rule brother-sister { <siblings=.selector> +% '+' }

    proto rule selector      { * }
    rule selector:sym<class> { '.' <name> }
    rule selector:sym<id>    { '#' <name> }
    rule selector:sym<attr>  {
        '[' <attr-key> [ <attr-op> <attr-value> ]? ']'
    }
    token selector:sym<pseudo-class> {
        ':' <pseudo-class>
    }
    token selector:sym<tag> {
        [ <.escape> \s | '\\.' | <-[,.#:\[ >~+]> ]+ #]
    }
    token selector:sym<any> { '*' }

    proto rule pseudo-class { * }
    rule pseudo-class:sym<not>   { not <TOP> }
    rule pseudo-class:sym<nth>   { <nth-x> <equation> }
    rule pseudo-class:sym<first> { <first-x> }
    rule pseudo-class:sym<last>  { <last-x> }
    rule pseudo-class:sym<only>  { <only-x> }
    rule pseudo-class:sym<other> { empty | checked | root }

    token nth-x {
        | 'nth-child'
        | 'nth-last-child'
        | 'nth-of-type'
        | 'nth-last-of-type'
    }
    token first-x { 'first-child' | 'first-of-type' }
    token last-x  { 'last-child' | 'last-of-type' }
    token only-x  { 'only-child' | 'only-of-type' }

    proto rule equation { * }
    rule equation:sym<even>     { even }
    rule equation:sym<odd>      { odd }
    rule equation:sym<number>   { $<number> = [ <[+-]>? \d+ ] }
    rule equation:sym<function> {
        $<coeff>  = [ <[+-]>? [ \d+ ]? ]? n
        $<offset> = [ <[+-]>? \d+ ]?
    }

    token attr-key { [ <.escape> | <[\w -]> ]+ }
    token attr-value {
        [ '"' $<value> = [ [ '\\"' | <-["]> ]* ] '"'
        | "'" $<value> = [ [ "\\'" | <-[']> ]* ] "'"
        | $<value> = [ <-[\\]> ]+? ]
        [ \s+ $<case-i> = 'i' ]?
    }

    proto token attr-op { * }
    token attr-op:sym<=>  { '=' }
    token attr-op:sym<~=> { '~=' }
    token attr-op:sym<^=> { '^=' }
    token attr-op:sym<$=> { '$=' }
    token attr-op:sym<*=> { '*=' }

    token name { [ <.escape> | '\\.' | <-[,.#:[ >~+]> ]+ } #]
    token escape {
        | '\\' <-[0..9 a..f A..F]>
        | '\\' <[0..9 a..f A..F]> ** 1..6
    }
}

class Compiler {
    method TOP($/)   {
        make Matcher.new(joiners => $<ancestor-child>».made);
    }

    method ancestor-child($/) { make AncestorJoiner.new(combine => $<ancestors>».made) }
    method parent-child($/)   { make ParentJoiner.new(combine => $<family>».made) }
    method cousins($/)        { make CousinJoiner.new(combine => $<clans>».made) }
    method brother-sister($/) { make SiblingJoiner.new(combine => $<siblings>».made) }

    method selector:sym<class>($/) {
        make AttrIs.new(
            name  => 'class',
            op    => '~=',
            value => ~$<name>,
        )
    }
    method selector:sym<id>($/) {
        make AttrIs.new(
            name  => 'id',
            op    => '=',
            value => ~$<name>,
        )
    }
    method selector:sym<attr>($/) {
        with $<attr-op> {
            make AttrIs.new(
                name  => ~$<attr-key>,
                op    => ~$<attr-op>,
                |$<attr-value>.made,
            );
        }
        else {
            make HasAttr.new(name => ~$<attr-key>);
        }
    }
    method selector:sym<pseudo-class>($/) { make $<pseudo-class>.made }
    method selector:sym<tag>($/) { make TagMatch.new(name => (~$/).trim) }
    method selector:sym<any>($/) { make TagMatch.new(name => *) }

    method pseudo-class:sym<not>($/) {
        make PseudoNot.new(groups => $<TOP>.made)
    }
    method pseudo-class:sym<nth>($/) {
        my $nth              = ~<$nth-x>;
        my $end              = $nth ~~ / '-last-' /;
        my $of-type          = $nth.ends-with('-of-type');
        my ($coeff, $offset) = |$<equation>.made;

        make PseudoNth.new(:$end, :$of-type, :$coeff, :$offset);
    }
    method pseudo-class:sym<first>($/) {
        my $first   = ~$<first-x>;
        my $of-type = $first.ends-with('-of-type');

        make PseudoNth.new(:!end, :$of-type, :coeff(0), :offset(1));
    }
    method pseudo-class:sym<last>($/) {
        my $last    = ~$<first-x>;
        my $of-type = $last.ends-with('-of-type');

        make PseudoNth.new(:!end, :$of-type, :coeff(-1), :offset(1));
    }
    method pseudo-class:sym<only>($/) {
        make PseudoOnly.new(
            of-type => (~$<only-x>).ends-with('-of-type'),
        );
    }
    method pseudo-class:sym<other>($/) {
        given ~$/ {
            when 'empty'   { make PseudoEmpty }
            when 'checked' { make PseudoChecked }
            when 'root'    { make PseudoRoot }
        }
    }

    method equation:sym<even>($/)     { make [2, 2] }
    method equation:sym<odd>($/)      { make [2, 1] }
    method equation:sym<number>($/)   { make [0, (~$<number>).Int] }
    method equation:sym<function>($/) {
        my $coeff = do given ~$<coeff> {
            when '-' { -1 }
            default  { .Int }
        }
        my $offset = (~$<offset>).Int // 0;
        make [$coeff, $offset]
    }

    method attr-value($/) {
        my $i = (~$<case-i> eq 'i');
        make \(value => ~$<value>, :$i);
    }
}

has $.tree is rw;

method matches(Mojo::DOM::CSS:D: Str:D $css) returns Bool:D {
    my $*TREE-CONTEXT = $!tree;
    $!tree ~~ _compile($css);
}

method select(Mojo::DOM::CSS:D: Str:D $css) {
    my $*TREE-CONTEXT = $!tree;
    my $matcher = _compile($css);
    my @search = $!tree.child-nodes(:tags-only);
    gather while @search.shift -> $current {
        @search.prepend: $current.child-nodes(:tags-only);
        take $current if $current ~~ $matcher;
    }
}

method select-one(Mojo::DOM::CSS:D: Str:D $css) returns DocumentNode:D {
    self.select($css).first
}

my sub _compile($css) returns Matcher {
    Mojo::DOM::CSS::Selector.parse($css,
        actions => Mojo::DOM::CSS::Compiler,
    ).made;
}

my sub _unescape($value is copy) {
    # Remove escaped newlines
    $value .= trans([ "\\\n" ] => [ '' ]);

    # Unescape Unicode characters
    $value .= subst(/
        "\\" $<cp> = [ <[ 0..9 a..f A..F ]> ** 1..6 ] \s?
    /, { :16($<cp>).chr }, :global);

    # Remove backslash
    $value .= trans([ '\\' ] => [ '' ]);
}
