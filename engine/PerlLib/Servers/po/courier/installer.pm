=head1 NAME

 Servers::po::courier::installer - i-MSCP Courier IMAP/POP3 Server installer implementation

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

package Servers::po::courier::installer;

use strict;
use warnings;
use File::Basename;
use iMSCP::Config;
use iMSCP::Crypt qw/ randomStr /;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dialog::InputValidation;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::Rights;
use iMSCP::ProgramFinder;
use iMSCP::Stepper;
use iMSCP::TemplateParser;
use Servers::mta::postfix;
use Servers::po::courier;
use Servers::sqld;
use parent 'Common::SingletonClass';

%main::sqlUsers = () unless %main::sqlUsers;
@main::createdSqlUsers = () unless @main::createdSqlUsers;

=head1 DESCRIPTION

 i-MSCP Courier IMAP/POP3 Server installer implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
    my ($self, $eventManager) = @_;

    my $rs = $eventManager->register(
        'beforeSetupDialog',
        sub {
            push @{$_[0]},
                sub { $self->authdaemonSqlUserDialog( @_ ) },
                sub { $self->cyrusSaslSqlUserDialog( @_ ) };
            0;
        }
    );
    $rs ||= $eventManager->register( 'beforeMtaBuildMainCfFile', sub { $self->configurePostfix( @_ ); } );
    $rs ||= $eventManager->register( 'beforeMtaBuildMasterCfFile', sub { $self->configurePostfix( @_ ); } );
}

=item authdaemonSqlUserDialog(\%dialog)

 Authdaemon SQL user dialog

 Param iMSCP::Dialog \%dialog
 Return int 0 on success, other on failure

=cut

sub authdaemonSqlUserDialog
{
    my ($self, $dialog) = @_;

    my $masterSqlUser = main::setupGetQuestion( 'DATABASE_USER' );
    my $dbUser = main::setupGetQuestion('AUTHDAEMON_SQL_USER', $self->{'config'}->{'AUTHDAEMON_DATABASE_USER'} || 'authdaemon_user');
    my $dbPass = main::setupGetQuestion('AUTHDAEMON_SQL_PASSWORD', $self->{'config'}->{'AUTHDAEMON_DATABASE_PASSWORD'});

    if ($main::reconfigure =~ /^(?:po|servers|all|forced)$/
        || !isValidUsername($dbUser)
        || !isStringNotInList($dbUser, 'root', $masterSqlUser)
        || !isValidPassword($dbPass)
    ) {
        my ($rs, $msg) = (0, '');

        do {
            ($rs, $dbUser) = $dialog->inputbox( <<"EOF", $dbUser );

Please enter an username for the Courier Authdaemon SQL user:$msg
EOF
            $msg = '';
            if (!isValidUsername($dbUser)
                || !isStringNotInList($dbUser, 'root', $masterSqlUser)
            ) {
                $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
            }
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;

        if (isStringNotInList($dbUser, keys %main::sqlUsers)) {
            do {
                ($rs, $dbPass) = $dialog->inputbox( <<"EOF", $dbPass || randomStr(16, iMSCP::Crypt::ALNUM) );

Please enter a password for the Courier Authdaemon SQL user:$msg
EOF
                $msg = (isValidPassword($dbPass)) ? '' : $iMSCP::Dialog::InputValidation::lastValidationError;
            } while $rs < 30 && $msg;
            return $rs if $rs >= 30;
        } else {
            $dbPass = $main::sqlUsers{$dbUser};
        }
    }

    main::setupSetQuestion( 'AUTHDAEMON_SQL_USER', $dbUser );
    main::setupSetQuestion( 'AUTHDAEMON_SQL_PASSWORD', $dbPass );
    $main::sqlUsers{$dbUser} = $dbPass;
    0;
}

=item cyrusSaslSqlUserDialog(\%dialog)

 Cyrus SASL SQL user dialog

 Param iMSCP::Dialog \%dialog
 Return int 0 on success, other on failure

=cut

sub cyrusSaslSqlUserDialog
{
    my ($self, $dialog) = @_;

    my $masterSqlUser = main::setupGetQuestion( 'DATABASE_USER' );
    my $dbUser = main::setupGetQuestion( 'SASL_SQL_USER', $self->{'config'}->{'SASL_DATABASE_USER'} || 'sasl_user' );
    my $dbPass = main::setupGetQuestion( 'SASL_SQL_PASSWORD', $self->{'config'}->{'SASL_DATABASE_PASSWORD'} );

    if ($main::reconfigure =~ /^(?:po|servers|all|forced)$/
        || !isValidUsername($dbUser)
        || !isStringNotInList($dbUser, 'root', $masterSqlUser)
        || !isValidPassword($dbPass)
    ) {
        my ($rs, $msg) = (0, '');

        do {
            ($rs, $dbUser) = $dialog->inputbox(
                "\nPlease enter a username for the Postfix SASL SQL user:$msg", $dbUser
            );

            $msg = '';
            if (!isValidUsername($dbUser)
                || !isStringNotInList($dbUser, 'root', $masterSqlUser)
            ) {
                $msg = $iMSCP::Dialog::InputValidation::lastValidationError;
            }
        } while $rs < 30 && $msg;
        return $rs if $rs >= 30;

        if (isStringNotInList($dbUser, keys %main::sqlUsers)) {
            do {
                ($rs, $dbPass) = $dialog->inputbox( <<"EOF", $dbPass || randomStr(16, iMSCP::Crypt::ALNUM) );

Please enter a password for the Postfix SASL SQL user:$msg
EOF
                $msg = (isValidPassword($dbPass)) ? '' : $iMSCP::Dialog::InputValidation::lastValidationError;
            } while $rs < 30 && $msg;
            return $rs if $rs >= 30;
        } else {
            $dbPass = $main::sqlUsers{$dbUser};
        }
    }

    main::setupSetQuestion( 'SASL_SQL_USER', $dbUser );
    main::setupSetQuestion( 'SASL_SQL_PASSWORD', $dbPass );
    $main::sqlUsers{$dbUser} = $dbPass;
    0;
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my $self = shift;

    for my $file(
        "/etc/init.d/$self->{'config'}->{'AUTHDAEMON_SNAME'}",
        "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/authdaemonrc",
        "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/authmysqlrc",
        "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/self->{'config'}->{'COURIER_IMAP_SSL'}",
        "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/$self->{'config'}->{'COURIER_POP_SSL'}"
    ) {
        my $rs = $self->_bkpConfFile( $file );
        return $rs if $rs;
    }

    my $rs = $self->_setupAuthdaemonSqlUser();
    $rs ||= $self->_setupCyrusSaslSqlUser();
    $rs ||= $self->_overrideAuthdaemonInitScript();
    $rs ||= $self->_buildConf();
    $rs ||= $self->_buildCyrusSaslConfFile();
    $rs ||= $self->_saveConf();
    $rs ||= $self->_migrateFromDovecot();
    $rs ||= $self->_oldEngineCompatibility();
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
    my $self = shift;

    my $rs = setRights(
        $self->{'config'}->{'AUTHLIB_SOCKET_DIR'},
        {
            user  => $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'},
            group => $self->{'config'}->{'AUTHDAEMON_GROUP'},
            mode  => '0750'
        }
    );
    return $rs if $rs;

    if (-f "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem") {
        $rs = setRights(
            "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem",
            {
                user  => $self->{'config'}->{'AUTHDAEMON_USER'},
                group => $main::imscpConfig{'ROOT_GROUP'},
                mode  => '0600'
            }
        );
        return $rs if $rs;
    }

    0;
}

=back

=head1 EVENT LISTENERS

=over 4

=item configurePostfix(\$fileContent, $fileName)

 Injects configuration for both, maildrop LDA and Cyrus SASL in Postfix configuration files.

 Listener that listen on the following events:
  - beforeMtaBuildMainCfFile
  - beforeMtaBuildMasterCfFile

 Param string \$fileContent Configuration file content
 Param string $fileName Configuration filename
 Return int 0 on success, other on failure

=cut

sub configurePostfix
{
    my ($self, $fileContent, $fileName) = @_;

    if ($fileName eq 'main.cf') {
        return $self->{'eventManager'}->register(
            'afterMtaBuildConf',
            sub {
                $self->{'mta'}->postconf(
                    (
                        # Maildrop MDA parameters
                        virtual_transport                      => { action => 'replace', values => [ 'maildrop' ] },
                        maildrop_destination_concurrency_limit => { action => 'replace', values => [ '2' ] },
                        maildrop_destination_recipient_limit   => { action => 'replace', values => [ '1' ] },
                        # Cyrus SASL parameters
                        smtpd_sasl_type                        => { action => 'replace', values => [ 'cyrus' ] },
                        smtpd_sasl_path                        => { action => 'replace', values => [ 'smtpd' ] },
                        smtpd_sasl_auth_enable                 => { action => 'replace', values => [ 'yes' ] },
                        smtpd_sasl_security_options            => { action => 'replace', values => [ 'noanonymous' ] },
                        smtpd_sasl_authenticated_header        => { action => 'replace', values => [ 'yes' ] },
                        broken_sasl_auth_clients               => { action => 'replace', values => [ 'yes' ] }
                    )
                );
            }
        );
    }

    if ($fileName eq 'master.cf') {
        my $configSnippet = <<'EOF';

maildrop  unix  -       n       n       -       -       pipe
 flags=DRhu user={MTA_MAILBOX_UID_NAME}:{MTA_MAILBOX_GID_NAME} argv=maildrop -w 90 -d ${user}@${nexthop} ${extension} ${recipient} ${user} ${nexthop} ${sender}
EOF
        $$fileContent .= iMSCP::TemplateParser::process(
            {
                MTA_MAILBOX_UID_NAME => $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'},
                MTA_MAILBOX_GID_NAME => $self->{'mta'}->{'config'}->{'MTA_MAILBOX_GID_NAME'}
            },
            $configSnippet
        );
    }

    0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Servers::po::courier::installer

=cut

sub _init
{
    my $self = shift;

    $self->{'eventManager'} = iMSCP::EventManager->getInstance();
    $self->{'po'} = Servers::po::courier->getInstance();
    $self->{'mta'} = Servers::mta::postfix->getInstance();
    $self->{'cfgDir'} = $self->{'po'}->{'cfgDir'};
    $self->{'bkpDir'} = "$self->{'cfgDir'}/backup";
    $self->{'wrkDir'} = "$self->{'cfgDir'}/working";
    $self->{'config'} = $self->{'po'}->{'config'};

    # Be sure to work with newest conffile
    # Cover case where the conffile has been loaded prior installation of new files (even if discouraged)
    untie(%{$self->{'config'}});
    tie %{$self->{'config'}}, 'iMSCP::Config', fileName => "$self->{'cfgDir'}/courier.data";

    my $oldConf = "$self->{'cfgDir'}/courier.old.data";

    if(defined $main::execmode && $main::execmode eq 'setup' && -f $oldConf) {
        tie my %oldConfig, 'iMSCP::Config', fileName => $oldConf, readonly => 1;
        while(my($key, $value) = each(%oldConfig)) {
            next unless exists $self->{'config'}->{$key};
            $self->{'config'}->{$key} = $value;
        }
    }

    $self;
}

=item _bkpConfFile($filePath)

 Backup the given file

 Param string $filePath File path
 Return int 0 on success, other on failure

=cut

sub _bkpConfFile
{
    my ($self, $filePath) = @_;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoBkpConfFile', $filePath );
    return $rs if $rs;

    if (-f $filePath) {
        my $fileName = fileparse( $filePath );
        my $file = iMSCP::File->new( filename => $filePath );

        unless (-f "$self->{'bkpDir'}/$fileName.system") {
            $rs = $file->copyFile( "$self->{'bkpDir'}/$fileName.system" );
            return $rs if $rs;
        } else {
            $rs = $file->copyFile( "$self->{'bkpDir'}/$fileName".time() );
            return $rs if $rs;
        }
    }

    $self->{'eventManager'}->trigger( 'afterPoBkpConfFile', $filePath );
}

=item _setupAuthdaemonSqlUser()

 Setup authdaemon SQL user

 Return int 0 on success, other on failure

=cut

sub _setupAuthdaemonSqlUser
{
    my $self = shift;

    my $sqlServer = Servers::sqld->factory();
    my $dbName = main::setupGetQuestion( 'DATABASE_NAME' );
    my $dbUser = main::setupGetQuestion( 'AUTHDAEMON_SQL_USER' );
    my $dbUserHost = main::setupGetQuestion( 'DATABASE_USER_HOST' );
    my $oldDbUserHost = $main::imscpOldConfig{'DATABASE_USER_HOST'} || '';
    my $dbPass = main::setupGetQuestion( 'AUTHDAEMON_SQL_PASSWORD' );
    my $dbOldUser = $self->{'config'}->{'AUTHDAEMON_DATABASE_USER'};

    my $rs = $self->{'eventManager'}->trigger(
        'beforePoSetupAuthdaemonSqlUser', $dbUser, $dbOldUser, $dbPass, $dbUserHost
    );
    return $rs if $rs;

    for my $sqlUser ($dbOldUser, $dbUser) {
        next if !$sqlUser || grep($_ eq "$sqlUser\@$dbUserHost", @main::createdSqlUsers);

        for my $host($dbUserHost, $oldDbUserHost) {
            next unless $host;
            $sqlServer->dropUser( $sqlUser, $host );
        }
    }

    my $db = iMSCP::Database->factory();

    # Create SQL user if not already created by another server/package installer
    unless (grep($_ eq "$dbUser\@$dbUserHost", @main::createdSqlUsers)) {
        debug( sprintf( 'Creating %s@%s SQL user', $dbUser, $dbUserHost ) );
        $sqlServer->createUser( $dbUser, $dbUserHost, $dbPass );
        push @main::createdSqlUsers, "$dbUser\@$dbUserHost";
    }

    # Give needed privileges to this SQL user

    # No need to escape wildcard characters. See https://bugs.mysql.com/bug.php?id=18660
    my $quotedDbName = $db->quoteIdentifier( $dbName );
    $rs = $db->doQuery( 'g', "GRANT SELECT ON $quotedDbName.mail_users TO ?\@?", $dbUser, $dbUserHost );
    unless (ref $rs eq 'HASH') {
        error( sprintf( 'Could not add SQL privileges: %s', $rs ) );
        return 1;
    }

    $self->{'config'}->{'AUTHDAEMON_DATABASE_USER'} = $dbUser;
    $self->{'config'}->{'AUTHDAEMON_DATABASE_PASSWORD'} = $dbPass;
    $self->{'eventManager'}->trigger( 'afterPoSetupAuthdaemonSqlUser' );
}

=item _setupCyrusSaslSqlUser()

 Setup Cyrus SASL SQL user

 Return int 0 on success, other on failure

=cut

sub _setupCyrusSaslSqlUser
{
    my $self = shift;

    my $sqlServer = Servers::sqld->factory();
    my $dbName = main::setupGetQuestion( 'DATABASE_NAME' );
    my $dbUser = main::setupGetQuestion( 'SASL_SQL_USER' );
    my $dbUserHost = main::setupGetQuestion( 'DATABASE_USER_HOST' );
    $dbUserHost = '127.0.0.1' if $dbUserHost eq 'localhost';
    my $oldDbuSerHost = $main::imscpOldConfig{'DATABASE_USER_HOST'} || '';
    my $dbPass = main::setupGetQuestion( 'SASL_SQL_PASSWORD' );
    my $dbOldUser = $self->{'config'}->{'SASL_DATABASE_USER'};

    my $rs = $self->{'eventManager'}->trigger(
        'beforePoSetupCyrusSaslSqlUser', $dbUser, $dbOldUser, $dbPass, $dbUserHost
    );
    return $rs if $rs;

    for my $sqlUser ($dbOldUser, $dbUser) {
        next if !$sqlUser || grep($_ eq "$sqlUser\@$dbUserHost", @main::createdSqlUsers);

        for my $host($dbUserHost, $oldDbuSerHost) {
            next unless $host;
            $sqlServer->dropUser( $sqlUser, $host );
        }
    }

    my $db = iMSCP::Database->factory();

    # Create SQL user if not already created by another server/package installer
    unless (grep($_ eq "$dbUser\@$dbUserHost", @main::createdSqlUsers)) {
        debug( sprintf( 'Creating %s@%s SQL user with password: %s', $dbUser, $dbUserHost, $dbPass ) );
        $sqlServer->createUser( $dbUser, $dbUserHost, $dbPass );
        push @main::createdSqlUsers, "$dbUser\@$dbUserHost";
    }

    # No need to escape wildcard characters. See https://bugs.mysql.com/bug.php?id=18660
    my $quotedDbName = $db->quoteIdentifier( $dbName );
    $rs = $db->doQuery( 'g', "GRANT SELECT ON $quotedDbName.mail_users TO ?\@?", $dbUser, $dbUserHost );
    unless (ref $rs eq 'HASH') {
        error( sprintf( 'Could not add SQL privileges: %s', $rs ) );
        return 1;
    }

    $self->{'config'}->{'SASL_DATABASE_USER'} = $dbUser;
    $self->{'config'}->{'SASL_DATABASE_PASSWORD'} = $dbPass;
    $self->{'eventManager'}->trigger( 'afterPoSetupCyrusSaslSqlUser' );
}

=item _overrideAuthdaemonInitScript()

 Override courier-authdaemon init script

 Return int 0 on success, other on failure

=cut

sub _overrideAuthdaemonInitScript
{
    my $self = shift;

    my $file = iMSCP::File->new( filename => "/etc/init.d/$self->{'config'}->{'AUTHDAEMON_SNAME'}" );
    my $fileContent = $file->get();
    unless (defined $fileContent) {
        error( sprintf( 'Could not read %s file', $file->{'filename'} ) );
        return 1;
    }

    my $mailUser = $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'};
    my $authdaemonUser = $self->{'config'}->{'AUTHDAEMON_USER'};
    my $authdaemonGroup = $self->{'config'}->{'AUTHDAEMON_GROUP'};

    $fileContent =~ s/$authdaemonUser:$authdaemonGroup\s+\$rundir$/$mailUser:$authdaemonGroup \$rundir/m;

    my $rs = $file->set( $fileContent );
    $rs ||= $file->save();
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $main::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0755 );
}

=item _buildConf()

 Build courier configuration files

 Return int 0 on success, other on failure

=cut

sub _buildConf
{
    my $self = shift;

    my $rs = $self->_buildDHparametersFile();
    $rs ||= $self->_buildAuthdaemonrcFile();
    $rs ||= $self->_buildSslConfFiles();
    return $rs if $rs;

    my $data = {
        DATABASE_HOST        => main::setupGetQuestion( 'DATABASE_HOST' ),
        DATABASE_PORT        => main::setupGetQuestion( 'DATABASE_PORT' ),
        DATABASE_USER        => $self->{'config'}->{'AUTHDAEMON_DATABASE_USER'},
        DATABASE_PASSWORD    => $self->{'config'}->{'AUTHDAEMON_DATABASE_PASSWORD'},
        DATABASE_NAME        => main::setupGetQuestion( 'DATABASE_NAME' ),
        HOST_NAME            => main::setupGetQuestion( 'SERVER_HOSTNAME' ),
        MTA_MAILBOX_UID      => scalar getpwnam( $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'} ),
        MTA_MAILBOX_GID      => scalar getgrnam( $self->{'mta'}->{'config'}->{'MTA_MAILBOX_GID_NAME'} ),
        MTA_VIRTUAL_MAIL_DIR => $self->{'mta'}->{'config'}->{'MTA_VIRTUAL_MAIL_DIR'}
    };

    my %cfgFiles = (
        'authmysqlrc'   => [
            "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/authmysqlrc", # Destpath
            $self->{'config'}->{'AUTHDAEMON_USER'}, # Owner
            $self->{'config'}->{'AUTHDAEMON_GROUP'}, # Group
            0660 # Permissions
        ],
        'quota-warning' => [
            $self->{'config'}->{'QUOTA_WARN_MSG_PATH'}, # Destpath
            $self->{'mta'}->{'config'}->{'MTA_MAILBOX_UID_NAME'}, # Owner
            $main::imscpConfig{'ROOT_GROUP'}, # Group
            0640 # Permissions
        ]
    );

    for my $conffile(keys %cfgFiles) {
        $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'courier', $conffile, \ my $cfgTpl, $data );
        return $rs if $rs;

        unless (defined $cfgTpl) {
            $cfgTpl = iMSCP::File->new( filename => "$self->{'cfgDir'}/$conffile" )->get();
            unless (defined $cfgTpl) {
                error( sprintf( 'Could not read %s file', "$self->{'cfgDir'}/$conffile" ) );
                return 1;
            }
        }

        $rs = $self->{'eventManager'}->trigger( 'beforePoBuildConf', \ $cfgTpl, $conffile );
        return $rs if $rs;

        $cfgTpl = process( $data, $cfgTpl );

        $rs = $self->{'eventManager'}->trigger( 'afterPoBuildConf', \ $cfgTpl, $conffile );
        return $rs if $rs;

        my $filename = fileparse( $cfgFiles{$conffile}->[0] );

        my $file = iMSCP::File->new( filename => "$self->{'wrkDir'}/$filename" );
        $rs = $file->set( $cfgTpl );
        $rs ||= $file->save();
        $rs ||= $file->owner( $cfgFiles{$conffile}->[1], $cfgFiles{$conffile}->[2] );
        $rs ||= $file->mode( $cfgFiles{$conffile}->[3] );
        $rs ||= $file->copyFile( $cfgFiles{$conffile}->[0] );
        return $rs if $rs;
    }

    if (-f "$self->{'cfgDir'}/imapd.local") {
        my $file = iMSCP::File->new( filename => "$self->{'config'}->{'COURIER_CONF_DIR'}/imapd" );
        my $fileContent = $file->get();
        unless (defined $fileContent) {
            error( sprintf( 'Could not read %s file', $file->{'filename'} ) );
            return 1;
        }

        $fileContent = replaceBloc(
            "\n# Servers::po::courier::installer - BEGIN\n",
            "# Servers::po::courier::installer - ENDING\n",
            '',
            $fileContent
        );

        $fileContent .=
            "\n# Servers::po::courier::installer - BEGIN\n"
                .". $self->{'cfgDir'}/imapd.local\n"
                ."# Servers::po::courier::installer - ENDING\n";

        $rs = $file->set( $fileContent );
        $rs ||= $file->save();
        $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $main::imscpConfig{'ROOT_GROUP'} );
        $rs ||= $file->mode( 0644 );
        return $rs if $rs;
    }

    0;
}

=item _buildCyrusSaslConfFile()

 Build Cyrus SASL configuration file

 Return int 0 on success, other on failure

=cut

sub _buildCyrusSaslConfFile
{
    my $self = shift;

    my $rs = $self->_bkpConfFile( "self->{'config'}->{'SASL_CONF_DIR'}/smtpd.conf" );
    return $rs if $rs;

    my $dbHost = main::setupGetQuestion( 'DATABASE_HOST' );

    my $data = {
        DATABASE_HOST     => ($dbHost eq 'localhost') ? '127.0.0.1' : $dbHost, # Force TCP connection
        DATABASE_PORT     => main::setupGetQuestion( 'DATABASE_PORT' ),
        DATABASE_NAME     => main::setupGetQuestion( 'DATABASE_NAME' ),
        DATABASE_USER     => $self->{'config'}->{'SASL_DATABASE_USER'},
        DATABASE_PASSWORD => $self->{'config'}->{'SASL_DATABASE_PASSWORD'}
    };

    $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'courier', 'smtpd.conf', \ my $cfgTpl, $data );
    return $rs if $rs;

    unless (defined $cfgTpl) {
        $cfgTpl = iMSCP::File->new( filename => "$self->{'cfgDir'}/sasl/smtpd.conf" )->get();
        unless (defined $cfgTpl) {
            error( sprintf( 'Could not read %s file', "$self->{'cfgDir'}/sasl/smtpd.conf" ) );
            return 1;
        }
    }

    $rs = $self->{'eventManager'}->trigger( 'beforePoBuildSaslConfFile', \ $cfgTpl, 'smtpd.conf' );
    return $rs if $rs;

    $cfgTpl = process( $data, $cfgTpl );

    $rs = $self->{'eventManager'}->trigger( 'afterPoBuildSaslConfFil', \ $cfgTpl, 'smtpd.conf' );
    return $rs if $rs;

    my $file = iMSCP::File->new( filename => "$self->{'wrkDir'}/smtpd.conf" );
    $rs = $file->set( $cfgTpl );
    $rs ||= $file->save();
    $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $main::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0640 );
    $rs ||= $file->copyFile( "$self->{'config'}->{'SASL_CONF_DIR'}/smtpd.conf" );
}

=item _buildDHparametersFile()

 Build a DH parameters file with a stronger size (2048 instead of 768)

 Fix: #IP-1401
 Return int 0 on success, other on failure

=cut

sub _buildDHparametersFile
{
    my $self = shift;

    return 0 unless iMSCP::ProgramFinder::find( 'mkdhparams' );

    if (-f "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem") {
        my $rs = execute(
            [ 'openssl', 'dhparam', '-in', "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem", '-text', '-noout' ],
            \ my $stdout,
            \ my $stderr
        );
        debug( $stderr || 'Unknown error' ) if $rs;
        if ($rs == 0 && $stdout =~ /\((\d+)\s+bit\)/ && $1 >= 2048) {
            return 0; # Don't regenerate file if not needed
        }

        $rs = iMSCP::File->new( filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/dhparams.pem" )->delFile();
        return $rs if $rs;
    }

    startDetail();
    my $rs = step(
        sub {
            my $rs = execute( 'DH_BITS=2048 mkdhparams', \ my $stdout, \ my $stderr );
            debug($stdout) if $stdout;
            error( $stderr || 'Unknown error' ) if $rs;
            $rs;
        }, 'Generating DH parameter file. Please be patient...', 1, 1
    );
    endDetail();
    $rs;
}

=item _buildAuthdaemonrcFile()

 Build the authdaemonrc file

 Return int 0 on success, other on failure

=cut

sub _buildAuthdaemonrcFile
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'courier', 'authdaemonrc', \ my $cfgTpl, { } );
    return $rs if $rs;

    unless (defined $cfgTpl) {
        $cfgTpl = iMSCP::File->new( filename => "$self->{'bkpDir'}/authdaemonrc.system" )->get();
        unless (defined $cfgTpl) {
            error( sprintf( 'Could not read %s file', "$self->{'bkpDir'}/authdaemonrc.system" ) );
            return 1;
        }
    }

    $rs = $self->{'eventManager'}->trigger( 'beforePoBuildAuthdaemonrcFile', \ $cfgTpl, 'authdaemonrc' );
    return $rs if $rs;

    $cfgTpl =~ s/authmodulelist=".*"/authmodulelist="authmysql authpam"/;

    $rs = $self->{'eventManager'}->trigger( 'afterPoBuildAuthdaemonrcFile', \ $cfgTpl, 'authdaemonrc' );
    return $rs if $rs;

    my $file = iMSCP::File->new( filename => "$self->{'wrkDir'}/authdaemonrc" );
    $rs = $file->set( $cfgTpl );
    $rs ||= $file->save();
    $rs ||= $file->owner( $self->{'config'}->{'AUTHDAEMON_USER'}, $self->{'config'}->{'AUTHDAEMON_GROUP'} );
    $rs ||= $file->mode( 0660 );
    $rs ||= $file->copyFile( "$self->{'config'}->{'AUTHLIB_CONF_DIR'}" );
}

=item _buildSslConfFiles()

 Build ssl configuration file

 Return int 0 on success, other on failure

=cut

sub _buildSslConfFiles
{
    my $self = shift;

    return 0 unless main::setupGetQuestion( 'SERVICES_SSL_ENABLED' ) eq 'yes';

    for my $conffile($self->{'config'}->{'COURIER_IMAP_SSL'}, $self->{'config'}->{'COURIER_POP_SSL'}) {
        my $rs = $self->{'eventManager'}->trigger( 'onLoadTemplate', 'courier', $conffile, \ my $cfgTpl, { } );
        return $rs if $rs;

        unless (defined $cfgTpl) {
            $cfgTpl = iMSCP::File->new( filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/$conffile" )->get();
            unless (defined $cfgTpl) {
                error( sprintf( 'Could not read %s file', "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/$conffile" ) );
                return 1;
            }
        }

        $rs = $self->{'eventManager'}->trigger( 'beforePoBuildSslConfFile', \ $cfgTpl, $conffile );
        return $rs if $rs;

        if ($cfgTpl =~ m/^TLS_CERTFILE=/msg) {
            $cfgTpl =~ s!^TLS_CERTFILE=.*$!TLS_CERTFILE=$main::imscpConfig{'CONF_DIR'}/imscp_services.pem!gm;
        } else {
            $cfgTpl .= "TLS_CERTFILE=$main::imscpConfig{'CONF_DIR'}/imscp_services.pem";
        }

        $rs = $self->{'eventManager'}->trigger( 'afterPoBuildSslConfFile', \ $cfgTpl, $conffile );
        return $rs if $rs;

        my $file = iMSCP::File->new( filename => "$self->{'wrkDir'}/$conffile" );
        $rs = $file->set( $cfgTpl );
        $rs ||= $file->save();
        $rs ||= $file->owner( $main::imscpConfig{'ROOT_USER'}, $main::imscpConfig{'ROOT_GROUP'} );
        $rs ||= $file->mode( 0644 );
        $rs ||= $file->copyFile( "$self->{'config'}->{'AUTHLIB_CONF_DIR'}" );
        return $rs if $rs;
    }

    0;
}

=item _saveConf()

 Save configuration file

 Return int 0 on success, other on failure

=cut

sub _saveConf
{
    my $self = shift;

    (tied %{$self->{'config'}})->flush();
    iMSCP::File->new( filename => "$self->{'cfgDir'}/courier.data" )->copyFile( "$self->{'cfgDir'}/courier.old.data" );
}

=item _migrateFromDovecot()

 Migrate mailboxes from Dovecot

 Return int 0 on success, other on failure

=cut

sub _migrateFromDovecot
{
    my $self = shift;

    return 0 if $main::imscpConfig{'PO_SERVER'} eq $main::imscpOldConfig{'PO_SERVER'};

    my $rs = $self->{'eventManager'}->trigger( 'beforePoMigrateFromDovecot' );
    return $rs if $rs;

    my @cmd = (
        'perl', "$main::imscpConfig{'ENGINE_ROOT_DIR'}/PerlVendor/courier-dovecot-migrate.pl",
        '--to-courier',
        '--convert',
        '--overwrite',
        '--recursive',
        escapeShell( $self->{'mta'}->{'config'}->{'MTA_VIRTUAL_MAIL_DIR'} )
    );
    $rs = execute( "@cmd", \ my $stdout, \ my $stderr );
    debug( $stdout ) if $stdout;
    error( $stderr || 'Unknown error' ) if $rs;

    $main::imscpOldConfig{'PO_SERVER'} = 'courier' unless $rs;

    $rs ||= $self->{'eventManager'}->trigger( 'afterPoMigrateFromDovecot' );
}

=item _oldEngineCompatibility()

 Remove old files

 Return int 0 on success, other on failure

=cut

sub _oldEngineCompatibility
{
    my $self = shift;

    my $rs = $self->{'eventManager'}->trigger( 'beforePoOldEngineCompatibility' );
    return $rs if $rs;

    if (-f "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/userdb") {
        my $file = iMSCP::File->new( filename => "$self->{'config'}->{'AUTHLIB_CONF_DIR'}/userdb" );
        $rs = $file->set( '' );
        $rs ||= $file->save();
        $rs ||= $file->mode( 0600 );
        return $rs if $rs;

        $rs = execute( "makeuserdb -f $self->{'config'}->{'AUTHLIB_CONF_DIR'}/userdb", \ my $stdout, \ my $stderr );
        debug( $stdout ) if $stdout;
        error( $stderr || 'Unknown error' ) if $rs;
        return $rs if $rs;
    }

    $self->{'eventManager'}->trigger( 'afterPodOldEngineCompatibility' );
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
