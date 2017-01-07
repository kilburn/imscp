=head1 NAME

 iMSCP::Debug - Debug library

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2017 by internet Multi Server Control Panel
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package iMSCP::Debug;

use strict;
use warnings;
use iMSCP::Log;
use open qw/ :std :utf8 /;
use parent 'Exporter';

our @EXPORT = qw/
    debug warning error fatal newDebug endDebug getMessage getLastError getMessageByType setVerbose setDebug
    debugRegisterCallBack output silent
    /;

BEGIN {
    # Catch uncaught exceptions
    $SIG{'__DIE__'} = sub {
        fatal( @_, (caller( 1 ))[3] || 'main' ) if defined $^S && !$^S
    };

    # Catch warns
    $SIG{'__WARN__'} = sub {
        warning( @_, (caller( 1 ))[3] || 'main' );
    };
}

my $self = {
    debug          => 0,
    verbose        => 0,
    debugCallBacks => [ ],
    targets        => [ iMSCP::Log->new( id => 'default' ) ]
};

$self->{'target'} = $self->{'targets'}->[0];
$self->{'default'} = $self->{'target'};

=head1 DESCRIPTION

 Debug library

=head1 CLASS METHODS

=over 4

=item setDebug($debug)

 Enable or disable debug mode

 Param bool $debug Enable verbose mode if true, disable otherwise
 Return undef

=cut

sub setDebug
{
    if (shift) {
        $self->{'debug'} = 1;
        return;
    }

    # Remove any debug message from the current target
    getMessageByType( 'debug', { remove => 1 } );
    $self->{'debug'} = 0;
    undef;
}

=item setVerbose()

 Enable or disable verbose mode

 Param bool $debug Enable debug mode if true, disable otherwise
 Return undef

=cut

sub setVerbose
{
    $self->{'verbose'} = shift // 0;
    undef;
}

=item silent()

 Method kept for backward compatibility (plugins)

 Return undef

=cut

sub silent
{

}

=item newDebug($logfile)

 Create new log object for the given logfile and set it as current target for new messages

 Param string $logfile Logfile unique identifier
 Return int 0

=cut

sub newDebug
{
    my $logfile = shift || '';

    fatal( "logfile name expected" ) if ref $logfile || $logfile eq '';
    $self->{'target'} = iMSCP::Log->new( id => $logfile );
    push @{$self->{'targets'}}, $self->{'target'};
    0;
}

=item endDebug()

 Write current logfile and set the target for new messages to the previous log object

 Return int 0

=cut

sub endDebug
{
    my $target = pop @{$self->{'targets'}};
    my $targetId = $target->getId();

    if ($targetId eq 'default') {
        push @{$self->{'targets'}}, $target;
        $self->{'target'} = $self->{'default'};
        return 0;
    }

    my @firstItems = (@{$self->{'targets'}} == 1) ? $self->{'default'}->flush() : ();

    # Retrieve any log which must be printed to default and store them in the appropriate log object
    for my $item($target->retrieve( tag => qr/^(?:warn|error|fatal)/i ), @firstItems) {
        $self->{'default'}->store( when => $item->{'when'}, message => $item->{'message'}, tag => $item->{'tag'} );
    }

    my $logDir = $main::imscpConfig{'LOG_DIR'} || '/tmp';
    if ($logDir ne '/tmp' && !-d $logDir) {
        require iMSCP::Dir;
        my $rs = iMSCP::Dir->new( dirname => $logDir )->make(
            {
                user  => $main::imscpConfig{'ROOT_USER'},
                group => $main::imscpConfig{'ROOT_GROUP'},
                mode  => 0750
            }
        );
        $logDir = '/tmp' if $rs;
    }

    # Write logfile
    $targetId =~ s#[\s?+%/:]+#:#gs; # Replace unwanted characters in logfile names
    _writeLogfile( $target, "$logDir/$targetId" );

    # Set previous log object as target for new messages
    $self->{'target'} = @{$self->{'targets'}}[$#{$self->{'targets'}}];
    0;
}

=item debug($message)

 Log debug message

 Param string $message Debug message
 Return int undef

=cut

sub debug
{
    my $message = shift;

    my $caller = (caller( 1 ))[3] || 'main';
    $self->{'target'}->store( message => "$caller: $message", tag => 'debug' ) if $self->{'debug'};
    print STDOUT output( "$caller: $message", 'debug' ) if $self->{'verbose'};
    undef;
}

=item warning($message [, $caller ])

 Log warning message

 Param string $message Warning message
 Param string $caller OPTIONAL Caller
 Return int undef

=cut

sub warning
{
    my $message = shift;

    my $caller = shift || (caller( 1 ))[3] || 'main';
    $self->{'target'}->store( message => "$caller: $message", tag => 'warn' );
    undef;
}

=item error($message)

 Log error message

 Param string $message Error message
 Return int undef

=cut

sub error
{
    my $message = shift;

    my $caller = (caller( 1 ))[3] || 'main';
    $self->{'target'}->store( message => "$caller: $message", tag => 'error' );
    0;
}

=item fatal($message [, $caller ])

 Log fatal message

 Param string $message Fatal message
 Param string $caller OPTIONAL Caller
 Return void

=cut

sub fatal
{
    my $message = shift;

    my $caller = shift || (caller( 1 ))[3] || 'main';
    $self->{'target'}->store( message => "$caller: $message", tag => 'fatal' );
    exit 255;
}

=item getLastError()

 Get last error message

 Return string last error message

=cut

sub getLastError
{
    getMessageByType( 'error' );
}

=item getMessageByType($type = 'error', [ %option | \%options ])

 Get message by type

 Param string $type Type or regexp
 Param hash %option|\%options Hash containing options (amount, chrono, remove)
 Return array|string Either an array containing messages or a string representing concatenation of messages

=cut

sub getMessageByType
{
    my $type = shift || '';

    my %options = (@_ && ref $_[0] eq 'HASH') ? %{$_[0]} : @_;
    my @messages = map { $_->{'message'} } $self->{'target'}->retrieve(
        tag    => ref $type eq 'Regexp' ? $type : qr/^$type$/i,
        amount => $options{'amount'},
        chrono => $options{'chrono'} // 1,
        remove => $options{'remove'} // 0
    );
    wantarray ? @messages : join "\n", @messages;
}

=item output($text, $level)

 Prepare the given text to be show on the console according the given level

 Return string Formatted message

=cut

sub output
{
    my ($text, $level) = @_;

    return "$text\n" unless $level;

    my $output = '';

    if ($level eq 'debug') {
        $output = "[\033[0;34mDEBUG\033[0m] $text\n";
    } elsif ($level eq 'info') {
        $output = "[\033[0;34mINFO\033[0m]  $text\n";
    } elsif ($level eq 'warn') {
        $output = "[\033[0;33mWARN\033[0m]  $text\n";
    } elsif ($level eq 'error') {
        $output = "[\033[0;31mERROR\033[0m] $text\n";
    } elsif ($level eq 'fatal') {
        $output = "[\033[0;31mFATAL\033[0m] $text\n";
    } elsif ($level eq 'ok') {
        $output = "[\033[0;32mDONE\033[0m]  $text\n";
    } else {
        $output = "$text\n";
    }

    $output;
}

=item debugRegisterCallBack($callback)

 Register the given callback, which will be triggered before log processing

 Param callback Callback to register
 Return int 0;

=cut

sub debugRegisterCallBack
{
    my $callback = shift;

    push @{$self->{'debugCallBacks'}}, $callback;
    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _writeLogfile($logObject, $logfilePath)

 Write all messages for the given log

 Param iMSCP::Log $logObject iMSCP::Log object representing a logfile
 Param string $logfilePath Logfile path

 Return int 0

=cut

sub _writeLogfile
{
    my ($logObject, $logfilePath) = @_;

    # Make error message free of any ANSI color and end of line codes
    (my $messages = _getMessages( $logObject )) =~ s/\x1B\[([0-9]{1,3}((;[0-9]{1,3})*)?)?[m|K]//g;

    if (open( my $fh, '>', $logfilePath )) {
        print {$fh} $messages;
        close $fh;
        return 0;
    }

    print output( sprintf("Could not to open log file `%s' for writting: %s", $logfilePath, $! ), 'error');
    0;
}

=item _getMessages($logObject)

 Flush and return all messages for the given log object as a string

 Param iMSCP::Log $logObject iMSCP::Log object representing a logfile
 Return string String representing concatenation of all messages found in the given log object

=cut

sub _getMessages
{
    my $logObject = shift;

    my $bf = '';
    $bf .= "[$_->{'when'}] [$_->{'tag'}] $_->{'message'}\n" for $logObject->flush();
    $bf;
}

=item END

 Process ending tasks (Dump of messages)

=cut

END {
    my $exitCode = $?;

    &{$_} for @{$self->{'debugCallBacks'}};
    endDebug() for @{$self->{'targets'}};

    my @output;
    for my $logLevel('warn', 'error', 'fatal') {
        my @messages;
        push @messages, $_->{'message'} for $self->{'default'}->retrieve( tag => qr/^$logLevel/ );
        push @output, output( join( "\n", @messages ), $logLevel ) if @messages;
    }

    print STDERR "@output" if @output;

    $? = $exitCode;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
