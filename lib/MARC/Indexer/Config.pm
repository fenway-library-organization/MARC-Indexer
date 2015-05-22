package MARC::Indexer::Config;

use strict;
use warnings;

use constant SPACE => 1 << 0;
use constant PLAIN => 1 << 1;
use constant QUOTE => 1 << 2;
use constant GROUP => 1 << 3;
use constant COMMA => 1 << 4;
use constant SEMIC => 1 << 5;
use constant ASTER => 1 << 6;
use constant NEWLN => 1 << 7;

sub new {
    my ($cls, $f) = @_;
    bless {
        'file' => $f,
    }, $cls;
}

sub parse {
    my ($self, $f) = @_;
    $f = $self->{'file'} || die "No file given"
        if !defined $f;
    open my $fh, '<', $f or die "Can't open file $f: $!";
    local $/;
    my $src = $self->{'source'} = <$fh>;
    $src =~ s/^\s*#.*//mg;
    my @tok = _tokenize($src);
    my %term;
    $self->{'tokens'} = \@tok;
    $self->{'terms'}  = \%term;
    while (@tok) {
        _wsp(\@tok);
        _docid(\@tok, \$self->{'docid'})
        || _defaults(\@tok, $self)
        || _term(\@tok, \%term)
        || _fatal("Unparseable", $tok[0][2]);
    }
    return $self;
}

sub _wspafter {
    my ($tok) = @_;
    my $n = 0;
    $n++, pop @$tok while @$tok && $tok->[-1][0] == SPACE;
    $n;
}

sub _wsp {
    my ($tok) = @_;
    my $n = 0;
    $n++, shift @$tok while @$tok && $tok->[0][0] == SPACE;
    $n;
}

sub _last {
    my ($tok, $typ, $val) = @_;
    _wspafter($tok);
    return if !@$tok
           || defined($typ) && !($tok->[-1][0] & $typ)
           || ref($val)     && $tok->[-1][1] !~ $val
           || defined($val) && $tok->[-1][1] ne $val;
    return @{ pop @$tok };
}

sub _next {
    my ($tok, $typ, $val) = @_;
    _wsp($tok);
    return if !@$tok
           || defined($typ) && !($tok->[0][0] & $typ)
           || ref($val)     && $tok->[0][1] !~ $val
           || defined($val) && $tok->[0][1] ne $val;
    return @{ shift @$tok };
}

sub _docid {
    # docid FIELD;
    my ($tok, $ref) = @_;
    return if @$tok < 3;
    my ($typ, $val, $lno);
    ($typ, $val, $lno) = _next($tok, PLAIN, 'docid') or return;
    ($typ, $val, $lno) = _next($tok, PLAIN) or return;
    $$ref = $val;
    ($typ, $val, $lno) = _next($tok, SEMIC) or fatal("Junk after docid declaration");
}

sub _defaults {
    # defaults { foo; bar; }
    my ($tok, $self) = @_;
    return if @$tok < 3;
    my ($typ, $val, $lno, %def);
    ($typ, $val, $lno) = _next($tok, PLAIN, 'defaults') or return;
    $self->{'defaults'} = \%def;
    _term_body($tok, \%def);
    1;
}

sub _term {
    # term * { foo; bar; }
    # term foo "bar" { baz; qux; }
    my ($tok, $terms) = @_;
    return if @$tok < 4;
    my ($typ, $val, $lno);
    ($typ, $val, $lno) = _next($tok, PLAIN, 'term') or return;
    ($typ, $val, $lno) = _next($tok, ASTER|PLAIN  ) or return;
    my %term;
    $terms->{$val} = \%term;
    $term{'description'} = $val if ($typ, $val, $lno) = _next($tok, QUOTE);
    _term_body($tok, \%term);
    1;
}

sub _term_body {
    my ($tok, $term) = @_;
    _wsp($tok);
    my ($typ, $val, $lno);
    ($typ, $val, $lno) = _next($tok, GROUP, '{') or die;
    my @prop;
    while (1) {
        _wsp($tok);
        ($typ, $val, $lno) = _next($tok) or die;
        if ($typ == GROUP && $val eq '}') {
            if (@prop) {
                my ($pkey, $pval) = _mkprop(@prop);
                $term->{$pkey} = $pval;
            }
            last;
        }
        elsif ($typ == SEMIC) {
            next if !@prop;
            my ($pkey, $pval) = _mkprop(@prop);
            $term->{$pkey} = $pval;
            @prop = ();
        }
        elsif (!@prop && $typ == PLAIN) {
            push @prop, $val;
        }
        elsif (@prop) {
            push @prop, [$typ, $val];
        }
        else {
            die;
        }
    }
}

sub _mkprop {
    my $pkey = shift;
    if (!@_) {
        return ($pkey, '') if $pkey =~ s/^no//;
        return ($pkey, 1);
    }
    if (_next(\@_, GROUP, '[')) {
        _last(\@_, GROUP, ']') or _fatal("Unclosed list");
        my @list;
        while (1) {
            _wsp(\@_);
            my ($typ, $val, $lno) = _next(\@_, PLAIN|QUOTE)
                or _fatal("Unrecognized list element");
            push @list, $val;
            _next(\@_, COMMA) or last;
        }
        _wsp(\@_);
        _fatal("Junk at end of list") if @_;
        return ($pkey, \@list);
    }
    return ($pkey, join(' ', map { $_->[1] } @_));
}

sub _fatal {
    my ($err, $lno) = @_;
    print STDERR "FATAL: $err at line $lno\n";
    exit 2;
}

sub _tokenize {
    local $_ = shift;
    my @tok;
    my $lno = 1;
    while (!/\G\z/gc) {
        $lno++, next if /\G\n/gc;
        push @tok,
            /\G(\s+)/gc                  ? [ SPACE,  $1,         $lno    ] :
            /\G([:.\/\w][-:.\$\/\w]*)/gc ? [ PLAIN,  $1,         $lno    ] :
            /\G"((?:\\.|[^"])*)"/gc      ? [ QUOTE,  _unesc($1), $lno    ] :
            /\G(,)/gc                    ? [ COMMA,  $1,         $lno    ] :
            /\G(;)/gc                    ? [ SEMIC,  $1,         $lno    ] :
            /\G(\*)/gc                   ? [ ASTER,  $1,         $lno    ] :
            /\G([(){}\[\]])/gc           ? [ GROUP,  $1,         $lno    ] :
            _fatal("Unrecognized", $lno)
            ;
    }
    return @tok;
}

sub _unesc {
    local $_ = shift;
    s/\\(.)|(.)/defined($1) ? $1 : $2/eg;
    return $_;
}

1;

__END__
# Example

docid id;

defaults {
    repeat;
    noparse;
    nostem;
    nodefault;
    nonorm;
}

term mtyp "Material type" {
    source 007/0-1;
    default "--";
    prefix XMT;
    norm [lowercase, blank2hash];
}

term id "Bib ID" {
    norepeat;
    source 001;
    match numeric;
    prefix Q;
}

term rtyp "Record type" {
    source L/06;
    norepeat;
    norm [lowercase, blank2hash];
    prefix XRT;
}

term mform "Material form" {
    source 006/0;
    norm [lowercase, blank2hash];
    prefix XMF;
}

term mtyp "Material type" {
    source 007/0-1;
    default "--";
    norm [lowercase, blank2hash];
    prefix XMT;
}

term sig "Record signature" {
    permute [rtyp, mtyp];
    prefix XRS;
}

term rdacontent "RDA content type" {
    source 336$b;
    norm [trim, lowercase];
    prefix X6R;
}

term rdamedia "RDA media type" {
    source 337$b;
    norm [trim, lowercase];
    prefix X7R;
}

term rdacarrier "RDA carrier type" {
    source 338$b;
    norm [trim, lowercase];
    prefix X8R;
}

term title "Title" {
    source 245$abfgknps;
    norm [lowercase, trim, nfc];
    parse;
    stem english;
    prefix [S, ""];
}

term descrip "Physical description" {
    source 300$abcefg;
    norm [lowercase, trim];
    parse;
    stem english;
    prefix [XDE, ""];
}

term gmd "General material designation" {
    source 245$h;
    norm [lowercase, alpha, trim];
    parse;
    stem english;
    prefix [XGM, ""];
}

term inst "Holding institution" {
    source 9ho$i;
    prefix XHI;
}

term loc "Location" {
    source 9ho$l;
    prefix XHL;
}

term group "Record load institution" {
    source 9bl$g;
    prefix XBG;
}

term proj "Record load project" {
    source 9bl$p;
    prefix XBP;
}

term update "Record load update" {
    source 9bl$u;
    prefix XBU;
}

term batch "Record load batch" {
    source 9bl$b;
    prefix XBB;
}

term job "Record load job" {
    source 9bl$j;
    prefix XBJ;
}

