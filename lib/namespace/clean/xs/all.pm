package namespace::clean::xs::all;
use strict;
use namespace::clean::xs ();

BEGIN {
    our $VERSION = $namespace::clean::xs::VERSION;

    $INC{'namespace/clean.pm'} = $INC{'namespace/clean/xs.pm'};

    for my $glob (keys %namespace::clean::xs::) {
        no strict 'refs';
        next unless defined *{"namespace::clean::xs::$glob"}{CODE};

        *{"namespace::clean::$glob"} = *{"namespace::clean::xs::$glob"}{CODE};
    }
}

1;
__END__

=cut
