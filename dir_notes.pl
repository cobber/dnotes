#!/usr/bin/env perl

use strict;
use warnings;
use Cwd;
use DBI;
use Getopt::Long;
use Pod::Usage;
use File::Spec::Functions qw( catfile );

my $VERSION       = '1.0';
my $notes_db_file = "$ENV{HOME}/.notes.db";
my $dbh           = setup_db_handle( db_file => $notes_db_file );

my $sql = {
    init_table => "
        CREATE TABLE noted_dirs (
            dir_name,
            timestamp,
            UNIQUE ( dir_name )
        );
    ",
    init_view => "
        CREATE VIEW recent_activity
        AS SELECT
            strftime( '%Y-%m-%d %H:%M', timestamp, 'unixepoch', 'localtime' ) AS date,
            dir_name
        FROM noted_dirs
        ORDER BY timestamp
        ;
        ",
    add_dir   => "
                    INSERT OR REPLACE INTO noted_dirs (
                        dir_name,
                        timestamp
                    )
                    VALUES (
                        '?',
                        STRFTIME( '%s', 'now' )
                    )",
    check_dir => "SELECT dir_name FROM noted_dirs WHERE dir_name = '?'",
    rm_dir    => "DELETE FROM noted_dirs WHERE dir_name = '?'",
    ls_dirs   => "SELECT * FROM recent_activity",
};

my $options = {};
GetOptions( $options,
    'help',
    'version',
) or pod2usage( 2 );

$options->{help}      and pod2usage( -verbose => 2, -exitval => 0 );
$options->{version}   and pod2usage( -verbose => 99, -sections => [ qw( VERSION COPYRIGHT ) ] );

my $command    = ( $ARGV[0] and $ARGV[0] =~ /show|ls|rm/i ) ? shift : 'show';
my %duplicate = ();
my $notes_dirs = [ grep { not $duplicate{$_}++ } @ARGV ];

if( $command =~ /ls/i )
    {
    list_notes_dirs();
    }
elsif( $command =~ /rm/i )
    {
    delete_notes( dirs => $notes_dirs );
    list_notes_dirs( header => "\nRemaining directories with notes:" );
    }
else # show
    {
    show_notes( dirs => $notes_dirs );
    clean_up(   dirs => $notes_dirs );
    }

$dbh->disconnect();

exit( 0 );

sub setup_db_handle
    {
    my %param   = @_;
    my $db_file = $param{db_file};

    my $needs_init = -f $db_file;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db_file" );

    if( $needs_init )
        {
        init_db( db_handle => $dbh );
        }

    return $dbh;
    }

sub init_db
    {
    my %param = @_;
    my $dbh   = $param{db_handle};

    $dbh->do( $sql->{init_table} );
    $dbh->do( $sql->{init_view} );
    }

sub show_notes
{
    my %param         = @_;
    my @dirs          = @{$param{dirs} || []};
    my $explicit_dirs = scalar @dirs;

    push( @dirs, cwd() )    unless $explicit_dirs;

    foreach my $dir ( @dirs )
    {
        my $notes_file = catfile( $dir, '.notes' );

        # make noises if there are no notes in selected directories,
        # but not if we're using the current directory
        if( $explicit_dirs and ! -d $dir or ! -f $notes_file )
        {
            printf "No notes in $dir\n";
        }

        next unless -f $notes_file;
        next unless open( my $notes, '<', $notes_file );

        my $header = sprintf "NOTES%s:", $explicit_dirs ? " for $dir" : '';
        printf "%s\n%s\n", $header, '=' x length( $header );
        while( my $line = <$notes> )
            {
            print $line;
            }
        close( $notes );
    }
}

sub list_notes_dirs
    {
    my %param = @_;
    my $header = $param{header} || "Recently used directories with notes:";

    printf "%s\n", $header;
    $header =~ s/\n//g;
    printf "%s\n", '=' x length( $header );
    # TODO: Riehm 2011-08-12 get data from db
    my $sth = $dbh->prepare( $sql->{ls_dirs} );
    $sth->execute();
    while( my $row = $sth->fetchrow_hashref() )
        {
        printf "%s %s\n", $row->{timestamp}, $row->{dir_name};
        }
    $sth->finish();
    }

sub clean_up
    {
    my %param         = @_;
    my @dirs          = @{$param{dirs} || []};

    my @dirs_to_remove = grep { ! -f catfile( $_, '.notes' ) } @dirs;

    return unless @dirs_to_remove;

    # TODO: Riehm 2011-08-12 remove dir from db
    }

sub delete_notes
    {
    my %param         = @_;
    my @dirs          = @{$param{dirs} || []};
    my $explicit_dirs = scalar @dirs;

    push( @dirs, cwd() )    unless $explicit_dirs;

    foreach my $dir ( @dirs )
        {
        next    unless -d $dir;
        # TODO: Riehm 2011-08-12 remove $dir from DB
        printf "Removing from DB:    $dir\n";

        my $notes_file = catfile( $dir, '.notes' );
        next    unless -f $notes_file;

        printf "Removing notes file: $notes_file\n";
        unlink $notes_file;
        }
    }

=head1 NAME

dir_notes - display or manage simple notes stored in the current directory

=head1 SYNOPSIS

tcsh:

    alias cd     'pushd \!* && dir_notes'
    alias cdback 'pushd +1'

bash:

    alias cd=cd_with_notes
    function cd_with_notes {
        pushd "$@" && dir_notes
    }
    alias cdback=pushd

dir_notes [show [<dir>]]

dir_notes ls

dir_notes rm <dir>

=head1 DESCRIPTION

This command is a very simple way of managing directory specific notes files.

The concept is simple:

    If you want to leave some reminders for yourself in a directory, simply
    create a file called '.notes' in the directory, and write any text you like
    in there.

    Add this script to your 'cd' alias, it will then automatically display the
    notes for each directory when you cd to it - and do nothing if there are no
    notes for the directory.

Additionally, this command keeps tracks of the time it displayed any notes, so
that you can easily find out where you were working recently.

When you no longer need notes for a directory, simply remove the .notes file.
This command will automatically notice and remove the direcory from the recent
activities list.

=head1 SUB COMMANDS

=over 4

=item show [<dir>]

Display the notes for the current directory.

Optionally, a directory may be provided to display notes from a different directory.

If a directory has no .notes file - then it will be removed from the recent activity list.

This is the default command.

=item ls

Display a list of directories with .notes files - in the order they were last accessed

=item rm <dir>

Remove the directory from the recent activities list and if possible, also
remove the .notes file in that directory.

=back

=head1 OPTIONS

=over 4

=item --help

Display this man page and exit

=item --version

Display the current version information and exit

=back

=head1 VERSION

dir_notes version 1.0, 2011-08-12

=head1 COPYRIGHT

Copyright 2008, Stephen Riehm, Munich, Germany

=head1 AUTHOR

Stephen Riehm <s.riehm@opensauce.de>
