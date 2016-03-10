use strict;
use constant HAS_LEAKTRACE => eval{ require Test::LeakTrace };
use Test::More HAS_LEAKTRACE ? ('no_plan') : (skip_all => 'requires Test::LeakTrace');
use Test::LeakTrace;

package Foo;
package main;

no_leaks_ok {
    eval 'use namespace::clean::xs -cleanee => "Foo"';
};

no_leaks_ok {
    eval 'use namespace::clean::xs -cleanee => "Foo", "foo", "bar"';
};

use namespace::clean::xs;

BEGIN {
    no_leaks_ok {
        namespace::clean::xs->get_class_store('main');
    };

    no_leaks_ok {
        namespace::clean::xs->get_functions('main');
    };
}