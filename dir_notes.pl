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
my $global_dbh           = setup_db_handle( db_file => $notes_db_file );

my $options = {};
GetOptions( $options,
    'help',
    'refresh|update',
    'version',
) or pod2usage( 2 );

$options->{help}      and pod2usage( -verbose => 2,  -exitval  => 0 );
$options->{version}   and pod2usage( -verbose => 99, -sections => [ qw( VERSION COPYRIGHT ) ] );

my $command       = ( $ARGV[0] and $ARGV[0] =~ /show|ls|rm/i ) ? shift : 'show';
my $explicit_dirs = scalar @ARGV;
my $notes_dirs    = [ clean_dirs( @ARGV ) ];

if( $command =~ /ls/i )
    {
    if( $options->{refresh} )
        {
        refresh_notes_dirs( dirs => ( $explicit_dirs ? $notes_dirs : [] ) );
        }
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

$global_dbh->disconnect();

exit( 0 );

# ----------------------------------------------------------------------------
#                           END OF MAIN PROGRAM
# ----------------------------------------------------------------------------

sub clean_dirs
    {
    my @unclean_dirs = @_;
    my @dirs         = ();
    my %duplicate    = ();

    my $cwd = cwd();
    push( @unclean_dirs, $cwd )    unless $explicit_dirs;

    # special cases and cleanups
    foreach my $dir ( @unclean_dirs )
        {
        $dir =~ s:^~:$ENV{HOME}:; # home directory
        $dir =~ s:/*$::;          # remove trailing slashes
        $dir =~ s:/+:/:;          # remove duplicate slashes

        # special handling of . and ..
        if( $dir eq '.' )
            {
            $dir = $cwd;
            }
        elsif( $dir eq '..' )
            {
            $dir = $cwd;
            $dir =~ s:/[^/]+$::;    # chop last part of path
            }

        next if $duplicate{$dir}++; # faster
        next if not -d $dir;        # slower

        push @dirs, $dir;
        }

    return @dirs;
    }

sub db_queries
    {
    # DB schema
    return {
            init_table => "
                CREATE TABLE noted_dirs (
                    dir_name,
                    last_activity DEFAULT ( STRFTIME( '%s', 'now' ) ),
                    summary,
                    UNIQUE ( dir_name )
                )
            ",
            init_view => "
                CREATE VIEW recent_activity
                AS SELECT
                    strftime( '%Y-%m-%d %H:%M', last_activity, 'unixepoch', 'localtime' ) AS last_activity,
                    dir_name,
                    summary
                FROM noted_dirs
                ORDER BY last_activity DESC
                ",
            track_dir => "
                INSERT OR REPLACE INTO noted_dirs (
                    dir_name,
                    last_activity,
                    summary
                    )
                VALUES (
                    ?,
                    STRFTIME( '%s', 'now' ),
                    ?
                    )
                ",
            refresh_dir => "
                INSERT OR REPLACE INTO noted_dirs (
                    dir_name,
                    summary
                    )
                VALUES (
                    ?,
                    ?
                    )
                ",
#             refresh_dir => "
#                 INSERT OR UPDATE noted_dirs
#                 SET
#                     dir_name = ?,
#                     summary  = ?
#                 WHERE
#                     dir_name = ?
#                 ",
            rm_dir    => "DELETE FROM noted_dirs WHERE dir_name = ?",
            ls_dirs   => "SELECT * FROM recent_activity",
        };
    }

sub setup_db_handle
    {
    my %param   = @_;
    my $db_file = $param{db_file};

    my $needs_init = not -f $db_file;

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
    my $sql   = db_queries();

    $dbh->do( $sql->{init_table}   );
    $dbh->do( $sql->{init_view}    );
    }

sub show_notes
    {
    my %param         = @_;
    my @dirs          = @{$param{dirs} || []};

    foreach my $dir ( @dirs )
        {
        my $notes_file = catfile( $dir, '.notes' );

        # make noises if there are no notes in selected directories,
        # but not if we're using the current directory
        if( $explicit_dirs and ( not -d $dir or not -f $notes_file ) )
            {
            printf "No notes in $dir\n";
            }

        next unless -f $notes_file;
        next unless open( my $notes, '<', $notes_file );

        my $summary;

        my $header = sprintf "NOTES%s:", $explicit_dirs ? " for $dir" : '';
        printf "%s\n%s\n", $header, '=' x length( $header );
        while( my $line = <$notes> )
            {
            print $line;
            $summary ||= $line;
            }
        close( $notes );

        track_dir( dir => $dir, summary => $summary );
        }
    }

sub track_dir
    {
    my %param    = @_;
    my $dir      = $param{dir};
    my $summary  = $param{summary};
    my $sql      = db_queries();

    # strip whitespace from summary
    $summary =~ s/^\s*|[\s\n\r]*$//g;

    # throw the directory and summary into the overview DB
    my $sth = $global_dbh->prepare( $sql->{track_dir} );
    $sth->execute( $dir, $summary );
    $sth->finish();

    return;
    }

sub refresh_notes_dirs
    {
    my %param = @_;
    my @dirs  = @{$param{dirs}};
    my $sql   = db_queries();

    printf "Refreshing notes overview...\n";

    # grab the list of dirs from the DB if none were provided
    if( not scalar @dirs )
        {
        my $sth = $global_dbh->prepare( $sql->{ls_dirs} );
        $sth->execute();
        while( my $row = $sth->fetchrow_hashref() )
            {
            push @dirs, $row->{dir_name};
            }
        $sth->finish();
        }

    # throw the directory and summary into the overview DB
    my $sth = $global_dbh->prepare( $sql->{refresh_dir} );

    foreach my $dir ( @dirs )
        {

        # skip missing directories - perhaps they are just not mounted
        next    unless -d $dir;

        my $notes_file = catfile( $dir, '.notes' );
        if( -f $notes_file and open( my $NOTES_SUMMARY, '<', $notes_file ) )
            {
            # found a notes file:
            #   grab the first line and update the database
            my $summary = <$NOTES_SUMMARY>; # just the first line
            close $NOTES_SUMMARY;

            # strip whitespace from summary
            $summary =~ s/^\s*|[\s\n\r]*$//g;

            # update the summary in the DB
#             $sth->execute( $dir, $summary, $dir );
            $sth->execute( $dir, $summary );
            }
        else
            {
            # directory exists but no .notes file - remove the directory from the DB
            remove_dir_from_db( $dir );
            }
        }

    $sth->finish();

    return;
    }

sub list_notes_dirs
    {
    my %param  = @_;
    my $header = $param{header} || "Recently used directories with notes:";
    my $sql    = db_queries();

    printf "%s\n", $header;
    $header =~ s/\n//g;
    printf "%s\n", '=' x length( $header );

    my @overview   = ();
    my $dirs_width = 1;
    my $sth        = $global_dbh->prepare( $sql->{ls_dirs} );

    $sth->execute();

    while( my $row = $sth->fetchrow_hashref() )
        {
        push @overview, $row;
        my $width   = length $row->{dir_name};
        $dirs_width = $width    if $width >= $dirs_width;
        }
    $sth->finish();

    foreach my $dir ( @overview )
        {
        printf "%16s  %-*s  %s\n", $dir->{last_activity}, $dirs_width, $dir->{dir_name}, $dir->{summary} || '';
        }

    return;
    }

sub clean_up
    {
    my %param = @_;
    my @dirs  = @{$param{dirs}};

    my @dirs_to_remove = grep { -d $_ and not -f catfile( $_, '.notes' ) } @dirs;

    foreach my $dir ( @dirs_to_remove )
        {
        remove_dir_from_db( $dir );
        }

    return;
    }

sub delete_notes
    {
    my %param = @_;
    my @dirs  = @{$param{dirs}};
    my $sql   = db_queries();

    foreach my $dir ( @dirs )
        {
        # don't delete notes if the directory cannot be accessed (TODO: Riehm 2011-08-30 add --force?)
        next    unless -d $dir;

        remove_dir_from_db( $dir );

        my $notes_file = catfile( $dir, '.notes' );
        next    unless -f $notes_file;

        printf "Removing notes file: $notes_file\n";
        unlink $notes_file;
        }
    }

sub remove_dir_from_db
    {
    my $dir = shift;
    my $sql = db_queries();

    my $sth = $global_dbh->prepare( $sql->{rm_dir} );
    $sth->execute( $dir );
    $sth->finish();

    return;
    }

sub self_test
    {
    require Test::More;
    # TODO: Riehm 2011-08-30 create a test db
    # TODO: Riehm 2011-08-30 create a test directory tree
    # TODO: Riehm 2011-08-30 create a .notes file
    # display the notes file
    # ls the overview
    # display after rm file
    # create then rm notes file
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

dir_notes [show [<dir...>]]

dir_notes ls [--refresh]

dir_notes rm <dir...>

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

if --refresh is provided, then the summaries of the notes in the known directories will be updated in the overview DB, without updating the last-activity timestamps.

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
