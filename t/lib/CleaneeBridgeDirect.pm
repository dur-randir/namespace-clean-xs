package CleaneeBridgeDirect;
use strict;

use namespace::clean::xs ();

sub import {
    namespace::clean::xs->clean_subroutines(scalar(caller), qw( d_foo d_baz ));
}

1;
