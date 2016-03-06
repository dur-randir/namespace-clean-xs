package namespace::clean::xs;
use 5.008001;
use strict;

our $VERSION = '0.01';

require XSLoader;
XSLoader::load('namespace::clean::xs', $VERSION);

1;
