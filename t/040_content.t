#!perl
#
# This file is part of HTTP-Tiny
#
# This software is copyright (c) 2010 by Christian Hansen.
#
# This is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
#

use strict;
use warnings;

use Test::More qw[no_plan];
use t::Util    qw[tmpfile rewind $CRLF $LF];
use HTTP::Tiny;

{
    no warnings 'redefine';
    sub HTTP::Tiny::Handle::can_read  { 1 };
    sub HTTP::Tiny::Handle::can_write { 1 };
}

{
    my $chunk    = join('', '0' .. '9', 'A' .. 'Z', 'a' .. 'z', '_', $LF) x 16; # 1024
    my $fh       = tmpfile();
    my $handle   = HTTP::Tiny::Handle->new(fh => $fh);
    my $nchunks  = 128;
    my $length   = $nchunks * length $chunk;

    {
        my $got = $handle->write_content_body(sub { $nchunks-- ? $chunk : undef }, $length);
        is($got, $length, "written $length octets");
    }

    rewind($fh);

    {
        my $got = 0;
        $handle->read_content_body(sub { $got += length $_[0] }, $length);
        is($got, $length, "read $length octets");
    }
}

