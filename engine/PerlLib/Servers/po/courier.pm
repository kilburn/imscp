=head1 NAME

 Servers::po::courier - i-MSCP Courier IMAP/POP3 Server implementation

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

package Servers::po::courier;

use strict;
use warnings;
use iMSCP::Config;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Service;
use Servers::mta;
use Tie::File;
use Class::Autouse qw/ :nostat Servers::po::courier::installer Servers::po::courier::uninstaller /;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Courier IMAP/POP3 Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my (undef, $eventManager) = @_;

    Servers::po::courier::installer->getInstance()->registerSetupListeners( $eventManager );
}

=item preinstall()

 Process preinstall tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoPreinstall', 'courier' );
    $rs ||= $self->stop();
    $rs ||= $self->{'eventManager'}->trigger( 'afterPoPreinstall', 'courier' );
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoInstall', 'courier' );
    $rs ||= Servers::po::courier::installer->getInstance()->install();
    $rs ||= $self->{'eventManager'}->trigger( 'afterPoInstall', 'courier' );
}

=item postinstall()

 Process postinstall tasks

 Return int 0 on success, other on failure

=cut

sub postinstall
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoPostinstall', 'courier' );
    return $rs if $rs;

    local $@;
    eval {
        my @toEnableServices = ('AUTHDAEMON_SNAME', 'POPD_SNAME', 'IMAPD_SNAME');
        my @toDisableServices = ();

        if ($main::imscpConfig{'SERVICES_SSL_ENABLED'} eq 'yes') {
            push @toEnableServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        } else {
            push @toDisableServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        }

        my $serviceMngr = iMSCP::Service->getInstance();
        $serviceMngr->enable( $self->{'config'}->{$_} ) for @toEnableServices;

        for(@toDisableServices) {
            $serviceMngr->stop( $self->{'config'}->{$_} );
            $serviceMngr->disable( $self->{'config'}->{$_} );
        }
    };
    if ($@) {
        error( $@ );
        return 1;
    }

    $rs = $self->{'eventManager'}->register(
        'beforeSetupRestartServices',
        sub {
            push @{$_[0]}, [ sub { $self->start(); }, 'Courier IMAP/POP, Courier Authdaemon' ];
            0;
        }
    );
    $rs ||= $self->{'eventManager'}->trigger( 'afterPoPostinstall', 'courier' );
}

=item uninstall()

 Process uninstall tasks

 Return int 0 on success, other on failure

=cut

sub uninstall
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoUninstall', 'courier' );
    $rs ||= Servers::po::courier::uninstaller->getInstance()->uninstall();
    $rs ||= $self->restart();
    $rs ||= $self->{'eventManager'}->trigger( 'afterPoUninstall', 'courier' );
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoSetEnginePermissions' );
    $rs ||= Servers::po::courier::installer->getInstance()->setEnginePermissions();
    $rs ||= $self->{'eventManager'}->trigger( 'afterPoSetEnginePermissions' );
}

=item postaddMail(\%data)

 Process postaddMail tasks

 Param hash \%data Mail data
 Return int 0 on success, other on failure

=cut

sub postaddMail
{
    my (undef, $data) = @_;

    return 0 unless $data->{'MAIL_TYPE'} =~ /_mail/;

    my $mta = Servers::mta->factory();
    my $mailDir = "$mta->{'config'}->{'MTA_VIRTUAL_MAIL_DIR'}/$data->{'DOMAIN_NAME'}/$data->{'MAIL_ACC'}";
    my $mailUidName = $mta->{'config'}->{'MTA_MAILBOX_UID_NAME'};
    my $mailGidName = $mta->{'config'}->{'MTA_MAILBOX_GID_NAME'};

    for my $mailbox('.Drafts', '.Junk', '.Sent', '.Trash') {
        my $rs = iMSCP::Dir->new( dirname => "$mailDir/$mailbox" )->make(
            {
                user => $mailUidName,
                group => $mailGidName,
                mode => 0750,
                fixpermissions => iMSCP::Getopt->fixPermissions
            }
        );
        return $rs if $rs;

        for ('cur', 'new', 'tmp') {
            $rs = iMSCP::Dir->new( dirname => "$mailDir/$mailbox/$_" )->make(
                {
                    user => $mailUidName,
                    group => $mailGidName,
                    mode => 0750,
                    fixpermissions => iMSCP::Getopt->fixPermissions
                }
            );
            return $rs if $rs;
        }
    }

    my @subscribedFolders = ('INBOX.Drafts', 'INBOX.Junk', 'INBOX.Sent', 'INBOX.Trash');
    my $subscriptionsFile = iMSCP::File->new( filename => "$mailDir/courierimapsubscribed" );

    if (-f "$mailDir/courierimapsubscribed") {
        my $subscriptionsFileContent = $subscriptionsFile->get();
        unless (defined $subscriptionsFile) {
            error( 'Could not read Courier subscriptions file' );
            return 1;
        }

        if ($subscriptionsFileContent ne '') {
            @subscribedFolders = (@subscribedFolders, split( "\n", $subscriptionsFileContent ));
            require List::MoreUtils;
            @subscribedFolders = sort { lc $a cmp lc $b } List::MoreUtils::uniq(@subscribedFolders);
        }
    }

    my $rs = $subscriptionsFile->set( (join "\n", @subscribedFolders)."\n" );
    $rs = $subscriptionsFile->save();
    $rs ||= $subscriptionsFile->owner( $mailUidName, $mailGidName );
    $rs ||= $subscriptionsFile->mode( 0640 );
    return $rs if $rs;

    if (defined( $data->{'MAIL_QUOTA'} ) && $data->{'MAIL_QUOTA'} != 0) {
        my @maildirmakeCmdArgs = (escapeShell( "$data->{'MAIL_QUOTA'}S" ), escapeShell( "$mailDir" ));
        $rs = execute( "maildirmake -q @maildirmakeCmdArgs", \my $stdout, \my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr || 'Unknown error' ) if $rs;
        return $rs if $rs;

        if (-f "$mailDir/maildirsize") {
            my $file = iMSCP::File->new( filename => "$mailDir/maildirsize" );
            $rs ||= $file->owner( $mailUidName, $mailGidName );
            $rs = $file->mode( 0640 );
            return $rs if $rs;
        }
    } elsif (-f "$mailDir/maildirsize") {
        $rs = iMSCP::File->new( filename => "$mailDir/maildirsize" )->delFile();
        return $rs if $rs;
    }

    0;
}

=item start()

 Start courier servers

 Return int 0 on success, other on failure

=cut

sub start
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoStart' );
    return $rs if $rs;

    local $@;
    eval {
        my $serviceMngr = iMSCP::Service->getInstance();

        for my $service('AUTHDAEMON_SNAME', 'POPD_SNAME', 'IMAPD_SNAME') {
            $serviceMngr->start( $self->{'config'}->{$service} );
        }

        if ($main::imscpConfig{'SERVICES_SSL_ENABLED'} eq 'yes') {
            for my $service('POPD_SSL_SNAME', 'IMAPD_SSL_SNAME') {
                $serviceMngr->start( $self->{'config'}->{$service} );
            }
        }
    };
    if ($@) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterPoStart' );
}

=item stop()

 Stop courier servers

 Return int 0 on success, other on failure

=cut

sub stop
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoStop' );
    return $rs if $rs;

    local $@;
    eval {
        my $serviceMngr = iMSCP::Service->getInstance();
        for my $service('AUTHDAEMON_SNAME', 'POPD_SNAME', 'POPD_SSL_SNAME', 'IMAPD_SNAME', 'IMAPD_SSL_SNAME') {
            $serviceMngr->stop( $self->{'config'}->{$service} );
        }
    };
    if ($@) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterPoStop' );
}

=item restart()

 Restart courier servers

 Return int 0 on success, other on failure

=cut

sub restart
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoRestart' );
    return $rs if $rs;

    local $@;
    eval {
        my @toRestartServices = ('AUTHDAEMON_SNAME', 'POPD_SNAME', 'IMAPD_SNAME');
        if ($main::imscpConfig{'SERVICES_SSL_ENABLED'} eq 'yes') {
            push @toRestartServices, 'POPD_SSL_SNAME', 'IMAPD_SSL_SNAME';
        }

        my $serviceMngr = iMSCP::Service->getInstance();
        $serviceMngr->restart( $self->{'config'}->{$_} ) for @toRestartServices;
    };
    if ($@) {
        error( $@ );
        return 1;
    }

    $self->{'eventManager'}->trigger( 'afterPoRestart' );
}

=item getTraffic()

 Get IMAP/POP traffic data

 Return hash Traffic data or die on failure

=cut

sub getTraffic
{
    my ($self, $trafficDataSrc, $trafficDb) = @_;

    require File::Temp;

    my $trafficDir = $main::imscpConfig{'IMSCP_HOMEDIR'};
    my $trafficDbPath = "$trafficDir/po_traffic.db";
    my $selfCall = 1;
    my %trafficDb;

    # Load traffic database
    unless (ref $trafficDb eq 'HASH') {
        tie %trafficDb, 'iMSCP::Config', fileName => $trafficDbPath, nodie => 1;
        $selfCall = 0;
    } else {
        %trafficDb = %{$trafficDb};
    }

    # Data source file
    $trafficDataSrc ||= "$main::imscpConfig{'TRAFF_LOG_DIR'}/$main::imscpConfig{'MAIL_TRAFF_LOG'}";

    if (-f -s $trafficDataSrc) {
        # We are using a small file to memorize the number of the last line that has been read and his content
        tie my %indexDb, 'iMSCP::Config', fileName => "$trafficDir/traffic_index.db", nodie => 1;

        my $lastParsedLineNo = $indexDb{'po_lineNo'} || 0;
        my $lastParsedLineContent = $indexDb{'po_lineContent'} || '';

        # Create a snapshot of log file to process
        my $tmpFile = File::Temp->new( UNLINK => 1 );
        iMSCP::File->new( filename => $trafficDataSrc )->copyFile( $tmpFile, { preserve => 'no' } ) == 0 or die(
            iMSCP::Debug::getLastError()
        );

        tie my @content, 'Tie::File', $tmpFile or die( sprintf( 'Could not tie %s file', $tmpFile ) );

        unless ($selfCall) {
            # Save last processed line number and line content
            $indexDb{'po_lineNo'} = $#content;
            $indexDb{'po_lineContent'} = $content[$#content];
        }

        if ($content[$lastParsedLineNo] && $content[$lastParsedLineNo] eq $lastParsedLineContent) {
            # Skip lines which were already processed
            (tied @content)->defer;
            @content = @content[$lastParsedLineNo + 1 .. $#content];
            (tied @content)->flush;
        } elsif (!$selfCall) {
            debug( sprintf( 'Log rotation has been detected. Processing %s first...', "$trafficDataSrc.1" ) );
            %trafficDb = %{$self->getTraffic( "$trafficDataSrc.1", \%trafficDb )};
            $lastParsedLineNo = 0;
        }

        debug( sprintf( 'Processing lines from %s, starting at line %d', $trafficDataSrc, $lastParsedLineNo ) );

        if (@content) {
            untie @content;

            # Read and parse IMAP/POP traffic source file (line by line)
            open my $fh, '<', $tmpFile or die( sprintf( 'Could not open file: %s', $! ) );
            while(<$fh>) {
                # Extract traffic data ( IMAP )
                #
                # Important consideration for both IMAP and POP traffic accounting with courier
                #
                # Courier distinguishes header, body, received and sent bytes fields. Clearly, header and body fields can be zero
                # while there is still some traffic. But more importantly, body gives only the bytes of messages sent.
                #
                # Here, we want count all traffic so we take sum of the received and sent bytes only.
                #
                # IMAP traffic line sample
                # Oct 15 12:56:42 imscp imapd: LOGOUT, user=user@domain.tld, ip=[::ffff:192.168.1.2], headers=0, body=0, rcvd=172, sent=310, time=205
                if (m/^.*(?:imapd|imapd\-ssl).*user=[^\@]*\@([^,]*),\sip=\[([^\]]+)\],\sheaders=\d+,\sbody=\d+,\srcvd=(\d+),\ssent=(\d+),.*$/gim
                    && !grep($_ eq $2, ( 'localhost', '127.0.0.1', '::1', '::ffff:127.0.0.1' ))
                ) {
                    $trafficDb{$1} += $3 + $4;
                    next;
                }

                # Extract traffic data ( POP3 )
                #
                # POP traffic line sample
                #
                # Oct 15 14:54:06 imscp pop3d: LOGOUT, user=user@domain.tld, ip=[::ffff:192.168.1.2], port=[41477], top=0, retr=0, rcvd=32, sent=147, time=0, stls=1
                # Oct 15 14:51:12 imscp pop3d-ssl: LOGOUT, user=user@domain.tld, ip=[::ffff:192.168.1.2], port=[41254], top=0, retr=496, rcvd=32, sent=672, time=0, stls=1
                #
                # Note: courierpop3login is for Debian. pop3d for Fedora.
                $trafficDb{$1} += $3 + $4 if m/^.*(?:courierpop3login|pop3d|pop3d-ssl).*user=[^\@]*\@([^,]*),\sip=\[([^\]]+)\].*\stop=\d+,\sretr=\d+,\srcvd=(\d+),\ssent=(\d+),.*$/gim
                    && !grep($_ eq $2, ( 'localhost', '127.0.0.1', '::1', '::ffff:127.0.0.1' ));
            }
            close( $fh );
        } else {
            debug( sprintf( 'No traffic data found in %s - Skipping', $trafficDataSrc ) );
            untie @content;
        }
    } elsif (!$selfCall) {
        debug( sprintf( 'Log rotation has been detected. Processing %s...', "$trafficDataSrc.1" ) );
        %trafficDb = %{$self->getTraffic( "$trafficDataSrc.1", \%trafficDb )};
    }

    # Schedule deletion of traffic database. This is only done on success. On failure, the traffic database is kept
    # in place for later processing. In such case, data already processed are zeroed by the traffic processor script.
    $self->{'eventManager'}->register(
        'afterVrlTraffic',
        sub { -f $trafficDbPath ? iMSCP::File->new( filename => $trafficDbPath )->delFile() : 0; }
    ) unless $selfCall;

    \%trafficDb;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Servers::po::courier

=cut

sub _init
{
    my $self = shift;

    $self->{'restart'} = 0;
    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self->{'cfgDir'} = "$main::imscpConfig{'CONF_DIR'}/courier";
    $self->{'bkpDir'} = "$self->{'cfgDir'}/backup";
    $self->{'wrkDir'} = "$self->{'cfgDir'}/working";
    tie %{$self->{'config'}}, 'iMSCP::Config', fileName => "$self->{'cfgDir'}/courier.data", readonly => 1;
    $self;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
