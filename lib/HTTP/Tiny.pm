#
# This file is part of HTTP-Tiny
#
# This software is copyright (c) 2010 by Christian Hansen.
#
# This is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
#
# vim: ts=4 sts=4 sw=4 et:
package HTTP::Tiny;
BEGIN {
  $HTTP::Tiny::VERSION = '0.001';
}
use strict;
use warnings;
# ABSTRACT: A tiny HTTP client

use Carp ();

my @attributes;
BEGIN {
    @attributes = qw(agent default_headers max_redirect max_size proxy timeout);
    no strict 'refs';
    for my $accessor ( @attributes ) {
        *{$accessor} = sub { 
            @_ > 1 ? $_[0]->{$accessor} = $_[1] : $_[0]->{$accessor};
        };
    }
}

sub new {
    my($class, %args) = @_;
    (my $agent = $class) =~ s{::}{-}g;
    my $self = {
        agent        => $agent . "/" . $class->VERSION,
        max_redirect => 5,
        timeout      => 60,
    };
    for my $key ( @attributes ) {
        $self->{$key} = $args{$key} if exists $args{$key}
    }
    return bless $self, $class;
}

sub get {
    my ($self, $url, $args) = @_;
    @_ == 2 || (@_ == 3 && ref $args eq 'HASH')
      or Carp::croak(q/Usage: $http->get(URL, [HASHREF])/);
    return $self->request('GET', $url, $args || {});
}

sub request {
    my ($self, $method, $url, $args) = @_;
    @_ == 3 || (@_ == 4 && ref $args eq 'HASH')
      or Carp::croak(q/Usage: $http->request(METHOD, URL, [HASHREF])/);

    my $response = eval { $self->_request($method, $url, $args) };

    if (my $e = "$@") {
        $response = {
            status  => 599,
            reason  => 'Internal Exception',
            content => $e,
            headers => {
                'content-type'   => 'text/plain',
                'content-length' => length $e,
            }
        };
    }
    return $response;
}

my %DefaultPort = (
    http => 80,
    https => 443,
);

sub _request {
    my ($self, $method, $url, $args) = @_;

    my ($scheme, $host, $port, $path_query) = $self->_split_url($url);

    my $request = {
        method    => $method,
        scheme    => $scheme,
        host_port => ($port == $DefaultPort{$scheme} ? $host : "$host:$port"),
        uri       => $path_query,
        headers     => {},
    };

    my $handle  = HTTP::Tiny::Handle->new(timeout => $self->{timeout});

    if ($self->{proxy}) {
        $request->{uri} = "$scheme://$request->{host_port}$path_query";
        # XXX CONNECT for https scheme
        $handle->connect(($self->_split_url($self->{proxy}))[0..2]);
    }
    else {
        $handle->connect($scheme, $host, $port);
    }

    $self->_prepare_headers_and_cb($request, $args);
    $handle->write_request($request);

    my $response;
    do { $response = $handle->read_response_header }
        until ($response->{status} ne '100');

    if ( my $location = $self->_maybe_redirect($request, $response, $args) ) {
        $handle->close;
        return $self->_request($method, $location, $args);
    }

    if ($method eq 'HEAD' || $response->{status} =~ /^[23]04/) {
        # response has no message body
    }
    else {
        my $data_cb = $self->_prepare_data_cb($response, $args);
        $handle->read_body($data_cb, $response->{headers}{'content-length'});
    }

    $handle->close;
    return $response;
}

sub _prepare_headers_and_cb {
    my ($self, $request, $args) = @_;

    for ($self->{default_headers}, $args->{headers}) {
        next unless defined;
        while (my ($k, $v) = each %$_) {
            $request->{headers}{lc $k} = $v;
        }
    }
    $request->{headers}{'host'}         = $request->{host_port};
    $request->{headers}{'connection'}   = "close";
    $request->{headers}{'user-agent'} ||= $self->{agent};

    if (defined $args->{content}) {
        if (ref $args->{content} eq 'CODE') {
            $request->{headers}{'transfer-encoding'} = 'chunked'
              unless $request->{headers}{'content-length'}
                  || $request->{headers}{'transfer-encoding'};
            $request->{cb} = $args->{content};
        }
        else {
            my $content = $args->{content};
            utf8::downgrade($content, 1)
              or Carp::croak(q/Wide character in request message body/);
            $request->{headers}{'content-length'} = length $content
              unless $request->{headers}{'content-length'}
                  || $request->{headers}{'transfer-encoding'};
            $request->{cb} = sub { substr $content, 0, length $content, '' };
        }
    }
    return;
}

sub _prepare_data_cb {
    my ($self, $response, $args) = @_;
    my $data_cb = $args->{data_callback};
    $response->{content} = '';

    # XXX Should max_size apply even if a data callback is provided?
    # Perhaps it should for consistency. I'm also not clear why
    # max_size should be ignored on status other than 2XX.  Perhaps
    # all $data_cb's should be wrapped in a max_size checking
    # callback if max_size is true -- dagolden, 2010-12-02
    if (!$data_cb || $response->{status} !~ /^2/) {
        if (defined $self->{max_size}) {
            $data_cb = sub {
                $response->{content} .= $_[0];
                Carp::croak(qq/Size of response body exceeds the maximum allowed of $self->{max_size}/)
                  if length $response->{content} > $self->{max_size};
            };
        }
        else {
            $data_cb = sub { $response->{content} .= $_[0] };
        }
    }
    return $data_cb;
}

sub _maybe_redirect {
    my ($self, $request, $response, $args) = @_;
    my $headers = $response->{headers};
    if (   $response->{status} =~ /^30[12]/
        && $request->{method} =~ /^GET|HEAD$/
        && $headers->{location}
        && $args->{redirects}++ < $self->{max_redirect}
    ) {
        return ($headers->{location} =~ /^\//)
            ? "$request->{scheme}://$request->{host_port}$headers->{location}"
            : $headers->{location} ;
    }
    return;
}

sub _split_url {
    my $url = pop;

    my ($scheme, $authority, $path_query) = $url =~ m<\A([^:/?#]+)://([^/?#]+)([^#]*)>
      or Carp::croak(qq/Cannot parse URL: '$url'/);

    $scheme     = lc $scheme;
    $path_query = "/$path_query" unless $path_query =~ m<\A/>;

    my $host = lc $authority;
       $host =~ s/\A[^@]*@//;   # userinfo
    my $port = do {
       $host =~ s/:([0-9]*)\z// && length $1
         ? $1
         : ($scheme eq 'http' ? 80 : $scheme eq 'https' ? 443 : undef);
    };

    return ($scheme, $host, $port, $path_query);
}

package
    HTTP::Tiny::Handle; # hide from PAUSE/indexers
use strict;
use warnings;

use Carp       qw[croak];
use Errno      qw[EINTR];
use IO::Socket qw[SOCK_STREAM];

sub BUFSIZE () { 32768 } # XXX Should be an attribute? -- dagolden, 2010-12-03

my $Printable = sub {
    local $_ = shift;
    s/\r/\\r/g;
    s/\n/\\n/g;
    s/\t/\\t/g;
    s/([^\x20-\x7E])/sprintf('\\x%.2X', ord($1))/ge;
    $_;
};

my $Token = qr/[\x21\x23-\x27\x2A\x2B\x2D\x2E\x30-\x39\x41-\x5A\x5E-\x7A\x7C\x7E]/;

sub new {
    my ($class, %args) = @_;
    return bless {
        rbuf             => '',
        timeout          => 60,
        max_line_size    => 16384,
        max_header_lines => 64,
        %args
    }, $class;
}

sub connect {
    @_ == 4 || croak(q/Usage: $handle->connect(scheme, host, port)/);
    my ($self, $scheme, $host, $port) = @_;

    # XXX IO::Socket::SSL
    $scheme eq 'http'
      or croak(qq/Unsupported URL scheme '$scheme'/);

    $self->{fh} = IO::Socket::INET->new(
        PeerHost  => $host,
        PeerPort  => $port,
        Proto     => 'tcp',
        Type      => SOCK_STREAM,
        Timeout   => $self->{timeout}
    ) or croak(qq/Could not connect to '$host:$port': $@/);

    binmode($self->{fh})
      or croak(qq/Could not binmode() socket: '$!'/);

    $self->{host} = $host;
    $self->{port} = $port;

    return $self;
}

sub close {
    @_ == 1 || croak(q/Usage: $handle->close()/);
    my ($self) = @_;
    CORE::close($self->{fh})
      or croak(qq/Could not close socket: '$!'/);
}

sub write {
    @_ == 2 || croak(q/Usage: $handle->write(buf)/);
    my ($self, $buf) = @_;

    utf8::downgrade($buf, 1)
      or croak(q/Wide character in write()/);

    my $len = length $buf;
    my $off = 0;

    while () {
        $self->can_write
          or croak(q/Timed out while waiting for socket to become ready for writing/);
        my $r = syswrite($self->{fh}, $buf, $len, $off);
        if (defined $r) {
            $len -= $r;
            $off += $r;
            last unless $len > 0;
        }
        elsif ($! != EINTR) {
            croak(qq/Could not write to socket: '$!'/);
        }
    }
    return $off;
}

sub read {
    @_ == 2 || @_ == 3 || croak(q/Usage: $handle->read(len [, partial])/);
    my ($self, $len, $partial) = @_;

    my $buf  = '';
    my $got = length $self->{rbuf};

    if ($got) {
        my $take = ($got < $len) ? $got : $len;
        $buf  = substr($self->{rbuf}, 0, $take, '');
        $len -= $take;
    }

    while ($len > 0) {
        $self->can_read
          or croak(q/Timed out while waiting for socket to become ready for reading/);
        my $r = sysread($self->{fh}, $buf, $len, length $buf);
        if (defined $r) {
            last unless $r;
            $len -= $r;
        }
        elsif ($! != EINTR) {
            croak(qq/Could not read from socket: '$!'/);
        }
    }
    if ($len && !$partial) {
        croak(q/Unexpected end of stream/);
    }
    return $buf;
}

sub readline {
    @_ == 1 || croak(q/Usage: $handle->readline()/);
    my ($self) = @_;

    while () {
        if ($self->{rbuf} =~ s/\A ([^\x0D\x0A]* \x0D?\x0A)//x) {
            return $1;
        }
        if (length $self->{rbuf} >= $self->{max_line_size}) {
            croak(qq/Line size exceeds the maximum allowed size of $self->{max_line_size}/);
        }
        $self->can_read
          or croak(q/Timed out while waiting for socket to become ready for reading/);
        my $r = sysread($self->{fh}, $self->{rbuf}, BUFSIZE, length $self->{rbuf});
        if (defined $r) {
            last unless $r;
        }
        elsif ($! != EINTR) {
            croak(qq/Could not read from socket: '$!'/);
        }
    }
    croak(q/Unexpected end of stream while looking for line/);
}

sub read_header_lines {
    @_ == 1 || croak(q/Usage: $handle->read_header_lines()/);
    my ($self) = @_;

    my %headers = ();
    my $lines   = 0;
    my $val;

    while () {
         my $line = $self->readline;

         if (++$lines >= $self->{max_header_lines}) {
             croak(qq/Header lines exceeds maximum number allowed of $self->{max_header_lines}/);
         }
         elsif ($line =~ /\A ([^\x00-\x1F\x7F:]+) : [\x09\x20]* ([^\x0D\x0A]*)/x) {
             my ($field_name) = lc $1;
             if (exists $headers{$field_name}) {
                 for ($headers{$field_name}) {
                     $_ = [$_] unless ref $_ eq "ARRAY";
                     push @$_, $2;
                     $val = \$_->[-1];
                 }
             }
             else {
                 $val = \($headers{$field_name} = $2);
             }
         }
         elsif ($line =~ /\A [\x09\x20]+ ([^\x0D\x0A]*)/x) {
             $val
               or croak(q/Unexpected header continuation line/);
             next unless length $1;
             $$val .= ' ' if length $$val;
             $$val .= $1;
         }
         elsif ($line =~ /\A \x0D?\x0A \z/x) {
            last;
         }
         else {
            croak(q/Malformed header line: / . $Printable->($line));
         }
    }
    return \%headers;
}

sub write_request {
    @_ == 2 || croak(q/Usage: $handle->write_request(request)/);
    my($self, $request) = @_;
    $self->write_request_header(@{$request}{qw/method uri headers/});
    $self->write_body($request->{cb}, $request->{headers}{'content-length'})
        if $request->{cb};
    return;
}

my %HeaderCase = (
    'content-md5'      => 'Content-MD5',
    'etag'             => 'ETag',
    'te'               => 'TE',
    'www-authenticate' => 'WWW-Authenticate',
    'x-xss-protection' => 'X-XSS-Protection',
);

sub write_header_lines {
    @_ == 2 || croak(q/Usage: $handle->write_header_lines(headers)/);
    my($self, $headers) = @_;

    my $buf = '';
    while (my ($k, $v) = each %$headers) {
        my $field_name = lc $k;
        if (exists $HeaderCase{$field_name}) {
            $field_name = $HeaderCase{$field_name};
        }
        else {
            $field_name =~ /\A $Token+ \z/xo
              or croak(q/Invalid HTTP header field name: / . $Printable->($field_name));
            $field_name =~ s/\b(\w)/\u$1/g;
            $HeaderCase{lc $field_name} = $field_name;
        }
        for (ref $v eq 'ARRAY' ? @$v : $v) {
            /[^\x0D\x0A]/
              or croak(qq/Invalid HTTP header field value ($field_name): / . $Printable->($_));
            $buf .= "$field_name: $_\x0D\x0A";
        }
    }
    $buf .= "\x0D\x0A";
    return $self->write($buf);
}

sub read_body {
    @_ == 2 || @_ == 3 || croak(q/Usage: $handle->read_body(callback [, content_length])/);
    my ($self, $cb, $content_length) = @_;
    if ($content_length) {
        $self->read_content_body($cb, $content_length);
    }
    else {
        $self->read_chunked_body($cb);
    }
    return;
}

sub write_body {
    @_ == 2 || @_ == 3 || croak(q/Usage: $handle->write_body(callback [, content_length])/);
    my ($self, $cb, $content_length) = @_;
    if ($content_length) {
        return $self->write_content_body($cb, $content_length);
    }
    else {
        return $self->write_chunked_body($cb);
    }
}

sub read_content_body {
    @_ == 3 || croak(q/Usage: $handle->read_content_body(callback, content_length)/);
    my ($self, $cb, $content_length) = @_;

    my $len = $content_length;
    while ($len > 0) {
        my $read = ($len > BUFSIZE) ? BUFSIZE : $len;
        $cb->($self->read($read));
        $len -= $read;
    }

    return $content_length; # XXX ignored? -- dagolden, 2010-12-03
}

sub write_content_body {
    @_ == 3 || croak(q/Usage: $handle->write_content_body(callback, content_length)/);
    my ($self, $cb, $content_length) = @_;

    my $len = 0;
    while () {
        my $data = $cb->();

        defined $data && length $data
          or last;

        utf8::downgrade($data, 1)
          or croak(q/Wide character in write_content()/);

        $len += $self->write($data);
    }

    $len == $content_length
      or croak(qq/Content-Length missmatch (got: $len expected: $content_length)/);

    return $len;
}

sub read_chunked_body {
    @_ == 2 || croak(q/Usage: $handle->read_chunked_body(callback)/);
    my ($self, $cb) = @_;

    while () {
        my $head = $self->readline;

        $head =~ /\A ([A-Fa-f0-9]+)/x
          or croak(q/Malformed chunk head: / . $Printable->($head));

        my $len = hex($1)
          or last;

        $self->read_content_body($cb, $len);

        $self->read(2) eq "\x0D\x0A"
          or croak(q/Malformed chunk: missing CRLF after chunk data/);
    }
    return $self->read_header_lines; # XXX ignored? -- dagolden, 2010-12-03
}

sub write_chunked_body {
    @_ == 2 || @_ == 3 || croak(q/Usage: $handle->write_chunked_body(callback [, trailers])/);
    my ($self, $cb, $trailers) = @_;

    $trailers ||= {}; # XXX not used; remove? -- dagolden, 2010-12-03

    my $len = 0;
    while () {
        my $data = $cb->();

        defined $data && length $data
          or last;

        utf8::downgrade($data, 1)
          or croak(q/Wide character in write_chunked_body()/);

        $len += length $data;

        my $chunk  = sprintf '%X', length $data;
           $chunk .= "\x0D\x0A";
           $chunk .= $data;
           $chunk .= "\x0D\x0A";

        $self->write($chunk);
    }
    $self->write("0\x0D\x0A");
    $self->write_header_lines($trailers); # XXX remove? -- dagolden, 2010-12-03
    return $len;
}

sub read_response_header {
    @_ == 1 || croak(q/Usage: $handle->read_response_header()/);
    my ($self) = @_;

    my $line = $self->readline;

    $line =~ /\A (HTTP\/1.[0-1]) [\x09\x20]+ ([0-9]{3}) [\x09\x20]+ ([^\x0D\x0A]*) \x0D?\x0A/x
      or croak(q/Malformed Status-Line: / . $Printable->($line));

    my ($version, $status, $reason) = ($1, $2, $3);

    return {
        status   => $status,
        reason   => $reason,
        headers  => $self->read_header_lines,
        protocol => $version
    };
}

sub write_request_header {
    @_ == 4 || @_ == 5 || croak(q/Usage: $handle->write_request_header(method, request_uri, headers [, protocol])/);
    my ($self, $method, $request_uri, $headers, $protocol) = @_;

    $protocol ||= 'HTTP/1.1'; # XXX never provided -- dagolden, 2010-12-03

    return $self->write("$method $request_uri $protocol\x0D\x0A")
         + $self->write_header_lines($headers);
}

sub _do_timeout {
    my ($self, $type, $timeout) = @_;
    $timeout = $self->{timeout}
        unless defined $timeout && $timeout >= 0;

    my $fd = fileno $self->{fh};
    defined $fd && $fd >= 0
      or croak(q/select(2): 'Bad file descriptor'/);

    my $initial = time;
    my $pending = $timeout;
    my $nfound;

    vec(my $fdset = '', $fd, 1) = 1;

    while () {
        $nfound = ($type eq 'read')
            ? select($fdset, undef, undef, $pending)
            : select(undef, $fdset, undef, $pending) ;
        if ($nfound == -1) {
            $! == EINTR
              or croak(qq/select(2): '$!'/);
            redo if !$timeout || ($pending = $timeout - (time - $initial)) > 0;
            $nfound = 0;
        }
        last;
    }
    $! = 0;
    return $nfound;
}

sub can_read {
    @_ == 1 || @_ == 2 || croak(q/Usage: $handle->can_read([timeout])/);
    my $self = shift;
    return $self->_do_timeout('read', @_)
}

sub can_write {
    @_ == 1 || @_ == 2 || croak(q/Usage: $handle->can_write([timeout])/);
    my $self = shift;
    return $self->_do_timeout('write', @_)
}

1;



__END__
=pod

=head1 NAME

HTTP::Tiny - A tiny HTTP client

=head1 VERSION

version 0.001

=head1 SYNOPSIS

    use HTTP::Tiny;

    my $response = HTTP::Tiny->new->get('http://example.com/');

    print "$response->{status} $response->{reason}\n";

    while (my ($k, $v) = each %{$response->{headers}}) {
        for (ref $v eq 'ARRAY' ? @$v : $v) {
            print "$k: $_\n";
        }
    }

    print $response->{content} if defined $response->{content};

=head1 DESCRIPTION

This is a very simple HTTP/1.1 client, designed primarily for doing simple GET
requests without the overhead of a large framework like L<LWP::UserAgent>.

It is more correct and more complete than L<HTTP::Lite>.  It supports
proxies (currently only non-authenticating ones) and redirection.  It
also correctly resumes after EINTR.

Additional documentation and improved tests will be forthcoming.

=for Pod::Coverage agent
default_headers
get
max_redirect
max_size
new
proxy
request
timeout

=head1 AUTHORS

=over 4

=item *

Christian Hansen <chansen@cpan.org>

=item *

David Golden <dagolden@cpan.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2010 by Christian Hansen.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

