package Test::Class::Moose::Role::CLI;

# ABSTRACT: Role for command line argument handling and extra CLI features

use strict;
use warnings;
use namespace::autoclean;

use 5.010000;

our $VERSION = '1.00';

use Moose::Role 2.0000;
use Carp;

use File::Find qw( find );
use JSON::MaybeXS qw( encode_json );
use Module::Runtime qw( use_package_optimistically );
use Module::Util qw( fs_path_to_module );
use MooseX::Getopt 0.71;
use Test::Class::Moose::Runner;

has classes => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

has methods => (
    traits  => ['Array'],
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
    handles => {
        _has_methods => 'count',
    },
);

has exclude_methods => (
    traits  => ['Array'],
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
    handles => {
        _has_exclude_methods => 'count',
    },
);

has tags => (
    traits  => ['Array'],
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
    handles => {
        _has_tags => 'count',
    },
);

has test_lib_dirs => (
    traits  => ['Array'],
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { ['t/lib'] },
    handles => {
        _all_test_lib_dirs => 'elements',
        _has_test_lib_dirs => 'count',
    },
);

has exclude_tags => (
    traits  => ['Array'],
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
    handles => {
        _has_exclude_tags => 'count',
    },
);

has parallel_progress => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_parallel_progress',
);

has color => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_color',
);

has jobs => (
    is        => 'ro',
    isa       => 'Int',
    predicate => '_has_jobs',
);

has randomize_methods => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_randomize_methods',
);

has randomize_classes => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_randomize_classes',
);

has set_process_name => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_set_process_name',
);

has statistics => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_statistics',
);

has show_timing => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_show_timing',
);

has use_environment => (
    is        => 'ro',
    isa       => 'Bool',
    predicate => '_has_use_environment',
);

has _runner_class => (
    is       => 'ro',
    isa      => 'ClassName',
    init_arg => 'runner_class',
    default  => 'Test::Class::Moose::Runner',
);

has _timing_data_file => (
    is        => 'ro',
    isa       => 'Str',
    init_arg  => 'timing_data_file',
    predicate => '_has_timing_data_file',
);

has _start_time => (
    is       => 'ro',
    isa      => 'Int',
    init_arg => undef,
    default  => sub {time},
);

has _runner => (
    is       => 'ro',
    init_arg => undef,
    lazy     => 1,
    builder  => '_build_runner',
);

has _class_names => (
    traits   => ['Array'],
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    init_arg => undef,
    lazy     => 1,
    builder  => '_build_class_names',
    handles  => {
        _has_class_names => 'count',
    },
);

with 'MooseX::Getopt::Dashes';

sub run {
    my $self = shift;

    $self->_before_run;
    $self->_load_classes;
    $self->_runner->runtests;
    $self->_after_run;
    $self->_maybe_save_timing_data;

    return $self->_runner;
}

sub _before_run { }

sub _load_classes {
    my $self = shift;

    if ( $self->_has_class_names ) {
        local @INC = ( $self->_test_lib_dirs, @INC );
        foreach my $class ( @{ $self->_class_names } ) {
            use_package_optimistically($class);
        }
    }
    else {
        require Test::Class::Moose::Load;
        Test::Class::Moose::Load->import( $self->_test_lib_dirs );
    }

    return;
}

sub _after_run { }

{
    my $meta     = __PACKAGE__->meta;
    my %attr_map = map { $_ => $_ }
      grep { $meta->get_attribute($_)->original_role->name eq __PACKAGE__ }
      grep { !/^_/ && $_ ne 'classes' } $meta->get_attribute_list;
    $attr_map{randomize_methods} = 'randomize';
    $attr_map{tags}              = 'include_tags';
    $attr_map{color}             = 'color_output';
    $attr_map{parallel_progress} = 'show_parallel_progress';

    sub _build_runner {
        my $self = shift;

        my %args;
        for my $attr ( keys %attr_map ) {
            my $pred = '_has_' . $attr;
            next unless $self->$pred();

            $args{ $attr_map{$attr} } = $self->$attr;
        }

        if ( $self->_has_class_names ) {
            $args{test_classes} = $self->_class_names;
        }

        if ( $args{methods} ) {
            my $re = join '|',
              map { quotemeta($_) } @{ delete $args{methods} };
            $args{include} = qr/^(?:$re)$/;
        }

        if ( $args{exclude_methods} ) {
            my $re = join '|',
              map { quotemeta($_) } @{ delete $args{exclude_methods} };
            $args{exclude} = qr/^(?:$re)$/;
        }

        use_package_optimistically( $self->_runner_class );
        return $self->_runner_class->new(%args);
    }
}

sub _build_class_names {
    my $self = shift;

    return [
        map { $self->_munge_class($_) }
        map { $self->_maybe_resolve_path($_) } @{ $self->classes }
    ];
}

sub _munge_class { $_[1] }

sub _maybe_resolve_path {
    my $self = shift;
    my $path = shift;

    if ( -d $path ) {
        return $self->_find_classes($path);
    }

    if ( $path =~ /\.pm$/ ) {
        for my $dir ( $self->_test_lib_dirs ) {
            if ( $path =~ s{^.*\Q$dir}{} ) {
                return fs_path_to_module($path);
            }
        }
    }

    return $path;
}

# This is still here to maintain backwards compatibility for people writing
# custom test runners. In past releases the only way to customize this value
# was to override this method, though we later added a CLI option to set this
# value.
sub _test_lib_dirs {
    my $self = shift;
    return $self->_all_test_lib_dirs;
}

sub _find_classes {
    my $self = shift;
    my $dir  = shift;

    my @classes;
    my $finder = sub {
        return unless /\.pm$/;
        s{^.*\Q$dir}{};
        push @classes, fs_path_to_module($_);
    };

    find(
        {   wanted   => $finder,
            no_chdir => 1,
        },
        $dir
    );

    return @classes;
}

sub _maybe_save_timing_data {
    my $self = shift;

    return unless $self->_has_timing_data_file;

    my $file = $self->_timing_data_file;
    open my $fh, '>', $file or die "Cannot write to $file: $!";
    print {$fh} encode_json(
        {   process_name => $0,
            start_time   => $self->_start_time,
            timing       => $self->_runner->test_report->timing_data,
        }
    ) or die "Cannot write to $file: $!";
    close $fh or die "Cannot write to $file: $!";

    return;
}

1;

__END__

=pod

=encoding UTF-8

=for Pod::Coverage run

=head1 SYNOPSIS

    package My::CLI;

    use Moose;

    with 'Test::Class::Moose::Role::CLI';

    sub _munge_class {
        return $_[1] =~ /^TestFor::/ ? $_[1] : 'TestFor::MyApp::' . $_[1] );
    }

    sub _before_run { ... }
    sub _after_run { ... }

=head1 DESCRIPTION

This role provides the core implementation of command line option processing
for L<Test::Class::Moose::CLI>. You can consume this role and add additional
hooks to customize how your test classes are run.

See L<Test::Class::Moose::CLI> for a list of all the available command line
options that this role handles.

=head1 HOOKS

This role has several hook methods that it calls. The role provides no-op or
default implementations of these hooks but you can provide an implementation in
your class that does something.

=head2 _munge_class

This method is called for each class as found by the command line C<--classes>
option. Note that this is called I<after> resolving file and directory paths
passed as a C<--classes> option.

You can use this to allow people to pass short names like C<Model::Car> and
turn it into a full name like C<TestFor::MyApp::Model::Car>.

By default this method is a no-op.

=head2 _before_run

This method is called before the test classes are run (or even loaded).

By default this method is a no-op.

=head2 _test_lib_dirs

This should return a list of directories containing test classes. The
directories can be relative to the project root (F<t/lib>) or absolute.

This defaults to returning a single path, F<t/lib>.

Note that this is now also settable via
L<Test::Class::Moose::CLI/--test_lib_dirs>.

=head2 _load_classes

This method will try to load all the classes passed on the command line if any
were passed. If the value that was passed is a path rather than a class name,
any leading part matching a value in the list from C<_test_lib_dirs> will be
stripped, and the rest will be transformed from a path to a module name.

Otherwise it invokes L<Test::Class::Moose::Load> with the value returned by
C<_test_lib_dirs> as its argument.

=head2 _after_run

This method is called after all the test classes are run.

By default this method is a no-op.

=cut
