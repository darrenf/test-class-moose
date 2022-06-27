package Quux;

use strict;
use warnings;
use namespace::autoclean;

use Test::Class::Moose bare => 1;

use Test2::V0 '!meta';

# initialise some local data using implicit $_
my @x;
while (<DATA>) {
    chomp;
    push @x, $_;
}

sub test_quux {
    ok(1);
}

1;

__DATA__
Quux
