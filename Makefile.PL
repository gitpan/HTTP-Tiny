
use strict;
use warnings;

BEGIN { require 5.006; }

use ExtUtils::MakeMaker 6.31;



my %WriteMakefileArgs = (
  'ABSTRACT' => 'A small, simple, correct HTTP/1.1 client',
  'AUTHOR' => 'Christian Hansen <chansen@cpan.org>, David Golden <dagolden@cpan.org>',
  'BUILD_REQUIRES' => {
    'Exporter' => '0',
    'File::Basename' => '0',
    'File::Find' => '0',
    'File::Temp' => '0',
    'IO::Dir' => '0',
    'IO::File' => '0',
    'IO::Socket::INET' => '0',
    'Test::More' => '0.88'
  },
  'CONFIGURE_REQUIRES' => {
    'ExtUtils::MakeMaker' => '6.31'
  },
  'DISTNAME' => 'HTTP-Tiny',
  'EXE_FILES' => [],
  'LICENSE' => 'perl',
  'NAME' => 'HTTP::Tiny',
  'PREREQ_PM' => {
    'Carp' => '0',
    'Errno' => '0',
    'IO::Socket' => '0',
    'Time::Local' => '0'
  },
  'VERSION' => '0.007',
  'test' => {
    'TESTS' => 't/*.t'
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



