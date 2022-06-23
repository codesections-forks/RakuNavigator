use nqp;
use QAST:from<NQP>;

say "Running navigator.raku";

my $code = $*IN.slurp;
my $file-path = @*ARGS[0];
say "Received file: $file-path\n";


sub parse-code( Str $source ) {
    # Parsing logic from https://github.com/Raku/Raku-Parser/blob/master/lib/Perl6/Parser.pm6

    my $*LINEPOSCACHE;

    my $compiler := nqp::getcomp('perl6');

    if !$compiler {
        $compiler := nqp::getcomp('Raku');
    }

    my $g := nqp::findmethod(
        $compiler,'parsegrammar'
    )($compiler);

    my $a := nqp::findmethod(
        $compiler,'parseactions'
    )($compiler);

    my $munged-source = $source;
    # Replace BEGIN/CHECK blocks, but only if they start the line or follow a semicolon
    # This will mess with the phaser list in the outline.
    $munged-source ~~ s:Perl5:g:m:sigspace/((?:^|;|})[ \t]*)BEGIN(?=\s)/{$0}ENTER/;
    $munged-source ~~ s:Perl5:g:m:sigspace/((?:^|;|})[ \t]*)CHECK(?=\s)/{$0}ENTER/;

    my $parsed = $g.parse(
        $munged-source,
        :p( 0 ),
        :actions( $a )
    );

    # Assuming the code can be parsed, then compile it too. Additional errors are available from the optimize level of checks.
    # TODO: This results in compiling twice and throws double warnings to STDERR How can I only compile once?
    note("90d0cb6c-4a53-427b-8d30-b1195895c2df\n");
    $compiler.compile($parsed);

    return $parsed;
}

# Warnings are not always capture in @worries. How do we get those?
my $parsed = try parse-code $code;
if $! { print-exc $! }

my $line_num = 0;
my $last_to = 0;
# Some lines are skipped, so you may need to match to the original.
for $parsed.hash.<statementlist>.hash.<statement>.list -> $k {
    #print $k.orig;
    #print substr( $k.orig, $k.from, $k.to - $k.from );
    my $missing = $k.from - $last_to;
    if ( $missing > 0 ) {
        # The parser excludes whitespace, so we need to add it back to keep the line count correct
        my $skipped = substr( $k.orig, $last_to, $missing );
        $line_num += $skipped.split("\n").elems() - 1;
    }
    $last_to = $k.to;
    my $subStr = $k.Str;
    my @lines = $subStr.split("\n");

    my $cleanContent = clean-content($subStr);

    my $var_continues = 0;

    match-constructs(@lines[0], $line_num, $cleanContent, $var_continues);

    loop (my $j = 1; $j < +@lines; $j++) {
        # Intentionally Skip first line where definition is.
        match-constructs(@lines[$j], $line_num + $j, @lines[$j], $var_continues);
    }
    $line_num += +@lines - 1;
}

sub clean-content($_) {
    # Strip trailing comments and whitespace for computing end of block line numbers
    if m:P5:s/(.*})[^}]+$/ { $0 }
    else                   { $_ }
}

sub match-constructs ($stmt_in, $line_number, $content, $var_continues is rw) {

    my $end_line = $line_number + $content.split("\n").elems() - 1;
    my $stmt = $stmt_in;
    given $stmt {
        s/^\s*//;
        s/^\#.*//;
        s/\s*$//;
        when .not {
            $var_continues = 0;
        }
        when $var_continues.so or m:P5/^(?:my|our|let|state)\b/ {
            $var_continues =  $stmt !~~ m:P5/;/ and $stmt !~~ m:P5/[\)\=\}\x7b]/ ;

            s/^(my|our|let|state)\s+//;
            s/\s*\=.*//;

            my @vars = m:P5:g/([\$\@\%](?:[\w\-]|::)+)/;
            for @vars -> $var {
                make-tag :name($var), :kind<v>, :lines($line_number);
            }
        }
        when m:P5/^multi\s+(?:(sub|method|submethod)\s+)?!?([\w\-]+)((?::[\w\-<>]+)?\s?\([^()]+\))/
                 # Grab signature for Multi-sub.
            or m:P5/^(sub|method|submethod)\s+!?([\w\-]+)(:[\w\-<>]+)?/ {
            # Captures multi-dispatch details and signature in $details for display in the outline,
            # different from the symbol name itself

            my $kind = (!defined($0) or $0 eq 'sub') ?? 's' !! 'o';
            my $details = $2 // '';
            make-tag :name($1), :$kind, :$details, :lines("$line_number;$end_line");

            $var_continues =  $stmt !~~ m:P5/;/ and $stmt !~~ m:P5/[\)\=\}\x7b]/;

            my @vars = m:P5:g/([\$\@\%](?:[\w\-]|::)+)/;
            for @vars -> $var {
                make-tag :name($var), :kind<v>, :lines($line_number);
            }
        }
        when m:P5/^(?:my )?class\s+((?:[\w\-]|::)+)/ {
            make-tag :name($0), :kind<a>, :lines("$line_number;$end_line");
        }
        when m:P5/^(?:my )?(?:proto )?role\s+([\w\-:<>]+)/ {
            make-tag :name($0), :kind<b>, :lines("$line_number;$end_line");
        }
        when m:P5/^(?:my )?token\s+([\w\-]+)(:[\w\-<>]+)?/ {
            my $details = $1 // '';
            make-tag :name($0), :kind<t>, :$details, :lines("$line_number;$end_line");
        }
        when m:P5/^(?:my )?rule\s+([\w\-]+)(:[\w\-<>]+)?/ {
            my $details = $1 // '';
            make-tag :name($0), :kind<r>, :$details, :lines("$line_number;$end_line");
        }
        when m:P5/^(?:my )?grammar\s+((?:[\w\-]|::)+)/ {
            make-tag :name($0), :kind<g>, :lines("$line_number;$end_line");
        }
        when m:P5/^has\s+(?:\w+\s+)?([$@%][\.\!][\w-]+)(?:\s|;|)/ {
            make-tag :name($0), :kind<f>, :lines("$line_number;$end_line");
        }
        when /^(BEGIN|CHECK|INIT|END)\s*\x7b/ {
            # Exclude for now given the source munging.
            # my $phaser = $0;
            # make-tag($phaser, "e", '', $file-path, "$line_number;$end_line");
        }
    }
    # TODO: object type detection
}

sub make-tag(:$name!, :$kind!, :$details = '', :$lines!) {
    # captures $file-path from lexical scope
    print "$name\t$kind\t$details\t$file-path\t$lines\n";
}

sub print-exc(Exception $_) {
    # We check a number of fields hunting for any defined errors
    my @errors = [ |(.?worries, |.?message).map({ %(exc => $_, level => 0)}),
                   |(.?sorrows, |.?panic  ).map({ %(exc => $_, level => 1)})
                 ].grep: *.<exc>.defined;

    if not @errors { # If we can't find an error, we'll use the gist of $!
        say "Could not figure out the error structure of" ~ $!.WHO;
        @errors.push: %(exc => .gist, level => 1);
    }

    my Str @output = @errors.map: -> (:$exc, :$level) {
        my $message = $exc.?message // $exc.gist;

        # Errors from some types appear to have the wrong .line (or I didn't find the correct attribute for $line)
        # We fix this by getting the correct line from the message, when it's printed
        my rule prefix { [used at lines?] || [Could not find \S+ at line] };
        my $line = ($message ~~ / <prefix> $<line>=(\S+) /) // $exc.?line // 0;

        ($line, $level, "$message\n").join: '~|~'
    }

    # Final `~||~` is probably not needed
    say "~||~@output.join('~||~')~||~" and exit 1;
}

# TODO: Figure out how to make symbol table parsing work
# for ::.kv -> $k, $v {
#     if ($k.starts-with('&')) {
#         make-tag($k, "s", $v.signature.gist(), $v.file, $v.line );
#     }
# }
